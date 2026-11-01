import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

Future<void> idleLibrary(LibraryController library) async {
  for (var i = 0; i < 500 && library.scanning; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(library.scanning, isFalse, reason: 'bounded synthetic metadata scan');
}

void main() {
  test('app live service stays bound to legacy source while browsing additions; new sources start at zero transfer and a bad selected file does not block saved ink exchange', () async {
    final dir = await Directory.systemTemp.createTemp('multi-app-sync-');
    final controllers = <SyncController>[];
    Future<SyncController> make(String name, {String? root}) async {
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/$name'),
        watchSource: false,
      );
      await library.initialize();
      if (root != null) await library.selectRoot(root);
      final workspace = ReaderWorkspace(
        await ReaderStateStore.open(
          statePath: '${dir.path}/$name/reader-state.json',
        ),
      );
      final sync = SyncController(
        library: library,
        workspace: workspace,
        bindAddress: InternetAddress.loopbackIPv4,
        ioTimeout: const Duration(seconds: 2),
      );
      controllers.add(sync);
      await sync.initialize();
      expect(sync.initializationError, isNull);
      return sync;
    }

    try {
      final old = await Directory('${dir.path}/one/Scores')
          .create(recursive: true);
      final fresh = await Directory('${dir.path}/two/Scores/foo')
          .create(recursive: true);
      await File('${old.path}/a.png').writeAsBytes([1, 2, 3]);
      await File('${fresh.path}/a.png').writeAsBytes([4, 5, 6, 7]);
      await Directory('${fresh.parent.path}/foobar').create();
      await File('${fresh.parent.path}/foobar/a.png').writeAsBytes([8, 9]);
      final bad = await File('${fresh.parent.path}/bad.png').writeAsBytes([0]);
      final computer = await make('computer', root: old.path),
          reader = await make('ipad');
      final legacyId = computer.library.snapshot!.entries.single.id;
      await computer.startServer();
      final port = computer.port;
      await reader.pair('127.0.0.1:$port', computer.pairingCode!);
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      expect(reader.offlineCount, 1);
      final received = reader.replica!.verificationStats.downloadBytesReceived;
      await computer.library.addSource(fresh.parent.path);
      await idleLibrary(computer.library);
      expect(computer.library.sources.map((s) => s.name), [
        'Scores',
        'Scores (2)',
      ]);
      expect(computer.library.selectedSourceId, isNot('legacy'));
      expect(p.equals(computer.library.rootPath!, old.path), isTrue);
      expect(computer.serving, isTrue);
      expect(computer.port, port);
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      expect(reader.hasOfflineLibrary, isTrue);
      expect(reader.collection!.index!.sources, hasLength(2));
      expect(reader.offlineCount, 1);
      expect(reader.replica!.verificationStats.downloadBytesReceived, received);
      final added = computer.library.sources.singleWhere(
        (s) => s.id != 'legacy',
      );
      expect(
        added.catalog.snapshot.entries.every(
          (e) => e.currentRevision.contentHash == null,
        ),
        isTrue,
      );
      expect(
        reader.offlineSnapshot!.entries
            .where((e) => reader.sourceIdFor(e.id) == added.id)
            .length,
        3,
      );
      await reader.selectOffline(
        OfflineRule(sourceId: added.id, folder: 'foo', selected: true),
      );
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      expect(reader.offlineCount, 2);
      expect(
        reader.replica!.verificationStats.downloadBytesReceived,
        received + 4,
      );
      expect(
        reader.collection!.index!.entries
            .singleWhere((e) => e.relativePath == 'foobar/a.png')
            .hash,
        isNull,
      );
      final legacy = reader.locateOffline(legacyId)!;
      final page = PageKey(
        entryId: legacy.entryId,
        revisionId: legacy.revisionId,
        pageNumber: 1,
      );
      await computer.workspace.store.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff123456,
          widthFraction: .004,
        ),
        points: [NormalizedPoint(.2, .3)],
      );
      computer.workspace.refreshFromStore();
      final badItem = reader.collection!.index!.entries.singleWhere(
        (e) => e.relativePath == 'bad.png',
      );
      final other = reader.collection!.index!.entries.singleWhere(
        (e) => e.relativePath == 'foobar/a.png',
      );
      await reader.selectOffline(
        OfflineRule(
          sourceId: added.id,
          entryId: badItem.entryId,
          selected: true,
        ),
      );
      await reader.selectOffline(
        OfflineRule(sourceId: added.id, entryId: other.entryId, selected: true),
      );
      await bad.delete();
      await reader.synchronize();
      expect(reader.phase, SyncPhase.partial);
      expect(reader.locateOffline(other.entryId), isNotNull);
      expect(reader.workspace.store.snapshot.strokesFor(page), hasLength(1));
      expect(reader.message, contains('已保存的批注和曲单交换完成'));
      expect(reader.locateOffline(legacyId)!.revisionId, legacy.revisionId);
      expect(p.equals(computer.library.rootPath!, old.path), isTrue);
    } finally {
      for (final c in controllers.reversed) {
        await c.stopServer();
        c.dispose();
        await idleLibrary(c.library);
        c.library.dispose();
        await c.workspace.flushPositions();
        c.workspace.dispose();
      }
      await dir.delete(recursive: true);
    }
  });

  test('fresh source registry restores metadata-only IDs and disambiguated names; unavailable primary does not delete its catalog or stop another source refresh', () async {
    final dir = await Directory.systemTemp.createTemp('multi-app-registry-');
    LibraryController? library;
    try {
      final first = await Directory('${dir.path}/one/Scores')
          .create(recursive: true);
      final second = await Directory('${dir.path}/two/Scores')
          .create(recursive: true);
      await File('${first.path}/a.png').writeAsBytes([1, 2, 3]);
      await File('${second.path}/a.png').writeAsBytes([4, 5, 6]);
      final data = Directory('${dir.path}/app');
      library = LibraryController(dataDirectory: data, watchSource: false);
      await library.initialize();
      await library.addSource(first.path);
      await library.addSource(second.path);
      await idleLibrary(library);
      expect(library.legacySourceEnabled, isFalse);
      final originals = {
        for (final s in library.sources)
          s.id: library.snapshot!.entries
              .singleWhere((e) => library!.sourceIdFor(e) == s.id)
              .id,
      };
      expect(originals.values.toSet(), hasLength(2));
      expect(
        library.snapshot!.entries.every(
          (e) => e.currentRevision.contentHash == null,
        ),
        isTrue,
      );
      final held = await first.rename('${first.path}.offline');
      await File('${second.path}/b.png').writeAsBytes([7, 8]);
      await library.rescan();
      await idleLibrary(library);
      expect(library.sources.first.online, isFalse);
      expect(
        library.snapshot!.entryById(originals.values.first)!.status,
        EntryStatus.available,
      );
      expect(
        library.snapshot!.entries.where(
          (e) => library!.sourceIdFor(e) == library.sources.last.id,
        ),
        hasLength(2),
      );
      await held.rename(first.path);
      library.dispose();
      library = LibraryController(dataDirectory: data, watchSource: false);
      await library.initialize();
      await idleLibrary(library);
      expect(library.legacySourceEnabled, isFalse);
      expect(library.sources.map((s) => s.name), ['Scores', 'Scores (2)']);
      for (final id in originals.values) {
        expect(library.snapshot!.entryById(id), isNotNull);
      }
      expect(
        library.snapshot!.entries.every(
          (e) => e.currentRevision.contentHash == null,
        ),
        isTrue,
        reason: 'restarting must not silently promote a fresh metadata-only source to full hashing',
      );
      library.setQuery('a.png');
      expect(library.visibleEntries, hasLength(2));
      library.setQuery('Scores (2)');
      expect(library.visibleEntries, hasLength(2));
      library.setSource(library.sources.last.id);
      await library.rescan(verifyAll: true);
      await idleLibrary(library);
      expect(
        library.sources.last.catalog.snapshot.entries.every(
          (e) => e.currentRevision.contentHash != null,
        ),
        isTrue,
        reason: 'explicit full verification hashes only the selected source',
      );
      expect(
        library
            .sources
            .first
            .catalog
            .snapshot
            .entries
            .single
            .currentRevision
            .contentHash,
        isNull,
        reason: 'an unselected metadata-only source is not silently read',
      );
    } finally {
      if (library != null) {
        await idleLibrary(library);
        library.dispose();
      }
      await dir.delete(recursive: true);
    }
  });
}
