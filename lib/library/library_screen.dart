import '../signing/signing_expiry_chip.dart';
import 'score_path_label.dart';
import 'directory_navigation.dart';
import 'page_count_service.dart';
import 'desktop_navigation_history.dart';

import 'package:library_sync/library_sync.dart' show PageMetadataKey;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reader_state/reader_state.dart';

import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/reader_workspace.dart';
import '../reader/set_lists_screen.dart';
import 'library_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_screen.dart';
import '../sync/offline_library_screen.dart';

Future<String> _hashExternalFile(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class _ExternalHashRequest {
  const _ExternalHashRequest(this.path);
  final String path;
  Future<String> call() => _hashExternalFile(path);
}

/// The host library shows local file types without offline download status.
class _HostLibraryIcon extends StatelessWidget {
  const _HostLibraryIcon({required this.path}) : isFolder = false;
  const _HostLibraryIcon.folder() : path = '', isFolder = true;

  final String path;
  final bool isFolder;

  @override
  Widget build(BuildContext context) {
    final image = const {
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
    }.contains(p.extension(path).toLowerCase());
    return SizedBox(
      width: 44,
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 8, 7),
        child: Icon(
          isFolder
              ? Icons.folder_outlined
              : image
              ? Icons.image_outlined
              : Icons.description_outlined,
          size: 32,
          color: const Color(0xff53645c),
        ),
      ),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.controller,
    this.dataDirectory,
    this.readerWorkspace,
    this.initialPath,
  });
  final LibraryController? controller;
  final Directory? dataDirectory;
  final ReaderWorkspace? readerWorkspace;
  final String? initialPath;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  LibraryController? _library;
  final TextEditingController _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  bool _directoryMutation = false;
  DesktopNavigationHistory? _history;
  final Set<String> _collapsedFolders = {};
  List<String>? _treeFolders;
  FolderHierarchy? _hierarchy;
  List<FolderTreeRow>? _treeRows;
  String? _initializationError;
  ReaderWorkspace? _workspace;
  Future<ReaderWorkspace>? _workspaceFuture;
  bool _openingReader = false;
  LibrarySnapshot? _setListCatalogSnapshot;
  List<ScoreCatalogEntry> _setListCatalog = const [];
  SyncController? _sync;
  Future<SyncController>? _syncFuture;
  bool get _canProvideLibrary =>
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_searchKey);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final controller =
          widget.controller ??
          LibraryController(
            dataDirectory:
                widget.dataDirectory ??
                Directory(
                  p.join(
                    (await getApplicationSupportDirectory()).path,
                    'library',
                  ),
                ),
          );
      if (!mounted) {
        if (widget.controller == null) controller.dispose();
        return;
      }
      _library = controller;
      controller.addListener(_changed);
      setState(() {});
      if (!controller.initialized) await controller.initialize();
      await _prepareSync();
      if (widget.initialPath != null && mounted) {
        unawaited(_openPath(widget.initialPath!));
      }
    } catch (failure) {
      debugPrint('LIBRARY data_directory_failed: $failure');
      if (mounted) {
        setState(() => _initializationError = '应用存储不可用，请检查空间与权限。');
      }
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
      _recordDirectory(replaceSearch: _searchOpen);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _history = DesktopHistoryScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordDirectory();
    });
  }

  void _recordDirectory({bool replaceSearch = false}) {
    final library = _library, route = ModalRoute.of(context);
    if (_directoryMutation ||
        library == null ||
        route == null ||
        !route.isCurrent) {
      return;
    }
    final state = (
      library.selectedSourceId,
      library.currentFolder,
      library.query,
      library.searchCurrentFolder,
      _searchOpen,
    );
    _history?.directory(route, state, () {
      if (!mounted) return;
      _directoryMutation = true;
      library.setSource(state.$1);
      library.setFolder(state.$2);
      library.setSearchScope(state.$4);
      library.setQuery(state.$3);
      setState(() {
        _searchOpen = state.$5;
        _search.text = state.$3;
      });
      _searchFocus.unfocus();
      _directoryMutation = false;
    }, replace: replaceSearch);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _library?.scheduleRescan();
    if (state == AppLifecycleState.paused) {
      _sync?.cancel();
      unawaited(_workspace?.flushPositions());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _library?.removeListener(_changed);
    if (widget.controller == null) _library?.dispose();
    _workspace?.removeListener(_changed);
    _sync?.removeListener(_changed);
    if (widget.readerWorkspace == null) _workspace?.dispose();
    _sync?.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_searchKey);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    _recordDirectory();
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
    _library?.setQuery('');
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

  Future<void> _selectRoot() async {
    try {
      final root = await getDirectoryPath(confirmButtonText: '添加这个谱库');
      if (root != null && mounted) {
        _search.clear();
        _collapsedFolders.clear();
        await _library?.addSource(root);
      }
    } catch (failure) {
      debugPrint('LIBRARY picker_failed: $failure');
      if (mounted) _message('无法选择谱库，请关闭其他文件选择窗口后重试。');
    }
  }

  Future<void> _openSingle() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '曲谱',
          extensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
          uniformTypeIdentifiers: ['com.adobe.pdf', 'public.image'],
        ),
      ],
    );
    if (file != null && mounted) {
      await _openPath(file.path);
    }
  }

  Future<void> _openPath(String path) async {
    final library = _library;
    if (library == null || _openingReader) return;
    try {
      final (registered, entry) = await library.entryForFilePath(path);
      if (!mounted) return;
      if (entry != null) {
        await _openEntry(entry);
        return;
      }
      if (registered) {
        library.scheduleRescan();
        _message('目录正在更新，请刷新后重试。');
        return;
      }
      _openingReader = true;
      final workspace = await _prepareReader();
      final actual = p.normalize(await File(path).resolveSymbolicLinks());
      final stat = await File(actual).stat();
      final contentHash = await Isolate.run(_ExternalHashRequest(actual).call);
      final after = await File(actual).stat();
      if (after.size != stat.size || after.modified != stat.modified) {
        throw const FileSystemException('Selected file changed.');
      }
      final revision = sha256
          .convert(
            utf8.encode(
              '$actual/${stat.size}/${stat.modified.microsecondsSinceEpoch}',
            ),
          )
          .toString();
      final target = ScoreTarget(
        entryId: 'external-view',
        revisionId: revision,
        filePath: actual,
        contentHash: contentHash,
        displayPath: actual,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LibraryReaderScreen(
            workspace: workspace,
            initialTarget: target,
            locate: (id) => id == target.entryId ? target : null,
            allowAnnotations: false,
          ),
        ),
      );
    } catch (failure) {
      if (mounted) _message('无法打开曲谱，请重试。');
      debugPrint('READER selected_path_failed: $failure');
    } finally {
      _openingReader = false;
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _folder(String folder) {
    _directoryMutation = true;
    _searchOpen = false;
    _searchFocus.unfocus();
    _search.clear();
    _library!.setQuery('');
    _library!.setFolder(folder);
    _directoryMutation = false;
    _recordDirectory();
  }

  Future<void> _openEntry(LibraryEntry entry) async {
    if (_openingReader) return;
    _openingReader = true;
    try {
      final library = _library!;
      final workspace = await _prepareReader();
      final target = _locate(entry.id);
      if (!mounted) return;
      if (target == null) {
        _message('曲谱暂不可读，请刷新谱库。');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LibraryReaderScreen(
            workspace: workspace,
            locate: _locate,
            initialTarget: target,
            sourceChanges: library,
            loader: _loadLocalTarget,
          ),
        ),
      );
    } catch (failure, stack) {
      debugPrint('READER workspace_failed: $failure\n$stack');
      if (mounted) _message('无法打开批注数据，请检查应用存储。');
    } finally {
      _openingReader = false;
    }
  }

  ScoreTarget? _locate(String id) {
    final library = _library;
    if (library?.snapshot == null) return null;
    final entry = library!.snapshot!.entryById(id);
    if (entry != null && entry.status == EntryStatus.available) {
      return ScoreTarget(
        entryId: entry.id,
        revisionId: entry.currentRevisionId,
        filePath: library.absolutePathFor(entry),
        displayPath: library.absolutePathFor(entry),
        parentFolderLabel:
            '${library.sourceNameFor(entry)} · ${scoreParentFolder(entry.relativePath)}',
        contentHash: entry.currentRevision.contentHash,
        validateBeforeRead: () =>
            library.validateForRead(entry.id, entry.currentRevisionId),
      );
    }
    return null;
  }

  Future<LoadedScore> _loadLocalTarget(ScoreTarget target) async {
    await _library!.ensureReady(target.entryId);
    final resolved = _locate(target.entryId);
    if (resolved == null || resolved.revisionId != target.revisionId) {
      throw StateError('Source changed while preparing the selected score.');
    }
    final loaded = await loadScore(
      resolved,
      cacheDirectory: p.join(
        p.dirname(_workspace!.store.statePath),
        'reading-cache',
      ),
    );
    _sync?.pageCounts.remember(
      PageMetadataKey(resolved.entryId, resolved.revisionId),
      loaded.pageCount,
    );
    return loaded;
  }

  List<ScoreTarget> _targets() => [
    for (final entry
        in _library?.snapshot?.availableEntries ?? <LibraryEntry>[])
      if (_locate(entry.id) case final ScoreTarget target) target,
  ];

  List<ScoreCatalogEntry> _catalogEntries() {
    final library = _library!, snapshot = library.snapshot;
    if (identical(snapshot, _setListCatalogSnapshot)) return _setListCatalog;
    _setListCatalogSnapshot = snapshot;
    final online = {
      for (final source in library.sources) source.id: source.online,
    };
    _setListCatalog = List.unmodifiable([
      for (final entry in snapshot?.entries ?? <LibraryEntry>[])
        ScoreCatalogEntry(
          entryId: entry.id,
          displayPath: entry.relativePath,
          sourceId: library.sourceIdFor(entry),
          sourceName: library.sourceNameFor(entry),
          parentFolderLabel:
              '${library.sourceNameFor(entry)} · ${scoreParentFolder(entry.relativePath)}',
          state: entry.status == EntryStatus.missing
              ? ScoreContentState.missing
              : online[library.sourceIdFor(entry)] == false
              ? ScoreContentState.sourceOffline
              : entry.availability == ContentAvailability.ready
              ? ScoreContentState.ready
              : ScoreContentState.unprepared,
          bytes: entry.currentRevision.size,
        ),
    ]);
    return _setListCatalog;
  }

  Future<String> _prepareScores(Set<String> ids) async {
    var ready = 0, unavailable = 0;
    for (final id in ids) {
      try {
        await _library!.ensureReady(id);
        ready++;
      } catch (_) {
        unavailable++;
      }
    }
    return unavailable == 0
        ? '本次所选曲谱已准备。'
        : '$ready 份已准备，$unavailable 份尚不可读；曲单内容已保留。';
  }

  Future<ReaderWorkspace> _prepareReader() => _workspaceFuture ??= (() async {
    try {
      final workspace =
          widget.readerWorkspace ??
          ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: p.join(
                _library!.dataDirectory.path,
                'reader-state.json',
              ),
            ),
          );
      if (!mounted) {
        if (widget.readerWorkspace == null) workspace.dispose();
        throw StateError('Library disposed');
      }
      _workspace = workspace;
      workspace.addListener(_changed);
      setState(() {});
      return workspace;
    } catch (_) {
      _workspaceFuture = null;
      rethrow;
    }
  })();

  Future<void> _openSetLists() async {
    if (_openingReader) return;
    _openingReader = true;
    try {
      final workspace = await _prepareReader();
      final offline = !_canProvideLibrary || _library?.rootPath == null;
      final sync = offline ? await _prepareSync() : null;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SetListsScreen(
            workspace: workspace,
            locate: sync?.locateOffline ?? _locate,
            targets: sync == null ? _targets : () => sync.offlineTargets,
            catalog: sync == null
                ? _catalogEntries
                : () => sync.offlineScoreCatalog,
            prepare: sync == null ? _prepareScores : sync.prepareOfflineScores,
            preparationLabel: sync == null ? '准备本曲单' : '下载本曲单缺少内容',
            preparationNotice: sync == null
                ? '只准备本曲单所需的本机文件。'
                : '需要电脑在线。离线时会记住所选曲目，连接后再准备。',
            loader: sync == null ? _loadLocalTarget : null,
            sourceChanges: sync ?? _library,
          ),
        ),
      );
    } catch (failure, stack) {
      debugPrint('READER workspace_failed: $failure\n$stack');
      if (mounted) _message('批注和曲单数据暂时无法打开。请检查应用数据目录后重试。');
    } finally {
      _openingReader = false;
    }
  }

  Future<SyncController> _prepareSync() => _syncFuture ??= (() async {
    try {
      final workspace = await _prepareReader();
      final sync = SyncController(library: _library!, workspace: workspace);
      await sync.initialize();
      if (!mounted) {
        sync.dispose();
        throw StateError('Library disposed');
      }
      _sync = sync;
      sync.addListener(_changed);
      setState(() {});
      return sync;
    } catch (_) {
      _syncFuture = null;
      rethrow;
    }
  })();

  Future<void> _openSync({bool scan = false, bool syncNow = false}) async {
    try {
      final sync = await _prepareSync();
      if (!mounted) return;
      if (_canProvideLibrary) unawaited(sync.connectMyIpad());
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SyncScreen(
            controller: sync,
            openOffline: () => unawaited(_openOffline()),
            scanOnOpen: scan,
            syncOnOpen: syncNow,
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message('同步资料暂时无法打开，请检查应用数据目录。');
    }
  }

  Future<void> _openOffline() async {
    try {
      final sync = await _prepareSync();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => OfflineLibraryScreen(controller: sync),
        ),
      );
    } catch (_) {
      if (mounted) _message('离线谱库暂时无法打开，请检查应用数据目录。');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canProvideLibrary) {
      final sync = _sync;
      if (sync != null) {
        return OfflineLibraryScreen(controller: sync, isHome: true);
      }
      return Scaffold(
        appBar: AppBar(title: const Text('曲谱库')),
        body: Center(
          child: _initializationError == null
              ? const CircularProgressIndicator()
              : Text(_initializationError!),
        ),
      );
    }
    final library = _library;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        return Scaffold(
          appBar: AppBar(
            title: wide
                ? Row(
                    children: [
                      const SizedBox(
                        width: 261,
                        child: Text(
                          '曲谱库',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (_searchOpen)
                        Expanded(
                          child: DirectorySearchField(
                            controller: _search,
                            focusNode: _searchFocus,
                            onChanged: (text) => library?.setQuery(text),
                          ),
                        ),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: _searchOpen
                            ? DirectorySearchField(
                                controller: _search,
                                focusNode: _searchFocus,
                                onChanged: (text) => library?.setQuery(text),
                              )
                            : const Text(
                                '曲谱库',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                      ),
                    ],
                  ),
            backgroundColor: const Color(0xfffaf9f5),
            actions: [
              IconButton(
                tooltip: _searchOpen ? '关闭搜索' : '搜索',
                icon: Icon(_searchOpen ? Icons.close : Icons.search),
                onPressed: _searchOpen ? _closeSearch : _openSearch,
              ),
              IconButton(
                tooltip: '刷新谱库',
                icon: const Icon(Icons.refresh),
                onPressed: library?.rootPath == null || library!.scanning
                    ? null
                    : () => unawaited(library.rescan()),
              ),
              if (wide && !_searchOpen) ...[
                IconButton(
                  tooltip: '无线同步 / 连接电脑',
                  icon: const Icon(Icons.wifi),
                  onPressed: library?.initialized == true
                      ? () => unawaited(_openSync())
                      : null,
                ),
                IconButton(
                  tooltip: '曲单',
                  icon: const Icon(Icons.queue_music),
                  onPressed: library?.initialized == true
                      ? _openSetLists
                      : null,
                ),
                IconButton(
                  tooltip: '打开单份曲谱',
                  onPressed: _openSingle,
                  icon: const Icon(Icons.description_outlined),
                ),
              ],
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  switch (value) {
                    case 'add':
                      unawaited(_selectRoot());
                    case 'single':
                      unawaited(_openSingle());
                    case 'sync':
                      unawaited(_openSync());
                    case 'offline':
                      unawaited(_openOffline());
                    case 'lists':
                      _openSetLists();
                    case 'verify':
                      unawaited(library?.rescan(verifyAll: true));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'add', child: Text('添加谱库文件夹')),
                  const PopupMenuItem(value: 'single', child: Text('打开单份曲谱')),
                  const PopupMenuItem(value: 'sync', child: Text('连接我的 iPad')),
                  const PopupMenuItem(value: 'offline', child: Text('离线谱库')),
                  const PopupMenuItem(value: 'lists', child: Text('曲单')),
                  PopupMenuItem(
                    value: 'verify',
                    enabled: library?.rootPath != null && !library!.scanning,
                    child: const Text('完整校验此谱库内容'),
                  ),
                ],
              ),
            ],
          ),
          drawer: !wide && library?.rootPath != null
              ? Drawer(child: SafeArea(child: _sidebar(library!)))
              : null,
          body: library == null
              ? Center(
                  child: _initializationError == null
                      ? const CircularProgressIndicator()
                      : Text(_initializationError!),
                )
              : !library.initialized
              ? const Center(child: CircularProgressIndicator())
              : library.rootPath == null
              ? _welcome(library)
              : Row(
                  children: [
                    if (wide) SizedBox(width: 260, child: _sidebar(library)),
                    if (wide) const VerticalDivider(width: 1),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _searchOpen ? _closeSearch : null,
                        child: _content(library),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _welcome(LibraryController library) => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.library_music_outlined,
                size: 64,
                color: Color(0xff236459),
              ),
              const SizedBox(height: 24),
              Text(
                _canProvideLibrary ? '你的文件夹，就是你的谱库' : '把整个谱库带在身边',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                _canProvideLibrary
                    ? '选择存放 PDF 或图片的文件夹。'
                    : '连接电脑更新目录，再选择要带走的文件夹或曲谱。\n已下载的曲谱、批注和曲单可断网使用。',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.8, color: Color(0xff65736b)),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _selectRoot,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('添加谱库文件夹'),
              ),
              if (library.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    library.error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _sidebar(LibraryController library) {
    final folders = library.folders;
    if (!identical(folders, _treeFolders)) {
      _treeFolders = folders;
      _hierarchy = FolderHierarchy(folders);
      _treeRows = null;
    }
    final visible = _treeRows ??= _hierarchy!.visibleRows(_collapsedFolders);
    final rows = [
      for (final source in library.sources) ...[
        (source, null as FolderTreeRow?),
        if (source.id == library.selectedSourceId)
          for (final row in visible) (source, row),
      ],
    ];
    return Material(
      color: const Color(0xfff6f5ef),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '文件夹',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  '${library.selectedSourceCount} 份曲谱 · ${library.folders.length - 1} 个文件夹',
                  style: const TextStyle(
                    color: Color(0xff65736b),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const PageStorageKey('library-folder-tree'),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final (source, row) = rows[index];
                if (row != null) {
                  return _folderNode(library, row.path, row.depth);
                }
                return ListTile(
                  key: ValueKey('source-${source.id}'),
                  leading: const _HostLibraryIcon.folder(),
                  selected:
                      source.id == library.selectedSourceId &&
                      library.currentFolder.isEmpty,
                  title: Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: source.online ? null : const Text('文件夹暂未连接'),
                  onTap: () {
                    _directoryMutation = true;
                    _search.clear();
                    _searchOpen = false;
                    library.setSource(source.id);
                    _directoryMutation = false;
                    _recordDirectory();
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message:
                      library.selectedSource?.catalog.rootPath ??
                      library.rootPath!,
                  child: Text(
                    library.selectedSource?.name ??
                        p.basename(library.rootPath!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff65736b),
                    ),
                  ),
                ),
                if (defaultTargetPlatform == TargetPlatform.windows) ...[
                  const SizedBox(height: 12),
                  SigningExpiryChip(
                    pairedDevice: true,
                    pairedStatus: _sync?.signingStatus,
                    unavailable: _sync?.signingUnavailable,
                    onRefresh: _sync?.refreshSigningStatus,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _parent(String folder) {
    final index = folder.lastIndexOf('/');
    return index < 0 ? '' : folder.substring(0, index);
  }

  Widget _folderNode(LibraryController library, String folder, int depth) {
    final children = _hierarchy!.childrenOf(folder);
    final expanded = !_collapsedFolders.contains(folder);
    final selected = library.currentFolder == folder;
    return Padding(
      key: ValueKey('folder-$folder'),
      padding: EdgeInsets.only(left: mathIndent(depth)),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: const Color(0xffdfe8df),
        leading: const _HostLibraryIcon.folder(),
        title: Tooltip(
          message: folder.isEmpty ? library.rootPath! : folder,
          child: Text(
            folder.isEmpty
                ? p.basename(library.rootPath!)
                : p.posix.basename(folder),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: children.isEmpty
            ? null
            : IconButton(
                tooltip: expanded ? '收起文件夹' : '展开文件夹',
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  expanded
                      ? _collapsedFolders.add(folder)
                      : _collapsedFolders.remove(folder);
                  _treeRows = null;
                }),
              ),
        onTap: () => _folder(folder),
      ),
    );
  }

  double mathIndent(int depth) => (depth * 12.0).clamp(0, 132);

  Widget _content(LibraryController library) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: DirectoryParentButton(
                currentPath: library.currentFolder,
                parentLabel: _parent(library.currentFolder).isEmpty
                    ? library.selectedSource?.name ?? '谱库'
                    : p.posix.basename(_parent(library.currentFolder)),
                rootLabel: library.selectedSource?.name ?? '谱库',
                onPressed: library.currentFolder.isEmpty
                    ? null
                    : () => _folder(_parent(library.currentFolder)),
              ),
            ),
            if (library.searching) ...[
              const Text('当前文件夹及子文件夹', style: TextStyle(fontSize: 12)),
              Checkbox(
                value: library.searchCurrentFolder,
                onChanged: (value) => library.setSearchScope(value ?? false),
              ),
            ],
          ],
        ),
      ),
      if (library.scanning) const LinearProgressIndicator(minHeight: 2),
      if ((_workspace?.unsavedCount ?? 0) > 0)
        _notice(
          '${_workspace!.unsavedCount} 项批注未保存',
          Icons.edit_outlined,
          () => unawaited(_workspace!.retryStrokes()),
        ),
      if (library.error != null)
        _notice(library.error!, Icons.error_outline, () => _details(library)),
      if (library.watchWarning != null)
        _notice(
          library.watchWarning!,
          Icons.info_outline,
          () => _details(library),
        ),
      if (library.storageWarnings.isNotEmpty ||
          (library.lastScan?.issues.isNotEmpty ?? false) ||
          (library.lastScan?.ambiguities.isNotEmpty ?? false))
        _notice(
          '${library.lastScan?.issues.length ?? 0} 项读取提示 · ${library.lastScan?.ambiguities.length ?? 0} 项关联待确认${library.storageWarnings.isEmpty ? '' : ' · 索引恢复提示'}',
          Icons.info_outline,
          () => _details(library),
        ),
      Expanded(child: _entries(library)),
    ],
  );

  Widget _notice(String text, IconData icon, VoidCallback action) => Material(
    color: const Color(0xffffedcf),
    child: InkWell(
      onTap: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    ),
  );

  Widget _entries(LibraryController library) {
    final entries = library.visibleEntries;
    final subfolders = library.searching ? <String>[] : library.listing.folders;
    if (entries.isEmpty && subfolders.isEmpty) {
      return Center(
        child: Text(
          library.scanning
              ? '正在扫描文件夹…'
              : library.searching
              ? '没有找到匹配的曲谱'
              : '这个文件夹里还没有曲谱',
          style: const TextStyle(color: Color(0xff65736b)),
        ),
      );
    }
    return ListView.separated(
      key: PageStorageKey((
        library.selectedSourceId,
        library.currentFolder,
        library.query,
      )),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: subfolders.length + entries.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 56, color: Color(0xffdfe4df)),
      itemBuilder: (context, index) {
        if (index < subfolders.length) {
          final folder = subfolders[index];
          return ListTile(
            leading: const _HostLibraryIcon.folder(),
            title: Text(p.posix.basename(folder)),
            subtitle: Text(folder, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _folder(folder),
          );
        }
        final entry = entries[index - subfolders.length];
        return ListTile(
          minTileHeight: 72,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 0,
          ),
          leading: _HostLibraryIcon(path: entry.relativePath),
          title: Text(
            p.posix.basenameWithoutExtension(entry.relativePath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Tooltip(
            message:
                '${library.sourceNameFor(entry)} · ${scoreParentFolder(entry.relativePath)}',
            child: Text(
              '${library.sourceNameFor(entry)} · ${scoreParentFolder(entry.relativePath)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xff65736b)),
            ),
          ),
          trailing: ScoreFileTrailing(
            metadata: ScoreFileMetadata(
              key: ValueKey((entry.id, entry.currentRevisionId)),
              entryId: entry.id,
              revisionId: entry.currentRevisionId,
              path: entry.relativePath,
              service: _sync?.pageCounts,
            ),
            menuAction: IconButton(
              tooltip: '查看完整路径',
              icon: const Icon(Icons.info_outline, size: 19),
              onPressed: () => _pathDetails(entry),
            ),
          ),
          onTap: () => unawaited(_openEntry(entry)),
        );
      },
    );
  }

  void _pathDetails(LibraryEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(p.posix.basename(entry.relativePath)),
      content: SelectableText(_library!.absolutePathFor(entry)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  void _details(LibraryController library) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('谱库更新提示'),
      content: SizedBox(
        width: 650,
        height: 380,
        child: SingleChildScrollView(
          child: SelectableText(
            [
              if (library.error != null) library.error!,
              if (library.watchWarning != null) library.watchWarning!,
              if (library.storageWarnings.isNotEmpty)
                '上次索引文件无法完整读取，已从备份恢复。最近一次索引变化可能需要重新扫描确认；原谱未被更改。',
              for (final issue in library.lastScan?.issues ?? <ScanIssue>[])
                '${issue.relativePath.isEmpty ? '谱库根目录' : issue.relativePath}：${_issueMessage(issue.stage)}',
              for (final ambiguity
                  in library.lastScan?.ambiguities ?? <MoveAmbiguity>[])
                '存在相同内容的多个位置，已保留独立条目，未自动转移批注。缺失关联 ${ambiguity.missingEntryIds.length} 项，新增 ${ambiguity.newEntryIds.length} 项。',
            ].join('\n\n'),
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
  );

  String _issueMessage(ScanIssueStage stage) => switch (stage) {
    ScanIssueStage.deferred => '文件尚未下载，请先从云盘下载到本机后刷新。',
    ScanIssueStage.link => '此位置是文件夹链接，已跳过，以免读取谱库之外的资料。',
    ScanIssueStage.enumeration => '暂时无法浏览此文件夹，已保留上次索引。请检查连接或权限后刷新。',
    ScanIssueStage.metadata ||
    ScanIssueStage.content => '文件暂时无法读取，请检查是否完整、是否已下载，再刷新。',
    ScanIssueStage.identity => '无法确认文件关联，已保守保留条目。',
  };
}
