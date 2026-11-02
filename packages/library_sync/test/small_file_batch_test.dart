import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:library_sync/library_sync.dart';
import 'package:library_sync/src/small_file_batch.dart';
import 'package:reader_state/reader_state.dart';
import 'package:test/test.dart';

class _Source implements LibrarySource, CollectionLibrarySource {
  _Source(List<int> sizes) {
    for (var i = 0; i < sizes.length; i++) {
      final bytes = Uint8List(sizes[i]);
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = (i + j) % 251;
      }
      data['$i'] = bytes;
    }
  }
  final data = <String, Uint8List>{};
  final ready = <String>{};
  final reads = <String, int>{};
  final corrupt = <String>{}, corruptOnce = <String>{};
  String? movedId;
  CatalogItem item(String id, {bool resolved = false}) => CatalogItem(
      sourceId: 's',
      entryId: id,
      revisionId: 'r$id',
      relativePath:
          resolved && movedId == id ? 'unselected/$id.pdf' : 'selected/$id.pdf',
      length: data[id]!.length,
      format: 'pdf',
      hash: resolved || ready.contains(id)
          ? sha256.convert(data[id]!).toString()
          : null);
  @override
  Future<CollectionIndex> index() async => CollectionIndex(
      id: 'c',
      sources: const [LibrarySourceInfo('s', 'Synthetic')],
      entries: data.keys.map(item).toList(),
      folders: const {
        's': ['', 'selected', 'unselected']
      });
  @override
  Future<CatalogItem> prepare(String id, String revision) async {
    if (revision != 'r$id') throw StateError('Revision changed');
    ready.add(id);
    return item(id, resolved: true);
  }

  @override
  Future<Stream<List<int>>> openSelectedObject(
      String id, String revision) async {
    if (revision != 'r$id') throw StateError('Revision changed');
    reads.update(id, (n) => n + 1, ifAbsent: () => 1);
    final bytes = Uint8List.fromList(data[id]!);
    if (corrupt.contains(id) || corruptOnce.remove(id)) bytes[0] ^= 1;
    Stream<List<int>> chunks() async* {
      for (var offset = 0; offset < bytes.length; offset += 4096) {
        yield Uint8List.sublistView(
            bytes, offset, (offset + 4096).clamp(0, bytes.length));
      }
    }

    return chunks();
  }

  @override
  Future<SyncManifest> manifest() async => throw LibrarySourceNotReady();
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async =>
      throw StateError('Legacy not used');
}

class _BulkSource extends _Source implements CollectionBatchPreparation {
  _BulkSource(super.sizes);
  int bulkCalls = 0, singleCalls = 0;
  @override
  Future<CatalogItem> prepare(String id, String revision) {
    singleCalls++;
    return super.prepare(id, revision);
  }

  @override
  Future<Map<String, CatalogItem>> prepareMany(
      Map<String, String> selected) async {
    bulkCalls++;
    return {
      for (final request in selected.entries)
        request.key: await super.prepare(request.key, request.value)
    };
  }
}

