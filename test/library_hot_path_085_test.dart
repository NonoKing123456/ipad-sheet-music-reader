import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==';

Future<void> _cleanup(Directory dir) async {
  final root = Directory.systemTemp.absolute.path;
  if (!dir.absolute.path.startsWith('$root${Platform.pathSeparator}')) {
    throw StateError('Invalid temporary root');
  }
  if (await dir.exists()) await dir.delete(recursive: true);
}

void main() {
  test('delayed stale scan reload cannot roll a later foreground sibling publication back', () async {
    final dir = await Directory.systemTemp.createTemp('reader-adopt-race-085-');
    final root = await Directory('${dir.path}/scores').create();
    await File('${root.path}/A.PNG').writeAsBytes(base64Decode(_png));
    await File('${root.path}/B.PNG').writeAsBytes(base64Decode(_png));
    final reloadRead = Completer<void>(), releaseReload = Completer<void>();
    var delayReload = false;
    late LibraryScanPacket stale;
    final library = LibraryController(
      dataDirectory: Directory('${dir.path}/app'),
      watchSource: false,
      scanRunner: (_, _, _) async => stale,
      catalogLoader: (root, state) async {
        final loaded = await LibraryCatalog.open(
          rootPath: root,
          statePath: state,
        );
        if (delayReload) {
          delayReload = false;
          reloadRead.complete();
          await releaseReload.future;
        }
        return loaded;
      },
    );
    try {
      await library.initialize();
      await library.selectRoot(root.path, metadataOnly: true);
      final initialScan = library.lastScan;
      final source = library.sources.single;
      final old = source.catalog;
      final snapshot = old.snapshot;
      stale = LibraryScanPacket(
        ScanResult(
          snapshot: snapshot,
          issues: [],
          inferredMoves: [],
          ambiguities: [],
          addedEntryIds: [],
          modifiedEntryIds: [],
          restoredEntryIds: [],
          missingEntryIds: [],
          hasIncompleteAreas: false,
        ),
        [],
        Duration.zero,
        old,
      );
      final a = snapshot.availableEntries.firstWhere(
        (e) => e.relativePath == 'A.PNG',
      );
      final b = snapshot.availableEntries.firstWhere(
        (e) => e.relativePath == 'B.PNG',
      );
      final external = await LibraryCatalog.open(
        rootPath: root.path,
        statePath: old.statePath,
      );
      await external.materialize(a.id);
      delayReload = true;
      final delayedScan = library.rescan(verifyAll: true);
      await reloadRead.future;
      await library.ensureReady(collectionEntryId(source.id, b.id));
      final foregroundGeneration =
          library.sources.single.catalog.snapshot.generation;
      expect(foregroundGeneration, snapshot.generation + 2);
      releaseReload.complete();
      await delayedScan;
      expect(
        identical(library.lastScan, initialScan),
        isTrue,
        reason:
            'stale scan diagnostics do not publish as a newer successful scan',
      );
      expect(
        library.sources.single.catalog.snapshot.generation,
        foregroundGeneration,
      );
      expect(
        library.sources.single.catalog.snapshot
            .entryById(a.id)!
            .currentRevision
            .contentHash,
        isNotNull,
      );
      expect(
        library.sources.single.catalog.snapshot
            .entryById(b.id)!
            .currentRevision
            .contentHash,
        isNotNull,
      );
      debugPrint(
        'HOT_PATH_085 delayed_scan_g2_after_foreground_g3=true no_sibling_rollback=true',
      );
      await File(old.statePath).writeAsString('broken primary');
      await library.ensureReady(collectionEntryId(source.id, a.id));
      expect(
        library.sources.single.catalog.snapshot.generation,
        snapshot.generation + 1,
        reason: 'a validated backup can replace an invalid newer in-memory publication',
      );
      expect(library.storageWarnings, isNotEmpty);
      await library.validateForRead(
        collectionEntryId(source.id, a.id),
        a.currentRevisionId,
      );
      await library.ensureReady(collectionEntryId(source.id, b.id));
      expect(
        library.sources.single.catalog.snapshot
            .entryById(b.id)!
            .currentRevision
            .contentHash,
        isNotNull,
      );
      debugPrint(
        'HOT_PATH_085 damaged_primary_recovers_lower_backup_without_restart=true subsequent_materialize=true',
      );
    } finally {
      if (!releaseReload.isCompleted) releaseReload.complete();
      library.dispose();
      await _cleanup(dir);
    }
  });

  test('51150-entry offline directory keeps structure across two real receives, selection and flush; visible lookups stay lazy', () async {
    final dir = await Directory.systemTemp.createTemp(
      'reader-offline-scale-085-',
    );
    final library = LibraryController(
      dataDirectory: Directory('${dir.path}/app'),
      watchSource: false,
    );
    SyncController? sync;
    try {
      await library.initialize();
      final workspace = ReaderWorkspace(
        await ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
      );
      sync = SyncController(library: library, workspace: workspace);
      await sync.initialize();
      final view = sync.collection!;
      final bytes = base64Decode(_png),
          hash = sha256.convert(base64Decode(_png)).toString();
      final items = [
        for (var i = 0; i < 51150; i++)
          CatalogItem(
            sourceId: 'source',
            entryId: 'e$i',
            revisionId: 'r1',
            relativePath: 'folder-${i < 2 ? 2312 : i % 2312}/score-$i.PNG',
            length: bytes.length,
            format: 'png',
          ),
      ];
      await view.updateIndex(
        CollectionIndex(
          id: 'scale',
          sources: const [
            LibrarySourceInfo('source', 'Synthetic'),
            LibrarySourceInfo('second', 'Other'),
          ],
          entries: [
            ...items,
            CatalogItem(
              sourceId: 'second',
              entryId: 'other',
              revisionId: 'r1',
              relativePath: 'folder-2312/score-0.PNG',
              length: bytes.length,
              format: 'png',
            ),
          ],
          folders: {
            'source': ['', for (var i = 0; i < 2313; i++) 'folder-$i'],
            'second': ['', 'folder-2312'],
          },
        ),
      );
      final structure = view.directory;
      final firstList = sync.offlineEntries(
        sourceId: 'source',
        folder: 'folder-0',
        query: '',
        withinFolder: false,
      );
      final beforeOther = firstList[1];
      expect(sync.offlineCount, 0);
      expect(sync.folderOfflineStatus(sourceId: 'source').total, 51150);
      for (var i = 0; i < 2; i++) {
        final original = items[i];
        final resolved = CatalogItem(
          sourceId: original.sourceId,
          entryId: original.entryId,
          revisionId: original.revisionId,
          relativePath: original.relativePath,
          length: bytes.length,
          hash: hash,
          format: 'png',
        );
        await view.receive(resolved, Stream.value(bytes));
        expect(
          identical(view.directory, structure),
          isTrue,
          reason: 'a completed download patches ancestor status, not the metadata structure',
        );
        expect(sync.sourceIdFor(original.entryId), 'source');
        expect(sync.hasPendingVersion(original.entryId), isFalse);
        expect(sync.locateOffline(original.entryId), isNotNull);
        expect(sync.offlineCount, i + 1);
        expect(
          sync.folderOfflineStatus(sourceId: 'source').currentReady,
          i + 1,
        );
        expect(sync.folderOfflineStatus(sourceId: 'source').total, 51150);
        expect(
          sync
              .folderOfflineStatus(sourceId: 'source', folder: 'folder-2312')
              .currentReady,
          i + 1,
        );
        expect(
          sync.needsOfflineDownload(sourceId: 'source', folder: 'folder-2312'),
          i == 0,
        );
        expect(
          sync
              .folderOfflineStatus(sourceId: 'second', folder: 'folder-2312')
              .currentReady,
          0,
        );
      }
      await view.select(
        OfflineRule(sourceId: 'source', entryId: 'e0', selected: true),
      );
      await view.flush();
      expect(
        identical(view.directory, structure),
        isTrue,
        reason: 'selection persistence and journal compaction preserve the structure index',
      );
      expect(
        identical(
          beforeOther,
          sync.offlineEntries(
            sourceId: 'source',
            folder: 'folder-0',
            query: '',
            withinFolder: false,
          )[1],
        ),
        isTrue,
      );
      expect(
        sync.offlineEntries(
          sourceId: 'source',
          folder: '',
          query: 'score-',
          withinFolder: false,
        ),
        hasLength(51151),
      );
      expect(sync.offlineCount, 2);
      final updatedBytes = [...bytes, 0];
      final update = CatalogItem(
        sourceId: 'source',
        entryId: 'e0',
        revisionId: 'r2',
        relativePath: items[0].relativePath,
        length: updatedBytes.length,
        hash: sha256.convert(updatedBytes).toString(),
        format: 'png',
      );
      await expectLater(
        view.receive(
          update,
          Stream.error(StateError('synthetic interruption')),
        ),
        throwsStateError,
      );
      expect(identical(view.directory, structure), isTrue);
      expect(sync.hasPendingVersion('e0'), isTrue);
      expect(
        sync.locateOffline('e0')!.revisionId,
        'r1',
        reason: 'a failed update retains the readable old revision',
      );
      expect(
        sync
            .folderOfflineStatus(sourceId: 'source', folder: 'folder-2312')
            .pendingUpdate,
        1,
      );
      expect(
        sync.needsOfflineDownload(sourceId: 'source', folder: 'folder-2312'),
        isTrue,
      );
      await view.flush();
      final reopened = await ReplicaCollectionView.open(sync.replica!);
      expect(reopened.readableItemFor('e0')!.revisionId, 'r1');
      expect(reopened.itemFor('e0')!.revisionId, 'r2');
      await view.receive(update, Stream.value(updatedBytes));
      expect(identical(view.directory, structure), isTrue);
      expect(sync.hasPendingVersion('e0'), isFalse);
      expect(sync.locateOffline('e0')!.revisionId, 'r2');
      debugPrint(
        'HOT_PATH_085 offline_entries=51150 folders=2313 real_receives=2 same_structure=true lazy_visible_entries=true selection_flush_stable=true',
      );
    } finally {
      if (sync != null) {
        sync.dispose();
        sync.workspace.dispose();
      }
      library.dispose();
      await _cleanup(dir);
    }
  });

  test('ready reads bypass a scan lock; stale generation and source metadata cannot use that fast path; scan yield leaves snapshot atomic', () async {
    final dir = await Directory.systemTemp.createTemp('reader-hot-085-');
    final source = await Directory('${dir.path}/scores/foo')
        .create(recursive: true);
    final a = await File('${source.path}/A.PNG')
        .writeAsBytes(base64Decode(_png));
    await File('${source.path}/B.PNG').writeAsBytes(base64Decode(_png));
    await File('${source.path}/C.PNG').writeAsBytes(base64Decode(_png));
    final state = '${dir.path}/catalog.json';
    try {
      final catalog = await LibraryCatalog.open(
        rootPath: source.parent.path,
        statePath: state,
      );
      await catalog.rescan(metadataOnly: true);
      final aId = catalog.snapshot.availableEntries
          .firstWhere((e) => e.relativePath.endsWith('A.PNG'))
          .id;
      final bId = catalog.snapshot.availableEntries
          .firstWhere((e) => e.relativePath.endsWith('B.PNG'))
          .id;
      final cId = catalog.snapshot.availableEntries
          .firstWhere((e) => e.relativePath.endsWith('C.PNG'))
          .id;
      await catalog.materialize(aId);
      final listing = catalog.listFolder('foo');
      expect(identical(listing, catalog.listFolder('foo')), isTrue);
      expect(
        identical(
          catalog.snapshot.availableEntries,
          catalog.snapshot.availableEntries,
        ),
        isTrue,
      );

      final entered = Completer<void>(), release = Completer<void>();
      final scanner = await LibraryCatalog.open(
        rootPath: source.parent.path,
        statePath: state,
        fileAccessProbe: (_, _) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return FileAccess.ordinary;
        },
      );
      var yieldRequested = false;
      final before = await File(state).readAsBytes();
      final scanning = scanner.rescan(
        verifyAll: true,
        shouldYield: () => yieldRequested,
      );
      final yielded = expectLater(scanning, throwsA(isA<CatalogScanYielded>()));
      await entered.future;
      final ready = await catalog.materialize(aId);
      expect(ready.currentRevision.contentHash, isNotNull);
      expect(
        await File(state).readAsBytes(),
        before,
        reason: 'read-only ready preparation does not rewrite catalogue',
      );
      yieldRequested = true;
      release.complete();
      await yielded;
      expect(
        await File(state).readAsBytes(),
        before,
        reason: 'yield before commit publishes no partial scan',
      );

      final oldSnapshot = catalog.snapshot;
      final preparing = await LibraryCatalog.open(
        rootPath: source.parent.path,
        statePath: state,
      );
      final patch = await preparing.materializeForPublication(
        bId,
        catalog.publication,
      );
      expect(patch.fallback, isNull);
      expect(await catalog.applyMaterialization(patch), isTrue);
      expect(
        identical(oldSnapshot.entryById(aId), catalog.snapshot.entryById(aId)),
        isTrue,
      );
      expect(oldSnapshot.entryById(bId)!.currentRevision.contentHash, isNull);
      expect(
        catalog.snapshot.entryById(bId)!.currentRevision.contentHash,
        isNotNull,
      );
      final stalePatch = await preparing.materializeForPublication(
        bId,
        catalog.publication,
      );

      final other = await LibraryCatalog.open(
        rootPath: source.parent.path,
        statePath: state,
      );
      await other.materialize(cId);
      expect(
        await catalog.applyMaterialization(stalePatch),
        isFalse,
        reason:
            'a newer external generation cannot be rolled back by an old patch',
      );
      expect(
        await catalog.readyIfUnchanged(aId),
        isNull,
        reason: 'another persisted generation invalidates cached ready state',
      );
      await catalog.materialize(aId);
      expect(
        catalog.snapshot.entryById(cId)!.currentRevision.contentHash,
        isNotNull,
        reason: 'reload preserves newer sibling materialization',
      );
      final oldRevision = catalog.snapshot.entryById(aId)!.currentRevisionId;
      await a.writeAsBytes([...base64Decode(_png), 0]);
      expect(await catalog.readyIfUnchanged(aId), isNull);
      expect(
        (await catalog.materialize(aId)).currentRevisionId,
        isNot(oldRevision),
      );
      expect(identical(listing, catalog.listFolder('foo')), isFalse);
      await File(state).writeAsString('broken primary');
      final recovered = await LibraryCatalog.open(
        rootPath: source.parent.path,
        statePath: state,
      );
      expect(recovered.storageWarnings, isNotEmpty);
      expect(
        await recovered.readyIfUnchanged(bId),
        isNotNull,
        reason: 'verified backup recovery retains read-only access',
      );
      debugPrint(
        'HOT_PATH_085 ready_lock_bypass=true generation_guard=true source_change_guard=true atomic_yield=true',
      );
    } finally {
      await _cleanup(dir);
    }
  });

  test('Windows and real HTTP selected preparation share foreground worker; view changes reuse entry identities and preserve selection scope', () async {
    final dir = await Directory.systemTemp.createTemp('reader-worker-085-');
    final library = LibraryController(
      dataDirectory: Directory('${dir.path}/computer'),
      watchSource: false,
    );
    final readerLibrary = LibraryController(
      dataDirectory: Directory('${dir.path}/ipad'),
      watchSource: false,
    );
    SyncController? computer, reader;
    try {
      final root = await Directory('${dir.path}/scores/foo')
          .create(recursive: true);
      await File('${root.path}/A.PNG').writeAsBytes(base64Decode(_png));
      await File('${root.path}/B.PNG').writeAsBytes(base64Decode(_png));
      final sibling = await Directory('${root.parent.path}/foobar').create();
      await File('${sibling.path}/C.PNG').writeAsBytes(base64Decode(_png));
      await library.initialize();
      await library.selectRoot(root.parent.path, metadataOnly: true);
      final initial = library.snapshot!;
      final a = initial.availableEntries.firstWhere(
        (e) => e.relativePath.endsWith('A.PNG'),
      );
      final b = initial.availableEntries.firstWhere(
        (e) => e.relativePath.endsWith('B.PNG'),
      );
      library.setFolder('foo');
      final listing = library.listing;
      library.setQuery('A');
      library.visibleEntries;
      library.setQuery('');
      library.setFolder('foo');
      expect(identical(initial, library.snapshot), isTrue);
      expect(identical(a, library.snapshot!.entryById(a.id)), isTrue);
      expect(identical(listing, library.listing), isTrue);
      await library.ensureReady(a.id);
      final afterLocal = library.snapshot!;
      expect(
        afterLocal.entryById(a.id)!.currentRevision.contentHash,
        isNotNull,
      );
      expect(afterLocal.entryById(b.id)!.currentRevision.contentHash, isNull);
      expect(
        identical(initial.entryById(b.id), afterLocal.entryById(b.id)),
        isTrue,
        reason: 'one-entry worker patch retains unrelated view objects',
      );
      await library.ensureReady(a.id);
      await library.validateForRead(a.id, a.currentRevisionId);
      expect(
        identical(afterLocal, library.snapshot),
        isTrue,
        reason: 'hot validation causes no fake data publication',
      );
      await readerLibrary.initialize();
      computer = SyncController(
        library: library,
        workspace: ReaderWorkspace(
          await ReaderStateStore.open(
            statePath: '${dir.path}/computer-reader.json',
          ),
        ),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      reader = SyncController(
        library: readerLibrary,
        workspace: ReaderWorkspace(
          await ReaderStateStore.open(
            statePath: '${dir.path}/ipad-reader.json',
          ),
        ),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await computer.initialize();
      await reader.initialize();
      await computer.startServer();
      await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
      await reader.synchronize();
      final source = library.sources.single.id;
      await reader.selectOffline(
        OfflineRule(sourceId: source, entryId: b.id, selected: true),
      );
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      expect(
        library.snapshot!.entryById(b.id)!.currentRevision.contentHash,
        isNotNull,
      );
      final c = library.snapshot!.availableEntries.firstWhere(
        (e) => e.relativePath.endsWith('C.PNG'),
      );
      expect(c.currentRevision.contentHash, isNull);
      expect(reader.locateOffline(b.id), isNotNull);
      expect(reader.locateOffline(c.id), isNull);
      debugPrint(
        'HOT_PATH_085 typed_worker_local=true http_cold_prepare=true ready_no_publish=true unrelated_unhashed=true',
      );
    } finally {
      if (computer != null) {
        await computer.stopServer();
        computer.dispose();
        computer.workspace.dispose();
      }
      if (reader != null) {
        reader.dispose();
        reader.workspace.dispose();
      }
      library.dispose();
      readerLibrary.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await _cleanup(dir);
    }
  });
}
