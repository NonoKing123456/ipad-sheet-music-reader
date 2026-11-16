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
  test('default 24px visuals anchor to the control frame with nearest circular 44px targets', () {
    for (final scale in [.7, .9, 1.0, 1.25, 2.0, 4.0]) {
      for (final height in [48.0, 68.0]) {
        final unit = 1 / scale;
        final frame = Rect.fromLTWH(250, 250, 210 * unit, height * unit);
        final placements = layoutTextHandles(
          frame: frame,
          viewport: const Rect.fromLTWH(0, 0, 2000, 2000),
          rotation: 0,
          scale: scale,
        );
        expect(
          (placements[TextHandleKind.move]!.visualRect.center -
                  frame.bottomLeft)
              .distance,
          closeTo(0, .001),
        );
        expect(
          (placements[TextHandleKind.width]!.visualRect.center -
                  frame.centerRight)
              .distance,
          closeTo(0, .001),
        );
        expect(
          (placements[TextHandleKind.transform]!.visualRect.center -
                  frame.bottomRight)
              .distance,
          closeTo(0, .001),
        );
        expect(
          placements[TextHandleKind.move]!.hitRect.topLeft,
          frame.bottomLeft - Offset(22 * unit, 22 * unit),
        );
        expect(
          placements[TextHandleKind.width]!.hitRect.topLeft,
          frame.centerRight - Offset(22 * unit, 22 * unit),
        );
        expect(
          placements[TextHandleKind.transform]!.hitRect.topLeft,
          frame.bottomRight - Offset(22 * unit, 22 * unit),
        );
        final rects = placements.values.toList();
        for (var i = 0; i < rects.length; i++) {
          expect(rects[i].hitRect.width * scale, closeTo(44, .001));
          expect(rects[i].visualRect.width * scale, closeTo(24, .001));
          // 9870dab / spec 10.2: centered circular targets may overlap their
          // bounding boxes; the input center stays outside the 22dp radius.
          expect(
            hitTestTextHandle(
              point: frame.center,
              centres: {
                for (final entry in placements.entries)
                  entry.key: entry.value.hitRect.center,
              },
              radius: 22 * unit,
            ),
            isNull,
          );
          for (var j = i + 1; j < rects.length; j++) {
            expect(
              hitTestTextHandle(
                point: rects[i].hitRect.center,
                centres: {
                  for (final entry in placements.entries)
                    entry.key: entry.value.hitRect.center,
                },
                radius: 22 * unit,
              ),
              placements.keys.elementAt(i),
            );
          }
        }
      }
    }
  });
  test('rotated and edge placements keep targets separate and inside the viewport when space allows', () {
    const viewport = Rect.fromLTWH(0, 0, 744, 800);
    for (final scale in [.7, 1.0, 2.0, 4.0]) {
      for (final rotation in [-.55, 0.0, .55, math.pi / 2]) {
        for (final origin in [const Offset(100, 150), const Offset(390, 590)]) {
          final frame = origin & Size(180, 68 / scale);
          // Rotation remains about the original text's centre, independently
          // of any extra control-frame height supplied by the caller.
          final pivot = frame.topLeft + const Offset(90, 24);
          final placements = layoutTextHandles(
            frame: frame,
            viewport: viewport,
            rotation: rotation,
            scale: scale,
            rotationCentre: pivot,
          );
          final rects = placements.values.toList();
          for (var i = 0; i < rects.length; i++) {
            expect(rects[i].hitRect.width * scale, closeTo(44, .001));
            expect(rects[i].hitRect.height * scale, closeTo(44, .001));
            expect(rects[i].visualRect.width * scale, closeTo(24, .001));
            expect(rects[i].visualRect.height * scale, closeTo(24, .001));
            for (var j = i + 1; j < rects.length; j++) {
              expect(
                hitTestTextHandle(
                  point: rects[j].hitRect.center,
                  centres: {
                    for (final entry in placements.entries)
                      entry.key: entry.value.hitRect.center,
                  },
                  radius: 22 / scale,
                ),
                placements.keys.elementAt(j),
              );
            }
            for (final point in _corners(rects[i].hitRect)) {
              final d = point - pivot;
              final rotated =
                  pivot +
                  Offset(
                    d.dx * math.cos(rotation) - d.dy * math.sin(rotation),
                    d.dx * math.sin(rotation) + d.dy * math.cos(rotation),
                  );
              expect(viewport.inflate(.001).contains(rotated), isTrue);
            }
          }
        }
      }
    }
  });
  test('bottom/keyboard placement keeps every target visible without an extra bottom area', () {
    const frame = Rect.fromLTWH(410, 420, 280, 58),
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
        for (final color in [0xff9b5949, 0xff222222, 0xff1c57ac, 0xffffc107]) {
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
        expect(find.byTooltip('当前颜色'), findsOneWidget);
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
          // SUSPECTED-REGRESSION: the handle must not swallow caret placement.
          reason: 'handles do not consume the text caret area',
        );
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          const Color(0xff1c57ac),
        );
        final widthHandle = tester.renderObject<RenderBox>(
          find.byTooltip('调整换行宽度'),
        );
        final contextActions = tester.renderObject<RenderBox>(
          find.byKey(const ValueKey('text-context-actions')),
        );
        final widthHandleRect =
            widthHandle.localToGlobal(Offset.zero) & widthHandle.size;
        final contextActionsRect =
            contextActions.localToGlobal(Offset.zero) & contextActions.size;
        expect(
          widthHandleRect.overlaps(contextActionsRect),
          isFalse,
          reason: 'the floating context actions must not cover a text handle',
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
            const Size(24, 24),
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
        // 9870dab: a short nonempty draft tightens to the 96dp minimum.
        expect(tester.getSize(find.byType(TextField)).width, 96);
        final shortWidth = tester.getSize(find.byType(TextField)).width;
        await tester.enterText(
          find.byType(TextField),
          'abcdefghij abcdefghij abcdefghij abcdefghij',
        );
        await tester.pump();
        final grown = tester.getSize(find.byType(TextField));
        expect(grown.width, greaterThan(shortWidth));
        expect(grown.width, lessThanOrEqualTo(paper.size.width * .181));
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
  );
}
