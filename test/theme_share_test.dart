import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:score_reader/sharing/score_share.dart';
import 'package:score_reader/theme/app_theme.dart';
import 'package:score_reader/theme/tokens.dart';
import 'package:score_reader/theme/reader_icons.dart';
import 'package:score_reader/library/page_count_service.dart';
import 'package:library_sync/library_sync.dart' show PageMetadataKey;

import 'annotated_pdf_export_test.dart' show exportFixtureAnnotations;
import 'reader_fixture.dart' show writeSyntheticPaper;

class _ObservedThemeController extends ThemeController {
  _ObservedThemeController({super.directory});
  int pending = 0;
  @override
  Future<void> setMode(ThemeMode mode) {
    pending++;
    return super.setMode(mode).whenComplete(() => pending--);
  }
}

Future<void> _waitForThemeSaved(
  WidgetTester tester,
  Directory root,
  ThemeMode mode, {
  int Function()? pending,
}) async {
  final file = File(p.join(root.path, 'appearance.json'));
  var saved = false;
  for (var i = 0; i < 100 && !saved; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    saved = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return await file.exists() &&
          jsonDecode(await file.readAsString())['theme'] == mode.name &&
          (pending == null || pending() == 0);
    }))!;
  }
  expect(saved, isTrue);
}

