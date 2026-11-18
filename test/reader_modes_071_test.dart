import 'dart:io';

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
        setReaderTestViewport,
        resetReaderTestViewport,
        canvasPage,
        beginNewSample,
        openTools,
        GateSampler,
        paperRight;

void main() {
  testWidgets(
    'eyedropper and reusable sample stay separate; cancel/error/stale reads cannot replace the last sample',
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
          find.byWidgetPredicate(
            (w) => w is ReaderSampleColorButton && w.sample == null,
          ),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byType(ReaderSampleColorButton)),
          const Size(48, 48),
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
        expect(
          find.byWidgetPredicate(
            (w) => w is ReaderSampleColorButton && w.sample == null,
          ),
          findsNothing,
        );
        await tester.tap(find.byTooltip('颜色'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        final blue = inkColor();
        expect(blue, isNot(paperRight.toARGB32()));
        expect(button().sample, paperRight);
        expect(button().usingSample, isFalse);
        final matrix = tester
            .widget<ReaderInput>(find.byType(ReaderInput))
            .transform!
            .value
            .clone();
        await beginNewSample(tester);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => button().usingSample);
        await tester.pump();
        expect(inkColor(), paperRight.toARGB32());
        expect(
          tester.widget<ReaderInput>(find.byType(ReaderInput)).transform!.value,
          matrix,
        );
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
          find.byKey(const ValueKey('reader-sample-swatch')),
        );
        final decoration = swatch.decoration! as BoxDecoration;
        expect(decoration.color, Colors.white);
        expect(decoration.border, isNotNull);
        expect(
          find.byWidgetPredicate(
            (w) => w is ReaderSampleColorButton && w.sample == null,
          ),
          findsNothing,
        );
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
        await tester.tap(find.byTooltip('阅读状态'));
        await tester.pumpAndSettle();
        expect(find.text('底色读取失败，请重试。'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭状态详情'));
        await tester.pumpAndSettle();
        expect(button().sample, Colors.white);
        await tester.tap(find.byType(ReaderSampleColorButton));
        await tester.pump();
        sampler.fail = false;
        sampler.reset();
        await beginNewSample(tester);
        await pickAt(const Offset(.65, .55));
        await until(tester, () => sampler.started.isCompleted);
        await tester.tap(find.byTooltip('完成批注'));
        await tester.pump(const Duration(milliseconds: 220));
        sampler.release.complete();
        await tester.pump();
        await tester.pump();
        await openTools(tester);
        expect(button().sample, Colors.white);
        expect(button().picking, isFalse);
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
        await resetReaderTestViewport(tester);
        await tester.runAsync(() async {
          for (var attempt = 0; ; attempt++) {
            try {
              await dir.delete(recursive: true);
              break;
            } on FileSystemException catch (error) {
              if (error.osError?.errorCode != 32 || attempt >= 4) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
          }
        });
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
      int? presentedPage;
      ReaderInput input() => tester.widget(find.byType(ReaderInput));
      Matrix4 matrix() => input().transform!.value;
      Offset centerFraction(Matrix4 transform, Size viewport, double aspect) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          Size(aspect, 1),
          viewport,
        ).destination;
        final paper = Alignment.center.inscribe(fitted, Offset.zero & viewport);
        final scene =
            (viewport.center(Offset.zero) -
                Offset(transform.storage[12], transform.storage[13])) /
            transform.getMaxScaleOnAxis();
        return Offset(
          (scene.dx - paper.left) / paper.width,
          (scene.dy - paper.top) / paper.height,
        );
      }

      Future<void> hide() async {
        final before = matrix().clone();
        final anchor = centerFraction(
          before,
          tester.getSize(find.byType(ReaderInput)),
          input().pageAspect!,
        );
        await tester.tap(find.byTooltip('完成批注'));
        await tester.pumpAndSettle();
        // 11ec49e retains zoom/content; chrome reprojects to the new viewport.
        expect(matrix().getMaxScaleOnAxis(), before.getMaxScaleOnAxis());
        expect(
          (centerFraction(
                    matrix(),
                    tester.getSize(find.byType(ReaderInput)),
                    input().pageAspect!,
                  ) -
                  anchor)
              .distance,
          lessThan(.0001),
        );
      }

      Future<void> enter() async {
        await openTools(tester);
        expect(input().editing, isTrue);
      }

      try {
        await mount(
          tester,
          workspace,
          target,
          onPresented: (page) => presentedPage = page.pageNumber,
        );
        await openTools(tester);
        expect(input().editing, isTrue);
        final finger = await tester.startGesture(
          const Offset(405, 500),
          pointer: 20,
        );
        await finger.moveBy(const Offset(8, 230));
        await tester.pump();
        // be6676d / dcedfce: fitted paper is below chrome; no extra pan.
        expect(matrix().storage[13], 0);
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
          viewport: tester.getSize(find.byType(ReaderInput)),
          scale: matrix().getMaxScaleOnAxis(),
          translation: const Offset(5000, 5000),
          pageAspect: input().pageAspect,
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
        final hiddenZoom = matrix().clone();
        await a.moveBy(const Offset(-50, 50));
        await b.moveBy(const Offset(50, 50));
        await a.up();
        await b.up();
        await tester.pump();
        expect(matrix(), hiddenZoom);
        input().transform!.value = Matrix4.identity();
        await tester.pump();
        await enter();
        final horizontal = await tester.startGesture(
          const Offset(500, 500),
          pointer: 50,
        );
        await horizontal.moveBy(const Offset(-120, 0));
        await tester.pump();
        expect(matrix(), Matrix4.identity());
        await horizontal.up();
        await until(tester, () => presentedPage == 2);
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
        await until(tester, () => presentedPage == 1);
        expect(matrix(), Matrix4.identity());
        final rotate = await tester.startGesture(
          const Offset(405, 500),
          pointer: 52,
        );
        await rotate.moveBy(const Offset(0, 150));
        await tester.pump();
        await setReaderTestViewport(tester, const Size(1080, 810));
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
        await tester.tap(find.byKey(const ValueKey(ReaderTool.pen)));
        await until(
          tester,
          () =>
              tester.widget<AnnotationCanvas>(canvasPage(1)).enabled &&
              !tester.widget<AnnotationCanvas>(canvasPage(1)).suspended,
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
        await resetReaderTestViewport(tester);
        await tester.runAsync(() async {
          for (var attempt = 0; ; attempt++) {
            try {
              await dir.delete(recursive: true);
              break;
            } on FileSystemException catch (error) {
              if (error.osError?.errorCode != 32 || attempt >= 4) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
          }
        });
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.iOS,
    }),
  );
}
