import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/sync/ios_background_transfer.dart';

class _Source implements LibrarySource, CollectionLibrarySource {
  final data = {
    'a': [1, 2, 3],
    'b': [4, 5],
    'other': [6],
  };
  int prepares = 0, opens = 0;
  final prepared = <String>{};
  CatalogItem item(String id, {bool resolved = false}) => CatalogItem(
    sourceId: id == 'other' ? 'other-source' : 'scores',
    entryId: id,
    revisionId: resolved ? 'resolved-$id' : 'metadata-$id',
    relativePath: '$id.pdf',
    length: data[id]!.length,
    format: 'pdf',
    hash: resolved ? sha256.convert(data[id]!).toString() : null,
  );
  @override
  Future<CollectionIndex> index() async => CollectionIndex(
    id: 'collection',
    sources: const [
      LibrarySourceInfo('scores', 'Scores'),
      LibrarySourceInfo('other-source', 'Other'),
    ],
    entries: data.keys
        .map((id) => item(id, resolved: prepared.contains(id)))
        .toList(),
    folders: const {
      'scores': [''],
      'other-source': [''],
    },
  );
  @override
  Future<CatalogItem> prepare(String id, String revision) async {
    prepares++;
    prepared.add(id);
    return item(id, resolved: true);
  }

  @override
  Future<Stream<List<int>>> openSelectedObject(
    String id,
    String revision,
  ) async {
    opens++;
    return Stream.value(data[id]!);
  }

  @override
  Future<SyncManifest> manifest() async => throw LibrarySourceNotReady();
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async =>
      throw StateError('No legacy transfer');
}

