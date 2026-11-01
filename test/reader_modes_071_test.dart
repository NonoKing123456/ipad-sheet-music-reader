import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_tool_button.dart';

import 'reader_color_070_test.dart'
    show
        setup,
        mount,
        flush,
        until,
        canvasPage,
        beginNewSample,
        openTools,
        GateSampler,
        paperRight;

void main() {
  testWidgets(
    'eyedropper keeps an independent visible last sample, explicit menu reuses or resamples, and cancel/error/stale reads cannot replace it',
    (tester) async {
      final (dir, workspace, target) = await setup(tester);
      final sampler = GateSampler();
      ReaderSampleColorButton button() =>
          tester.widget(find.byType(ReaderSampleColorButton));
      int inkColor() =>
          tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb;
      Future<void> pickAt(Offset normalized) async {
        final box = tester.renderObject<RenderBox>(canvasPage(1));
        await tester.tapAt(
          box.localToGlobal(
            Offset(
              box.size.width * normalized.dx,
              box.size.height * normalized.dy,
            ),
          ),
        );
      }

      try {
        await mount(tester, workspace, target, sampler: sampler);
        await openTools(tester);
        expect(button().sample, isNull);
        expect(
          find.byKey(const ValueKey('sample-color-empty')),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byType(ReaderSampleColorButton)),
          const Size(44, 44),
        );
        await beginNewSample(tester);
        expect(button().picking, isTrue);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => button().sample != null);
        expect(button().sample, paperRight);
        expect(button().usingSample, isTrue);
        await tester.tap(find.byKey(const ValueKey(ReaderTool.eraser)));
        await tester.pump();
        expect(button().usingSample, isFalse);
        await tester.tap(find.byKey(const ValueKey(ReaderTool.pen)));
        await tester.pump();
        expect(button().usingSample, isTrue);
        expect(find.byKey(const ValueKey('sample-color-empty')), findsNothing);
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        final blue = inkColor();
        expect(button().sample, paperRight);
        expect(button().usingSample, isFalse);
        final matrix = tester
            .widget<ReaderInput>(find.byType(ReaderInput))
            .transform!
            .value
            .clone();
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pumpAndSettle();
        expect(find.text('使用此颜色'), findsOneWidget);
        expect(find.text('重新吸色'), findsOneWidget);
        for (final row in find.byType(PopupMenuItem<String>).evaluate()) {
          expect(
            (row.widget as PopupMenuItem<String>).height,
            greaterThanOrEqualTo(44),
          );
        }
        await tester.tapAt(const Offset(10, 500));
        await tester.pumpAndSettle();
        expect(inkColor(), blue);
        expect(
          tester.widget<ReaderInput>(find.byType(ReaderInput)).transform!.value,
          matrix,
        );
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('使用此颜色'));
        await tester.pumpAndSettle();
        expect(inkColor(), paperRight.toARGB32());
        expect(button().usingSample, isTrue);
        await beginNewSample(tester);
        // White is a real sample, visually distinct from the empty swatch.
        tester
            .widget<ReaderInput>(find.byType(ReaderInput))
            .transform!
            .value = Matrix4.identity()
          ..setTranslationRaw(0, 140, 0);
        await tester.pump();
        await pickAt(const Offset(.1, .07));
        await until(tester, () => button().sample == Colors.white);
        expect(inkColor(), 0xffffffff);
        final swatch = tester.widget<Container>(
          find.byKey(const ValueKey('sample-color-swatch')),
        );
        final decoration = swatch.decoration! as BoxDecoration;
        expect(decoration.color, Colors.white);
        expect(decoration.border, isNotNull);
        expect(find.byKey(const ValueKey('sample-color-empty')), findsNothing);
        sampler.reset();
        await beginNewSample(tester);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => sampler.started.isCompleted);
        expect(button().sample, Colors.white);
        expect(button().busy, isTrue);
        expect(button().picking, isTrue);
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pump();
        sampler.release.complete();
        await until(tester, () => !button().busy);
        expect(button().sample, Colors.white);
        sampler.fail = true;
        await beginNewSample(tester);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => find.byTooltip('阅读状态').evaluate().isNotEmpty);
        expect(button().sample, Colors.white);
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pump();
        sampler.fail = false;
        sampler.reset();
        await beginNewSample(tester);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => sampler.started.isCompleted);
        await tester.tap(find.byTooltip('收起阅读工具'));
        await tester.pump(const Duration(milliseconds: 220));
        sampler.release.complete();
        await tester.pump();
        await tester.pump();
        expect(button().sample, Colors.white);
        expect(button().picking, isFalse);
        await tester.tapAt(const Offset(405, 540));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
        expect(
          ModalRoute.of(tester.element(find.byType(ReaderInput)))!.isCurrent,
          isTrue,
          reason: 'pedal pops the menu immediately; its 300ms route exit may still paint',
        );
        await until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
        await tester.pumpAndSettle(
          const Duration(milliseconds: 16),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 1),
        );
        expect(find.text('重新吸色'), findsNothing);
        expect(button().sample, Colors.white);
        expect(workspace.pending, isEmpty);
        expect(
          workspace.store.snapshot.pages.values.expand((strokes) => strokes),
          isEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'editing alone enables bounded fit vertical drag; hide/page/orientation invalidate finger tails, reading pinch and horizontal turns remain intact',
    (tester) async {
      final (dir, workspace, target) = await setup(tester);
      ReaderInput input() => tester.widget(find.byType(ReaderInput));
      Matrix4 matrix() => input().transform!.value;
      Future<void> hide() async {
        await tester.tap(find.byTooltip('收起阅读工具'));
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        await tester.pump(const Duration(milliseconds: 220));
      }

      Future<void> enter() async {
        await tester.tapAt(const Offset(405, 540));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(input().editing, isTrue);
      }

      try {
        await mount(tester, workspace, target);
        await openTools(tester);
        expect(input().editing, isTrue);
        final finger = await tester.startGesture(
          const Offset(405, 500),
          pointer: 20,
        );
        await finger.moveBy(const Offset(8, 230));
        await tester.pump();
        expect(matrix().storage[13], greaterThan(0));
        expect(matrix().storage[12], 0);
        await hide();
        await finger.moveBy(const Offset(0, 200));
        await finger.up();
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        expect(input().editing, isFalse);
        final readA = await tester.startGesture(
          const Offset(350, 450),
          pointer: 30,
        );
        final readB = await tester.startGesture(
          const Offset(450, 450),
          pointer: 31,
        );
        await readA.moveBy(const Offset(100, 180));
        await readB.moveBy(const Offset(100, 180));
        expect(matrix(), Matrix4.identity());
        await readA.moveBy(const Offset(-60, 0));
        await readB.moveBy(const Offset(60, 0));
        await readA.up();
        await readB.up();
        await tester.pump();
        expect(matrix().getMaxScaleOnAxis(), greaterThan(1));
        final zoom = await tester.startGesture(
          const Offset(400, 500),
          pointer: 32,
        );
        await zoom.moveBy(const Offset(5000, 5000));
        await zoom.up();
        await tester.pump();
        final bounded = clampReaderPan(
          viewport: const Size(810, 1080),
          scale: matrix().getMaxScaleOnAxis(),
          translation: const Offset(5000, 5000),
          pageAspect: .8,
        );
        expect(matrix().storage[12], closeTo(bounded.dx, .001));
        expect(matrix().storage[13], closeTo(bounded.dy, .001));
        input().transform!.value = Matrix4.identity();
        await tester.pump();
        await enter();
        final a = await tester.startGesture(
          const Offset(350, 450),
          pointer: 40,
        );
        final b = await tester.startGesture(
          const Offset(450, 450),
          pointer: 41,
        );
        await a.moveBy(const Offset(-50, 50));
        await b.moveBy(const Offset(50, 50));
        await tester.pump();
        expect(matrix().getMaxScaleOnAxis(), greaterThan(1));
        await hide();
        await a.moveBy(const Offset(-50, 50));
        await b.moveBy(const Offset(50, 50));
        await a.up();
        await b.up();
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        await enter();
        final horizontal = await tester.startGesture(
          const Offset(500, 500),
          pointer: 50,
        );
        await horizontal.moveBy(const Offset(-120, 0));
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        await horizontal.up();
        await until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
        final pageTail = await tester.startGesture(
          const Offset(405, 500),
          pointer: 51,
        );
        await pageTail.moveBy(const Offset(0, 150));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pump();
        await pageTail.moveBy(const Offset(0, 150));
        await pageTail.up();
        await until(tester, () => find.text('1 / 2').evaluate().isNotEmpty);
        expect(matrix(), Matrix4.identity());
        final rotate = await tester.startGesture(
          const Offset(405, 500),
          pointer: 52,
        );
        await rotate.moveBy(const Offset(0, 150));
        await tester.pump();
        await tester.binding.setSurfaceSize(const Size(1080, 810));
        await tester.pump();
        await tester.pump();
        await rotate.moveBy(const Offset(0, 100));
        await rotate.up();
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        // System stylus keeps its existing ink path; touch drags created no ink.
        expect(
          workspace.store.snapshot.pages.values.expand((strokes) => strokes),
          isEmpty,
        );
        final box = tester.renderObject<RenderBox>(canvasPage(1));
        final start = box.localToGlobal(box.size.center(Offset.zero));
        final pen = await tester.startGesture(
          start,
          kind: PointerDeviceKind.stylus,
        );
        await pen.moveBy(const Offset(30, 0));
        await pen.up();
        await flush(tester, workspace);
        expect(
          workspace.store.snapshot.pages.values.expand((strokes) => strokes),
          hasLength(1),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.iOS,
    }),
  );
}
