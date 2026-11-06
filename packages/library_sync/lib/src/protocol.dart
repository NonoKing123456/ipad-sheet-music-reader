import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'manifest.dart';
import 'replica.dart';
import 'storage.dart';
import 'collection.dart';
import 'collection_delta.dart';
import 'collection_replica.dart';
import 'signing_status.dart';
import 'page_metadata.dart';
import 'background_transfer.dart';
import 'small_file_batch.dart';
import 'score_import.dart';

class _SmallBatchPlan {
  _SmallBatchPlan(this.peerId, this.items, this.metadataBytes)
      : expires = DateTime.now().add(const Duration(minutes: 30));
  final String peerId;
  final List<CatalogItem?> items;
  final DateTime expires;
  final int metadataBytes;
}

class SyncProtocolException implements Exception {
  const SyncProtocolException(this.message, [this.status, this.code]);
  final String message;
  final int? status;

  /// Recognized protocol code only; arbitrary peer diagnostics are discarded.
  final String? code;
  @override
  String toString() =>
      'SyncProtocolException: $message${status == null ? '' : ' ($status)'}';
}

class _DifferentLibrary implements Exception {}

LibrarySyncFailure _libraryFailure(Object error) {
  if (error is SyncCancelled) return LibrarySyncFailure.cancelled;
  if (error is _DifferentLibrary) return LibrarySyncFailure.differentLibrary;
  if (error is LibraryContentIntegrityException)
    return LibrarySyncFailure.integrity;
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException) return LibrarySyncFailure.connection;
  if (error is FileSystemException) return LibrarySyncFailure.localStorage;
  if (error is SyncProtocolException) {
    if (error.status == 401 || error.status == 403)
      return LibrarySyncFailure.authentication;
    if (error.status == 503 && error.code == 'source_not_ready')
      return LibrarySyncFailure.sourceNotReady;
  }
  return LibrarySyncFailure.unknown;
}

String _libraryFailureMessage(LibrarySyncFailure failure) => switch (failure) {
      LibrarySyncFailure.differentLibrary =>
        'Replica belongs to another library. Use a new directory.',
      LibrarySyncFailure.sourceNotReady =>
        'Source library is not ready; make all scores readable and retry.',
      LibrarySyncFailure.connection =>
        'Connection interrupted or timed out; retry to resume verified objects.',
      LibrarySyncFailure.authentication =>
        'Authentication failed; pair this device again.',
      LibrarySyncFailure.integrity =>
        'Content verification failed; retry to download complete objects.',
      LibrarySyncFailure.localStorage =>
        'Local storage is unavailable; check space and access, then retry.',
      LibrarySyncFailure.cancelled => 'Sync cancelled.',
      LibrarySyncFailure.unknown =>
        'Library transfer incomplete; retry to resume verified objects.'
    };

Future<Map<String, dynamic>> _readBody(
    Stream<List<int>> stream, Duration timeout, int limit,
    {void Function(int)? onBytesRead}) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(timeout)) {
    if (bytes.length + chunk.length > limit)
      throw const FormatException('Request too large.');
    bytes.addAll(chunk);
  }
  onBytesRead?.call(bytes.length);
  return asMap(jsonDecode(utf8.decode(bytes)));
}

const _catalogPageBytes = 512 * 1024;
const _catalogMaxRecords = 250000;
const _catalogMaxBytes = 128 * 1024 * 1024;

/// One immutable metadata view; never stores a full encoded catalogue or bytes.
class _CatalogTransfer {
  _CatalogTransfer(this.peerId, CollectionIndex current)
      : token = randomId(),
        index = CollectionIndex(
            id: current.id,
            legacyLibraryId: current.legacyLibraryId,
            sources: List.unmodifiable(current.sources),
            entries: List.unmodifiable(current.entries),
            folders: Map.unmodifiable({
              for (final e in current.folders.entries)
                e.key: List<String>.unmodifiable(e.value),
            })),
        folders = [
          for (final source in current.folders.entries)
            for (final folder in source.value) (source.key, folder)
        ];
  final String peerId, token;
  final CollectionIndex index;
  final List<(String, String)> folders;
  Timer? expiry;
  int nextOffset = 0;
  int get totalRecords =>
      1 + index.sources.length + folders.length + index.entries.length;

  Map<String, Object?> _record(int offset) {
    if (offset == 0)
      return {
        'kind': 'header',
        'id': index.id,
        'legacyLibraryId': index.legacyLibraryId,
        'sources': index.sources.length,
        'folders': folders.length,
        'entries': index.entries.length,
      };
    var i = offset - 1;
    if (i < index.sources.length)
      return {
        'kind': 'source',
        'value': index.sources[i].toJson(),
        'hasFolders': index.folders.containsKey(index.sources[i].id),
      };
    i -= index.sources.length;
    if (i < folders.length)
      return {
        'kind': 'folder',
        'sourceId': folders[i].$1,
        'path': folders[i].$2,
      };
    return {
      'kind': 'entry',
      'value': index.entries[i - folders.length].toJson(),
    };
  }

  Uint8List page(int offset) {
    if (offset != nextOffset || offset >= totalRecords) {
      throw const SyncProtocolException('Invalid catalogue offset.', 409);
    }
    final bytes = BytesBuilder(copy: false)
      ..add(utf8.encode('{"protocol":2,"snapshot":${jsonEncode(token)},'
          '"offset":$offset,"totalRecords":$totalRecords,"records":['));
    var end = offset;
    while (end < totalRecords) {
      final record = utf8.encode(jsonEncode(_record(end)));
      // Reserve the comma plus a bounded trailing cursor/complete envelope.
      if (bytes.length + record.length + 128 > _catalogPageBytes) break;
      if (end > offset) bytes.addByte(44);
      bytes.add(record);
      end++;
    }
    if (end == offset) {
      throw const SyncProtocolException('Catalogue record is too large.', 413);
    }
    bytes.add(utf8.encode('],"nextOffset":$end,'
        '"complete":${end == totalRecords}}'));
    nextOffset = end;
    return bytes.takeBytes();
  }
}

/// Parse each bounded response directly into typed records. Publish only the
/// completed view; interruption cannot replace a previously committed index.
class _CatalogAccumulator {
  String? token, id, legacyLibraryId;
  int offset = 0, totalRecords = 0, bytes = 0;
  int sourceCount = 0, folderCount = 0, entryCount = 0;
  final sources = <LibrarySourceInfo>[];
  final folders = <String, List<String>>{};
  final folderKeys = <(String, String)>{};
  final entries = <CatalogItem>[];

  void countBytes(int count) {
    bytes += count;
    if (bytes > _catalogMaxBytes) {
      throw const FormatException('Catalogue exceeds the metadata budget.');
    }
  }

  bool add(Map<String, dynamic> page) {
    final receivedToken = page['snapshot'];
    final declared = page['totalRecords'];
    final records = page['records'] as List;
    final next = page['nextOffset'];
    if (page['protocol'] != 2 ||
        receivedToken is! String ||
        receivedToken.isEmpty ||
        receivedToken.length > 128 ||
        page['offset'] != offset ||
        declared is! int ||
        declared < 1 ||
        declared > _catalogMaxRecords ||
        records.isEmpty ||
        next is! int ||
        next != offset + records.length ||
        next > declared ||
        page['complete'] != (next == declared) ||
        (token != null &&
            (token != receivedToken || totalRecords != declared))) {
      throw const FormatException('Inconsistent catalogue page.');
    }
    token ??= receivedToken;
    totalRecords = declared;
    for (final value in records) {
      final record = asMap(value);
      if (offset == 0) {
        if (record['kind'] != 'header') {
          throw const FormatException('Missing catalogue header.');
        }
        id = record['id'] as String;
        legacyLibraryId = record['legacyLibraryId'] as String?;
        sourceCount = record['sources'] as int;
        folderCount = record['folders'] as int;
        entryCount = record['entries'] as int;
        if (sourceCount < 0 ||
            folderCount < 0 ||
            entryCount < 0 ||
            1 + sourceCount + folderCount + entryCount != totalRecords) {
          throw const FormatException('Invalid catalogue record totals.');
        }
      } else if (offset <= sourceCount) {
        if (record['kind'] != 'source')
          throw const FormatException('Expected source.');
        final source = LibrarySourceInfo.fromJson(asMap(record['value']));
        sources.add(source);
        if (record['hasFolders'] == true) folders[source.id] = [];
      } else if (offset <= sourceCount + folderCount) {
        if (record['kind'] != 'folder')
          throw const FormatException('Expected folder.');
        final source = record['sourceId'] as String,
            path = record['path'] as String;
        if (!folders.containsKey(source))
          throw const FormatException('Unknown folder source.');
        if (!folderKeys.add((source, path)))
          throw const FormatException('Duplicate folder.');
        validatePortablePath(path, folder: true);
        folders[source]!.add(path);
      } else {
        if (record['kind'] != 'entry')
          throw const FormatException('Expected entry.');
        entries.add(CatalogItem.fromJson(asMap(record['value'])));
      }
      offset++;
    }
    return offset == totalRecords;
  }

