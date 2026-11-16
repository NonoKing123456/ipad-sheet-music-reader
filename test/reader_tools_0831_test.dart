import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/paper_color_sampler.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_text_editing.dart';
import 'package:score_reader/reader/reader_tool_button.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/theme/app_theme.dart';

import 'desktop_reader_fixture.dart' show desktopPdf, desktopUntil;

class _Sampler extends PaperColorSampler {
  @override
  Future<Color?> sample(Object page, Offset normalized) async =>
      const Color(0xffeeeeee);
}

class _GateWorkspace extends ReaderWorkspace {
  _GateWorkspace(super.store);
  Completer<bool>? gate;
  @override
  Future<bool> saveText(
    PageKey page,
    TextAnnotation value, {
    TextEditBase? expected,
  }) async {
    if (gate != null && !await gate!.future) {
      final prior = pendingText
          .where((p) => p.page == page && p.value.id == value.id)
          .firstOrNull;
      if (prior != null) {
        prior.value = value;
      } else {
        pendingText.add(PendingTextEdit(page, value, expected!));
      }
      notifyListeners();
      return false;
    }
    return super.saveText(page, value, expected: expected);
  }
}

Future<void> _dispose(
  WidgetTester tester,
  ReaderWorkspace workspace,
  Directory dir,
) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await desktopUntil(tester, () => !workspace.saving);
  await tester.runAsync(
    () => workspace.flushPositions().timeout(const Duration(seconds: 10)),
  );
  workspace.dispose();
  await tester.runAsync(() async {
    for (var i = 0; ; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (i == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
}

void main() {
  testWidgets(
    'dark reader surround and safe status area are pure black without changing paper or tools',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      try {
        final theme = scoreReaderTheme(Brightness.dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ReaderStage(
                top: Material(
                  key: const ValueKey('test-reader-tools'),
                  color: theme.colorScheme.surface,
                ),
                bottom: const SizedBox.shrink(),
                contentBuilder: (_) => const Center(
                  child: SizedBox(
                    width: 200,
                    height: 300,
                    child: ColoredBox(
                      key: ValueKey('test-original-paper'),
                      color: Color(0xfff4f1e8),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester
              .widget<ColoredBox>(find.byKey(const ValueKey('reader-surround')))
              .color,
          Colors.black,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('reader-surround'))).dy,
          0,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('reading-viewport'))).dy,
          0,
        );
        expect(
          tester
              .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
                find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
              )
              .value
              .statusBarColor,
          Colors.black,
        );
        expect(
          tester
              .widget<ColoredBox>(
                find.byKey(const ValueKey('test-original-paper')),
              )
              .color,
          const Color(0xfff4f1e8),
        );
        expect(
          tester
              .widget<Material>(find.byKey(const ValueKey('test-reader-tools')))
              .color,
          theme.colorScheme.surface,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.view.resetPadding();
      }
    },
  );
  testWidgets(
    'color dots keep 28px and a neutral contrast rim in either theme',
    (tester) async {
      for (final brightness in Brightness.values) {
        final theme = scoreReaderTheme(brightness);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Material(
              child: ReaderAnnotationColors(
                argb: 0xff222222,
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The black swatch remains distinguishable on dark reader chrome.
        final actual = find.byKey(
          ValueKey('annotation-color-dot-${0xff222222}'),
        );
        expect(tester.getSize(actual), const Size(28, 28));
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: actual,
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.border!.top.color, theme.colorScheme.outline);
      }
    },
  );
  testWidgets(
    'selected tool permits finger ink; pinch cancels entire finger draft and pen excludes palm ink',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tools31-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final page = PageKey(
        entryId: 'synthetic',
        revisionId: 'r',
        pageNumber: 1,
      );
      final transform = TransformationController();
      var enabled = false;
      var tool = AnnotationTool.pen;
      var eraser = false;
      late StateSetter rebuild;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, set) {
                rebuild = set;
                return ReaderInput(
                  onPrevious: () {},
                  onNext: () {},
                  transform: transform,
                  editing: enabled,
                  mouseInk: enabled,
                  touchInk: enabled,
                  child: AnnotationCanvas(
                    workspace: workspace,
                    page: page,
                    enabled: enabled,
                    eraser: eraser,
                    style: StrokeStyle(
                      tool: tool,
                      argb: 0xff222222,
                      widthFraction: .004,
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.dragFrom(const Offset(150, 200), const Offset(80, 40));
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        rebuild(() => enabled = true);
        await tester.pump();
        await tester.dragFrom(const Offset(150, 200), const Offset(80, 40));
        await desktopUntil(tester, () => !workspace.savingAnnotations);
        expect(workspace.store.snapshot.strokesFor(page), hasLength(1));
        final first = await tester.startGesture(
          const Offset(260, 240),
          pointer: 11,
        );
        await first.moveBy(const Offset(25, 15));
        final second = await tester.startGesture(
          const Offset(420, 280),
          pointer: 12,
        );
        await second.moveBy(const Offset(70, 20));
        await first.up();
        await second.up();
        await tester.pump();
        expect(
          workspace.store.snapshot.strokesFor(page),
          hasLength(1),
          reason: 'pinch leaves no partial finger stroke',
        );
        expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
        transform.value = Matrix4.identity();
        final palm = await tester.startGesture(
          const Offset(140, 200),
          pointer: 13,
        );
        await palm.moveBy(const Offset(30, 10));
        final pen = await tester.startGesture(
          const Offset(320, 230),
          pointer: 14,
          kind: PointerDeviceKind.stylus,
        );
        await pen.moveBy(const Offset(90, 30));
        await palm.moveBy(const Offset(80, 20));
        await pen.up();
        await palm.up();
        await desktopUntil(tester, () => !workspace.savingAnnotations);
        expect(workspace.store.snapshot.strokesFor(page), hasLength(2));
        expect(
          workspace.store.snapshot.strokesFor(page).last.points.first.x,
          greaterThan(.3),
          reason: 'only the pen stroke survived',
        );
        rebuild(() => tool = AnnotationTool.highlighter);
        await tester.pump();
        await tester.dragFrom(const Offset(420, 400), const Offset(80, 0));
        await desktopUntil(tester, () => !workspace.savingAnnotations);
        expect(
          workspace.store.snapshot.strokesFor(page).last.style.tool,
          AnnotationTool.highlighter,
        );
        rebuild(() => eraser = true);
        await tester.pump();
        await tester.dragFrom(const Offset(420, 400), const Offset(80, 0));
        await desktopUntil(tester, () => !workspace.savingAnnotations);
        expect(
          workspace.store.snapshot.strokesFor(page),
          hasLength(2),
          reason: 'single-finger eraser removed the highlighted line',
        );
      } finally {
        await _dispose(tester, workspace, dir);
        transform.dispose();
      }
    },
  );

  testWidgets(
    'iPad actual reader keeps system bars, none by default, consistent T tools and empty one-line input; double tap edits and action delete preserves failure',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader31-'),
      ))!;
      final workspace = _GateWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final theme = ThemeController(directory: dir);
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => dir.path,
      );
      final sharedPaths = <String>[];
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        shareChannel,
        (call) async {
          sharedPaths.addAll((call.arguments['paths'] as List).cast<String>());
          return 'dev.fluttercommunity.plus/share/dismissed';
        },
      );
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      tester.view.physicalSize = const Size(744, 1000);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.binding.setSurfaceSize(const Size(744, 1000));
      final bytes = desktopPdf(1), path = '${dir.path}/Synthetic.pdf';
      await tester.runAsync(() => File(path).writeAsBytes(bytes));
      final target = ScoreTarget(
        entryId: 'synthetic',
        revisionId: 'r',
        filePath: path,
        displayPath: 'Synthetic.pdf',
        contentHash: sha256.convert(bytes).toString(),
      );
      final page = PageKey(
        entryId: 'synthetic',
        revisionId: 'r',
        pageNumber: 1,
      );
      try {
        await tester.pumpWidget(
          ThemeScope(
            controller: theme,
            child: MaterialApp(
              theme: scoreReaderTheme(Brightness.light),
              navigatorObservers: [readerRouteVisibility],
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: (_) => target,
                initialTarget: target,
                colorSampler: _Sampler(),
                loader: (v) =>
                    loadScore(v, cacheDirectory: '${dir.path}/cache'),
              ),
            ),
          ),
        );
        await desktopUntil(
          tester,
          () => workspace.store.readingPosition(target.key) != null,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('reading-viewport'))).dy,
          0,
        );
        await tester.tapAt(const Offset(372, 480));
        await tester.pumpAndSettle();
        expect(find.byTooltip('批注'), findsOneWidget);
        expect(find.byTooltip('完成批注'), findsNothing);
        await tester.tap(find.byTooltip('批注'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<ReaderToolButton>(find.byType(ReaderToolButton))
              .any((w) => w.selected),
          isFalse,
        );
        expect(
          tester
              .widget<AnnotationTextLayer>(find.byType(AnnotationTextLayer))
              .textTool,
          isFalse,
        );
        await tester.tap(find.byTooltip('画笔'));
        await tester.pump();
        final sizeButton = find.byKey(const ValueKey('annotation-size-button'));
        final penWidthBefore = tester
            .widget<ReaderSizeButton>(sizeButton)
            .value;
        await tester.drag(sizeButton, const Offset(45, 0));
        await tester.pump();
        expect(
          tester.widget<ReaderSizeButton>(sizeButton).value,
          greaterThan(penWidthBefore),
        );
        expect(
          tester
              .widgetList<ReaderToolButton>(find.byType(ReaderToolButton))
              .singleWhere((w) => w.tool == ReaderTool.pen)
              .selected,
          isTrue,
        );
        await tester.tap(find.byTooltip('画笔'));
        await tester.pump();
        expect(
          tester
              .widgetList<ReaderToolButton>(find.byType(ReaderToolButton))
              .any((w) => w.selected),
          isFalse,
        );
        await tester.tap(find.byTooltip('文字批注'));
        await tester.pump();
        expect(find.byType(ReaderToolButton), findsNWidgets(3));
        expect(find.byType(ReaderSampleColorButton), findsOneWidget);
        expect(
          find.byKey(const ValueKey('annotation-size-button')),
          findsOneWidget,
        );
        expect(find.byType(ReaderSizeButton), findsOneWidget);
        expect(tester.widget<ReaderSizeButton>(sizeButton).label, '字号');
        expect(tester.widget<ReaderSizeButton>(sizeButton).textMode, isTrue);
        final textSizeBefore = tester.widget<ReaderSizeButton>(sizeButton);
        expect(textSizeBefore.min, 8 / 1024);
        expect(textSizeBefore.max, 96 / 1024);
        await tester.drag(sizeButton, const Offset(35, 0));
        await tester.pump();
        final selectedTextSize = tester
            .widget<ReaderSizeButton>(sizeButton)
            .value;
        expect(selectedTextSize, greaterThan(20 / 1024));
        expect(find.byTooltip('编辑文字'), findsNothing);
        final paper = tester.renderObject<RenderBox>(
          find.byType(AnnotationTextLayer),
        );
        final spot = paper.localToGlobal(
          Offset(paper.size.width * .3, paper.size.height * .45),
        );
        await tester.tapAt(spot);
        await tester.pump();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, '');
        expect(field.decoration!.hintText, isNull);
        expect(field.minLines, 1);
        expect(tester.getSize(find.byType(TextField)).height, lessThan(44));
        expect(
          find.byKey(const ValueKey('text-context-actions')),
          findsOneWidget,
        );
        expect(find.byTooltip('删除文字'), findsNothing);
        await tester.tapAt(paper.localToGlobal(const Offset(15, 350)));
        await tester.pump();
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        await tester.tapAt(spot);
        await tester.pump();
        await tester.enterText(find.byType(TextField), '原文字\n第二行');
        workspace.gate = Completer<bool>();
        await tester.tap(find.byTooltip('分享'));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly,
          isTrue,
        );
        workspace.gate!.complete(false);
        await desktopUntil(
          tester,
          () => find.byTooltip('分享').evaluate().isNotEmpty,
        );
        expect(find.text('分享原文件'), findsNothing);
        expect(
          sharedPaths,
          isEmpty,
          reason: 'failed save blocks native sharing',
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '原文字\n第二行',
        );
        workspace.gate = null;
        await tester.tap(find.byTooltip('吸取谱面底色'));
        await tester.pump();
        await tester.tapAt(paper.localToGlobal(const Offset(35, 300)));
        await desktopUntil(
          tester,
          () =>
              tester.widget<TextField>(find.byType(TextField)).style!.color ==
              const Color(0xffeeeeee),
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '原文字\n第二行',
        );
        expect(
          tester
              .widgetList<ReaderToolButton>(find.byType(ReaderToolButton))
              .any((w) => w.selected),
          isFalse,
        );
        await tester.tapAt(paper.localToGlobal(const Offset(15, 350)));
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isEmpty,
        );
        var saved = workspace.store.snapshot
            .annotationsFor(page)
            .whereType<TextAnnotation>()
            .single;
        expect(saved.fontSizeFraction, closeTo(selectedTextSize, .001));
        expect(saved.argb, 0xffeeeeee);
        // Distinguish the original from the reader's cached PDF without real files.
        final originalBytes = [
          ...bytes,
          ...'\n% synthetic original source\n'.codeUnits,
        ];
        await tester.runAsync(() => File(path).writeAsBytes(originalBytes));
        await tester.tap(find.byTooltip('分享'));
        await desktopUntil(
          tester,
          () => find.text('分享原文件').evaluate().isNotEmpty,
        );
        // Sharing stays busy until the sheet closes; settle only its entrance.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('分享原文件'));
        await desktopUntil(tester, () => sharedPaths.isNotEmpty);
        expect(
          await tester.runAsync(() => File(sharedPaths.single).readAsBytes()),
          originalBytes,
          reason: 'share uses original, never reading cache',
        );

        var point = paper.localToGlobal(
          textAnnotationFrame(saved, paper.size).center,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(point);
        await tester.pump();
        workspace.gate = Completer<bool>();
        final fontSizeButton = find.byKey(
          const ValueKey('annotation-size-button'),
        );
        final selectedFontBefore = tester
            .widget<ReaderSizeButton>(fontSizeButton)
            .value;
        // The compact size button starts dragging after touch slop.
        await tester.drag(fontSizeButton, const Offset(36, 0));
        await tester.pump();
        expect(
          tester.widget<ReaderSizeButton>(fontSizeButton).onChanged,
          isNull,
        );
        workspace.gate!.complete(false);
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isNotEmpty,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          saved.text,
        );
        expect(workspace.unsavedCount, greaterThan(0));
        workspace.gate = null;
        await tester.tapAt(paper.localToGlobal(const Offset(15, 350)));
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isEmpty,
        );
        saved = workspace.store.snapshot
            .annotationsFor(page)
            .whereType<TextAnnotation>()
            .single;
        expect(saved.fontSizeFraction, greaterThan(selectedFontBefore));
        point = paper.localToGlobal(
          textAnnotationFrame(saved, paper.size).center,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(point);
        await tester.pump();
        expect(
          find.byType(TextField),
          findsNothing,
          reason: 'single tap selects',
        );
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(point);
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          saved.text,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        workspace.gate = Completer<bool>();
        await tester.tap(find.byKey(const ValueKey('text-action-delete')));
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        workspace.gate!.complete(false);
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isNotEmpty,
        );
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          saved.text,
        );
        expect(workspace.store.snapshot.annotationsFor(page), hasLength(1));
        expect(workspace.pendingText.single.value.isDeleted, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(
          workspace
              .annotationsFor(page)
              .whereType<TextAnnotation>()
              .single
              .text,
          saved.text,
        );
        expect(
          workspace.pendingText.where((edit) => edit.value.isDeleted),
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('text-action-delete')),
          findsOneWidget,
        );
        workspace.gate = null;
        await tester.runAsync(workspace.retryStrokes);
        expect(
          workspace.store.snapshot.annotationsFor(page),
          hasLength(1),
          reason: 'cancel withdraws the deletion from background retry',
        );
        workspace.gate = Completer<bool>();
        await tester.tap(find.byKey(const ValueKey('text-action-delete')));
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        workspace.gate!.complete(false);
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isNotEmpty,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          saved.text,
        );
        expect(workspace.pendingText.single.value.isDeleted, isTrue);
        workspace.gate = null;
        // The protected editor has the recovered text; confirming an empty
        // edit retries deletion through its existing save path.
        await tester.enterText(find.byType(TextField), '');
        await tester.tapAt(const Offset(30, 600));
        await desktopUntil(
          tester,
          () => find.byType(TextField).evaluate().isEmpty,
        );
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        expect(
          calls
              .where(
                (c) => c.method == 'SystemChrome.setEnabledSystemUIOverlays',
              )
              .every((c) => (c.arguments as List).isNotEmpty),
          isTrue,
        );
        final stage = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
        );
        expect(stage.value.statusBarIconBrightness, Brightness.dark);
        await tester.tap(find.byTooltip('完成批注'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('批注').hitTestable(), findsOneWidget);
        expect(find.byTooltip('完成批注'), findsNothing);
        expect(find.byTooltip('文字批注'), findsNothing);
        // Exiting annotations keeps the reader header available. Hiding that
        // header explicitly restores the original full paper viewport.
        await tester.tapAt(tester.getRect(find.byType(ReaderInput)).center);
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('reading-viewport'))).dy,
          0,
        );
        expect(tester.takeException(), isNull);
      } finally {
        final gate = workspace.gate;
        if (gate != null && !gate.isCompleted) gate.complete(false);
        await _dispose(tester, workspace, dir);
        theme.dispose();
        tester.view.resetPadding();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.binding.setSurfaceSize(null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          shareChannel,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
