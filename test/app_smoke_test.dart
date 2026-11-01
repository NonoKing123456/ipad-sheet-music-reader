import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/main.dart';
import 'package:score_reader/library/library_controller.dart';

import 'dart:io';

import 'package:score_reader/reader/reader_screen.dart';

void main() {
  testWidgets(
    'library is the default home and direct reader remains available',
    (tester) async {
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('score-home-'),
      ))!;
      final controller = LibraryController(
        dataDirectory: temporary,
        watchSource: false,
      );
      await tester.runAsync(controller.initialize);
      await tester.pumpWidget(ScoreReaderApp(libraryController: controller));
      await tester.pumpAndSettle();
      expect(find.text('曲谱库'), findsOneWidget);
      expect(find.text('你的文件夹，就是你的谱库'), findsOneWidget);
      expect(find.byTooltip('打开单份曲谱'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: ReaderScreen()));
      await tester.pumpAndSettle();
      expect(find.text('曲谱阅读器'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('平板布局预览'));
      await tester.pumpAndSettle();
      expect(find.byType(AspectRatio), findsWidgets);
      await tester.tap(find.byTooltip('切换横竖屏'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => temporary.delete(recursive: true));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
