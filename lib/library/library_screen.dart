import '../signing/signing_expiry_chip.dart';
import 'score_path_label.dart';
import 'directory_navigation.dart';
import 'library_widgets.dart';
import 'score_file_icon.dart';
import 'desktop_navigation_history.dart';

import 'package:library_sync/library_sync.dart'
    show PageMetadataKey, CatalogSourceBinding, SyncProtocolException;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
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
import '../reader/add_to_set_list_dialog.dart';
import '../theme/reader_icons.dart';
import 'library_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_screen.dart';
import '../sync/offline_library_screen.dart';
import '../theme/app_theme.dart';
import '../theme/device_layout.dart';
import '../theme/tokens.dart';
import '../sharing/score_share.dart';
import '../importing/external_import_store.dart';
import '../importing/file_import_bridge.dart';
import '../importing/import_screens.dart';
import '../importing/import_annotation_mirror.dart';

const sidebarWidth = ScoreLayout.sidebarWidth;
const dividerWidth = 1.0;

/// Host files never show replica availability badges.
class _HostLibraryIcon extends StatelessWidget {
  const _HostLibraryIcon({required this.path}) : isFolder = false;
  const _HostLibraryIcon.folder() : path = '', isFolder = true;
  final String path;
  final bool isFolder;
  @override
  Widget build(BuildContext context) => isFolder
      ? const ScoreFileIcon.folder(showBadge: false)
      : ScoreFileIcon(path: path, showBadge: false);
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
  bool _setListsOpen = false;
  String? _setListId;
  bool _setListCreate = false;
  int _setListEntry = 0;
  bool _directoryMutation = false;
  DesktopNavigationHistory? _history;
  final Set<String> _collapsedFolders = {};
  final Set<String> _knownTreeFolders = {};
  LibrarySnapshot? _countSnapshot;
  List<String>? _countFolders;
  String? _countSource;
  final Map<String, int> _folderCounts = {};
  List<String>? _treeFolders;
  FolderHierarchy? _hierarchy;
  List<FolderTreeRow>? _treeRows;
  Object? _navEntriesKey;
  List<LibraryNavEntry> _navEntries = const [];
  String? _initializationError;
  ReaderWorkspace? _workspace;
  bool _openingSetList = false;
  Future<ReaderWorkspace>? _workspaceFuture;
  bool _openingReader = false;
  final Set<String> _sharingEntries = {};
  LibrarySnapshot? _setListCatalogSnapshot;
  List<ScoreCatalogEntry> _setListCatalog = const [];
  SyncController? _sync;
  Future<SyncController>? _syncFuture;
  SyncController? _setListSync;
  ExternalImportStore? _imports;
  final _importBridge = FileImportBridge();
  final _incomingImports = <String>[];
  final _offeredImports = <String>{};
  bool _consumeImportsAgain = false;
  bool _consumingImports = false,
      _showingImport = false,
      _importReaderOpen = false;
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
      try {
        final imports = ExternalImportStore(
          Directory(p.join(controller.dataDirectory.path, 'external-imports')),
          copyToNewFile: FileImportBridge.copyToNewFile,
        );
        await imports.initialize();
        if (!mounted) {
          imports.dispose();
          return;
        }
        _imports = imports;
        for (final score in imports.records.where((s) => s.mirrorPending)) {
          final workspace = await _prepareReader();
          await mirrorImportAnnotations(
            workspace,
            DocumentKey(entryId: 'import-${score.id}', revisionId: score.hash),
            DocumentKey(
              entryId: score.catalogEntryId!,
              revisionId: score.catalogRevisionId!,
            ),
          );
          await imports.completeMirror(score.id);
        }
      } catch (failure) {
        debugPrint('IMPORT initialization_failed: $failure');
        if (mounted) _message('本机导入暂时不可用，原稿已保留。');
      }
      await _prepareSync();
      _importBridge.onChanged = _consumeImports;
      _importBridge.start();
      unawaited(_consumeImports());
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
      _setListsOpen,
      _setListId,
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
        _setListsOpen = state.$6;
        _setListId = state.$7;
        _setListCreate = false;
        _setListEntry++;
      });
      _searchFocus.unfocus();
      _directoryMutation = false;
    }, replace: replaceSearch);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _library?.scheduleRescan();
    if (state == AppLifecycleState.paused) {
      // URLSession owns iPad transfers while Flutter is suspended/locked.
      // Explicit user cancellation still pauses the persistent native queue.
      if (defaultTargetPlatform != TargetPlatform.iOS) _sync?.cancel();
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
    _importBridge.dispose();
    _imports?.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_searchKey);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() {
      _searchOpen = true;
      _setListsOpen = false;
      _setListId = null;
    });
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
    try {
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
    } catch (_) {
      if (mounted) _message('无法选择曲谱，请关闭其他文件选择窗口后重试。');
    }
  }

  Future<void> _consumeImports() async {
    if (_imports == null) return;
    if (_consumingImports) {
      _consumeImportsAgain = true;
      return;
    }
    _consumingImports = true;
    try {
      do {
        _consumeImportsAgain = false;
        for (final item in await _importBridge.listPending()) {
          final id = item['id'] as String;
          if (item['error'] != null || item['path'] == null) {
            if (mounted) _message('无法接收 ${item['name'] ?? '文件'}，请检查格式与文件权限。');
            await _importBridge.acknowledge(id);
            continue;
          }
          try {
            final score = await _imports!.receive(
              item['path'] as String,
              name: item['name'] as String?,
              originId: id,
            );
            try {
              await _importBridge.acknowledge(id);
            } catch (failure) {
              debugPrint('IMPORT acknowledgement_failed: $failure');
            }
            if (_offeredImports.add(score.id)) _incomingImports.add(score.id);
          } catch (_) {
            if (mounted) _message('文件接收失败，原文件未改动，可重新打开或分享。');
          }
        }
      } while (_consumeImportsAgain && mounted);
    } catch (failure) {
      debugPrint('IMPORT pending_failed: $failure');
    } finally {
      _consumingImports = false;
    }
    unawaited(_showIncomingImports());
  }

  Future<void> _showIncomingImports() async {
    if (_showingImport || _importReaderOpen || !mounted) return;
    _showingImport = true;
    try {
      while (_incomingImports.isNotEmpty && mounted) {
        final id = _incomingImports.removeAt(0);
        if (_imports?.byId(id) != null) await _openImportedScore(id);
      }
    } finally {
      _showingImport = false;
    }
  }

  List<ImportDestination> get _importDestinations => [
    if (_canProvideLibrary)
      for (final source in _library?.sources ?? <CatalogSourceBinding>[])
        if (source.online)
          ImportDestination(source.name, Directory(source.catalog.rootPath)),
  ];

  Future<(String, String)?> _savedCatalogIdentity(String path) async {
    final library = _library!;
    final managed = library.sources.any(
      (source) => p.isWithin(source.catalog.rootPath, path),
    );
    if (!managed) return null;
    await library.rescan();
    final (_, first) = await library.entryForFilePath(path);
    if (first == null) throw StateError('保存后目录尚未更新');
    await library.ensureReady(first.id);
    final (_, ready) = await library.entryForFilePath(path);
    if (ready == null) throw StateError('保存后曲谱尚未准备');
    return (ready.id, ready.currentRevisionId);
  }

  Future<void> _openImportedScore(String id) async {
    final imports = _imports;
    if (imports == null || imports.byId(id) == null) return;
    final workspace = await _prepareReader();
    final score = imports.byId(id)!;
    final sync = !_canProvideLibrary ? await _prepareSync() : null;
    if (score.saved && score.mirrorPending) {
      try {
        await mirrorImportAnnotations(
          workspace,
          DocumentKey(entryId: 'import-${score.id}', revisionId: score.hash),
          DocumentKey(
            entryId: score.catalogEntryId!,
            revisionId: score.catalogRevisionId!,
          ),
        );
        if (score.remoteTransaction != null) {
          await sync?.syncImportedReaderState();
        }
        await imports.completeMirror(score.id);
      } catch (_) {
        if (mounted) _message('批注暂时无法整理，原稿已保留，请重试。');
        return;
      }
    }
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => ImportReaderScreen(
        store: imports,
        scoreId: id,
        workspace: workspace,
        destinations: _importDestinations,
        allowOtherDirectories: _canProvideLibrary,
        catalogIdentity: _canProvideLibrary ? _savedCatalogIdentity : null,
        computerDestinationProvider: sync == null
            ? null
            : () => [
                for (final source
                    in sync.activeCollection?.index?.sources ?? [])
                  ImportComputerDestination(
                    id: source.id,
                    name: source.name,
                    folders:
                        sync.activeCollection!.index!.folders[source.id] ??
                        const [],
                  ),
              ],
        saveToComputer: sync == null
            ? null
            : (transaction, score, filePath) async {
                try {
                  if (sync.busy) throw const ImportSaveBusy();
                  final receipt = await sync.importScoreToComputer(
                    operationId: transaction.operationId,
                    sourceId: transaction.sourceId,
                    relativeFolder: transaction.relativeFolder,
                    fileName: transaction.fileName,
                    filePath: filePath,
                    hash: score.hash,
                  );
                  final target = sync.locateOffline(receipt.item.entryId);
                  if (target == null) throw StateError('保存的曲谱尚未进入离线谱库');
                  return ImportRemoteResult(
                    entryId: target.entryId,
                    revisionId: target.revisionId,
                    localPath: target.filePath,
                    receipt: Map<String, dynamic>.from(receipt.toJson()),
                  );
                } on SyncProtocolException catch (failure) {
                  if (failure.status == 409 &&
                      failure.code == 'import_destination_exists') {
                    throw const ImportSaveConflict();
                  }
                  rethrow;
                }
              },
        syncImportedReaderState: sync == null
            ? null
            : () async {
                if (sync.busy) throw const ImportSaveBusy();
                await sync.syncImportedReaderState();
              },
      ),
    );
    _importReaderOpen = true;
    try {
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _importReaderOpen = false;
      if (!_showingImport) unawaited(_showIncomingImports());
    }
  }

  Future<void> _openImports() async {
    final imports = _imports;
    if (imports == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImportLibraryScreen(
          store: imports,
          openScore: _openImportedScore,
          openFiles: () => unawaited(_openSingle()),
          initialDrafts: !_canProvideLibrary,
        ),
      ),
    );
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
      final score = await _imports!.receive(path);
      _incomingImports.add(score.id);
      await _showIncomingImports();
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
    _setListsOpen = false;
    _setListId = null;
    _collapsedFolders.removeWhere(
      (path) => folder == path || folder.startsWith('$path/'),
    );
    _treeRows = null;
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
    final savedQuery = _searchOpen ? _search.text : null;
    var opened = false;
    try {
      final library = _library!;
      final workspace = await _prepareReader();
      final target = _locate(entry.id);
      if (!mounted) return;
      if (target == null) {
        _message('曲谱暂不可读，请刷新谱库。');
        return;
      }
      opened = true;
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
      if (mounted && opened && savedQuery != null) {
        setState(() {
          _searchOpen = true;
          _search.text = savedQuery;
        });
        _library?.setQuery(savedQuery);
        _recordDirectory(replaceSearch: true);
      }
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

  Future<void> _openSetLists({
    String? initialListId,
    bool initialCreate = false,
  }) async {
    if (_openingReader) return;
    _openingReader = true;
    try {
      await _prepareReader();
      final offline = !_canProvideLibrary || _library?.rootPath == null;
      final sync = offline ? await _prepareSync() : null;
      if (!mounted) return;
      setState(() {
        _setListSync = sync;
        _setListsOpen = true;
        _setListId = initialListId;
        _setListCreate = initialCreate;
        _setListEntry++;
      });
      _searchFocus.unfocus();
      _recordDirectory();
    } catch (failure, stack) {
      debugPrint('READER workspace_failed: $failure\n$stack');
      if (mounted) _message('批注和曲单数据暂时无法打开。请检查应用数据目录后重试。');
    } finally {
      _openingReader = false;
    }
  }

  void _leaveSetLists() {
    setState(() {
      _setListsOpen = false;
      _setListId = null;
      _setListCreate = false;
    });
    _recordDirectory();
  }

  Widget _embeddedSetLists() {
    final sync = _setListSync;
    return SetListsScreen(
      key: ValueKey(('library-setlists', _setListEntry)),
      workspace: _workspace!,
      embedded: true,
      initialListId: _setListId,
      initialCreate: _setListCreate,
      pageCounts: (sync ?? _sync)?.pageCounts,
      onBack: _leaveSetLists,
      onSelectionChanged: (id) {
        _setListId = id;
        _setListCreate = false;
        _recordDirectory();
        setState(() {});
      },
      locate: sync?.locateOffline ?? _locate,
      targets: sync == null ? _targets : () => sync.offlineTargets,
      catalog: sync == null ? _catalogEntries : () => sync.offlineScoreCatalog,
      prepare: sync == null ? _prepareScores : sync.prepareOfflineScores,
      preparationLabel: sync == null ? '准备本曲单' : '下载本曲单缺少内容',
      preparationNotice: sync == null
          ? '只准备本曲单所需的本机文件。'
          : '需要电脑在线。离线时会记住所选曲目，连接后再准备。',
      loader: sync == null ? _loadLocalTarget : null,
      sourceChanges: sync ?? _library,
    );
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
      await showDeviceSyncPanel(
        context,
        controller: sync,
        openOffline: () => unawaited(_openOffline()),
        scanOnOpen: scan,
        syncOnOpen: syncNow,
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
          builder: (_) => OfflineLibraryScreen(
            controller: sync,
            openLocalImports: _openImports,
          ),
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
        return OfflineLibraryScreen(
          controller: sync,
          isHome: true,
          openLocalImports: _openImports,
        );
      }
      return Scaffold(
        body: Center(
          child: _initializationError == null
              ? const CircularProgressIndicator()
              : Text(_initializationError!),
        ),
      );
    }
    final library = _library;
    final ipad = DeviceLayoutScope.isCompact(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            library?.rootPath != null &&
            constraints.maxWidth >=
                (ipad
                    ? ScoreLayout.ipadSidebarMin
                    : ScoreLayout.windowsSidebarMin);
        return Scaffold(
          drawer: !wide && library?.rootPath != null
              ? Drawer(
                  width: ScoreLayout.drawerWidth,
                  child: SafeArea(child: _sidebar(library!)),
                )
              : null,
          body: SafeArea(
            child: Row(
              children: [
                if (wide && library?.rootPath != null)
                  SizedBox(width: sidebarWidth, child: _sidebar(library!)),
                Expanded(
                  child: _setListsOpen && _workspace != null
                      ? _embeddedSetLists()
                      : Column(
                          children: [
                            Builder(
                              builder: (headerContext) =>
                                  _header(headerContext, library, wide),
                            ),
                            if (!wide &&
                                ipad &&
                                library != null &&
                                library.sources.isNotEmpty)
                              SizedBox(
                                height: ScoreLayout.sourceStripHeight,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: ScoreLayout.listMargin,
                                  ),
                                  itemCount: library.sources.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (_, index) {
                                    final source = library.sources[index];
                                    return Center(
                                      child: TextButton(
                                        onPressed: () =>
                                            _selectSource(library, source.id),
                                        style: TextButton.styleFrom(
                                          backgroundColor:
                                              source.id ==
                                                  library.selectedSourceId
                                              ? ScoreTokens.of(context).pineWash
                                              : ScoreTokens.of(context).paper0,
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
                                            color:
                                                source.id ==
                                                    library.selectedSourceId
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
                              child: library == null
                                  ? Center(
                                      child: _initializationError == null
                                          ? const CircularProgressIndicator()
                                          : Text(_initializationError!),
                                    )
                                  : !library.initialized
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : library.rootPath == null
                                  ? _welcome(library)
                                  : LibraryOutsideTapListener(
                                      enabled: _searchOpen,
                                      onTap: () => scheduleMicrotask(() {
                                        if (mounted &&
                                            _searchOpen &&
                                            (ModalRoute.of(context)
                                                    ?.isCurrent ??
                                                true)) {
                                          _closeSearch();
                                        }
                                      }),
                                      child: _content(library, wide: wide),
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
  }

  void _selectSource(LibraryController library, String id) {
    _setListsOpen = false;
    _setListId = null;
    _directoryMutation = true;
    _search.clear();
    _searchOpen = false;
    _searchFocus.unfocus();
    library.setSource(id);
    _directoryMutation = false;
    _recordDirectory();
  }

  Widget _header(
    BuildContext headerContext,
    LibraryController? library,
    bool wide,
  ) {
    return SizedBox(
      height: ScoreLayout.headerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ScoreLayout.listMargin),
        child: Row(
          children: [
            if (!wide) ...[
              LibraryIconButton(
                glyph: ReaderGlyph.list,
                label: '打开来源',
                onPressed: library?.rootPath == null
                    ? null
                    : () => Scaffold.of(headerContext).openDrawer(),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: _searchOpen
                  ? DirectorySearchField(
                      controller: _search,
                      focusNode: _searchFocus,
                      onChanged: (text) => library?.setQuery(text),
                    )
                  : wide && library?.rootPath != null
                  ? DirectoryBreadcrumbs(
                      rootLabel: library!.selectedSource?.name ?? '谱库',
                      currentPath: library.currentFolder,
                      onNavigate: _folder,
                    )
                  : Text(
                      '曲谱库',
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
            LibraryIconButton(
              glyph: ReaderGlyph.folder,
              label: '本机导入',
              onPressed: _imports == null
                  ? null
                  : () => unawaited(_openImports()),
            ),
            if (!wide) ...[
              const SizedBox(width: 8),
              LibraryIconButton(
                glyph: ReaderGlyph.downloadList,
                label: '曲单',
                onPressed: _openSetLists,
              ),
              const SizedBox(width: 8),
              _deviceSummary(compact: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _deviceSummary({bool compact = false}) {
    final t = ScoreTokens.of(context);
    final sync = _sync;
    final signing = SigningExpiryChip(
      summaryOnly: true,
      pairedDevice: true,
      pairedStatus: sync?.signingStatus,
      unavailable: sync?.signingUnavailable,
      onRefresh: sync?.refreshSigningStatus,
      compact: compact,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: compact ? 160 : double.infinity,
        minHeight: compact ? ScoreLayout.touchTarget : 0,
      ),
      child: InkWell(
        onTap: () => unawaited(_openSync()),
        borderRadius: ScoreRadius.controlAll,
        child: Padding(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: ScoreSpace.md)
              : const EdgeInsets.all(ScoreSpace.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              sync?.hasSyncActivity == true
                  ? const LibrarySyncActivityIcon()
                  : ReaderIcon(ReaderGlyph.sync, color: t.pine),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compact)
                      Text(
                        sync?.signingStatus.value != null
                            ? 'iPad · 已配对'
                            : sync?.serving == true
                            ? 'iPad · 等待连接'
                            : '连接我的 iPad',
                        style: ScoreText.body.copyWith(color: t.ink900),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    IgnorePointer(child: signing),
                    if (!compact && sync?.hasSyncActivity == true)
                      Text(
                        '同步中',
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

  Widget _welcome(LibraryController library) => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Padding(
          padding: const EdgeInsets.all(ScoreSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReaderIcon(
                ReaderGlyph.book,
                size: ScoreSpace.huge,
                color: ScoreTokens.of(context).pine,
              ),
              const SizedBox(height: ScoreSpace.xl),
              Text(
                _canProvideLibrary ? '你的文件夹，就是你的谱库' : '把整个谱库带在身边',
                style: ScoreText.display,
              ),
              const SizedBox(height: ScoreSpace.md),
              Text(
                _canProvideLibrary
                    ? '选择存放 PDF 或图片的文件夹。'
                    : '连接电脑更新目录，再选择要带走的文件夹或曲谱。\n已下载的曲谱、批注和曲单可断网使用。',
                textAlign: TextAlign.center,
                style: ScoreText.body.copyWith(
                  color: ScoreTokens.of(context).ink500,
                ),
              ),
              const SizedBox(height: ScoreSpace.xl),
              FilledButton.icon(
                onPressed: _selectRoot,
                icon: const ReaderIcon(ReaderGlyph.folder),
                label: const Text('添加谱库文件夹'),
              ),
              if (library.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: ScoreSpace.lg),
                  child: Text(
                    library.error!,
                    style: TextStyle(color: ScoreTokens.of(context).dangerInk),
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
      for (final path in folders) {
        if (_knownTreeFolders.add(path) &&
            path.isNotEmpty &&
            library.currentFolder != path &&
            !library.currentFolder.startsWith('$path/')) {
          _collapsedFolders.add(path);
        }
      }
      _hierarchy = FolderHierarchy(folders);
      _treeRows = null;
    }
    final visible = _treeRows ??= _hierarchy!.visibleRows(_collapsedFolders);
    final key = (
      library.snapshot,
      library.selectedSourceId,
      visible,
      _workspace?.store.snapshot,
    );
    if (_navEntriesKey != key) {
      _navEntriesKey = key;
      _navEntries = [
        const LibraryNavEntry(LibraryNavKind.group, label: '谱库来源'),
        for (final source in library.sources) ...[
          LibraryNavEntry(LibraryNavKind.source, value: source),
          if (source.id == library.selectedSourceId)
            for (final row in visible)
              if (row.path.isNotEmpty)
                LibraryNavEntry(LibraryNavKind.folder, value: row),
        ],
        const LibraryNavEntry(LibraryNavKind.addSource),
        const LibraryNavEntry(LibraryNavKind.group, label: '曲单'),
        for (final list
            in _workspace?.store.snapshot.activeSetLists ?? <ScoreSetList>[])
          LibraryNavEntry(LibraryNavKind.setList, value: list),
        const LibraryNavEntry(LibraryNavKind.newSetList),
        const LibraryNavEntry(LibraryNavKind.operations),
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
            final source = entry.value! as CatalogSourceBinding;
            return LibraryNavigationItem(
              key: ValueKey('source-${source.id}'),
              label: source.name,
              selected: !_setListsOpen && source.id == library.selectedSourceId,
              count: '${source.catalog.snapshot.availableEntries.length}',
              onTap: () => _selectSource(library, source.id),
            );
          case LibraryNavKind.folder:
            final row = entry.value! as FolderTreeRow;
            return _folderNode(library, row.path, row.depth);
          case LibraryNavKind.addSource:
            return LibraryNavigationItem(
              label: '添加来源',
              glyph: ReaderGlyph.plus,
              onTap: () => unawaited(_selectRoot()),
            );
          case LibraryNavKind.setList:
            final list = entry.value! as ScoreSetList;
            return LibraryNavigationItem(
              label: list.name,
              glyph: ReaderGlyph.list,
              selected: _setListsOpen && list.id == _setListId,
              count: '${list.activeItems.length}',
              onTap: () => unawaited(_openSetLists(initialListId: list.id)),
            );
          case LibraryNavKind.newSetList:
            return LibraryNavigationItem(
              label: '新建曲单',
              glyph: ReaderGlyph.plus,
              onTap: () => unawaited(_openSetLists(initialCreate: true)),
            );
          case LibraryNavKind.operations:
            return PopupMenuButton<String>(
              tooltip: '曲库操作',
              icon: const ReaderIcon(ReaderGlyph.more),
              style: libraryIconButtonStyle(context),
              constraints: const BoxConstraints.tightFor(
                width: ScoreLayout.menuWidth,
              ),
              onSelected: (value) {
                switch (value) {
                  case 'single':
                    unawaited(_openSingle());
                  case 'refresh':
                    unawaited(library.rescan());
                  case 'verify':
                    unawaited(library.rescan(verifyAll: true));
                  case 'offline':
                    unawaited(_openOffline());
                  case 'imports':
                    unawaited(_openImports());
                  case 'layout':
                    DeviceLayoutScope.maybeOf(context)?.toggle();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'single', child: Text('打开单份曲谱')),
                const PopupMenuItem(value: 'imports', child: Text('本机导入与暂存')),
                PopupMenuItem(
                  value: 'refresh',
                  enabled: !library.scanning,
                  child: const Text('刷新谱库'),
                ),
                PopupMenuItem(
                  value: 'verify',
                  enabled: !library.scanning,
                  child: const Text('完整校验此谱库内容'),
                ),
                const PopupMenuItem(value: 'offline', child: Text('离线谱库')),
                if (defaultTargetPlatform == TargetPlatform.windows)
                  const PopupMenuItem(
                    value: 'layout',
                    child: Text('切换 iPad 预览'),
                  ),
              ],
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  Widget _folderNode(LibraryController library, String folder, int depth) {
    final children = _hierarchy!.childrenOf(folder);
    final expanded = !_collapsedFolders.contains(folder);
    return LibraryNavigationItem(
      key: ValueKey('folder-$folder'),
      label: p.posix.basename(folder),
      selected: !_setListsOpen && library.currentFolder == folder,
      indent: mathIndent(depth),
      onTap: () => _folder(folder),
      trailing: children.isEmpty
          ? null
          : LibraryIconButton(
              touch: true,
              glyph: expanded ? ReaderGlyph.chevronUp : ReaderGlyph.chevronDown,
              label: expanded ? '收起文件夹' : '展开文件夹',
              onPressed: () => setState(() {
                expanded
                    ? _collapsedFolders.add(folder)
                    : _collapsedFolders.remove(folder);
                _treeRows = null;
              }),
            ),
    );
  }

  double mathIndent(int depth) =>
      (depth * ScoreLayout.treeIndent).clamp(0, 132);

  Widget _content(LibraryController library, {required bool wide}) => Column(
    children: [
      if (!wide)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ScoreLayout.listMargin,
          ),
          child: DirectoryBreadcrumbs(
            rootLabel: library.selectedSource?.name ?? '谱库',
            currentPath: library.currentFolder,
            onNavigate: _folder,
          ),
        ),
      if (library.searching)
        LibrarySearchContext(
          count: library.visibleEntries.length,
          withinFolder: library.searchCurrentFolder,
          onScopeChanged: library.setSearchScope,
        ),
      if (library.scanning) const LinearProgressIndicator(minHeight: 2),
      if ((_workspace?.unsavedCount ?? 0) > 0)
        _notice(
          '${_workspace!.unsavedCount} 项批注未保存',
          () => unawaited(_workspace!.retryStrokes()),
        ),
      if (library.error != null)
        _notice(library.error!, () => _details(library)),
      if (library.watchWarning != null)
        _notice(library.watchWarning!, () => _details(library)),
      if (library.storageWarnings.isNotEmpty ||
          (library.lastScan?.issues.isNotEmpty ?? false) ||
          (library.lastScan?.ambiguities.isNotEmpty ?? false))
        _notice(
          '${library.lastScan?.issues.length ?? 0} 项读取提示 · ${library.lastScan?.ambiguities.length ?? 0} 项关联待确认${library.storageWarnings.isEmpty ? '' : ' · 索引恢复提示'}',
          () => _details(library),
        ),
      Expanded(child: _entries(library)),
    ],
  );

  Widget _notice(String text, VoidCallback action) => Material(
    color: Theme.of(context).colorScheme.tertiaryContainer,
    child: InkWell(
      onTap: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ScoreSpace.xl,
          vertical: ScoreSpace.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ScoreText.note,
              ),
            ),
            const ReaderIcon(ReaderGlyph.chevronRight),
          ],
        ),
      ),
    ),
  );

  Widget _entries(LibraryController library) {
    final entries = library.visibleEntries;
    final subfolders = library.searching ? <String>[] : library.listing.folders;
    final snapshot = library.selectedSource?.catalog.snapshot;
    final folders = library.folders;
    if (!identical(snapshot, _countSnapshot) ||
        !identical(folders, _countFolders) ||
        library.selectedSourceId != _countSource) {
      _countSnapshot = snapshot;
      _countFolders = folders;
      _countSource = library.selectedSourceId;
      _folderCounts.clear();
      for (final folder in folders) {
        final parent = p.posix.dirname(folder);
        _folderCounts[parent] = (_folderCounts[parent] ?? 0) + 1;
      }
      for (final entry in snapshot?.availableEntries ?? <LibraryEntry>[]) {
        final parent = p.posix.dirname(entry.relativePath);
        _folderCounts[parent] = (_folderCounts[parent] ?? 0) + 1;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ScoreLayout.listMargin),
      child: Column(
        children: [
          const LibraryColumnHeader(),
          Expanded(
            child: entries.isEmpty && subfolders.isEmpty
                ? Center(
                    child: Text(
                      library.scanning
                          ? '正在扫描文件夹…'
                          : library.searching
                          ? '未找到曲谱'
                          : '这个文件夹里还没有曲谱',
                      style: ScoreText.body.copyWith(
                        color: ScoreTokens.of(context).ink500,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: PageStorageKey((
                      library.selectedSourceId,
                      library.currentFolder,
                      library.query,
                    )),
                    padding: EdgeInsets.zero,
                    itemCount: subfolders.length + entries.length,
                    itemBuilder: (context, index) {
                      if (index < subfolders.length) {
                        final folder = subfolders[index];
                        return LibraryFileRow(
                          key: ValueKey('library-folder-$folder'),
                          leading: const _HostLibraryIcon.folder(),
                          name: p.posix.basename(folder),
                          subtitle: '${_folderCounts[folder] ?? 0} 项',
                          action: LibraryIconButton(
                            glyph: ReaderGlyph.more,
                            label: '文件夹选项',
                            onPressed: () => _folder(folder),
                          ),
                          onTap: () => _folder(folder),
                        );
                      }
                      final entry = entries[index - subfolders.length];
                      return LibraryFileRow(
                        key: ValueKey('library-file-${entry.id}'),
                        leading: _HostLibraryIcon(path: entry.relativePath),
                        name: p.posix.basename(entry.relativePath),
                        query: library.searching ? library.query : '',
                        subtitle: library.searching
                            ? '${library.sourceNameFor(entry)} / ${scoreParentFolder(entry.relativePath)}'
                            : null,
                        metadata: LibraryFileMetadata(
                          entryId: entry.id,
                          revisionId: entry.currentRevisionId,
                          path: entry.relativePath,
                          service: _sync?.pageCounts,
                        ),
                        action: Builder(
                          builder: (shareContext) => PopupMenuButton<String>(
                            style: libraryIconButtonStyle(context),
                            constraints: const BoxConstraints.tightFor(
                              width: ScoreLayout.menuWidth,
                            ),
                            tooltip: '曲谱选项',
                            icon: const ReaderIcon(ReaderGlyph.more),
                            padding: EdgeInsets.zero,
                            enabled: !_sharingEntries.contains(entry.id),
                            onSelected: (value) {
                              if (value == 'add') {
                                unawaited(_addEntryToSetList(entry));
                              } else if (value == 'share') {
                                unawaited(
                                  _shareEntry(shareContext, library, entry),
                                );
                              } else if (Platform.isWindows) {
                                unawaited(_revealFile(library, entry));
                              } else {
                                _pathDetails(entry);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'add',
                                child: Text('加入曲单'),
                              ),
                              const PopupMenuItem(
                                value: 'share',
                                child: Text('分享'),
                              ),
                              PopupMenuItem(
                                value: 'location',
                                child: Text(
                                  Platform.isWindows ? '打开文件所在目录' : '查看完整路径',
                                ),
                              ),
                            ],
                          ),
                        ),
                        onTap: () => unawaited(_openEntry(entry)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _addEntryToSetList(LibraryEntry entry) async {
    if (_openingSetList) return;
    _openingSetList = true;
    try {
      final workspace = await _prepareReader();
      if (!mounted) return;
      await showAddToSetList(
        context,
        workspace: workspace,
        entryId: entry.id,
        displayPath: entry.relativePath,
      );
    } catch (_) {
      if (mounted) _message('无法打开曲单，请重试。');
    } finally {
      _openingSetList = false;
    }
  }

  Future<void> _shareEntry(
    BuildContext anchor,
    LibraryController library,
    LibraryEntry entry,
  ) async {
    if (!_sharingEntries.add(entry.id)) return;
    setState(() {});
    try {
      final workspace = await _prepareReader();
      if (!anchor.mounted) return;
      await shareScore(
        anchor,
        filePath: library.absolutePathFor(entry),
        fileName: p.posix.basename(entry.relativePath),
        validate: () =>
            library.validateForRead(entry.id, entry.currentRevisionId),
        beforeShare: () async {
          if (!workspace.savingAnnotations) await workspace.retryStrokes();
          if (workspace.savingAnnotations || workspace.unsavedCount > 0) {
            if (mounted) _message('批注尚未保存，请稍后分享。');
            return false;
          }
          return true;
        },
        annotationsFor: (number) => workspace.annotationsFor(
          PageKey(
            entryId: entry.id,
            revisionId: entry.currentRevisionId,
            pageNumber: number,
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message('无法读取批注资料，请检查应用存储后重试。');
    } finally {
      _sharingEntries.remove(entry.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _revealFile(
    LibraryController library,
    LibraryEntry entry,
  ) async {
    try {
      final path = library.absolutePathFor(entry);
      if (!await File(path).exists()) {
        if (mounted) _message('文件已移动或不存在，请刷新谱库后重试。');
        return;
      }
      await Process.start(
        'explorer.exe',
        ['/select,', path],
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (mounted) _message('无法打开文件所在目录，请重试。');
    }
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
