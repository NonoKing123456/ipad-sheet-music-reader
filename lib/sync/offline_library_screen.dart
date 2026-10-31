import '../library/score_path_label.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;

import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/set_lists_screen.dart';
import 'sync_controller.dart';
import 'sync_screen.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({
    super.key,
    required this.controller,
    this.isHome = false,
  });
  final SyncController controller;
  final bool isHome;
  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _collapsed = {};
  String _folder = '';
  bool _withinFolder = false;
  bool _opening = false;
  String? _sourceId, _dismissedMessage;
  String? get _activeSourceId {
    final sources = widget.controller.offlineSources;
    if (sources.any((s) => s.id == _sourceId)) return _sourceId;
    return sources.isEmpty ? null : sources.first.id;
  }

  void _selectSource(String id) => setState(() {
    _sourceId = id;
    _folder = '';
    _search.clear();
    _collapsed.clear();
  });
  String _size(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';
  Future<void> _download({
    String? sourceId,
    String? folder,
    LibraryEntry? entry,
  }) async {
    final sync = widget.controller;
    final source =
        sourceId ??
        (entry == null ? _activeSourceId : sync.sourceIdFor(entry.id));
    if (source == null) return;
    final (count, bytes) = sync.downloadEstimate(
      sourceId: source,
      folder: folder,
      entryId: entry?.id,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          entry == null
              ? (folder?.isEmpty ?? true)
                    ? '下载整个谱库'
                    : '下载文件夹'
              : '下载到iPad',
        ),
        content: Text('$count 份曲谱 · ${_size(bytes)}\n需要电脑在线，已下载的内容会复用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: count == 0 ? null : () => Navigator.pop(context, true),
            child: const Text('下载到iPad'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await sync.selectOffline(
        OfflineRule(
          sourceId: source,
          folder: entry == null ? folder ?? '' : null,
          entryId: entry?.id,
          selected: true,
        ),
      );
      if (sync.paired) {
        await sync.synchronize();
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已记住所选曲谱，连接电脑后可下载。')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能保存下载选择，请检查空间后重试。')));
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _parent(String folder) =>
      folder.contains('/') ? folder.substring(0, folder.lastIndexOf('/')) : '';
  void _selectFolder(String folder) {
    setState(() {
      _folder = folder;
      _search.clear();
    });
  }

  List<ScoreTarget> _targets() => widget.controller.offlineTargets;
  Future<void> _sync({bool immediate = false}) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SyncScreen(
        controller: widget.controller,
        openOffline: () => Navigator.pop(context),
        scanOnOpen: immediate && !widget.controller.paired,
        syncOnOpen: immediate && widget.controller.paired,
      ),
    ),
  );
  Future<void> _open(LibraryEntry entry) async {
    if (_opening) return;
    final target = widget.controller.locateOffline(entry.id);
    if (target == null) {
      await _download(entry: entry);
      return;
    }
    _opening = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => LibraryReaderScreen(
            workspace: widget.controller.workspace,
            locate: widget.controller.locateOffline,
            initialTarget: target,
            sourceChanges: widget.controller,
          ),
        ),
      );
    } finally {
      _opening = false;
    }
  }

  void _setLists() => unawaited(
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SetListsScreen(
          workspace: widget.controller.workspace,
          locate: widget.controller.locateOffline,
          targets: _targets,
          sourceChanges: widget.controller,
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.workspace,
    ]),
    builder: (context, _) {
      final sync = widget.controller;
      final view = sync.replica;
      final folders =
          sync.activeCollection?.index?.folders[_activeSourceId] ??
          view?.snapshot.folders ??
          const [''];
      final folder = folders.contains(_folder) ? _folder : '';
      final searching = _search.text.trim().isNotEmpty;
      final terms = _search.text.toLowerCase().trim().split(RegExp(r'\s+'));
      final entries =
          (sync.offlineSnapshot?.availableEntries ?? <LibraryEntry>[]).where((
            entry,
          ) {
            final sourceId = sync.sourceIdFor(entry.id);
            if (!searching) {
              return sourceId == _activeSourceId &&
                  _parent(entry.relativePath) == folder;
            }
            if (_withinFolder &&
                (sourceId != _activeSourceId ||
                    !folderContains(folder, entry.relativePath))) {
              return false;
            }
            final text = '${sync.sourceNameFor(entry.id)}/${entry.relativePath}'
                .toLowerCase();
            return terms.every(text.contains);
          }).toList();
      final children = searching
          ? <String>[]
          : folders.where((f) => f.isNotEmpty && _parent(f) == folder).toList();
      final missing =
          sync.offlineSnapshot?.entries
              .where((e) => e.status == EntryStatus.missing)
              .toList() ??
          <LibraryEntry>[];
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.isHome ? '曲谱库' : '离线谱库'),
              leading: widget.isHome
                  ? null
                  : IconButton(
                      tooltip: '返回谱库',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
              actions: [
                IconButton(
                  tooltip: '同步与连接',
                  onPressed: () => unawaited(_sync()),
                  icon: const Icon(Icons.sync),
                ),
                if (!wide)
                  Builder(
                    builder: (context) => IconButton(
                      tooltip: '离线文件夹',
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.folder_outlined),
                    ),
                  ),
                IconButton(
                  tooltip: '曲单',
                  onPressed: _setLists,
                  icon: const Icon(Icons.queue_music),
                ),
                if (sync.workspace.store.snapshot.conflicts.isNotEmpty)
                  IconButton(
                    tooltip: '保留的冲突版本',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SyncConflictsScreen(controller: sync),
                      ),
                    ),
                    icon: const Icon(Icons.compare),
                  ),
              ],
            ),
            drawer: wide
                ? null
                : Drawer(child: SafeArea(child: _tree(folders))),
            body: Row(
              children: [
                if (wide) SizedBox(width: 260, child: _tree(folders)),
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                sync.hasOfflineLibrary
                                    ? '已离线 ${sync.offlineCount} 份曲谱'
                                    : '连接电脑更新目录，再选择要下载的曲谱',
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed: sync.busy
                                  ? null
                                  : () => unawaited(_sync(immediate: true)),
                              icon: Icon(
                                sync.paired
                                    ? Icons.sync
                                    : Icons.qr_code_scanner,
                              ),
                              label: Text(
                                sync.busy
                                    ? '正在同步…'
                                    : sync.paired
                                    ? '更新目录与所选内容'
                                    : '扫描电脑二维码',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (sync.initializationError != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(sync.initializationError!),
                        ),
                      if (sync.busy)
                        const LinearProgressIndicator(minHeight: 2),
                      if (sync.message != null &&
                          sync.message != _dismissedMessage &&
                          (sync.phase == SyncPhase.partial ||
                              sync.phase == SyncPhase.failed ||
                              sync.phase == SyncPhase.cancelled))
                        ListTile(
                          dense: true,
                          title: Text(
                            sync.message!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: sync.busy
                                    ? null
                                    : () => unawaited(sync.synchronize()),
                                child: const Text('重试'),
                              ),
                              IconButton(
                                tooltip: '关闭此提示',
                                onPressed: () => setState(
                                  () => _dismissedMessage = sync.message,
                                ),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: '搜索曲名、谱库或文件夹',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空搜索',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(_search.clear),
                                  ),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: '上一级文件夹',
                              onPressed: folder.isEmpty
                                  ? null
                                  : () => _selectFolder(_parent(folder)),
                              icon: const Icon(Icons.arrow_upward),
                            ),
                            Expanded(
                              child: Text(
                                folder.isEmpty ? '谱库根目录' : folder,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_activeSourceId != null)
                              TextButton.icon(
                                onPressed: () =>
                                    unawaited(_download(folder: folder)),
                                icon: const Icon(Icons.download_outlined),
                                label: Text(
                                  folder.isEmpty ? '下载整个谱库' : '下载此文件夹',
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (searching)
                        CheckboxListTile(
                          dense: true,
                          title: const Text('仅搜索当前文件夹及子文件夹'),
                          value: _withinFolder,
                          onChanged: (value) =>
                              setState(() => _withinFolder = value ?? false),
                        ),
                      if (missing.isNotEmpty)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.info_outline),
                          title: Text('${missing.length} 份源曲谱已标为缺失，缓存与曲单引用仍保留'),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('源曲谱缺失'),
                              content: SizedBox(
                                width: 550,
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    missing
                                        .map((e) => e.relativePath)
                                        .join('\n'),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (sync.workspace.unsavedCount > 0)
                        ListTile(
                          title: Text('${sync.workspace.unsavedCount} 笔未保存'),
                          trailing: TextButton(
                            onPressed: () =>
                                unawaited(sync.workspace.retryStrokes()),
                            child: const Text('重试保存'),
                          ),
                        ),
                      Expanded(
                        child: entries.isEmpty && children.isEmpty
                            ? const Center(child: Text('没有找到曲谱'))
                            : ListView.builder(
                                itemCount: entries.length + children.length,
                                itemBuilder: (context, index) {
                                  if (index < children.length) {
                                    final child = children[index];
                                    return ListTile(
                                      leading: const Icon(
                                        Icons.folder_outlined,
                                      ),
                                      title: Text(p.posix.basename(child)),
                                      subtitle: Text(child),
                                      trailing: IconButton(
                                        tooltip: '下载到iPad',
                                        icon: const Icon(
                                          Icons.download_outlined,
                                        ),
                                        onPressed: () =>
                                            unawaited(_download(folder: child)),
                                      ),
                                      onTap: () => _selectFolder(child),
                                    );
                                  }
                                  final entry =
                                      entries[index - children.length];
                                  return ListTile(
                                    leading: Icon(
                                      entry.availability ==
                                              ContentAvailability.ready
                                          ? Icons.description_outlined
                                          : Icons.cloud_download_outlined,
                                    ),
                                    title: Text(
                                      p.posix.basenameWithoutExtension(
                                        entry.relativePath,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${sync.sourceNameFor(entry.id)} · ${scoreParentFolder(entry.relativePath)}\n${entry.availability == ContentAvailability.ready
                                          ? sync.hasPendingVersion(entry.id)
                                                ? '离线旧版 · 有更新待下载'
                                                : '已离线'
                                          : '未下载'}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => unawaited(_open(entry)),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (entry.availability !=
                                                ContentAvailability.ready ||
                                            sync.hasPendingVersion(entry.id))
                                          IconButton(
                                            tooltip: '下载到iPad',
                                            icon: const Icon(
                                              Icons.download_outlined,
                                            ),
                                            onPressed: () => unawaited(
                                              _download(entry: entry),
                                            ),
                                          ),
                                        PopupMenuButton<String>(
                                          tooltip: '离线选项',
                                          onSelected: (value) => unawaited(
                                            value == 'remove'
                                                ? sync.removeOfflineDownload(
                                                    entry.id,
                                                  )
                                                : sync.selectOffline(
                                                    OfflineRule(
                                                      sourceId: sync
                                                          .sourceIdFor(
                                                            entry.id,
                                                          )!,
                                                      entryId: entry.id,
                                                      selected: false,
                                                    ),
                                                  ),
                                          ),
                                          itemBuilder: (_) => [
                                            const PopupMenuItem(
                                              value: 'unselect',
                                              child: Text('取消离线选择'),
                                            ),
                                            if (entry.availability ==
                                                ContentAvailability.ready)
                                              const PopupMenuItem(
                                                value: 'remove',
                                                child: Text('移除本机下载'),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                      Container(
                        width: double.infinity,
                        color: const Color(0xfffaf9f5),
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${sync.offlineCount} 份可读离线曲谱 · 断网仍可阅读和批注',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  Widget _tree(List<String> folders) => Material(
    color: const Color(0xfff6f5ef),
    child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('离线文件夹', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        for (final source in widget.controller.offlineSources) ...[
          ListTile(
            title: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            leading: const Icon(Icons.library_music_outlined),
            selected: _activeSourceId == source.id && _folder.isEmpty,
            onTap: () => _selectSource(source.id),
            trailing: IconButton(
              tooltip: '下载整个谱库',
              icon: const Icon(Icons.download_outlined),
              onPressed: () =>
                  unawaited(_download(sourceId: source.id, folder: '')),
            ),
          ),
          if (_activeSourceId == source.id)
            for (final folder in folders.where(
              (f) => f.isNotEmpty && _parent(f).isEmpty,
            ))
              _node(folder, folders, 1),
        ],
      ],
    ),
  );
  Widget _node(String folder, List<String> folders, int depth) {
    final children =
        folders
            .where(
              (candidate) =>
                  candidate.isNotEmpty && _parent(candidate) == folder,
            )
            .toList()
          ..sort();
    final expanded = !_collapsed.contains(folder);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.only(left: (depth * 12.0).clamp(0, 132)),
          child: ListTile(
            dense: true,
            selected: _folder == folder,
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              folder.isEmpty ? '全部离线谱库' : p.posix.basename(folder),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _selectFolder(folder),
            trailing: children.isEmpty
                ? null
                : IconButton(
                    tooltip: expanded ? '收起文件夹' : '展开文件夹',
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    onPressed: () => setState(() {
                      expanded
                          ? _collapsed.add(folder)
                          : _collapsed.remove(folder);
                    }),
                  ),
          ),
        ),
        if (expanded)
          for (final child in children) _node(child, folders, depth + 1),
      ],
    );
  }
}