  CollectionIndex finish() {
    if (offset != totalRecords ||
        id == null ||
        sources.length != sourceCount ||
        folderKeys.length != folderCount ||
        entries.length != entryCount) {
      throw const FormatException('Incomplete catalogue.');
    }
    return CollectionIndex(
        id: id!,
        legacyLibraryId: legacyLibraryId,
        sources: sources,
        entries: entries,
        folders: folders);
  }
}

bool _constantEqual(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var difference = x.length ^ y.length;
  for (var i = 0; i < max(x.length, y.length); i++) {
    difference |= (i < x.length ? x[i] : 0) ^ (i < y.length ? y[i] : 0);
  }
  return difference == 0;
}

class SyncServer {
  SyncServer._(
      this.source,
      this.readerStore,
      this.stateDirectory,
      this._lease,
      this._state,
      this.ioTimeout,
      this.maxJsonBytes,
      this.collectionSource,
      this.catalogSnapshotTtl);
  final LibrarySource source;
  final CollectionLibrarySource? collectionSource;
  final ReaderStateStore readerStore;
  final String stateDirectory;
  final Duration ioTimeout;
  final int maxJsonBytes;
  final Duration catalogSnapshotTtl;
  final _catalogTransfers = <String, _CatalogTransfer>{};
  int get activeCatalogSnapshots => _catalogTransfers.length;
  Future<void> Function(
          String peerId, SigningDeviceStatus status, DateTime receivedAt)?
      onSigningStatus;
  Future<Map<PageMetadataKey, int>> Function(List<PageMetadataKey>)?
      onPageMetadata;
  Future<ScoreImportReceipt> Function(
          String peerId, ScoreImportRequest metadata, Stream<List<int>> bytes)?
      onScoreImport;
  Future<ScoreImportReceipt?> Function(String peerId, ScoreImportRequest metadata)?
      onScoreImportReceipt;
  late final _changeJournal = CollectionChangeJournal(p.join(stateDirectory, 'catalog-changes-v1.json'));
  final _readerEpoch = randomId();
  Set<String> get authenticatedPeerIds => _peerIds(_state);
  static Set<String> _peerIds(Map<String, dynamic> state) => {
        for (final entry in asMap(state['peers']).entries)
          if (asMap(entry.value)['token'] is String &&
              (asMap(entry.value)['token'] as String).isNotEmpty)
            entry.key,
      };

  /// Projection only: callers never receive tokens or peer baselines.
  static Future<Set<String>> authenticatedPeerIdsAt(String directory) async {
    try {
      final state = await readJson(p.join(directory, 'peers.json'));
      return state == null || state['schema'] != 1 ? {} : _peerIds(state);
    } catch (_) {
      return {};
    }
  }