/// A durable fake of the platform boundary, not a simulation of iOS scheduling.
/// Restart tests deliberately replace both Dart adapter and in-memory native
/// fake; only staged files and the persisted platform reply survive.
class _NativeBoundary {
  _NativeBoundary(this.root, this.source);
  final Directory root;
  final _Source source;
  final calls = <String>[];
  Map<String, dynamic> jobs = {};
  List<String> enqueuedIds = [];
  String? namespace;
  bool hold = false, badBytes = false;
  int pauses = 0, acknowledgements = 0;
  final firstStatus = Completer<void>();
  File get ledger => File('${root.path}/native-ledger.json');
  Future<void> save() =>
      ledger.writeAsString(jsonEncode(jobs), flush: true).then((_) {});
  Future<void> load() async {
    jobs = Map<String, dynamic>.from(
      jsonDecode(await ledger.readAsString()) as Map,
    );
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = Map<String, dynamic>.from(call.arguments as Map);
    namespace = args['namespace'] as String;
    switch (call.method) {
      case 'enqueue':
        final items = (args['items'] as List)
            .map(
              (v) => CatalogItem.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        enqueuedIds = items.map((item) => item.entryId).toList();
        for (final original in items) {
          final item = args['prepare'] == true
              ? await source.prepare(original.entryId, original.revisionId)
              : original;
          final stage = File('${root.path}/${item.entryId}.stage');
          await stage.writeAsBytes(
            badBytes ? [99] : source.data[item.entryId]!,
          );
          jobs[item.entryId] = {
            'state': hold ? 'running' : 'staged',
            'item': item.toJson(),
            'path': stage.path,
            'requestedRevisionId': original.revisionId,
          };
        }
        await save();
        return null;
      case 'status':
        if (!firstStatus.isCompleted) firstStatus.complete();
        return jobs[args['entryId']] ?? {'state': 'missing'};
      case 'staged':
        return jobs.values.where((v) => v['state'] == 'staged').toList();
      case 'acknowledge':
        final value = jobs.remove(args['entryId']);
        if (value != null) await File(value['path'] as String).delete();
        acknowledgements++;
        await save();
        return null;
      case 'acknowledgeMany':
        for (final id in args['entryIds'] as List) {
          final value = jobs.remove(id);
          if (value != null) await File(value['path'] as String).delete();
          acknowledgements++;
        }
        await save();
        return null;
      case 'pause':
        pauses++;
        for (final value in jobs.values) {
          if (value['state'] == 'running') value['state'] = 'paused';
        }
        await save();
        return null;
      case 'resume':
        for (final value in jobs.values) {
          if (value['state'] == 'paused') value['state'] = 'staged';
        }
        await save();
        return null;
      case 'activity':
        return {
          'pending': jobs.values.where((v) => v['state'] == 'running').length,
          'staged': jobs.values.where((v) => v['state'] == 'staged').length,
          'failed': 0,
          'paused': 0,
        };
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const channel = MethodChannel('test/background-transfer');
  late Directory root;
  late _Source source;
  late SyncServer server;
  late SyncClient client;
  late ReplicaCollectionView view;
  late _NativeBoundary native;
  late IosBackgroundTransfer transfer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('background-contract-');
    source = _Source();
    server = await SyncServer.start(
      source: source,
      collectionSource: source,
      readerStore: await ReaderStateStore.open(
        statePath: '${root.path}/state.json',
      ),
      stateDirectory: '${root.path}/server',
    );
    client = await SyncClient.pair(
      baseUri: server.uri,
      code: server.createPairingCode(),
      stateDirectory: '${root.path}/client',
    );
    view = await ReplicaCollectionView.open(
      await ReplicaLibraryView.open(rootDirectory: '${root.path}/replica'),
    );
    await client.refreshCollectionIndex(view);
    await view.select(
      OfflineRule(sourceId: 'scores', folder: '', selected: true),
    );
    native = _NativeBoundary(root, source);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
    transfer = IosBackgroundTransfer(
      channel: channel,
      pollInterval: const Duration(milliseconds: 1),
    );
    client.backgroundTransfer = transfer;
  });
  tearDown(() async {
    transfer.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await server.close();
    await root.delete(recursive: true);
  });

  test('whole selected batch is queued before waiting; only verified imports are acknowledged', () async {
    final result = await client.syncCollection(view);
    expect(result.status, LibrarySyncStatus.complete);
    expect(result.downloaded, 2);
    expect(native.enqueuedIds, ['a', 'b']);
    expect(
      native.calls.indexOf('enqueue'),
      lessThan(native.calls.indexOf('status')),
    );
    expect(source.prepares, 2);
    expect(source.opens, 0); // Object bytes came through the platform boundary.
    expect(native.acknowledgements, 2);
    expect(view.readableItemFor('a')!.revisionId, 'resolved-a');
    expect(await File(view.presentationPathFor('b')).readAsBytes(), [4, 5]);
    expect(view.readableItemFor('other'), isNull);
    expect(native.jobs, isEmpty);
  });

  test('cancel pauses the durable batch; new adapter resumes exactly the queued IDs', () async {
    native.hold = true;
    final cancellation = SyncCancellation();
    final operation = client.syncCollection(
      view,
      onlyEntryIds: {'a'},
      cancellation: cancellation,
    );
    await native.firstStatus.future;
    cancellation.cancel();
    expect((await operation).status, LibrarySyncStatus.cancelled);
    expect(native.pauses, greaterThan(0));
    expect(native.enqueuedIds, ['a']);
    expect(view.readableItemFor('a'), isNull);
    transfer.dispose();
    final restored = _NativeBoundary(root, source);
    await restored.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, restored.handle);
    transfer = IosBackgroundTransfer(channel: channel);
    client.backgroundTransfer = transfer;
    await transfer.resume(client.backgroundTransferNamespace);
    await server
        .close(); // Recovery/import must work with the paired PC offline.
    server = await SyncServer.start(
      source: source,
      readerStore: await ReaderStateStore.open(
        statePath: '${root.path}/spare.json',
      ),
      stateDirectory: '${root.path}/spare',
    );
    expect(await client.recoverBackgroundCollection(view), 1);
    expect(view.readableItemFor('a'), isNotNull);
    expect(view.readableItemFor('b'), isNull);
    expect(restored.jobs, isEmpty);
  });

  test(
    'metadata refresh neither submits nor prunes a paused selected batch',
    () async {
      native.hold = true;
      await transfer.enqueue(
        namespace: client.backgroundTransferNamespace,
        origin: client.baseUri,
        bearerToken: 'test-only',
        items: [source.item('a')],
        prepare: true,
        cancellation: null,
      );
      await transfer.pause(client.backgroundTransferNamespace);
      final before = jsonEncode(native.jobs);
      final calls = native.calls.length;
      await client.refreshCollectionIndex(view);
      expect(jsonEncode(native.jobs), before);
      expect(native.calls.length, calls);
    },
  );

