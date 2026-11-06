import '../library/score_path_label.dart';
import '../library/directory_navigation.dart';
import '../library/library_widgets.dart';
import '../library/score_file_icon.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../signing/signing_expiry_chip.dart';

import 'package:flutter/services.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart' show PageKey, ScoreSetList;

import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/set_lists_screen.dart';
import '../reader/add_to_set_list_dialog.dart';
import '../theme/reader_icons.dart';
import 'sync_controller.dart';
import 'sync_screen.dart';
import '../theme/app_theme.dart';
import '../theme/device_layout.dart';
import '../theme/tokens.dart';
import '../sharing/score_share.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({
    super.key,
    required this.controller,
    this.isHome = false,
    this.openLocalImports,
  });
  final SyncController controller;
  final bool isHome;
  final VoidCallback? openLocalImports;
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
  String _query = '';
  bool _setListsOpen = false;
  String? _setListId;
  bool _setListCreate = false;
  int _setListEntry = 0;
  final Set<String> _collapsed = {};
  final Set<String> _knownTreeFolders = {};
  Object? _treeStructure;
  FolderHierarchy? _hierarchy;
  List<FolderTreeRow>? _treeRows;
  Object? _navEntriesKey;
  List<LibraryNavEntry> _navEntries = const [];
  String _folder = '';
  bool _withinFolder = false;
  bool _opening = false;
  final Set<String> _sharingEntries = {};
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
    setState(() {
      _searchOpen = true;
      _setListsOpen = false;
      _setListId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _search.clear();
      _query = '';
    });
    _searchFocus.unfocus();
  }

  KeyEventResult _searchKey(KeyEvent event) {
    if (mounted &&
        _searchOpen &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (!_search.value.composing.isValid ||
            _search.value.composing.isCollapsed)) {
      _closeSearch();
      return KeyEventResult.handled;
    }
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
    await sync.synchronize();
  }

  void _selectSource(String id) => setState(() {
    _setListsOpen = false;
    _setListId = null;
    _searchOpen = false;
    _searchFocus.unfocus();
    _sourceId = id;
    _folder = '';
    _search.clear();
    _query = '';
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

  void _selectFolder(String folder) {
    _setListsOpen = false;
    _setListId = null;
    _collapsed.removeWhere(
      (path) => folder == path || folder.startsWith('$path/'),
    );
    _treeRows = null;
    setState(() {
      _folder = folder;
      _searchOpen = false;
      _searchFocus.unfocus();
      _search.clear();
      _query = '';
    });
  }

  List<ScoreTarget> _targets() => widget.controller.offlineTargets;
  Future<void> _sync() => showDeviceSyncPanel(
    context,
    controller: widget.controller,
    openOffline: () => Navigator.pop(context),
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

  Future<void> _open(LibraryEntry entry) async {
    if (_opening) return;
    _opening = true;
    final savedQuery = _searchOpen ? _query : null;
    var opened = false;
    try {
      var target = widget.controller.locateOffline(entry.id);
      if (target == null) {
        await _download(entry: entry);
        if (!mounted) return;
        target = widget.controller.locateOffline(entry.id);
        if (target == null) return;
      }
      final readable = target;
      opened = true;
      widget.controller.setReaderActive(true);
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
      if (opened) widget.controller.setReaderActive(false);
      _opening = false;
      if (mounted && opened && savedQuery != null) {
        setState(() {
          _searchOpen = true;
          _search.text = savedQuery;
          _query = savedQuery;
        });
      }
    }
  }

  Widget _folderDownloadMenu({
    required String sourceId,
    required String folder,
  }) {
    final needsDownload = widget.controller.needsOfflineDownload(
      sourceId: sourceId,
      folder: folder,
    );
    return PopupMenuButton<String>(
      style: libraryIconButtonStyle(context),
      constraints: const BoxConstraints.tightFor(width: ScoreLayout.menuWidth),
      tooltip: '文件夹选项',
      icon: const ReaderIcon(ReaderGlyph.more),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'download') {
          unawaited(_download(sourceId: sourceId, folder: folder));
        } else {
          showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('文件夹位置'),
              content: SelectableText('$_sourceName / $folder'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'location', child: Text('查看位置')),
        if (needsDownload)
          PopupMenuItem(
            value: 'download',
            child: Text(folder.isEmpty ? '下载整个谱库' : '下载此文件夹'),
          ),
      ],
    );
  }

  void _setLists({String? initialListId, bool initialCreate = false}) {
    setState(() {
      _setListsOpen = true;
      _setListId = initialListId;
      _setListCreate = initialCreate;
      _setListEntry++;
    });
    _searchFocus.unfocus();
  }

  Widget _embeddedSetLists() => SetListsScreen(
    key: ValueKey(('offline-setlists', _setListEntry)),
    workspace: widget.controller.workspace,
    embedded: true,
    initialListId: _setListId,
    initialCreate: _setListCreate,
    pageCounts: widget.controller.pageCounts,
    onReaderActive: widget.controller.setReaderActive,
    onBack: () => setState(() {
      _setListsOpen = false;
      _setListId = null;
      _setListCreate = false;
    }),
    onSelectionChanged: (id) => setState(() {
      _setListId = id;
      _setListCreate = false;
    }),
    locate: widget.controller.locateOffline,
    targets: _targets,
    catalog: () => widget.controller.offlineScoreCatalog,
    prepare: widget.controller.prepareOfflineScores,
    preparationLabel: '下载本曲单缺少内容',
    preparationNotice: '需要电脑在线。离线时会记住所选曲目，连接后再准备。',
    sourceChanges: widget.controller,
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.workspace,
    ]),
    builder: (context, _) {
      final sync = widget.controller;
      final folders =
          sync.activeCollection?.index?.folders[_activeSourceId] ??
          sync.replica?.snapshot.folders ??
          const [''];
      final folder = folders.contains(_folder) ? _folder : '';
      final searching = _query.trim().isNotEmpty;
      final entries = sync.offlineEntries(
        sourceId: _activeSourceId,
        folder: folder,
        query: _query,
        withinFolder: _withinFolder,
      );
      _ensureHierarchy(folders);
      final children = searching ? <String>[] : _hierarchy!.childrenOf(folder);
      final ipad = DeviceLayoutScope.isCompact(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >=
              (ipad
                  ? ScoreLayout.ipadSidebarMin
                  : ScoreLayout.windowsSidebarMin);
          return Scaffold(
            drawer: wide
                ? null
                : Drawer(
                    width: ScoreLayout.drawerWidth,
                    child: SafeArea(child: _tree(folders)),
                  ),
            body: SafeArea(
              child: Row(
                children: [
                  if (wide)
                    SizedBox(
                      width: ScoreLayout.sidebarWidth,
                      child: _tree(folders),
                    ),
                  Expanded(
                    child: _setListsOpen
                        ? _embeddedSetLists()
                        : Column(
                            children: [
                              Builder(
                                builder: (headerContext) =>
                                    _header(headerContext, wide, folder),
                              ),
                              if (!wide && ipad)
                                SizedBox(
                                  height: ScoreLayout.sourceStripHeight,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: ScoreLayout.listMargin,
                                    ),
                                    itemCount: sync.offlineSources.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: 8),
                                    itemBuilder: (_, index) {
                                      final source = sync.offlineSources[index];
                                      final selected =
                                          source.id == _activeSourceId;
                                      return Center(
                                        child: TextButton(
                                          onPressed: () =>
                                              _selectSource(source.id),
                                          style: TextButton.styleFrom(
                                            backgroundColor: selected
                                                ? ScoreTokens.of(context)
                                                      .pineWash
                                                : ScoreTokens.of(context)
                                                      .paper0,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                            ),
                                            minimumSize: const Size(0, 40),
                                            shape: const RoundedRectangleBorder(
                                              borderRadius:
                                                  ScoreRadius.controlAll,
                                            ),
                                          ),
                                          child: Text(
                                            source.name,
                                            style: ScoreText.caption.copyWith(
                                              color: selected
                                                  ? ScoreTokens.of(context).pine
                                                  : ScoreTokens.of(context)
                                                        .ink700,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              Expanded(
                                child: LibraryOutsideTapListener(
                                  enabled: _searchOpen,
                                  onTap: () => scheduleMicrotask(() {
                                    if (mounted &&
                                        _searchOpen &&
                                        (ModalRoute.of(context)?.isCurrent ??
                                            true)) {
                                      _closeSearch();
                                    }
                                  }),
                                  child: Column(
                                    children: [
                                      if (!wide)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: ScoreLayout.listMargin,
                                          ),
                                          child: DirectoryBreadcrumbs(
                                            rootLabel: _sourceName,
                                            currentPath: folder,
                                            onNavigate: _selectFolder,
                                          ),
                                        ),
                                      if (searching)
                                        LibrarySearchContext(
                                          count: entries.length,
                                          withinFolder: _withinFolder,
                                          onScopeChanged: (value) => setState(
                                            () => _withinFolder = value,
                                          ),
                                        ),
                                      if (sync.initializationError != null)
                                        _notice(sync.initializationError!),
                                      if (sync.busy)
                                        const LinearProgressIndicator(
                                          minHeight: 2,
                                        ),
                                      if (sync.message != null &&
                                          sync.message != _dismissedMessage &&
                                          [
                                            SyncPhase.partial,
                                            SyncPhase.failed,
                                            SyncPhase.cancelled,
                                          ].contains(sync.phase))
                                        _notice(
                                          sync.message!,
                                          action: TextButton(
                                            onPressed: sync.busy
                                                ? null
                                                : () => unawaited(
                                                    sync.synchronize(),
                                                  ),
                                            child: const Text('重试'),
                                          ),
                                          dismiss: () => setState(
                                            () => _dismissedMessage =
                                                sync.message,
                                          ),
                                        ),
                                      if (sync.workspace.unsavedCount > 0)
                                        _notice(
                                          '${sync.workspace.unsavedCount} 项批注未保存',
                                          action: TextButton(
                                            onPressed: () => unawaited(
                                              sync.workspace.retryStrokes(),
                                            ),
                                            child: const Text('重试保存'),
                                          ),
                                        ),
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: ScoreLayout.listMargin,
                                          ),
                                          child: Column(
                                            children: [
                                              const LibraryColumnHeader(),
                                              Expanded(
                                                child:
                                                    entries.isEmpty &&
                                                        children.isEmpty
                                                    ? Center(
                                                        child: Text(
                                                          searching
                                                              ? '未找到曲谱'
                                                              : '这个文件夹里还没有曲谱',
                                                          style: ScoreText.body
                                                              .copyWith(
                                                                color:
                                                                    ScoreTokens.of(
                                                                      context,
                                                                    ).ink500,
                                                              ),
                                                        ),
                                                      )
                                                    : ListView.builder(
                                                        key: PageStorageKey((
                                                          _activeSourceId,
                                                          folder,
                                                          _query,
                                                        )),
                                                        padding:
                                                            EdgeInsets.zero,
                                                        itemCount:
                                                            entries.length +
                                                            children.length,
                                                        itemBuilder: (context, index) {
                                                          if (index <
                                                              children.length) {
                                                            final child =
                                                                children[index];
                                                            final status = sync
                                                                .folderOfflineStatus(
                                                                  sourceId:
                                                                      _activeSourceId!,
                                                                  folder: child,
                                                                );
                                                            return LibraryFileRow(
                                                              key: ValueKey(
                                                                'offline-library-folder-$child',
                                                              ),
                                                              leading:
                                                                  _OfflineFolderIcon(
                                                                    status:
                                                                        status,
                                                                  ),
                                                              name: p.posix
                                                                  .basename(
                                                                    child,
                                                                  ),
                                                              subtitle:
                                                                  '${status.total} 项',
                                                              action: _folderDownloadMenu(
                                                                sourceId:
                                                                    _activeSourceId!,
                                                                folder: child,
                                                              ),
                                                              onTap: () =>
                                                                  _selectFolder(
                                                                    child,
                                                                  ),
                                                            );
                                                          }
                                                          final entry =
                                                              entries[index -
                                                                  children
                                                                      .length];
                                                          final ready =
                                                              entry
                                                                  .availability ==
                                                              ContentAvailability
                                                                  .ready;
                                                          final pending =
                                                              ready &&
                                                              sync.hasPendingVersion(
                                                                entry.id,
                                                              );
                                                          return LibraryFileRow(
                                                            key: ValueKey(
                                                              'offline-library-file-${entry.id}',
                                                            ),
                                                            leading: _OfflineStatusIcon(
                                                              availability: entry
                                                                  .availability,
                                                              pendingVersion:
                                                                  pending,
                                                              path: entry
                                                                  .relativePath,
                                                            ),
                                                            name: p.posix.basename(
                                                              entry
                                                                  .relativePath,
                                                            ),
                                                            query: searching
                                                                ? _query
                                                                : '',
                                                            subtitle: searching
                                                                ? '${sync.sourceNameFor(entry.id)} / ${scoreParentFolder(entry.relativePath)}'
                                                                : null,
                                                            metadata: LibraryFileMetadata(
                                                              entryId: entry.id,
                                                              revisionId: entry
                                                                  .currentRevisionId,
                                                              path: entry
                                                                  .relativePath,
                                                              service: sync
                                                                  .pageCounts,
                                                            ),
                                                            action: Builder(
                                                              builder: (shareContext) => PopupMenuButton<String>(
                                                                style:
                                                                    libraryIconButtonStyle(
                                                                      context,
                                                                    ),
                                                                constraints:
                                                                    const BoxConstraints.tightFor(
                                                                      width: ScoreLayout
                                                                          .menuWidth,
                                                                    ),
                                                                tooltip: '曲谱选项',
                                                                icon:
                                                                    const ReaderIcon(
                                                                      ReaderGlyph
                                                                          .more,
                                                                    ),
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                enabled:
                                                                    !_sharingEntries
                                                                        .contains(
                                                                          entry
                                                                              .id,
                                                                        ),
                                                                onSelected: (value) {
                                                                  if (value ==
                                                                      'add') {
                                                                    unawaited(
                                                                      showAddToSetList(
                                                                        context,
                                                                        workspace:
                                                                            sync.workspace,
                                                                        entryId:
                                                                            entry.id,
                                                                        displayPath:
                                                                            entry.relativePath,
                                                                      ),
                                                                    );
                                                                  } else if (value ==
                                                                      'location') {
                                                                    _pathDetails(
                                                                      entry,
                                                                    );
                                                                  } else {
                                                                    unawaited(
                                                                      value ==
                                                                              'share'
                                                                          ? _shareEntry(
                                                                              shareContext,
                                                                              entry,
                                                                            )
                                                                          : value == 'download'
                                                                          ? _download(
                                                                              entry: entry,
                                                                            )
                                                                          : value == 'remove'
                                                                          ? sync.removeOfflineDownload(
                                                                              entry.id,
                                                                            )
                                                                          : sync.selectOffline(
                                                                              OfflineRule(
                                                                                sourceId: sync.sourceIdFor(entry.id)!,
                                                                                entryId: entry.id,
                                                                                selected: false,
                                                                              ),
                                                                            ),
                                                                    );
                                                                  }
                                                                },
                                                                itemBuilder: (_) => [
                                                                  const PopupMenuItem(
                                                                    value:
                                                                        'add',
                                                                    child: Text(
                                                                      '加入曲单',
                                                                    ),
                                                                  ),
                                                                  PopupMenuItem(
                                                                    value:
                                                                        'share',
                                                                    enabled:
                                                                        ready,
                                                                    child: Text(
                                                                      ready
                                                                          ? '分享'
                                                                          : '下载后可分享',
                                                                    ),
                                                                  ),
                                                                  const PopupMenuItem(
                                                                    value: 'location',
                                                                    child: Text(
                                                                      '查看位置',
                                                                    ),
                                                                  ),
                                                                  if (!ready ||
                                                                      pending)
                                                                    PopupMenuItem(
                                                                      value: 'download',
                                                                      child: Text(
                                                                        pending
                                                                            ? '更新下载'
                                                                            : '下载到 iPad',
                                                                      ),
                                                                    ),
                                                                  const PopupMenuItem(
                                                                    value: 'unselect',
                                                                    child: Text(
                                                                      '取消离线选择',
                                                                    ),
                                                                  ),
                                                                  if (ready)
                                                                    const PopupMenuItem(
                                                                      value: 'remove',
                                                                      child:
                                                                          Text(
                                                                            '移除本机下载',
                                                                          ),
                                                                    ),
                                                                ],
                                                              ),
                                                            ),
                                                            onTap: () =>
                                                                unawaited(
                                                                  _open(entry),
                                                                ),
                                                          );
                                                        },
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );

  String get _sourceName =>
      widget.controller.offlineSources
          .where((source) => source.id == _activeSourceId)
          .firstOrNull
          ?.name ??
      '谱库';

  Widget _header(BuildContext headerContext, bool wide, String folder) =>
      SizedBox(
        height: ScoreLayout.headerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ScoreLayout.listMargin,
          ),
          child: Row(
            children: [
              if (!wide) ...[
                LibraryIconButton(
                  glyph: ReaderGlyph.list,
                  label: '打开来源',
                  onPressed: () => Scaffold.of(headerContext).openDrawer(),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: _searchOpen
                    ? DirectorySearchField(
                        controller: _search,
                        focusNode: _searchFocus,
                        onChanged: (text) => setState(() => _query = text),
                      )
                    : wide
                    ? DirectoryBreadcrumbs(
                        rootLabel: _sourceName,
                        currentPath: folder,
                        onNavigate: _selectFolder,
                      )
                    : Text(
                        widget.isHome ? '曲谱库' : '离线谱库',
                        style: ScoreText.title.copyWith(
                          color: ScoreTokens.of(context).ink900,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              LibraryIconButton(
                glyph: _searchOpen ? ReaderGlyph.close : ReaderGlyph.search,
                label: _searchOpen ? '关闭搜索' : '搜索',
                onPressed: _searchOpen ? _closeSearch : _openSearch,
              ),
              const SizedBox(width: 8),
              const ThemeAction(),
              if (widget.openLocalImports != null)
                LibraryIconButton(
                  glyph: ReaderGlyph.folder,
                  label: '本机导入',
                  onPressed: widget.openLocalImports,
                ),
              if (!wide) ...[
                const SizedBox(width: 8),
                LibraryIconButton(
                  glyph: ReaderGlyph.downloadList,
                  label: '曲单',
                  onPressed: _setLists,
                ),
                const SizedBox(width: 8),
                _deviceSummary(compact: true),
              ],
            ],
          ),
        ),
      );

  Widget _deviceSummary({bool compact = false}) {
    final sync = widget.controller;
    final t = ScoreTokens.of(context);
    final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final signing = SigningExpiryChip(
      summaryOnly: true,
      compact: compact,
      pairedDevice: !ios,
      pairedStatus: ios ? null : sync.signingStatus,
      unavailable: ios ? null : sync.signingUnavailable,
      onRefresh: ios ? null : sync.refreshSigningStatus,
      onRead: ios
          ? (value) => sync.reportLocalSigningExpiry(value.expiration)
          : null,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: compact ? 160 : double.infinity,
        minHeight: compact ? ScoreLayout.touchTarget : 0,
      ),
      child: InkWell(
        key: const ValueKey('offline-sync-management'),
        onTap: () => unawaited(_sync()),
        borderRadius: ScoreRadius.controlAll,
        child: Padding(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: ScoreSpace.md)
              : const EdgeInsets.all(ScoreSpace.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              sync.hasSyncActivity
                  ? const LibrarySyncActivityIcon()
                  : ReaderIcon(ReaderGlyph.sync, color: t.pine),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compact)
                      Text(
                        sync.paired ? '电脑 · 已连接' : '连接电脑',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScoreText.body.copyWith(color: t.ink900),
                      ),
                    IgnorePointer(child: signing),
                    if (!compact && sync.hasSyncActivity)
                      Text(
                        _activityLabel(sync),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScoreText.caption.copyWith(color: t.ink500),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notice(String message, {Widget? action, VoidCallback? dismiss}) =>
      Material(
        color: ScoreTokens.of(context).warnBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ScoreText.note,
                ),
              ),
              ?action,
              if (dismiss != null)
                LibraryIconButton(
                  glyph: ReaderGlyph.close,
                  label: '关闭提示',
                  onPressed: dismiss,
                ),
            ],
          ),
        ),
      );

  void _pathDetails(LibraryEntry entry) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(p.posix.basename(entry.relativePath)),
      content: SelectableText(
        '${widget.controller.sourceNameFor(entry.id)} / ${entry.relativePath}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _shareEntry(BuildContext anchor, LibraryEntry entry) async {
    if (!_sharingEntries.add(entry.id)) return;
    setState(() {});
    try {
      final target = widget.controller.locateOffline(entry.id);
      if (target == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请先下载这份曲谱，再分享原文件。')));
        return;
      }
      final workspace = widget.controller.workspace;
      await shareScore(
        anchor,
        filePath: target.filePath,
        fileName: p.posix.basename(target.displayPath),
        validate: target.validateBeforeRead,
        beforeShare: () async {
          if (!workspace.savingAnnotations) await workspace.retryStrokes();
          if (workspace.savingAnnotations || workspace.unsavedCount > 0) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('批注尚未保存，请稍后分享。')));
            }
            return false;
          }
          return true;
        },
        annotationsFor: (number) => workspace.annotationsFor(
          PageKey(
            entryId: target.entryId,
            revisionId: target.revisionId,
            pageNumber: number,
          ),
        ),
      );
    } finally {
      _sharingEntries.remove(entry.id);
      if (mounted) setState(() {});
    }
  }

  void _ensureHierarchy(List<String> folders) {
    final key = (
      folders,
      _activeSourceId,
    );
    if (key != _treeStructure) {
      _treeStructure = key;
      for (final path in folders) {
        if (_knownTreeFolders.add(path) &&
            path.isNotEmpty &&
            _folder != path &&
            !_folder.startsWith('$path/')) {
          _collapsed.add(path);
        }
      }
      _hierarchy = FolderHierarchy(folders);
      _treeRows = null;
    }
  }

  Widget _tree(List<String> folders) {
    _ensureHierarchy(folders);
    final visible = _treeRows ??= _hierarchy!.visibleRows(_collapsed);
    final key = (
      _treeStructure,
      _activeSourceId,
      visible,
      widget.controller.workspace.store.snapshot,
    );
    if (_navEntriesKey != key) {
      _navEntriesKey = key;
      _navEntries = [
        const LibraryNavEntry(LibraryNavKind.group, label: '谱库来源'),
        for (final source in widget.controller.offlineSources) ...[
          LibraryNavEntry(LibraryNavKind.source, value: source),
          if (_activeSourceId == source.id)
            for (final row in visible)
              if (row.path.isNotEmpty)
                LibraryNavEntry(LibraryNavKind.folder, value: row),
        ],
        const LibraryNavEntry(LibraryNavKind.addSource),
        const LibraryNavEntry(LibraryNavKind.group, label: '曲单'),
        for (final list
            in widget.controller.workspace.store.snapshot.activeSetLists)
          LibraryNavEntry(LibraryNavKind.setList, value: list),
        const LibraryNavEntry(LibraryNavKind.newSetList),
        const LibraryNavEntry(LibraryNavKind.refresh),
        if (!widget.isHome) const LibraryNavEntry(LibraryNavKind.returnLibrary),
      ];
    }
    return LibrarySidebar(
      entries: _navEntries,
      device: _deviceSummary(),
      itemBuilder: (context, entry) {
        switch (entry.kind) {
          case LibraryNavKind.group:
            return Padding(
              padding: EdgeInsets.only(
                top: entry.label == '曲单' ? ScoreSpace.lg : 0,
              ),
              child: LibraryGroupLabel(entry.label),
            );
          case LibraryNavKind.source:
            final source = entry.value! as LibrarySourceInfo;
            return LibraryNavigationItem(
              label: source.name,
              selected: !_setListsOpen && source.id == _activeSourceId,
              count:
                  '${widget.controller.folderOfflineStatus(sourceId: source.id).total}',
              onTap: () => _selectSource(source.id),
            );
          case LibraryNavKind.folder:
            final row = entry.value! as FolderTreeRow;
            return _node(row.path, row.depth);
          case LibraryNavKind.addSource:
            return LibraryNavigationItem(
              label: '连接电脑',
              glyph: ReaderGlyph.plus,
              onTap: () => unawaited(_sync()),
            );
          case LibraryNavKind.setList:
            final list = entry.value! as ScoreSetList;
            return LibraryNavigationItem(
              label: list.name,
              glyph: ReaderGlyph.list,
              selected: _setListsOpen && list.id == _setListId,
              count: '${list.activeItems.length}',
              onTap: () => _setLists(initialListId: list.id),
            );
          case LibraryNavKind.newSetList:
            return LibraryNavigationItem(
              label: '新建曲单',
              glyph: ReaderGlyph.plus,
              onTap: () => _setLists(initialCreate: true),
            );
          case LibraryNavKind.refresh:
            return LibraryNavigationItem(
              label: '立即同步',
              glyph: ReaderGlyph.sync,
              onTap: () => unawaited(_refresh()),
            );
          case LibraryNavKind.returnLibrary:
            return LibraryNavigationItem(
              label: '返回谱库',
              glyph: ReaderGlyph.back,
              onTap: () => Navigator.pop(context),
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  Widget _node(String folder, int depth) {
    final children = _hierarchy!.childrenOf(folder);
    final expanded = !_collapsed.contains(folder);
    return LibraryNavigationItem(
      key: ValueKey('offline-folder-$folder'),
      label: p.posix.basename(folder),
      selected: !_setListsOpen && _folder == folder,
      indent: (depth * ScoreLayout.treeIndent).clamp(0, 132),
      onTap: () => _selectFolder(folder),
      trailing: children.isEmpty
          ? null
          : LibraryIconButton(
              touch: true,
              glyph: expanded ? ReaderGlyph.chevronUp : ReaderGlyph.chevronDown,
              label: expanded ? '收起文件夹' : '展开文件夹',
              onPressed: () => setState(() {
                expanded ? _collapsed.add(folder) : _collapsed.remove(folder);
                _treeRows = null;
              }),
            ),
    );
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
              : status.readable == status.total
              ? ScoreFileIconState.ready
              : status.readable == 0
              ? ScoreFileIconState.cloud
              : ScoreFileIconState.partial,
        ),
      ),
    ),
  );
}
