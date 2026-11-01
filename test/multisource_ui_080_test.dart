import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';

import 'reader_fixture.dart';
import 'multisource_app_080_test.dart' show idleLibrary;

class _LoopbackHttp extends HttpOverrides {}

Future<void> uiUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (done()) return;
  }
  expect(done(), isTrue, reason: 'bounded synthetic UI/network operation');
}

void main() {
  testWidgets(
    'Windows shows multiple original folder trees and global source plus parent search labels with a visible add-library action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 810));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('multi-ui-win-'),
      ))!;
      final data = Directory('${dir.path}/app');
      LibraryController? library;
      ReaderWorkspace? workspace;
      try {
        await tester.runAsync(() async {
          library = LibraryController(dataDirectory: data, watchSource: false);
          final a = await Directory('${dir.path}/one/Scores/foo')
              .create(recursive: true);
          final b = await Directory('${dir.path}/two/Scores/bar')
              .create(recursive: true);
          await File('${a.path}/Piece.png').writeAsBytes([1, 2, 3]);
          await File('${b.path}/Piece.png').writeAsBytes([4, 5, 6]);
          await library!.initialize();
          await library!.addSource(a.parent.path);
          await library!.addSource(b.parent.path);
          await idleLibrary(library!);
          workspace = ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: '${data.path}/reader-state.json',
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: LibraryScreen(
                controller: library,
                readerWorkspace: workspace,
              ),
            ),
          );
        });
        await uiUntil(tester, () => find.text('添加谱库文件夹').evaluate().isNotEmpty);
        // Finish the screen's asynchronous sync initialization before teardown.
        await tester.tap(find.byTooltip('离线谱库'));
        await uiUntil(
          tester,
          () => find.byType(OfflineLibraryScreen).evaluate().isNotEmpty,
        );
        Navigator.of(tester.element(find.byType(OfflineLibraryScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.text('Scores'), findsOneWidget);
        expect(find.text('Scores (2)'), findsOneWidget);
        expect(find.text('bar'), findsWidgets);
        final search = find.byType(TextField).first;
        await tester.enterText(search, 'Piece');
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.text('Piece'),
          ),
          findsNWidgets(2),
        );
        expect(find.text('Scores · foo'), findsOneWidget);
        expect(find.text('Scores (2) · bar'), findsOneWidget);
        await tester.enterText(search, 'Scores (2)');
        await tester.pump();
        expect(find.text('Piece'), findsOneWidget);
        expect(find.text('Scores · foo'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (library != null) {
          await tester.runAsync(() => idleLibrary(library!));
          library!.dispose();
        }
        workspace?.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'iPad browses zero-ready metadata, confirms exact folder size, downloads only that folder, reads offline and removes bytes without ink or set-list loss',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      final httpOverride = HttpOverrides.current;
      HttpOverrides.global = _LoopbackHttp();
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('multi-ui-ipad-'),
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
        return sync;
      }

      try {
        await tester.runAsync(() async {
          await Directory('${dir.path}/Scores/foo').create(recursive: true);
          await Directory('${dir.path}/Scores/foobar').create(recursive: true);
        });
        for (final relative in [
          'foo/Piece.png',
          'foobar/Other.png',
          'Root.png',
        ]) {
          await writeSyntheticPaper(tester, '${dir.path}/Scores/$relative');
        }
        late SyncController computer, reader;
        await tester.runAsync(() async {
          computer = await make('computer');
          reader = await make('ipad');
          await computer.library.addSource('${dir.path}/Scores');
          await idleLibrary(computer.library);
          await computer.startServer();
          await reader.pair(
            '127.0.0.1:${computer.port}',
            computer.pairingCode!,
          );
          await reader.synchronize();
          expect(reader.offlineCount, 0);
          expect(reader.hasOfflineLibrary, isTrue);
          expect(reader.replica!.verificationStats.downloadBytesReceived, 0);
          // Fresh sources are not exposed to an unupgraded full-download client.
          computer.refreshCode();
          final oldClient = await SyncClient.pair(
            baseUri: Uri.parse('http://127.0.0.1:${computer.port}'),
            code: computer.pairingCode!,
            stateDirectory: '${dir.path}/old-client',
          );
          final oldView = await ReplicaLibraryView.open(
            rootDirectory: '${dir.path}/old-replica',
          );
          expect(
            (await oldClient.syncLibrary(oldView)).failure,
            LibrarySyncFailure.sourceNotReady,
          );
          expect(oldView.manifest, isNull);
          expect(oldView.verificationStats.downloadBytesReceived, 0);
          await tester.pumpWidget(
            MaterialApp(
              home: OfflineLibraryScreen(controller: reader, isHome: true),
            ),
          );
        });
        await tester.pump();
        expect(find.text('Root'), findsOneWidget);
        Finder folderRow(String name) => find.byWidgetPredicate(
          (w) =>
              w is ListTile &&
              w.title is Text &&
              (w.title! as Text).data == name,
        );
        expect(folderRow('foo'), findsOneWidget);
        expect(folderRow('foobar'), findsOneWidget);
        await tester.tap(find.text('下载整个谱库'));
        await tester.pumpAndSettle();
        expect(find.textContaining('3 份曲谱'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(reader.collection!.selection.rules, isEmpty);
        await tester.tap(folderRow('foo'));
        await tester.pump();
        expect(find.text('Piece'), findsOneWidget);
        expect(find.byTooltip('未下载'), findsOneWidget);
        await tester.tap(find.text('下载此文件夹'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 份曲谱'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '下载到iPad'));
        await uiUntil(tester, () => reader.offlineCount == 1 && !reader.busy);
        expect(find.byTooltip('已离线'), findsOneWidget);
        final tile = tester.widget<ListTile>(folderRow('Piece'));
        expect((tile.subtitle! as Text).maxLines, 1);
        expect((tile.subtitle! as Text).data, isNot(contains('\n')));
        expect(
          tester.getSize(folderRow('Piece')).height,
          lessThanOrEqualTo(72),
        );
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
        final item = reader.collection!.index!.entries.singleWhere(
          (e) => e.relativePath == 'foo/Piece.png',
        );
        // Present a metadata-only newer version through the existing replica
        // boundary; the already verified offline revision remains readable.
        final readyIndex = reader.collection!.index!;
        await tester.runAsync(
          () => reader.collection!.updateIndex(
            readyIndex.replacing(
              CatalogItem(
                sourceId: item.sourceId,
                entryId: item.entryId,
                revisionId: '${item.revisionId}-pending-081',
                relativePath: item.relativePath,
                length: item.length,
                format: item.format,
              ),
            ),
          ),
        );
        reader.workspace.refreshFromStore(force: true);
        await tester.pump();
        expect(find.byTooltip('离线旧版可读，有更新待下载'), findsOneWidget);
        expect(find.byIcon(Icons.update), findsOneWidget);
        expect(find.byTooltip('已离线'), findsNothing);
        expect(
          tester.getSize(folderRow('Piece')).height,
          lessThanOrEqualTo(72),
        );
        expect(
          find.descendant(
            of: folderRow('Piece'),
            matching: find.byTooltip('离线选项'),
          ),
          findsOneWidget,
        );
        await tester.runAsync(() => reader.collection!.updateIndex(readyIndex));
        reader.workspace.refreshFromStore(force: true);
        await tester.pump();
        expect(find.byTooltip('已离线'), findsOneWidget);
        expect(
          reader.collection!.index!.entries
              .singleWhere((e) => e.relativePath == 'foobar/Other.png')
              .hash,
          isNull,
        );
        expect(
          reader.collection!.selection.includes(
            reader.collection!.index!.entries.singleWhere(
              (e) => e.relativePath == 'Root.png',
            ),
          ),
          isFalse,
        );
        final page = PageKey(
          entryId: item.entryId,
          revisionId: item.revisionId,
          pageNumber: 1,
        );
        late ScoreSetList list;
        await tester.runAsync(() async {
          await reader.workspace.store.addStroke(
            page,
            style: StrokeStyle(
              tool: AnnotationTool.pen,
              argb: 0xff123456,
              widthFraction: .004,
            ),
            points: [NormalizedPoint(.2, .3)],
          );
          list = await reader.workspace.store.createSetList('keep');
          await reader.workspace.store.addItem(list.id, item.entryId);
          reader.workspace.refreshFromStore();
          await computer.stopServer();
        });
        await tester.tap(find.text('Piece'));
        await uiUntil(
          tester,
          () => find.byType(RawImage).evaluate().isNotEmpty,
        );
        expect(find.byType(LibraryReaderScreen), findsOneWidget);
        final context = tester.element(find.byType(LibraryReaderScreen));
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('离线选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除本机下载'));
        await uiUntil(
          tester,
          () =>
              reader.offlineCount == 0 &&
              find.byTooltip('未下载').evaluate().isNotEmpty,
        );
        expect(find.text('Piece'), findsOneWidget);
        expect(find.byTooltip('未下载'), findsOneWidget);
        expect(find.byTooltip('已离线'), findsNothing);
        expect(find.byIcon(Icons.check_circle), findsNothing);
        expect(reader.workspace.store.snapshot.strokesFor(page), hasLength(1));
        expect(
          reader.workspace.store.snapshot
              .setListById(list.id)!
              .activeItems
              .single
              .entryId,
          item.entryId,
        );
        expect(reader.collection!.index!.entries, hasLength(3));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var positionsDone = false;
        Future.wait(controllers.map((c) => c.workspace.flushPositions()))
            .then((_) => positionsDone = true);
        await uiUntil(tester, () => positionsDone);
        await tester.runAsync(() async {
          for (final c in controllers.reversed) {
            await c.stopServer();
            c.dispose();
            await idleLibrary(c.library);
            c.library.dispose();
            c.workspace.dispose();
          }
          await dir.delete(recursive: true);
        });
        await tester.binding.setSurfaceSize(null);
        HttpOverrides.global = httpOverride;
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
