import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_text_editing.dart';
import 'package:score_reader/reader/reader_workspace.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.workspace});
  final ReaderWorkspace workspace;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controls = ReaderTextEditorController(),
      transform = TransformationController();
  final topKey = GlobalKey(),
      viewportKey = GlobalKey(),
      selection = GlobalKey();
  final paperKeys = [GlobalKey(), GlobalKey()];
  bool textTool = true, suspended = false;
  int turns = 0;
  PageKey page(int number) => PageKey(
    entryId: 'synthetic-outside',
    revisionId: 'r',
    pageNumber: number,
  );
  Future<void> leave() async {
    if (await controls.finish() && mounted) setState(() => textTool = false);
  }

  @override
  void dispose() {
    controls.dispose();
    transform.dispose();
    super.dispose();
  }

  Offset paperPoint(int index, double x, double y) {
    final box =
        paperKeys[index].currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset(box.size.width * x, box.size.height * y));
  }

  Widget _paper(int index) => Expanded(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: ColoredBox(
        key: paperKeys[index],
        color: Colors.white,
        child: AnnotationTextLayer(
          workspace: widget.workspace,
          page: page(index + 1),
          enabled: index == 0,
          textTool: textTool,
          suspended: suspended,
          transform: transform,
          textControls: controls,
          topControlsKey: topKey,
          viewportKey: viewportKey,
          selectionKey: index == 0 ? selection : null,
          style: StrokeStyle(
            tool: AnnotationTool.highlighter,
            argb: 0x55c12b32,
            widthFraction: .004,
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Column(
      children: [
        Material(
          key: topKey,
          child: Row(
            children: [
              ReaderTextFormatControls(controller: controls),
              IconButton(
                tooltip: '退出批注',
                onPressed: leave,
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReaderStage(
            top: const SizedBox.shrink(),
            bottom: const SizedBox.shrink(),
            hasReadablePage: true,
            onNext: () => turns++,
            onPrevious: () => turns++,
            contentBuilder: (_) => ReaderInput(
              onNext: () => turns++,
              onPrevious: () => turns++,
              transform: transform,
              viewportKey: viewportKey,
              editing: true,
              textTool: textTool,
              textControls: controls,
              textSelectionKey: selection,
              pageAspect: 1.5,
              mouseWheel: true,
              onTransformGestureChanged: (value) =>
                  setState(() => suspended = value),
              child: ColoredBox(
                color: const Color(0xffdddddd),
                child: Row(children: [_paper(0), _paper(1)]),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _GatedWorkspace extends ReaderWorkspace {
  _GatedWorkspace(super.store);
  Completer<bool>? gate;
  int calls = 0;
  @override
  Future<bool> saveText(
    PageKey page,
    TextAnnotation value, {
    TextEditBase? expected,
  }) async {
    calls++;
    if (gate != null && !await gate!.future) return false;
    return super.saveText(page, value, expected: expected);
  }
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 350 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 4)),
    );
  }
  expect(done(), isTrue);
  await tester.pump();
}

Future<void> _durable(
  WidgetTester tester,
  Future<Object?> Function() action,
) async {
  var done = false;
  Object? error;
  action().then(
    (_) {
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  await _until(tester, () => done);
  expect(error, isNull);
}

Future<void> _setup(
  WidgetTester tester,
  ReaderWorkspace workspace,
  GlobalKey<_HarnessState> key,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 800);
  await tester.binding.setSurfaceSize(const Size(900, 800));
  await tester.pumpWidget(
    MaterialApp(
      home: _Harness(key: key, workspace: workspace),
    ),
  );
  await tester.pumpAndSettle();
}

TextAnnotation _text(ReaderWorkspace workspace, PageKey page) => workspace
    .store
    .snapshot
    .annotationsFor(page)
    .whereType<TextAnnotation>()
    .single;
Future<void> _cleanup(
  WidgetTester tester,
  ReaderWorkspace workspace,
  Directory dir,
) async {
  await tester.pumpWidget(const SizedBox());
  workspace.dispose();
  tester.view.resetViewInsets();
  tester.view.resetDevicePixelRatio();
  tester.view.resetPhysicalSize();
  await tester.binding.setSurfaceSize(null);
  await tester.runAsync(() => dir.delete(recursive: true));
}

void main() {
  testWidgets(
    'blank outside commits once across papers; selected colors persist, undo and empty edit deletes',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-outside-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<_HarnessState>();
      try {
        await _setup(tester, workspace, key);
        final state = key.currentState!, page = key.currentState!.page(1);
        await tester.tapAt(state.paperPoint(0, .2, .4));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          const Color(0xffc12b32),
          reason: 'new T text is opaque even after the highlighter',
        );
        await tester.enterText(find.byType(TextField), '中文，Hello!\n第二行。');
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          const Color(0xff1c57ac),
        );
        // Another paper's blank tap only finishes the current record.
        await tester.tapAt(state.paperPoint(1, .7, .6));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        expect(workspace.store.snapshot.annotationsFor(page), hasLength(1));
        expect(workspace.store.snapshot.annotationsFor(state.page(2)), isEmpty);
        expect(_text(workspace, page).argb, 0xff1c57ac);
        expect(state.turns, 0);
        expect(find.byType(TextField), findsNothing);
        final generation = workspace.store.snapshot.generation;
        state.controls.onEdit!();
        await tester.pump();
        await tester.tapAt(state.paperPoint(0, .8, .8));
        await _until(tester, () => !state.controls.editing);
        expect(
          workspace.store.snapshot.generation,
          generation,
          reason: 'unchanged confirmation adds no history/write',
        );
        await tester.tap(find.byTooltip('红色'));
        await _until(
          tester,
          () => !workspace.savingAnnotations && !state.controls.saving,
        );
        expect(_text(workspace, page).argb, 0xffc12b32);
        await _durable(tester, () => workspace.store.undo(page));
        expect(_text(workspace, page).argb, 0xff1c57ac);
        await _durable(tester, () => workspace.store.redo(page));
        final reopened = (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!;
        expect(
          reopened.snapshot
              .annotationsFor(page)
              .whereType<TextAnnotation>()
              .single
              .argb,
          0xffc12b32,
        );
        await _durable(
          tester,
          () => workspace.store.saveText(
            page,
            _text(
              workspace,
              page,
            ).revise(argb: 0xffffffff, now: DateTime.now().toUtc()),
          ),
        );
        await tester.tapAt(state.paperPoint(0, .25, .41));
        await tester.pump();
        expect(
          find.byTooltip('当前文字颜色'),
          findsOneWidget,
          reason: 'custom/white stored colors remain visible',
        );
        expect(state.controls.argb, 0xffffffff);
        await tester.tap(find.byTooltip('红色'));
        await _until(
          tester,
          () => !workspace.savingAnnotations && !state.controls.saving,
        );
        state.controls.onEdit!();
        await tester.pump();
        await tester.enterText(find.byType(TextField), '');
        await tester.tapAt(state.paperPoint(1, .8, .8));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        await _durable(tester, () => workspace.store.undo(page));
        expect(_text(workspace, page).argb, 0xffc12b32);
        // Empty new draft is discarded without a record or extra undo.
        final beforeEmpty = workspace.store.snapshot.generation;
        await tester.tapAt(state.paperPoint(0, .3, .75));
        await tester.pump();
        await tester.tapAt(state.paperPoint(1, .7, .75));
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(workspace.store.snapshot.annotationsFor(page), hasLength(1));
        expect(workspace.store.snapshot.generation, beforeEmpty);
        expect(readerTextEditorActive, isFalse);
        await tester.tapAt(state.paperPoint(0, .5, .75));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '第二处文字');
        await tester.tapAt(state.paperPoint(0, .25, .41));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        expect(workspace.store.snapshot.annotationsFor(page), hasLength(2));
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _cleanup(tester, workspace, dir);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'IME, top colors, handles, pan and pinch preserve the draft; bottom outside restores view',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-ime-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<_HarnessState>();
      try {
        await _setup(tester, workspace, key);
        final state = key.currentState!, page = key.currentState!.page(1);
        await tester.tapAt(state.paperPoint(0, .2, .4));
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '正在输入中',
            composing: TextRange(start: 4, end: 5),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .controller!
              .value
              .composing,
          const TextRange(start: 4, end: 5),
        );
        await tester.enterText(find.byType(TextField), '中文，Hello!\n第二行。');
        expect(find.byKey(const ValueKey('annotation-font')), findsNothing);
        await tester.tap(find.byTooltip('黑色'));
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        await tester.tapAt(tester.getCenter(find.byType(TextField)));
        await tester.pump();
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        final handle = await tester.createGesture();
        await handle.down(tester.getCenter(find.byTooltip('调整换行宽度')));
        await handle.moveBy(const Offset(50, 0));
        await tester.pump();
        await handle.up();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        final pan = await tester.createGesture();
        await pan.down(state.paperPoint(1, .6, .7));
        await pan.moveBy(const Offset(0, -55));
        await tester.pump();
        await pan.up();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        final a = await tester.createGesture(pointer: 31),
            b = await tester.createGesture(pointer: 32);
        await a.down(const Offset(250, 650));
        await b.down(const Offset(600, 650));
        await b.moveBy(const Offset(80, 0));
        await tester.pump();
        await b.up();
        await a.up();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(workspace.store.snapshot.annotationsFor(page), isEmpty);
        expect(state.suspended, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(readerTextEditorActive, isFalse);
        state.transform.value = Matrix4.identity();
        await tester.pump();
        await tester.pump();
        final before = state.transform.value.clone();
        await tester.tapAt(state.paperPoint(0, .2, .98));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '底部\n换行输入');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        await tester.pump();
        final input = tester.renderObject<RenderBox>(find.byType(TextField));
        expect(
          input.localToGlobal(input.size.bottomRight(Offset.zero)).dy,
          lessThanOrEqualTo(489),
        );
        // Gray reader margin is also a completion target.
        await tester.tapAt(const Offset(5, 250));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        await tester.pump();
        await tester.pump();
        expect(state.transform.value, before);
        expect(_text(workspace, page).text, '底部\n换行输入');
        expect(tester.takeException(), isNull);
      } finally {
        await _cleanup(tester, workspace, dir);
      }
    },
  );

  testWidgets(
    'in-flight finish is shared and locks input formatting and handles until save resolves',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-pending-'),
      ))!;
      final workspace = _GatedWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<_HarnessState>();
      try {
        await _setup(tester, workspace, key);
        final state = key.currentState!, page = key.currentState!.page(1);
        await tester.tapAt(state.paperPoint(0, .2, .4));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '完整保留');
        workspace.gate = Completer<bool>();
        await tester.tapAt(state.paperPoint(1, .8, .8));
        await tester.pump();
        final first = state.controls.finish(), second = state.controls.finish();
        expect(workspace.calls, 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly,
          isTrue,
        );
        await tester.tap(find.byTooltip('蓝色'));
        await tester.drag(find.byTooltip('移动文字'), const Offset(40, 20));
        await tester.pump();
        expect(workspace.calls, 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          const Color(0xffc12b32),
        );
        workspace.gate!.complete(true);
        await _until(tester, () => !state.controls.editing);
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(workspace.calls, 1);
        expect(_text(workspace, page).text, '完整保留');
        expect(_text(workspace, page).argb, 0xffc12b32);
      } finally {
        await _cleanup(tester, workspace, dir);
      }
    },
  );

  testWidgets(
    'failed outside save keeps text and pending retry; guarded exit cannot discard it',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-failed-'),
      ))!;
      final stateDir = (await tester.runAsync(
        () => Directory('${dir.path}/state').create(),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () =>
              ReaderStateStore.open(statePath: '${stateDir.path}/reader.json'),
        ))!,
      );
      final key = GlobalKey<_HarnessState>();
      Directory? held;
      try {
        await _setup(tester, workspace, key);
        final state = key.currentState!, page = key.currentState!.page(1);
        await tester.tapAt(state.paperPoint(0, .2, .4));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '保存失败也保留，中文\nEnglish!');
        held = await tester.runAsync(
          () => stateDir.rename('${stateDir.path}.held'),
        );
        await tester.runAsync(
          () => File(stateDir.path).writeAsString('synthetic failure'),
        );
        await tester.tapAt(state.paperPoint(1, .8, .8));
        await _until(
          tester,
          () => !state.controls.saving && !workspace.savingAnnotations,
        );
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly,
          isFalse,
        );
        expect(workspace.pendingText, hasLength(1));
        await tester.tap(find.byTooltip('退出批注'));
        await _until(tester, () => !state.controls.saving);
        expect(state.textTool, isTrue);
        await tester.runAsync(() => File(stateDir.path).delete());
        await tester.runAsync(() => held!.rename(stateDir.path));
        held = null;
        await tester.tapAt(state.paperPoint(1, .8, .8));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        expect(_text(workspace, page).text, '保存失败也保留，中文\nEnglish!');
        expect(workspace.pendingText, isEmpty);
        expect(readerTextEditorActive, isFalse);
      } finally {
        if (held != null) {
          await tester.runAsync(() => File(stateDir.path).delete());
          await tester.runAsync(() => held!.rename(stateDir.path));
        }
        await _cleanup(tester, workspace, dir);
      }
    },
  );
  testWidgets(
    'one transform handle snaps and guides quarter turns while keeping scale and one undo',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-snap-widget-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final key = GlobalKey<_HarnessState>();
      try {
        await _setup(tester, workspace, key);
        final state = key.currentState!, page = key.currentState!.page(1);
        final original = workspace.store
            .newText(
              text: 'Rotate',
              anchor: NormalizedPoint(.18, .4),
              argb: 0xff222222,
            )
            .revise(rotation: .15, now: DateTime.now().toUtc());
        await _durable(tester, () => workspace.store.saveText(page, original));
        final paper =
            state.paperKeys.first.currentContext!.findRenderObject()!
                as RenderBox;
        final frame = textAnnotationFrame(original, paper.size);
        await tester.tapAt(paper.localToGlobal(frame.center));
        await tester.pump();
        final start = paper.globalToLocal(
              tester.getCenter(find.byTooltip('缩放并旋转文字')),
            ),
            vector =
                paper.globalToLocal(
                  tester.getCenter(find.byTooltip('缩放并旋转文字')),
                ) -
                frame.center;
        Offset target(double degrees) {
          final angle = degrees * math.pi / 180 - original.rotation;
          return frame.center +
              Offset(
                    vector.dx * math.cos(angle) - vector.dy * math.sin(angle),
                    vector.dx * math.sin(angle) + vector.dy * math.cos(angle),
                  ) *
                  1.2;
        }

        final pointer = await tester.createGesture();
        await pointer.down(paper.localToGlobal(start));
        await pointer.moveTo(paper.localToGlobal(target(2)));
        await tester.pump();
        TextAnnotation preview() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<AnnotationPainter>()
            .firstWhere(
              (p) => p.annotations.whereType<TextAnnotation>().isNotEmpty,
            )
            .annotations
            .whereType<TextAnnotation>()
            .single;
        expect(preview().rotation, 0);
        expect(
          preview().fontSizeFraction,
          closeTo(original.fontSizeFraction * 1.2, .0001),
        );
        expect(
          find.byKey(const ValueKey('text-rotation-guide')),
          findsOneWidget,
        );
        await pointer.moveTo(paper.localToGlobal(target(6)));
        await tester.pump();
        expect(preview().rotation, 0);
        await pointer.moveTo(paper.localToGlobal(target(8)));
        await tester.pump();
        expect(preview().rotation, closeTo(8 * math.pi / 180, .001));
        await pointer.moveTo(paper.localToGlobal(target(88)));
        await tester.pump();
        expect(preview().rotation, math.pi / 2);
        expect(
          workspace.store.snapshot
              .annotationsFor(page)
              .whereType<TextAnnotation>()
              .single
              .rotation,
          .15,
        );
        await pointer.up();
        await _until(tester, () => !workspace.savingAnnotations);
        expect(_text(workspace, page).rotation, math.pi / 2);
        expect(find.byKey(const ValueKey('text-rotation-guide')), findsNothing);
        await _durable(tester, () => workspace.store.undo(page));
        expect(_text(workspace, page).geometry, original.geometry);
      } finally {
        await _cleanup(tester, workspace, dir);
      }
    },
  );
}