  test('restart reconciles staged new revisions and discards empty/corrupt stages without poisoning retry', () async {
    await transfer.enqueue(
      namespace: client.backgroundTransferNamespace,
      origin: client.baseUri,
      bearerToken: 'test-only',
      items: [source.item('a'), source.item('b')],
      prepare: true,
      cancellation: null,
    );
    await File(native.jobs['b']['path'] as String).writeAsBytes([]);
    transfer.dispose();
    final restored = _NativeBoundary(root, source);
    await restored.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, restored.handle);
    transfer = IosBackgroundTransfer(channel: channel);
    client.backgroundTransfer = transfer;
    final reopened = await ReplicaCollectionView.open(
      await ReplicaLibraryView.open(rootDirectory: '${root.path}/replica'),
    );
    expect(await client.recoverBackgroundCollection(reopened), 1);
    expect(reopened.readableItemFor('a'), isNotNull);
    expect(reopened.readableItemFor('b'), isNull);
    expect(restored.jobs, isEmpty);
    expect(
      (await client.syncCollection(reopened)).status,
      LibrarySyncStatus.complete,
    );
    expect(restored.enqueuedIds, ['b']);
  });

  test('changed selection drops recovered stage without importing unwanted content', () async {
    await transfer.enqueue(
      namespace: client.backgroundTransferNamespace,
      origin: client.baseUri,
      bearerToken: 'test-only',
      items: [source.item('a')],
      prepare: true,
      cancellation: null,
    );
    await view.select(
      OfflineRule(sourceId: 'scores', entryId: 'a', selected: false),
    );
    expect(await client.recoverBackgroundCollection(view), 0);
    expect(view.readableItemFor('a'), isNull);
    expect(native.jobs, isEmpty);
  });

  test('bad staged bytes never report success or replace a previous ready revision', () async {
    expect(
      (await client.syncCollection(view)).status,
      LibrarySyncStatus.complete,
    );
    final oldPath = view.presentationPathFor('a');
    await transfer.enqueue(
      namespace: client.backgroundTransferNamespace,
      origin: client.baseUri,
      bearerToken: 'test-only',
      items: [source.item('a')],
      prepare: true,
      cancellation: null,
    );
    await File(native.jobs['a']['path'] as String).writeAsBytes([99]);
    expect(await client.recoverBackgroundCollection(view), 0);
    expect(await File(oldPath).readAsBytes(), [1, 2, 3]);
    expect(native.jobs, isEmpty);
  });

  test(
    'native integrity/auth/storage failures retain their domain classification',
    () async {
      final item = source.item('a');
      for (final failure in ['integrity', 'storage', 'http']) {
        native.jobs['a'] = {
          'state': 'error',
          'failure': failure,
          'status': 401,
        };
        await expectLater(
          transfer.wait(client.backgroundTransferNamespace, item, null),
          throwsA(
            failure == 'integrity'
                ? isA<LibraryContentIntegrityException>()
                : failure == 'storage'
                ? isA<FileSystemException>()
                : isA<SyncProtocolException>(),
          ),
        );
      }
    },
  );

  test('microbatch metadata is fetched once and acknowledged in one native checkpoint', () async {
    await transfer.enqueue(
      namespace: client.backgroundTransferNamespace,
      origin: client.baseUri,
      bearerToken: 'test-only',
      prepare: true,
      smallFileBatches: true,
      cancellation: null,
      items: [source.item('a'), source.item('b')],
    );
    native.jobs['a']['batchKey'] = 'synthetic-batch';
    native.jobs['b']['batchKey'] = 'synthetic-batch';
    var metadataRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'batchMetadata') {
            metadataRequests++;
            return [native.jobs['a']['item'], native.jobs['b']['item']];
          }
          return native.handle(call);
        });
    final a = await transfer.wait(
      client.backgroundTransferNamespace,
      source.item('a'),
      null,
    );
    final b = await transfer.wait(
      client.backgroundTransferNamespace,
      source.item('b'),
      null,
    );
    expect(a.companions, hasLength(2));
    expect(b.companions, hasLength(2));
    expect(metadataRequests, 1);
    await transfer.acknowledgeMany(client.backgroundTransferNamespace, [
      a.item,
      b.item,
    ]);
    expect(
      native.calls.where((call) => call == 'acknowledgeMany'),
      hasLength(1),
    );
    expect(native.jobs, isEmpty);
  });

  test(
    'thirty thousand planned objects cross the platform boundary in one batch',
    () async {
      var batches = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'enqueue');
            batches++;
            final args = Map<String, dynamic>.from(call.arguments as Map);
            expect((args['items'] as List).length, 30000);
            expect(args['selection'], isNotNull);
            return null;
          });
      await transfer.enqueue(
        namespace: client.backgroundTransferNamespace,
        origin: client.baseUri,
        bearerToken: 'test-only',
        prepare: true,
        cancellation: null,
        selection: OfflineSelection([
          OfflineRule(sourceId: 'scores', folder: '', selected: true),
        ]),
        items: List.generate(
          30000,
          (i) => CatalogItem(
            sourceId: 'scores',
            entryId: 'entry-$i',
            revisionId: 'revision-$i',
            relativePath: '$i.pdf',
            length: 10,
            format: 'pdf',
          ),
        ),
      );
      expect(batches, 1);
    },
  );
}
