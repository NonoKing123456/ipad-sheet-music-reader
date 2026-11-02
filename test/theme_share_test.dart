import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:score_reader/sharing/score_share.dart';
import 'package:score_reader/theme/app_theme.dart';
import 'package:score_reader/library/page_count_service.dart';
import 'package:library_sync/library_sync.dart' show PageMetadataKey;

void main() {
  test(
    'appearance defaults to system, persists changes and ignores damaged data',
    () async {
      final root = await Directory.systemTemp.createTemp('reader-theme-');
      final controller = ThemeController(directory: root);
      final reopened = ThemeController(directory: root);
      addTearDown(() async {
        controller.dispose();
        reopened.dispose();
        await root.delete(recursive: true);
      });
      expect(controller.mode, ThemeMode.system);
      await controller.load();
      await controller.setMode(ThemeMode.dark);
      await reopened.load();
      expect(reopened.mode, ThemeMode.dark);
      await controller.setMode(ThemeMode.light);
      await controller.setMode(ThemeMode.system);
      await reopened.load();
      expect(reopened.mode, ThemeMode.system);
      await File(p.join(root.path, 'appearance.json'))
          .writeAsString('{invalid');
      await reopened.load();
      expect(reopened.mode, ThemeMode.system);
    },
  );

  test('original share keeps exact bytes, filename and extension, retains active copies', () async {
    final root = await Directory.systemTemp.createTemp(
      'reader-original-share-',
    );
    addTearDown(() => root.delete(recursive: true));
    final original = File(p.join(root.path, 'immutable-object'));
    final bytes = List.generate(65537, (i) => (i * 37) % 256);
    await original.writeAsBytes(bytes);
    ShareParams? sent;
    var validationCalls = 0;
    final service = ScoreShareService(
      temporaryDirectory: root,
      share: (params) async {
        sent = params;
        return const ShareResult('', ShareResultStatus.dismissed);
      },
    );
    for (final extension in ['PDF', 'jpg', 'PNG', 'webp']) {
      final name = '排练原谱.$extension';
      final result = await service.share(
        filePath: original.path,
        fileName: name,
        origin: const Rect.fromLTWH(40, 20, 48, 48),
        validate: () async => validationCalls++,
      );
      expect(result.status, ShareResultStatus.dismissed);
      final copy = File(sent!.files!.single.path);
      expect(p.basename(copy.path), name);
      expect(await copy.readAsBytes(), bytes);
      expect(sent!.sharePositionOrigin, const Rect.fromLTWH(40, 20, 48, 48));
      expect(
        await copy.exists(),
        isTrue,
        reason: 'receivers may read after the sheet closes',
      );
    }
    expect(validationCalls, 4);
    expect(await original.readAsBytes(), bytes);
    await expectLater(
      service.share(filePath: original.path, origin: Rect.zero),
      throwsFormatException,
    );
    sent = null;
    await expectLater(
      service.share(
        filePath: original.path,
        origin: const Rect.fromLTWH(0, 0, 48, 48),
        validate: () async => throw StateError('source revision changed'),
      ),
      throwsStateError,
    );
    expect(sent, isNull);
  });

  testWidgets(
    'appearance action exposes all modes and system brightness reaches chrome',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('theme-ui-'),
      ))!;
      final controller = ThemeController(directory: root);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
      });
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(
        ThemeScope(
          controller: controller,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => MaterialApp(
              theme: scoreReaderTheme(Brightness.light),
              darkTheme: scoreReaderTheme(Brightness.dark),
              themeMode: controller.mode,
              home: Scaffold(appBar: AppBar(actions: const [ThemeAction()])),
            ),
          ),
        ),
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('theme-action'))).height,
        greaterThanOrEqualTo(44),
      );
      IconData actionIcon() =>
          (tester
                      .widget<PopupMenuButton<ThemeMode>>(
                        find.byKey(const ValueKey('theme-action')),
                      )
                      .icon!
                  as Icon)
              .icon!;
      expect(actionIcon(), Icons.dark_mode_outlined);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(controller.mode, ThemeMode.system);
      expect(actionIcon(), Icons.light_mode_outlined);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(actionIcon(), Icons.dark_mode_outlined);
      await tester.tap(find.byKey(const ValueKey('theme-action')));
      await tester.pumpAndSettle();
      for (final label in ['跟随系统', '浅色', '深色']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(PopupMenuItem<ThemeMode>, '浅色'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(controller.mode, ThemeMode.light);
      expect(actionIcon(), Icons.light_mode_outlined);
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.light,
      );
    },
  );

  testWidgets(
    'share waits for editing to finish, then offers original and flattened PDF',
    (tester) async {
      var ready = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                ShareAction(
                  filePath: 'never-read-before-choice.pdf',
                  beforeShare: () async => ready,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(ShareAction));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      ready = true;
      await tester.tap(find.byType(ShareAction));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('分享原文件'), findsOneWidget);
      expect(find.text('分享带批注的 PDF 副本'), findsOneWidget);
      Navigator.of(tester.element(find.text('分享原文件'))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact metadata frees title space and keeps file type, page tooltip and 44 point menu',
    (tester) async {
      final service = PageCountService(resolve: (_) => null);
      addTearDown(service.dispose);
      service.remember(const PageMetadataKey('long-score.pdf', 'r1'), 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      for (final width in [320.0, 375.0, 744.0]) {
        tester.view.physicalSize = Size(width, 600);
        await tester.binding.setSurfaceSize(Size(width, 600));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final path in ['long-score.pdf', 'image.webp'])
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: const Text(
                        '奏鸣曲 — 第一乐章（排练版本）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: ScoreFileTrailing(
                        metadata: ScoreFileMetadata(
                          entryId: path,
                          revisionId: 'r1',
                          path: path,
                          service: service,
                        ),
                        menuAction: IconButton(
                          tooltip: '曲谱选项',
                          icon: const Icon(Icons.more_horiz),
                          onPressed: () {},
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.getSize(find.byType(ScoreFileTrailing).first).width,
          width < 600 ? 128 : 160,
        );
        expect(
          tester.getSize(find.byTooltip('曲谱选项').first).width,
          greaterThanOrEqualTo(44),
        );
        expect(find.text('WebP'), findsOneWidget);
        expect(find.text('1页'), findsOneWidget);
        expect(find.byTooltip('1200页'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
