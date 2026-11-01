import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/set_lists_screen.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';

import 'reader_fixture.dart';
import 'multisource_app_080_test.dart' show idleLibrary;

class _Loopback083 extends HttpOverrides {}

Future<void> _until083(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue, reason: 'bounded preparation and catalog operation');
  await tester.pump();
}

void main() {
  testWidgets(
    'Windows metadata-only scores can be named and added before opening; explicit set-list preparation hashes only its targets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 810));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('set-prep-win-083-'),
      ))!;
      final source = (await tester.runAsync(
        () => Directory('${dir.path}/Scores/folder').create(recursive: true),
      ))!;
      await writeSyntheticPaper(tester, '${source.path}/A.PNG');
      await writeSyntheticPaper(tester, '${source.path}/B.PNG', width: 82);
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      await tester.runAsync(() async {
        await library.initialize();
        await library.addSource(source.parent.path);
        await idleLibrary(library);
      });
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/app/reader.json'),
        ))!,
      );
      final list = (await tester.runAsync(
        () => workspace.store.createSetList('Gig'),
      ))!;
      final before = library.snapshot!.availableEntries;
      final a = before.singleWhere(
            (entry) => entry.relativePath.endsWith('A.PNG'),
          ),
          b = before.singleWhere(
            (entry) => entry.relativePath.endsWith('B.PNG'),
          );
      expect(a.currentRevision.contentHash, isNull);
      expect(b.currentRevision.contentHash, isNull);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryScreen(
              controller: library,
              readerWorkspace: workspace,
            ),
          ),
        );
        await _until083(
          tester,
          () => find.byTooltip('曲单').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('曲单'));
        await _until083(
          tester,
          () => find.byType(SetListsScreen).evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Gig'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        expect(find.text('A.PNG'), findsOneWidget);
        expect(find.text('B.PNG'), findsOneWidget);
        expect(find.textContaining('待准备'), findsWidgets);
        await tester.tap(find.text('A.PNG'));
        await _until083(
          tester,
          () =>
              workspace.store.snapshot
                  .setListById(list.id)!
                  .activeItems
                  .length ==
              1,
        );
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 份未准备'), findsOneWidget);
        expect(find.byType(LibraryReaderScreen), findsNothing);
        await tester.tap(find.text('准备本曲单'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 份曲谱'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '开始准备'));
        await _until083(
          tester,
          () =>
              library.snapshot!.entries
                  .singleWhere((entry) => entry.id == a.id)
                  .currentRevision
                  .contentHash !=
              null,
        );
        expect(
          library.snapshot!.entries
              .singleWhere((entry) => entry.id == b.id)
              .currentRevision
              .contentHash,
          isNull,
        );
        expect(
          workspace.store.snapshot
              .setListById(list.id)!
              .activeItems
              .single
              .entryId,
          a.id,
        );
        expect(find.textContaining('0 份未准备'), findsOneWidget);
        expect(find.text('准备本曲单'), findsNothing);
        expect(find.byType(LibraryReaderScreen), findsNothing);
        expect(tester.takeException(), isNull);
        debugPrint(
          'SET_PREP_WINDOWS_083 metadata_identity_before_open=true add_unprepared=true explicit_confirm=true only_selected_hash=true unrelated_unhashed=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => workspace.flushPositions());
        workspace.dispose();
        library.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'iPad catalog set-list preparation deduplicates targets, preserves other folder rules, reports missing/old/offline states and downloads only confirmed content',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _Loopback083();
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('set-prep-ipad-083-'),
      ))!;
      final controllers = <SyncController>[];
      Future<SyncController> make(String name) async {
        final library = LibraryController(
          dataDirectory: Directory('${dir.path}/$name'),
          watchSource: false,
        );
        await library.initialize();
        final workspace = ReaderWorkspace(
          await ReaderStateStore.open(
            statePath: '${dir.path}/$name/reader.json',
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
        return sync;
      }

      try {
        await tester.runAsync(() async {
          for (final folder in ['show', 'other', 'gone']) {
            await Directory('${dir.path}/Scores/$folder')
                .create(recursive: true);
          }
        });
        await writeSyntheticPaper(tester, '${dir.path}/Scores/show/A.PNG');
        await writeSyntheticPaper(
          tester,
          '${dir.path}/Scores/other/B.PNG',
          width: 83,
        );
        await writeSyntheticPaper(
          tester,
          '${dir.path}/Scores/gone/C.PNG',
          width: 85,
        );
        late SyncController computer, reader;
        late ScoreSetList list;
        await tester.runAsync(() async {
          computer = await make('computer');
          reader = await make('reader');
          await computer.library.addSource('${dir.path}/Scores');
          await idleLibrary(computer.library);
          list = await computer.workspace.store.createSetList('Gig');
          await computer.startServer();
          await reader.pair(
            '127.0.0.1:${computer.port}',
            computer.pairingCode!,
          );
          await reader.synchronize();
        });
        expect(reader.offlineCount, 0);
        expect(reader.offlineScoreCatalog, hasLength(3));
        expect(reader.offlineScoreCatalog, same(reader.offlineScoreCatalog));
        final index = reader.collection!.index!;
        final a = index.entries.singleWhere(
              (entry) => entry.relativePath == 'show/A.PNG',
            ),
            b = index.entries.singleWhere(
              (entry) => entry.relativePath == 'other/B.PNG',
            ),
            c = index.entries.singleWhere(
              (entry) => entry.relativePath == 'gone/C.PNG',
            );
        await tester.runAsync(
          () => reader.selectOffline(
            OfflineRule(sourceId: b.sourceId, folder: 'other', selected: true),
          ),
        );
        final rulesBefore = jsonEncode(reader.collection!.selection.toJson());
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineLibraryScreen(controller: reader, isHome: true),
          ),
        );
        await tester.tap(find.byTooltip('曲单'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Gig'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        expect(find.text('A.PNG'), findsOneWidget);
        expect(find.text('B.PNG'), findsOneWidget);
        expect(find.text('C.PNG'), findsOneWidget);
        for (var i = 1; i <= 2; i++) {
          await tester.tap(find.text('A.PNG'));
          await _until083(
            tester,
            () =>
                reader.workspace.store.snapshot
                    .setListById(list.id)!
                    .activeItems
                    .length ==
                i,
          );
        }
        await tester.tap(find.text('C.PNG'));
        await _until083(
          tester,
          () =>
              reader.workspace.store.snapshot
                  .setListById(list.id)!
                  .activeItems
                  .length ==
              3,
        );
        await _until083(tester, () => !reader.workspace.saving);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        await _until083(
          tester,
          () => find.textContaining('2 份未准备').evaluate().isNotEmpty,
        );
        debugPrint(
          'SET_CATALOG_INITIAL_083 unique=${reader.workspace.store.snapshot.setListById(list.id)!.activeItems.map((i) => i.entryId).toSet().length} states=${reader.offlineScoreCatalog.map((e) => e.state.name).join(',')} summaries=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().where((t) => t.contains('未准备')).join('|')}',
        );
        expect(find.textContaining('2 份未准备'), findsOneWidget);
        expect(find.textContaining('暂时缺失'), findsNothing);
        expect(find.textContaining('Scores · show'), findsWidgets);
        await tester.runAsync(() async {
          await File('${dir.path}/Scores/gone/C.PNG').delete();
          await computer.library.rescan();
          await idleLibrary(computer.library);
        });
        await tester.tap(find.text('下载本曲单缺少内容'));
        await tester.pumpAndSettle();
        expect(find.textContaining('2 份曲谱'), findsOneWidget);
        expect(find.textContaining('需要电脑在线'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(jsonEncode(reader.collection!.selection.toJson()), rulesBefore);
        expect(reader.offlineCount, 0);
        await tester.tap(find.text('下载本曲单缺少内容'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '开始准备'));
        await _until083(
          tester,
          () =>
              reader.phase == SyncPhase.partial &&
              !reader.busy &&
              reader.offlineCount == 1,
        );
        expect(reader.collection!.readableItemFor(b.entryId), isNull);
        expect(reader.collection!.selection.includes(b), isTrue);
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == c.entryId)
              .state,
          ScoreContentState.missing,
        );
        expect(find.text('C.PNG'), findsOneWidget);
        expect(find.textContaining('源曲谱缺失'), findsWidgets);
        expect(find.textContaining('1 份未准备'), findsOneWidget);
        expect(
          reader.workspace.store.snapshot.setListById(list.id)!.activeItems,
          hasLength(3),
        );
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'set-list header wraps in narrow Split View',
        );
        await tester.binding.setSurfaceSize(const Size(810, 1080));
        await tester.pump();
        final onlineIndex = reader.collection!.index!;
        final offlineIndex = CollectionIndex(
          id: onlineIndex.id,
          legacyLibraryId: onlineIndex.legacyLibraryId,
          sources: [
            for (final source in onlineIndex.sources)
              LibrarySourceInfo(source.id, source.name, online: false),
          ],
          entries: onlineIndex.entries,
          folders: onlineIndex.folders,
        );
        var offlinePublished = false;
        unawaited(
          reader.collection!.updateIndex(offlineIndex).then((_) {
            reader.workspace.refreshFromStore(force: true);
            offlinePublished = true;
          }),
        );
        await _until083(tester, () => offlinePublished);
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == b.entryId)
              .state,
          ScoreContentState.sourceOffline,
        );
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == a.entryId)
              .state,
          ScoreContentState.ready,
        );
        expect(
          reader.locateOffline(a.entryId),
          isNotNull,
          reason: 'an offline source cannot block verified local bytes',
        );
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        expect(find.textContaining('来源暂离线'), findsWidgets);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        final oldRevision = reader.locateOffline(a.entryId)!.revisionId;
        await writeSyntheticPaper(
          tester,
          '${dir.path}/Scores/show/A.PNG',
          width: 99,
        );
        await tester.runAsync(() async {
          await computer.library.rescan();
          await idleLibrary(computer.library);
        });
        var refreshed = false;
        unawaited(
          reader
              .synchronize(onlyEntryIds: {c.entryId})
              .then((_) => refreshed = true),
        );
        await _until083(tester, () => refreshed);
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == a.entryId)
              .state,
          ScoreContentState.readableOld,
        );
        expect(reader.locateOffline(a.entryId)!.revisionId, oldRevision);
        expect(find.textContaining('旧版可读'), findsWidgets);
        await tester.tap(find.text('A.PNG').first);
        await _until083(
          tester,
          () =>
              find.byType(RawImage).evaluate().isNotEmpty &&
              find.byType(LibraryReaderScreen).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<LibraryReaderScreen>(find.byType(LibraryReaderScreen))
              .initialTarget
              .revisionId,
          oldRevision,
        );
        Navigator.of(tester.element(find.byType(LibraryReaderScreen))).pop();
        await tester.pumpAndSettle();
        await _until083(tester, () => !reader.workspace.saving);
        await tester.runAsync(computer.stopServer);
        await tester.tap(find.text('下载本曲单缺少内容'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 份曲谱'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '开始准备'));
        await _until083(
          tester,
          () => reader.message?.contains('连接中断') == true && !reader.busy,
        );
        expect(
          reader.workspace.store.snapshot.setListById(list.id)!.activeItems,
          hasLength(3),
        );
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == a.entryId)
              .state,
          ScoreContentState.readableOld,
        );
        expect(reader.collection!.readableItemFor(b.entryId), isNull);
        expect(reader.collection!.selection.includes(b), isTrue);
        expect(tester.takeException(), isNull);
        debugPrint(
          'SET_PREP_IPAD_083 catalog_add_before_download=true confirmed_unique_targets=2 only_A_downloaded=true other_folder_rule_preserved=true missing_is_partial=true old_revision_opens=true offline_retry_keeps_list=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        var positionsDone = false;
        unawaited(
          Future.wait(
            controllers.map((sync) => sync.workspace.flushPositions()),
          ).then((_) => positionsDone = true),
        );
        await _until083(
          tester,
          () =>
              positionsDone &&
              controllers.every((sync) => !sync.workspace.saving),
        );
        await tester.runAsync(() async {
          for (final sync in controllers.reversed) {
            await sync.stopServer();
            sync.dispose();
            sync.workspace.dispose();
            sync.library.dispose();
          }
          await dir.delete(recursive: true);
        });
        HttpOverrides.global = previousHttp;
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
