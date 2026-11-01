import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/reader_tool_button.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_workspace.dart';

Future<void> flushInk(WidgetTester tester, ReaderWorkspace workspace) async {
  for (var i = 0; i < 240; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    if (!workspace.saving) break;
  }
  await tester.pump();
  expect(workspace.saving, isFalse);
}

void main() {
  testWidgets(
    'compact tool icons select on tap, independently drag sizes, cancel restores and pedal stays active',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = ReaderTool.pen, turns = 0, paperDowns = 0;
      final sizes = {
        ReaderTool.pen: 3.2,
        ReaderTool.highlighter: 16.0,
        ReaderTool.eraser: 14.6,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, refresh) => ReaderStage(
              onNext: () => turns++,
              top: Material(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final tool in ReaderTool.values)
                      ReaderToolButton(
                        key: ValueKey(tool),
                        tool: tool,
                        selected: selected == tool,
                        value: sizes[tool]!,
                        onSelect: () => refresh(() => selected = tool),
                        onChanged: (value) =>
                            refresh(() => sizes[tool] = value),
                      ),
                  ],
                ),
              ),
              bottom: const SizedBox(height: 60),
              contentBuilder: (_) => Listener(
                onPointerDown: (_) => paperDowns++,
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      expect(find.text('画笔'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      for (final tool in ReaderTool.values) {
        expect(tester.getSize(find.byKey(ValueKey(tool))), const Size(44, 44));
      }
      await tester.tap(find.byKey(const ValueKey(ReaderTool.highlighter)));
      await tester.pump();
      expect(selected, ReaderTool.highlighter);
      expect(sizes[ReaderTool.highlighter], 16);
      final pen = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey(ReaderTool.pen))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
      await pen.moveBy(const Offset(110, 25));
      await tester.pump();
      expect(sizes[ReaderTool.pen], greaterThan(12));
      expect(selected, ReaderTool.pen);
      expect(sizes[ReaderTool.highlighter], 16);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
      expect(turns, 1);
      await pen.up();
      await tester.pump();
      expect(paperDowns, 0);
      final before = sizes[ReaderTool.pen]!;
      final cancel = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey(ReaderTool.pen))),
      );
      await cancel.moveBy(const Offset(-70, 0));
      await tester.pump();
      expect(sizes[ReaderTool.pen], lessThan(before));
      await cancel.cancel();
      await tester.pump();
      expect(sizes[ReaderTool.pen], closeTo(before, .0001));
      final semantics = tester.ensureSemantics();
      final node = tester.getSemantics(find.bySemanticsLabel('橡皮'));
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          viewId: tester.view.viewId,
          nodeId: node.id,
          type: ui.SemanticsAction.increase,
        ),
      );
      await tester.pump();
      expect(sizes[ReaderTool.eraser], greaterThan(14.6));
      expect(sizes[ReaderTool.pen], before);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'parallel two-finger drag at 1x exposes both obstructed paper edges in portrait and landscape; stylus remains aligned',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('safe-paper-'),
      ))!;
      final workspace = (await tester.runAsync(
        () async => ReaderWorkspace(
          await ReaderStateStore.open(statePath: '${dir.path}/s.json'),
        ),
      ))!;
      var turns = 0;
      try {
        for (final size in [const Size(810, 1080), const Size(1080, 810)]) {
          await tester.binding.setSurfaceSize(size);
          final transform = TransformationController();
          EdgeInsets obstruction = EdgeInsets.zero;
          final page = PageKey(
            entryId: '${size.width}',
            revisionId: 'r',
            pageNumber: 1,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: StatefulBuilder(
                builder: (context, refresh) => ReaderStage(
                  onObstructionChanged: (value) =>
                      refresh(() => obstruction = value),
                  top: const SizedBox(height: 100),
                  bottom: const SizedBox(height: 80),
                  contentBuilder: (_) => ReaderInput(
                    editing: true,
                    transform: transform,
                    panInsets: obstruction,
                    pageAspect: .75,
                    onPrevious: () => turns++,
                    onNext: () => turns++,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: .75,
                        child: AnnotationCanvas(
                          workspace: workspace,
                          page: page,
                          enabled: true,
                          style: StrokeStyle(
                            tool: AnnotationTool.pen,
                            argb: 0xff123456,
                            widthFraction: .004,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          final paper = find.byType(AnnotationCanvas);
          final originalSize = tester.getSize(paper);
          Future<void> pan(double dy) async {
            final centre = size.center(Offset.zero);
            final a = await tester.startGesture(
              centre - const Offset(40, 0),
              pointer: 10,
              kind: PointerDeviceKind.touch,
            );
            final b = await tester.startGesture(
              centre + const Offset(40, 0),
              pointer: 11,
              kind: PointerDeviceKind.touch,
            );
            await a.moveBy(Offset(0, dy));
            await b.moveBy(Offset(0, dy));
            await a.up();
            await b.up();
            await tester.pump();
          }

          await pan(300);
          expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .0001));
          expect(
            tester.getTopLeft(paper).dy,
            greaterThanOrEqualTo(obstruction.top),
          );
          expect(tester.getSize(paper), originalSize);
          transform.value = Matrix4.identity();
          await tester.pump();
          await pan(-300);
          expect(
            tester.getBottomRight(paper).dy,
            lessThanOrEqualTo(size.height - obstruction.bottom),
          );
          expect(turns, 0);
          expect(workspace.store.snapshot.strokesFor(page), isEmpty);
          final box = tester.renderObject<RenderBox>(paper);
          final stroke = await tester.startGesture(
            box.localToGlobal(
              Offset(box.size.width * .25, box.size.height * .5),
            ),
            pointer: 20,
            kind: PointerDeviceKind.stylus,
          );
          await stroke.moveTo(
            box.localToGlobal(
              Offset(box.size.width * .75, box.size.height * .5),
            ),
          );
          await stroke.up();
          await flushInk(tester, workspace);
          final saved = workspace.store.snapshot.strokesFor(page).single;
          expect(saved.points.first.x, closeTo(.25, .001));
          expect(saved.points.last.x, closeTo(.75, .001));
          expect(saved.points.first.y, closeTo(.5, .001));
          await tester.pumpWidget(const SizedBox());
          transform.dispose();
        }
      } finally {
        await flushInk(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