  final DirectoryLease _lease;
  Map<String, dynamic> _state;
  late HttpServer _server;
  Future<void> _tail = Future.value();
  String? _pairCode;
  DateTime? _pairExpires;
  int _attempts = 0;
  Uri get uri =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port);
  int get port => _server.port;
  String get _statePath => p.join(stateDirectory, 'peers.json');
  final _smallBatchPlans = <String, _SmallBatchPlan>{};

  static Future<SyncServer> start(
      {required LibrarySource source,
      required ReaderStateStore readerStore,
      required String stateDirectory,
      InternetAddress? address,
      int port = 0,
      CollectionLibrarySource? collectionSource,
      Duration ioTimeout = const Duration(seconds: 30),
      Duration catalogSnapshotTtl = const Duration(minutes: 2),
      int maxJsonBytes = 16 * 1024 * 1024}) async {
    if (catalogSnapshotTtl <= Duration.zero)
      throw ArgumentError.value(catalogSnapshotTtl);
    final dir = p.normalize(p.absolute(stateDirectory));
    if (source is CatalogLibrarySource &&
        (p.equals(source.catalog.rootPath, dir) ||
            p.isWithin(source.catalog.rootPath, dir))) {
      throw ArgumentError(
          'Server state must be outside the read-only source library.');
    }
    final lease = await DirectoryLease.acquire(dir);
    try {
      final state = await readJson(p.join(dir, 'peers.json')) ??
          {'schema': 1, 'peers': <String, dynamic>{}};
      if (state['schema'] != 1)
        throw const FormatException('Unsupported peer schema.');
      final server = SyncServer._(source, readerStore, dir, lease, state,
          ioTimeout, maxJsonBytes, collectionSource, catalogSnapshotTtl);
      server._server =
          await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
      server._server.idleTimeout = ioTimeout;
      server._server.listen((request) {
        // One durable protocol transaction at a time; local reader edits still
        // use the reader store's own queue and can run while bytes transfer.
        final next = server._tail.then((_) => server._handle(request));
        server._tail =
            next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      });
      return server;
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  /// UI displays this short-lived code. Successful use consumes it immediately.
  String createPairingCode({Duration validity = const Duration(minutes: 2)}) {
    _pairCode = List.generate(8, (_) => Random.secure().nextInt(10)).join();
    _pairExpires = DateTime.now().toUtc().add(validity);
    _attempts = 0;
    return _pairCode!;
  }

  Future<void> close() async {
    _pairCode = null;
    await _server.close(force: true);
    await _tail;
    for (final transfer in _catalogTransfers.values) {
      transfer.expiry?.cancel();
    }
    _catalogTransfers.clear();
    await _lease.close();
  }

  Future<void> _persist(Map<String, dynamic> state) async {
    await writeJson(_statePath, state);
    _state = state;
  }

  Map<String, dynamic> _copyState() => asMap(jsonDecode(jsonEncode(_state)));
  String _authenticate(HttpRequest request) {
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!authorization.startsWith('Bearer '))
      throw const SyncProtocolException('Authentication required.', 401);
    final token = authorization.substring(7);
    final peers = asMap(_state['peers']);
    for (final e in peers.entries) {
      if (_constantEqual(asMap(e.value)['token'] as String, token))
        return e.key;
    }
    throw const SyncProtocolException('Authentication required.', 401);
  }

  Future<void> _reply(HttpResponse response, Map<String, Object?> json,
      {int status = 200}) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(json));
    await response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/pair' && request.method == 'POST') {
        final body = await _readBody(request, ioTimeout, 1024);
        _attempts++;
        if (_pairCode == null ||
            _attempts > 5 ||
            !DateTime.now().toUtc().isBefore(_pairExpires!) ||
            !_constantEqual(body['code'] as String? ?? '', _pairCode!)) {
          if (_attempts >= 5) _pairCode = null;
          throw const SyncProtocolException(
              'Pairing code invalid or expired.', 403);
        }
        _pairCode = null;
        final peerId = randomId(16), token = randomId();
        final state = _copyState(), peers = asMap(_state['peers']);
        peers[peerId] = {
          'token': token,
          'baselineId': 'initial',
          'baseline': ReaderSnapshot.empty().toJson(),
          'pending': null,
          'lastConfirmed': null
        };
        state['peers'] = peers;
        await _persist(state);
        await _reply(request.response, {'peerId': peerId, 'token': token});
        return;
      }
      final peerId = _authenticate(request);
      final collection = collectionSource;
      if (request.method == 'POST' &&
          path == '/v2/score-import' &&
          onScoreImport != null) {
        final header = request.headers.value('x-score-import');
        if (header == null || header.length > 12288) {
          throw const SyncProtocolException('Invalid import metadata.', 400);
        }
        final metadata = ScoreImportRequest.fromJson(asMap(jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(header))))));
        if (request.contentLength != metadata.length) {
          throw const ScoreImportFailure('import_integrity', 422);
        }
        final receipt =
            await onScoreImport!(peerId, metadata, request.timeout(ioTimeout));
        await _reply(request.response, receipt.toJson());
      } else if (request.method == 'POST' &&
          path == '/device-status/signing' &&
          onSigningStatus != null) {
        if (request.contentLength > 1024) {
          throw const SyncProtocolException('Signing status too large.', 413);
        }
        final body = await _readBody(request, ioTimeout, 1024);
        final status = SigningDeviceStatus.fromJson(body);
        final receivedAt = DateTime.now().toUtc();
        await onSigningStatus!(peerId, status, receivedAt);
        await _reply(request.response, {'accepted': true});
      } else if (request.method == 'POST' && path == '/v2/score-import-receipt' &&
          onScoreImportReceipt != null) {
        final body = await _readBody(request, ioTimeout, 12288);
        final receipt = await onScoreImportReceipt!(peerId, ScoreImportRequest.fromJson(body));
        await _reply(request.response, {'receipt': receipt?.toJson()});
      } else if (request.method == 'GET' && path == '/state-head') {
        await _reply(request.response, {'protocol': 1,
          'version': '$_readerEpoch:${readerStore.snapshot.generation}'});
      } else if (request.method == 'GET' && path == '/state-capabilities') {
        await _reply(request.response,
            {'readerStateMaxSchema': ReaderSnapshot.schemaVersion});
      } else if (request.method == 'POST' &&
          path == '/collection/page-metadata' &&
          onPageMetadata != null) {
        if (request.contentLength > 8192)
          throw const SyncProtocolException('Metadata request too large.', 413);
        final body = await _readBody(request, ioTimeout, 8192);
        final raw = body['items'];
        if (raw is! List || raw.isEmpty || raw.length > 16)
          throw const FormatException('Invalid metadata batch.');
        final keys =
            raw.map((e) => PageMetadataKey.fromJson(asMap(e))).toSet().toList();
        final result = await onPageMetadata!(keys);
        await _reply(request.response, {
          'items': [
            for (final key in keys) {...key.toJson(), 'pages': result[key]}
          ]
        });
      } else if (collection is CollectionVersionSource &&
          request.method == 'GET' &&
          (path == '/v2/catalog-head' || path == '/v2/catalog-changes')) {
        await _changeJournal.refresh(collection!);
        if (path == '/v2/catalog-head') {
          await _reply(request.response, {'protocol': 1,
            'collectionId': _changeJournal.index.id, 'cursor': _changeJournal.cursor});
        } else {
          final since = request.uri.queryParameters['since'];
          if (since == null || since.length > 128) {
            throw const SyncProtocolException('Invalid catalogue cursor.', 400);
          }
          final delta = _changeJournal.changes(since);
          if (delta == null) throw const SyncProtocolException('Catalogue cursor expired.', 410);
          await _reply(request.response, delta.toJson());
        }
      } else if (collection != null &&
          request.method == 'GET' &&
          path == '/v2/catalog-page') {
        await _catalogPage(request, peerId, collection);
      } else if (collection != null &&
          request.method == 'GET' &&
          path == '/v2/catalog') {
        await _reply(request.response, (await collection.index()).toJson());
      } else if (collection != null &&
          request.method == 'GET' &&
          path == '/v2/transfer-capabilities') {
        await _reply(request.response, {
          'smallFileBatch': 1,
          'smallFileObjectBytes': SmallFileBatchLimits.objectBytes
        });
      } else if (collection != null &&
          request.method == 'POST' &&
          path == '/v2/batch-prepare') {
        await _prepareSmallBatch(request, peerId, collection);
      } else if (collection != null &&
          request.method == 'GET' &&
          path == '/v2/batch-object') {
        final token = request.uri.queryParameters['batchId'];
        final maskText = request.uri.queryParameters['mask'] ?? '';
        final plan = _smallBatchPlans[token];
        if (plan == null ||
            plan.peerId != peerId ||
            plan.expires.isBefore(DateTime.now())) {
          throw const SyncProtocolException(
              'Batch plan expired; prepare again.', 410);
        }
        if (!RegExp(r'^[a-f0-9]{1,16}$').hasMatch(maskText))
          throw const FormatException('Invalid selection mask.');
        final mask = BigInt.parse(maskText, radix: 16);
        if ((mask >> plan.items.length) != BigInt.zero)
          throw const FormatException('Selection mask exceeds batch.');
        final selected = <CatalogItem>[];
        for (var i = 0; i < plan.items.length; i++) {
          if ((mask & (BigInt.one << i)) != BigInt.zero) {
            final item = plan.items[i];
            if (item == null)
              throw const FormatException(
                  'Selection mask contains unavailable object.');
            selected.add(item);
          }
        }
        request.response.headers.contentType =
            ContentType('application', 'vnd.score-reader.batch-v1');
        request.response.headers
            .set(HttpHeaders.cacheControlHeader, 'no-store');
        await for (final chunk
            in encodeSmallFileBatch(selected, collection).timeout(ioTimeout)) {
          request.response.add(chunk);
          await request.response.flush();
        }
        await request.response.close();
      } else if (collection != null &&
          request.method == 'POST' &&
          path == '/v2/prepare') {
        final body = await _readBody(request, ioTimeout, 4096);
        final item = await collection.prepare(
            body['entryId'] as String, body['revisionId'] as String);
        await _reply(request.response, item.toJson());
      } else if (collection != null &&
          request.method == 'GET' &&
          path == '/v2/object') {
        final id = request.uri.queryParameters['entryId'] ?? '';
        final revision = request.uri.queryParameters['revisionId'] ?? '';
        final item = collection is CollectionObjectLookup
            ? await (collection as CollectionObjectLookup).itemForObject(id)
            : (await collection.index()).entry(id);
        if (item == null ||
            item.missing ||
            item.hash == null ||
            item.revisionId != revision) {
          throw const SyncProtocolException('Object not available.', 404);
        }
        final stream = await collection.openSelectedObject(id, revision);
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = item.length;
        await request.response.addStream(stream.timeout(ioTimeout));
        await request.response.close();
      } else if (request.method == 'GET' && path == '/manifest') {
        await _reply(request.response, (await source.manifest()).toJson());
      } else if (request.method == 'GET' && path == '/object') {
        final id = request.uri.queryParameters['entryId'] ?? '';
        final revision = request.uri.queryParameters['revisionId'] ?? '';
        final manifest = await source.manifest();
        final e = manifest.entry(id, revision);
        if (e == null || e.missing)
          throw const SyncProtocolException('Object not available.', 404);
        final stream = await source.openObject(id, revision);
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = e.length;
        await request.response.addStream(stream.timeout(ioTimeout));
        await request.response.close();
      } else if (request.method == 'POST' && path == '/state') {
        _requireReaderCapability(request);
        await _exchange(request, peerId);
      } else if (request.method == 'POST' && path == '/ack') {
        _requireReaderCapability(request);
        await _acknowledge(request, peerId);
      } else {
        throw const SyncProtocolException('Unknown protocol route.', 404);
      }
    } catch (error) {
      // Do not echo headers, URLs, file paths or tokens to peer or logs.
      try {
        await _reply(
            request.response,
            {
              'error': error is LibrarySourceNotReady
                  ? 'Source library is not ready for sync.'
                  : 'Sync operation failed.',
              if (error is LibrarySourceNotReady) 'code': 'source_not_ready',
              if (error is ScoreImportFailure) 'code': error.code,
              if (error is SyncProtocolException &&
                  error.code == 'reader_upgrade_required')
                'code': 'reader_upgrade_required',
            },
            status: error is LibrarySourceNotReady
                ? 503
                : error is ScoreImportFailure
                    ? error.status
                    : error is SyncProtocolException
                        ? error.status ?? 400
                        : 400);
      } catch (_) {
        await request.response.close().catchError((Object _) {});
      }
    }
  }

  Future<void> _prepareSmallBatch(HttpRequest request, String peerId,
      CollectionLibrarySource source) async {
    final body = await _readBody(request, ioTimeout, 64 * 1024);
    final raw = body['items'];
    if (raw is! List || raw.isEmpty || raw.length > SmallFileBatchLimits.count)
      throw const FormatException('Invalid small batch.');
    final selected = <String, String>{};
    for (final rawItem in raw) {
      final value = asMap(rawItem);
      final id = value['entryId'] as String;
      if (selected.containsKey(id))
        throw const FormatException('Duplicate batch object.');
      selected[id] = value['revisionId'] as String;
    }
    final prepared = source is CollectionBatchPreparation
        ? await (source as CollectionBatchPreparation).prepareMany(selected)
        : null;
    final items = <CatalogItem?>[], results = <Map<String, Object?>>[];
    var total = 0;
    for (var i = 0; i < raw.length; i++) {
      final value = asMap(raw[i]),
          id = value['entryId'] as String,
          revision = value['revisionId'] as String,
          sourceId = value['sourceId'] as String;
      CatalogItem? item;
      var status = 200;
      try {
        item = prepared == null
            ? await source.prepare(id, revision)
            : prepared[id];
        if (item == null) throw StateError('Selected object unavailable.');
        if (item.entryId != id ||
            item.sourceId != sourceId ||
            item.revisionId != revision ||
            item.missing ||
            item.hash == null) {
          throw const FormatException('Prepared identity changed.');
        }
        if (item.length > SmallFileBatchLimits.objectBytes ||
            total + item.length > SmallFileBatchLimits.payloadBytes ||
            utf8.encode(jsonEncode(item.toJson())).length >
                SmallFileBatchLimits.headerBytes - 1024) {
          status = 413;
          item = null;
        } else {
          total += item.length;
        }
      } catch (_) {
        status = 409;
        item = null;
      }
      items.add(item);
      results.add({
        'index': i,
        'entryId': id,
        'status': status,
        if (item != null) 'item': item.toJson()
      });
    }
    _smallBatchPlans
        .removeWhere((_, plan) => plan.expires.isBefore(DateTime.now()));
    final metadataBytes = utf8.encode(jsonEncode(results)).length;
    while (_smallBatchPlans.isNotEmpty &&
        (_smallBatchPlans.length >= 128 ||
            _smallBatchPlans.values
                        .fold(0, (total, plan) => total + plan.metadataBytes) +
                    metadataBytes >
                8 * 1024 * 1024)) {
      _smallBatchPlans.remove(_smallBatchPlans.keys.first);
    }
    final token = randomId(24);
    _smallBatchPlans[token] = _SmallBatchPlan(peerId, items, metadataBytes);
    await _reply(
        request.response, {'protocol': 1, 'batchId': token, 'items': results});
  }

  void _requireReaderCapability(HttpRequest request) {
    final schema =
        int.tryParse(request.headers.value('x-reader-state-max-schema') ?? '');
    if (schema == null || schema < ReaderSnapshot.schemaVersion) {
      throw const SyncProtocolException(
          'Update both readers before syncing annotations.',
          426,
          'reader_upgrade_required');
    }
  }

  Future<void> _catalogPage(HttpRequest request, String peerId,
      CollectionLibrarySource source) async {
    final offset = int.tryParse(request.uri.queryParameters['offset'] ?? '0');
    final token = request.uri.queryParameters['snapshot'];
    if (offset == null || offset < 0) {
      throw const SyncProtocolException('Invalid catalogue offset.', 400);
    }
    _CatalogTransfer? transfer;
    if (token == null) {
      if (offset != 0)
        throw const SyncProtocolException('Missing snapshot.', 409);
      final index = await source.index();
      final count = 1 +
          index.sources.length +
          index.entries.length +
          index.folders.values.fold<int>(0, (n, paths) => n + paths.length);
      if (count > _catalogMaxRecords) {
        throw const SyncProtocolException(
            'Catalogue exceeds record budget.', 413);
      }
      // At most one outstanding snapshot per peer and two for the server.
      for (final old in _catalogTransfers.values.toList()) {
        if (old.peerId == peerId) _releaseCatalog(old);
      }
      while (_catalogTransfers.length >= 2) {
        _releaseCatalog(_catalogTransfers.values.first);
      }
      transfer = _CatalogTransfer(peerId, index);
      _catalogTransfers[transfer.token] = transfer;
    } else {
      transfer = _catalogTransfers[token];
      if (transfer == null || transfer.peerId != peerId) {
        throw const SyncProtocolException('Catalogue snapshot expired.', 409);
      }
    }
    Uint8List bytes;
    try {
      bytes = transfer.page(offset);
    } catch (_) {
      _releaseCatalog(transfer);
      rethrow;
    }
    transfer.expiry?.cancel();
    if (transfer.nextOffset == transfer.totalRecords) {
      _releaseCatalog(transfer);
    } else {
      transfer.expiry =
          Timer(catalogSnapshotTtl, () => _releaseCatalog(transfer!));
    }
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.add(bytes);
    await request.response.close();
  }

  void _releaseCatalog(_CatalogTransfer transfer) {
    transfer.expiry?.cancel();
    if (identical(_catalogTransfers[transfer.token], transfer)) {
      _catalogTransfers.remove(transfer.token);
    }
  }

  Future<void> _exchange(HttpRequest request, String peerId) async {
    final body = await _readBody(request, ioTimeout, maxJsonBytes);
    final requestId = body['requestId'] as String;
    if (requestId.isEmpty || requestId.length > 128)
      throw const FormatException('Invalid request ID.');
    final fingerprint =
        sha256.convert(utf8.encode(canonicalReaderJson(body))).toString();
    final state = _copyState(), peers = asMap(state['peers']);
    final peer = asMap(peers[peerId]);
    for (final raw in [peer['pending'], peer['lastConfirmed']]) {
      if (raw == null) continue;
      final pending = asMap(raw);
      if (pending['requestId'] == requestId) {
        if (pending['fingerprint'] != fingerprint)
          throw const SyncProtocolException(
              'Request ID content mismatch.', 409);
        await _reply(request.response, asMap(pending['response']));
        return;
      }
    }
    if (peer['pending'] != null)
      throw const SyncProtocolException(
          'Confirm previous pending request first.', 409);
    if (body['baselineId'] != peer['baselineId'])
      throw const SyncProtocolException('Common baseline mismatch.', 409);
    final base = ReaderSnapshot.fromJson(asMap(peer['baseline']));
    final remote = ReaderSnapshot.fromJson(asMap(body['snapshot']));
    final receiptPrefix = 'server/${sha256.convert(utf8.encode(jsonEncode([
          peerId,
          requestId
        ])))}';
    final receipt = '$receiptPrefix/$fingerprint';
    if (readerStore.snapshot.mergeReceipts
        .any((id) => id.startsWith('$receiptPrefix/') && id != receipt)) {
      throw const SyncProtocolException('Request ID content mismatch.', 409);
    }
    final merged = await readerStore.mergeFromPeer(
        base: base, remote: remote, peerId: peerId, operationId: receipt);
    final response = <String, Object?>{
      'requestId': requestId,
      'baselineId': randomId(16),
      'snapshot': merged.snapshot.toJson(),
      'version': '$_readerEpoch:${merged.snapshot.generation}'
    };
    peer['pending'] = {
      'requestId': requestId,
      'fingerprint': fingerprint,
      'response': response
    };
    peers[peerId] = peer;
    state['peers'] = peers;
    await _persist(state);
    await _reply(request.response, response);
  }

  Future<void> _acknowledge(HttpRequest request, String peerId) async {
    final body = await _readBody(request, ioTimeout, 1024);
    final state = _copyState(), peers = asMap(state['peers']);
    final peer = asMap(peers[peerId]);
    final pendingRaw = peer['pending'] ?? peer['lastConfirmed'];
    if (pendingRaw == null)
      throw const SyncProtocolException('No pending baseline.', 409);
    final pending = asMap(pendingRaw), response = asMap(pending['response']);
    if (body['requestId'] != pending['requestId'] ||
        body['baselineId'] != response['baselineId']) {
      throw const SyncProtocolException('Pending baseline mismatch.', 409);
    }
    peer['baselineId'] = response['baselineId'];
    peer['baseline'] = response['snapshot'];
    peer['lastConfirmed'] = pending;
    peer['pending'] = null;
    peers[peerId] = peer;
    state['peers'] = peers;
    await _persist(state);
    await _reply(request.response, {'confirmed': true});
  }
}

