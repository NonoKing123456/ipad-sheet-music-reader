import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';

class _NoLegacy implements LibrarySource {
  @override
  Future<SyncManifest> manifest() async => throw LibrarySourceNotReady();
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async =>
      throw StateError('no legacy');
}

class _CountedSource implements CollectionLibrarySource {
  _CountedSource(this.base);
  final CatalogCollectionSource base;
  var opens = 0;
  bool logicalLarge = true;
  @override
  Future<CollectionIndex> index() async {
    final i = await base.index();
    return CollectionIndex(
      id: i.id,
      sources: i.sources,
      folders: i.folders,
      legacyLibraryId: i.legacyLibraryId,
      entries: [
        ...i.entries,
        if (logicalLarge)
          CatalogItem(
            sourceId: i.sources.last.id,
            entryId: 'logical-large',
            revisionId: 'unhashed',
            relativePath: 'archive/large.pdf',
            length: 120 * 1024 * 1024 * 1024,
            format: 'pdf',
          ),
      ],
    );
  }

  @override
  Future<CatalogItem> prepare(String id, String revision) =>
      base.prepare(id, revision);
  @override
  Future<Stream<List<int>>> openSelectedObject(String id, String revision) {
    opens++;
    return base.openSelectedObject(id, revision);
  }
}

class _GateSource extends _CountedSource {
  _GateSource(super.base) {
    logicalLarge = false;
  }
  final started = Completer<void>(), release = Completer<void>();
  bool gateEnabled = true, partialFirst = false;
  @override
  Future<Stream<List<int>>> openSelectedObject(
    String id,
    String revision,
  ) async {
    final stream = await super.openSelectedObject(id, revision);
    if (!gateEnabled ||
        !(await base.index()).entry(id)!.relativePath.startsWith('z')) {
      return stream;
    }
    Stream<List<int>> delayed() async* {
      if (partialFirst) {
        var held = false;
        await for (final chunk in stream) {
          if (!held && chunk.isNotEmpty) {
            final split = chunk.length > 1 ? chunk.length ~/ 2 : 1;
            yield chunk.sublist(0, split);
            if (!started.isCompleted) started.complete();
            await release.future;
            if (chunk.length > split) yield chunk.sublist(split);
            held = true;
          } else {
            yield chunk;
          }
        }
      } else {
        if (!started.isCompleted) started.complete();
        await release.future;
        yield* stream;
      }
    }

    return delayed();
  }
}

