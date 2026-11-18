import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

Future<void> _catalogStatus083(
  WidgetTester tester,
  String title,
  String status,
) async {
  // v2 §11 keeps the header to title/count; the existing add picker reports
  // each item's preparation state, including already included items.
  await tester.tap(find.text('添加曲谱'));
  await tester.pumpAndSettle();
  expect(
    find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.textContaining(status),
    ),
    findsOneWidget,
  );
  await tester.tap(find.text('完成'));
  await tester.pumpAndSettle();
}

Future<void> _cleanup083(WidgetTester tester, Directory dir) async {
  final clock = Stopwatch()..start();
  var removed = false;
  while (!removed) {
    await tester.pump();
    await tester.runAsync(() async {
      try {
        await dir.delete(recursive: true);
        removed = true;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 32 ||
            clock.elapsed >= const Duration(seconds: 2)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
  }
}

void main() {
  testWidgets(
    '29 picker reports no matches, clears previous feedback and preserves selected scores',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('picker-search-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      final list = (await tester.runAsync(
        () => workspace.store.createSetList('排练'),
      ))!;
      var entries = [
        for (final id in ['A', 'B'])
          ScoreCatalogEntry(
            entryId: id,
            displayPath: '$id.pdf',
            state: ScoreContentState.ready,
          ),
      ];
      final picker = find.byType(BottomSheet);
      Finder inPicker(Finder content) =>
          find.descendant(of: picker, matching: content);
      final input = inPicker(find.byType(TextField));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SetListsScreen(
                workspace: workspace,
                embedded: true,
                initialListId: list.id,
                targets: () => [],
                locate: (_) => null,
                catalog: () => entries,
              ),
            ),
          ),
        );
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        await tester.tap(inPicker(find.widgetWithText(ListTile, 'A')));
        final success = inPicker(find.text('已添加，可继续选择'));
        await _until083(tester, () => success.evaluate().isNotEmpty);
        await tester.enterText(input, 'qzxz');
        await tester.pump();
        expect(inPicker(find.text('未找到匹配的曲谱')), findsOneWidget);
        expect(success, findsNothing);
        expect(inPicker(find.byType(ListTile)), findsNothing);
        await tester.tap(inPicker(find.byTooltip('清除搜索')));
        await tester.pump();
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(inPicker(find.byType(ListTile)), findsNWidgets(2));
        final a = inPicker(find.widgetWithText(ListTile, 'A'));
        expect(
          tester
              .widget<Checkbox>(
                find.descendant(of: a, matching: find.byType(Checkbox)),
              )
              .value,
          isTrue,
        );
        expect(
          workspace.store.snapshot
              .setListById(list.id)!
              .activeItems
              .map((item) => item.entryId),
          ['A'],
        );
        await tester.tap(inPicker(find.text('完成')));
        await tester.pumpAndSettle();
        entries = [];
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        expect(inPicker(find.text('谱库中还没有可添加的曲谱')), findsOneWidget);
        expect(inPicker(find.text('未找到匹配的曲谱')), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await _cleanup083(tester, dir);
      }
    },
  );

  testWidgets(
    '25 opening an unprepared set-list item distinguishes cancel, failure and ready',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('set-list-open-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final list = (await tester.runAsync(
        () => workspace.store.createSetList('演出'),
      ))!;
      await tester.runAsync(() => workspace.store.addItem(list.id, 'solo'));
      final path = '${dir.path}/Solo.png';
      await writeSyntheticPaper(tester, path);
      final bytes = (await tester.runAsync(() => File(path).readAsBytes()))!;
      final target = ScoreTarget(
        entryId: 'solo',
        revisionId: 'r1',
        filePath: path,
        displayPath: 'Solo.png',
        contentHash: sha256.convert(bytes).toString(),
      );
      final messenger = GlobalKey<ScaffoldMessengerState>();
      var calls = 0, ready = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            scaffoldMessengerKey: messenger,
            home: Scaffold(
              body: SetListsScreen(
                workspace: workspace,
                embedded: true,
                initialListId: list.id,
                targets: () => ready ? [target] : [],
                locate: (id) => ready && id == target.entryId ? target : null,
                catalog: () => [
                  ScoreCatalogEntry(
                    entryId: target.entryId,
                    displayPath: target.displayPath,
                    state: ready
                        ? ScoreContentState.ready
                        : ScoreContentState.notDownloaded,
                  ),
                ],
                prepare: (ids) async {
                  expect(ids, {target.entryId});
                  calls++;
                  if (calls == 1) return '存储空间不足。';
                  ready = true;
                  return '已准备。';
                },
              ),
            ),
          ),
        );
        Future<void> choose(String button) async {
          await tester.tap(find.text('Solo'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(button));
          await _until083(
            tester,
            () => find.byType(AlertDialog).evaluate().isEmpty,
          );
        }

        await choose('取消');
        expect(calls, 0);
        expect(find.text('Solo'), findsOneWidget);
        expect(find.byType(LibraryReaderScreen), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        await choose('开始准备');
        expect(calls, 1);
        expect(find.textContaining('存储空间不足'), findsOneWidget);
        expect(find.byType(LibraryReaderScreen), findsNothing);
        messenger.currentState!.removeCurrentSnackBar();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        await choose('开始准备');
        final presentedPage = find.descendant(
          of: find.byType(LibraryReaderScreen),
          matching: find.byType(RawImage),
        );
        await _until083(tester, () => presentedPage.evaluate().isNotEmpty);
        expect(tester.widget<RawImage>(presentedPage.first).image, isNotNull);
        expect(calls, 2);
        expect(
          tester
              .widget<LibraryReaderScreen>(find.byType(LibraryReaderScreen))
              .initialTarget
              .entryId,
          'solo',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await _cleanup083(tester, dir);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
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
        expect(find.text('A'), findsOneWidget);
        expect(find.text('B'), findsOneWidget);
        expect(find.textContaining('待准备'), findsWidgets);
        await tester.tap(find.text('A'));
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
        expect(find.text('1 首 · 按演出顺序排列'), findsOneWidget);
        await _catalogStatus083(tester, 'A', '待准备');
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
        await _catalogStatus083(tester, 'A', '已准备');
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
        await _cleanup083(tester, dir);
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
        // Release 49 schedules this selected folder automatically. Pause that
        // separate job so this test measures only explicit set-list preparation.
        reader.cancel();
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
        final picker = find.byType(BottomSheet);
        Finder scoreRow(String title) => find.descendant(
          of: picker,
          matching: find.widgetWithText(ListTile, title),
        );
        expect(scoreRow('A'), findsOneWidget);
        expect(scoreRow('B'), findsOneWidget);
        expect(scoreRow('C'), findsOneWidget);
        await tester.tap(scoreRow('A'));
        await _until083(
          tester,
          () =>
              reader.workspace.store.snapshot
                  .setListById(list.id)!
                  .activeItems
                  .length ==
              1,
        );
        final included = find.descendant(
          of: scoreRow('A'),
          matching: find.byType(Checkbox),
        );
        await _until083(
          tester,
          () => tester.widget<Checkbox>(included).value == true,
        );
        await tester.tap(scoreRow('A'));
        await _until083(tester, () => !reader.workspace.saving);
        expect(
          reader.workspace.store.snapshot.setListById(list.id)!.activeItems,
          hasLength(1),
          reason: 'v2 §11: adding an included score again creates no duplicate',
        );
        // Retain coverage for duplicate entries in an existing legacy list:
        // the current picker cannot create them, but preparation must dedupe them.
        await tester.runAsync(
          () => reader.workspace.edit(
            (store) => store.addItem(list.id, a.entryId),
          ),
        );
        await _until083(
          tester,
          () =>
              reader.workspace.store.snapshot
                  .setListById(list.id)!
                  .activeItems
                  .length ==
              2,
        );
        await tester.tap(scoreRow('C'));
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
          () => find.text('3 首 · 按演出顺序排列').evaluate().isNotEmpty,
        );
        debugPrint(
          'SET_CATALOG_INITIAL_083 unique=${reader.workspace.store.snapshot.setListById(list.id)!.activeItems.map((i) => i.entryId).toSet().length} states=${reader.offlineScoreCatalog.map((e) => e.state.name).join(',')} summaries=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().where((t) => t.contains('未准备')).join('|')}',
        );
        expect(find.text('3 首 · 按演出顺序排列'), findsOneWidget);
        await _catalogStatus083(tester, 'A', '未下载');
        await _catalogStatus083(tester, 'C', '未下载');
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
        reader.cancel();
        expect(reader.collection!.readableItemFor(b.entryId), isNull);
        expect(reader.collection!.selection.includes(b), isTrue);
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == c.entryId)
              .state,
          ScoreContentState.missing,
        );
        expect(find.text('C'), findsOneWidget);
        await _catalogStatus083(tester, 'C', '源曲谱缺失');
        expect(find.textContaining('本曲单仍有1份未准备'), findsOneWidget);
        expect(
          reader.workspace.store.snapshot.setListById(list.id)!.activeItems,
          hasLength(3),
        );
        await tester.binding.setSurfaceSize(const Size(640, 844));
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
        reader.cancel();
        expect(
          reader.offlineScoreCatalog
              .singleWhere((entry) => entry.entryId == a.entryId)
              .state,
          ScoreContentState.readableOld,
        );
        expect(reader.locateOffline(a.entryId)!.revisionId, oldRevision);
        await _catalogStatus083(tester, 'A', '旧版可读');
        await tester.tap(find.text('A').first);
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
