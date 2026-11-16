import 'dart:ui' as ui;
import 'dart:io';

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
    'compact tool icons select on tap while explicit sizing remains external and page keys stay active',
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final tool in ReaderTool.values)
                          ReaderToolButton(
                            key: ValueKey(tool),
                            tool: tool,
                            selected: selected == tool,
                            value: sizes[tool]!,
                            onSelect: () => refresh(() => selected = tool),
                          ),
                      ],
                    ),
                    SizedBox(
                      width: 220,
                      child: Slider(
                        key: const ValueKey('explicit-tool-size'),
                        min: selected.minSize,
                        max: selected.maxSize,
                        value: sizes[selected]!,
                        onChanged: (value) =>
                            refresh(() => sizes[selected] = value),
                      ),
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
      expect(find.byTooltip('画笔'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      for (final tool in ReaderTool.values) {
        expect(tester.getSize(find.byKey(ValueKey(tool))), const Size(48, 48));
      }
      await tester.tap(find.byKey(const ValueKey(ReaderTool.highlighter)));
      await tester.pump();
      expect(selected, ReaderTool.highlighter);
      expect(sizes[ReaderTool.highlighter], 16);
      await tester.drag(
        find.byKey(const ValueKey('explicit-tool-size')),
        const Offset(70, 0),
      );
      await tester.pump();
      expect(sizes[ReaderTool.highlighter], greaterThan(16));
      expect(sizes[ReaderTool.pen], 3.2);
      await tester.tap(find.byKey(const ValueKey(ReaderTool.pen)));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('explicit-tool-size')),
        const Offset(55, 0),
      );
      await tester.pump();
      expect(sizes[ReaderTool.pen], greaterThan(3.2));
      expect(sizes[ReaderTool.highlighter], greaterThan(16));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
      expect(turns, 1);
      expect(paperDowns, 0);
      final before = sizes[ReaderTool.pen]!;
      expect(before, greaterThan(3.2));
      final semantics = tester.ensureSemantics();
      final eraserKey = const ValueKey(ReaderTool.eraser);
      final eraserSemantics = find.descendant(
        of: find.byKey(eraserKey),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '橡皮',
        ),
      );
      final node = tester.getSemantics(eraserSemantics);
      expect(node.label, '橡皮');
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isSelected, ui.Tristate.isFalse);
      // v2 puts the actionable semantics on the inner native TextButton.
      final tapNode = tester.getSemantics(
        find.descendant(
          of: find.byKey(eraserKey),
          matching: find.byType(TextButton),
        ),
      );
      tapNode.owner!.performAction(tapNode.id, ui.SemanticsAction.tap);
      await tester.pump();
      expect(selected, ReaderTool.eraser);
      expect(sizes[ReaderTool.eraser], 14.6);
      expect(sizes[ReaderTool.pen], before);
      final selectedNode = tester.getSemantics(eraserSemantics);
      expect(selectedNode.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('explicit-tool-size')))
            .value,
        14.6,
      );
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
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