void main() {
  test('last ready revision and its ink survive metadata update and interrupted new download until verified replacement; pending old download can be removed', () async {
    final dir = await Directory.systemTemp.createTemp('last-ready-');
    SyncServer? server;
    _GateSource? source;
    SyncCancellation? activeCancellation;
    Future<LibrarySyncResult>? activeJob;
    try {
      final root = await Directory('${dir.path}/scores').create();
      final file = File('${root.path}/z.png');
      await file.writeAsBytes([1, 2, 3]);
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
      );
      await catalog.rescan(metadataOnly: true);
      source =
          _GateSource(
              CatalogCollectionSource(
                id: 'c',
                bindings: () => [CatalogSourceBinding('new', 'new', catalog)],
              ),
            )
            ..gateEnabled = false
            ..partialFirst = true;
      final ink = await ReaderStateStore.open(
        statePath: '${dir.path}/ink.json',
      );
      server = await SyncServer.start(
        source: _NoLegacy(),
        collectionSource: source,
        readerStore: ink,
        stateDirectory: '${dir.path}/server',
      );
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final view = await ReplicaCollectionView.open(objects);
      await client.syncCollection(view);
      await view.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      expect(
        (await client.syncCollection(view)).status,
        LibrarySyncStatus.complete,
      );
      final old = view.index!.entries.single;
      final oldPath = view.presentationPathFor(old.entryId);
      final page = PageKey(
        entryId: old.entryId,
        revisionId: old.revisionId,
        pageNumber: 1,
      );
      await ink.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff112233,
          widthFraction: .004,
        ),
        points: [NormalizedPoint(.2, .3)],
      );
      final list = await ink.createSetList('keep');
      await ink.addItem(list.id, old.entryId);
      await view.select(
        OfflineRule(sourceId: 'new', folder: '', selected: false),
      );
      final newerBytes = List<int>.filled(32768, 4);
      await file.writeAsBytes(newerBytes);
      await catalog.rescan(metadataOnly: true);
      expect(
        (await client.syncCollection(view)).status,
        LibrarySyncStatus.complete,
      );
      final pending = view.index!.entries.single;
      expect(pending.hash, isNull);
      expect(pending.revisionId, isNot(old.revisionId));
      expect(view.isReady(pending), isFalse);
      expect(view.readableItemFor(old.entryId)!.revisionId, old.revisionId);
      expect(view.snapshot.entries.single.currentRevisionId, old.revisionId);
      expect(view.presentationPathFor(old.entryId), oldPath);
      await view.validateForRead(old.entryId, old.revisionId);
      await expectLater(
        view.validateForRead(old.entryId, pending.revisionId),
        throwsStateError,
      );
      expect(
        view.isReady(old),
        isTrue,
        reason:
            'a stale/new revision request cannot invalidate the valid fallback',
      );
      var reopened = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: objects.rootDirectory),
      );
      expect(
        reopened.snapshot.entries.single.currentRevisionId,
        old.revisionId,
      );
      await reopened.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      source.gateEnabled = true;
      final cancel = SyncCancellation();
      final job = client.syncCollection(reopened, cancellation: cancel);
      activeCancellation = cancel;
      activeJob = job;
      await source.started.future.timeout(const Duration(seconds: 3));
      for (
        var i = 0;
        i < 100 &&
            reopened.objects.verificationStats.downloadBytesReceived == 0;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        reopened.objects.verificationStats.downloadBytesReceived,
        greaterThan(0),
      );
      cancel.cancel();
      expect(
        (await job.timeout(const Duration(seconds: 3))).status,
        LibrarySyncStatus.cancelled,
      );
      source.release.complete();
      reopened = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: objects.rootDirectory),
      );
      expect(
        reopened.snapshot.entries.single.currentRevisionId,
        old.revisionId,
      );
      expect(reopened.isReady(reopened.index!.entries.single), isFalse);
      await reopened.validateForRead(old.entryId, old.revisionId);
      expect(
        await File(reopened.presentationPathFor(old.entryId)).readAsBytes(),
        [1, 2, 3],
      );
      expect(ink.snapshot.strokesFor(page), hasLength(1));
      expect(
        (await client.syncCollection(reopened)).status,
        LibrarySyncStatus.complete,
      );
      final current = reopened.index!.entries.single;
      expect(current.revisionId, pending.revisionId);
      expect(reopened.isReady(current), isTrue);
      expect(
        reopened.snapshot.entries.single.currentRevisionId,
        current.revisionId,
      );
      expect(
        await File(reopened.presentationPathFor(current.entryId)).readAsBytes(),
        newerBytes,
      );
      await expectLater(
        reopened.validateForRead(old.entryId, old.revisionId),
        throwsStateError,
      );
      expect(reopened.isReady(current), isTrue);
      expect(
        ink.snapshot.strokesFor(
          PageKey(
            entryId: current.entryId,
            revisionId: current.revisionId,
            pageNumber: 1,
          ),
        ),
        isEmpty,
      );
      await reopened.select(
        OfflineRule(sourceId: 'new', folder: '', selected: false),
      );
      await file.writeAsBytes([9, 9, 9, 9, 9, 9]);
      await catalog.rescan(metadataOnly: true);
      await client.syncCollection(reopened);
      expect(reopened.index!.entries.single.hash, isNull);
      final readablePath = reopened.presentationPathFor(current.entryId);
      await reopened.removeDownload(current.entryId);
      expect(await File(readablePath).exists(), isFalse);
      expect(
        reopened.snapshot.entries.single.availability,
        ContentAvailability.deferred,
      );
      expect(ink.snapshot.strokesFor(page), hasLength(1));
      expect(
        ink.snapshot.setListById(list.id)!.activeItems.single.entryId,
        old.entryId,
      );
    } finally {
      activeCancellation?.cancel();
      if (source != null && !source.release.isCompleted) {
        source.release.complete();
      }
      if (activeJob != null) {
        try {
          await activeJob.timeout(const Duration(seconds: 3));
        } catch (_) {
          /* Preserve the original assertion. */
        }
      }
      await server?.close();
      await dir.delete(recursive: true);
    }
  });

  test('resolved journal recovers completed objects when full index flush also fails and ignores an incomplete tail', () async {
    final dir = await Directory.systemTemp.createTemp('selected-journal-');
    SyncServer? server;
    var blocked = false;
    final objectDir = Directory('${dir.path}/replica/objects');
    final held = Directory('${dir.path}/held-objects');
    final indexFile = File('${dir.path}/replica/collection-v2.json');
    final heldIndex = File('${dir.path}/held-index.json');
    Future<void> restore() async {
      if (!blocked) return;
      await File(objectDir.path).delete();
      await held.rename(objectDir.path);
      await Directory(indexFile.path).delete();
      await heldIndex.rename(indexFile.path);
      blocked = false;
    }

    try {
      final root = await Directory('${dir.path}/scores').create();
      for (final name in ['a', 'b', 'c']) {
        await File('${root.path}/$name.png').writeAsBytes([1, 2, 3]);
      }
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
      );
      await catalog.rescan(metadataOnly: true);
      final source = _CountedSource(
        CatalogCollectionSource(
          id: 'c',
          bindings: () => [CatalogSourceBinding('new', 'new', catalog)],
        ),
      )..logicalLarge = false;
      server = await SyncServer.start(
        source: _NoLegacy(),
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${dir.path}/ink.json',
        ),
        stateDirectory: '${dir.path}/server',
      );
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final view = await ReplicaCollectionView.open(objects);
      await client.syncCollection(view);
      await view.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      final result = await client.syncCollection(
        view,
        onProgress: (progress) {
          if (progress.processed == 1 && !blocked) {
            objectDir.renameSync(held.path);
            File(objectDir.path).writeAsBytesSync([0]);
            indexFile.renameSync(heldIndex.path);
            Directory(indexFile.path).createSync();
            blocked = true;
          }
        },
      );
      expect(result.failure, LibrarySyncFailure.localStorage);
      expect(
        source.opens,
        2,
        reason: 'local failure stops before requesting the third object',
      );
      final journal = File(
        '${objects.rootDirectory}/selected-resolutions-v2.log',
      );
      expect(await journal.length(), greaterThan(0));
      await restore();
      final oldJson = jsonDecode(await indexFile.readAsString()) as Map;
      expect(
        ((oldJson['index'] as Map)['entries'] as List).every(
          (e) => (e as Map)['hash'] == null,
        ),
        isTrue,
        reason:
            'the global snapshot really failed to commit any resolved hashes',
      );
      await journal.writeAsString(
        '128:unfinished-tail',
        mode: FileMode.append,
        flush: true,
      );
      final reopenedObjects = await ReplicaLibraryView.open(
        rootDirectory: objects.rootDirectory,
      );
      final reopened = await ReplicaCollectionView.open(reopenedObjects);
      expect(reopened.index!.entries.where(reopened.isReady), hasLength(1));
      expect(
        reopened.index!.entries
            .singleWhere((e) => e.relativePath == 'c.png')
            .hash,
        isNull,
      );
      expect(
        reopened.index!.entries
            .singleWhere((e) => e.relativePath == 'b.png')
            .hash,
        isNotNull,
      );
      expect(
        reopened.isReady(
          reopened.index!.entries.singleWhere((e) => e.relativePath == 'b.png'),
        ),
        isFalse,
      );
      expect(
        reopenedObjects.verificationStats.localHashBytesRead,
        3,
        reason: 'recovery verifies the completed object; a journal record alone never means ready',
      );
      expect(
        await journal.length(),
        0,
        reason: 'successful full snapshot retires the journal',
      );
    } finally {
      await restore();
      await server?.close();
      await dir.delete(recursive: true);
    }
  });

  test('local write failure stops remaining selected requests and preserves completed objects for reopen', () async {
    final dir = await Directory.systemTemp.createTemp('selected-storage-');
    SyncServer? server;
    var blocked = false;
    final objectDir = Directory('${dir.path}/replica/objects');
    final held = Directory('${dir.path}/held-objects');
    try {
      final root = await Directory('${dir.path}/scores').create();
      for (final name in ['a', 'b', 'c']) {
        await File('${root.path}/$name.png').writeAsBytes([1, 2, 3]);
      }
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
      );
      await catalog.rescan(metadataOnly: true);
      final source = _CountedSource(
        CatalogCollectionSource(
          id: 'c',
          bindings: () => [CatalogSourceBinding('new', 'new', catalog)],
        ),
      )..logicalLarge = false;
      server = await SyncServer.start(
        source: _NoLegacy(),
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${dir.path}/ink.json',
        ),
        stateDirectory: '${dir.path}/server',
      );
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final view = await ReplicaCollectionView.open(objects);
      await client.syncCollection(view);
      await view.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      final result = await client.syncCollection(
        view,
        onProgress: (progress) {
          if (progress.processed == 1 && !blocked) {
            objectDir.renameSync(held.path);
            File(objectDir.path).writeAsBytesSync([0]);
            blocked = true;
          }
        },
      );
      expect(result.status, LibrarySyncStatus.partial);
      expect(result.failure, LibrarySyncFailure.localStorage);
      expect(
        source.opens,
        2,
        reason: 'the third selected object is never requested after a local write fails',
      );
      expect(catalog.contentHashOperations, 2);
      await File(objectDir.path).delete();
      await held.rename(objectDir.path);
      blocked = false;
      final reopenedObjects = await ReplicaLibraryView.open(
        rootDirectory: objects.rootDirectory,
      );
      final reopened = await ReplicaCollectionView.open(reopenedObjects);
      expect(reopened.index!.entries.where(reopened.isReady), hasLength(1));
      expect(
        reopened.index!.entries.where(reopened.selection.includes),
        hasLength(3),
      );
      expect(reopenedObjects.verificationStats.localHashBytesRead, 0);
    } finally {
      if (blocked) {
        await File(objectDir.path).delete();
        await held.rename(objectDir.path);
      }
      await server?.close();
      await dir.delete(recursive: true);
    }
  });

  test('metadata-only catalog hashes zero bytes, materializes only selected file, retains unknown identity and rejects a changing read', () async {
    final dir = await Directory.systemTemp.createTemp('metadata-only-');
    try {
      final root = await Directory('${dir.path}/scores').create();
      await File('${root.path}/a.png').writeAsBytes([1, 2, 3]);
      await File('${root.path}/b.png').writeAsBytes([4, 5, 6]);
      var change = false;
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
        fileAccessProbe: (path, stat) async {
          if (change) await File(path).writeAsBytes([8, 9, 10, 11]);
          return FileAccess.ordinary;
        },
      );
      await catalog.rescan(metadataOnly: true);
      expect(catalog.contentHashOperations, 0);
      expect(catalog.contentHashBytesRead, 0);
      final a = catalog.snapshot.entries.firstWhere(
        (e) => e.relativePath == 'a.png',
      );
      final b = catalog.snapshot.entries.firstWhere(
        (e) => e.relativePath == 'b.png',
      );
      expect(a.currentRevision.contentHash, isNull);
      final ready = await catalog.materialize(a.id);
      expect(ready.id, a.id);
      expect(ready.currentRevisionId, a.currentRevisionId);
      expect(catalog.contentHashOperations, 1);
      expect(catalog.contentHashBytesRead, 3);
      expect(
        catalog.snapshot.entryById(b.id)!.currentRevision.contentHash,
        isNull,
      );
      await catalog.rescan(metadataOnly: true);
      expect(catalog.contentHashOperations, 1);
      change = true;
      await expectLater(
        catalog.materialize(b.id),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        catalog.snapshot.entryById(b.id)!.currentRevision.contentHash,
        isNull,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('v2 logical 120GB directory commits with zero transfers; exact folder selection downloads only foo and survives reopen without hashing cached bytes', () async {
    final dir = await Directory.systemTemp.createTemp('selected-v2-');
    SyncServer? server;
    try {
      final root = await Directory('${dir.path}/root').create();
      await Directory('${root.path}/foo').create();
      await Directory('${root.path}/foobar').create();
      await File('${root.path}/foo/a.png').writeAsBytes([1, 2, 3, 4]);
      await File('${root.path}/foobar/a.png').writeAsBytes([5, 6, 7, 8]);
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
      );
      await catalog.rescan(metadataOnly: true);
      final source = _CountedSource(
        CatalogCollectionSource(
          id: 'collection',
          bindings: () => [CatalogSourceBinding('new', '新谱库', catalog)],
        ),
      );
      server = await SyncServer.start(
        source: _NoLegacy(),
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${dir.path}/reader.json',
        ),
        stateDirectory: '${dir.path}/server',
      );
      final client = (await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      ));
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final replica = await ReplicaCollectionView.open(objects);
      expect(
        (await client.syncCollection(replica)).status,
        LibrarySyncStatus.complete,
      );
      expect(
        replica.index!.entries.fold<int>(0, (n, e) => n + e.length),
        greaterThan(100 * 1024 * 1024 * 1024),
      );
      expect(source.opens, 0);
      expect(catalog.contentHashBytesRead, 0);
      expect(objects.verificationStats.downloadBytesReceived, 0);
      expect(replica.selection.rules, isEmpty);
      await replica.select(
        OfflineRule(sourceId: 'new', folder: 'foo', selected: true),
      );
      expect(
        replica.index!.entries
            .where(replica.selection.includes)
            .single
            .relativePath,
        'foo/a.png',
      );
      expect(
        (await client.syncCollection(replica)).status,
        LibrarySyncStatus.complete,
      );
      expect(source.opens, 1);
      expect(catalog.contentHashBytesRead, 4);
      expect(objects.verificationStats.downloadBytesReceived, 4);
      final ready = replica.index!.entries.singleWhere(replica.isReady);
      final path = replica.presentationPathFor(ready.entryId);
      await replica.select(
        OfflineRule(sourceId: 'new', folder: '', selected: false),
      );
      expect(await File(path).exists(), isTrue);
      final reopenedObjects = await ReplicaLibraryView.open(
        rootDirectory: objects.rootDirectory,
      );
      final reopened = await ReplicaCollectionView.open(reopenedObjects);
      expect(reopened.isReady(ready), isTrue);
      expect(reopenedObjects.verificationStats.localHashBytesRead, 0);
      expect((await client.syncCollection(reopened)).downloaded, 0);
      expect(source.opens, 1);
      await reopened.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      expect(
        reopened.index!.entries.where(reopened.selection.includes),
        hasLength(3),
        reason: 'explicit empty root means the whole one source, unlike empty selection',
      );
      final partial = await client.syncCollection(reopened);
      expect(partial.status, LibrarySyncStatus.partial);
      expect(
        partial.downloaded,
        1,
        reason: 'one unavailable selected item does not block other files',
      );
      expect(reopened.index!.entries.where(reopened.isReady), hasLength(2));
    } finally {
      await server?.close();
      await dir.delete(recursive: true);
    }
  });

  test('legacy transfer and migration retain IDs objects and full preference; v1 cannot see new source objects and removing a download retains ink', () async {
    final dir = await Directory.systemTemp.createTemp('legacy-v2-');
    SyncServer? server;
    try {
      final a = await Directory('${dir.path}/old').create();
      final b = await Directory('${dir.path}/new').create();
      await File('${a.path}/same.png').writeAsBytes([1, 2, 3]);
      await File('${b.path}/same.png').writeAsBytes([4, 5, 6]);
      final old = await LibraryCatalog.open(
        rootPath: a.path,
        statePath: '${dir.path}/a.json',
      );
      final fresh = await LibraryCatalog.open(
        rootPath: b.path,
        statePath: '${dir.path}/b.json',
      );
      await old.rescan();
      await fresh.rescan(metadataOnly: true);
      final item = old.snapshot.entries.single;
      final ink = await ReaderStateStore.open(
        statePath: '${dir.path}/ink.json',
      );
      final page = PageKey(
        entryId: item.id,
        revisionId: item.currentRevisionId,
        pageNumber: 1,
      );
      await ink.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff112233,
          widthFraction: .004,
        ),
        points: [NormalizedPoint(.2, .3)],
      );
      final list = await ink.createSetList('keep');
      await ink.addItem(list.id, item.id);
      final source = CatalogCollectionSource(
        id: 'legacy-library',
        legacyLibraryId: 'legacy-library',
        bindings: () => [
          CatalogSourceBinding('legacy', '谱库', old),
          CatalogSourceBinding('new', '谱库 (2)', fresh),
        ],
      );
      server = await SyncServer.start(
        source: CatalogLibrarySource(catalog: old, libraryId: 'legacy-library'),
        collectionSource: source,
        readerStore: ink,
        stateDirectory: '${dir.path}/server',
      );
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      expect(
        (await client.syncLibrary(objects)).status,
        LibrarySyncStatus.complete,
      );
      expect(objects.manifest!.entries.single.entryId, item.id);
      final oldPath = objects.presentationPathFor(item.id);
      final view = await ReplicaCollectionView.open(objects);
      expect(view.selection.includes(view.index!.entries.single), isTrue);
      expect(
        (await client.syncCollection(view)).status,
        LibrarySyncStatus.complete,
      );
      expect(view.index!.entries, hasLength(2));
      expect(view.presentationPathFor(item.id), oldPath);
      expect(view.isReady(view.index!.entry(item.id)!), isTrue);
      expect(fresh.contentHashBytesRead, 0);
      final extra = view.index!.entries.singleWhere((e) => e.sourceId == 'new');
      expect(extra.entryId, isNot(item.id));
      final peer = jsonDecode(
        await File('${dir.path}/client/client.json').readAsString(),
      ) as Map;
      final http = HttpClient();
      final request = await http.getUrl(
        server.uri
            .resolve('/object')
            .replace(
              queryParameters: {
                'entryId': extra.entryId,
                'revisionId': extra.revisionId,
              },
            ),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${peer['token']}',
      );
      final denied = await request.close();
      expect(denied.statusCode, 404);
      await denied.drain<void>();
      http.close(force: true);
      // A legacy client still sees only its original source after v2 metadata.
      expect(
        (await client.syncLibrary(objects)).status,
        LibrarySyncStatus.complete,
      );
      expect(objects.manifest!.entries, hasLength(1));
      await File(oldPath).writeAsBytes([9, 9, 9]);
      await expectLater(
        view.validateForRead(item.id, item.currentRevisionId),
        throwsStateError,
      );
      expect(view.isReady(view.index!.entry(item.id)!), isFalse);
      await view.removeDownload(item.id);
      expect(await File(oldPath).exists(), isFalse);
      expect(ink.snapshot.strokesFor(page), hasLength(1));
      expect(
        ink.snapshot.setListById(list.id)!.activeItems.single.entryId,
        item.id,
      );
      expect(
        ink.snapshot.strokesFor(
          PageKey(
            entryId: extra.entryId,
            revisionId: extra.revisionId,
            pageNumber: 1,
          ),
        ),
        isEmpty,
      );
    } finally {
      await server?.close();
      await dir.delete(recursive: true);
    }
  });

  test('cancelled selected transfer persists only verified completed objects, releases the replica lease and preserves cache after deselection', () async {
    final dir = await Directory.systemTemp.createTemp('selected-cancel-');
    SyncServer? server;
    _GateSource? source;
    try {
      final root = await Directory('${dir.path}/scores').create();
      await File('${root.path}/a.png').writeAsBytes([1, 2, 3]);
      await File('${root.path}/z.png').writeAsBytes([4, 5, 6]);
      final catalog = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
      );
      await catalog.rescan(metadataOnly: true);
      source = _GateSource(
        CatalogCollectionSource(
          id: 'c',
          bindings: () => [CatalogSourceBinding('new', 'new', catalog)],
        ),
      );
      server = await SyncServer.start(
        source: _NoLegacy(),
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${dir.path}/ink.json',
        ),
        stateDirectory: '${dir.path}/server',
      );
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final view = await ReplicaCollectionView.open(objects);
      await client.syncCollection(view);
      await view.select(
        OfflineRule(sourceId: 'new', folder: '', selected: true),
      );
      final cancel = SyncCancellation();
      final transfer = client.syncCollection(view, cancellation: cancel);
      await source.started.future.timeout(const Duration(seconds: 3));
      cancel.cancel();
      expect(
        (await transfer.timeout(const Duration(seconds: 3))).status,
        LibrarySyncStatus.cancelled,
      );
      await view
          .select(OfflineRule(sourceId: 'new', folder: '', selected: false))
          .timeout(const Duration(seconds: 3));
      expect(view.index!.entries.where(view.isReady), hasLength(1));
      final reopenedObjects = await ReplicaLibraryView.open(
        rootDirectory: objects.rootDirectory,
      );
      final reopened = await ReplicaCollectionView.open(reopenedObjects);
      expect(reopened.index!.entries.where(reopened.isReady), hasLength(1));
      expect(reopenedObjects.verificationStats.localHashBytesRead, 0);
      expect(
        reopened.index!.entries.where(reopened.selection.includes),
        isEmpty,
      );
    } finally {
      if (source != null && !source.release.isCompleted) {
        source.release.complete();
      }
      await server?.close();
      await dir.delete(recursive: true);
    }
  });
}
