import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

final class CountIo extends IOOverrides {
  int types = 0, stats = 0;
  String? pretendLink;
  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) {
    types++;
    if (path == pretendLink && !followLinks) return FileSystemEntityType.link;
    return super.fseGetTypeSync(path, followLinks);
  }

  @override
  FileStat statSync(String path) {
    stats++;
    return super.statSync(path);
  }
}

void main() {
  test('400 offline targets and repeated snapshot/source-status builds perform zero synchronous filesystem checks', () async {
    final temp = await Directory.systemTemp.createTemp('presentation-400-');
    final library = LibraryController(dataDirectory: temp, watchSource: false);
    await library.initialize();
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: p.join(temp.path, 'reader.json')),
    );
    final sync = SyncController(library: library, workspace: workspace);
    await sync.initialize();
    final view = sync.replica!;
    final bytes = utf8.encode('synthetic score');
    ManifestEntry entry(
      int i, {
      String revision = 'r1',
      bool missing = false,
    }) => ManifestEntry(
      entryId: 'e$i',
      revisionId: revision,
      relativePath: 'folder/score-$i.png',
      hash: sha256.convert(bytes).toString(),
      length: bytes.length,
      format: 'png',
      missing: missing,
    );
    final entries = List.generate(400, entry);
    ReaderSession? session;
    try {
      for (final e in entries) {
        await view.receiveObject(e, Stream.value(bytes));
      }
      await view.commitManifest(
        SyncManifest(
          libraryId: 'synthetic-400',
          entries: entries,
          folders: ['', 'folder'],
        ),
      );
      final io = CountIo();
      final watch = Stopwatch()..start();
      IOOverrides.runWithIOOverrides(() {
        final snapshot = view.snapshot;
        expect(sync.offlineTargets, hasLength(400));
        for (final e in entries) {
          expect(identical(view.snapshot, snapshot), isTrue);
          expect(sync.locateOffline(e.entryId)?.revisionId, 'r1');
        }
        for (var i = 0; i < 20; i++) {
          view.search('score');
          view.listFolder('folder');
          sync.offlineCount;
        }
      }, io);
      watch.stop();
      expect(io.types, 0);
      expect(io.stats, 0);
      // Informational measurement only; correctness is asserted by exact counts.
      stdout.writeln(
        jsonEncode({
          'case': '400_targets_new_lookup',
          'scores': 400,
          'lookups_measured': 400,
          'elapsed_us': watch.elapsedMicroseconds,
          'sync_type_calls': io.types,
          'sync_stat_calls': io.stats,
        }),
      );
      var workspaceEvents = 0, locateCalls = 0;
      workspace.addListener(() => workspaceEvents++);
      session = ReaderSession(
        workspace: workspace,
        locate: (id) {
          locateCalls++;
          return sync.locateOffline(id);
        },
        loader: (target) async => LoadedScore(target: target, pageCount: 3),
      );
      await session.open(sync.locateOffline('e0')!);
      await workspace.flushPositions();
      workspace.refreshFromStore();
      expect(
        workspaceEvents,
        0,
        reason: 'bookmark writes must not rebuild the library',
      );
      final beforeStatusReads = locateCalls;
      for (var i = 0; i < 100; i++) {
        expect(session.sourceChanged, isFalse);
      }
      expect(locateCalls, beforeStatusReads);
      await session.turn(NavigationDirection.forward);
      await workspace.flushPositions();
      final reopened = await ReaderStateStore.open(
        statePath: workspace.store.statePath,
      );
      expect(
        reopened.readingPosition(sync.locateOffline('e0')!.key)?.pageNumber,
        2,
      );
      final oldSnapshot = view.snapshot;
      final revised = entry(0, revision: 'r2');
      await view.receiveObject(revised, Stream.value(bytes));
      await view.commitManifest(
        SyncManifest(
          libraryId: 'synthetic-400',
          entries: [revised, entry(1, missing: true), ...entries.skip(2)],
          folders: ['', 'folder'],
        ),
      );
      expect(identical(oldSnapshot, view.snapshot), isFalse);
      expect(sync.locateOffline('e0')!.revisionId, 'r2');
      expect(sync.locateOffline('e1'), isNull);
      session.refreshSource();
      expect(session.sourceChanged, isTrue);
      final target = sync.locateOffline('e2')!;
      await File(target.filePath).writeAsString('damaged');
      await expectLater(target.validateBeforeRead!(), throwsStateError);
      expect(
        sync.locateOffline('e2'),
        isNull,
        reason: 'read-boundary failure invalidates availability cache',
      );
      await view.receiveObject(entries[2], Stream.value(bytes));
      expect(
        sync.locateOffline('e2'),
        isNotNull,
        reason: 'verified repair invalidates the old unavailable snapshot',
      );
      final linkIo = CountIo()
        ..pretendLink = sync.locateOffline('e3')!.filePath;
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(
          sync.locateOffline('e3')!.validateBeforeRead!(),
          throwsA(isA<FileSystemException>()),
        );
      }, linkIo);
      expect(
        linkIo.types,
        greaterThan(0),
        reason: 'real opening still performs the link guard',
      );
    } finally {
      session?.dispose();
      await workspace.flushPositions();
      sync.dispose();
      library.dispose();
      workspace.dispose();
      await temp.delete(recursive: true);
    }
  });
}