class SyncClient {
  SyncClient._(this.baseUri, this.peerId, this._token, this.stateDirectory,
      this.ioTimeout, this.maxJsonBytes);
  final Uri baseUri;
  final String peerId;
  final String _token;
  final String stateDirectory;
  final Duration ioTimeout;
  final int maxJsonBytes;
  String get _statePath => p.join(stateDirectory, 'client.json');
  BackgroundTransfer? backgroundTransfer;
  bool enableSmallFileBatches = true;
  bool? _smallBatchesAvailable;
  int _smallBatchObjectBytes = SmallFileBatchLimits.legacyObjectBytes;
  Future<bool> _supportsSmallBatches(HttpClient http) async {
    if (!enableSmallFileBatches) return false;
    if (_smallBatchesAvailable != null) return _smallBatchesAvailable!;
    try {
      final value = await _json(http, '/v2/transfer-capabilities');
      final limit = value['smallFileObjectBytes'];
      _smallBatchObjectBytes = limit is int &&
              limit >= SmallFileBatchLimits.legacyObjectBytes &&
              limit <= SmallFileBatchLimits.objectBytes
          ? limit
          : SmallFileBatchLimits.legacyObjectBytes;
      return _smallBatchesAvailable = value['smallFileBatch'] == 1;
    } on SyncProtocolException catch (error) {
      if (error.status != 404) rethrow;
      return _smallBatchesAvailable = false;
    }
  }

  String get _transferNamespace =>
      sha256.convert(utf8.encode('$baseUri/$peerId')).toString();
  String get backgroundTransferNamespace => _transferNamespace;

  ScoreImportReceipt _validatedImportReceipt(Map<String, dynamic> body, ScoreImportRequest metadata) {
    final receipt = ScoreImportReceipt.fromJson(body);
    if (receipt.operationId != metadata.operationId ||
        receipt.item.sourceId != metadata.sourceId ||
        receipt.item.relativePath != metadata.relativePath ||
        receipt.item.hash != metadata.hash || receipt.item.length != metadata.length) {
      throw const FormatException('Computer returned another imported score.');
    }
    return receipt;
  }

