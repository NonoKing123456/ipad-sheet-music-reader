import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_page_window.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_tool_button.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';
import 'package:score_reader/theme/app_theme.dart';
import 'package:score_reader/theme/tokens.dart';

import 'desktop_reader_fixture.dart' show desktopUntil;
import 'reader_fixture.dart' show writeSyntheticPaper;

Future<(Directory, LibraryController, ReaderWorkspace, SyncController)>
_fixture(WidgetTester tester) async {
  final fixture = (await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp('appearance32-');
    final library = LibraryController(
      dataDirectory: Directory('${directory.path}/state'),
      watchSource: false,
    );
    await library.initialize();
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${directory.path}/reader.json'),
    );
    final sync = SyncController(library: library, workspace: workspace);
    await sync.initialize();
    return (directory, library, workspace, sync);
  }))!;
  final (directory, library, workspace, sync) = fixture;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await desktopUntil(tester, () => !workspace.saving);
    sync.dispose();
    workspace.dispose();
    library.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
    await tester.binding.setSurfaceSize(null);
  });
  return (directory, library, workspace, sync);
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

Future<void> _frame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'both library headers put search before the one-click theme action',
    (tester) async {
      final (directory, library, workspace, sync) = await _fixture(tester);
      final theme = ThemeController(
        directory: Directory('${directory.path}/theme'),
      );
      addTearDown(theme.dispose);
      await tester.binding.setSurfaceSize(const Size(744, 900));
      for (final screen in [
        LibraryScreen(controller: library, readerWorkspace: workspace),
        OfflineLibraryScreen(controller: sync, isHome: true),
      ]) {
        await tester.pumpWidget(
          ThemeScope(
            controller: theme,
            child: MaterialApp(
              theme: scoreReaderTheme(Brightness.dark),
              home: screen,
            ),
          ),
        );
        await _frame(tester);
        final search = find.byTooltip('搜索'),
            action = find.byKey(const ValueKey('theme-action'));
        expect(
          tester.getCenter(search).dx,
          lessThan(tester.getCenter(action).dx),
        );
        expect(tester.getSize(search).width, greaterThanOrEqualTo(44));
        await tester.tap(search);
        await _frame(tester);
        expect(
          tester.getCenter(find.byTooltip('关闭搜索')).dx,
          lessThan(tester.getCenter(action).dx),
        );
        expect(
          find.byKey(const ValueKey('directory-search-input')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'actual iPad none tool pans only to the real toolbar obstruction, keeps horizontal turns and resets on hide',
    (tester) async {
      final (directory, _, workspace, _) = await _fixture(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(744, 1000);
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetPadding();
      });
      await tester.binding.setSurfaceSize(const Size(744, 1000));
      final path = '${directory.path}/synthetic.png';
      await writeSyntheticPaper(tester, path);
      final target = ScoreTarget(
        entryId: 'synthetic',
        revisionId: 'r',
        filePath: path,
        displayPath: 'synthetic.png',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: scoreReaderTheme(Brightness.dark),
          navigatorObservers: [readerRouteVisibility],
          home: LibraryReaderScreen(
            workspace: workspace,
            locate: (_) => target,
            initialTarget: target,
            loader: (v) async =>
                LoadedScore(target: v, pageCount: 3, imageAspect: .75),
          ),
        ),
      );
      await desktopUntil(
        tester,
        () => workspace.store.readingPosition(target.key) != null,
      );
      ReaderInput input() =>
          tester.widget<ReaderInput>(find.byType(ReaderInput));
      expect(input().editing, isFalse);
      await tester.tapAt(const Offset(372, 450));
      await _frame(tester);
      expect(input().editing, isTrue);
      expect(input().touchInk, isFalse);
      expect(
        tester
            .widgetList<ReaderToolButton>(find.byType(ReaderToolButton))
            .any((w) => w.selected),
        isFalse,
      );
      final paper = tester.getRect(
        find.byType(AnnotationTextLayer).hitTestable(),
      );
      final allowed = math.max(0.0, input().panInsets!.top - paper.top);
      expect(allowed, greaterThan(0));
      final transform = input().transform!;
      await tester.dragFrom(const Offset(372, 350), const Offset(0, 550));
      await tester.pump();
      expect(transform.value.storage[13], closeTo(allowed, 1));
      await tester.dragFrom(const Offset(372, 700), const Offset(0, -450));
      await tester.pump();
      expect(
        transform.value.storage[13],
        closeTo(0, .1),
        reason: 'no negative overscroll or extra bottom space',
      );
      await tester.dragFrom(const Offset(560, 470), const Offset(-250, 0));
      await desktopUntil(
        tester,
        () => workspace.store.readingPosition(target.key)?.pageNumber == 2,
      );
      expect(
        workspace.store.snapshot.annotations.values.expand((v) => v),
        isEmpty,
      );
      await tester.dragFrom(const Offset(372, 350), const Offset(0, 200));
      await tester.pump();
      expect(transform.value.storage[13], greaterThan(0));
      await tester.tapAt(const Offset(372, 450));
      await _frame(tester);
      expect(input().editing, isFalse);
      expect(transform.value, Matrix4.identity());
      await tester.tapAt(const Offset(372, 450));
      await _frame(tester);
      await tester.tap(find.byTooltip('画笔；左右拖动调大小'));
      await tester.pump();
      expect(input().touchInk, isTrue);
      await tester.dragFrom(const Offset(220, 430), const Offset(0, 65));
      await desktopUntil(tester, () => !workspace.savingAnnotations);
      expect(transform.value.storage[13], closeTo(0, .1));
      expect(
        workspace.store.snapshot.annotations.values
            .expand((v) => v)
            .whereType<AnnotationStroke>(),
        hasLength(1),
      );
      final first = await tester.startGesture(
        const Offset(260, 500),
        pointer: 40,
      );
      final second = await tester.startGesture(
        const Offset(440, 500),
        pointer: 41,
      );
      await second.moveBy(const Offset(90, 20));
      await first.up();
      await second.up();
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(
        workspace.store.snapshot.annotations.values
            .expand((v) => v)
            .whereType<AnnotationStroke>(),
        hasLength(1),
      );
      await tester.tap(find.byTooltip('文字批注'));
      await _frame(tester);
      await tester.tapAt(const Offset(372, 600));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        _contrast(field.cursorColor!, Colors.white),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(field.cursorErrorColor!, Colors.white),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(field.decoration!.errorStyle!.color!, Colors.white),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(
          field.decoration!.focusedBorder!.borderSide.color,
          Colors.white,
        ),
        greaterThanOrEqualTo(3),
      );
      final localTheme = Theme.of(tester.element(find.byType(TextField)));
      expect(
        _contrast(
          localTheme.textSelectionTheme.selectionHandleColor!,
          Colors.white,
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        field.style!.color,
        const Color(0xffc12b32),
        reason: 'paper annotation ink is not replaced with dark chrome text',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'dark sync and reader errors keep readable contrast and the actual tool preview paints a visible stroke',
    (tester) async {
      final (_, _, _, sync) = await _fixture(tester);
      final theme = scoreReaderTheme(Brightness.dark);
      sync.initializationError = 'Synthetic sync failure';
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: SyncScreen(controller: sync, openOffline: () {}),
        ),
      );
      await tester.pump();
      final text = find.text('Synthetic sync failure');
      final banner = tester.widget<Container>(
        find.ancestor(of: text, matching: find.byType(Container)).first,
      );
      expect(
        _contrast(tester.widget<Text>(text).style!.color!, banner.color!),
        greaterThanOrEqualTo(4.5),
      );
      final readyPages = <int, VoidCallback>{};
      final failedPages = <int, ValueChanged<String?>>{};
      Future<void> showPage(int page) => tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: ReaderPageWindow(
              pageNumber: page,
              pageCount: 2,
              aspectFor: (_) => .75,
              readyPageBuilder: (number, active, ready, failure) {
                readyPages[number] = ready;
                failedPages[number] = failure;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await showPage(1);
      readyPages[1]!();
      await tester.pump();
      await tester.pump();
      await showPage(2);
      failedPages[2]!('Synthetic page failure');
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('页面加载失败 · 查看并重试'));
      await tester.pumpAndSettle();
      final error = find.text('Synthetic page failure');
      final material = tester.widget<Material>(
        find.ancestor(of: error, matching: find.byType(Material)).first,
      );
      expect(
        _contrast(tester.widget<Text>(error).style!.color!, material.color!),
        greaterThanOrEqualTo(4.5),
      );
      await tester.tap(find.byTooltip('关闭状态详情'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: ReaderToolButton(
                tool: ReaderTool.pen,
                selected: true,
                value: 3.2,
                onSelect: () {},
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ReaderToolButton)),
      );
      await gesture.moveBy(const Offset(35, 0));
      await tester.pump();
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((w) => w.painter.runtimeType.toString() == '_ToolPreview')
          .painter!;
      final recorder = ui.PictureRecorder();
      // Paint the real popup painter against its actual themed surface.
      final rendered = Canvas(recorder)
        ..drawColor(ScoreTokens.dark.paper0, BlendMode.src);
      paint.paint(rendered, const Size(86, 32));
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(86, 32)))!;
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      final offset = (16 * 86 + 43) * 4;
      final ink = Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
      expect(_contrast(ink, ScoreTokens.dark.paper0), greaterThanOrEqualTo(3));
      image.dispose();
      picture.dispose();
      await gesture.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
