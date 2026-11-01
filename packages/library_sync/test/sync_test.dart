import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:test/test.dart';

ManifestEntry entry(String id, String rev, String path, List<int> bytes,
        {bool missing = false}) =>
    ManifestEntry(
        entryId: id,
        revisionId: rev,
        relativePath: path,
        hash: sha256.convert(bytes).toString(),
        length: bytes.length,
        format: p.posix.extension(path).substring(1),
        missing: missing);

class FakeSource implements LibrarySource {
  SyncManifest value =
      SyncManifest(libraryId: 'library', entries: [], folders: ['', '甲', '乙']);
  final bytes = <String, List<int>>{};
  String? failId;
  String? hangId;
  Object? manifestFailure;
  Completer<void>? requested;
  Completer<void>? release;
  final opened = <String>[];
  @override
  Future<SyncManifest> manifest() async {
    if (manifestFailure != null) throw manifestFailure!;
    return value;
  }

  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async {
    opened.add('$id/$revision');
    if (requested?.isCompleted == false) requested!.complete();
    return _stream(id);
  }

  Stream<List<int>> _stream(String id) async* {
    final data = bytes[id]!;
    final gate = release;
    if (id == hangId) {
      yield data.take(1).toList();
      await gate!.future;
      yield data.skip(1).toList();
      return;
    }
    if (id == failId) {
      yield data.take(data.length ~/ 2).toList();
      throw const FileSystemException('Injected source interruption.');
    }
    yield data;
  }

  void setEntries(List<ManifestEntry> entries) {
    value = SyncManifest(
        libraryId: value.libraryId, entries: entries, folders: value.folders);
  }
}

class Harness {
  Harness(this.dir, this.source, this.serverStore, this.clientStore);
  final Directory dir;
  final FakeSource source;
  final ReaderStateStore serverStore, clientStore;
  late SyncServer server;
  SyncClient? client;
  late ReplicaLibraryView replica;
  String path(String name) => p.join(dir.path, name);
  static Future<Harness> create(
      {bool pair = true, Duration timeout = const Duration(seconds: 2)}) async {
    final dir = await Directory.systemTemp.createTemp('library-sync-');
    final h = Harness(
        dir,
        FakeSource(),
        await ReaderStateStore.open(
            statePath: p.join(dir.path, 'server-reader.json')),
        await ReaderStateStore.open(
            statePath: p.join(dir.path, 'client-reader.json')));
    h.server = await SyncServer.start(
        source: h.source,
        readerStore: h.serverStore,
        stateDirectory: h.path('server'),
        ioTimeout: timeout);
    addTearDown(() async {
      await h.server.close();
      await dir.delete(recursive: true);
    });
    h.replica = await ReplicaLibraryView.open(rootDirectory: h.path('replica'));
    if (pair) {
      h.client = await SyncClient.pair(
          baseUri: h.server.uri,
          code: h.server.createPairingCode(),
          stateDirectory: h.path('client'),
          ioTimeout: timeout);
    }
    return h;
  }

  Future<Map<String, dynamic>> clientJson() async => Map<String, dynamic>.from(
      jsonDecode(await File(path('client/client.json')).readAsString()) as Map);
  Future<(int, String)> raw(String path,
      {String method = 'GET', Object? body, bool auth = true}) async {
    final http = HttpClient();
    try {
      final request = await http.openUrl(method, server.uri.resolve(path));
      if (auth)
        request.headers
            .set('authorization', 'Bearer ${(await clientJson())['token']}');
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    } finally {
      http.close(force: true);
    }
  }
}

final page = PageKey(entryId: 'entry', revisionId: 'revision', pageNumber: 1);
final pen = StrokeStyle(
    tool: AnnotationTool.pen, argb: 0xff202020, widthFraction: .003);
Future<AnnotationStroke> draw(ReaderStateStore store, [double x = .2]) =>
    store.addStroke(page, style: pen, points: [NormalizedPoint(x, .3)]);

