import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:library_sync/library_sync.dart';
import 'package:test/test.dart';
import 'sync_test.dart' show Harness, entry;

List<(LibrarySyncPhase, int, int)> values(List<LibrarySyncProgress> events) =>
    events.map((e) => (e.phase, e.processed, e.total)).toList();

Future<SyncClient> clientForEndpoint(Harness h, Uri uri) async {
  final json = await h.clientJson();
  json['baseUri'] = uri.toString();
  await File(h.path('client/client.json')).writeAsString(jsonEncode(json));
  return SyncClient.open(stateDirectory: h.path('client'));
}

void main() {
  test(
      'progress counts verified and reused targets, excludes missing, commits last',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    h.source.bytes.addAll({'a': bytes, 'b': bytes});
    h.source.setEntries([
      entry('a', 'r', 'a.pdf', bytes),
      entry('b', 'r', 'b.pdf', bytes),
      entry('missing', 'r', 'missing.pdf', bytes, missing: true)
    ]);
    final events = <LibrarySyncProgress>[];
    final observed = <(LibrarySyncPhase, int, int, bool, bool)>[];
    final result = await h.client!.syncLibrary(h.replica, onProgress: (e) {
      events.add(e);
      // Assertions stay outside the callback: observer errors are swallowed.
      observed.add((
        e.phase,
        e.processed,
        h.replica.verificationStats.downloadObjectsVerified,
        h.replica.manifest != null,
        File(h.path('replica/manifest.json')).existsSync()
      ));
    });
    expect(result.status, LibrarySyncStatus.complete);
    expect(result.failure, isNull);
    expect(result.downloaded, 2);
    expect(values(events), [
      (LibrarySyncPhase.transferring, 0, 2),
      (LibrarySyncPhase.transferring, 1, 2),
      (LibrarySyncPhase.transferring, 2, 2),
      (LibrarySyncPhase.committing, 2, 2),
      (LibrarySyncPhase.complete, 2, 2)
    ]);
    expect(observed, [
      (LibrarySyncPhase.transferring, 0, 0, false, false),
      (LibrarySyncPhase.transferring, 1, 1, false, false),
      (LibrarySyncPhase.transferring, 2, 2, false, false),
      (LibrarySyncPhase.committing, 2, 2, false, false),
      (LibrarySyncPhase.complete, 2, 2, true, true)
    ]);
    expect(h.replica.manifest!.entries, hasLength(3));
    expect(h.replica.verificationStats.localHashBytesRead, 0);
    final reopened =
        await ReplicaLibraryView.open(rootDirectory: h.path('replica'));
    final reused = <LibrarySyncProgress>[];
    final repeat =
        await h.client!.syncLibrary(reopened, onProgress: reused.add);
    expect(repeat.status, LibrarySyncStatus.complete);
    expect(repeat.downloaded, 0);
    expect(values(reused), values(events));
    expect(h.source.opened, hasLength(2));
    expect(reopened.verificationStats.localHashBytesRead, 0);
    expect(reopened.verificationStats.downloadBytesReceived, 0);
  });

  test(
      'empty manifest has truthful zero targets and a post-commit complete event',
      () async {
    final h = await Harness.create();
    final events = <LibrarySyncProgress>[];
    final result =
        await h.client!.syncLibrary(h.replica, onProgress: events.add);
    expect(result.status, LibrarySyncStatus.complete);
    expect(values(events), [
      (LibrarySyncPhase.transferring, 0, 0),
      (LibrarySyncPhase.committing, 0, 0),
      (LibrarySyncPhase.complete, 0, 0)
    ]);
    expect(h.replica.manifest, isNotNull);
  });

  test(
      'bad hash cannot advance progress; retry counts the retained complete object',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('right');
    h.source.bytes.addAll({'a': bytes, 'b': utf8.encode('wrong')});
    h.source.setEntries(
        [entry('a', 'r', 'a.pdf', bytes), entry('b', 'r', 'b.pdf', bytes)]);
    final events = <LibrarySyncProgress>[];
    final result =
        await h.client!.syncLibrary(h.replica, onProgress: events.add);
    expect(result.status, LibrarySyncStatus.partial);
    expect(result.failure, LibrarySyncFailure.integrity);
    expect(result.downloaded, 1);
    expect(values(events), [
      (LibrarySyncPhase.transferring, 0, 2),
      (LibrarySyncPhase.transferring, 1, 2)
    ]);
    expect(h.replica.manifest, isNull);
    expect(
        Directory(h.path('replica/objects'))
            .listSync()
            .any((e) => e.path.contains('.part.')),
        isFalse);
    h.source.bytes['b'] = bytes;
    final retryEvents = <LibrarySyncProgress>[];
    final retry =
        await h.client!.syncLibrary(h.replica, onProgress: retryEvents.add);
    expect(retry.status, LibrarySyncStatus.complete);
    expect(retry.downloaded, 1);
    expect(retryEvents.last.processed, 2);
    expect(retryEvents.last.phase, LibrarySyncPhase.complete);
    expect(h.replica.verificationStats.localHashBytesRead, 0);
  });

  test('cancel after a verified object does not report commit or complete',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    h.source.bytes.addAll({'a': bytes, 'b': bytes});
    h.source.setEntries(
        [entry('a', 'r', 'a.pdf', bytes), entry('b', 'r', 'b.pdf', bytes)]);
    final events = <LibrarySyncProgress>[];
    final cancellation = SyncCancellation();
    final result = await h.client!
        .syncLibrary(h.replica, cancellation: cancellation, onProgress: (e) {
      events.add(e);
      if (e.processed == 1) cancellation.cancel();
    });
    expect(result.status, LibrarySyncStatus.cancelled);
    expect(result.failure, LibrarySyncFailure.cancelled);
    expect(result.downloaded, 1);
    expect(values(events), [
      (LibrarySyncPhase.transferring, 0, 2),
      (LibrarySyncPhase.transferring, 1, 2)
    ]);
    expect(h.replica.manifest, isNull);
    expect(h.source.opened, ['a/r']);
  });

  test(
      'declared length mismatch is typed integrity and leaves no complete object',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    final target = entry('a', 'r', 'a.pdf', bytes);
    for (final received in [
      bytes.sublist(1),
      [...bytes, 0]
    ]) {
      await expectLater(h.replica.receiveObject(target, Stream.value(received)),
          throwsA(isA<LibraryContentIntegrityException>()));
      expect(File(h.replica.objectPath(target)).existsSync(), isFalse);
      expect(Directory(h.path('replica/objects')).listSync(), isEmpty);
    }
    expect(h.replica.verificationStats.downloadObjectsVerified, 0);
  });

  test(
      'synchronous and asynchronous observer errors cannot change a committed result',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    h.source.bytes['a'] = bytes;
    h.source.setEntries([entry('a', 'r', 'a.pdf', bytes)]);
    final events = <LibrarySyncProgress>[];
    final result = await h.client!.syncLibrary(h.replica, onProgress: (e) {
      events.add(e);
      if (e.processed == 0 || e.phase == LibrarySyncPhase.complete) {
        throw StateError('observer only');
      }
      return Future<void>.error(StateError('asynchronous observer only'));
    });
    await Future<void>.delayed(Duration.zero);
    expect(result.status, LibrarySyncStatus.complete);
    expect(result.failure, isNull);
    expect(result.error, isNull);
    expect(events.last.phase, LibrarySyncPhase.complete);
    expect(h.replica.snapshot.entries, hasLength(1));
    final reopened =
        await ReplicaLibraryView.open(rootDirectory: h.path('replica'));
    expect(reopened.snapshot.entries, hasLength(1));
    expect(reopened.verificationStats.localHashBytesRead, 0);
  });

  test('a never-ending observer cannot block completion or active cancellation',
      () async {
    final h = await Harness.create();
    final pendingObserver = Completer<void>();
    final bytes = utf8.encode('score');
    h.source.bytes['a'] = bytes;
    h.source.setEntries([entry('a', 'r', 'a.pdf', bytes)]);
    final completed = await h.client!
        .syncLibrary(h.replica, onProgress: (_) => pendingObserver.future)
        .timeout(const Duration(seconds: 2));
    expect(completed.status, LibrarySyncStatus.complete);
    h.source.bytes['b'] = bytes;
    h.source.setEntries(
        [entry('a', 'r', 'a.pdf', bytes), entry('b', 'r', 'b.pdf', bytes)]);
    h.source.hangId = 'b';
    h.source.requested = Completer<void>();
    final gate = h.source.release = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final cancellation = SyncCancellation();
    final active = h.client!.syncLibrary(h.replica,
        cancellation: cancellation, onProgress: (_) => pendingObserver.future);
    await h.source.requested!.future.timeout(const Duration(seconds: 2));
    cancellation.cancel();
    final cancelled = await active.timeout(const Duration(seconds: 2));
    expect(cancelled.failure, LibrarySyncFailure.cancelled);
    expect(cancelled.status, LibrarySyncStatus.cancelled);
    expect(h.replica.manifest!.entries.map((e) => e.entryId), ['a']);
    expect(pendingObserver.isCompleted, isFalse);
    gate.complete();
  });

  test(
      'different-library failure preserves committed data and emits no target progress',
      () async {
    final h = await Harness.create();
    await h.client!.syncLibrary(h.replica);
    h.source.value =
        SyncManifest(libraryId: 'other', entries: [], folders: ['']);
    final events = <LibrarySyncProgress>[];
    final result =
        await h.client!.syncLibrary(h.replica, onProgress: events.add);
    expect(result.status, LibrarySyncStatus.partial);
    expect(result.failure, LibrarySyncFailure.differentLibrary);
    expect(h.replica.manifest!.libraryId, 'library');
    expect(events, isEmpty);
  });

  test(
      'source-not-ready uses a typed safe protocol code; source diagnostics never leak',
      () async {
    final h = await Harness.create();
    h.source.manifestFailure = LibrarySourceNotReady();
    final raw = await h.raw('/manifest');
    expect(raw.$1, 503);
    expect(jsonDecode(raw.$2), {
      'error': 'Source library is not ready for sync.',
      'code': 'source_not_ready'
    });
    final result = await h.client!.syncLibrary(h.replica);
    expect(result.failure, LibrarySyncFailure.sourceNotReady);
    expect(result.status, LibrarySyncStatus.partial);
    const secret = 'C:\\private-scores\\secret.pdf Bearer private-token';
    // Even a source throwing the public protocol exception cannot echo details.
    h.source.manifestFailure = const SyncProtocolException(secret, 503);
    final generic = await h.raw('/manifest');
    expect(generic.$1, 503);
    expect(generic.$2, isNot(contains(secret)));
    expect(generic.$2, isNot(contains('private-token')));
    expect(jsonDecode(generic.$2), {'error': 'Sync operation failed.'});
    final unknown = await h.client!.syncLibrary(h.replica);
    expect(unknown.failure, LibrarySyncFailure.unknown);
    expect(unknown.error, isNot(contains('private-token')));
    expect(h.replica.manifest, isNull);
  });

  test('connection refusal and a truncated transfer are connection failures',
      () async {
    final h = await Harness.create();
    final endpoint = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = endpoint.port;
    await endpoint.close();
    final disconnected = await clientForEndpoint(
        h, Uri(scheme: 'http', host: '127.0.0.1', port: port));
    final refused = await disconnected.syncLibrary(h.replica);
    expect(refused.failure, LibrarySyncFailure.connection);
    final bytes = utf8.encode('score content');
    h.source.bytes['a'] = bytes;
    h.source.setEntries([entry('a', 'r', 'a.pdf', bytes)]);
    h.source.failId = 'a';
    final events = <LibrarySyncProgress>[];
    final truncated =
        await h.client!.syncLibrary(h.replica, onProgress: events.add);
    expect(truncated.failure, LibrarySyncFailure.connection);
    expect(truncated.downloaded, 0);
    expect(values(events), [(LibrarySyncPhase.transferring, 0, 1)]);
    expect(h.replica.manifest, isNull);
  });

  test('rejected bearer is authentication and does not expose credentials',
      () async {
    final h = await Harness.create();
    final json = await h.clientJson();
    json['token'] = 'invalid-private-token';
    await File(h.path('client/client.json')).writeAsString(jsonEncode(json));
    final client = await SyncClient.open(stateDirectory: h.path('client'));
    final result = await client.syncLibrary(h.replica);
    expect(result.failure, LibrarySyncFailure.authentication);
    expect(result.error, isNot(contains('invalid-private-token')));
    expect(result.downloaded, 0);
  });

  test(
      'manifest format and unrecognized peer codes stay unknown, not content integrity',
      () async {
    final h = await Harness.create();
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => remote.close(force: true));
    var status = 200;
    var body = '{"protocol":999}';
    remote.listen((request) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
    final client = await clientForEndpoint(
        h, Uri(scheme: 'http', host: '127.0.0.1', port: remote.port));
    expect((await client.syncLibrary(h.replica)).failure,
        LibrarySyncFailure.unknown);
    status = 503;
    body = '{"code":"unrecognized_source_error","error":"not exposed"}';
    final unknownCode = await client.syncLibrary(h.replica);
    expect(unknownCode.failure, LibrarySyncFailure.unknown);
    expect(unknownCode.error, isNot(contains('not exposed')));
    expect(h.replica.manifest, isNull);
  });

  test(
      'a local commit failure has no complete event despite all objects being verified',
      () async {
    final h = await Harness.create();
    final bytes = utf8.encode('score');
    h.source.bytes['a'] = bytes;
    h.source.setEntries([entry('a', 'r', 'a.pdf', bytes)]);
    final events = <LibrarySyncProgress>[];
    final result = await h.client!.syncLibrary(h.replica, onProgress: (e) {
      events.add(e);
      if (e.phase == LibrarySyncPhase.committing) {
        Directory(h.path('replica/manifest.json')).createSync();
      }
    });
    expect(result.failure, LibrarySyncFailure.localStorage);
    expect(result.status, LibrarySyncStatus.partial);
    expect(result.downloaded, 1);
    expect(values(events), [
      (LibrarySyncPhase.transferring, 0, 1),
      (LibrarySyncPhase.transferring, 1, 1),
      (LibrarySyncPhase.committing, 1, 1)
    ]);
    expect(h.replica.manifest, isNull);
    expect(h.replica.verificationStats.localHashBytesRead, 0);
    expect(result.error, isNot(contains(h.path('replica'))));
  });
}
