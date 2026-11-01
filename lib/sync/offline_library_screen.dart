import '../library/score_path_label.dart';
import '../library/directory_navigation.dart';
import '../library/page_count_service.dart';
import '../library/score_file_icon.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../signing/signing_expiry_chip.dart';

import 'package:flutter/services.dart';
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

class _OfflineStatusIcon extends StatelessWidget {
  const _OfflineStatusIcon({
    required this.availability,
    required this.pendingVersion,
    required this.path,
  });

  final ContentAvailability availability;
  final bool pendingVersion;
  final String path;

  @override
  Widget build(BuildContext context) {
    final ready = availability == ContentAvailability.ready;
    final unreadable = availability == ContentAvailability.unreadable;
    final label = ready
        ? pendingVersion
              ? '离线旧版可读，有更新待下载'
              : '已离线'
        : unreadable
        ? '本机内容不可读，请重新下载'
        : '未下载';
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: ScoreFileIcon(
            path: path,
            state: unreadable
                ? ScoreFileIconState.unreadable
                : !ready
                ? ScoreFileIconState.cloud
                : pendingVersion
                ? ScoreFileIconState.update
                : ScoreFileIconState.ready,
          ),
        ),
      ),
    );
  }
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final TextEditingController _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  final Set<String> _collapsed = {};
  Object? _treeStructure;
  FolderHierarchy? _hierarchy;
  List<FolderTreeRow>? _treeRows;
  String _folder = '';
  bool _withinFolder = false;
  bool _opening = false;
  String? _sourceId, _dismissedMessage;
  String? get _activeSourceId {
    final sources = widget.controller.offlineSources;
    if (sources.any((s) => s.id == _sourceId)) return _sourceId;
    return sources.isEmpty ? null : sources.first.id;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_searchKey);
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _search.clear();
    });
    _searchFocus.unfocus();
  }

  KeyEventResult _searchKey(KeyEvent event) {
    if (mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyF &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _openSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _refresh() async {
    final sync = widget.controller;
    if (sync.hasSyncActivity || !sync.paired) return;
    await sync.refreshCatalog();
  }

  void _selectSource(String id) => setState(() {
    _searchOpen = false;
    _searchFocus.unfocus();
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
        content: Text('$count 份曲谱 · ${_size(bytes)}'),
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
        final scope = entry != null
            ? {entry.id}
            : {
                for (final item
                    in sync.activeCollection?.currentItems ?? <CatalogItem>[])
                  if (!item.missing &&
                      item.sourceId == source &&
                      (folder == null ||
                          folder.isEmpty ||
                          item.relativePath.startsWith('$folder/')))
                    item.entryId,
              };
        await sync.synchronize(onlyEntryIds: scope);
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
    FocusManager.instance.removeEarlyKeyEventHandler(_searchKey);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  String _parent(String folder) =>
      folder.contains('/') ? folder.substring(0, folder.lastIndexOf('/')) : '';
  void _selectFolder(String folder) {
    setState(() {
      _folder = folder;
      _searchOpen = false;
      _searchFocus.unfocus();
      _search.clear();
    });
  }

  List<ScoreTarget> _targets() => widget.controller.offlineTargets;
  Future<void> _sync() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SyncScreen(
        controller: widget.controller,
        openOffline: () => Navigator.pop(context),
      ),
    ),
  );

  String _activityLabel(SyncController sync) {
    if (sync.backgroundImporting) return '正在保存下载内容';
    if (!sync.busy && sync.backgroundPendingObjects > 0) {
      return '后台下载中 · 余 ${sync.backgroundPendingObjects} 份';
    }
    if (sync.phase == SyncPhase.pairing) return '连接中';
    if (sync.phase == SyncPhase.verifying) return '校验中';
    if (sync.phase == SyncPhase.transferring) {
      final total = sync.totalObjects;
      if (total != null && sync.committingLibrary) return '正在保存下载内容';
      if (total != null && total > 0) {
        return '下载中 ${sync.processedObjects.clamp(0, total)}/$total';
      }
    }
    return '同步中';
  }

  Widget _syncActions({
    required bool compact,
    required bool minimal,
    required double maxWidth,
  }) {
    final sync = widget.controller;
    final active = sync.hasSyncActivity;
    final label = active
        ? _activityLabel(sync)
        : sync.paired
        ? '同步管理'
        : '连接电脑';
    final shortLabel = minimal
        ? active
              ? sync.phase == SyncPhase.transferring &&
                        (sync.totalObjects ?? 0) > 0
                    ? '${(100 * sync.processedObjects / sync.totalObjects!).clamp(0, 100).floor()}%'
                    : !sync.busy && sync.backgroundPendingObjects > 0
                    ? '余${sync.backgroundPendingObjects}份'
                    : '同步中'
              : sync.paired
              ? '管理'
              : label
        : label;
    final manage = Tooltip(
      message: active ? '$label，查看同步与连接' : label,
      child: TextButton.icon(
        key: const ValueKey('offline-sync-management'),
        onPressed: () => unawaited(_sync()),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(48, 48),
          textStyle: minimal ? const TextStyle(fontSize: 12) : null,
          iconSize: minimal ? 18 : null,
        ),
        icon: compact && !active
            ? null
            : active
            ? const _SyncActivityIcon()
            : Icon(sync.paired ? Icons.sync : Icons.computer),
        label: Text(shortLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final refresh = Tooltip(
      message: '更新电脑上的曲谱目录',
      child: TextButton.icon(
        key: const ValueKey('offline-refresh-catalog'),
        onPressed: sync.paired && sync.initializationError == null
            ? () => unawaited(_refresh())
            : null,
        icon: const Icon(Icons.refresh),
        label: const Text('更新目录', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (!active && !(compact && (_searchOpen || !sync.paired))) ...[
          if (compact)
            IconButton(
              key: const ValueKey('offline-refresh-catalog'),
              tooltip: '更新目录',
              icon: const Icon(Icons.refresh),
              onPressed: sync.paired && sync.initializationError == null
                  ? () => unawaited(_refresh())
                  : null,
            )
          else
            refresh,
        ],
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: manage,
        ),
      ],
    );
  }

  Future<void> _open(LibraryEntry entry) async {
    if (_opening) return;
    _opening = true;
    try {
      var target = widget.controller.locateOffline(entry.id);
      if (target == null) {
        await _download(entry: entry);
        if (!mounted) return;
        target = widget.controller.locateOffline(entry.id);
        if (target == null) return;
      }
      final readable = target;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => LibraryReaderScreen(
            workspace: widget.controller.workspace,
            locate: widget.controller.locateOffline,
            initialTarget: readable,
            sourceChanges: widget.controller,
            onLoaded: (document) => widget.controller.pageCounts.remember(
              PageMetadataKey(
                document.target.entryId,
                document.target.revisionId,
              ),
              document.pageCount,
            ),
          ),
        ),
      );
    } finally {
      _opening = false;
    }
  }

  Widget? _folderDownloadMenu({
    required String sourceId,
    required String folder,
  }) {
    if (!widget.controller.needsOfflineDownload(
      sourceId: sourceId,
      folder: folder,
    )) {
      return null;
    }
    return PopupMenuButton<String>(
      tooltip: '文件夹选项',
      onSelected: (_) =>
          unawaited(_download(sourceId: sourceId, folder: folder)),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'download',
          child: Text(folder.isEmpty ? '下载整个谱库' : '下载此文件夹'),
        ),
      ],
    );
  }

  void _setLists() => unawaited(
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SetListsScreen(
          workspace: widget.controller.workspace,
          locate: widget.controller.locateOffline,
          targets: _targets,
          catalog: () => widget.controller.offlineScoreCatalog,
          prepare: widget.controller.prepareOfflineScores,
          preparationLabel: '下载本曲单缺少内容',
          preparationNotice: '需要电脑在线。离线时会记住所选曲目，连接后再准备。',
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
      final entries = sync.offlineEntries(
        sourceId: _activeSourceId,
        folder: folder,
        query: _search.text,
        withinFolder: _withinFolder,
      );
      _ensureHierarchy(folders);
      final children = searching ? <String>[] : _hierarchy!.childrenOf(folder);
      final missing = sync.offlineMissingEntries;
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          // Keep connection/status text readable in phone and split-view widths.
          final compactActions =
              constraints.maxWidth < 700 ||
              MediaQuery.textScalerOf(context).scale(14) > 18;
          final otherActionsWidth =
              48.0 + // Search.
              (!_searchOpen ? 48 : 0) + // Set lists.
              (!wide && !widget.isHome ? 48 : 0) + // Folders.
              (!sync.hasSyncActivity &&
                      !(compactActions && (_searchOpen || !sync.paired))
                  ? compactActions
                        ? 48
                        : 124
                  : 0);
          final managementWidth =
              (constraints.maxWidth -
                      otherActionsWidth -
                      (!wide || !widget.isHome ? 56 : 0) -
                      (widget.isHome && !_searchOpen && compactActions
                          ? 80
                          : 16))
                  .clamp(56.0, 240.0);
          return Scaffold(
            appBar: AppBar(
              titleSpacing: compactActions ? 8 : null,
              title: wide && defaultTargetPlatform == TargetPlatform.windows
                  ? Row(
                      children: [
                        SizedBox(
                          width: 261,
                          child: Text(widget.isHome ? '曲谱库' : '离线谱库'),
                        ),
                        if (_searchOpen)
                          Expanded(
                            child: DirectorySearchField(
                              controller: _search,
                              focusNode: _searchFocus,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, titleConstraints) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_searchOpen ||
                              !widget.isHome ||
                              defaultTargetPlatform != TargetPlatform.iOS ||
                              titleConstraints.maxWidth >= 160)
                            Flexible(
                              child: _searchOpen
                                  ? DirectorySearchField(
                                      controller: _search,
                                      focusNode: _searchFocus,
                                      onChanged: (_) => setState(() {}),
                                    )
                                  : Text(
                                      widget.isHome ? '曲谱库' : '离线谱库',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                          if (widget.isHome &&
                              !kIsWeb &&
                              defaultTargetPlatform == TargetPlatform.iOS)
                            Flexible(
                              child: Visibility(
                                visible: !_searchOpen,
                                maintainState: true,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    left: compactActions ? 0 : 8,
                                  ),
                                  child: SigningExpiryChip(
                                    compact: compactActions,
                                    onRead: (value) =>
                                        sync.reportLocalSigningExpiry(
                                          value.expiration,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
              leading: widget.isHome
                  ? null
                  : IconButton(
                      tooltip: '返回谱库',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
              actions: [
                IconButton(
                  tooltip: _searchOpen ? '关闭搜索' : '搜索',
                  icon: Icon(_searchOpen ? Icons.close : Icons.search),
                  onPressed: _searchOpen ? _closeSearch : _openSearch,
                ),
                _syncActions(
                  compact: compactActions,
                  minimal: constraints.maxWidth < 360,
                  maxWidth: managementWidth,
                ),
                if (!wide && !widget.isHome)
                  Builder(
                    builder: (context) => IconButton(
                      tooltip: '离线文件夹',
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.folder_outlined),
                    ),
                  ),
                if (!_searchOpen)
                  IconButton(
                    tooltip: '曲单',
                    onPressed: _setLists,
                    icon: const Icon(Icons.queue_music),
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: DirectoryParentButton(
                                currentPath: folder,
                                parentLabel: _parent(folder).isEmpty
                                    ? '谱库根目录'
                                    : p.posix.basename(_parent(folder)),
                                rootLabel:
                                    sync.offlineSources
                                        .where(
                                          (source) =>
                                              source.id == _activeSourceId,
                                        )
                                        .firstOrNull
                                        ?.name ??
                                    '谱库',
                                onPressed: folder.isEmpty
                                    ? null
                                    : () => _selectFolder(_parent(folder)),
                              ),
                            ),
                            if (_activeSourceId != null)
                              _OfflineFolderIcon(
                                status: sync.folderOfflineStatus(
                                  sourceId: _activeSourceId!,
                                  folder: folder,
                                ),
                              ),
                            if (_activeSourceId != null &&
                                sync.needsOfflineDownload(
                                  sourceId: _activeSourceId!,
                                  folder: folder,
                                ))
                              _folderDownloadMenu(
                                sourceId: _activeSourceId!,
                                folder: folder,
                              )!,
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
                          title: Text('${missing.length} 份源曲谱缺失'),
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
                          title: Text('${sync.workspace.unsavedCount} 项批注未保存'),
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
                                      leading: _OfflineFolderIcon(
                                        status: sync.folderOfflineStatus(
                                          sourceId: _activeSourceId!,
                                          folder: child,
                                        ),
                                      ),
                                      title: Text(p.posix.basename(child)),
                                      subtitle: Text(child),
                                      trailing: _folderDownloadMenu(
                                        sourceId: _activeSourceId!,
                                        folder: child,
                                      ),
                                      onTap: () => _selectFolder(child),
                                    );
                                  }
                                  final entry =
                                      entries[index - children.length];
                                  final ready =
                                      entry.availability ==
                                      ContentAvailability.ready;
                                  final pending =
                                      ready && sync.hasPendingVersion(entry.id);
                                  return ListTile(
                                    minTileHeight: 72,
                                    leading: _OfflineStatusIcon(
                                      availability: entry.availability,
                                      pendingVersion: pending,
                                      path: entry.relativePath,
                                    ),
                                    title: Text(
                                      p.posix.basenameWithoutExtension(
                                        entry.relativePath,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${sync.sourceNameFor(entry.id)} · ${scoreParentFolder(entry.relativePath)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => unawaited(_open(entry)),
                                    trailing: ScoreFileTrailing(
                                      metadata: ScoreFileMetadata(
                                        key: ValueKey((
                                          entry.id,
                                          entry.currentRevisionId,
                                        )),
                                        entryId: entry.id,
                                        revisionId: entry.currentRevisionId,
                                        path: entry.relativePath,
                                        service: sync.pageCounts,
                                      ),
                                      menuAction: PopupMenuButton<String>(
                                        tooltip: '离线选项',
                                        onSelected: (value) => unawaited(
                                          value == 'download'
                                              ? _download(entry: entry)
                                              : value == 'remove'
                                              ? sync.removeOfflineDownload(
                                                  entry.id,
                                                )
                                              : sync.selectOffline(
                                                  OfflineRule(
                                                    sourceId: sync.sourceIdFor(
                                                      entry.id,
                                                    )!,
                                                    entryId: entry.id,
                                                    selected: false,
                                                  ),
                                                ),
                                        ),
                                        itemBuilder: (_) => [
                                          if (!ready || pending)
                                            PopupMenuItem(
                                              value: 'download',
                                              child: Text(
                                                pending ? '更新下载' : '下载到iPad',
                                              ),
                                            ),
                                          const PopupMenuItem(
                                            value: 'unselect',
                                            child: Text('取消离线选择'),
                                          ),
                                          if (ready)
                                            const PopupMenuItem(
                                              value: 'remove',
                                              child: Text('移除本机下载'),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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
  void _ensureHierarchy(List<String> folders) {
    final key = (
      widget.controller.activeCollection?.directory ?? folders,
      _activeSourceId,
    );
    if (key != _treeStructure) {
      _treeStructure = key;
      _hierarchy = FolderHierarchy(folders);
      _treeRows = null;
    }
  }

  Widget _tree(List<String> folders) {
    _ensureHierarchy(folders);
    final visible = _treeRows ??= _hierarchy!.visibleRows(_collapsed);
    final rows = [
      for (final source in widget.controller.offlineSources) ...[
        (source, null as FolderTreeRow?),
        if (_activeSourceId == source.id)
          for (final row in visible) (source, row),
      ],
    ];
    return Material(
      color: const Color(0xfff6f5ef),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              key: const PageStorageKey('offline-folder-tree'),
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: rows.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '离线文件夹',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  );
                }
                final (source, row) = rows[index - 1];
                if (row != null) return _node(row.path, row.depth);
                return ListTile(
                  title: Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: _OfflineFolderIcon(
                    status: widget.controller.folderOfflineStatus(
                      sourceId: source.id,
                    ),
                  ),
                  selected: _activeSourceId == source.id && _folder.isEmpty,
                  onTap: () => _selectSource(source.id),
                  trailing: _folderDownloadMenu(
                    sourceId: source.id,
                    folder: '',
                  ),
                );
              },
            ),
          ),
          if (defaultTargetPlatform == TargetPlatform.windows)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SigningExpiryChip(
                  pairedDevice: true,
                  pairedStatus: widget.controller.signingStatus,
                  unavailable: widget.controller.signingUnavailable,
                  onRefresh: widget.controller.refreshSigningStatus,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _node(String folder, int depth) {
    final children = _hierarchy!.childrenOf(folder);
    final expanded = !_collapsed.contains(folder);
    return Padding(
      key: ValueKey('offline-folder-$folder'),
      padding: EdgeInsets.only(left: (depth * 12.0).clamp(0, 132)),
      child: ListTile(
        dense: true,
        selected: _folder == folder,
        leading: _OfflineFolderIcon(
          status: widget.controller.folderOfflineStatus(
            sourceId: _activeSourceId!,
            folder: folder,
          ),
        ),
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
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() {
                  expanded ? _collapsed.add(folder) : _collapsed.remove(folder);
                  _treeRows = null;
                }),
              ),
      ),
    );
  }
}

class _SyncActivityIcon extends StatefulWidget {
  const _SyncActivityIcon();

  @override
  State<_SyncActivityIcon> createState() => _SyncActivityIconState();
}

class _SyncActivityIconState extends State<_SyncActivityIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _turns.stop();
    } else {
      _turns.repeat();
    }
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    key: const ValueKey('offline-sync-rotation'),
    turns: _turns,
    child: const Icon(Icons.sync),
  );

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }
}

class _OfflineFolderIcon extends StatelessWidget {
  const _OfflineFolderIcon({required this.status});
  final OfflineFolderStatus status;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: status.description,
    excludeFromSemantics: true,
    child: Semantics(
      label: status.description,
      child: ExcludeSemantics(
        child: ScoreFileIcon.folder(
          state: status.total == 0
              ? ScoreFileIconState.empty
              : status.allCurrent
              ? ScoreFileIconState.ready
              : status.readable == 0
              ? ScoreFileIconState.cloud
              : ScoreFileIconState.partial,
        ),
      ),
    ),
  );
}
