import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_page_seek_bar.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/reader_text_editing.dart';

class ControlsHarness extends StatefulWidget {
  const ControlsHarness({super.key, required this.workspace});
  final ReaderWorkspace workspace;
  @override
  State<ControlsHarness> createState() => ControlsState();
}

class ControlsState extends State<ControlsHarness> {
  final transform = TransformationController();
  final textControls = ReaderTextEditorController();
  final selectionKey = GlobalKey(),
      controlKey = GlobalKey(),
      paperKey = GlobalKey();
  bool textTool = true, editing = true, writing = false, suspended = false;
  int number = 1, generation = 0, turns = 0, seeks = 0;
  EdgeInsets obstruction = EdgeInsets.zero;
  PageKey get page =>
      PageKey(entryId: 'ui-synthetic', revisionId: 'r', pageNumber: number);
  void mode(bool value) => setState(() {
    textTool = value;
    generation++;
  });
  void goto(int value) => setState(() {
    number = value;
    generation++;
  });
  @override
  void dispose() {
    transform.dispose();
    textControls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ReaderStage(
      hasReadablePage: true,
      onToolsVisibilityChanged: (visible) => setState(() {
        editing = visible;
        if (!visible) {
          textTool = false;
          transform.value = Matrix4.identity();
          generation++;
        }
      }),
      onObstructionChanged: (value) => setState(() => obstruction = value),
      top: Material(
        child: SizedBox(
          height: 88,
          child: Row(
            children: [
              IconButton(
                tooltip: '文字批注',
                isSelected: textTool,
                icon: const Icon(Icons.text_fields),
                onPressed: () => mode(!textTool),
              ),
              ReaderTextFormatControls(controller: textControls),
            ],
          ),
        ),
      ),
      bottom: !editing || writing
          ? const SizedBox.shrink()
          : ReaderPageSeekBar(
              hitRegionKey: controlKey,
              currentPage: number,
              pageCount: 820,
              onSeek: (value, _) {
                seeks++;
                goto(value);
              },
            ),
      contentBuilder: (toggleTools) => ReaderInput(
        onPrevious: () => turns++,
        onNext: () => turns++,
        onCenterTap: toggleTools,
        transform: transform,
        pageAspect: .75,
        editing: editing,
        panInsets: obstruction,
        textTool: textTool,
        textSelectionKey: selectionKey,
        touchControlKey: controlKey,
        mouseInk: true,
        gestureGeneration: generation,
        onTransformGestureChanged: (value) => setState(() => suspended = value),
        child: ColoredBox(
          color: Colors.white,
          child: SizedBox.expand(
            key: paperKey,
            child: AnnotationTextLayer(
              workspace: widget.workspace,
              page: page,
              enabled: true,
              textTool: textTool,
              selectionKey: selectionKey,
              textControls: textControls,
              transform: transform,
              mouseControlKey: controlKey,
              suspended: suspended,
              style: StrokeStyle(
                tool: AnnotationTool.pen,
                argb: 0xff222222,
                widthFraction: .005,
              ),
              onWritingChanged: (value) {
                if (mounted) setState(() => writing = value);
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue);
  await tester.pump();
}

Future<void> durable(
  WidgetTester tester,
  Future<Object?> Function() action,
) async {
  var done = false;
  Object? failure;
  action().then(
    (_) => done = true,
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  await until(tester, () => done);
  expect(failure, isNull);
}

void main() {
  testWidgets(
    'raised bounded dots coordinate touch mouse pen and hidden tools; only actual top overlap extends editing pan',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 800));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader-controls-084-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<ControlsState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ControlsHarness(key: key, workspace: workspace),
          ),
        );
        await tester.pumpAndSettle();
        final state = key.currentState!;
        final stale = await tester.createGesture(pointer: 40);
        await stale.down(const Offset(200, 300));
        state.goto(2);
        await tester.pump();
        await stale.up();
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(workspace.store.snapshot.annotations, isEmpty);
        final rect = tester.getRect(find.byKey(state.controlKey));
        expect(rect.height, 56);
        expect(rect.bottom, 782);
        expect(readerSeekDotCount(820, rect.width), 33);
        final touch = await tester.createGesture(pointer: 41);
        await touch.down(Offset(rect.left + 440, rect.center.dy));
        await tester.pump();
        expect(state.number, greaterThan(500), reason: 'live seek before up');
        await touch.moveBy(const Offset(100, 0));
        await tester.pump();
        await touch.up();
        await tester.pump();
        expect(state.turns, 0);
        expect(find.byType(TextField), findsNothing);
        final mouse = await tester.createGesture(
          pointer: 42,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.down(Offset(rect.left + 100, rect.center.dy));
        await mouse.moveTo(Offset(rect.right - 20, rect.center.dy));
        await tester.pump();
        await mouse.up();
        await tester.pump();
        expect(state.seeks, greaterThanOrEqualTo(3));
        expect(state.turns, 0);
        expect(workspace.store.snapshot.annotations, isEmpty);
        state.mode(false);
        state.goto(1);
        await tester.pump();
        final inkPage = state.page,
            pen = await tester.createGesture(
              pointer: 43,
              kind: PointerDeviceKind.stylus,
            );
        await pen.down(rect.center);
        await tester.pump();
        expect(find.byType(ReaderPageSeekBar), findsNothing);
        await pen.moveBy(const Offset(0, -12));
        await pen.up();
        await until(
          tester,
          () =>
              !workspace.savingAnnotations &&
              workspace.store.snapshot.strokesFor(inkPage).isNotEmpty,
        );
        final stroke = workspace.store.snapshot.strokesFor(inkPage).single;
        expect(stroke.points.first.y, closeTo(rect.center.dy / 800, .0001));
        expect(
          workspace.store.snapshot
              .annotationsFor(inkPage)
              .whereType<TextAnnotation>(),
          isEmpty,
        );
        state.transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-300, -300, 0);
        await tester.pump();
        await tester.tapAt(const Offset(300, 400));
        await tester.pumpAndSettle();
        expect(state.editing, isFalse);
        expect(find.byType(ReaderPageSeekBar), findsNothing);
        expect(state.transform.value, Matrix4.identity());
        expect(state.obstruction, EdgeInsets.zero);
        await touch.down(rect.center);
        await touch.moveBy(const Offset(-100, 0));
        await touch.up();
        await tester.pump();
        expect(
          state.turns,
          1,
          reason: 'former control area becomes ordinary page input when hidden',
        );
        expect(workspace.store.snapshot.strokesFor(inkPage), hasLength(1));
        expect(
          clampReaderPan(
            viewport: const Size(600, 800),
            pageAspect: .75,
            scale: 1,
            translation: const Offset(0, 900),
            obstruction: const EdgeInsets.only(top: 88, bottom: 600),
          ).dy,
          88,
        );
        expect(
          clampReaderPan(
            viewport: const Size(600, 800),
            pageAspect: .75,
            scale: 1,
            translation: const Offset(0, -900),
            obstruction: const EdgeInsets.only(top: 88, bottom: 600),
          ).dy,
          0,
        );
        expect(
          clampReaderPan(
            viewport: const Size(600, 800),
            pageAspect: 1.5,
            scale: 1,
            translation: const Offset(0, 900),
            obstruction: const EdgeInsets.only(top: 88),
          ).dy,
          0,
        );
        expect(
          clampReaderPan(
            viewport: const Size(600, 800),
            pageAspect: .75,
            scale: 2,
            translation: const Offset(0, -900),
            obstruction: const EdgeInsets.only(top: 88),
          ).dy,
          -800,
        );
        expect(
          clampReaderPan(
            viewport: const Size(600, 800),
            pageAspect: .75,
            scale: 1,
            translation: const Offset(0, 900),
            verticalLocked: true,
          ).dy,
          0,
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'READER_CONTROLS_084 dots_56px_raised18_bounded33=true touch_mouse_live_seek_no_text_ink_or_turn=true pen_bottom_first_ink_hides_dots=true stale_page_up_canceled=true hidden_area_restored=true top_overlap_only_pan_88_no_bottom_extra=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'explicit T touch composes Unicode only on done, selects then moves once at 4x, isolates pan and cancels stale pointers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 800));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-ui-084-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<ControlsState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ControlsHarness(key: key, workspace: workspace),
          ),
        );
        await tester.pumpAndSettle();
        final state = key.currentState!, initialPage = key.currentState!.page;
        await tester.tapAt(const Offset(240, 320));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          state.editing,
          isTrue,
          reason: 'T tap cannot also hide reader tools',
        );
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '中',
            composing: TextRange(start: 0, end: 1),
          ),
        );
        await tester.pump();
        expect(workspace.store.snapshot.annotationsFor(initialPage), isEmpty);
        await tester.enterText(find.byType(TextField), '中文，Hello! “标点”\n第二行。');
        await tester.tap(find.byTooltip('完成文字编辑'));
        await until(
          tester,
          () =>
              !workspace.savingAnnotations &&
              workspace.pendingText.isEmpty &&
              workspace.store.snapshot
                  .annotationsFor(initialPage)
                  .whereType<TextAnnotation>()
                  .isNotEmpty,
        );
        await tester.pumpAndSettle();
        final created = workspace.store.snapshot
            .annotationsFor(initialPage)
            .whereType<TextAnnotation>()
            .single;
        Offset location(TextAnnotation value) {
          final box =
              state.paperKey.currentContext!.findRenderObject()! as RenderBox;
          return box.localToGlobal(
            Offset(
              value.anchor.x * box.size.width + 2,
              value.anchor.y * box.size.height + 2,
            ),
          );
        }

        expect(created.text, '中文，Hello! “标点”\n第二行。');
        state.mode(false);
        await tester.pump();
        state.mode(true);
        await tester.pump();
        final finger = await tester.createGesture(pointer: 11);
        await finger.down(location(created));
        await finger.moveBy(const Offset(0, 30));
        await tester.pump();
        await finger.up();
        await tester.pump();
        expect(
          workspace.store.snapshot
              .annotationsFor(initialPage)
              .whereType<TextAnnotation>()
              .single
              .anchor,
          created.anchor,
        );
        expect(
          find.byTooltip('编辑文字'),
          findsNothing,
          reason: 'first drag over unselected text is page movement',
        );
        state.transform.value = Matrix4.identity();
        await tester.pump();
        await tester.tapAt(location(created));
        await tester.pump();
        expect(find.byTooltip('编辑文字'), findsOneWidget);
        state.transform.value = Matrix4.diagonal3Values(4, 4, 1)
          ..setTranslationRaw(-720, -960, 0);
        await tester.pump();
        final selectedBox =
            state.selectionKey.currentContext!.findRenderObject()! as RenderBox;
        final point = selectedBox.localToGlobal(const Offset(2, 2));
        final originalMatrix = state.transform.value.clone(),
            before = workspace.store.snapshot.generation;
        await finger.down(point);
        await finger.moveBy(const Offset(17, 0));
        await tester.pump();
        expect(workspace.store.snapshot.generation, before);
        await finger.moveBy(const Offset(7, 0));
        await tester.pump();
        expect(
          state.transform.value,
          originalMatrix,
          reason: 'selected text drag cannot also pan paper',
        );
        expect(
          workspace.store.snapshot.generation,
          before,
          reason: 'movement is preview only',
        );
        await finger.up();
        await until(
          tester,
          () =>
              !workspace.savingAnnotations &&
              workspace.store.snapshot.generation > before,
        );
        final moved = workspace.store.snapshot
            .annotationsFor(initialPage)
            .whereType<TextAnnotation>()
            .single;
        expect(moved.anchor.x - created.anchor.x, closeTo(24 / 4 / 600, .0001));
        await durable(tester, () => workspace.store.undo(initialPage));
        expect(
          workspace.store.snapshot
              .annotationsFor(initialPage)
              .whereType<TextAnnotation>()
              .single
              .anchor,
          created.anchor,
        );
        await durable(tester, () => workspace.store.redo(initialPage));
        final blank = await tester.createGesture(pointer: 12);
        final pageMatrix = state.transform.value.clone();
        await blank.down(const Offset(40, 690));
        await blank.moveBy(const Offset(60, 25));
        await tester.pump();
        await blank.up();
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(
          state.transform.value,
          isNot(pageMatrix),
          reason: 'blank T drag still pans zoomed paper',
        );
        final first = await tester.createGesture(pointer: 13),
            second = await tester.createGesture(pointer: 14);
        final generation = workspace.store.snapshot.generation;
        await first.down(const Offset(250, 460));
        await second.down(const Offset(500, 600));
        await second.moveTo(const Offset(450, 550));
        await tester.pump();
        expect(state.transform.value.getMaxScaleOnAxis(), lessThan(4));
        await second.up();
        await first.up();
        await tester.pump();
        expect(workspace.store.snapshot.generation, generation);
        state.transform.value = Matrix4.identity();
        await tester.pump();
        final anchor = workspace.store.snapshot
            .annotationsFor(initialPage)
            .whereType<TextAnnotation>()
            .single
            .anchor;
        await tester.tapAt(Offset(anchor.x * 600 + 2, anchor.y * 800 + 2));
        await tester.pump();
        await finger.down(Offset(anchor.x * 600 + 2, anchor.y * 800 + 2));
        await finger.moveBy(const Offset(40, 0));
        await tester.pump();
        state.mode(false);
        await tester.pump();
        await finger.up();
        await tester.pump();
        expect(
          workspace.store.snapshot.generation,
          generation,
          reason: 'leaving T cancels old up',
        );
        expect(find.byTooltip('编辑文字'), findsNothing);
        state.mode(true);
        await tester.pump();
        final fast = TestPointer(31, PointerDeviceKind.touch);
        await tester.sendEventToBinding(fast.down(const Offset(60, 550)));
        await tester.sendEventToBinding(
          fast.up().copyWith(position: const Offset(140, 550)),
        );
        await tester.pump();
        expect(
          find.byType(TextField),
          findsNothing,
          reason: 'far up without an intermediate move is not a text tap',
        );
        await tester.tapAt(Offset(anchor.x * 600 + 2, anchor.y * 800 + 2));
        await tester.pump();
        await tester.tap(find.byTooltip('编辑文字'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '取消的文字');
        await tester.tap(find.byTooltip('取消文字编辑'));
        await tester.pumpAndSettle();
        expect(workspace.store.snapshot.generation, generation);
        await tester.tap(find.byTooltip('删除文字'));
        await until(
          tester,
          () =>
              !workspace.savingAnnotations &&
              workspace.store.snapshot
                  .annotationsFor(initialPage)
                  .whereType<TextAnnotation>()
                  .isEmpty,
        );
        await durable(tester, () => workspace.store.undo(initialPage));
        await tester.pump();
        expect(
          workspace.store.snapshot
              .annotationsFor(initialPage)
              .whereType<TextAnnotation>()
              .single
              .text,
          created.text,
        );
        expect(workspace.store.snapshot.strokesFor(initialPage), isEmpty);
        expect(tester.takeException(), isNull);
        debugPrint(
          'TEXT_TOUCH_084 explicit_T_only=true ime_done_only=true select_then_drag=true global_slop_4x=true preview_until_up_one_undo=true no_simultaneous_pan=true blank_pan_pinch=true cancel_exit_and_dialog=true no_touch_ink=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
