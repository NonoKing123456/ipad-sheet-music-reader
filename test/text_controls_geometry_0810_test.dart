import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_text_editing.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/text_handle_layout.dart';

class _EdgeHarness extends StatefulWidget {
  const _EdgeHarness({super.key, required this.workspace, required this.page});
  final ReaderWorkspace workspace;
  final PageKey page;
  @override
  State<_EdgeHarness> createState() => _EdgeState();
}

class _EdgeState extends State<_EdgeHarness> {
  final controls = ReaderTextEditorController();
  final transform = TransformationController();
  final viewport = GlobalKey(),
      top = GlobalKey(),
      paper = GlobalKey(),
      selection = GlobalKey();
  bool textTool = true;
  void hide() => setState(() => textTool = false);
  @override
  void dispose() {
    controls.dispose();
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Column(
      children: [
        Material(
          key: top,
          child: ReaderTextFormatControls(controller: controls),
        ),
        Expanded(
          child: ReaderInput(
            onPrevious: () {},
            onNext: () {},
            editing: true,
            textTool: textTool,
            transform: transform,
            viewportKey: viewport,
            textControls: controls,
            textSelectionKey: selection,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 20),
              child: ColoredBox(
                key: paper,
                color: Colors.white,
                child: AnnotationTextLayer(
                  workspace: widget.workspace,
                  page: widget.page,
                  enabled: true,
                  textTool: textTool,
                  transform: transform,
                  textControls: controls,
                  viewportKey: viewport,
                  topControlsKey: top,
                  selectionKey: selection,
                  style: StrokeStyle(
                    tool: AnnotationTool.pen,
                    argb: 0xff222222,
                    widthFraction: .004,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 4)),
    );
  }
  expect(done(), isTrue);
  await tester.pump();
}

List<Offset> _corners(Rect rect) => [
  rect.topLeft,
  rect.topRight,
  rect.bottomLeft,
  rect.bottomRight,
];
void main() {
  test('44px handle targets stay separate outside input; 28px visuals remain four pixels from its edge', () {
    for (final scale in [.7, 1.0, 2.0, 4.0]) {
      for (final rotation in [-.55, 0.0, .55, math.pi / 2]) {
        for (final frame in [
          const Rect.fromLTWH(220, 230, 210, 12),
          const Rect.fromLTWH(80, 70, 80, 12),
          const Rect.fromLTWH(570, 430, 100, 16),
        ]) {
          const viewport = Rect.fromLTWH(0, 44, 744, 456);
          final placements = layoutTextHandles(
            frame: frame,
            viewport: viewport,
            rotation: rotation,
            scale: scale,
          );
          final rects = placements.values.toList();
          for (var i = 0; i < rects.length; i++) {
            final placement = rects[i];
            expect(placement.hitRect.width * scale, closeTo(44, .001));
            expect(placement.hitRect.height * scale, closeTo(44, .001));
            expect(placement.visualRect.width * scale, closeTo(28, .001));
            expect(placement.visualRect.height * scale, closeTo(28, .001));
            expect(placement.hitRect.overlaps(frame), isFalse);
            for (var j = i + 1; j < rects.length; j++) {
              expect(placement.hitRect.overlaps(rects[j].hitRect), isFalse);
            }
            final visual = placement.visualRect;
            final dx = math.max(
              0.0,
              math.max(frame.left - visual.right, visual.left - frame.right),
            );
            final dy = math.max(
              0.0,
              math.max(frame.top - visual.bottom, visual.top - frame.bottom),
            );
            expect(Offset(dx, dy).distance * scale, inInclusiveRange(2, 6.01));
          }
        }
      }
    }
  });
  test('bottom/keyboard placement keeps every target visible without an extra bottom area', () {
    const frame = Rect.fromLTWH(410, 470, 280, 16),
        viewport = Rect.fromLTRB(0, 44, 744, 500);
    final placements = layoutTextHandles(
      frame: frame,
      viewport: viewport,
      rotation: 0,
      scale: 1,
    );
    for (final placement in placements.values) {
      for (final point in _corners(placement.hitRect)) {
        expect(viewport.inflate(.001).contains(point), isTrue);
      }
    }
    expect(
      placements[TextHandleKind.transform]!.visualRect.center.dx,
      greaterThan(frame.right),
    );
  });
  testWidgets(
    'pen/text colors always use the same 28px dot, external ring and 44px target',
    (tester) async {
      final controls = ReaderTextEditorController();
      var ink = 0xff222222;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    ReaderAnnotationColors(
                      argb: ink,
                      onChanged: (color) => setState(() => ink = color),
                    ),
                    ReaderTextFormatControls(controller: controls),
                  ],
                ),
              ),
            ),
          ),
        );
        for (final color in [0xffc12b32, 0xff222222, 0xff1c57ac, 0xffffc107]) {
          final dots = find.byKey(ValueKey('annotation-color-dot-$color'));
          expect(dots, findsNWidgets(2));
          for (final item in dots.evaluate()) {
            expect(
              (item.findRenderObject()! as RenderBox).size,
              const Size(28, 28),
            );
          }
        }
        expect(tester.getSize(find.byTooltip('蓝色').first), const Size(44, 44));
        await tester.tap(find.byTooltip('蓝色').first);
        await tester.tap(find.byTooltip('蓝色').last);
        await tester.pump();
        expect(
          find.byKey(ValueKey('annotation-color-selection-${0xff1c57ac}')),
          findsNWidgets(2),
        );
        for (final element
            in find
                .byKey(ValueKey('annotation-color-selection-${0xff1c57ac}'))
                .evaluate()) {
          expect(
            (element.findRenderObject()! as RenderBox).size,
            const Size(36, 36),
          );
        }
        controls.changeColor(0xffffffff);
        await tester.pump();
        expect(
          tester.getSize(
            find.byKey(ValueKey('annotation-color-dot-${0xffffffff}')),
          ),
          const Size(28, 28),
        );
        expect(find.byTooltip('当前文字颜色'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controls.dispose();
      }
    },
  );
  testWidgets(
    'rotated edge single-line text keeps caret, keyboard targets, transparent outside and portal cleanup',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(744, 800);
      await tester.binding.setSurfaceSize(const Size(744, 800));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('handle-edge-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final page = PageKey(
            entryId: 'synthetic-edge',
            revisionId: 'r',
            pageNumber: 1,
          ),
          key = GlobalKey<_EdgeState>();
      try {
        final original = workspace.store
            .newText(
              text: '单行文字',
              anchor: NormalizedPoint(.66, .9),
              argb: 0xff222222,
            )
            .revise(
              rotation: -.25,
              widthFraction: .2,
              now: DateTime.now().toUtc(),
            );
        await tester.runAsync(() => workspace.store.saveText(page, original));
        await tester.pumpWidget(
          MaterialApp(
            home: _EdgeHarness(key: key, workspace: workspace, page: page),
          ),
        );
        await tester.pumpAndSettle();
        final state = key.currentState!,
            paper =
                key.currentState!.paper.currentContext!.findRenderObject()!
                    as RenderBox;
        await tester.tapAt(
          paper.localToGlobal(textAnnotationFrame(original, paper.size).center),
        );
        await tester.pump();
        state.controls.onEdit!();
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        for (final label in ['移动文字', '缩放并旋转文字', '调整换行宽度']) {
          final handle = tester.renderObject<RenderBox>(find.byTooltip(label));
          expect(handle.size, const Size(44, 44));
          for (final point in _corners(
            Offset.zero & handle.size,
          ).map(handle.localToGlobal)) {
            expect(point.dx, inInclusiveRange(0, 744));
            expect(point.dy, inInclusiveRange(44, 500));
          }
        }
        final field = tester.widget<TextField>(find.byType(TextField)),
            input = tester.renderObject<RenderBox>(find.byType(TextField));
        field.controller!.selection = const TextSelection.collapsed(offset: 4);
        await tester.tapAt(input.localToGlobal(const Offset(2, 5)));
        await tester.pump();
        expect(
          field.controller!.selection.baseOffset,
          lessThan(4),
          reason: 'handles do not consume the text caret area',
        );
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          const Color(0xff1c57ac),
        );
        final generation = workspace.store.snapshot.generation;
        await tester.drag(find.byTooltip('调整换行宽度'), const Offset(-12, 0));
        await tester.pump();
        expect(workspace.store.snapshot.generation, generation);
        expect(find.byType(TextField), findsOneWidget);
        await tester.tapAt(const Offset(5, 250));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        await tester.pump();
        expect(
          workspace.store.snapshot
              .annotationsFor(page)
              .whereType<TextAnnotation>()
              .single
              .argb,
          0xff1c57ac,
        );
        state.transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-500, -700, 0);
        await tester.pump();
        await tester.pump();
        for (final kind in TextHandleKind.values) {
          expect(
            tester.getSize(
              find.byKey(ValueKey('text-handle-visual-${kind.name}')),
            ),
            const Size(28, 28),
          );
        }
        state.hide();
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('移动文字'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        expect(find.byTooltip('调整换行宽度'), findsNothing);
        expect(readerTextEditorActive, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        tester.view.resetViewInsets();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'new draft starts short, grows to a cap, then keeps manual and saved widths',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(744, 800);
      await tester.binding.setSurfaceSize(const Size(744, 800));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('text-auto-width-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
        ))!,
      );
      final page = PageKey(
            entryId: 'synthetic-width',
            revisionId: 'r',
            pageNumber: 1,
          ),
          key = GlobalKey<_EdgeState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: _EdgeHarness(key: key, workspace: workspace, page: page),
          ),
        );
        await tester.pumpAndSettle();
        final state = key.currentState!,
            paper =
                key.currentState!.paper.currentContext!.findRenderObject()!
                    as RenderBox;
        await tester.tapAt(
          paper.localToGlobal(
            Offset(paper.size.width * .2, paper.size.height * .35),
          ),
        );
        await tester.pump();
        final firstWidth = tester.getSize(find.byType(TextField)).width,
            firstHeight = tester.getSize(find.byType(TextField)).height;
        final font = tester
            .widget<TextField>(find.byType(TextField))
            .style!
            .fontSize;
        expect(firstWidth, inInclusiveRange(90, 120));
        expect(firstWidth, lessThan(paper.size.width * .45));
        await tester.enterText(find.byType(TextField), '短');
        await tester.pump();
        expect(tester.getSize(find.byType(TextField)).width, firstWidth);
        await tester.enterText(
          find.byType(TextField),
          'abcdefghij abcdefghij abcdefghij abcdefghij',
        );
        await tester.pump();
        final grown = tester.getSize(find.byType(TextField));
        expect(grown.width, greaterThan(firstWidth));
        expect(grown.width, lessThanOrEqualTo(paper.size.width * .301));
        expect(grown.height, greaterThan(firstHeight));
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.fontSize,
          font,
        );
        await tester.drag(find.byTooltip('调整换行宽度'), const Offset(40, 0));
        await tester.pump();
        final manual = tester.getSize(find.byType(TextField)).width;
        expect(manual, greaterThan(grown.width));
        await tester.enterText(find.byType(TextField), 'longer text ' * 12);
        await tester.pump();
        expect(
          tester.getSize(find.byType(TextField)).width,
          manual,
          reason: 'typing no longer owns width after the width handle',
        );
        await tester.tapAt(const Offset(5, 250));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        final saved = workspace.store.snapshot
            .annotationsFor(page)
            .whereType<TextAnnotation>()
            .single;
        expect(saved.widthFraction, closeTo(manual / paper.size.width, .0001));
        state.controls.onEdit!();
        await tester.pump();
        await tester.enterText(find.byType(TextField), '旧文字变短');
        await tester.pump();
        expect(
          tester.getSize(find.byType(TextField)).width,
          manual,
          reason: 'existing records keep their saved width',
        );
        await tester.tapAt(const Offset(5, 250));
        await _until(
          tester,
          () => !state.controls.editing && !workspace.savingAnnotations,
        );
        expect(
          workspace.store.snapshot
              .annotationsFor(page)
              .whereType<TextAnnotation>()
              .single
              .widthFraction,
          saved.widthFraction,
        );
        state.transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-500, -600, 0);
        await tester.pump();
        await tester.pump();
        await tester.tapAt(const Offset(730, 650));
        await tester.pump();
        await tester.pump();
        final input = tester.renderObject<RenderBox>(find.byType(TextField));
        expect(input.localToGlobal(Offset.zero).dx, greaterThanOrEqualTo(0));
        expect(
          input.localToGlobal(Offset(input.size.width, 0)).dx,
          lessThanOrEqualTo(744),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
