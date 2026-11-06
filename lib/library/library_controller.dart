import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;

import 'windows_file_identity.dart';
import 'page_count_service.dart';

class LibraryScanPacket {
  const LibraryScanPacket(
    this.result,
    this.storageWarnings,
    this.elapsed, [
    this.catalog,
  ]);
  final ScanResult result;
  final List<String> storageWarnings;
  final Duration elapsed;
  final LibraryCatalog? catalog;
}

typedef LibraryScanRunner = Future<LibraryScanPacket> Function(
  String rootPath,
  String statePath,
  bool verifyAll,
);
typedef LibraryCatalogLoader = Future<LibraryCatalog> Function(
  String root,
  String state,
);

Future<LibraryCatalog> _openCatalog(String root, String state) =>
    LibraryCatalog.open(
      rootPath: root,
      statePath: state,
      fileIdentityResolver: windowsFileIdentity,
      stateIdentityResolver: windowsFileIdentity,
    );

Future<LibraryCatalog> _openInWorker(String root, String state) =>
    Isolate.run(() async {
      final catalog = await _openCatalog(root, state);
      catalog.snapshot.entryById('');
      catalog.snapshot.availableEntries;
      catalog.listFolder();
      return catalog;
    });

final _foregroundTasks = <String, Future<void>>{};
final _scanJobs = <String, _ScanJob>{};
String _catalogJobKey(String state) {
  final key = p.normalize(p.absolute(state));
  return Platform.isWindows ? key.toLowerCase() : key;
}

class _ScanJob {
  final done = Completer<LibraryScanPacket>();
  SendPort? commands;
  bool yielded = false;
  void requestYield() {
    yielded = true;
    commands?.send('yield');
  }
}

Future<void> _scanWorker((String, String, bool, bool, Set<String>?, SendPort) request) async {
  final (root, state, verify, metadata, dirtyPaths, reply) = request;
  final commands = ReceivePort();
  var yieldRequested = false;
  final subscription = commands.listen((_) => yieldRequested = true);
  reply.send(commands.sendPort);
  try {
    final watch = Stopwatch()..start();
    final catalog = await _openCatalog(root, state);
    if (yieldRequested) throw const CatalogScanYielded();
    final result = await catalog.rescan(
      verifyAll: verify,
      metadataOnly: metadata,
      dirtyPaths: dirtyPaths,
      shouldYield: () => yieldRequested,
    );
    catalog.snapshot.entryById('');
    catalog.snapshot.availableEntries;
    catalog.listFolder();
    reply.send(
      LibraryScanPacket(
        result,
        catalog.storageWarnings,
        watch.elapsed,
        catalog,
      ),
    );
  } catch (error, stack) {
    reply.send((error, stack.toString()));
  } finally {
    await subscription.cancel();
    commands.close();
  }
}

Future<LibraryScanPacket> _cooperativeScan(
  String root,
  String state,
  bool verify,
  bool metadata, [Set<String>? dirtyPaths]
) async {
  // A foreground job that was already queued runs before a new idle scan.
  final key = _catalogJobKey(state);
  await _foregroundTasks[key]?.catchError((Object _) {});
  final job = _ScanJob();
  _scanJobs[key] = job;
  final replies = ReceivePort();
  final subscription = replies.listen((message) {
    if (message is SendPort) {
      job.commands = message;
      if (job.yielded) message.send('yield');
    } else if (message is LibraryScanPacket) {
      job.done.complete(message);
    } else if (message is (Object, String)) {
      job.done.completeError(message.$1, StackTrace.fromString(message.$2));
    } else if (!job.done.isCompleted) {
      job.done.completeError(StateError('Catalogue worker stopped: $message'));
    }
  });
  try {
    await Isolate.spawn(
      _scanWorker,
      (root, state, verify, metadata, dirtyPaths, replies.sendPort),
      onError: replies.sendPort,
      onExit: replies.sendPort,
    );
    return await job.done.future;
  } finally {
    if (identical(_scanJobs[key], job)) _scanJobs.remove(key);
    await subscription.cancel();
    replies.close();
  }
}

Future<LibraryScanPacket> _scanInWorker(
  String root,
  String state,
  bool verify,
) => _cooperativeScan(root, state, verify, false);

Future<LibraryScanPacket> _scanMetadata(String root, String state) =>
    _cooperativeScan(root, state, false, true);

