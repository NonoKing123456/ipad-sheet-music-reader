import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;

import '../library/library_controller.dart';
import '../library/score_path_label.dart';
import '../library/page_count_service.dart';
import '../reader/reader_session.dart';
import '../reader/reader_workspace.dart';
import 'pairing_qr.dart';
import 'ios_background_transfer.dart';

enum SyncPhase {
  idle,
  pairing,
  transferring,
  merging,
  verifying,
  complete,
  partial,
  cancelled,
  failed,
}

String _newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
String _rootKey(String root) {
  final normalized = p.normalize(p.absolute(root));
  return sha256
      .convert(
        utf8.encode(Platform.isWindows ? normalized.toLowerCase() : normalized),
      )
      .toString();
}

/// Binds a running listener to one root, while resolving its latest catalog.
class _LiveLibrarySource implements LibrarySource {
  _LiveLibrarySource(this.library, this.root, this.libraryId);
  final LibraryController library;
  final String root;
  final String libraryId;
  CatalogLibrarySource get _current {
    if (!library.legacySourceEnabled) throw LibrarySourceNotReady();
    final catalog = library.catalogForSync;
    if (library.rootPath != root || catalog == null) {
      throw StateError('Source changed.');
    }
    return CatalogLibrarySource(catalog: catalog, libraryId: libraryId);
  }

  @override
  Future<SyncManifest> manifest() => _current.manifest();
  @override
  Future<Stream<List<int>>> openObject(String entryId, String revisionId) =>
      _current.openObject(entryId, revisionId);
}

class _OfflineEntryList extends ListBase<LibraryEntry> {
  _OfflineEntryList(this.view, this.ids);
  final ReplicaCollectionView view;
  final List<String> ids;
  @override
  int get length => ids.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only directory view');
  @override
  LibraryEntry operator [](int index) => view.entryForDisplay(ids[index])!;
  @override
  void operator []=(int index, LibraryEntry value) =>
      throw UnsupportedError('Read-only directory view');
}

/// App-private orchestration. The protocol and domain stores own durable data.
class _SigningReadRequest {
  const _SigningReadRequest(
    this.statusDirectory,
    this.serverDirectory,
    this.serverId,
  );
  final String statusDirectory, serverDirectory, serverId;
  Future<(Set<String>, SigningStatusReceipt?)> call() async {
    final peers = await SyncServer.authenticatedPeerIdsAt(serverDirectory);
    return (
      peers,
      await SigningStatusStore.readAuthorized(statusDirectory, serverId, peers),
    );
  }
}

