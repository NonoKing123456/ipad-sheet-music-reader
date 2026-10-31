import 'dart:async';

import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;

import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/set_lists_screen.dart';
import 'sync_controller.dart';
import 'sync_screen.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key, required this.controller});
  final SyncController controller;
  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _collapsed = {};
  String _folder = '';
  bool _withinFolder = false;
  bool _opening = false;
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

  List<ScoreTarget> _targets() => [
    for (final entry
        in widget.controller.replica?.snapshot.availableEntries ??
            <LibraryEntry>[])
      if (widget.controller.locateOffline(entry.id)
          case final ScoreTarget target)
        target,
  ];
  Future<void> _open(LibraryEntry entry) async {
    if (_opening) return;
    final target = widget.controller.locateOffline(entry.id);
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('离线文件缺失或无法读取，请连接电脑重新同步修复。')));
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
    animation: widget.controller,
    builder: (context, _) {
      final sync = widget.controller;
      final view = sync.replica;
      if (view == null || view.manifest == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('离线谱库')),
          body: const Center(child: Text('尚未建立完整离线谱库，请先连接电脑同步。')),
        );
      }
      final folders = view.snapshot.folders;
      final folder = folders.contains(_folder) ? _folder : '';
      final searching = _search.text.trim().isNotEmpty;
      final listing = view.listFolder(folder);
      final entries = searching
          ? view.search(
              _search.text,
              withinFolder: _withinFolder ? folder : null,
            )
          : listing.entries;
      final children = searching ? <String>[] : listing.folders;
      final missing = view.snapshot.entries
          .where((e) => e.status == EntryStatus.missing)
          .toList();
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          return Scaffold(
            appBar: AppBar(
              title: const Text('离线谱库'),
              leading: IconButton(
                tooltip: '返回谱库',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
              ),
              actions: [
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
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: '搜索离线曲名或文件夹',
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
                                folder.isEmpty ? '离线谱库根目录' : folder,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
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
                                          : Icons.error_outline,
                                    ),
                                    title: Text(
                                      p.posix.basenameWithoutExtension(
                                        entry.relativePath,
                                      ),
                                    ),
                                    subtitle: Text(
                                      entry.relativePath,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => unawaited(_open(entry)),
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
  Widget _tree(List<String> folders) => ColoredBox(
    color: const Color(0xfff6f5ef),
    child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('离线文件夹', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        _node('', folders, 0),
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