class _Harness {
  _Harness(this.root, this.source, this.server, this.proxy, this.http);
  final Directory root;
  final _Source source;
  final SyncServer server;
  final HttpServer proxy;
  final HttpClient http;
  late SyncClient client;
  late ReplicaCollectionView view;
  final requests = <String, int>{};
  bool legacyCap = false,
      legacy = false,
      expireOnce = false,
      tamperOnce = false,
      invalidFrameOnce = false;
  static Future<_Harness> create(List<int> sizes, {bool bulk = false}) async {
    final root = await Directory.systemTemp.createTemp('small-batch-test-');
    final source = bulk ? _BulkSource(sizes) : _Source(sizes);
    final server = await SyncServer.start(
        source: source,
        collectionSource: source,
        readerStore:
            await ReaderStateStore.open(statePath: '${root.path}/reader.json'),
        stateDirectory: '${root.path}/server');
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        http = HttpClient();
    final h = _Harness(root, source, server, proxy, http);
    proxy.listen(h.forward);
    h.client = await SyncClient.pair(
        baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: proxy.port),
        code: server.createPairingCode(),
        stateDirectory: '${root.path}/client');
    h.view = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: '${root.path}/replica'));
    await h.view
        .select(OfflineRule(sourceId: 's', folder: 'selected', selected: true));
    addTearDown(() async {
      await proxy.close(force: true);
      http.close(force: true);
      await server.close();
      await root.delete(recursive: true);
    });
    return h;
  }

  Future<void> forward(HttpRequest incoming) async {
    try {
      final path = incoming.uri.path;
      requests.update(path, (n) => n + 1, ifAbsent: () => 1);
      if (legacy && path == '/v2/transfer-capabilities' ||
          expireOnce && path == '/v2/batch-object') {
        incoming.response.statusCode = legacy ? 404 : 410;
        expireOnce = false;
        await incoming.response.close();
        return;
      }
      if (legacyCap && path == '/v2/transfer-capabilities') {
        incoming.response.write(jsonEncode({'smallFileBatch': 1}));
        await incoming.response.close();
        return;
      }
      final outgoing = await http.openUrl(
          incoming.method, server.uri.resolveUri(incoming.uri));
      incoming.headers.forEach((name, values) {
        if (!['host', 'content-length', 'transfer-encoding'].contains(name))
          outgoing.headers.set(name, values);
      });
      await outgoing.addStream(incoming);
      final response = await outgoing.close();
      incoming.response.statusCode = response.statusCode;
      if (path == '/v2/batch-object' && (tamperOnce || invalidFrameOnce)) {
        final builder = BytesBuilder();
        await for (final chunk in response) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        final headerLength = ByteData.sublistView(bytes).getUint32(8);
        if (invalidFrameOnce) {
          bytes[0] = 0;
          invalidFrameOnce = false;
        } else {
          bytes[16 + headerLength] ^= 1;
          tamperOnce = false;
        }
        incoming.response.add(bytes);
      } else {
        await incoming.response.addStream(response);
      }
      await incoming.response.close();
    } catch (_) {
      await incoming.response.close().catchError((Object _) {});
    }
  }

  int count(String path) => requests[path] ?? 0;
  Future<(int, List<int>)> raw(String method, String path,
      {Object? body, String? token}) async {
    final state =
        jsonDecode(await File('${root.path}/client/client.json').readAsString())
            as Map;
    final request = await http.openUrl(method, server.uri.resolve(path));
    request.headers.set('Authorization', 'Bearer ${token ?? state['token']}');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final builder = BytesBuilder();
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return (response.statusCode, builder.takeBytes());
  }
}

