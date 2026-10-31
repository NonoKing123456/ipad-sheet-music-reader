import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;

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
  final catalog = await LibraryCatalog.open(rootPath: root, statePath: state);
  final result = await catalog.rescan(verifyAll: verify);
  return LibraryScanPacket(result, catalog.storageWarnings, watch.elapsed);
}

Future<LibraryScanPacket> _scanInWorker(
  String root,
  String state,
  bool verify,
) => Isolate.run(() => _scanFiles(root, state, verify));

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

  bool get scanning => _scanningEpoch == _epoch;
  LibrarySnapshot? get snapshot => _catalog?.snapshot;

  /// The sync adapter resolves this on every request after scans replace it.
  LibraryCatalog? get catalogForSync => _catalog;
  int get totalCount => snapshot?.availableEntries.length ?? 0;
  bool get searching => query.trim().isNotEmpty;
  List<String> get folders => snapshot?.folders ?? const [''];

  FolderListing get listing =>
      _catalog?.listFolder(currentFolder) ??
      FolderListing(folders: [], entries: []);

  List<LibraryEntry> get visibleEntries => searching
      ? (_catalog?.search(
              query,
              withinFolder: searchCurrentFolder ? currentFolder : null,
            ) ??
            [])
      : listing.entries;

  String absolutePathFor(LibraryEntry entry) =>
      _catalog!.absolutePathFor(entry);

  String get statePath {
    final root = p.normalize(p.absolute(rootPath!));
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
      if (await settings.exists()) {
        final json =
            jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
        if (json['version'] != 1 || json['rootPath'] is! String) {
          throw const FormatException('谱库设置格式无法识别');
        }
        await selectRoot(json['rootPath'] as String, persist: false);
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

  Future<void> selectRoot(String root, {bool persist = true}) async {
    final epoch = ++_epoch;
    _debounce?.cancel();
    await _watcher?.cancel();
    _watcher = null;
    if (_disposed || epoch != _epoch) return;
    rootPath = p.normalize(p.absolute(root));
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
      final catalog = await LibraryCatalog.open(
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
      await rescan();
    } catch (failure) {
      if (_disposed || epoch != _epoch) return;
      debugPrint('LIBRARY open_failed: $failure');
      error = '无法打开谱库。请确认文件夹仍可访问、应用数据目录可写，或重新选择文件夹。已有索引未被清空。';
      notifyListeners();
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
    if (_disposed || rootPath == null || _catalog == null) return;
    if (scanning) {
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
      final packet = await _scanRunner(root, state, verifyAll);
      if (_disposed || epoch != _epoch) return;
      final refreshed = await LibraryCatalog.open(
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
          unawaited(rescan(verifyAll: verify));
        }
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
    _epoch++;
    _debounce?.cancel();
    unawaited(_watcher?.cancel());
    super.dispose();
  }
}