Future<CatalogMaterialization> _materializeInWorker(
  String root,
  String state,
  String id,
  CatalogPublication expected,
) => Isolate.run(() async {
  for (var attempt = 0; ; attempt++) {
    try {
      final catalog = await _openCatalog(root, state);
      final patch = await catalog.materializeForPublication(id, expected);
      if (patch.fallback != null) {
        catalog.snapshot.availableEntries;
        catalog.snapshot.entryById('');
        catalog.listFolder();
      }
      return patch;
    } on ConcurrentCatalogWriteException {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }
});

Future<CatalogBatchMaterialization> _materializeManyInWorker(
  String root,
  String state,
  Map<String, String> selected,
  CatalogPublication expected,
) => Isolate.run(() async {
  for (var attempt = 0; ; attempt++) {
    try {
      final catalog = await _openCatalog(root, state);
      return await catalog.materializeManyForPublication(selected, expected);
    } on ConcurrentCatalogWriteException {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }
});

class _AddedSource {
  _AddedSource(this.id, this.name, this.root, this.catalog);
  final String id, name, root;
  LibraryCatalog catalog;
  bool online = true, running = false;
  bool verifyQueued = false, refreshQueued = false, fullScanQueued = false;
  final dirtyQueued = <String>{};
  Timer? retry;
  StreamSubscription<FileSystemEvent>? watcher;
}

/// File content scanning/hash work runs in a worker isolate. All view queries
/// use the shared library_core snapshot; the UI does not reimplement indexing.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.dataDirectory,
    LibraryScanRunner? scanRunner,
    LibraryCatalogLoader? catalogLoader,
    this.watchSource = true,
  }) : _scanRunner = scanRunner ?? _scanInWorker,
       _catalogLoader = catalogLoader ?? _openInWorker;

  final Directory dataDirectory;
  final bool watchSource;
  final LibraryScanRunner _scanRunner;
  final LibraryCatalogLoader _catalogLoader;
  LibraryCatalog? _catalog;
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _debounce;
  bool _disposed = false;
  int _epoch = 0;
  int? _scanningEpoch;
  bool _scanQueued = false, _queuedFullScan = false;
  final _queuedDirtyPaths = <String>{};
  final _watchDirty = <String, Set<String>?>{};
  bool _verifyQueued = false;
  final _added = <_AddedSource>[];
  String _primaryId = 'legacy';
  bool _primaryMetadataOnly = false, _primaryOnline = true;
  String? _browsingSource;
  LibrarySnapshot? _combined;
  final _owners = <String, (CatalogSourceBinding, LibraryEntry)>{};
  List<(String, LibrarySnapshot, String, bool)> _indexedSources = const [];
  final _externalEntries = <String, LibraryEntry>{};
  final _searchText = <String, String>{};
  (LibrarySnapshot, String, String)? _listingKey;
  FolderListing? _listing;
  (LibrarySnapshot, String, String, String, bool)? _searchKey;
  List<LibraryEntry> _searchResults = const [];
  int _extraJobs = 0;
  Future<void>? _registryWrites;
  final _importScanWaiters = <Completer<void>>{};

  bool initialized = false;
  String? rootPath;
  String currentFolder = '';
  String query = '';
  bool searchCurrentFolder = false;
  String? error;
  String? watchWarning;
  ScanResult? lastScan;
  Duration? lastScanDuration;
  List<String> storageWarnings = const [];

  bool get scanning => _scanningEpoch == _epoch || _extraJobs > 0;
  bool get legacySourceEnabled => !_primaryMetadataOnly;
  String get selectedSourceId => _browsingSource ?? _primaryId;
  List<CatalogSourceBinding> get sources => [
    if (_catalog != null)
      CatalogSourceBinding(
        _primaryId,
        p.basename(rootPath!),
        _catalog!,
        online: _primaryOnline,
      ),
    for (final s in _added)
      CatalogSourceBinding(s.id, s.name, s.catalog, online: s.online),
  ];
  CatalogSourceBinding? get selectedSource {
    for (final s in sources) {
      if (s.id == selectedSourceId) return s;
    }
    return null;
  }

  LibraryEntry _external(CatalogSourceBinding source, LibraryEntry e) =>
      source.id == 'legacy'
      ? e
      : LibraryEntry(
          id: collectionEntryId(source.id, e.id),
          relativePath: e.relativePath,
          status: e.status,
          availability: e.availability,
          revisions: e.revisions,
          currentRevisionId: e.currentRevisionId,
          lastSeenUtc: e.lastSeenUtc,
          platformFileId: e.platformFileId,
        );
  LibrarySnapshot? get snapshot {
    if (_catalog == null) {
      _combined = null;
      _indexedSources = const [];
      return null;
    }
    final currentSources = sources;
    final keys = [
      for (final s in currentSources)
        (s.id, s.catalog.snapshot, s.name, s.online),
    ];
    if (_combined != null && listEquals(keys, _indexedSources)) {
      return _combined;
    }
    _indexedSources = keys;
    _owners.clear();
    _externalEntries.clear();
    _searchText.clear();
    final entries = <LibraryEntry>[];
    for (final source in currentSources) {
      for (final e in source.catalog.snapshot.entries) {
        final external = _external(source, e);
        _owners[external.id] = (source, e);
        _externalEntries[external.id] = external;
        _searchText[external.id] = '${source.name}/${e.relativePath}'
            .toLowerCase();
        entries.add(external);
      }
    }
    return _combined = LibrarySnapshot(
      rootPath: rootPath!,
      generation: currentSources.fold(
        0,
        (n, s) => n + s.catalog.snapshot.generation,
      ),
      entries: entries,
      folders: _catalog!.snapshot.folders,
      savedUtc: _catalog!.snapshot.savedUtc,
    );
  }

  /// The sync adapter resolves this on every request after scans replace it.
  LibraryCatalog? get catalogForSync => _catalog;
  int get totalCount => snapshot?.availableEntries.length ?? 0;
  int get selectedSourceCount =>
      selectedSource?.catalog.snapshot.availableEntries.length ?? 0;
  bool get searching => query.trim().isNotEmpty;
  List<String> get folders =>
      selectedSource?.catalog.snapshot.folders ?? const [''];

  FolderListing get listing {
    final combined = snapshot, source = selectedSource;
    if (combined == null || source == null) {
      return FolderListing(folders: [], entries: []);
    }
    final key = (combined, source.id, currentFolder);
    if (key == _listingKey) return _listing!;
    final local = source.catalog.listFolder(currentFolder);
    _listingKey = key;
    return _listing = FolderListing(
      folders: local.folders,
      entries: [
        for (final e in local.entries)
          _externalEntries[collectionEntryId(source.id, e.id)]!,
      ],
    );
  }

  List<LibraryEntry> get visibleEntries {
    if (!searching) return listing.entries;
    final combined = snapshot;
    if (combined == null) return const [];
    final key = (
      combined,
      query,
      selectedSourceId,
      currentFolder,
      searchCurrentFolder,
    );
    if (key == _searchKey) return _searchResults;
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    _searchKey = key;
    return _searchResults = combined.availableEntries
        .where((entry) {
          final owner = _owners[entry.id]!.$1;
          if (searchCurrentFolder &&
              (owner.id != selectedSourceId ||
                  !folderContains(currentFolder, entry.relativePath))) {
            return false;
          }
          return terms.every(_searchText[entry.id]!.contains);
        })
        .toList(growable: false);
  }

  String absolutePathFor(LibraryEntry entry) {
    snapshot;
    final owner = _owners[entry.id]!;
    return owner.$1.catalog.absolutePathFor(owner.$2);
  }

  PageCountFile? pageCountFile(PageMetadataKey key) {
    snapshot;
    final owner = _owners[key.entryId];
    if (owner == null ||
        owner.$2.status != EntryStatus.available ||
        owner.$2.currentRevisionId != key.revisionId ||
        !owner.$1.online) {
      return null;
    }
    final revision = owner.$2.currentRevision;
    return PageCountFile(
      owner.$1.catalog.absolutePathFor(owner.$2),
      owner.$1.catalog.rootPath,
      size: revision.size,
      modifiedUtc: revision.modifiedUtc,
    );
  }

  /// A chosen file inside a registered source reuses that source's identity.
  /// Folder lookup is indexed; it never scans every catalogue entry per open.
  Future<(bool, LibraryEntry?)> entryForFilePath(String path) async {
    final actual = p.normalize(await File(path).resolveSymbolicLinks());
    for (final source in sources) {
      final root = source.catalog.rootPath;
      if (!p.isWithin(root, actual)) continue;
      final relative = p
          .relative(actual, from: root)
          .split(p.separator)
          .join('/');
      final parent = p.posix.dirname(relative);
      final key = Platform.isWindows ? relative.toLowerCase() : relative;
      for (final entry
          in source.catalog.listFolder(parent == '.' ? '' : parent).entries) {
        if ((Platform.isWindows
                ? entry.relativePath.toLowerCase()
                : entry.relativePath) ==
            key) {
          snapshot;
          return (
            true,
            _externalEntries[collectionEntryId(source.id, entry.id)],
          );
        }
      }
      return (true, null);
    }
    return (false, null);
  }

  String sourceNameFor(LibraryEntry entry) {
    snapshot;
    return _owners[entry.id]?.$1.name ?? '';
  }

  String sourceIdFor(LibraryEntry entry) {
    snapshot;
    return _owners[entry.id]?.$1.id ?? '';
  }

  Future<void> ensureReady(String id) async {
    await prepareEntry(id);
  }

  Future<LibraryEntry> prepareForRead(String id, String revision) =>
      prepareEntry(id, revision: revision);

  Future<LibraryEntry> prepareEntry(String id, {String? revision}) async {
    snapshot;
    final owner = _owners[id];
    if (owner == null || !owner.$1.online) {
      throw StateError('Source is offline.');
    }
    if (revision != null && owner.$2.currentRevisionId != revision) {
      throw StateError('Source revision changed.');
    }
    final epoch = _epoch;
    final ready = await owner.$1.catalog.readyIfUnchanged(owner.$2.id);
    if (_disposed || epoch != _epoch) throw StateError('Source changed.');
    if (ready != null) return ready;
    final state = owner.$1.catalog.statePath;
    final jobKey = _catalogJobKey(state);
    final root = owner.$1.catalog.rootPath;
    final result = Completer<LibraryEntry>();
    final previous = _foregroundTasks[jobKey] ?? Future<void>.value();
    late Future<void> task;
    task = previous.catchError((Object _) {}).then((_) async {
      try {
        if (_disposed || epoch != _epoch) throw StateError('Source changed.');
        final scan = _scanJobs[jobKey];
        if (scan != null) {
          scan.requestYield();
          try {
            await scan.done.future;
          } catch (_) {
            // The foreground job reloads the durable generation independently.
          }
        }
        snapshot;
        final freshOwner = _owners[id];
        if (freshOwner == null || freshOwner.$1.catalog.rootPath != root) {
          throw StateError('Source changed.');
        }
        final localCatalog = freshOwner.$1.catalog;
        final before = localCatalog.snapshot;
        final patch = await _materializeInWorker(
          root,
          state,
          owner.$2.id,
          localCatalog.publication,
        );
        if (_disposed || epoch != _epoch) throw StateError('Source changed.');
        if (await localCatalog.applyMaterialization(patch)) {
          if (!identical(before, localCatalog.snapshot)) {
            _patchCombined(owner.$1.id, patch.entry, before);
            notifyListeners();
          }
        } else {
          await _adoptCatalog(
            owner.$1.id,
            patch.fallback ?? await _openInWorker(root, state),
          );
        }
        snapshot;
        final current = _owners[id];
        final committed = current == null
            ? null
            : await current.$1.catalog.readyIfUnchanged(current.$2.id);
        if (committed == null ||
            (revision != null && committed.currentRevisionId != revision)) {
          throw StateError('Source revision changed.');
        }
        result.complete(committed);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    _foregroundTasks[jobKey] = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_foregroundTasks[jobKey], task)) {
          _foregroundTasks.remove(jobKey);
        }
      }),
    );
    return result.future;
  }

  /// Bulk host path shares the scan-yield queue and one worker per source.
  Future<Map<String, LibraryEntry>> prepareManyForRead(
    Map<String, String> selected,
  ) async {
    if (selected.isEmpty || selected.length > 64) {
      throw ArgumentError('Invalid preparation batch.');
    }
    final epoch = _epoch;
    snapshot;
    final groups = <String, Map<String, String>>{};
    for (final request in selected.entries) {
      final owner = _owners[request.key];
      if (owner != null &&
          owner.$1.online &&
          owner.$2.currentRevisionId == request.value) {
        (groups[owner.$1.id] ??= {})[request.key] = request.value;
      }
    }
    final ready = <String, LibraryEntry>{};
    for (final group in groups.entries) {
      final pending = <String, String>{};
      for (final request in group.value.entries) {
        final owner = _owners[request.key]!;
        try {
          final entry = await owner.$1.catalog.readyIfUnchanged(owner.$2.id);
          if (_disposed || epoch != _epoch) {
            throw StateError('Source changed.');
          }
          if (entry != null) {
            ready[request.key] = entry;
          } else {
            pending[request.key] = request.value;
          }
        } catch (_) {
          /* Worker reports this file without aborting siblings. */
          pending[request.key] = request.value;
        }
      }
      if (_disposed || epoch != _epoch) {
        throw StateError('Source changed.');
      }
      if (pending.isEmpty) continue;
      final owner = _owners[pending.keys.first]!;
      final root = owner.$1.catalog.rootPath,
          state = owner.$1.catalog.statePath;
      final key = _catalogJobKey(state);
      final result = Completer<void>();
      final previous = _foregroundTasks[key] ?? Future<void>.value();
      late Future<void> task;
      task = previous.catchError((Object _) {}).then((_) async {
        try {
          if (_disposed || epoch != _epoch) throw StateError('Source changed.');
          final scan = _scanJobs[key];
          if (scan != null) {
            scan.requestYield();
            try {
              await scan.done.future;
            } catch (_) {
              /* Reload durable base. */
            }
          }
          snapshot;
          final fresh = _owners[pending.keys.first];
          if (fresh == null || fresh.$1.catalog.rootPath != root) {
            throw StateError('Source changed.');
          }
          final local = fresh.$1.catalog, before = fresh.$1.catalog.snapshot;
          final localSelected = <String, String>{};
          for (final request in pending.entries) {
            final current = _owners[request.key];
            if (current != null &&
                current.$1.id == group.key &&
                current.$2.currentRevisionId == request.value) {
              localSelected[current.$2.id] = request.value;
            }
          }
          if (localSelected.isNotEmpty) {
            final patch = await _materializeManyInWorker(
              root,
              state,
              localSelected,
              local.publication,
            );
            if (_disposed || epoch != _epoch) {
              throw StateError('Source changed.');
            }
            if (await local.applyBatchMaterialization(patch)) {
              if (!identical(before, local.snapshot)) {
                _patchCombinedMany(group.key, patch.entries.values, before);
                notifyListeners();
              }
            } else {
              await _adoptCatalog(
                group.key,
                patch.fallback ?? await _openInWorker(root, state),
              );
            }
            snapshot;
            for (final request in pending.entries) {
              final current = _owners[request.key];
              if (current == null ||
                  current.$2.currentRevisionId != request.value) {
                continue;
              }
              try {
                final entry = await current.$1.catalog.readyIfUnchanged(
                  current.$2.id,
                );
                if (entry != null) ready[request.key] = entry;
              } catch (_) {
                /* Keep successful siblings. */
              }
            }
          }
          result.complete();
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      });
      _foregroundTasks[key] = task;
      unawaited(
        task.whenComplete(() {
          if (identical(_foregroundTasks[key], task)) {
            _foregroundTasks.remove(key);
          }
        }),
      );
      await result.future;
    }
    return ready;
  }

  void _patchCombined(
    String sourceId,
    LibraryEntry entry,
    LibrarySnapshot base,
  ) => _patchCombinedMany(sourceId, [entry], base);

  void _patchCombinedMany(
    String sourceId,
    Iterable<LibraryEntry> entries,
    LibrarySnapshot base,
  ) {
    if (_combined == null) return;
    final currentSources = sources;
    final beforeKeys = [
      for (final s in currentSources)
        (s.id, s.id == sourceId ? base : s.catalog.snapshot, s.name, s.online),
    ];
    if (!listEquals(beforeKeys, _indexedSources)) {
      _combined = null;
      return;
    }
    final source = currentSources.firstWhere((s) => s.id == sourceId);
    final replacements = <String, LibraryEntry>{};
    for (final entry in entries) {
      final external = _external(source, entry);
      replacements[external.id] = external;
      _owners[external.id] = (source, entry);
      _externalEntries[external.id] = external;
      _searchText[external.id] = '${source.name}/${entry.relativePath}'
          .toLowerCase();
    }
    _combined = _combined!.replacingEntries(
      replacements.values,
      generation: currentSources.fold(
        0,
        (n, s) => n + s.catalog.snapshot.generation,
      ),
      savedUtc: _catalog!.snapshot.savedUtc,
    );
    _indexedSources = [
      for (final s in currentSources)
        (s.id, s.catalog.snapshot, s.name, s.online),
    ];
    final listingKey = _listingKey;
    if (listingKey != null && _listing != null) {
      _listingKey = (_combined!, listingKey.$2, listingKey.$3);
      _listing = FolderListing(
        folders: _listing!.folders,
        entries: [for (final e in _listing!.entries) replacements[e.id] ?? e],
      );
    }
    final searchKey = _searchKey;
    if (searchKey != null) {
      _searchKey = (
        _combined!,
        searchKey.$2,
        searchKey.$3,
        searchKey.$4,
        searchKey.$5,
      );
      _searchResults = [
        for (final e in _searchResults) replacements[e.id] ?? e,
      ];
    }
  }

  Future<bool> _adoptCatalog(String sourceId, LibraryCatalog candidate) async {
    LibraryCatalog? currentCatalog() {
      for (final source in sources) {
        if (source.id == sourceId &&
            p.equals(source.catalog.rootPath, candidate.rootPath)) {
          return source.catalog;
        }
      }
      return null;
    }

    for (var attempt = 0; ; attempt++) {
      if (_disposed) return false;
      final current = currentCatalog();
      if (current == null) return false;
      final captured = current.publication;
      if (await candidate.matchesDisk()) {
        final currentValid = await current.matchesDisk();
        final candidateValid = await candidate.matchesDisk();
        final live = currentCatalog();
        if (_disposed || live == null) return false;
        if (candidateValid && live.publication.isSameAs(captured)) {
          if (currentValid &&
              current.snapshot.generation > candidate.snapshot.generation) {
            return false;
          }
          break;
        }
      }
      if (attempt == 2) {
        throw const ConcurrentCatalogWriteException(
          'Catalogue is still updating.',
        );
      }
      candidate = await _catalogLoader(candidate.rootPath, candidate.statePath);
    }
    if (_disposed) return false;
    // The exact current token was checked after the final await. A valid lower
    // backup may replace a damaged current publication, while a delayed scan
    // cannot replace a still-valid newer foreground publication.
    final latest = currentCatalog();
    if (latest == null) return false;
    if (latest.publication.isSameAs(candidate.publication)) return true;
    if (sourceId == _primaryId && _catalog?.rootPath == candidate.rootPath) {
      _catalog = candidate;
    } else {
      final matches = _added.where(
        (s) =>
            s.id == sourceId &&
            p.equals(s.catalog.rootPath, candidate.rootPath),
      );
      if (matches.isEmpty) throw StateError('Source changed.');
      matches.single.catalog = candidate;
    }
    storageWarnings = List.unmodifiable({
      ...storageWarnings,
      ...candidate.storageWarnings,
    });
    notifyListeners();
    return true;
  }

  Future<void> validateForRead(String id, String revision) async {
    await ensureReady(id);
    snapshot;
    final owner = _owners[id]!;
    if (owner.$2.currentRevisionId != revision) {
      throw StateError('Source revision changed.');
    }
    await owner.$1.catalog.validatedPathFor(owner.$2);
  }

  void refreshSourceMetadata() {
    if (!_disposed) notifyListeners();
  }

  void setSource(String id) {
    if (!sources.any((s) => s.id == id)) return;
    _browsingSource = id;
    currentFolder = '';
    query = '';
    notifyListeners();
  }

  String get statePath {
    return _stateFor(rootPath!);
  }

  String _stateFor(String sourceRoot) {
    final root = p.normalize(p.absolute(sourceRoot));
    final key = sha256.convert(
      utf8.encode(Platform.isWindows ? root.toLowerCase() : root),
    );
    return p.join(dataDirectory.path, 'catalogs', '$key.json');
  }

  Future<void> initialize() async {
    try {
      await dataDirectory.create(recursive: true);
      final settings = File(
        p.join(dataDirectory.path, 'library-settings.json'),
      );
      Map<String, dynamic>? registry;
      final registryFile = File(
        p.join(dataDirectory.path, 'sources-settings.json'),
      );
      if (await registryFile.exists() ||
          await File('${registryFile.path}.backup').exists()) {
        try {
          registry = Map<String, dynamic>.from(
            jsonDecode(await registryFile.readAsString()) as Map,
          );
        } catch (_) {
          registry = Map<String, dynamic>.from(
            jsonDecode(await File('${registryFile.path}.backup').readAsString())
                as Map,
          );
          storageWarnings = ['谱库设置已从备份恢复，请检查最近添加的文件夹。'];
        }
        if (registry['schema'] != 1) {
          throw const FormatException('Invalid source settings.');
        }
        if (registry['primaryMetadataOnly'] == true &&
            !RegExp(r'^[a-f0-9]{32}$')
                .hasMatch(registry['primaryId'] as String? ?? '')) {
          throw const FormatException('Invalid stable source identity.');
        }
      }
      String? restoredRoot;
      if (await settings.exists()) {
        final json =
            jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
        if (json['version'] != 1 || json['rootPath'] is! String) {
          throw const FormatException('谱库设置格式无法识别');
        }
        restoredRoot = json['rootPath'] as String;
      }
      restoredRoot = registry?['primaryRoot'] as String? ?? restoredRoot;
      if (restoredRoot != null) {
        final same = registry?['primaryRoot'] == restoredRoot;
        await selectRoot(
          restoredRoot,
          persist: false,
          metadataOnly: same && registry?['primaryMetadataOnly'] == true,
          sourceId: same ? (registry?['primaryId'] as String?) : null,
          background: same && registry?['primaryMetadataOnly'] == true,
        );
      }
      if (registry != null) {
        for (final raw in registry['sources'] as List) {
          final item = Map<String, dynamic>.from(raw as Map);
          if (!RegExp(r'^[a-f0-9]{32}$')
                  .hasMatch(item['id'] as String? ?? '') ||
              !p.isAbsolute(item['root'] as String)) {
            throw const FormatException('Invalid registered source.');
          }
          final catalog = await _openInWorker(
            item['root'] as String,
            _stateFor(item['root'] as String),
          );
          final added = _AddedSource(
            item['id'] as String,
            item['name'] as String,
            item['root'] as String,
            catalog,
          );
          added.online = await Directory(added.root).exists();
          _added.add(added);
          _watchAdded(added);
          unawaited(_refreshAdded(added));
        }
      }
    } catch (failure) {
      debugPrint('LIBRARY restore_failed: $failure');
      error = '无法恢复谱库设置，请重新选择文件夹。';
    } finally {
      if (!_disposed) {
        initialized = true;
        notifyListeners();
      }
    }
  }

  Future<void> selectRoot(
    String root, {
    bool persist = true,
    bool metadataOnly = false,
    String? sourceId,
    bool background = false,
  }) async {
    final epoch = ++_epoch;
    _debounce?.cancel();
    await _watcher?.cancel();
    _watcher = null;
    if (_disposed || epoch != _epoch) return;
    rootPath = p.normalize(p.absolute(root));
    _primaryMetadataOnly = metadataOnly;
    _primaryId = metadataOnly ? sourceId ?? _newSourceId() : 'legacy';
    _primaryOnline = await Directory(rootPath!).exists();
    _browsingSource = _primaryId;
    _catalog = null;
    currentFolder = '';
    query = '';
    error = null;
    watchWarning = null;
    lastScan = null;
    lastScanDuration = null;
    storageWarnings = const [];
    _scanQueued = false;
    _verifyQueued = false;
    _queuedFullScan = false; _queuedDirtyPaths.clear(); _watchDirty.clear();
    notifyListeners();
    try {
      if (persist) await _saveRegistry();
      final catalog = await _openInWorker(rootPath!, statePath);
      if (_disposed || epoch != _epoch) return;
      _catalog = catalog;
      storageWarnings = catalog.storageWarnings;
      if (persist) {
        await dataDirectory.create(recursive: true);
        final temporary = File(
          p.join(dataDirectory.path, 'library-settings.$epoch.tmp'),
        );
        await temporary.writeAsString(
          jsonEncode({'version': 1, 'rootPath': rootPath}),
          flush: true,
        );
        if (_disposed || epoch != _epoch) {
          await temporary.delete();
          return;
        }
        await temporary.rename(
          p.join(dataDirectory.path, 'library-settings.json'),
        );
      }
      if (_disposed || epoch != _epoch) return;
      _startWatcher();
      if (background) {
        unawaited(rescan());
      } else {
        await rescan();
      }
    } catch (failure) {
      if (_disposed || epoch != _epoch) return;
      debugPrint('LIBRARY open_failed: $failure');
      error = '无法打开谱库，请检查文件夹连接与应用存储。';
      notifyListeners();
    }
  }

  static String _newSourceId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<void> _saveRegistry() =>
      _registryWrites = (_registryWrites ?? Future<void>.value())
          .catchError((Object _) {})
          .then((_) async {
            final target = File(
              p.join(dataDirectory.path, 'sources-settings.json'),
            );
            final temp = File('${target.path}.tmp');
            await dataDirectory.create(recursive: true);
            await temp.writeAsString(
              jsonEncode({
                'schema': 1,
                'primaryRoot': rootPath,
                'primaryId': _primaryId,
                'primaryMetadataOnly': _primaryMetadataOnly,
                'sources': [
                  for (final s in _added)
                    {'id': s.id, 'name': s.name, 'root': s.root},
                ],
              }),
              flush: true,
            );
            if (await target.exists()) {
              try {
                jsonDecode(await target.readAsString());
                await target.copy('${target.path}.backup');
              } on FormatException {
                await target.rename('${target.path}.corrupt');
              }
            }
            await temp.rename(target.path);
          });

  Future<void> addSource(String root) async {
    final normalized = p.normalize(p.absolute(root));
    final actual = p.normalize(
      await Directory(normalized).resolveSymbolicLinks(),
    );
    for (final s in sources) {
      if (p.equals(s.catalog.rootPath, actual)) {
        setSource(s.id);
        return;
      }
    }
    if (rootPath == null) {
      await selectRoot(normalized, metadataOnly: true);
      return;
    }
    final base = p.basename(normalized);
    var name = base, suffix = 2;
    while (sources.any((s) => s.name == name)) {
      name = '$base (${suffix++})';
    }
    final catalog = await _openInWorker(normalized, _stateFor(normalized));
    final source = _AddedSource(_newSourceId(), name, normalized, catalog);
    final priorBrowse = _browsingSource;
    _added.add(source);
    _browsingSource = source.id;
    currentFolder = '';
    query = '';
    try {
      await _saveRegistry();
    } catch (_) {
      _added.remove(source);
      _browsingSource = priorBrowse;
      rethrow;
    }
    _watchAdded(source);
    notifyListeners();
    unawaited(_refreshAdded(source));
  }

  void _watchAdded(_AddedSource source) {
    if (!watchSource) return;
    try {
      source.watcher = Directory(source.root)
          .watch(recursive: true)
          .listen(
            (event) => _watchEvent(source.id, source.root, event),
            onError: (Object _) {
              source.online = false;
              if (!_disposed) notifyListeners();
            },
          );
    } catch (_) {
      source.online = false;
    }
  }

  Future<void> _refreshAdded(
    _AddedSource source, {
    bool verifyAll = false,
    Set<String>? dirtyPaths,
  }) async {
    if (_disposed) return;
    void retain() {
      source.refreshQueued = true;
      source.verifyQueued = source.verifyQueued || verifyAll;
      if (dirtyPaths == null) { source.fullScanQueued = true; }
      else { source.dirtyQueued.addAll(dirtyPaths); }
    }
    if (source.running) { retain(); return; }
    source.running = true;
    source.retry?.cancel();
    source.retry = null;
    source.verifyQueued = false;
    source.refreshQueued = false; source.fullScanQueued = false; source.dirtyQueued.clear();
    _extraJobs++;
    notifyListeners();
    try {
      source.online = await Directory(source.root).exists();
      if (!source.online) { retain(); return; }
      final packet = dirtyPaths != null && !verifyAll
          ? await _cooperativeScan(source.root, source.catalog.statePath, false, true, dirtyPaths)
          : verifyAll
          ? await _scanInWorker(
              source.catalog.rootPath,
              source.catalog.statePath,
              true,
            )
          : await _scanMetadata(
              source.catalog.rootPath,
              source.catalog.statePath,
            );
      if (_disposed) return;
      await _adoptCatalog(source.id, packet.catalog!);
    } on CatalogScanYielded {
      retain();
      if (!_disposed) {
        source.retry = Timer(
          const Duration(milliseconds: 250),
          () =>
              unawaited(_refreshAdded(source, verifyAll: source.verifyQueued,
                dirtyPaths: source.fullScanQueued ? null : Set.of(source.dirtyQueued))),
        );
      }
    } catch (failure) {
      retain();
      debugPrint('LIBRARY added_scan_failed: $failure');
      error = '有谱库无法刷新，请检查连接后重试。';
    } finally {
      source.running = false;
      _extraJobs--;
      if (!_disposed) notifyListeners();
      if (source.refreshQueued && source.retry == null && !_disposed) {
        source.retry = Timer(const Duration(milliseconds: 650), () => unawaited(
          _refreshAdded(source, verifyAll: source.verifyQueued,
            dirtyPaths: source.fullScanQueued ? null : Set.of(source.dirtyQueued))));
      }
    }
  }

  void _startWatcher() {
    if (!watchSource || rootPath == null) return;
    try {
      _watcher = Directory(rootPath!)
          .watch(recursive: true)
          .listen(
            (event) => _watchEvent(_primaryId, rootPath!, event),
            onError: (Object failure) {
              if (_disposed) return;
              debugPrint('LIBRARY watch_failed: $failure');
              watchWarning = '自动刷新不可用，请手动刷新。';
              notifyListeners();
            },
          );
    } catch (failure) {
      debugPrint('LIBRARY watch_failed: $failure');
      watchWarning = '自动刷新不可用，请手动刷新。';
    }
  }

  void _watchEvent(String sourceId, String root, FileSystemEvent event) {
    if (_disposed) return;
    Set<String>? paths;
    String? relative(String absolute) {
      final actual = p.normalize(p.absolute(absolute));
      if (!p.isWithin(root, actual) && !p.equals(root, actual)) return null;
      return p.relative(actual, from: root).split(p.separator).join('/').replaceFirst(RegExp(r'^\.$'), '');
    }
    final first = relative(event.path);
    if (first != null) {
      paths = {first};
      if (event is FileSystemMoveEvent) {
        final destination = event.destination;
        final target = destination == null ? null : relative(destination);
        if (target == null) { paths = null; } else { paths.add(target); }
      }
    }
    if (_watchDirty.containsKey(sourceId)) {
      final prior = _watchDirty[sourceId];
      paths = prior == null || paths == null ? null : {...prior, ...paths};
    }
    if (paths != null && paths.length > 256) paths = null;
    _watchDirty[sourceId] = paths;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), () => unawaited(_drainWatchChanges()));
  }

  Future<void> _drainWatchChanges() async {
    final changes = Map<String, Set<String>?>.of(_watchDirty); _watchDirty.clear();
    for (final change in changes.entries) {
      if (_disposed) return;
      if (change.key == _primaryId) {
        await _rescanPrimary(includeAdded: false, dirtyPaths: change.value);
      } else {
        final source = _added.where((s) => s.id == change.key).firstOrNull;
        if (source != null) await _refreshAdded(source, dirtyPaths: change.value);
      }
    }
  }

  void scheduleRescan() {
    if (_disposed || rootPath == null) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 650),
      () { _watchDirty.clear(); unawaited(rescan()); },
    );
  }

  Future<void> rescan({bool verifyAll = false}) async {
    if (verifyAll && selectedSourceId != _primaryId) {
      for (final source in _added) {
        if (source.id == selectedSourceId) {
          await _refreshAdded(source, verifyAll: true);
          return;
        }
      }
    }
    await _rescanPrimary(verifyAll: verifyAll);
  }

  /// An explicit host import needs its source's adopted index before replying.
  /// Use the existing scan queue, including its foreground-read yield policy.
  Future<void> refreshImportedSource(String sourceId, {String? relativePath}) async {
    bool sourceScanning() => sourceId == _primaryId
        ? _scanningEpoch == _epoch || _scanQueued
        : _added.any(
            (s) =>
                s.id == sourceId &&
                (s.running || s.retry != null || s.verifyQueued),
          );
    Future<void> waitForIdle() async {
      if (!sourceScanning() || _disposed) return;
      final done = Completer<void>();
      _importScanWaiters.add(done);
      void changed() {
        if ((!sourceScanning() || _disposed) && !done.isCompleted) {
          done.complete();
        }
      }

      addListener(changed);
      try {
        changed();
        await done.future;
      } finally {
        _importScanWaiters.remove(done);
        removeListener(changed);
      }
    }

    await waitForIdle();
    if (_disposed) throw StateError('Library closed.');
    if (sourceId == _primaryId) {
      await _rescanPrimary(includeAdded: false, dirtyPaths: relativePath == null ? null : {relativePath});
    } else {
      final source = _added.where((s) => s.id == sourceId).firstOrNull;
      if (source == null) throw StateError('Source removed.');
      await _refreshAdded(source, dirtyPaths: relativePath == null ? null : {relativePath});
    }
    await waitForIdle();
    if (_disposed || !sources.any((s) => s.id == sourceId && s.online)) {
      throw StateError('Source unavailable.');
    }
  }

  Future<void> _rescanPrimary({
    bool verifyAll = false,
    bool includeAdded = true,
    Set<String>? dirtyPaths,
  }) async {
    if (_disposed || rootPath == null || _catalog == null) return;
    void retain() {
      _scanQueued = true; _verifyQueued = _verifyQueued || verifyAll;
      if (dirtyPaths == null) { _queuedFullScan = true; }
      else { _queuedDirtyPaths.addAll(dirtyPaths); }
    }
    if (_scanningEpoch == _epoch) { retain(); return; }
    final epoch = _epoch;
    final root = _catalog!.rootPath;
    final state = _catalog!.statePath;
    _scanningEpoch = epoch;
    error = null;
    notifyListeners();
    try {
      _primaryOnline = await Directory(root).exists();
      if (!_primaryOnline) {
        if (dirtyPaths != null) {
          if (!_watchDirty.containsKey(_primaryId) || _watchDirty[_primaryId] != null) {
            _watchDirty[_primaryId] = {...?_watchDirty[_primaryId], ...dirtyPaths};
          }
        }
        for (final source in _added.toList()) {
          await _refreshAdded(source);
        }
        return;
      }
      final LibraryScanPacket packet;
      if (dirtyPaths != null && !verifyAll) {
        packet = await _cooperativeScan(root, state, false, true, dirtyPaths);
      } else if (_primaryMetadataOnly && !verifyAll) {
        packet = await _scanMetadata(root, state);
      } else {
        packet = await _scanRunner(root, state, verifyAll);
      }
      if (_disposed || epoch != _epoch) return;
      final refreshed = packet.catalog ?? await _openInWorker(root, state);
      if (_disposed || epoch != _epoch) return;
      if (!await _adoptCatalog(_primaryId, refreshed)) return;
      if (_catalog!.snapshot.generation != packet.result.snapshot.generation) {
        return;
      }
      lastScan = packet.result;
      lastScanDuration = packet.elapsed;
      storageWarnings = List.unmodifiable({
        ...storageWarnings,
        ...packet.storageWarnings,
        ...refreshed.storageWarnings,
      });
      for (final warning in storageWarnings) {
        debugPrint('LIBRARY storage_warning: $warning');
      }
      for (final issue in packet.result.issues) {
        debugPrint(
          'LIBRARY issue ${issue.relativePath} ${issue.stage}: ${issue.message}',
        );
      }
      if (!folders.contains(currentFolder)) currentFolder = '';
      debugPrint(
        'LIBRARY scanned files=$totalCount folders=${folders.length - 1} elapsed_ms=${packet.elapsed.inMilliseconds} issues=${packet.result.issues.length}',
      );
    } on CatalogScanYielded {
      retain();
    } catch (failure) {
      if (dirtyPaths != null) {
        if (!_watchDirty.containsKey(_primaryId) || _watchDirty[_primaryId] != null) {
          _watchDirty[_primaryId] = {...?_watchDirty[_primaryId], ...dirtyPaths};
        }
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 1), () => unawaited(_drainWatchChanges()));
      }
      debugPrint('LIBRARY scan_failed: $failure');
      if (!_disposed && epoch == _epoch) {
        error = '刷新失败，请检查连接后重试。';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        _scanningEpoch = null;
        notifyListeners();
        if (_scanQueued) {
          final verify = _verifyQueued;
          final queued = _queuedFullScan ? null : Set<String>.of(_queuedDirtyPaths);
          _scanQueued = false; _verifyQueued = false; _queuedFullScan = false; _queuedDirtyPaths.clear();
          unawaited(_rescanPrimary(verifyAll: verify, includeAdded: includeAdded, dirtyPaths: queued));
        }
      }
    }
    if (includeAdded) {
      for (final source in _added.toList()) {
        await _refreshAdded(source);
      }
    }
  }

  void setFolder(String folder) {
    if (!folders.contains(folder)) return;
    currentFolder = folder;
    notifyListeners();
  }

  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  void setSearchScope(bool withinFolder) {
    searchCurrentFolder = withinFolder;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final waiter in _importScanWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _epoch++;
    _debounce?.cancel();
    unawaited(_watcher?.cancel());
    for (final s in _added) {
      s.retry?.cancel();
      _scanJobs[_catalogJobKey(s.catalog.statePath)]?.requestYield();
      unawaited(s.watcher?.cancel());
    }
    if (_catalog != null) {
      _scanJobs[_catalogJobKey(_catalog!.statePath)]?.requestYield();
    }
    super.dispose();
  }
}
