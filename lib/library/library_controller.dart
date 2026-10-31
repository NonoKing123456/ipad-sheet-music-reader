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

class LibraryScanPacket {
  const LibraryScanPacket(this.result, this.storageWarnings, this.elapsed);
  final ScanResult result;
  final List<String> storageWarnings;
  final Duration elapsed;
}

typedef LibraryScanRunner = Future<LibraryScanPacket> Function(
  String rootPath,
  String statePath,
  bool verifyAll,
);

Future<LibraryScanPacket> _scanFiles(
  String root,
  String state,
  bool verify,
) async {
  final watch = Stopwatch()..start();
  final catalog = await LibraryCatalog.open(
    rootPath: root,
    statePath: state,
    fileIdentityResolver: windowsFileIdentity,
  );
  final result = await catalog.rescan(verifyAll: verify);
  return LibraryScanPacket(result, catalog.storageWarnings, watch.elapsed);
}

Future<LibraryScanPacket> _scanInWorker(
  String root,
  String state,
  bool verify,
) => Isolate.run(() => _scanFiles(root, state, verify));

Future<LibraryScanPacket> _scanMetadata(String root, String state) =>
    Isolate.run(() async {
      final watch = Stopwatch()..start();
      final catalog = await LibraryCatalog.open(
        fileIdentityResolver: windowsFileIdentity,
        rootPath: root,
        statePath: state,
      );
      final result = await catalog.rescan(metadataOnly: true);
      return LibraryScanPacket(result, catalog.storageWarnings, watch.elapsed);
    });

class _AddedSource {
  _AddedSource(this.id, this.name, this.root, this.catalog);
  final String id, name, root;
  LibraryCatalog catalog;
  bool online = true, running = false;
  bool verifyQueued = false;
  StreamSubscription<FileSystemEvent>? watcher;
}

