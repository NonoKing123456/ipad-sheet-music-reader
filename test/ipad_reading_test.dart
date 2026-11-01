import 'reader_fixture.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';

void main() {
  testWidgets(
    'iPad startup is the searchable synced folder library and returning from set lists keeps that root',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ipad-home-'),
      ))!;
      await tester.runAsync(() async {
        final root = await prepareTrustedStateRoot(temp);
        final view = await ReplicaLibraryView.open(
          rootDirectory: p.join(root.path, 'sync', 'replica'),
        );
        final bytes = utf8.encode('synthetic');
        final entry = ManifestEntry(
          entryId: 'e',
          revisionId: 'r',
          relativePath: '演出/夜曲.png',
          hash: sha256.convert(bytes).toString(),
          length: bytes.length,
          format: 'png',
          missing: false,
        );
        await view.receiveObject(entry, Stream.value(bytes));
        await view.commitManifest(
          SyncManifest(
            libraryId: 'test',
            entries: [entry],
            folders: ['', '演出'],
          ),
        );
      });
      final library = LibraryController(
        dataDirectory: temp,
        watchSource: false,
      );
      await tester.runAsync(library.initialize);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LibraryScreen(controller: library)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.byType(OfflineLibraryScreen), findsOneWidget);
      expect(find.text('把整个谱库带在身边'), findsNothing);
      expect(find.text('搜索离线曲名或文件夹'), findsOneWidget);
      expect(find.byTooltip('返回谱库'), findsNothing);
      await tester.enterText(find.byType(TextField), '夜曲');
      await tester.pump();
      expect(find.text('夜曲', findRichText: false).hitTestable(), findsWidgets);
      await tester.tap(find.byTooltip('曲单'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('夜曲', findRichText: false).hitTestable(), findsWidgets);
      expect(find.byType(OfflineLibraryScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      library.dispose();
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );

  for (final setList in [false, true]) {
    testWidgets(
      'iPad fit page, direct compact tools, edge/pedal turns and center access; setList=$setList',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final temp = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('ipad-reader-'),
        ))!;
        final workspace = (await tester.runAsync(
          () async => ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: p.join(temp.path, 'reader.json'),
            ),
          ),
        ))!;
        String? listId, itemId;
        if (setList) {
          await tester.runAsync(() async {
            final list = await workspace.store.createSetList('演出');
            listId = list.id;
            itemId = (await workspace.store.addItem(list.id, 'e')).id;
          });
        }
        await writeSyntheticPaper(tester, p.join(temp.path, 'fake.png'));
        final target = ScoreTarget(
          entryId: 'e',
          revisionId: 'r',
          filePath: p.join(temp.path, 'fake.png'),
          displayPath: 'score.png',
        );
        await tester.binding.setSurfaceSize(const Size(810, 1080));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: (_) => target,
                initialTarget: target,
                setListId: listId,
                itemId: itemId,
                loader: (target) async =>
                    LoadedScore(target: target, pageCount: 3, imageAspect: .75),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await settleReader(tester);
        final paper = find.byType(AnnotationCanvas).hitTestable();
        final viewport = find.byKey(const ValueKey('reading-viewport'));
        expect(tester.getSize(viewport), const Size(810, 1080));
        expect(tester.getSize(paper), const Size(810, 1080));
        expect(find.text('阅读'), findsNothing);
        expect(find.byIcon(Icons.tablet_mac_outlined), findsNothing);
        await tester.tapAt(const Offset(405, 540));
        await settleReader(tester);
        expect(find.text('阅读'), findsNothing);
        expect(
          tester
              .widget<FadeTransition>(
                find
                    .descendant(
                      of: find.byType(ReaderStage),
                      matching: find.byType(FadeTransition),
                    )
                    .first,
              )
              .opacity
              .value,
          1,
        );
        expect(
          tester.getSize(paper),
          const Size(810, 1080),
          reason: 'tools float without shrinking paper',
        );
        expect(find.byIcon(Icons.tablet_mac_outlined), findsNothing);
        await tester.runAsync(() async {
          await tester.tapAt(const Offset(790, 540));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await settleReader(tester);
        expect(find.text('2 / 3'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await settleReader(tester);
        expect(find.text('3 / 3'), findsOneWidget);
        await tester.binding.setSurfaceSize(const Size(1080, 810));
        await tester.pump();
        expect(tester.getSize(viewport), const Size(1080, 810));
        expect(tester.getSize(paper).height, closeTo(810, .01));
        expect(tester.getSize(paper).width, closeTo(607.5, .01));
        await tester.tap(find.byTooltip('收起阅读工具'));
        await settleReader(tester);
        expect(
          tester
              .widget<FadeTransition>(
                find
                    .descendant(
                      of: find.byType(ReaderStage),
                      matching: find.byType(FadeTransition),
                    )
                    .first,
              )
              .opacity
              .value,
          0,
        );
        await tester.tapAt(const Offset(540, 405));
        await settleReader(tester);
        expect(
          tester
              .widget<FadeTransition>(
                find
                    .descendant(
                      of: find.byType(ReaderStage),
                      matching: find.byType(FadeTransition),
                    )
                    .first,
              )
              .opacity
              .value,
          1,
        );
        expect(tester.getSize(paper).height, closeTo(810, .01));
        expect(tester.takeException(), isNull);
        await settleReader(tester);
        expect(workspace.saving, isFalse);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(
          calls.any(
            (call) =>
                call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
                (call.arguments as List).isEmpty,
          ),
          isTrue,
        );
        expect(
          calls.any(
            (call) =>
                call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
                (call.arguments as List).length == 2,
          ),
          isTrue,
        );
        debugDefaultTargetPlatformOverride = null;
        workspace.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      },
    );
  }

  testWidgets(
    'single file iPad reader uses the actual viewport with no device preview',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('single-ipad-'),
      ))!;
      final file = File(p.join(temp.path, 'pixel.png'));
      await tester.runAsync(
        () => file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: ReaderScreen(initialPath: file.path)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const ValueKey('reading-viewport'))),
        const Size(810, 1080),
      );
      expect(
        find.byKey(const ValueKey('tablet-preview-viewport')),
        findsNothing,
      );
      await tester.tapAt(const Offset(405, 540));
      await tester.pump();
      expect(find.byIcon(Icons.tablet_mac_outlined), findsNothing);
      expect(find.byTooltip('放大'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      await tester.runAsync(() => temp.delete(recursive: true));
    },
  );
}