void main() {
  test(
      'authentication is mandatory; pairing code is single use; tokens are 32 bytes',
      () async {
    final h = await Harness.create(pair: false);
    expect((await h.raw('/manifest', auth: false)).$1, 401);
    expect(
        (await h.raw('/object?entryId=x&revisionId=y', auth: false)).$1, 401);
    final code = h.server.createPairingCode();
    h.client = await SyncClient.pair(
        baseUri: h.server.uri, code: code, stateDirectory: h.path('client'));
    final token = (await h.clientJson())['token'] as String;
    expect(base64Url.decode(base64Url.normalize(token)), hasLength(32));
    await expectLater(
        SyncClient.pair(
            baseUri: h.server.uri,
            code: code,
            stateDirectory: h.path('another-client')),
        throwsA(isA<SyncProtocolException>()));
    expect((await h.raw('/object?entryId=..%2F..%2Fsecret&revisionId=bad')).$1,
        404);
    expect((await h.raw('/manifest')).$1, 200);
  });
  test('expired codes and five failed guesses close the pairing window',
      () async {
    final h = await Harness.create(pair: false);
    final expired = h.server.createPairingCode(validity: Duration.zero);
    expect(
        (await h.raw('/pair',
                method: 'POST', body: {'code': expired}, auth: false))
            .$1,
        403);
    final valid = h.server.createPairingCode();
    for (var i = 0; i < 5; i++) {
      expect(
          (await h.raw('/pair',
                  method: 'POST', body: {'code': 'wrong'}, auth: false))
              .$1,
          403);
    }
    expect(
        (await h.raw('/pair',
                method: 'POST', body: {'code': valid}, auth: false))
            .$1,
        403);
  });
  test(
      'first full transfer, repeated zero-download sync, portable IDs and offline reopen',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score bytes');
    h.source.bytes['../C:身份/甲'] = bytes;
    h.source.bytes['other'] = bytes;
    h.source.setEntries([
      entry('../C:身份/甲', 'rev/一', '甲/同名.pdf', bytes),
      entry('other', 'rev/二', '乙/同名.pdf', bytes)
    ]);
    final first = await h.client!.syncLibrary(h.replica);
    expect(first.status, LibrarySyncStatus.complete);
    expect(first.downloaded, 2);
    expect(h.replica.verificationStats.localHashBytesRead, 0);
    expect(h.replica.verificationStats.downloadBytesReceived, bytes.length * 2);
    final manifestJson = jsonEncode(h.replica.manifest!.toJson());
    expect(manifestJson, isNot(contains('rootPath')));
    expect(manifestJson, isNot(contains('platformFileId')));
    expect((await h.client!.syncLibrary(h.replica)).downloaded, 0);
    expect(h.replica.verificationStats.localHashBytesRead, 0);
    final reopened =
        await ReplicaLibraryView.open(rootDirectory: h.path('replica'));
    expect(reopened.verificationStats.localHashBytesRead, 0);
    expect((await h.client!.syncLibrary(reopened)).downloaded, 0);
    expect(reopened.verificationStats.localHashBytesRead, 0);
    expect(reopened.verificationStats.downloadBytesReceived, 0);
    expect(reopened.search('同名'), hasLength(2));
    expect(reopened.listFolder('甲').entries.single.id, '../C:身份/甲');
    expect(
        reopened.snapshot.availableEntries
            .every((e) => e.availability == ContentAvailability.ready),
        isTrue);
    for (final e in reopened.snapshot.availableEntries) {
      expect(await File(reopened.absolutePathFor(e)).readAsBytes(), bytes);
      expect(p.isWithin(h.path('replica/objects'), reopened.absolutePathFor(e)),
          isTrue);
    }
  });
  test('incremental revision and missing propagation retain old bytes',
      () async {
    final h = await Harness.create();
    final old = utf8.encode('old'), changed = utf8.encode('new score');
    h.source.bytes.addAll({'a': old, 'b': old});
    h.source.setEntries(
        [entry('a', 'r1', '甲/a.pdf', old), entry('b', 'r1', '乙/b.png', old)]);
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.complete);
    final oldEntry = h.replica.snapshot.entryById('a')!;
    final oldPath = h.replica.absolutePathFor(oldEntry);
    h.source.bytes['a'] = changed;
    h.source.setEntries([
      entry('a', 'r2', '乙/renamed.pdf', changed),
      entry('b', 'r1', '乙/b.png', old, missing: true)
    ]);
    final result = await h.client!.syncLibrary(h.replica);
    expect(result.status, LibrarySyncStatus.complete);
    expect(result.downloaded, 1);
    expect(h.replica.snapshot.entryById('a')!.currentRevisionId, 'r2');
    expect(h.replica.snapshot.entryById('b')!.status, EntryStatus.missing);
    expect(await File(oldPath).readAsBytes(), old);
    expect(await File(h.replica.absolutePathFor(oldEntry)).readAsBytes(), old);
  });
  test(
      'interruption retains committed old manifest and complete objects; retry downloads only unfinished',
      () async {
    final h = await Harness.create();
    final old = utf8.encode('old'), changed = utf8.encode('changed score');
    h.source.bytes.addAll({'a': old, 'b': old});
    h.source.setEntries(
        [entry('a', 'r1', '甲/a.pdf', old), entry('b', 'r1', '乙/b.pdf', old)]);
    await h.client!.syncLibrary(h.replica);
    final oldPath =
        h.replica.absolutePathFor(h.replica.snapshot.entryById('a')!);
    h.source.bytes.addAll({'a': changed, 'b': changed});
    h.source.setEntries([
      entry('a', 'r2', '甲/a.pdf', changed),
      entry('b', 'r2', '乙/b.pdf', changed)
    ]);
    h.source.failId = 'b';
    final interrupted = await h.client!.syncLibrary(h.replica);
    expect(interrupted.status, LibrarySyncStatus.partial);
    expect(interrupted.downloaded, 1);
    expect(h.replica.snapshot.entryById('a')!.currentRevisionId, 'r1');
    expect(
        (await ReplicaLibraryView.open(rootDirectory: h.path('replica')))
            .snapshot
            .entryById('a')!
            .currentRevisionId,
        'r1');
    expect(await File(oldPath).readAsBytes(), old);
    expect(
        Directory(h.path('replica/objects'))
            .listSync()
            .any((e) => e.path.contains('.part.')),
        isFalse);
    h.source.failId = null;
    final retry = await h.client!.syncLibrary(h.replica);
    expect(retry.status, LibrarySyncStatus.complete);
    expect(retry.downloaded, 1);
  });
  test('bad hash and source change never become ready', () async {
    final h = await Harness.create();
    final expected = utf8.encode('right');
    h.source.bytes['a'] = utf8.encode('wrong');
    h.source.setEntries([entry('a', 'r1', '甲/a.pdf', expected)]);
    final result = await h.client!.syncLibrary(h.replica);
    expect(result.status, LibrarySyncStatus.partial);
    expect(h.replica.snapshot.availableEntries, isEmpty);
    expect(await File(h.path('replica/manifest.json')).exists(), isFalse);
    h.source.bytes['a'] = expected;
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.complete);
  });
  test('portable manifest rejects path escapes and mismatched formats', () {
    for (final path in [
      '../secret.pdf',
      '/a.pdf',
      'x\\a.pdf',
      'C:/a.pdf',
      'a//b.pdf',
      './a.pdf'
    ]) {
      expect(() => entry('a', 'r', path, [1]), throwsFormatException);
    }
    expect(
        () => ManifestEntry(
            entryId: 'a',
            revisionId: 'r',
            relativePath: 'a.exe',
            hash: sha256.convert([1]).toString(),
            length: 1,
            format: 'pdf',
            missing: false),
        throwsFormatException);
  });
  test('cancellation preserves old complete data and permits retry', () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    h.source.bytes['a'] = bytes;
    h.source.setEntries([entry('a', 'r1', '甲/a.pdf', bytes)]);
    final cancellation = SyncCancellation()..cancel();
    expect(
        (await h.client!.syncLibrary(h.replica, cancellation: cancellation))
            .status,
        LibrarySyncStatus.cancelled);
    expect(h.replica.manifest, isNull);
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.complete);
  });
  test('two offline ends append strokes and lists, and converge after reopen',
      () async {
    final h = await Harness.create();
    await draw(h.serverStore, .1);
    await draw(h.clientStore, .9);
    await h.serverStore.createSetList('Windows');
    await h.clientStore.createSetList('iPad');
    await h.client!.syncReaderState(h.clientStore);
    expect(h.serverStore.snapshot.strokesFor(page), hasLength(2));
    expect(h.clientStore.snapshot.strokesFor(page), hasLength(2));
    expect(h.clientStore.snapshot.activeSetLists.map((l) => l.name).toSet(),
        {'Windows', 'iPad'});
    final reopenedClient =
        await SyncClient.open(stateDirectory: h.path('client'));
    final reopenedStore =
        await ReaderStateStore.open(statePath: h.path('client-reader.json'));
    await reopenedClient.syncReaderState(reopenedStore);
    expect(reopenedStore.snapshot.conflicts, isEmpty);
    expect(reopenedStore.snapshot.strokesFor(page), hasLength(2));
    expect((await h.clientJson())['pending'], isNull);
  });
  test(
      'same-object offline rename/reorder conflict keeps both names/orders and does not accumulate',
      () async {
    final h = await Harness.create();
    final list = await h.serverStore.createSetList('base');
    final a = await h.serverStore.addItem(list.id, 'a');
    await h.serverStore.addItem(list.id, 'b');
    final c = await h.serverStore.addItem(list.id, 'c');
    await h.client!.syncReaderState(h.clientStore);
    await h.serverStore.renameSetList(list.id, 'Windows-name');
    await h.serverStore.reorderItem(list.id, a.id, 2);
    await h.clientStore.renameSetList(list.id, 'iPad-name');
    await h.clientStore.reorderItem(list.id, c.id, 0);
    await h.serverStore.addItem(list.id, 'server-new');
    await h.clientStore.addItem(list.id, 'client-new');
    await h.client!.syncReaderState(h.clientStore);
    final conflicts = h.clientStore.snapshot.conflicts;
    expect(conflicts, hasLength(1));
    final recovered = [conflicts.single.first, conflicts.single.second]
        .map((j) => ScoreSetList.fromJson(Map<String, dynamic>.from(j)))
        .toList();
    expect(recovered.map((l) => l.name).toSet(), {'Windows-name', 'iPad-name'});
    expect(recovered.map((l) => l.items.first.id).toSet(), {
      c.id,
      h.serverStore.snapshot
          .setListById(list.id)!
          .items
          .firstWhere((i) => i.entryId == 'b')
          .id
    });
    expect(
        h.clientStore.snapshot.setListById(list.id)!.activeItems, hasLength(5));
    await h.client!.syncReaderState(h.clientStore);
    expect(h.clientStore.snapshot.conflicts.map((c) => c.id),
        conflicts.map((c) => c.id));
    expect(h.serverStore.snapshot.conflicts.map((c) => c.id),
        conflicts.map((c) => c.id));
  });
  test(
      'client edits while waiting are merged against sent snapshot and survive',
      () async {
    final h = await Harness.create();
    final list = await h.serverStore.createSetList('base');
    await h.client!.syncReaderState(h.clientStore);
    await h.serverStore.renameSetList(list.id, 'server');
    await h.client!.syncReaderState(h.clientStore, afterResponse: () async {
      await draw(h.clientStore);
      await h.clientStore.renameSetList(list.id, 'client-during-response');
    });
    expect(h.clientStore.snapshot.strokesFor(page), hasLength(1));
    expect(h.clientStore.snapshot.conflicts.single.kind, 'setList');
    await h.client!.syncReaderState(h.clientStore);
    expect(h.serverStore.snapshot.strokesFor(page), hasLength(1));
  });
  test(
      'interrupted response resumes durable pending request after server/client restart',
      () async {
    final h = await Harness.create();
    await draw(h.serverStore);
    await draw(h.clientStore);
    final baselineBefore = (await h.clientJson())['baselineId'];
    await expectLater(
        h.client!.syncReaderState(h.clientStore, afterResponse: () async {
          throw StateError(
              'Injected client interruption after durable response.');
        }),
        throwsStateError);
    expect((await h.clientJson())['baselineId'], baselineBefore);
    final pending = (await h.clientJson())['pending'] as Map;
    expect(pending['response'], isNotNull);
    final port = h.server.port;
    await h.server.close();
    h.server = await SyncServer.start(
        source: h.source,
        readerStore: h.serverStore,
        stateDirectory: h.path('server'),
        port: port);
    final reopenedClient =
        await SyncClient.open(stateDirectory: h.path('client'));
    await draw(h.clientStore, .8);
    await reopenedClient.syncReaderState(h.clientStore);
    expect(h.clientStore.snapshot.strokesFor(page), hasLength(3));
    expect((await h.clientJson())['pending'], isNull);
    await reopenedClient.syncReaderState(h.clientStore);
    expect(h.serverStore.snapshot.strokesFor(page), hasLength(3));
    expect(h.serverStore.snapshot.conflicts, isEmpty);
  });
  test(
      'server duplicate request returns same response and rejects changed request body',
      () async {
    final h = await Harness.create();
    await draw(h.clientStore);
    final body = {
      'requestId': 'repeat-request',
      'baselineId': 'initial',
      'snapshot': h.clientStore.snapshot.toJson()
    };
    final first = await h.raw('/state', method: 'POST', body: body);
    expect(first.$1, 200);
    final generation = h.serverStore.snapshot.generation;
    final second = await h.raw('/state', method: 'POST', body: body);
    expect(second, first);
    expect(h.serverStore.snapshot.generation, generation);
    expect(
        (await h.raw('/state',
                method: 'POST',
                body: {...body, 'snapshot': ReaderSnapshot.empty().toJson()}))
            .$1,
        409);
    final response = jsonDecode(first.$2) as Map;
    final ack = {
      'requestId': body['requestId'],
      'baselineId': response['baselineId']
    };
    expect((await h.raw('/ack', method: 'POST', body: ack)).$1, 200);
    expect((await h.raw('/ack', method: 'POST', body: ack)).$1, 200);
    expect(await h.raw('/state', method: 'POST', body: body), first);
  });
  test('failed ack cannot replay committed merge over newer client edits',
      () async {
    final h = await Harness.create();
    final list = await h.serverStore.createSetList('base');
    await h.client!.syncReaderState(h.clientStore);
    await h.serverStore.renameSetList(list.id, 'remote');
    final cancellation = SyncCancellation();
    await expectLater(
        h.client!.syncReaderState(h.clientStore, cancellation: cancellation,
            afterMerge: () async {
          cancellation.cancel();
        }),
        throwsA(isA<SyncCancelled>()));
    expect(h.clientStore.snapshot.setListById(list.id)!.name, 'remote');
    await h.clientStore.renameSetList(list.id, 'newest-local');
    final reopened = await SyncClient.open(stateDirectory: h.path('client'));
    await reopened.syncReaderState(h.clientStore);
    expect(h.clientStore.snapshot.setListById(list.id)!.name, 'newest-local');
    expect(h.clientStore.snapshot.conflicts, isEmpty);
    expect((await h.clientJson())['pending'], isNull);
    await reopened.syncReaderState(h.clientStore);
    expect(h.serverStore.snapshot.setListById(list.id)!.name, 'newest-local');
  });
  test(
      'active transfer cancellation and idle read timeout leave no temporary or ready object',
      () async {
    final h = await Harness.create();
    final data = utf8.encode('score data');
    h.source.bytes['a'] = data;
    h.source.setEntries([entry('a', 'r', '甲/a.pdf', data)]);
    h.source.hangId = 'a';
    h.source.requested = Completer<void>();
    h.source.release = Completer<void>();
    final cancellation = SyncCancellation();
    final transfer =
        h.client!.syncLibrary(h.replica, cancellation: cancellation);
    await h.source.requested!.future;
    cancellation.cancel();
    final cancelled = await transfer;
    expect(cancelled.status, LibrarySyncStatus.cancelled);
    expect(cancelled.failure, LibrarySyncFailure.cancelled);
    h.source.release!.complete();
    expect(h.replica.manifest, isNull);

    h.source.release = Completer<void>();
    final shortClient = await SyncClient.open(
        stateDirectory: h.path('client'),
        ioTimeout: const Duration(milliseconds: 100));
    final timeout = await shortClient
        .syncLibrary(h.replica)
        .timeout(const Duration(seconds: 3));
    expect(timeout.status, LibrarySyncStatus.partial);
    expect(timeout.failure, LibrarySyncFailure.connection);
    h.source.release!.complete();
    expect(h.replica.manifest, isNull);
    expect(
        Directory(h.path('replica/objects'))
            .listSync()
            .any((e) => e.path.contains('.part.')),
        isFalse);
    h.source.hangId = null;
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.complete);
  });
  test(
      'server merge survives pending-save failure; replay cannot change request contents',
      () async {
    final h = await Harness.create();
    await draw(h.clientStore);
    final body = {
      'requestId': 'crash-boundary',
      'baselineId': 'initial',
      'snapshot': h.clientStore.snapshot.toJson()
    };
    final blocker = Directory(h.path('server/peers.json.backup'));
    await blocker.create();
    expect((await h.raw('/state', method: 'POST', body: body)).$1, 400);
    expect(h.serverStore.snapshot.strokesFor(page), hasLength(1));
    final generation = h.serverStore.snapshot.generation;
    await blocker.delete();
    final port = h.server.port;
    await h.server.close();
    h.server = await SyncServer.start(
        source: h.source,
        readerStore: h.serverStore,
        stateDirectory: h.path('server'),
        port: port);
    expect(
        (await h.raw('/state',
                method: 'POST',
                body: {...body, 'snapshot': ReaderSnapshot.empty().toJson()}))
            .$1,
        409);
    expect((await h.raw('/state', method: 'POST', body: body)).$1, 200);
    expect(h.serverStore.snapshot.generation, generation);
    expect(h.serverStore.snapshot.conflicts, isEmpty);
  });
  test(
      'linked replica object directory is rejected without writing outside the replica',
      () async {
    final h = await Harness.create();
    final outside = Directory(h.path('outside'));
    await outside.create();
    try {
      await Link(h.path('replica/objects')).create(outside.path);
    } on FileSystemException {
      markTestSkipped(
          'Windows symbolic-link creation is not available to this user.');
      return;
    }
    final data = utf8.encode('score');
    h.source.bytes['a'] = data;
    h.source.setEntries([entry('a', 'r', '甲/a.pdf', data)]);
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.partial);
    expect(outside.listSync(), isEmpty);
  });
  test('corrupt cached bytes are unreadable on reopen and repaired by retry',
      () async {
    final h = await Harness.create();
    final data = utf8.encode('score');
    h.source.bytes['a'] = data;
    h.source.setEntries([entry('a', 'r', '甲/a.pdf', data)]);
    await h.client!.syncLibrary(h.replica);
    final path = h.replica.absolutePathFor(h.replica.snapshot.entries.single);
    await File(path).writeAsString('wrong');
    final reopened =
        await ReplicaLibraryView.open(rootDirectory: h.path('replica'));
    expect(reopened.snapshot.entries.single.availability,
        ContentAvailability.unreadable);
    final repaired = await h.client!.syncLibrary(reopened);
    expect(repaired.status, LibrarySyncStatus.complete);
    expect(repaired.downloaded, 1);
    expect(
        await File(reopened.absolutePathFor(reopened.snapshot.entries.single))
            .readAsBytes(),
        data);
  });
  test(
      'core source manifest excludes local identifiers and file allowlist blocks stale revision',
      () async {
    final dir = await Directory.systemTemp.createTemp('sync-core-');
    addTearDown(() => dir.delete(recursive: true));
    final root = Directory(p.join(dir.path, 'scores'))..createSync();
    await File(p.join(root.path, 'a.pdf')).writeAsString('score');
    final catalog = await LibraryCatalog.open(
        rootPath: root.path, statePath: p.join(dir.path, 'catalog.json'));
    await catalog.rescan();
    final source =
        CatalogLibrarySource(catalog: catalog, libraryId: 'stable-library');
    final manifest = await source.manifest();
    expect(jsonEncode(manifest.toJson()), isNot(contains(root.path)));
    final e = manifest.entries.single;
    expect(
        await (await source.openObject(e.entryId, e.revisionId))
            .expand((x) => x)
            .toList(),
        utf8.encode('score'));
    await expectLater(
        source.openObject(e.entryId, 'unknown'), throwsStateError);
    await expectLater(
        source.openObject('../outside', e.revisionId), throwsStateError);
    await expectLater(
        SyncServer.start(
            source: source,
            readerStore: await ReaderStateStore.open(
                statePath: p.join(dir.path, 'reader.json')),
            stateDirectory: p.join(root.path, 'sync-state')),
        throwsArgumentError);
    expect(await Directory(p.join(root.path, 'sync-state')).exists(), isFalse);
  });
  test('deferred live source cannot report a complete offline manifest',
      () async {
    final dir = await Directory.systemTemp.createTemp('sync-deferred-');
    addTearDown(() => dir.delete(recursive: true));
    final root = Directory(p.join(dir.path, 'scores'))..createSync();
    await File(p.join(root.path, 'deferred.pdf')).writeAsString('score');
    final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: p.join(dir.path, 'catalog.json'),
        fileAccessProbe: (_, __) async => FileAccess.deferred);
    await catalog.rescan();
    final source = CatalogLibrarySource(catalog: catalog, libraryId: 'library');
    await expectLater(source.manifest(), throwsA(isA<LibrarySourceNotReady>()));
    expect(
        await File(p.join(root.path, 'deferred.pdf')).readAsString(), 'score');
  });
  test(
      'replica refuses a different library identity without replacing committed content',
      () async {
    final h = await Harness.create();
    final data = utf8.encode('score');
    h.source.bytes['a'] = data;
    h.source.setEntries([entry('a', 'r', '甲/a.pdf', data)]);
    await h.client!.syncLibrary(h.replica);
    final path = h.replica.absolutePathFor(h.replica.snapshot.entries.single);
    h.source.value = SyncManifest(
        libraryId: 'different-library', entries: [], folders: ['']);
    expect((await h.client!.syncLibrary(h.replica)).status,
        LibrarySyncStatus.partial);
    expect(h.replica.manifest!.libraryId, 'library');
    expect(await File(path).readAsBytes(), data);
  });
}