/// File content scanning/hash work runs in a worker isolate. All view queries
/// use the shared library_core snapshot; the UI does not reimplement indexing.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.dataDirectory,
    LibraryScanRunner? scanRunner,
    this.watchSource = true,
  }) : _scanRunner = scanRunner ?? _scanInWorker;

  final Directory dataDirectory;
  final bool watchSource;
  final LibraryScanRunner _scanRunner;
  LibraryCatalog? _catalog;
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _debounce;
  bool _disposed = false;
  int _epoch = 0;
  int? _scanningEpoch;
  bool _scanQueued = false;
  bool _verifyQueued = false;
  final _added = <_AddedSource>[];
  String _primaryId = 'legacy';
  bool _primaryMetadataOnly = false, _primaryOnline = true;
  String? _browsingSource;
  LibrarySnapshot? _combined;
  final _owners = <String, (CatalogSourceBinding, LibraryEntry)>{};
  int _extraJobs = 0;
  Future<void>? _registryWrites;

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
    if (_catalog == null) return null;
    if (_combined != null) return _combined;
    _owners.clear();
    final entries = <LibraryEntry>[];
    for (final source in sources) {
      for (final e in source.catalog.snapshot.entries) {
        final external = _external(source, e);
        _owners[external.id] = (source, e);
        entries.add(external);
      }
    }
    return _combined = LibrarySnapshot(
      rootPath: rootPath!,
      generation: sources.fold(0, (n, s) => n + s.catalog.snapshot.generation),
      entries: entries,
      folders: folders,
      savedUtc: _catalog!.snapshot.savedUtc,
    );
  }

  @override
  void notifyListeners() {
    _combined = null;
    super.notifyListeners();
  }

  /// The sync adapter resolves this on every request after scans replace it.
  LibraryCatalog? get catalogForSync => _catalog;
  int get totalCount => snapshot?.availableEntries.length ?? 0;
  bool get searching => query.trim().isNotEmpty;
  List<String> get folders =>
      selectedSource?.catalog.snapshot.folders ?? const [''];

  FolderListing get listing => selectedSource == null
      ? FolderListing(folders: [], entries: [])
      : FolderListing(
          folders: selectedSource!.catalog.listFolder(currentFolder).folders,
          entries: selectedSource!.catalog
              .listFolder(currentFolder)
              .entries
              .map((e) => _external(selectedSource!, e))
              .toList(),
        );

  List<LibraryEntry> get visibleEntries => searching
      ? (snapshot?.availableEntries.where((entry) {
              final owner = _owners[entry.id]!.$1;
              if (searchCurrentFolder &&
                  (owner.id != selectedSourceId ||
                      !folderContains(currentFolder, entry.relativePath))) {
                return false;
              }
              final text = '${owner.name}/${entry.relativePath}'.toLowerCase();
              return query
                  .toLowerCase()
                  .trim()
                  .split(RegExp(r'\s+'))
                  .every(text.contains);
            }).toList() ??
            [])
      : listing.entries;

  String absolutePathFor(LibraryEntry entry) {
    snapshot;
    final owner = _owners[entry.id]!;
    return owner.$1.catalog.absolutePathFor(owner.$2);
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
    snapshot;
    final owner = _owners[id];
    if (owner == null || !owner.$1.online) {
      throw StateError('Source is offline.');
    }
    await owner.$1.catalog.materialize(owner.$2.id);
    if (!_disposed) notifyListeners();
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
          final catalog = await LibraryCatalog.open(
            fileIdentityResolver: windowsFileIdentity,
            rootPath: item['root'] as String,
            statePath: _stateFor(item['root'] as String),
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
      error = '无法恢复上次的谱库设置，请重新选择文件夹。原谱未被更改。';
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
    notifyListeners();
    try {
      if (persist) await _saveRegistry();
      final catalog = await LibraryCatalog.open(
        fileIdentityResolver: windowsFileIdentity,
        rootPath: rootPath!,
        statePath: statePath,
      );
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
      error = '无法打开谱库。请确认文件夹仍可访问、应用数据目录可写，或重新选择文件夹。已有索引未被清空。';
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
    final catalog = await LibraryCatalog.open(
      fileIdentityResolver: windowsFileIdentity,
      rootPath: normalized,
      statePath: _stateFor(normalized),
    );
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
            (_) => scheduleRescan(),
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
  }) async {
    if (_disposed) return;
    if (source.running) {
      source.verifyQueued = source.verifyQueued || verifyAll;
      return;
    }
    source.running = true;
    _extraJobs++;
    notifyListeners();
    try {
      source.online = await Directory(source.root).exists();
      if (!source.online) return;
      if (verifyAll) {
        await _scanInWorker(source.root, _stateFor(source.root), true);
      } else {
        await _scanMetadata(source.root, _stateFor(source.root));
      }
      source.catalog = await LibraryCatalog.open(
        fileIdentityResolver: windowsFileIdentity,
        rootPath: source.root,
        statePath: _stateFor(source.root),
      );
    } catch (_) {
      error = '有一个谱库暂时无法刷新，已保留上次目录。请连接该文件夹后重试。';
    } finally {
      source.running = false;
      _extraJobs--;
      if (!_disposed) notifyListeners();
      if (source.verifyQueued && !_disposed) {
        source.verifyQueued = false;
        unawaited(_refreshAdded(source, verifyAll: true));
      }
    }
  }

  void _startWatcher() {
    if (!watchSource || rootPath == null) return;
    try {
      _watcher = Directory(rootPath!)
          .watch(recursive: true)
          .listen(
            (_) => scheduleRescan(),
            onError: (Object failure) {
              if (_disposed) return;
              debugPrint('LIBRARY watch_failed: $failure');
              watchWarning = '文件夹变化监听暂时不可用，请点击刷新更新谱库。';
              notifyListeners();
            },
          );
    } catch (failure) {
      debugPrint('LIBRARY watch_failed: $failure');
      watchWarning = '文件夹变化监听暂时不可用，请点击刷新更新谱库。';
    }
  }

  void scheduleRescan() {
    if (_disposed || rootPath == null) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 650),
      () => unawaited(rescan()),
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

  Future<void> _rescanPrimary({bool verifyAll = false}) async {
    if (_disposed || rootPath == null || _catalog == null) return;
    if (_scanningEpoch == _epoch) {
      _scanQueued = true;
      _verifyQueued = _verifyQueued || verifyAll;
      return;
    }
    final epoch = _epoch;
    final root = rootPath!;
    final state = statePath;
    _scanningEpoch = epoch;
    error = null;
    notifyListeners();
    try {
      _primaryOnline = await Directory(root).exists();
      if (!_primaryOnline) {
        for (final source in _added.toList()) {
          await _refreshAdded(source);
        }
        return;
      }
      final LibraryScanPacket packet;
      if (_primaryMetadataOnly && !verifyAll) {
        packet = await _scanMetadata(root, state);
      } else {
        packet = await _scanRunner(root, state, verifyAll);
      }
      if (_disposed || epoch != _epoch) return;
      final refreshed = await LibraryCatalog.open(
        fileIdentityResolver: windowsFileIdentity,
        rootPath: root,
        statePath: state,
      );
      if (_disposed || epoch != _epoch) return;
      _catalog = refreshed;
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
    } catch (failure) {
      debugPrint('LIBRARY scan_failed: $failure');
      if (!_disposed && epoch == _epoch) {
        error = '刷新失败，已保留上次谱库结果。请检查文件夹连接和应用数据目录，再点击刷新。';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        _scanningEpoch = null;
        notifyListeners();
        if (_scanQueued) {
          final verify = _verifyQueued;
          _scanQueued = false;
          _verifyQueued = false;
          unawaited(_rescanPrimary(verifyAll: verify));
        }
      }
    }
    for (final source in _added.toList()) {
      await _refreshAdded(source);
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
    _epoch++;
    _debounce?.cancel();
    unawaited(_watcher?.cancel());
    for (final s in _added) {
      unawaited(s.watcher?.cancel());
    }
    super.dispose();
  }
}
