import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/main.dart';
import 'package:score_reader/library/library_controller.dart';

import 'dart:io';

import 'package:score_reader/reader/reader_screen.dart';

void main() {
  testWidgets(
    'library is the default home and direct reader remains available',
    (tester) async {
      debugPrint('SMOKE_STAGE start');
      expect(defaultTargetPlatform, TargetPlatform.windows);
      expect(Platform.isWindows, isTrue);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('score-home-'),
      ))!;
      debugPrint('SMOKE_STAGE temp_created');
      final controller = LibraryController(
        dataDirectory: temporary,
        watchSource: false,
      );
      addTearDown(() async {
        debugPrint('SMOKE_STAGE teardown_begin');
        await tester.pumpWidget(const SizedBox());
        debugPrint('SMOKE_STAGE teardown_widgets_disposed');
        controller.dispose();
        debugPrint('SMOKE_STAGE teardown_controller_disposed');
        await tester.runAsync(() async {
          if (await temporary.exists()) await temporary.delete(recursive: true);
        });
        debugPrint('SMOKE_STAGE teardown_complete');
      });
      await tester.runAsync(controller.initialize);
      debugPrint('SMOKE_STAGE controller_initialized');
      await tester.pumpWidget(ScoreReaderApp(libraryController: controller));
      debugPrint('SMOKE_STAGE app_pumped');
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE app_settled');
      expect(find.text('曲谱库'), findsOneWidget);
      expect(find.text('你的文件夹，就是你的谱库'), findsOneWidget);
      Future<void> operations() async {
        if (find.byTooltip('曲库操作').hitTestable().evaluate().isEmpty) {
          await tester.tap(find.byTooltip('打开来源'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('曲库操作'));
        await tester.pumpAndSettle();
      }

      // ba4cfc6 relocated these actions to 曲库操作. The empty-home access
      // expectation remains strict: do not add a source just to expose the menu.
      expect(find.byTooltip('曲库操作'), findsOneWidget);
      await operations();
      expect(find.text('切换 iPad 预览'), findsOneWidget);
      expect(find.text('打开单份曲谱'), findsOneWidget);
      await tester.tap(find.text('切换 iPad 预览'));
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE preview_toggled');
      await operations();
      expect(find.text('切换 iPad 预览'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      if (tester
          .state<ScaffoldState>(find.byType(Scaffold).first)
          .isDrawerOpen) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      expect(defaultTargetPlatform, TargetPlatform.windows);
      expect(Platform.isWindows, isTrue);
      final previewCanvas = tester.getSize(
        find.byKey(const ValueKey('ipad-preview-canvas')),
      );
      expect(previewCanvas.width / previewCanvas.height, closeTo(0.75, 0.01));
      expect(previewCanvas.width, closeTo(540, 1));
      expect(previewCanvas.height, closeTo(720, 1));
      final libraryTitle = tester.element(find.text('曲谱库'));
      expect(MediaQuery.sizeOf(libraryTitle), const Size(768, 1024));
      await operations();
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE overflow_open');
      expect(find.text('打开单份曲谱'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE overflow_closed');
      await operations();
      await tester.tap(find.text('切换 iPad 预览'));
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE preview_disabled');
      await operations();
      expect(find.text('切换 iPad 预览'), findsOneWidget);
      expect(find.byKey(const ValueKey('ipad-preview-canvas')), findsNothing);
      expect(find.text('打开单份曲谱'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: ReaderScreen()));
      await tester.pumpAndSettle();
      debugPrint('SMOKE_STAGE reader_settled');
      expect(find.text('曲谱阅读器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