  Future<ScoreImportReceipt?> lookupScoreImportReceipt(ScoreImportRequest metadata,
      {SyncCancellation? cancellation}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try {
      cancellation?.check();
      final body = await _json(http, '/v2/score-import-receipt', body: metadata.toJson());
      return body['receipt'] == null ? null : _validatedImportReceipt(asMap(body['receipt']), metadata);
    } on SyncProtocolException catch (error) {
      if (error.status != 404) rethrow;
      return null;
    } finally { cancellation?.removeListener(cancel); http.close(force: true); }
  }

  /// Explicit paired-device upload; it never touches the background download queue.
  Future<ScoreImportReceipt> importScore(ScoreImportRequest metadata, File file,
      {SyncCancellation? cancellation}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try {
      cancellation?.check();
      final confirmed = await lookupScoreImportReceipt(metadata, cancellation: cancellation);
      if (confirmed != null) return confirmed;
      final request = await http
          .postUrl(baseUri.resolve('/v2/score-import'))
          .timeout(ioTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.set('x-score-import',
          base64Url.encode(utf8.encode(jsonEncode(metadata.toJson()))));
      request.headers.contentType = ContentType.binary;
      request.contentLength = metadata.length;
      await request.addStream(file.openRead().timeout(ioTimeout));
      final response = await request.close().timeout(ioTimeout);
      final body = await _readBody(response, ioTimeout, 64 * 1024);
      if (response.statusCode != 200) {
        final code = body['code'];
        throw SyncProtocolException(
            'Computer did not confirm score import.',
            response.statusCode,
            const {
              'import_destination_exists',
              'import_operation_conflict',
              'import_source_unavailable',
              'import_integrity'
            }.contains(code)
                ? code as String
                : null);
      }
      final receipt = ScoreImportReceipt.fromJson(body);
      if (receipt.operationId != metadata.operationId ||
          receipt.item.sourceId != metadata.sourceId ||
          receipt.item.relativePath != metadata.relativePath ||
          receipt.item.hash != metadata.hash ||
          receipt.item.length != metadata.length) {
        throw const FormatException(
            'Computer returned another imported score.');
      }
      return receipt;
    } finally {
      cancellation?.removeListener(cancel);
      http.close(force: true);
    }
  }

  bool? _catalogDeltasAvailable;
  DateTime? _lastLegacyCatalogRefresh;
  CollectionRefreshResult? lastCollectionRefresh;
  String? lastReaderStateVersion;

  /// Identity-only check for choosing a cached destination after re-pairing.
  Future<String?> collectionIdentity({SyncCancellation? cancellation}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try {
      cancellation?.check();
      final head = await _json(http, '/v2/catalog-head');
      final id = head['collectionId'];
      if (head['protocol'] != 1 || id is! String || id.isEmpty || id.length > 256) {
        throw const FormatException('Invalid catalogue identity.');
      }
      return id;
    } on SyncProtocolException catch (error) {
      if (error.status != 404) rethrow;
      return null;
    } finally {
      cancellation?.removeListener(cancel);
      http.close(force: true);
    }
  }

  /// Metadata only; daily polling never reconciles the native download queue.
  Future<void> refreshCollectionIndex(ReplicaCollectionView replica,
      {SyncCancellation? cancellation}) async {
    await refreshCollectionDelta(replica, cancellation: cancellation, allowLegacyRefresh: true);
  }

  Future<CollectionRefreshResult> refreshCollectionDelta(ReplicaCollectionView replica,
      {SyncCancellation? cancellation, bool allowLegacyRefresh = false}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try { return await _refreshCollectionDelta(http, replica, cancellation, allowLegacyRefresh: allowLegacyRefresh); }
    finally { cancellation?.removeListener(cancel); http.close(force: true); }
  }

  Future<CollectionRefreshResult> _refreshCollectionDelta(HttpClient http,
      ReplicaCollectionView replica, SyncCancellation? cancellation, {bool allowLegacyRefresh = true}) async {
    cancellation?.check();
    if (!allowLegacyRefresh && _catalogDeltasAvailable == false &&
        _lastLegacyCatalogRefresh != null && replica.index != null &&
        DateTime.now().difference(_lastLegacyCatalogRefresh!) < const Duration(minutes: 5)) {
      return lastCollectionRefresh = const CollectionRefreshResult({}, unchanged: true);
    }
    Map<String, dynamic>? head;
    try { head = await _json(http, '/v2/catalog-head'); _catalogDeltasAvailable = true; }
    on SyncProtocolException catch (error) {
      if (error.status != 404) rethrow;
      _catalogDeltasAvailable = false;
    }
    if (head != null && (head['protocol'] != 1 || head['cursor'] is! String ||
        (head['cursor'] as String).isEmpty || (head['cursor'] as String).length > 128 ||
        head['collectionId'] is! String)) {
      throw const FormatException('Invalid catalogue head.');
    }
    if (head != null && replica.deltaOwner == _transferNamespace &&
        replica.index?.id == head['collectionId'] && replica.deltaCursor == head['cursor']) {
      return lastCollectionRefresh = const CollectionRefreshResult({}, unchanged: true);
    }
    if (head != null && replica.deltaOwner == _transferNamespace && replica.deltaCursor != null &&
        replica.index?.id == head['collectionId']) {
      try {
        final response = await _request(http, 'GET', '/v2/catalog-changes',
            query: {'since': replica.deltaCursor!});
        final delta = CollectionDelta.fromJson(await _readBody(response, ioTimeout, 512 * 1024));
        cancellation?.check();
        final changed = {for (final item in delta.upserts) item.entryId, ...delta.removed};
        await replica.applyDelta(delta, owner: _transferNamespace);
        return lastCollectionRefresh = CollectionRefreshResult(changed);
      } on SyncProtocolException catch (error) {
        if (error.status != 410 && error.status != 404) rethrow;
      }
    }
    // Establish a cursor only for a stable full baseline. A concurrent source
    // publication is retried; a partial transfer can never advance the cursor.
    for (var attempt = 0; attempt < 3; attempt++) {
      final index = await _collectionIndex(http, cancellation);
      if (head != null) {
        final after = await _json(http, '/v2/catalog-head');
        if (after['cursor'] != head['cursor'] || after['collectionId'] != index.id) {
          head = after; continue;
        }
      }
      final before = replica.index;
      final changed = <String>{
        for (final item in index.entries)
          if (before?.entry(item.entryId) == null ||
              !sameCatalogItem(before!.entry(item.entryId)!, item)) item.entryId,
        for (final item in before?.entries ?? const <CatalogItem>[])
          if (index.entry(item.entryId) == null) item.entryId
      };
      cancellation?.check();
      await replica.updateIndex(index, cursor: head?['cursor'] as String?,
          owner: head == null ? null : _transferNamespace);
      if (head == null) _lastLegacyCatalogRefresh = DateTime.now();
      return lastCollectionRefresh = CollectionRefreshResult(changed, fullFallback: true,
          unchanged: changed.isEmpty);
    }
    throw const SyncProtocolException('Catalogue changed during baseline transfer.', 409);
  }

  /// Lightweight reader-state publication, independent of annotation volume.
  Future<String?> readerStateVersion({SyncCancellation? cancellation}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try {
      final head = await _json(http, '/state-head');
      if (head['protocol'] != 1 || head['version'] is! String ||
          (head['version'] as String).length > 256) throw const FormatException('Invalid state head.');
      return head['version'] as String;
    } on SyncProtocolException catch (error) {
      if (error.status != 404) rethrow;
      return null;
    } finally { cancellation?.removeListener(cancel); http.close(force: true); }
  }

  /// Import completed system downloads even when the paired PC is now offline.
  /// Journal/selection/revision checks and SHA verification remain authoritative.
  Future<int> recoverBackgroundCollection(ReplicaCollectionView replica) async {
    final transfer = backgroundTransfer;
    if (transfer == null) return 0;
    var imported = 0;
    while (true) {
      final completed = await transfer.staged(_transferNamespace);
      if (completed.isEmpty) break;
      final acknowledgements = <CatalogItem>[];
      final eligible = <BackgroundTransferFile>[];
      for (final staged in completed) {
        final item = staged.item,
            current = replica.itemFor(staged.item.entryId);
        if (current == null ||
            current.sourceId != item.sourceId ||
            (current.revisionId !=
                    (staged.requestedRevisionId ?? item.revisionId) &&
                current.revisionId != item.revisionId) ||
            current.missing ||
            !replica.selection.includes(item)) {
          acknowledgements.add(item);
          continue;
        }
        eligible.add(staged);
      }
      await replica
          .prepareReceiveBatch(eligible.map((staged) => staged.item).toList());
      for (final staged in eligible) {
        final item = staged.item;
        try {
          await replica.receive(item, File(staged.path).openRead());
        } on LibraryContentIntegrityException {
          // A damaged or empty stage must not poison every future recovery.
          // Existing immutable objects remain untouched; the next batch retries.
          acknowledgements.add(item);
          continue;
        }
        acknowledgements.add(item);
        imported++;
      }
      if (transfer is BackgroundTransferBatchAcknowledger) {
        await (transfer as BackgroundTransferBatchAcknowledger)
            .acknowledgeMany(_transferNamespace, acknowledgements);
      } else {
        for (final item in acknowledgements) {
          await transfer.acknowledge(_transferNamespace, item);
        }
      }
    }
    await replica.flush();
    return imported;
  }

  /// Credentials and per-peer baselines stay in the app-private directory.
  static Future<SyncClient> pair(
      {required Uri baseUri,
      required String code,
      required String stateDirectory,
      Duration ioTimeout = const Duration(seconds: 30),
      int maxJsonBytes = 16 * 1024 * 1024}) async {
    _validateUri(baseUri);
    final lease = await DirectoryLease.acquire(stateDirectory);
    try {
      if (await readJson(p.join(stateDirectory, 'client.json')) != null) {
        throw StateError('Client directory already paired. Open it instead.');
      }
      final http = HttpClient()..connectionTimeout = ioTimeout;
      try {
        final request =
            await http.postUrl(baseUri.resolve('/pair')).timeout(ioTimeout);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'code': code}));
        final response = await request.close().timeout(ioTimeout);
        final body = await _readBody(response, ioTimeout, 1024);
        if (response.statusCode != 200)
          throw SyncProtocolException('Pairing failed.', response.statusCode);
        final client = SyncClient._(
            baseUri,
            body['peerId'] as String,
            body['token'] as String,
            p.normalize(p.absolute(stateDirectory)),
            ioTimeout,
            maxJsonBytes);
        await writeJson(client._statePath, {
          'schema': 1,
          'baseUri': baseUri.toString(),
          'peerId': client.peerId,
          'token': client._token,
          'baselineId': 'initial',
          'baseline': ReaderSnapshot.empty().toJson(),
          'pending': null
        });
        return client;
      } finally {
        http.close(force: true);
      }
    } finally {
      await lease.close();
    }
  }

  static Future<SyncClient> open(
      {required String stateDirectory,
      Duration ioTimeout = const Duration(seconds: 30),
      int maxJsonBytes = 16 * 1024 * 1024}) async {
    final json = await readJson(p.join(stateDirectory, 'client.json'));
    if (json == null || json['schema'] != 1)
      throw const FormatException('Missing or unsupported client state.');
    final uri = Uri.parse(json['baseUri'] as String);
    _validateUri(uri);
    return SyncClient._(uri, json['peerId'] as String, json['token'] as String,
        p.normalize(p.absolute(stateDirectory)), ioTimeout, maxJsonBytes);
  }

  static void _validateUri(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Use a plain private HTTP server origin.');
    }
  }

  Future<HttpClientResponse> _request(
      HttpClient http, String method, String path,
      {Map<String, Object?>? body,
      Map<String, String>? query,
      bool readLibraryFailure = false}) async {
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final request = await http.openUrl(method, uri).timeout(ioTimeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    if (path == '/state' || path == '/ack') {
      request.headers
          .set('x-reader-state-max-schema', ReaderSnapshot.schemaVersion);
    }
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      if (bytes.length > maxJsonBytes)
        throw const SyncProtocolException(
            'Reader state exceeds configured limit.');
      request.headers.contentType = ContentType.json;
      request.add(bytes);
    }
    final response = await request.close().timeout(ioTimeout);
    if (response.statusCode != 200) {
      String? code;
      if (response.statusCode == 426 || path == '/v2/score-import-receipt' ||
          (readLibraryFailure && response.statusCode == 503)) {
        try {
          final error = await _readBody(response, ioTimeout, maxJsonBytes);
          if (error['code'] == 'source_not_ready') code = 'source_not_ready';
          if (path == '/v2/score-import-receipt' && const {
            'import_operation_conflict', 'import_source_unavailable', 'import_integrity'
          }.contains(error['code'])) code = error['code'] as String;
          if (response.statusCode == 426 &&
              error['code'] == 'reader_upgrade_required')
            code = 'reader_upgrade_required';
        } on FormatException {
          // Malformed/unknown error bodies do not grant a typed source failure.
        } on TypeError {
          // A JSON value other than an object is also an unknown peer failure.
        }
      } else {
        await response.drain<void>().timeout(ioTimeout);
      }
      throw SyncProtocolException(
          'Peer rejected sync request.', response.statusCode, code);
    }
    return response;
  }

  Future<Map<String, dynamic>> _json(HttpClient http, String path,
          {Map<String, Object?>? body,
          bool readLibraryFailure = false}) async =>
      _readBody(
          await _request(http, body == null ? 'GET' : 'POST', path,
              body: body, readLibraryFailure: readLibraryFailure),
          ioTimeout,
          maxJsonBytes);

  /// Optional best-effort metadata report; no catalogue/state exchange is run.
  Future<bool> reportSigningStatus(SigningDeviceStatus status) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final response = await _request(http, 'POST', '/device-status/signing',
              body: status.toJson())
          .timeout(const Duration(seconds: 3));
      final body = await _readBody(response, const Duration(seconds: 3), 1024);
      return body['accepted'] == true;
    } on SyncProtocolException catch (error) {
      if (error.status == 404) return false;
      rethrow;
    } finally {
      http.close(force: true);
    }
  }

  /// Optional page counts only; a legacy peer's 404 means unknown.
  Future<Map<PageMetadataKey, int>> pageMetadata(
      List<PageMetadataKey> keys) async {
    if (keys.isEmpty || keys.length > 16)
      throw ArgumentError('Metadata batch size.');
    final http = HttpClient()..connectionTimeout = ioTimeout;
    try {
      final response = await _request(http, 'POST', '/collection/page-metadata',
          body: {'items': keys.map((key) => key.toJson()).toList()});
      final body = await _readBody(response, ioTimeout, 16384);
      final raw = body['items'];
      if (raw is! List || raw.length > keys.length)
        throw const FormatException('Invalid metadata reply.');
      final allowed = keys.toSet(), result = <PageMetadataKey, int>{};
      for (final item in raw) {
        final value = asMap(item),
            key = PageMetadataKey.fromJson(value),
            count = value['pages'];
        if (!allowed.contains(key))
          throw const FormatException('Unexpected metadata item.');
        if (count is int && count > 0 && count <= 100000) result[key] = count;
      }
      return result;
    } on SyncProtocolException catch (error) {
      if (error.status == 404) return {};
      rethrow;
    } finally {
      http.close(force: true);
    }
  }

  Future<CollectionIndex> _collectionIndex(
      HttpClient http, SyncCancellation? cancellation) async {
    final received = _CatalogAccumulator();
    while (true) {
      cancellation?.check();
      HttpClientResponse response;
      try {
        response = await _request(http, 'GET', '/v2/catalog-page', query: {
          'offset': '${received.offset}',
          if (received.token != null) 'snapshot': received.token!,
        });
      } on SyncProtocolException catch (error) {
        // Compatibility is negotiated only before any page is accepted.
        if (received.offset != 0 || error.status != 404) rethrow;
        return CollectionIndex.fromJson(await _json(http, '/v2/catalog'));
      }
      final page = await _readBody(response, ioTimeout, _catalogPageBytes,
          onBytesRead: received.countBytes);
      if (received.add(page)) return received.finish();
    }
  }

  Future<LibrarySyncResult> syncLibrary(ReplicaLibraryView replica,
      {SyncCancellation? cancellation,
      FutureOr<void> Function(LibrarySyncProgress progress)?
          onProgress}) async {
    void report(LibrarySyncPhase phase, int processed, int total) {
      if (onProgress == null) return;
      // Invoke in emission order, consume synchronous/asynchronous observer
      // errors, and never wait for an observer to complete or release a lease.
      unawaited(Future<void>.sync(
              () => onProgress(LibrarySyncProgress(phase, processed, total)))
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }

    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    DirectoryLease? lease;
    var downloaded = 0;
    try {
      cancellation?.check();
      lease = await DirectoryLease.acquire(replica.rootDirectory);
      final manifest = SyncManifest.fromJson(
          await _json(http, '/manifest', readLibraryFailure: true));
      if (replica.manifest != null &&
          replica.manifest!.libraryId != manifest.libraryId) {
        throw _DifferentLibrary();
      }
      final targets = manifest.entries.where((e) => !e.missing).toList();
      var processed = 0;
      report(LibrarySyncPhase.transferring, processed, targets.length);
      final transfer = backgroundTransfer;
      final pending = <CatalogItem>[];
      final pendingById = <String, CatalogItem>{};
      if (transfer != null) {
        for (final e in targets) {
          cancellation?.check();
          if (!await replica.hasVerifiedObject(e)) {
            pending.add(CatalogItem(
                sourceId: 'legacy',
                entryId: e.entryId,
                revisionId: e.revisionId,
                relativePath: e.relativePath,
                length: e.length,
                format: e.format,
                hash: e.hash));
          }
        }
        pendingById
            .addEntries(pending.map((item) => MapEntry(item.entryId, item)));
        if (transfer is BackgroundTransferBatchLimits) {
          (transfer as BackgroundTransferBatchLimits).smallFileObjectBytes =
              _smallBatchObjectBytes;
        }
        await transfer.enqueue(
            namespace: _transferNamespace,
            origin: baseUri,
            bearerToken: _token,
            items: pending,
            prepare: false,
            cancellation: cancellation);
      }
      for (final e in targets) {
        cancellation?.check();
        if (!await replica.hasVerifiedObject(e)) {
          if (transfer == null) {
            final response = await _request(http, 'GET', '/object',
                query: {'entryId': e.entryId, 'revisionId': e.revisionId},
                readLibraryFailure: true);
            await replica.receiveObject(e, response.timeout(ioTimeout),
                cancellation: cancellation);
          } else {
            final item = pendingById[e.entryId]!;
            final staged =
                await transfer.wait(_transferNamespace, item, cancellation);
            await replica.receiveObject(e, File(staged.path).openRead(),
                cancellation: cancellation);
            await transfer.acknowledge(_transferNamespace, item);
          }
          downloaded++;
        }
        processed++;
        report(LibrarySyncPhase.transferring, processed, targets.length);
      }
      cancellation?.check();
      report(LibrarySyncPhase.committing, processed, targets.length);
      await replica.commitManifest(manifest, cancellation: cancellation);
      report(LibrarySyncPhase.complete, processed, targets.length);
      return LibrarySyncResult(LibrarySyncStatus.complete, downloaded);
    } catch (error) {
      final failure = cancellation?.isCancelled == true
          ? LibrarySyncFailure.cancelled
          : _libraryFailure(error);
      return LibrarySyncResult(
          failure == LibrarySyncFailure.cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.partial,
          downloaded,
          _libraryFailureMessage(failure),
          failure);
    } finally {
      cancellation?.removeListener(cancel);
      http.close(force: true);
      await lease?.close();
      if (cancellation?.isCancelled == true)
        await backgroundTransfer?.pause(_transferNamespace);
    }
  }

  /// v2 directory updates never imply downloading an unselected source. v1
  /// fallback remains confined to its original complete-library endpoint.
  Future<LibrarySyncResult> syncCollection(ReplicaCollectionView replica,
      {Set<String>? onlyEntryIds,
      bool changedOnly = false,
      bool refreshIndex = true,
      SyncCancellation? cancellation,
      FutureOr<void> Function(LibrarySyncProgress progress)?
          onProgress}) async {
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    var downloaded = 0, processed = 0, failed = false;
    final acknowledgements = <CatalogItem>[];
    Future<void> acknowledgePending() async {
      final transfer = backgroundTransfer;
      if (transfer == null || acknowledgements.isEmpty) return;
      if (transfer is BackgroundTransferBatchAcknowledger) {
        await (transfer as BackgroundTransferBatchAcknowledger)
            .acknowledgeMany(_transferNamespace, acknowledgements);
      } else {
        for (final item in acknowledgements) {
          await transfer.acknowledge(_transferNamespace, item);
        }
      }
      acknowledgements.clear();
    }

    void report(int total) {
      if (onProgress != null) {
        unawaited(Future<void>.sync(() => onProgress(LibrarySyncProgress(
                LibrarySyncPhase.transferring, processed, total)))
            .catchError((Object _) {}));
      }
    }

    try {
      await recoverBackgroundCollection(replica);
      CollectionIndex index;
      try {
        if (refreshIndex) await _refreshCollectionDelta(http, replica, cancellation, allowLegacyRefresh: !changedOnly);
        index = replica.index!;
      } on SyncProtocolException catch (e) {
        if (e.status != 404) rethrow;
        // A v1 complete-manifest sync cannot promise a scoped download. Do not
        // turn one set-list request into an unexpected whole-library transfer.
        if (onlyEntryIds != null)
          return const LibrarySyncResult(
              LibrarySyncStatus.partial,
              0,
              'Scoped preparation requires a v2 computer',
              LibrarySyncFailure.sourceNotReady);
        final result = await syncLibrary(replica.objects,
            cancellation: cancellation, onProgress: onProgress);
        if (result.status == LibrarySyncStatus.complete)
          await replica.importLegacy();
        return result;
      }
      cancellation?.check();
      final scoped = changedOnly && onlyEntryIds == null ? replica.pendingDeltaEntryIds : null;
      final candidates = scoped == null ? replica.currentItems :
          scoped.map(replica.itemFor).whereType<CatalogItem>();
      final targets = candidates
          .where((e) =>
              !e.missing &&
              (onlyEntryIds == null || onlyEntryIds.contains(e.entryId)) &&
              replica.selection.includes(e) &&
              !replica.isReady(e))
          .toList();
      final eligible = onlyEntryIds == null ? <String>{} : {
        for (final id in onlyEntryIds)
          if (replica.itemFor(id) case final item?)
            if (!item.missing && replica.selection.includes(item)) id
      };
      final unavailable = onlyEntryIds?.difference(eligible).length ?? 0;
      final total = targets.length + unavailable;
      failed = unavailable > 0;
      processed = unavailable;
      report(total);
      if (targets.isEmpty) {
        replica.completeDeltaEntries(replica.pendingDeltaEntryIds.where((id) {
          final item = replica.itemFor(id);
          return item != null && replica.isReady(item);
        }).toList());
        await replica.flush();
        return LibrarySyncResult(failed ? LibrarySyncStatus.partial : LibrarySyncStatus.complete, 0,
            failed ? 'Some selected files are unavailable.' : null,
            failed ? LibrarySyncFailure.sourceNotReady : null);
      }
      final transfer = backgroundTransfer;
      final smallBatches = targets
              .any((item) => item.length <= SmallFileBatchLimits.objectBytes) &&
          await _supportsSmallBatches(http);
      final batched = <String>{};
      if (transfer != null) {
        final pending = <CatalogItem>[];
        for (final item in targets) {
          cancellation?.check();
          if (index.sources.firstWhere((s) => s.id == item.sourceId).online &&
              (item.hash == null ||
                  !await replica.objects.hasVerifiedObject(item.object))) {
            pending.add(item);
          }
        }
        if (transfer is BackgroundTransferBatchLimits) {
          (transfer as BackgroundTransferBatchLimits).smallFileObjectBytes =
              _smallBatchObjectBytes;
        }
        await transfer.enqueue(
            namespace: _transferNamespace,
            origin: baseUri,
            bearerToken: _token,
            items: pending,
            prepare: true,
            smallFileBatches: smallBatches,
            selection: replica.selection,
            cancellation: cancellation);
      } else if (smallBatches) {
        final pending = <CatalogItem>[];
        final online = {
          for (final source in index.sources) source.id: source.online
        };
        for (final item in targets) {
          if (online[item.sourceId] == true &&
              item.length <= _smallBatchObjectBytes &&
              (item.hash == null ||
                  !await replica.objects.hasVerifiedObject(item.object)))
            pending.add(item);
        }
        for (final batch in planSmallFileBatches(pending,
            objectBytes: _smallBatchObjectBytes)) {
          cancellation?.check();
          try {
            final prepared = await _readBody(
                await _request(http, 'POST', '/v2/batch-prepare', body: {
                  'items': [
                    for (final item in batch)
                      {
                        'sourceId': item.sourceId,
                        'entryId': item.entryId,
                        'revisionId': item.revisionId
                      }
                  ]
                }),
                ioTimeout,
                SmallFileBatchLimits.prepareBytes);
            final raw = prepared['items'];
            if (prepared['protocol'] != 1 ||
                raw is! List ||
                raw.length != batch.length)
              throw const FormatException('Invalid batch preparation.');
            final expected = <String, CatalogItem>{};
            var mask = BigInt.zero;
            for (var i = 0; i < raw.length; i++) {
              final record = asMap(raw[i]), original = batch[i];
              if (record['index'] != i || record['entryId'] != original.entryId)
                throw const FormatException('Batch identity changed.');
              if (record['status'] != 200)
                continue; // Isolated single-file retry below.
              final item = CatalogItem.fromJson(asMap(record['item']));
              if (item.entryId != original.entryId ||
                  item.sourceId != original.sourceId ||
                  item.revisionId != original.revisionId ||
                  item.hash == null ||
                  item.missing ||
                  item.length > SmallFileBatchLimits.objectBytes)
                throw const FormatException('Batch object changed.');
              if (!replica.selection.includes(item)) {
                batched.add(item.entryId);
                processed++;
                failed = true;
                continue;
              }
              expected[item.entryId] = item;
              mask |= BigInt.one << i;
            }
            if (expected.isEmpty) continue;
            await replica.prepareReceiveBatch(expected.values.toList());
            final response =
                await _request(http, 'GET', '/v2/batch-object', query: {
              'batchId': prepared['batchId'] as String,
              'mask': mask.toRadixString(16),
            });
            final seen = <String>{};
            await for (final frame in decodeSmallFileBatch(
                response.timeout(ioTimeout),
                cancellation: cancellation)) {
              final item = expected[frame.entryId];
              if (item == null ||
                  !seen.add(frame.entryId) ||
                  frame.sourceId != item.sourceId ||
                  frame.revisionId != item.revisionId) {
                throw const FormatException('Unexpected batch frame.');
              }
              if (frame.status != 200) continue;
              if (jsonEncode(frame.item?.toJson()) != jsonEncode(item.toJson()))
                throw const FormatException('Batch metadata changed.');
              if (!replica.selection.includes(item)) {
                batched.add(item.entryId);
                processed++;
                continue;
              }
              try {
                await replica.receive(item, Stream.value(frame.bytes),
                    cancellation: cancellation);
                downloaded++;
                replica.completeDeltaEntries([item.entryId]);
                batched.add(item.entryId);
                processed++;
                report(total);
              } on LibraryContentIntegrityException {
                /* Retry only this file below. */
              }
            }
            if (seen.length != expected.length)
              throw const FormatException('Batch omitted an object.');
          } on SyncProtocolException catch (error) {
            if (error.status != 404 && error.status != 410) rethrow;
            if (error.status == 404) _smallBatchesAvailable = false;
            break;
          } on FormatException {
            // Framing cannot safely locate later records. Retry only files
            // that have not already passed their independent atomic import.
          }
        }
      }
      for (var item in targets) {
        cancellation?.check();
        if (batched.contains(item.entryId)) continue;
        if (!replica.selection.includes(item)) continue;
        try {
          if (item.hash == null ||
              !await replica.objects.hasVerifiedObject(item.object)) {
            final source =
                index.sources.firstWhere((s) => s.id == item.sourceId);
            if (!source.online) {
              failed = true;
              processed++;
              report(total);
              continue;
            }
            final staged = transfer == null
                ? null
                : await transfer.wait(_transferNamespace, item, cancellation);
            if (staged != null) {
              final available = staged.companions.isNotEmpty
                  ? staged.companions
                  : (await transfer!.staged(_transferNamespace))
                      .map((file) => file.item)
                      .toList();
              await replica.prepareReceiveBatch(
                  available.where(replica.selection.includes).toList());
            }
            final resolved = staged?.item ??
                CatalogItem.fromJson(await _json(http, '/v2/prepare', body: {
                  'entryId': item.entryId,
                  'revisionId': item.revisionId,
                }));
            if (resolved.entryId != item.entryId ||
                resolved.sourceId != item.sourceId) {
              throw const FormatException('Selected object identity changed.');
            }
            item = resolved;
            if (item.hash == null ||
                item.missing ||
                !replica.selection.includes(item)) {
              failed = true;
              processed++;
              report(total);
              continue;
            }
            if (!await replica.objects.hasVerifiedObject(item.object)) {
              final bytes = staged != null
                  ? File(staged.path).openRead()
                  : (await _request(http, 'GET', '/v2/object', query: {
                      'entryId': item.entryId,
                      'revisionId': item.revisionId,
                    }))
                      .timeout(ioTimeout);
              await replica.receive(item, bytes, cancellation: cancellation);
              downloaded++;
            } else {
              replica.rememberResolved(item);
            }
            if (staged != null) {
              acknowledgements.add(item);
              if (acknowledgements.length >= 32) await acknowledgePending();
            }
          }
          if (!replica.isReady(item)) replica.rememberResolved(item);
          replica.completeDeltaEntries([item.entryId]);
        } catch (error) {
          if (error is SyncCancelled || cancellation?.isCancelled == true)
            rethrow;
          failed = true;
          if (error is SocketException ||
              error is TimeoutException ||
              error is HttpException ||
              error is FileSystemException) rethrow;
        }
        processed++;
        report(total);
      }
      await replica.flush();
      return LibrarySyncResult(
          failed ? LibrarySyncStatus.partial : LibrarySyncStatus.complete,
          downloaded,
          failed
              ? 'Some selected files are unavailable; other downloads are retained.'
              : null,
          failed ? LibrarySyncFailure.sourceNotReady : null);
    } catch (error) {
      final failure = cancellation?.isCancelled == true
          ? LibrarySyncFailure.cancelled
          : _libraryFailure(error);
      return LibrarySyncResult(
          failure == LibrarySyncFailure.cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.partial,
          downloaded,
          _libraryFailureMessage(failure),
          failure);
    } finally {
      await acknowledgePending();
      cancellation?.removeListener(cancel);
      http.close(force: true);
      if (cancellation?.isCancelled == true)
        await backgroundTransfer?.pause(_transferNamespace);
      // A cancelled/partial batch retains verified objects and their bounded
      // metadata without serializing the entire directory for every object.
      try {
        await replica.flush();
      } catch (_) {/* Normal-path errors are reported above. */}
    }
  }

  /// Hook is intended for deterministic interruption/concurrent-edit tests;
  /// application UI can use it to update progress after a response arrives.
  Future<ReaderMergeResult> syncReaderState(ReaderStateStore store,
      {SyncCancellation? cancellation,
      Future<void> Function()? afterResponse,
      Future<void> Function()? afterMerge}) async {
    final lease = await DirectoryLease.acquire(stateDirectory);
    final http = HttpClient()..connectionTimeout = ioTimeout;
    void cancel() => http.close(force: true);
    cancellation?.addListener(cancel);
    try {
      cancellation?.check();
      // Negotiate before creating/replaying any durable pending transaction.
      // The HTTP capability header leaves existing schema-2 body fingerprints
      // unchanged, allowing their exact retry and acknowledgement to finish.
      Map<String, dynamic> capability;
      try {
        capability = await _json(http, '/state-capabilities');
      } on SyncProtocolException catch (error) {
        if (error.status != 404) rethrow;
        throw const SyncProtocolException(
            'Update both readers before syncing annotations.',
            426,
            'reader_upgrade_required');
      }
      if (capability['readerStateMaxSchema'] is! int ||
          (capability['readerStateMaxSchema'] as int) <
              ReaderSnapshot.schemaVersion) {
        throw const SyncProtocolException(
            'Update both readers before syncing annotations.',
            426,
            'reader_upgrade_required');
      }
      final state = (await readJson(_statePath))!;
      var pending = state['pending'] == null ? null : asMap(state['pending']);
      if (pending == null) {
        pending = {
          'requestId': randomId(16),
          'baselineId': state['baselineId'],
          'snapshot': store.snapshot.toJson(),
          'response': null
        };
        state['pending'] = pending;
        await writeJson(_statePath, state);
      }
      Map<String, dynamic> response;
      if (pending['response'] == null) {
        response = await _json(http, '/state', body: {
          'requestId': pending['requestId'],
          'baselineId': pending['baselineId'],
          'snapshot': pending['snapshot']
        });
        if (response['requestId'] != pending['requestId'])
          throw const SyncProtocolException('Response request mismatch.');
        // Validate before persisting a response which will be replayed offline.
        ReaderSnapshot.fromJson(asMap(response['snapshot']));
        pending['response'] = response;
        state['pending'] = pending;
        await writeJson(_statePath, state);
      } else {
        response = asMap(pending['response']);
      }
      await afterResponse?.call();
      cancellation?.check();
      final received = ReaderSnapshot.fromJson(asMap(response['snapshot']));
      final result = await store.mergeFromPeer(
          base: ReaderSnapshot.fromJson(asMap(pending['snapshot'])),
          remote: received,
          peerId: peerId,
          operationId: 'client/$peerId/${pending['requestId']}');
      await afterMerge?.call();
      cancellation?.check();
      await _json(http, '/ack', body: {
        'requestId': pending['requestId'],
        'baselineId': response['baselineId']
      });
      state['baselineId'] = response['baselineId'];
      state['baseline'] = response['snapshot'];
      state['pending'] = null;
      await writeJson(_statePath, state);
      final version = response['version'];
      lastReaderStateVersion = version is String && version.length <= 256 ? version : null;
      return result;
    } finally {
      cancellation?.removeListener(cancel);
      http.close(force: true);
      await lease.close();
    }
  }
}