void main() {
  test(
      'negotiated 1MiB groups medium files with bounded payload and optional bulk source',
      () async {
    final h =
        await _Harness.create([350 * 1024, 650 * 1024, 900 * 1024], bulk: true);
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/batch-prepare'), 1);
    expect(h.count('/v2/batch-object'), 1);
    expect(h.count('/v2/prepare'), 0);
    expect((h.source as _BulkSource).bulkCalls, 1);
    expect((h.source as _BulkSource).singleCalls, 0);
  });
  test(
      '31 capability without size field keeps medium files on the single-object path',
      () async {
    final h = await _Harness.create([32 * 1024, 350 * 1024, 900 * 1024]);
    h.legacyCap = true;
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/batch-prepare'), 1);
    expect(h.count('/v2/prepare'), 2);
    expect(h.count('/v2/object'), 2);
  });
  for (final size in [1024, 32768]) {
    test(
        '129 synthetic $size-byte files use six transfer requests and three metadata checkpoints',
        () async {
      final h = await _Harness.create(List.filled(129, size));
      final result = await h.client.syncCollection(h.view);
      expect(result.status, LibrarySyncStatus.complete);
      expect(result.downloaded, 129);
      expect(h.count('/v2/batch-prepare'), 3);
      expect(h.count('/v2/batch-object'), 3);
      expect(h.count('/v2/object'), 0);
      expect(h.view.metadataJournalFlushes, 3);
      expect(h.source.reads.values.every((count) => count == 1), isTrue);
      expect((await h.client.syncCollection(h.view)).downloaded, 0);
      expect(h.count('/v2/batch-object'), 3);
    });
  }
  test('mixed sizes obey count and byte caps and send large files individually',
      () async {
    final h = await _Harness.create(
        [...List.filled(20, 256 * 1024), 1024 * 1024 + 1, 32 * 1024]);
    final groups =
        planSmallFileBatches((await h.source.index()).entries).toList();
    expect(groups.map((g) => g.length), [16, 5]);
    for (final group in groups) {
      expect(group.length, lessThanOrEqualTo(64));
      expect(group.fold(0, (n, item) => n + item.length),
          lessThanOrEqualTo(4 * 1024 * 1024));
    }
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/batch-object'), 2);
    expect(h.count('/v2/object'), 1);
  });
  test(
      'one source read failure retries only that file and preserves its following files',
      () async {
    final h = await _Harness.create(List.filled(64, 1024));
    h.source.corruptOnce.add('17');
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/batch-object'), 1);
    expect(h.count('/v2/object'), 1);
    expect(h.source.reads['17'], 2);
    expect(h.source.reads['18'], 1);
    expect(h.view.readableItemFor('63'), isNotNull);
  });
  test('persistent corrupt file cannot poison other files or become readable',
      () async {
    final h = await _Harness.create(List.filled(64, 1024));
    h.source.corrupt.add('17');
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.partial);
    expect(h.view.readableItemFor('17'), isNull);
    expect(h.view.readableItemFor('63'), isNotNull);
    expect(
        h.view.snapshot.availableEntries
            .where((entry) => h.view.readableItemFor(entry.id) != null),
        hasLength(63));
  });
  test(
      'a modified transport payload is isolated by per-file SHA and retried individually',
      () async {
    final h = await _Harness.create(List.filled(64, 1024));
    h.tamperOnce = true;
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/object'), 1);
    expect(h.source.reads['0'], 2);
    expect(h.source.reads['63'], 1);
  });
  test(
      'malformed archive or expired plan falls back without losing valid objects',
      () async {
    for (final malformed in [true, false]) {
      final h = await _Harness.create(List.filled(4, 1024));
      h.invalidFrameOnce = malformed;
      h.expireOnce = !malformed;
      expect((await h.client.syncCollection(h.view)).status,
          LibrarySyncStatus.complete);
      expect(h.count('/v2/object'), 4);
    }
  });
  test('old server capability 404 keeps the original per-file protocol',
      () async {
    final h = await _Harness.create(List.filled(4, 1024));
    h.legacy = true;
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/batch-prepare'), 0);
    expect(h.count('/v2/prepare'), 4);
    expect(h.count('/v2/object'), 4);
  });
  test(
      'old client algorithm continues to use unchanged routes on the new server',
      () async {
    final h = await _Harness.create(List.filled(4, 1024));
    h.client.enableSmallFileBatches = false;
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.complete);
    expect(h.count('/v2/transfer-capabilities'), 0);
    expect(h.count('/v2/prepare'), 4);
    expect(h.count('/v2/object'), 4);
  });
  test(
      'cancel after the first microbatch; reopen and retry only remaining files',
      () async {
    final h = await _Harness.create(List.filled(129, 1024));
    final cancel = SyncCancellation();
    final result = await h.client.syncCollection(h.view, cancellation: cancel,
        onProgress: (progress) {
      if (progress.processed == 64) cancel.cancel();
    });
    expect(result.status, LibrarySyncStatus.cancelled);
    final reopened = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: '${h.root.path}/replica'));
    expect(
        reopened.snapshot.availableEntries
            .where((entry) => reopened.readableItemFor(entry.id) != null),
        hasLength(64));
    final client =
        await SyncClient.open(stateDirectory: '${h.root.path}/client');
    expect((await client.syncCollection(reopened)).downloaded, 65);
    expect(h.source.reads['0'], 1);
    expect(h.source.reads['64'], 1);
  });
  test('resolved file moved outside the chosen folder is never transferred',
      () async {
    final h = await _Harness.create(List.filled(4, 1024));
    h.source.movedId = '1';
    expect((await h.client.syncCollection(h.view)).status,
        LibrarySyncStatus.partial);
    expect(h.source.reads.containsKey('1'), isFalse);
    expect(h.view.readableItemFor('1'), isNull);
    expect(h.view.readableItemFor('3'), isNotNull);
  });
  test(
      '64-bit text mask includes bit 63 and tokens remain bound to the paired peer',
      () async {
    final h = await _Harness.create(List.filled(64, 1024));
    final response = await h.raw('POST', '/v2/batch-prepare', body: {
      'items': [
        for (var i = 0; i < 64; i++)
          {'entryId': '$i', 'sourceId': 's', 'revisionId': 'r$i'}
      ]
    });
    expect(response.$1, 200);
    final token =
        (jsonDecode(utf8.decode(response.$2)) as Map)['batchId'] as String;
    final objects = await h.raw(
        'GET', '/v2/batch-object?batchId=$token&mask=8000000000000001');
    final frames =
        await decodeSmallFileBatch(Stream.value(objects.$2)).toList();
    expect(frames.map((frame) => frame.entryId), ['0', '63']);
    expect(
        (await h.raw('GET', '/v2/batch-object?batchId=$token&mask=1',
                token: 'unpaired-test-token'))
            .$1,
        401);
    final other = await SyncClient.pair(
        baseUri: h.server.uri,
        code: h.server.createPairingCode(),
        stateDirectory: '${h.root.path}/other');
    final otherState = jsonDecode(
            await File('${other.stateDirectory}/client.json').readAsString())
        as Map;
    expect(
        (await h.raw('GET', '/v2/batch-object?batchId=$token&mask=1',
                token: otherState['token'] as String))
            .$1,
        410);
  });
  test('oversized framing fails before payload allocation', () async {
    final prefix = ByteData(16)
      ..setUint32(0, 0x53524231)
      ..setUint32(4, 1)
      ..setUint32(8, 1)
      ..setUint32(12, SmallFileBatchLimits.objectBytes + 1);
    await expectLater(
        decodeSmallFileBatch(Stream.value(prefix.buffer.asUint8List()))
            .toList(),
        throwsFormatException);
  });
}