void main() {
  for (final (name, failExport, abandon) in const [
    (
      'retry system sharing with the same completed annotated PDF',
      false,
      false,
    ),
    ('retry a failed annotated export before handing off the PDF', true, false),
    (
      'abandon a failed annotated share and discard only the temporary copy',
      false,
      true,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('annotated-share-retry-'),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => root.delete(recursive: true));
      });
      final source = File(p.join(root.path, '排练.png'));
      await writeSyntheticPaper(tester, source.path);
      final originalBytes = source.readAsBytesSync();
      final sent = <String>[];
      var exports = 0;
      var completed = false;
      final service = ScoreShareService(
        temporaryDirectory: root,
        share: (params) async {
          sent.add(params.files!.single.path);
          if (!failExport && sent.length == 1)
            throw StateError('share sheet failed');
          return const ShareResult('sent', ShareResultStatus.success);
        },
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 300 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(ready(), isTrue);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await shareScore(
                    context,
                    filePath: source.path,
                    shareService: service,
                    annotationsFor: (page) {
                      exports++;
                      if (failExport && exports == 1)
                        throw StateError('unreadable annotations');
                      return exportFixtureAnnotations(page);
                    },
                  );
                  completed = true;
                },
                child: const Text('分享'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享带批注的 PDF 副本'));
      final retry = find.text(failExport ? '重新导出' : '重试分享');
      await until(() => retry.evaluate().isNotEmpty || completed);
      expect(retry, findsOneWidget);
      final error = failExport ? '无法导出批注副本，请检查文件和可用空间。' : '批注 PDF 已生成，系统分享未成功。';
      expect(find.text(error), findsOneWidget);
      final cache = Directory(p.join(root.path, 'score-reader-shares'));
      final entries = cache.listSync();
      expect(exports, 1);
      List<int>? preparedBytes;
      if (failExport) {
        expect(entries, isEmpty);
        expect(sent, isEmpty);
      } else {
        expect(entries, hasLength(1));
        preparedBytes = File(sent.single).readAsBytesSync();
      }
      if (abandon) {
        final failureDialog = find.widgetWithText(AlertDialog, error);
        await tester.tap(
          find.descendant(
            of: failureDialog,
            matching: find.widgetWithText(TextButton, '取消'),
          ),
        );
        await until(() => completed);
        expect(exports, 1);
        expect(sent, hasLength(1));
        expect(cache.listSync(), isEmpty);
        expect(source.readAsBytesSync(), orderedEquals(originalBytes));
        expect(tester.takeException(), isNull);
        return;
      }
      await tester.tap(retry);
      await until(() => completed);
      expect(exports, failExport ? 2 : 1);
      expect(sent, hasLength(failExport ? 1 : 2));
      expect(sent.toSet(), hasLength(1));
      expect(p.basename(sent.last), '排练-批注.pdf');
      final pdf = File(sent.last).readAsBytesSync();
      expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
      if (preparedBytes != null) expect(pdf, orderedEquals(preparedBytes));
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(cache.listSync(), hasLength(1));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  test('shell theme disables ripple and retains light/dark token surfaces', () {
    final light = scoreReaderTheme(Brightness.light);
    final dark = scoreReaderTheme(Brightness.dark);
    expect(light.splashFactory, NoSplash.splashFactory);
    expect(dark.splashFactory, NoSplash.splashFactory);
    expect(light.scaffoldBackgroundColor, ScoreTokens.light.paper1);
    expect(dark.scaffoldBackgroundColor, ScoreTokens.dark.paper1);
  });

  test('shell emphasis text colors meet 4.5:1 contrast in both themes', () {
    final light = scoreReaderTheme(Brightness.light).colorScheme;
    final dark = scoreReaderTheme(Brightness.dark).colorScheme;
    for (final (scheme, name) in [(light, 'light'), (dark, 'dark')]) {
      _expectTextContrast(scheme.primary, scheme.surface, '$name primary text');
      _expectTextContrast(
        scheme.secondary,
        scheme.surface,
        '$name secondary text',
      );
      _expectTextContrast(
        scheme.tertiary,
        scheme.surface,
        '$name tertiary text',
      );
      _expectTextContrast(
        scheme.onPrimary,
        scheme.primary,
        '$name primary fill',
      );
      _expectTextContrast(
        scheme.onSecondary,
        scheme.secondary,
        '$name secondary fill',
      );
      _expectTextContrast(
        scheme.onTertiary,
        scheme.tertiary,
        '$name tertiary fill',
      );
      _expectTextContrast(
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        '$name primary container',
      );
      _expectTextContrast(
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
        '$name secondary container',
      );
      _expectTextContrast(
        scheme.onTertiaryContainer,
        scheme.tertiaryContainer,
        '$name tertiary container',
      );
    }
  });

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
    'appearance action toggles effective brightness once and persists explicit mode without a menu',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('theme-ui-'),
      ))!;
      final controller = _ObservedThemeController(directory: root);
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
      ReaderGlyph actionIcon() =>
          (tester
                      .widget<IconButton>(
                        find.byKey(const ValueKey('theme-action')),
                      )
                      .icon
                  as ReaderIcon)
              .glyph;
      expect(actionIcon(), ReaderGlyph.sun);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(controller.mode, ThemeMode.system);
      expect(actionIcon(), ReaderGlyph.moon);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(actionIcon(), ReaderGlyph.sun);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('切换到浅色'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(controller.mode, ThemeMode.light);
      expect(actionIcon(), ReaderGlyph.moon);
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.light,
      );
      expect(find.byType(PopupMenuItem<ThemeMode>), findsNothing);
      final reopened = ThemeController(directory: root);
      await _waitForThemeSaved(
        tester,
        root,
        ThemeMode.light,
        pending: () => controller.pending,
      );
      await tester.runAsync(reopened.load);
      expect(reopened.mode, ThemeMode.light);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('切换到深色'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(controller.mode, ThemeMode.dark);
      await _waitForThemeSaved(
        tester,
        root,
        ThemeMode.dark,
        pending: () => controller.pending,
      );
      await tester.runAsync(reopened.load);
      expect(reopened.mode, ThemeMode.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        actionIcon(),
        ReaderGlyph.sun,
        reason: 'a click opts out of system mode',
      );
      await tester.tap(find.byKey(const ValueKey('theme-action')));
      await tester.tap(find.byKey(const ValueKey('theme-action')));
      expect(
        controller.mode,
        ThemeMode.dark,
        reason: 'rapid second click reads current explicit mode before theme animation catches up',
      );
      await _waitForThemeSaved(
        tester,
        root,
        ThemeMode.dark,
        pending: () => controller.pending,
      );
      await tester.runAsync(reopened.load);
      expect(reopened.mode, ThemeMode.dark);
      reopened.dispose();
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

void _expectTextContrast(Color foreground, Color background, String role) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  expect(
    (lighter + 0.05) / (darker + 0.05),
    greaterThanOrEqualTo(4.5),
    reason: role,
  );
}