class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController({
    required this.library,
    required this.workspace,
    this.ioTimeout = const Duration(seconds: 30),
    this.bindAddress,
    this.signingDirectoryWatch,
  }) {
    library.addListener(_libraryChanged);
    workspace.addListener(_workspaceChanged);
  }
  final LibraryController library;
  final ReaderWorkspace workspace;
  final Duration ioTimeout;

  /// Tests may restrict the listener to loopback; production binds IPv4 LAN.
  final InternetAddress? bindAddress;
  final Stream<FileSystemEvent> Function(String)? signingDirectoryWatch;
  Directory? _canonicalDataDirectory;
  Directory get directory => Directory(
    p.join((_canonicalDataDirectory ?? library.dataDirectory).path, 'sync'),
  );
  File get _settingsFile => File(p.join(directory.path, 'settings.json'));
  Map<String, dynamic> _settings = {'version': 1, 'roots': <String, dynamic>{}};
  SyncServer? _server;
  SyncClient? _client;
  IosBackgroundTransfer? _backgroundTransfer;
  bool _backgroundObserver = false;
  int backgroundPendingObjects = 0,
      backgroundStagedObjects = 0,
      backgroundFailedObjects = 0,
      backgroundPausedObjects = 0;
  bool backgroundImporting = false;
  bool backgroundStorageBlocked = false;
  bool _backgroundRecoveryPending = false;
  bool get hasSyncActivity => busy || backgroundPendingObjects > 0;
  Future<void> _refreshBackgroundActivity() async {
    final transfer = _backgroundTransfer, client = _client;
    if (transfer == null || client == null || _disposed) return;
    try {
      final activity = await transfer.activity(
        client.backgroundTransferNamespace,
      );
      if (_disposed || !identical(client, _client)) return;
      backgroundPendingObjects = activity['pending'] as int? ?? 0;
      backgroundStagedObjects = activity['staged'] as int? ?? 0;
      backgroundFailedObjects = activity['failed'] as int? ?? 0;
      backgroundPausedObjects = activity['paused'] as int? ?? 0;
      backgroundStorageBlocked = activity['storageBlocked'] == true;
      _changed();
    } catch (_) {
      /* Import/sync reports any protected-storage failure. */
    }
  }

  Future<void> _backgroundChanged() async {
    await _refreshBackgroundActivity();
    if (backgroundStagedObjects == 0) return;
    if (busy) {
      _backgroundRecoveryPending = true;
    } else {
      await _recoverBackgroundDownloads();
    }
  }

  void _configureBackgroundClient() {
    if (!Platform.isIOS || _client == null) return;
    _backgroundTransfer?.dispose();
    final transfer = IosBackgroundTransfer();
    _backgroundTransfer = transfer;
    _client!.backgroundTransfer = transfer;
    transfer.onChanged = () => unawaited(_backgroundChanged());
    if (!_backgroundObserver) {
      WidgetsBinding.instance.addObserver(this);
      _backgroundObserver = true;
    }
  }

  Future<void> _recoverBackgroundDownloads() async {
    if (_disposed ||
        !initialized ||
        busy ||
        collection == null ||
        _client == null) {
      return;
    }
    busy = true;
    backgroundImporting = true;
    try {
      final count = await _client!.recoverBackgroundCollection(collection!);
      if (count > 0 && !_disposed) {
        message = '后台下载的曲谱已校验并保存，可离线阅读。';
        _tick();
      }
    } catch (_) {
      if (!_disposed) message = '后台曲谱尚未导入，请检查空间后重试同步。';
    } finally {
      busy = false;
      backgroundImporting = false;
      await _refreshBackgroundActivity();
      if (!_disposed) _changed();
    }
  }

  late final pageCounts = PageCountService(
    cacheDirectory: p.join(directory.path, 'page-counts'),
    resolve: (key) {
      final local = library.pageCountFile(key);
      if (local != null) return local;
      final target = locateOffline(key.entryId);
      if (target == null || target.revisionId != key.revisionId) return null;
      return PageCountFile(target.filePath, p.dirname(target.filePath));
    },
    remote: (keys) async => await _client?.pageMetadata(keys) ?? {},
  );
  final signingStatus = ValueNotifier<SigningStatusReceipt?>(null);
  final signingUnavailable = ValueNotifier<bool>(false);
  SigningStatusStore? _signingStore;
  int _signingAuthEpoch = 0;
  SigningDeviceStatus? _lastLocalSigning, _pendingSigning;
  int _signingSequence = 0;
  bool _sendingSigning = false;
  int _signingRetries = 0;
  DateTime? _signingRetryAt;
  StreamSubscription<FileSystemEvent>? _signingFileWatch, _signingPeerWatch;
  String? _signingPeerWatchPath;
  String? _signingActualPeerWatchPath;
  Object? _signingFileWatchToken, _signingPeerWatchToken;
  bool _signingFileWatchDead = false, _signingPeerWatchDead = false;
  Timer? _signingReloadTimer;
  Future<void>? _signingReadTask;
  bool _signingReadPending = false, _signingObserver = false;
  bool _signingForeground = true, _signingProjecting = false;
  bool _signingAuthInvalidated = true;

  String? get _currentSigningServer {
    final root = library.rootPath;
    final value = root == null
        ? null
        : (_settings['roots'] as Map)[_rootKey(root)];
    return value == null
        ? null
        : Map<String, dynamic>.from(value as Map)['id'] as String;
  }

  Future<void> _loadSigningStatus() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    if (!_signingObserver) {
      _signingObserver = true;
      _signingForeground =
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      WidgetsBinding.instance.addObserver(this);
    }
    try {
      final store = await SigningStatusStore.open(
        p.join(directory.path, 'signing-status'),
      );
      if (_disposed) {
        await store.close();
        return;
      }
      _signingStore = store;
      store.onChanged = () {
        if (!_disposed &&
            _signingForeground &&
            !_signingProjecting &&
            !_signingAuthInvalidated) {
          final latest = store.latest;
          if (latest == null || latest.serverId == _currentSigningServer) {
            signingStatus.value = latest;
          }
        }
      };
    } catch (_) {
      // Another running instance may own the writer lease. Read its committed
      // snapshot through the same current-server/authentication boundary.
    }
    await refreshSigningStatus();
  }

  Future<void> _refreshSigningAuthorization() =>
      refreshSigningStatus(invalidate: true);

  Future<void> refreshSigningStatus({
    bool invalidate = false,
    bool retryWatch = true,
  }) {
    if (_disposed || defaultTargetPlatform != TargetPlatform.windows) {
      return Future.value();
    }
    if (invalidate) {
      _signingAuthEpoch++;
      _signingAuthInvalidated = true;
      signingStatus.value = null;
    }
    if (retryWatch) {
      _signingFileWatchDead = false;
      _signingPeerWatchDead = false;
    }
    _signingReadPending = true;
    if (!_signingForeground) return Future.value();
    return _signingReadTask ??= _drainSigningReads().whenComplete(() {
      _signingReadTask = null;
      if (_signingReadPending && _signingForeground && !_disposed) {
        scheduleMicrotask(
          () => unawaited(refreshSigningStatus(retryWatch: false)),
        );
      }
    });
  }

  Future<void> _drainSigningReads() async {
    while (_signingReadPending && _signingForeground && !_disposed) {
      _signingReadPending = false;
      final epoch = ++_signingAuthEpoch;
      final root = library.rootPath, serverId = _currentSigningServer;
      try {
        await _bindSigningWatches(serverId, epoch);
        if (_disposed || epoch != _signingAuthEpoch || !_signingForeground) {
          continue;
        }
        if (_signingFileWatchDead || _signingPeerWatchDead) {
          signingStatus.value = null;
          signingUnavailable.value = true;
          continue;
        }
        if (serverId == null) {
          _signingAuthInvalidated = false;
          signingStatus.value = null;
          signingUnavailable.value = false;
          continue;
        }
        final request = _SigningReadRequest(
          p.join(directory.path, 'signing-status'),
          p.join(directory.path, 'servers', serverId),
          serverId,
        );
        final result = await Isolate.run(request.call);
        if (_disposed ||
            epoch != _signingAuthEpoch ||
            !_signingForeground ||
            library.rootPath != root ||
            _currentSigningServer != serverId) {
          continue;
        }
        final store = _signingStore;
        _signingAuthInvalidated = false;
        if (store == null) {
          signingStatus.value = result.$2;
        } else {
          _signingProjecting = true;
          try {
            store.selectServer(serverId);
            store.setAuthenticatedPeers(serverId, result.$1);
          } finally {
            _signingProjecting = false;
          }
          signingStatus.value = store.latest;
        }
        signingUnavailable.value = false;
      } catch (_) {
        if (!_disposed && epoch == _signingAuthEpoch && _signingForeground) {
          _signingAuthInvalidated = true;
          signingStatus.value = null;
          signingUnavailable.value = true;
        }
      }
    }
  }

  void _signingFileChanged({bool auth = false}) {
    if (_disposed || !_signingForeground) return;
    if (auth) {
      _signingAuthEpoch++;
      _signingAuthInvalidated = true;
      signingStatus.value = null;
    }
    _signingReloadTimer?.cancel();
    _signingReloadTimer = Timer(
      const Duration(milliseconds: 80),
      () => unawaited(refreshSigningStatus(retryWatch: false)),
    );
  }

  void _signingWatchEnded(Object token, {bool peer = false}) {
    if (_disposed ||
        !identical(
          token,
          peer ? _signingPeerWatchToken : _signingFileWatchToken,
        )) {
      return;
    }
    final old = peer ? _signingPeerWatch : _signingFileWatch;
    if (peer) {
      _signingPeerWatch = null;
      _signingPeerWatchToken = null;
      _signingPeerWatchPath = null;
      _signingActualPeerWatchPath = null;
      _signingPeerWatchDead = true;
    } else {
      _signingFileWatch = null;
      _signingFileWatchToken = null;
      _signingFileWatchDead = true;
    }
    unawaited(old?.cancel());
    _signingAuthEpoch++;
    _signingAuthInvalidated = true;
    signingStatus.value = null;
    signingUnavailable.value = true;
    // Recovery is an explicit refresh/resume, never an error-driven poll loop.
  }

  Future<void> _bindSigningWatches(String? serverId, int epoch) async {
    final statusRoot = p.join(directory.path, 'signing-status');
    if (!_signingFileWatchDead &&
        _signingFileWatch == null &&
        await Directory(statusRoot).exists()) {
      if (_disposed || epoch != _signingAuthEpoch || !_signingForeground) {
        return;
      }
      final token = Object();
      _signingFileWatchToken = token;
      _signingFileWatch =
          (signingDirectoryWatch?.call(statusRoot) ??
                  Directory(statusRoot).watch())
              .listen(
                (event) {
                  if (!identical(token, _signingFileWatchToken)) return;
                  if (p.basename(event.path).startsWith('status.json')) {
                    _signingFileChanged();
                  }
                },
                onError: (Object _) => _signingWatchEnded(token),
                onDone: () => _signingWatchEnded(token),
              );
    }
    final desired = serverId == null
        ? null
        : p.join(directory.path, 'servers', serverId);
    var watched = desired;
    while (watched != null &&
        !await Directory(watched).exists() &&
        p.isWithin(directory.path, watched)) {
      watched = p.dirname(watched);
    }
    if (_signingPeerWatchPath == desired &&
        _signingActualPeerWatchPath == watched &&
        _signingPeerWatch != null) {
      return;
    }
    final old = _signingPeerWatch;
    _signingPeerWatch = null;
    _signingPeerWatchPath = null;
    _signingActualPeerWatchPath = null;
    _signingPeerWatchToken = null;
    await old?.cancel();
    if (_signingPeerWatchDead ||
        desired == null ||
        watched == null ||
        _disposed ||
        epoch != _signingAuthEpoch ||
        !_signingForeground) {
      return;
    }
    if (!await Directory(watched).exists() ||
        _disposed ||
        epoch != _signingAuthEpoch ||
        !_signingForeground) {
      return;
    }
    _signingPeerWatchPath = desired;
    _signingActualPeerWatchPath = watched;
    final token = Object();
    _signingPeerWatchToken = token;
    _signingPeerWatch =
        (signingDirectoryWatch?.call(watched) ?? Directory(watched).watch())
            .listen(
              (event) {
                if (!identical(token, _signingPeerWatchToken)) return;
                if (_currentSigningServer != serverId) return;
                if (p.equals(event.path, desired) ||
                    (event.isDirectory && p.isWithin(event.path, desired)) ||
                    (p.equals(p.dirname(event.path), desired) &&
                        p.basename(event.path).startsWith('peers.json'))) {
                  _signingFileChanged(auth: true);
                }
              },
              onError: (Object _) => _signingWatchEnded(token, peer: true),
              onDone: () => _signingWatchEnded(token, peer: true),
            );
  }

  Future<void> _stopSigningWatches() async {
    _signingReloadTimer?.cancel();
    final status = _signingFileWatch, peers = _signingPeerWatch;
    _signingFileWatch = null;
    _signingPeerWatch = null;
    _signingPeerWatchPath = null;
    _signingActualPeerWatchPath = null;
    _signingFileWatchToken = null;
    _signingPeerWatchToken = null;
    await Future.wait([
      if (status != null) status.cancel(),
      if (peers != null) peers.cancel(),
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_backgroundObserver && state == AppLifecycleState.resumed) {
      unawaited(_backgroundChanged());
    }
    if (!_signingObserver) return;
    _signingForeground = state == AppLifecycleState.resumed;
    if (_signingForeground) {
      unawaited(refreshSigningStatus(invalidate: true));
    } else {
      _signingAuthEpoch++;
      _signingReadPending = true;
      unawaited(_stopSigningWatches());
    }
  }

  void reportLocalSigningExpiry(DateTime? expiration) {
    _lastLocalSigning = SigningDeviceStatus(expiration?.toUtc());
    _retrySigningReport();
  }

  void _retrySigningReport() {
    if (_disposed || _lastLocalSigning == null) return;
    _pendingSigning = _lastLocalSigning;
    _signingSequence++;
    _signingRetries = 3;
    _signingRetryAt = null;
    unawaited(_sendSigningReports());
  }

  Future<void> _sendSigningReports() async {
    if (_sendingSigning || _disposed) return;
    _sendingSigning = true;
    try {
      while (!_disposed && _client != null && _pendingSigning != null) {
        final client = _client!,
            report = _pendingSigning!,
            sequence = _signingSequence;
        try {
          await client.reportSigningStatus(report);
          if (identical(client, _client) && sequence == _signingSequence) {
            _pendingSigning = null;
            _signingRetryAt = null;
            _signingRetries = 0;
          }
        } catch (_) {
          if (identical(client, _client) && sequence == _signingSequence) {
            if (_signingRetries > 0) {
              _signingRetryAt = DateTime.now().add(
                Duration(seconds: 2 << (3 - _signingRetries)),
              );
            }
            break;
          }
        }
      }
    } finally {
      _sendingSigning = false;
    }
  }

  SyncCancellation? _cancellation;
  String? _serverRoot;
  bool _disposed = false;
  bool _serverBusy = false;
  bool _preparingConnection = false;
  String? _autoStartAttemptedRoot;
  String? _lastSelectedRoot;
  bool initialized = false;
  bool busy = false;
  Timer? _timer;
  int _seenReaderGeneration = -1;
  int _received = 0;
  int _receivedBeforeRun = 0;
  int processedObjects = 0;
  int? totalObjects;
  bool committingLibrary = false;
  ReplicaLibraryView? replica;
  ReplicaCollectionView? collection;
  Future<void>? _syncTask;
  ReplicaCollectionView? get activeCollection =>
      collection?.index == null ? null : collection;
  LibrarySnapshot? get offlineSnapshot =>
      activeCollection?.snapshot ?? replica?.snapshot;
  List<LibrarySourceInfo> get offlineSources =>
      collection?.index?.sources ??
      (replica?.manifest == null
          ? []
          : const [LibrarySourceInfo('legacy', '原谱库', online: false)]);
  LibrarySnapshot? _scoreCatalogSnapshot;
  Object? _scoreCatalogToken;
  final _scoreCatalog = <String, ScoreCatalogEntry>{};
  List<ScoreCatalogEntry> _scoreCatalogValues = const [];
  final _offlineByFolder = <(String, String), List<LibraryEntry>>{};
  final _offlineSearchText = <String, String>{};
  List<LibraryEntry> _offlineMissing = const [];
  (LibrarySnapshot?, String?, String, String, bool)? _offlineSearchKey;
  List<LibraryEntry> _offlineSearchResults = const [];
  (CollectionDirectoryIndex, String?, String, String, bool)?
  _directorySearchKey;
  List<String> _directorySearchIds = const [];
  void _indexScoreCatalog() {
    final selected = activeCollection;
    final snapshot = selected == null ? offlineSnapshot : null;
    final token = selected == null
        ? snapshot
        : (selected, selected.index, selected.contentRevision);
    if (token == _scoreCatalogToken) return;
    _scoreCatalogToken = token;
    _scoreCatalogSnapshot = snapshot;
    _scoreCatalog.clear();
    final names = {for (final source in offlineSources) source.id: source.name};
    final online = {
      for (final source in offlineSources) source.id: source.online,
    };
    if (selected != null) {
      for (final item in selected.currentItems) {
        final old = selected.readableItemFor(item.entryId);
        final readable = old != null && selected.isReady(old);
        final state = item.missing
            ? ScoreContentState.missing
            : !readable
            ? online[item.sourceId] == false
                  ? ScoreContentState.sourceOffline
                  : ScoreContentState.notDownloaded
            : old.revisionId != item.revisionId
            ? ScoreContentState.readableOld
            : ScoreContentState.ready;
        final name = names[item.sourceId] ?? '谱库';
        _scoreCatalog[item.entryId] = ScoreCatalogEntry(
          entryId: item.entryId,
          displayPath: item.relativePath,
          parentFolderLabel: '$name · ${scoreParentFolder(item.relativePath)}',
          state: state,
          sourceId: item.sourceId,
          sourceName: name,
          bytes: item.length,
        );
      }
    } else if (snapshot != null) {
      for (final entry in snapshot.entries) {
        _scoreCatalog[entry.id] = ScoreCatalogEntry(
          entryId: entry.id,
          displayPath: entry.relativePath,
          sourceId: 'legacy',
          sourceName: names['legacy'] ?? '谱库',
          parentFolderLabel:
              '${names['legacy'] ?? '谱库'} · ${scoreParentFolder(entry.relativePath)}',
          state: entry.status == EntryStatus.missing
              ? ScoreContentState.missing
              : entry.availability == ContentAvailability.ready
              ? ScoreContentState.ready
              : ScoreContentState.notDownloaded,
          bytes: entry.currentRevision.size,
        );
      }
    }
    _scoreCatalogValues = List.unmodifiable(_scoreCatalog.values);
    _offlineByFolder.clear();
    _offlineSearchText.clear();
    _offlineMissing = List.unmodifiable(
      snapshot?.entries.where((entry) => entry.status == EntryStatus.missing) ??
          <LibraryEntry>[],
    );
    for (final entry in snapshot?.availableEntries ?? <LibraryEntry>[]) {
      final metadata = _scoreCatalog[entry.id];
      final folder = p.posix.dirname(entry.relativePath);
      (_offlineByFolder[(
                metadata?.sourceId ?? 'legacy',
                folder == '.' ? '' : folder,
              )] ??=
              [])
          .add(entry);
      _offlineSearchText[entry.id] =
          '${metadata?.sourceName ?? ''}/${entry.relativePath}'.toLowerCase();
    }
  }

  List<LibraryEntry> get offlineMissingEntries {
    final selected = activeCollection;
    if (selected != null) {
      return _OfflineEntryList(selected, selected.directory.missingIds);
    }
    _indexScoreCatalog();
    return _offlineMissing;
  }

  List<LibraryEntry> offlineEntries({
    required String? sourceId,
    required String folder,
    required String query,
    required bool withinFolder,
  }) {
    final selected = activeCollection;
    if (selected != null) {
      final directory = selected.directory;
      List<String> ids;
      if (query.trim().isEmpty) {
        ids = directory.idsInFolder(sourceId, folder);
      } else {
        final key = (directory, sourceId, folder, query, withinFolder);
        if (key != _directorySearchKey) {
          final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
          _directorySearchIds = [
            for (final id in directory.availableIds)
              if ((!withinFolder ||
                      (directory.sourceForId(id) == sourceId &&
                          folderContains(
                            folder,
                            selected.itemFor(id)!.relativePath,
                          ))) &&
                  terms.every(directory.searchText[id]!.contains))
                id,
          ];
          _directorySearchKey = key;
        }
        ids = _directorySearchIds;
      }
      return _OfflineEntryList(selected, ids);
    }
    _indexScoreCatalog();
    if (query.trim().isEmpty) {
      return _offlineByFolder[(sourceId, folder)] ?? const [];
    }
    final key = (_scoreCatalogSnapshot, sourceId, folder, query, withinFolder);
    if (key == _offlineSearchKey) return _offlineSearchResults;
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    _offlineSearchKey = key;
    return _offlineSearchResults = [
      for (final entry in offlineSnapshot?.availableEntries ?? <LibraryEntry>[])
        if ((!withinFolder ||
                (_scoreCatalog[entry.id]?.sourceId == sourceId &&
                    folderContains(folder, entry.relativePath))) &&
            terms.every(_offlineSearchText[entry.id]!.contains))
          entry,
    ];
  }

  List<ScoreCatalogEntry> get offlineScoreCatalog {
    _indexScoreCatalog();
    return _scoreCatalogValues;
  }

  String sourceNameFor(String entryId) {
    final selected = activeCollection;
    if (selected != null) {
      return selected.directory.sourceNames[selected.directory.sourceForId(
            entryId,
          )] ??
          '谱库';
    }
    _indexScoreCatalog();
    return _scoreCatalog[entryId]?.sourceName ?? '谱库';
  }

  String? sourceIdFor(String entryId) {
    final selected = activeCollection;
    if (selected != null) return selected.directory.sourceForId(entryId);
    _indexScoreCatalog();
    return _scoreCatalog[entryId]?.sourceId;
  }

  bool hasPendingVersion(String id) {
    final selected = activeCollection;
    if (selected != null) {
      final current = selected.itemFor(id), old = selected.readableItemFor(id);
      return current != null &&
          old != null &&
          selected.isReady(old) &&
          old.revisionId != current.revisionId;
    }
    _indexScoreCatalog();
    return _scoreCatalog[id]?.state == ScoreContentState.readableOld;
  }

  Future<String> prepareOfflineScores(Set<String> entryIds) async {
    if (busy) return '正在更新，请完成后再准备曲单。';
    if (hasUnsavedEdits) return '请先保存或重试未保存的批注，再准备曲单。';
    final selected = entryIds
        .map(_catalogEntry)
        .whereType<ScoreCatalogEntry>()
        .where((entry) => entry.needsPreparation && entry.sourceId != null)
        .toList();
    if (selected.isEmpty) return '没有需要下载的曲谱；源缺失的文件需先在电脑恢复。';
    await collection!.selectMany([
      for (final entry in selected)
        OfflineRule(
          sourceId: entry.sourceId!,
          entryId: entry.entryId,
          selected: true,
        ),
    ]);
    _changed();
    if (!paired) return '已记住所选曲目，尚未下载。请连接电脑后再准备本曲单。';
    final scope = entryIds
        .where(
          (id) =>
              _catalogEntry(id)?.needsPreparation == true ||
              _catalogEntry(id)?.readable != true,
        )
        .toSet();
    await synchronize(onlyEntryIds: scope);
    return message ?? '准备尚未完成，请检查电脑连接后重试。';
  }

  ScoreCatalogEntry? _catalogEntry(String id) {
    final selected = activeCollection;
    if (selected == null) {
      _indexScoreCatalog();
      return _scoreCatalog[id];
    }
    final item = selected.itemFor(id);
    if (item == null) return null;
    final old = selected.readableItemFor(id);
    final readable = old != null && selected.isReady(old);
    final online = selected.index!.sources
        .firstWhere((s) => s.id == item.sourceId)
        .online;
    final state = item.missing
        ? ScoreContentState.missing
        : !readable
        ? (online
              ? ScoreContentState.notDownloaded
              : ScoreContentState.sourceOffline)
        : old.revisionId != item.revisionId
        ? ScoreContentState.readableOld
        : ScoreContentState.ready;
    final name = selected.directory.sourceNames[item.sourceId] ?? '谱库';
    return ScoreCatalogEntry(
      entryId: id,
      displayPath: item.relativePath,
      parentFolderLabel: '$name · ${scoreParentFolder(item.relativePath)}',
      state: state,
      sourceId: item.sourceId,
      sourceName: name,
      bytes: item.length,
    );
  }

  LibrarySnapshot? _downloadFolderSnapshot;
  final _downloadFolders = <(String, String), OfflineFolderStatus>{};

  /// One in-memory ancestor summary per snapshot; every row reads this map.
  OfflineFolderStatus folderOfflineStatus({
    required String sourceId,
    String folder = '',
  }) {
    final collection = activeCollection;
    if (collection != null) {
      final counts = collection.directory.folderStatus(sourceId, folder);
      return OfflineFolderStatus(
        total: counts.$1,
        currentReady: counts.$2,
        readable: counts.$3,
        pendingUpdate: counts.$4,
      );
    }
    final snapshot = offlineSnapshot;
    if (!identical(snapshot, _downloadFolderSnapshot)) {
      _downloadFolderSnapshot = snapshot;
      _downloadFolders.clear();
      void include(
        String source,
        String path,
        bool current,
        bool readable,
        bool pending,
      ) {
        var folder = path.contains('/')
            ? path.substring(0, path.lastIndexOf('/'))
            : '';
        while (true) {
          final key = (source, folder);
          final prior = _downloadFolders[key] ?? const OfflineFolderStatus();
          _downloadFolders[key] = OfflineFolderStatus(
            total: prior.total + 1,
            currentReady: prior.currentReady + (current ? 1 : 0),
            readable: prior.readable + (readable ? 1 : 0),
            pendingUpdate: prior.pendingUpdate + (pending ? 1 : 0),
          );
          if (folder.isEmpty) break;
          folder = folder.contains('/')
              ? folder.substring(0, folder.lastIndexOf('/'))
              : '';
        }
      }

      final selected = activeCollection;
      if (selected != null) {
        for (final item in selected.currentItems) {
          if (item.missing) continue;
          final old = selected.readableItemFor(item.entryId);
          final readable = old != null && selected.isReady(old);
          final current =
              selected.isReady(item) ||
              (readable && old.revisionId == item.revisionId);
          include(
            item.sourceId,
            item.relativePath,
            current,
            readable,
            readable && old.revisionId != item.revisionId,
          );
        }
      } else if (snapshot != null) {
        for (final entry in snapshot.availableEntries) {
          final ready = entry.availability == ContentAvailability.ready;
          include('legacy', entry.relativePath, ready, ready, false);
        }
      }
    }
    return _downloadFolders[(sourceId, folder)] ?? const OfflineFolderStatus();
  }

  bool needsOfflineDownload({required String sourceId, String folder = ''}) =>
      folderOfflineStatus(sourceId: sourceId, folder: folder).needsDownload;

  (int, int) get selectedDownloadTotals {
    final selected =
        collection?.index?.entries.where(
          (e) => !e.missing && collection!.selection.includes(e),
        ) ??
        <CatalogItem>[];
    return (selected.length, selected.fold<int>(0, (n, e) => n + e.length));
  }

  (int, int) downloadEstimate({
    required String sourceId,
    String? folder,
    String? entryId,
  }) {
    final entries =
        collection?.index?.entries.where(
          (e) =>
              !e.missing &&
              e.sourceId == sourceId &&
              (entryId != null
                  ? e.entryId == entryId
                  : folderContains(folder ?? '', e.relativePath)),
        ) ??
        <CatalogItem>[];
    return (entries.length, entries.fold<int>(0, (n, e) => n + e.length));
  }

  Future<void> selectOffline(OfflineRule rule) async {
    if (busy) {
      cancel();
      await _syncTask;
    }
    await collection?.select(rule);
    _changed();
  }

  Future<void> removeOfflineDownload(String id) async {
    if (busy) {
      cancel();
      await _syncTask;
    }
    await collection?.removeDownload(id);
    _changed();
  }

  LibrarySnapshot? _targetSnapshot;
  Object? _targetCollectionToken;
  final Map<String, ScoreTarget> _offlineTargets = {};
  List<ScoreTarget> _readyTargets = const [];
  List<ScoreTarget> get offlineTargets {
    _indexOfflineTargets();
    return _readyTargets;
  }

  void _indexOfflineTargets() {
    final view = replica;
    final selected = activeCollection;
    if (selected != null) {
      final token = (selected, selected.contentRevision, selected.directory);
      if (_targetCollectionToken == token) return;
      _targetCollectionToken = token;
      _readyTargets = [
        for (final id in selected.directory.availableIds) ?locateOffline(id),
      ];
      return;
    }
    final snapshot = offlineSnapshot;
    if (identical(snapshot, _targetSnapshot)) return;
    _targetSnapshot = snapshot;
    _offlineTargets.clear();
    if (view != null && snapshot != null) {
      for (final entry in snapshot.availableEntries) {
        if (entry.availability != ContentAvailability.ready) continue;
        _offlineTargets[entry.id] = ScoreTarget(
          entryId: entry.id,
          revisionId: entry.currentRevisionId,
          filePath:
              selected?.presentationPathFor(entry.id) ??
              view.presentationPathFor(entry.id),
          displayPath: entry.relativePath,
          parentFolderLabel:
              '${sourceNameFor(entry.id)} · ${scoreParentFolder(entry.relativePath)}',
          contentHash: entry.currentRevision.contentHash,
          verifiedImmutable: true,
          validateBeforeRead: () =>
              selected?.validateForRead(entry.id, entry.currentRevisionId) ??
              view.validateForRead(entry.id, entry.currentRevisionId),
        );
      }
    }
    _readyTargets = List.unmodifiable(_offlineTargets.values);
  }

  SyncPhase phase = SyncPhase.idle;
  String? message;
  String? initializationError;
  String? serverMessage;
  String? pairingCode;
  DateTime? pairingExpires;
  List<Uri> addresses = const [];
  bool get serving => _server != null;
  bool get serverBusy => _serverBusy || _preparingConnection;
  bool get paired => _client != null;
  Uri? get computerAddress => _client?.baseUri;
  int? get port => _server?.port;
  bool get autoStartServer => _settings['autoStartServer'] == true;
  String? get pairingQr {
    final code = pairingCode;
    final expires = pairingExpires;
    final origins = addresses.where(PairingQr.isLanOrigin).take(3).toList();
    if (code == null || expires == null || origins.isEmpty) return null;
    return PairingQr(origins: origins, code: code, expires: expires).encode();
  }

  int get receivedObjects => _received;
  bool get hasOfflineLibrary =>
      collection?.index != null || replica?.manifest != null;
  int get offlineCount =>
      activeCollection?.directory.readableCount ??
      offlineSnapshot?.availableEntries
          .where((e) => e.availability == ContentAvailability.ready)
          .length ??
      0;
  bool get hasUnsavedEdits => workspace.unsavedCount > 0 || workspace.saving;

  void _changed() {
    if (!_disposed) {
      pageCounts.refreshVisible();
      notifyListeners();
      // A completion received during metadata refresh/verification is drained
      // once its existing operation releases busy. No stages means no import
      // or busy spinner; native byte-progress callbacks never enter this path.
      if (initialized && !busy && _backgroundRecoveryPending) {
        _backgroundRecoveryPending = false;
        scheduleMicrotask(() => unawaited(_backgroundChanged()));
      }
    }
  }

  Future<void> initialize() async {
    try {
      _canonicalDataDirectory = await prepareTrustedStateRoot(
        library.dataDirectory,
      );
      await directory.create(recursive: true);
    } catch (failure) {
      initializationError =
          '无法准备同步资料目录 [SYNC-ROOT-${_storageFailureKind(failure)}]。已有文件未被清空，请保留此提示以便排查。';
    }
    if (initializationError == null) {
      try {
        if (await _settingsFile.exists()) {
          try {
            _settings = _decodeSettings(await _settingsFile.readAsString());
          } catch (_) {
            _settings = _decodeSettings(
              await File('${_settingsFile.path}.bak').readAsString(),
            );
            message = '同步设置已从备份恢复，请核对电脑地址。';
          }
        }
      } catch (_) {
        initializationError = '同步设置无法恢复，已有配对资料未被清空；完整离线谱库仍会单独恢复。';
      }
      if (initializationError == null) {
        try {
          final clientFolder = _settings['clientFolder'] as String?;
          if (clientFolder != null) {
            if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(clientFolder)) {
              throw const FormatException('Invalid peer folder.');
            }
            _client = await SyncClient.open(
              stateDirectory: p.join(directory.path, 'clients', clientFolder),
              ioTimeout: ioTimeout,
            );
            _configureBackgroundClient();
          }
        } catch (_) {
          message = '上次的电脑配对资料无法读取，请重新配对；已保存的离线谱库仍可使用。';
        }
      }
    }
    await _loadSigningStatus();
    // Offline content must not depend on credentials or settings being readable.
    try {
      replica = await ReplicaLibraryView.open(
        rootDirectory: p.join(directory.path, 'replica'),
      );
      collection = await ReplicaCollectionView.open(replica!);
      if (Platform.isIOS && _client != null) {
        try {
          await _client!.recoverBackgroundCollection(collection!);
        } catch (_) {
          phase = SyncPhase.partial;
          message = '后台曲谱尚未导入，请检查空间后重试同步；已有离线曲谱仍可阅读。';
        }
      }
      if (collection!.persistenceFailed) {
        phase = SyncPhase.partial;
        message = '有些离线记录尚未写入，已验证的曲谱仍可阅读。请检查空间后重试。';
      }
    } catch (failure) {
      initializationError =
          '${initializationError == null ? '' : '${initializationError!}\n'}离线谱库无法恢复 [SYNC-REPLICA-${_storageFailureKind(failure)}]。已有文件未被清空，请保留此提示以便排查。';
    }
    _seenReaderGeneration = workspace.store.snapshot.generation;
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
    initialized = true;
    if (Platform.isIOS) unawaited(_backgroundChanged());
    _changed();
    _maybeAutoStart();
  }

  // Stable, path-free diagnostics; never expose file paths, state or credentials.
  String _storageFailureKind(Object failure) {
    if (failure is FileSystemException) {
      return failure.message == 'Linked sync/source paths are forbidden.'
          ? 'LINK'
          : 'IO';
    }
    if (failure is FormatException) return 'FORMAT';
    if (failure is StateError) return 'STATE';
    return 'UNKNOWN';
  }

  Map<String, dynamic> _decodeSettings(String text) {
    final value = Map<String, dynamic>.from(jsonDecode(text) as Map);
    if (value['version'] != 1 || value['roots'] is! Map) {
      throw const FormatException('Unknown settings.');
    }
    for (final item in (value['roots'] as Map).values) {
      final root = Map<String, dynamic>.from(item as Map);
      if (root['id'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(root['id'] as String) ||
          root['port'] is! int ||
          (root['port'] as int) < 0 ||
          (root['port'] as int) > 65535) {
        throw const FormatException('Invalid source identity.');
      }
    }
    return value;
  }

  Future<void> _saveSettings(Map<String, dynamic> next) async {
    await directory.create(recursive: true);
    final temporary = File('${_settingsFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(next), flush: true);
    if (await _settingsFile.exists()) {
      try {
        _decodeSettings(await _settingsFile.readAsString());
        await _settingsFile.copy('${_settingsFile.path}.bak');
      } catch (_) {
        // Preserve a valid backup after recovering from a broken primary.
        await _settingsFile.rename('${_settingsFile.path}.corrupt.${_newId()}');
      }
    }
    await temporary.rename(_settingsFile.path);
    _settings = next;
  }

  void _libraryChanged() {
    pageCounts.refreshVisible();
    if (_lastSelectedRoot != library.rootPath) {
      _lastSelectedRoot = library.rootPath;
      _autoStartAttemptedRoot = null;
      unawaited(_refreshSigningAuthorization());
    }
    if (_serverRoot != null && library.rootPath != _serverRoot) {
      unawaited(stopServer(reason: '谱库目录已切换，无线服务已关闭。请在新谱库中重新开启。'));
    }
    _maybeAutoStart();
  }

  void _maybeAutoStart() {
    final root = library.rootPath;
    if (!Platform.isWindows ||
        !autoStartServer ||
        !initialized ||
        _disposed ||
        root == null ||
        library.scanning ||
        library.catalogForSync == null ||
        serverBusy ||
        serving ||
        _autoStartAttemptedRoot == root) {
      return;
    }
    // One attempt per selected root. A failure requires an explicit button tap.
    _autoStartAttemptedRoot = root;
    unawaited(startServer());
  }

  Future<void> setAutoStartServer(bool enabled) async {
    try {
      await _saveSettings({..._settings, 'autoStartServer': enabled});
      _changed();
    } catch (_) {
      serverMessage = '无法保存自动连接偏好，请检查数据目录权限。';
      _changed();
    }
  }

  Future<void> connectMyIpad() async {
    if (serverBusy || _disposed) return;
    _preparingConnection = true;
    _changed();
    try {
      if (!autoStartServer) await setAutoStartServer(true);
      await startServer();
      if (serving) {
        await refreshAddresses();
        refreshCode();
      }
    } finally {
      _preparingConnection = false;
      _changed();
    }
  }

  void _workspaceChanged() {
    if (serving && workspace.unsavedCount > 0) {
      unawaited(stopServer(reason: '有笔迹未保存，无线服务已关闭。请重试保存后重新开启。'));
    }
  }

  void _tick() {
    if (_disposed) return;
    if (!_sendingSigning &&
        _pendingSigning != null &&
        _client != null &&
        _signingRetryAt != null &&
        !DateTime.now().isBefore(_signingRetryAt!)) {
      _signingRetryAt = null;
      _signingRetries--;
      unawaited(_sendSigningReports());
    }
    if (serving &&
        pairingExpires != null &&
        !pairingExpires!.isAfter(DateTime.now())) {
      refreshCode();
    }
    final generation = workspace.store.snapshot.generation;
    if (generation != _seenReaderGeneration) {
      _seenReaderGeneration = generation;
      workspace.refreshFromStore();
    }
    final received =
        (replica?.verificationStats.downloadObjectsVerified ?? 0) -
        _receivedBeforeRun;
    if (_received != received) {
      _received = received;
      _changed();
    }
  }

  Future<void> startServer() async {
    if (_serverBusy || serving || initializationError != null || !initialized) {
      return;
    }
    final root = library.rootPath;
    if (root == null || library.catalogForSync == null || library.scanning) {
      serverMessage = '请先选择谱库并等待更新完成。';
      _changed();
      return;
    }
    if (hasUnsavedEdits) {
      serverMessage = '请先等待保存完成或重试未保存笔迹，再开启服务。';
      _changed();
      return;
    }
    if (p.equals(root, directory.path) || p.isWithin(root, directory.path)) {
      serverMessage = '应用数据目录必须位于源谱库之外。';
      _changed();
      return;
    }
    _lastSelectedRoot = root;
    _autoStartAttemptedRoot = root;
    _serverBusy = true;
    serverMessage = null;
    _changed();
    SyncServer? started;
    try {
      final key = _rootKey(root);
      final roots = Map<String, dynamic>.from(_settings['roots'] as Map);
      final identity = roots[key] == null
          ? <String, dynamic>{'id': _newId(), 'port': 0}
          : Map<String, dynamic>.from(roots[key] as Map);
      roots[key] = identity;
      // Persist identity before it can be advertised, even if binding later fails.
      await _saveSettings({..._settings, 'roots': roots});
      started = await SyncServer.start(
        source: _LiveLibrarySource(library, root, identity['id'] as String),
        collectionSource: CatalogCollectionSource(
          id: identity['id'] as String,
          legacyLibraryId: library.legacySourceEnabled
              ? identity['id'] as String
              : null,
          bindings: () => library.sources,
          prepareEntry: library.prepareForRead,
        ),
        readerStore: workspace.store,
        stateDirectory: p.join(
          directory.path,
          'servers',
          identity['id'] as String,
        ),
        address: bindAddress ?? InternetAddress.anyIPv4,
        port: identity['port'] as int,
        ioTimeout: ioTimeout,
      );
      if (_disposed || library.rootPath != root) {
        await started.close();
        return;
      }
      final statusStore = _signingStore;
      started.onPageMetadata = (keys) async {
        final result = <PageMetadataKey, int>{};
        for (final key in keys) {
          if (_disposed || library.rootPath != root) break;
          final input = library.pageCountFile(key);
          if (input == null) continue;
          final extension = p.extension(input.path).toLowerCase();
          if (extension != '.pdf') {
            if (['.png', '.jpg', '.jpeg', '.webp'].contains(extension)) {
              result[key] = 1;
            }
          } else {
            final count = await pageCounts.lookup(key);
            if (count != null && input.same(library.pageCountFile(key))) {
              result[key] = count;
            }
          }
        }
        return result;
      };
      if (statusStore != null) {
        final server = started;
        _signingAuthEpoch++;
        statusStore.selectServer(identity['id'] as String);
        statusStore.setAuthenticatedPeers(
          identity['id'] as String,
          server.authenticatedPeerIds,
        );
        server.onSigningStatus = (peer, status, receivedAt) async {
          if (_disposed || library.rootPath != root) {
            throw const SyncProtocolException('Server changed.', 409);
          }
          _signingAuthEpoch++;
          statusStore.setAuthenticatedPeers(
            identity['id'] as String,
            server.authenticatedPeerIds,
          );
          await statusStore.receive(
            identity['id'] as String,
            peer,
            status,
            receivedAt,
          );
        };
      }
      identity['port'] = started.port;
      roots[key] = identity;
      await _saveSettings({..._settings, 'roots': roots});
      if (_disposed || library.rootPath != root) {
        await started.close();
        return;
      }
      _server = started;
      _serverRoot = root;
      await refreshAddresses();
      refreshCode();
      serverMessage = '服务已开启。请在同一可信Wi-Fi内连接；退出应用后服务关闭。';
    } catch (_) {
      await started?.close();
      _server = null;
      _serverRoot = null;
      serverMessage = '无法开启服务。请检查端口是否被另一实例占用、网络与数据目录权限，然后重试。';
    } finally {
      _serverBusy = false;
      _changed();
      _maybeAutoStart();
    }
  }

  Future<void> refreshAddresses() async {
    final port = _server?.port;
    if (port == null) return;
    final hosts = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      interfaces.sort((a, b) {
        int rank(String name) =>
            RegExp(
              r'wi-fi|wlan|wireless|无线',
              caseSensitive: false,
            ).hasMatch(name)
            ? 0
            : 1;
        return rank(a.name).compareTo(rank(b.name));
      });
      for (final interface in interfaces) {
        if (!PairingQr.isPhysicalInterface(interface.name)) continue;
        for (final address in interface.addresses) {
          final uri = Uri(scheme: 'http', host: address.address, port: port);
          if (PairingQr.isLanOrigin(uri)) hosts.add(address.address);
        }
      }
    } catch (_) {
      /* No reachable LAN address: show recovery guidance instead of loopback QR. */
    }
    addresses = [
      for (final host in hosts) Uri(scheme: 'http', host: host, port: port),
    ];
    _changed();
  }

  void refreshCode() {
    final server = _server;
    if (server == null) return;
    pairingCode = server.createPairingCode();
    pairingExpires = DateTime.now().add(const Duration(minutes: 2));
    _changed();
  }

  Future<void> stopServer({String? reason}) async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _serverRoot = null;
    pairingCode = null;
    pairingExpires = null;
    addresses = const [];
    _serverBusy = true;
    serverMessage = reason ?? '无线服务已关闭。';
    _changed();
    try {
      await server.close();
    } finally {
      _serverBusy = false;
      _changed();
    }
  }

  static Uri parseAddress(String value) {
    final text = value.trim();
    final uri = Uri.parse(text.contains('://') ? text : 'http://$text');
    if (uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.host == '0.0.0.0' ||
        uri.host == '::' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入电脑上显示的完整地址与端口。');
    }
    return uri;
  }

  Future<void> pair(String address, String code) async {
    if (busy || initializationError != null || !initialized) return;
    Uri uri;
    try {
      uri = parseAddress(address);
    } catch (_) {
      phase = SyncPhase.failed;
      message = '地址无效，请填写电脑上显示的地址和端口。';
      _changed();
      return;
    }
    if (!RegExp(r'^\d{8}$').hasMatch(code.trim())) {
      phase = SyncPhase.failed;
      message = '请输入电脑显示的8位配对码。';
      _changed();
      return;
    }
    await _pairOrigins([uri], code.trim());
  }

  Future<bool> pairFromQr(String text) async {
    if (busy || initializationError != null || !initialized) return false;
    PairingQr qr;
    try {
      qr = PairingQr.decode(text);
    } catch (failure) {
      phase = SyncPhase.failed;
      message = failure is FormatException
          ? failure.message.toString()
          : '二维码无效，请扫描电脑上的新二维码。';
      _changed();
      return false;
    }
    return _pairOrigins(qr.origins, qr.code, quickConnect: true);
  }

  Future<bool> _pairOrigins(
    List<Uri> origins,
    String code, {
    bool quickConnect = false,
  }) async {
    busy = true;
    phase = SyncPhase.pairing;
    message = '正在连接电脑…';
    _changed();
    try {
      String? folder;
      Object? lastFailure;
      for (final origin in origins) {
        final candidate = _newId();
        try {
          await SyncClient.pair(
            baseUri: origin,
            code: code,
            stateDirectory: p.join(directory.path, 'clients', candidate),
            ioTimeout: quickConnect && ioTimeout > const Duration(seconds: 5)
                ? const Duration(seconds: 5)
                : ioTimeout,
          );
          folder = candidate;
          break;
        } catch (failure) {
          lastFailure = failure;
        }
      }
      if (folder == null) {
        throw lastFailure ?? StateError('No reachable computer');
      }
      final client = await SyncClient.open(
        stateDirectory: p.join(directory.path, 'clients', folder),
        ioTimeout: ioTimeout,
      );
      final oldClient = _client, oldTransfer = _backgroundTransfer;
      if (oldClient != null && oldTransfer != null) {
        await oldTransfer.discard(oldClient.backgroundTransferNamespace);
      }
      await _saveSettings({..._settings, 'clientFolder': folder});
      _client = client;
      _configureBackgroundClient();
      pageCounts.connectionChanged();
      _retrySigningReport();
      phase = SyncPhase.idle;
      message = '已记住这台电脑，以后点击“立即同步”即可。';
      return true;
    } on SyncProtocolException catch (failure) {
      phase = SyncPhase.failed;
      message = failure.status == 403
          ? '二维码或配对码已使用、无效或已过期，请在电脑点击“更新二维码”后重扫。'
          : '电脑拒绝配对，请检查服务状态后重试。';
    } catch (_) {
      phase = SyncPhase.failed;
      message = '未能连接电脑。请让两台设备连接同一Wi-Fi，保持电脑阅读器打开，并允许本地网络访问后重扫。';
    } finally {
      busy = false;
      _changed();
    }
    return false;
  }

  Future<void> synchronize({Set<String>? onlyEntryIds}) =>
      _syncTask ??= _synchronize(onlyEntryIds: onlyEntryIds)
          .whenComplete(() => _syncTask = null);

  /// Refresh the directory without altering the system's selected download
  /// queue or exchanging reader state. Safe while native transfers are active.
  Future<void> refreshCatalog() async {
    if (busy || _client == null || collection == null) return;
    busy = true;
    phase = SyncPhase.transferring;
    processedObjects = 0;
    totalObjects = null;
    committingLibrary = false;
    message = '正在更新曲谱目录…';
    final cancellation = SyncCancellation();
    _cancellation = cancellation;
    _changed();
    try {
      await _client!.refreshCollectionIndex(
        collection!,
        cancellation: cancellation,
      );
      phase = SyncPhase.complete;
      message = '目录已更新。';
    } catch (_) {
      phase = cancellation.isCancelled
          ? SyncPhase.cancelled
          : SyncPhase.partial;
      message = cancellation.isCancelled ? '更新已取消。' : '目录更新未完成，请检查电脑与网络后重试。';
    } finally {
      _cancellation = null;
      busy = false;
      _tick();
      _changed();
    }
  }

  Future<void> _synchronize({Set<String>? onlyEntryIds}) async {
    if (busy || _client == null || replica == null) return;
    if (hasUnsavedEdits) {
      message = '批注未保存，请先重试保存。';
      _changed();
      return;
    }
    busy = true;
    processedObjects = 0;
    totalObjects = null;
    committingLibrary = false;
    _receivedBeforeRun = replica!.verificationStats.downloadObjectsVerified;
    _received = 0;
    phase = SyncPhase.transferring;
    message = '正在更新目录和所选离线内容…';
    final cancellation = SyncCancellation();
    _cancellation = cancellation;
    _changed();
    try {
      final result = await _client!.syncCollection(
        collection!,
        onlyEntryIds: onlyEntryIds,
        cancellation: cancellation,
        onProgress: (progress) {
          processedObjects = progress.processed;
          totalObjects = progress.total;
          committingLibrary = progress.phase == LibrarySyncPhase.committing;
          _changed();
        },
      );
      if (result.status != LibrarySyncStatus.complete) {
        phase = result.status == LibrarySyncStatus.cancelled
            ? SyncPhase.cancelled
            : SyncPhase.partial;
        message =
            onlyEntryIds != null &&
                result.error == 'Scoped preparation requires a v2 computer'
            ? '请先更新电脑端，再按曲单准备。'
            : _libraryFailureMessage(result.failure);
        if (result.status == LibrarySyncStatus.cancelled ||
            (onlyEntryIds != null &&
                result.error == 'Scoped preparation requires a v2 computer') ||
            hasUnsavedEdits ||
            (result.failure != LibrarySyncFailure.sourceNotReady &&
                result.failure != LibrarySyncFailure.integrity)) {
          return;
        }
      }
      if (hasUnsavedEdits) {
        phase = SyncPhase.partial;
        message = '批注未保存，请先重试保存。';
        return;
      }
      _retrySigningReport();
      phase = SyncPhase.merging;
      pageCounts.connectionChanged();
      final contentPartial = result.status != LibrarySyncStatus.complete;
      message = '正在交换已保存的批注和曲单…';
      _changed();
      await _client!.syncReaderState(
        workspace.store,
        cancellation: cancellation,
        afterMerge: () async {
          workspace.refreshFromStore(force: true);
        },
      );
      cancellation.check();
      if (hasUnsavedEdits) {
        phase = SyncPhase.partial;
        message = '批注正在保存，请稍后同步。';
        return;
      }
      phase = contentPartial ? SyncPhase.partial : SyncPhase.complete;
      message = contentPartial
          ? '部分曲谱未下载，请重试。'
          : workspace.store.snapshot.conflicts.isEmpty
          ? '已更新。'
          : '有不同版本，请查看。';
    } catch (failure) {
      phase = cancellation.isCancelled
          ? SyncPhase.cancelled
          : SyncPhase.partial;
      message =
          failure is SyncProtocolException &&
              failure.code == 'reader_upgrade_required'
          ? '请更新电脑和 iPad 后再同步批注。'
          : cancellation.isCancelled
          ? '同步已取消。'
          : '批注同步未完成，请重试。';
    } finally {
      workspace.refreshFromStore(force: true);
      _tick();
      _cancellation = null;
      busy = false;
      _changed();
      final stats = replica?.verificationStats;
      if (stats != null) {
        debugPrint(
          'SYNC replica local_hash_bytes=${stats.localHashBytesRead} received_bytes=${stats.downloadBytesReceived} reused_objects=${stats.cachedObjectsReused}',
        );
      }
    }
  }

  String _libraryFailureMessage(LibrarySyncFailure? failure) =>
      switch (failure) {
        LibrarySyncFailure.differentLibrary =>
          '电脑提供的是另一份谱库，本次未覆盖已有副本。请连接原电脑并选择原谱库。',
        LibrarySyncFailure.sourceNotReady =>
          '电脑谱库还有未下载或无法读取的文件，请在电脑补全文件并刷新后重试。',
        LibrarySyncFailure.connection => '连接中断，请检查电脑服务、Wi-Fi与局域网权限后重试。',
        LibrarySyncFailure.authentication => '电脑未接受现有配对，请刷新配对码并重新配对。',
        LibrarySyncFailure.integrity => '收到的文件未通过完整性校验，请刷新电脑谱库后重试。',
        LibrarySyncFailure.localStorage => '离线文件无法保存，请检查磁盘空间与应用数据目录权限后重试。',
        LibrarySyncFailure.cancelled => '本次同步已取消。',
        LibrarySyncFailure.unknown || null => '本次更新尚未完成，请检查电脑与网络后重试。',
      };

  void cancel() {
    _cancellation?.cancel();
    if (backgroundPendingObjects > 0) unawaited(pauseBackgroundDownloads());
  }

  Future<void> pauseBackgroundDownloads() async {
    final transfer = _backgroundTransfer, client = _client;
    if (transfer == null || client == null) return;
    _cancellation?.cancel();
    try {
      await transfer.pause(client.backgroundTransferNamespace);
      message = '下载已暂停，已保存的曲谱仍可阅读。';
    } catch (_) {
      message = '暂停状态尚未保存，请检查空间后重试。';
    }
    await _refreshBackgroundActivity();
  }

  Future<void> resumeBackgroundDownloads() async {
    final transfer = _backgroundTransfer, client = _client;
    if (transfer == null || client == null || busy) return;
    try {
      await transfer.resume(
        client.backgroundTransferNamespace,
        selection: collection?.selection,
      );
      message = '已继续后台下载。';
    } catch (_) {
      message = '下载尚未恢复，请检查空间后重试。';
    }
    await _backgroundChanged();
  }

  Future<void> verifyOfflineLibrary() async {
    if (busy || replica == null) return;
    busy = true;
    phase = SyncPhase.verifying;
    message = '正在完整校验离线文件，较大谱库需要一些时间…';
    _changed();
    try {
      final selected = activeCollection;
      var unavailable = 0;
      if (selected == null) {
        await replica!.verifyAll();
        unavailable = replica!.snapshot.availableEntries
            .where((e) => e.availability != ContentAvailability.ready)
            .length;
      } else {
        for (final entry in selected.snapshot.availableEntries) {
          final item = selected.readableItemFor(entry.id);
          if (item != null &&
              !await replica!.hasVerifiedObject(item.object, verifyAll: true)) {
            unavailable++;
          }
        }
        await selected.updateIndex(selected.index!);
      }
      phase = SyncPhase.idle;
      message = unavailable == 0
          ? '离线文件校验完成。'
          : '$unavailable 份离线文件无法读取，请重新同步修复。';
    } catch (_) {
      phase = SyncPhase.failed;
      message = '离线校验失败，请重新同步。';
    } finally {
      busy = false;
      _changed();
    }
  }

  ScoreTarget? locateOffline(String entryId) {
    final selected = activeCollection;
    if (selected != null) {
      final readable = selected.readableItemFor(entryId);
      if (readable == null ||
          !selected.isReady(readable) ||
          selected.itemFor(entryId)?.missing != false) {
        return null;
      }
      final entry = selected.entryForDisplay(entryId)!;
      return ScoreTarget(
        entryId: entry.id,
        revisionId: entry.currentRevisionId,
        filePath: selected.presentationPathFor(entry.id),
        displayPath: entry.relativePath,
        parentFolderLabel:
            '${sourceNameFor(entry.id)} · ${scoreParentFolder(entry.relativePath)}',
        contentHash: entry.currentRevision.contentHash,
        verifiedImmutable: true,
        validateBeforeRead: () =>
            selected.validateForRead(entry.id, entry.currentRevisionId),
      );
    }
    _indexOfflineTargets();
    return _offlineTargets[entryId];
  }

  @override
  void dispose() {
    _disposed = true;
    _signingAuthEpoch++;
    if (_signingObserver || _backgroundObserver) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _backgroundTransfer?.dispose();
    unawaited(_stopSigningWatches());
    signingUnavailable.dispose();
    pageCounts.dispose();
    signingStatus.dispose();
    final signingStore = _signingStore;
    if (signingStore != null) unawaited(signingStore.close());
    _timer?.cancel();
    _cancellation?.cancel();
    library.removeListener(_libraryChanged);
    workspace.removeListener(_workspaceChanged);
    unawaited(stopServer());
    super.dispose();
  }
}

class OfflineFolderStatus {
  const OfflineFolderStatus({
    this.total = 0,
    this.currentReady = 0,
    this.readable = 0,
    this.pendingUpdate = 0,
  });
  final int total, currentReady, readable, pendingUpdate;
  bool get allCurrent => total > 0 && currentReady == total;
  bool get needsDownload => currentReady < total;
  String get description => total == 0
      ? '空文件夹'
      : allCurrent
      ? '全部已下载 · $currentReady / $total 份'
      : readable == 0
      ? '全部未下载 · 0 / $total 份'
      : pendingUpdate > 0
      ? '部分已下载 · $readable / $total 份已有离线副本，$pendingUpdate 份待更新'
      : '部分已下载 · $readable / $total 份';
}
