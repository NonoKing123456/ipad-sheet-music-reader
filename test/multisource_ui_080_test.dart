import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/library/library_widgets.dart';
import 'package:score_reader/library/score_file_icon.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';

import 'reader_fixture.dart';
import 'multisource_app_080_test.dart' show idleLibrary;
import 'support/score_fixture.dart' show deleteFixture;

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

Future<void> _checkFolderUpdate(
  WidgetTester tester, {
  required SyncController computer,
  required SyncController reader,
  required File original,
}) async {
  final item = reader.collection!.currentItems.singleWhere(
    (item) => item.relativePath == 'foo/Piece.png',
  );
  final oldBytes = (await tester.runAsync(original.readAsBytes))!;
  final folder = find.byKey(const ValueKey('offline-library-folder-foo'));
  final file = find.byKey(ValueKey('offline-library-file-${item.entryId}'));
  Future<void> checkPresentation({required bool updated}) async {
    expect(
      find.descendant(
        of: file,
        matching: find.byTooltip(updated ? '已离线' : '离线旧版可读，有更新待下载'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('directory-parent-button')));
    await tester.pump();
    expect(
      tester
          .widget<ScoreFileIcon>(
            find.descendant(of: folder, matching: find.byType(ScoreFileIcon)),
          )
          .state,
      updated ? ScoreFileIconState.ready : ScoreFileIconState.partial,
    );
    expect(
      find.descendant(
        of: folder,
        matching: find.byTooltip(
          updated ? '全部已下载 · 1 / 1 份' : '部分已下载 · 1 / 1 份已有离线副本，1 份待更新',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('offline-sync-management')));
    await tester.pumpAndSettle();
    final panel = find.byType(SyncScreen);
    final progress = find.descendant(
      of: panel,
      matching: find.text(updated ? '1 / 1' : '0 / 1'),
    );
    await tester.scrollUntilVisible(
      progress,
      180,
      scrollable: find
          .descendant(of: panel, matching: find.byType(Scrollable))
          .first,
    );
    expect(progress.hitTestable(), findsOneWidget);
    expect(
      find.descendant(
        of: panel,
        matching: find.text(updated ? '已完成' : '1 份待更新'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: panel,
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      updated ? 1.0 : 0.0,
    );
    await tester.tap(find.byTooltip('关闭设备与同步'));
    await tester.pumpAndSettle();
    await tester.tap(folder);
    await tester.pump();
  }

  // Hold background synchronization while inspecting the catalog-only refresh.
  reader.setReaderActive(true);
  try {
    await writeSyntheticPaper(tester, original.path, width: 131);
    final newBytes = (await tester.runAsync(original.readAsBytes))!;
    expect(newBytes, isNot(orderedEquals(oldBytes)));
    await tester.runAsync(() async {
      await computer.library.refreshImportedSource(
        item.sourceId,
        relativePath: item.relativePath,
      );
      await reader.refreshCatalog();
    });
    await tester.pump();
    final revision = reader.collection!.currentItems
        .singleWhere((entry) => entry.entryId == item.entryId)
        .revisionId;
    expect(revision, isNot(item.revisionId));
    final old = reader.locateOffline(item.entryId)!;
    expect(old.revisionId, item.revisionId);
    await tester.runAsync(() async {
      await old.validateBeforeRead!();
      expect(await File(old.filePath).readAsBytes(), orderedEquals(oldBytes));
    });
    await checkPresentation(updated: false);
    await tester.runAsync(reader.synchronize);
    await tester.pump();
    final current = reader.locateOffline(item.entryId)!;
    expect(current.revisionId, revision);
    await tester.runAsync(() async {
      await current.validateBeforeRead!();
      expect(
        await File(current.filePath).readAsBytes(),
        orderedEquals(newBytes),
      );
    });
    await checkPresentation(updated: true);
  } finally {
    reader.setReaderActive(false);
  }
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
        await uiUntil(
          tester,
          () => find.byTooltip('打开来源').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('打开来源'));
        await tester.pumpAndSettle();
        expect(find.text('添加来源'), findsOneWidget);
        // Finish the screen's asynchronous sync initialization before teardown.
        await tester.tap(find.byTooltip('曲库操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('离线谱库'));
        await uiUntil(
          tester,
          () => find.byType(OfflineLibraryScreen).evaluate().isNotEmpty,
        );
        Navigator.of(tester.element(find.byType(OfflineLibraryScreen))).pop();
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(LibraryNavigationItem, 'Scores'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(LibraryNavigationItem, 'Scores (2)'),
          findsOneWidget,
        );
        expect(find.text('bar'), findsWidgets);
        await tester.tapAt(const Offset(1000, 400));
        await tester.pumpAndSettle();
        final folderRow = find.byKey(const ValueKey('library-folder-bar'));
        expect(tester.widget<LibraryFileRow>(folderRow).action, isNull);
        await tester.tap(
          find.descendant(of: folderRow, matching: find.text('bar')),
        );
        await tester.pumpAndSettle();
        expect(library!.currentFolder, 'bar');
        expect(find.widgetWithText(LibraryFileRow, 'Piece'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('directory-parent-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索'));
        await tester.pump();
        final search = find.byType(TextField);
        await tester.enterText(search, 'Piece');
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(LibraryFileRow),
            matching: find.text('Piece', findRichText: true),
          ),
          findsNWidgets(2),
        );
        expect(find.text('Scores / foo'), findsOneWidget);
        expect(find.text('Scores (2) / bar'), findsOneWidget);
        await tester.enterText(search, 'Scores (2)');
        await tester.pump();
        expect(find.text('Piece', findRichText: true), findsOneWidget);
        expect(find.text('Scores / foo'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (library != null) {
          await tester.runAsync(() => idleLibrary(library!));
          library!.dispose();
        }
        workspace?.dispose();
        await tester.binding.setSurfaceSize(null);
        final cleanup = Stopwatch()..start();
        var removed = false;
        while (!removed) {
          await tester.pump();
          await tester.runAsync(() async {
            try {
              await dir.delete(recursive: true);
              removed = true;
            } on FileSystemException catch (error) {
              if (error.osError?.errorCode != 32 ||
                  cleanup.elapsed >= const Duration(seconds: 2)) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          });
        }
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
          (w) => w is LibraryFileRow && w.name == name,
        );
        expect(folderRow('foo'), findsOneWidget);
        expect(folderRow('foobar'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('offline-current-folder-menu')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载整个谱库'));
        await tester.pumpAndSettle();
        expect(find.textContaining('3 份曲谱'), findsOneWidget);
        expect(find.textContaining('以后新增的曲谱也会自动下载。'), findsOneWidget);
        expect(find.textContaining('可在谱库菜单中关闭。'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(reader.collection!.selection.rules, isEmpty);
        await tester.tap(folderRow('foo'));
        await tester.pump();
        expect(find.text('Piece'), findsOneWidget);
        expect(find.byTooltip('未下载'), findsOneWidget);
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        expect(find.text('停止这首谱的自动下载'), findsNothing);
        expect(find.text('移除这台 iPad 上的副本'), findsNothing);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(folderRow('Piece'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('1 份曲谱'), findsOneWidget);
        expect(find.textContaining('自动下载'), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(reader.collection!.selection.rules, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('offline-current-folder-menu')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载此文件夹'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 份曲谱'), findsOneWidget);
        expect(find.textContaining('以后新增的曲谱也会自动下载。'), findsOneWidget);
        expect(find.textContaining('可在文件夹菜单中关闭。'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '下载到 iPad'));
        await uiUntil(tester, () => reader.offlineCount == 1 && !reader.busy);
        expect(find.byTooltip('已离线'), findsOneWidget);
        final tile = tester.widget<LibraryFileRow>(folderRow('Piece'));
        final title = tester.widget<Text>(
          find.descendant(
            of: folderRow('Piece'),
            matching: find.text(tile.name),
          ),
        );
        expect(title.maxLines, 1);
        expect(tile.name, isNot(contains('\n')));
        expect(tile.subtitle, isNull);
        expect(
          tester.getSize(folderRow('Piece')).height,
          lessThanOrEqualTo(72),
        );
        expect(find.byTooltip('已离线'), findsOneWidget);
        await _checkFolderUpdate(
          tester,
          computer: computer,
          reader: reader,
          original: File('${dir.path}/Scores/foo/Piece.png'),
        );
        final item = reader.collection!.index!.entries.singleWhere(
          (e) => e.relativePath == 'foo/Piece.png',
        );
        final downloaded = reader.collection!.readableItemFor(item.entryId)!;
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
        expect(
          find.descendant(
            of: folderRow('Piece'),
            matching: find.byTooltip('离线旧版可读，有更新待下载'),
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('已离线'), findsNothing);
        expect(
          tester.getSize(folderRow('Piece')).height,
          lessThanOrEqualTo(72),
        );
        expect(
          find.descendant(
            of: folderRow('Piece'),
            matching: find.byTooltip('曲谱选项'),
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
        // Exercise local actions without retrying the intentionally offline server.
        reader.cancel();
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        expect(find.text('移除这台 iPad 上的副本'), findsOneWidget);
        expect(find.textContaining('断网仍可读'), findsNothing);
        expect(find.textContaining('移除后需重新下载'), findsNothing);
        await tester.tap(find.text('停止这首谱的自动下载'));
        await uiUntil(tester, () => !reader.autoDownloadsEntry(item.entryId));
        expect(reader.autoDownloadsFolder(item.sourceId, 'foo'), isTrue);
        expect(reader.locateOffline(item.entryId), isNotNull);
        await tester.tap(find.text('Piece'));
        await uiUntil(
          tester,
          () => find.byType(RawImage).evaluate().isNotEmpty,
        );
        expect(find.byType(LibraryReaderScreen), findsOneWidget);
        final context = tester.element(find.byType(LibraryReaderScreen));
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除这台 iPad 上的副本'));
        await uiUntil(
          tester,
          () =>
              !reader.busy &&
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
        // A catalog row without a local file must not offer removal.
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        expect(find.text('移除这台 iPad 上的副本'), findsNothing);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();

        // The next steps inject and damage older local revisions directly.
        // Finish pending UI writes and keep the offline fixture isolated.
        await uiUntil(tester, () => !reader.busy);
        final view = reader.collection!;
        final original = File('${dir.path}/Scores/foo/Piece.png');
        final bytes = (await tester.runAsync(original.readAsBytes))!;
        final copy = File(view.objects.objectPath(downloaded.object));
        Future<void> prepareOlderCopy() async {
          await view.updateIndex(readyIndex);
          await view.receive(downloaded, Stream.value(bytes));
          await view.updateIndex(
            readyIndex.replacing(
              CatalogItem(
                sourceId: item.sourceId,
                entryId: item.entryId,
                revisionId: '${item.revisionId}-new',
                relativePath: item.relativePath,
                length: bytes.length + 10,
                format: item.format,
              ),
            ),
          );
          expect(
            view.readableItemFor(item.entryId)?.revisionId,
            item.revisionId,
          );
          await reader.verifyOfflineLibrary();
        }

        await tester.runAsync(prepareOlderCopy);
        await tester.pump();
        expect(find.byTooltip('离线旧版可读，有更新待下载'), findsOneWidget);
        await tester.runAsync(() async {
          final damaged = bytes.toList();
          damaged[0] ^= 0xff;
          await copy.writeAsBytes(damaged, flush: true);
          await reader.verifyOfflineLibrary();
        });
        await tester.pump();
        expect(reader.locateOffline(item.entryId), isNull);
        expect(find.byTooltip('本机内容不可读，请重新下载'), findsOneWidget);
        expect(reader.message, contains('1 份离线文件无法读取'));
        await tester.runAsync(reader.verifyOfflineLibrary);
        expect(reader.message, contains('1 份离线文件无法读取'));

        await tester.runAsync(() async {
          await copy.writeAsBytes(bytes, flush: true);
          await reader.verifyOfflineLibrary();
        });
        await tester.pump();
        expect(reader.message, '离线文件校验完成。');
        expect(find.byTooltip('离线旧版可读，有更新待下载'), findsOneWidget);
        await tester.runAsync(() async {
          await copy.delete();
          await reader.verifyOfflineLibrary();
        });
        await tester.pump();
        expect(reader.message, '离线文件校验完成。');
        expect(find.byTooltip('未下载'), findsOneWidget);
        expect(view.hasLocalDownload(item.entryId), isFalse);
        await tester.runAsync(prepareOlderCopy);
        await tester.runAsync(() async {
          await copy.writeAsBytes([8, 0, 4], flush: true);
          await expectLater(
            reader.locateOffline(item.entryId)!.validateBeforeRead!(),
            throwsStateError,
          );
          await view.flush();
          final reopened = await ReplicaCollectionView.restoreCached(
            rootDirectory: view.objects.rootDirectory,
          );
          while (reopened.backgroundVerificationPending) {
            await reopened.verifyNextBatch();
          }
          expect(reopened.readableItemFor(item.entryId), isNull);
          expect(reopened.hasLocalDownload(item.entryId), isTrue);
        });
        await tester.pump();
        expect(reader.locateOffline(item.entryId), isNull);
        expect(find.byTooltip('本机内容不可读，请重新下载'), findsOneWidget);
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        expect(find.text('下载后可分享'), findsOneWidget);
        expect(find.text('移除这台 iPad 上的副本'), findsOneWidget);
        await tester.tap(find.text('移除这台 iPad 上的副本'));
        await uiUntil(
          tester,
          () => !reader.busy && find.byTooltip('未下载').evaluate().isNotEmpty,
        );
        expect(copy.existsSync(), isFalse);
        expect(find.byTooltip('未下载'), findsOneWidget);
        expect(
          await tester.runAsync(original.readAsBytes),
          orderedEquals(bytes),
        );
        expect(find.text('Piece'), findsOneWidget);
        expect(reader.workspace.store.snapshot.strokesFor(page), hasLength(1));
        await tester.tap(find.byTooltip('曲谱选项'));
        await tester.pumpAndSettle();
        expect(find.text('移除这台 iPad 上的副本'), findsNothing);
        expect(find.text('停止这首谱的自动下载'), findsNothing);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        // Reopen the same row with a single-file rule, then with a root rule.
        for (final rule in [
          OfflineRule(
            sourceId: item.sourceId,
            entryId: item.entryId,
            selected: true,
          ),
          OfflineRule(sourceId: item.sourceId, folder: '', selected: true),
        ]) {
          await uiUntil(tester, () => !reader.busy);
          await tester.runAsync(() => reader.selectOffline(rule));
          await tester.tap(find.byTooltip('曲谱选项'));
          await tester.pumpAndSettle();
          expect(find.text('移除这台 iPad 上的副本'), findsNothing);
          await tester.tap(find.text('停止这首谱的自动下载'));
          await uiUntil(
            tester,
            () => !reader.busy && !reader.autoDownloadsEntry(item.entryId),
          );
          if (rule.folder == '') {
            final sibling = readyIndex.entries.firstWhere(
              (e) => e.entryId != item.entryId && e.sourceId == item.sourceId,
            );
            expect(reader.autoDownloadsEntry(sibling.entryId), isTrue);
          }
        }
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
        });
        await deleteFixture(tester, dir);
        await tester.binding.setSurfaceSize(null);
        HttpOverrides.global = httpOverride;
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
