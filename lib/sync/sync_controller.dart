import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;

import '../library/library_controller.dart';
import '../reader/reader_session.dart';
import '../reader/reader_workspace.dart';

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

/// App-private orchestration. The protocol and domain stores own durable data.
class SyncController extends ChangeNotifier {
  SyncController({
    required this.library,
    required this.workspace,
    this.ioTimeout = const Duration(seconds: 30),
    this.bindAddress,
  }) {
    library.addListener(_libraryChanged);
    workspace.addListener(_workspaceChanged);
  }
  final LibraryController library;
  final ReaderWorkspace workspace;
  final Duration ioTimeout;

  /// Tests may restrict the listener to loopback; production binds IPv4 LAN.
  final InternetAddress? bindAddress;
  Directory get directory =>
      Directory(p.join(library.dataDirectory.path, 'sync'));
  File get _settingsFile => File(p.join(directory.path, 'settings.json'));
  Map<String, dynamic> _settings = {'version': 1, 'roots': <String, dynamic>{}};
  SyncServer? _server;
  SyncClient? _client;
  SyncCancellation? _cancellation;
  String? _serverRoot;
  bool _disposed = false;
  bool _serverBusy = false;
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
  SyncPhase phase = SyncPhase.idle;
  String? message;
  String? initializationError;
  String? serverMessage;
  String? pairingCode;
  DateTime? pairingExpires;
  List<Uri> addresses = const [];
  bool get serving => _server != null;
  bool get serverBusy => _serverBusy;
  bool get paired => _client != null;
  Uri? get computerAddress => _client?.baseUri;
  int? get port => _server?.port;
  int get receivedObjects => _received;
  bool get hasOfflineLibrary => replica?.manifest != null;
  int get offlineCount =>
      replica?.snapshot.availableEntries
          .where((e) => e.availability == ContentAvailability.ready)
          .length ??
      0;
  bool get hasUnsavedEdits => workspace.pending.isNotEmpty || workspace.saving;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      await directory.create(recursive: true);
    } catch (_) {
      initializationError = '无法准备同步资料目录，请检查磁盘空间与写入权限。';
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
          }
        } catch (_) {
          message = '上次的电脑配对资料无法读取，请重新配对；已保存的离线谱库仍可使用。';
        }
      }
    }
    // Offline content must not depend on credentials or settings being readable.
    try {
      replica = await ReplicaLibraryView.open(
        rootDirectory: p.join(directory.path, 'replica'),
      );
    } catch (_) {
      initializationError =
          '${initializationError == null ? '' : '${initializationError!}\n'}离线谱库无法恢复，已有文件未被清空。请检查数据目录后重试。';
    }
    _seenReaderGeneration = workspace.store.snapshot.generation;
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
    initialized = true;
    _changed();
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
    if (_serverRoot != null && library.rootPath != _serverRoot) {
      unawaited(stopServer(reason: '谱库目录已切换，无线服务已关闭。请在新谱库中重新开启。'));
    }
  }

  void _workspaceChanged() {
    if (serving && workspace.unsavedCount > 0) {
      unawaited(stopServer(reason: '有笔迹未保存，无线服务已关闭。请重试保存后重新开启。'));
    }
  }

  void _tick() {
    if (_disposed) return;
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
    }
  }

  Future<void> refreshAddresses() async {
    final port = _server?.port;
    if (port == null) return;
    final hosts = <String>{};
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) hosts.add(address.address);
        }
      }
    } catch (_) {
      /* Loopback remains available for same-computer testing. */
    }
    addresses = [
      for (final host in hosts) Uri(scheme: 'http', host: host, port: port),
      Uri(scheme: 'http', host: '127.0.0.1', port: port),
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
    busy = true;
    phase = SyncPhase.pairing;
    message = '正在连接电脑…';
    _changed();
    try {
      final folder = _newId();
      final client = await SyncClient.pair(
        baseUri: uri,
        code: code.trim(),
        stateDirectory: p.join(directory.path, 'clients', folder),
        ioTimeout: ioTimeout,
      );
      await _saveSettings({..._settings, 'clientFolder': folder});
      _client = client;
      phase = SyncPhase.idle;
      message = '已配对。点击同步，下载全库并交换批注和曲单。';
    } on SyncProtocolException catch (failure) {
      phase = SyncPhase.failed;
      message = failure.status == 403
          ? '配对码无效、已使用或已过期，请在电脑刷新配对码后重试。'
          : '电脑拒绝配对，请检查服务状态后重试。';
    } catch (_) {
      phase = SyncPhase.failed;
      message = '连接失败。请检查电脑地址、同一Wi-Fi、电脑服务和局域网权限，再重试。';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> synchronize() async {
    if (busy || _client == null || replica == null) return;
    if (hasUnsavedEdits) {
      message = '请先等待保存完成或重试未保存笔迹；本次没有开始同步。';
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
    message = '正在核对并接收全库…';
    final cancellation = SyncCancellation();
    _cancellation = cancellation;
    _changed();
    try {
      final result = await _client!.syncLibrary(
        replica!,
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
            '${_libraryFailureMessage(result.failure)}${hasOfflineLibrary ? '仍可阅读上次完整离线库。' : '尚未建立完整离线库。'}已完整接收的文件可在重试时复用。';
        return;
      }
      if (hasUnsavedEdits) {
        phase = SyncPhase.partial;
        message = '全库已完整下载，但有正在保存或未保存的笔迹，批注和曲单尚未交换。请保存后再同步。';
        return;
      }
      phase = SyncPhase.merging;
      message = '全库已下载，正在交换批注和曲单…';
      _changed();
      await _client!.syncReaderState(
        workspace.store,
        cancellation: cancellation,
        afterMerge: () async {
          workspace.refreshFromStore();
        },
      );
      cancellation.check();
      if (hasUnsavedEdits) {
        phase = SyncPhase.partial;
        message = '全库已完整下载，本次已保存记录已交换；仍有正在保存或未保存的笔迹，请保存后再次同步。';
        return;
      }
      phase = SyncPhase.complete;
      message =
          '全库已完整同步，可离线阅读。${workspace.store.snapshot.conflicts.isEmpty ? '本次批注和曲单交换已完成；同步期间的新编辑请再次同步。' : '有待处理的批注或曲单版本，双方内容均已保留。'}';
    } catch (_) {
      phase = cancellation.isCancelled
          ? SyncPhase.cancelled
          : SyncPhase.partial;
      message =
          '${cancellation.isCancelled ? '同步已取消' : '批注和曲单交换尚未完成'}。完整离线库仍保留；请重试，未确认的交换会继续恢复。';
    } finally {
      workspace.refreshFromStore();
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
        LibrarySyncFailure.connection => '本次全库同步未完成，请检查电脑服务、Wi-Fi与局域网权限后重试。',
        LibrarySyncFailure.authentication => '电脑未接受现有配对，请刷新配对码并重新配对。',
        LibrarySyncFailure.integrity => '收到的文件未通过完整性校验，请刷新电脑谱库后重试。',
        LibrarySyncFailure.localStorage => '离线文件无法保存，请检查磁盘空间与应用数据目录权限后重试。',
        LibrarySyncFailure.cancelled => '本次同步已取消。',
        LibrarySyncFailure.unknown || null => '本次全库同步未完成，请检查电脑与网络后重试。',
      };

  void cancel() {
    _cancellation?.cancel();
  }

  Future<void> verifyOfflineLibrary() async {
    if (busy || replica == null) return;
    busy = true;
    phase = SyncPhase.verifying;
    message = '正在完整校验离线文件，较大谱库需要一些时间…';
    _changed();
    try {
      await replica!.verifyAll();
      phase = SyncPhase.idle;
      final unavailable = replica!.snapshot.availableEntries
          .where((e) => e.availability != ContentAvailability.ready)
          .length;
      message = unavailable == 0
          ? '离线文件校验完成。'
          : '$unavailable 份离线文件无法读取，请重新同步修复。';
    } catch (_) {
      phase = SyncPhase.failed;
      message = '离线文件校验失败，已有资料未被清空，请重试或重新同步。';
    } finally {
      busy = false;
      _changed();
    }
  }

  ScoreTarget? locateOffline(String entryId) {
    final view = replica;
    final entry = view?.snapshot.entryById(entryId);
    if (view == null ||
        entry == null ||
        entry.status != EntryStatus.available ||
        entry.availability != ContentAvailability.ready) {
      return null;
    }
    return ScoreTarget(
      entryId: entry.id,
      revisionId: entry.currentRevisionId,
      filePath: view.absolutePathFor(entry),
      displayPath: entry.relativePath,
      contentHash: entry.currentRevision.contentHash,
      verifiedImmutable: true,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _cancellation?.cancel();
    library.removeListener(_libraryChanged);
    workspace.removeListener(_workspaceChanged);
    unawaited(stopServer());
    super.dispose();
  }
}
