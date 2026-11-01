import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_workspace.dart';

void main() {
  testWidgets(
    'scaled paper records normalized points and writing never turns a page',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('canvas-test-'),
      ))!;
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(
            statePath: p.join(directory.path, 'state.json'),
          ),
        ))!,
      );
      final page = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1);
      var turns = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderInput(
              onPrevious: () => turns++,
              onNext: () => turns++,
              allowPointerPageTurns: false,
              child: Center(
                child: Transform.scale(
                  scale: 1.5,
                  child: SizedBox(
                    width: 200,
                    height: 100,
                    child: AnnotationCanvas(
                      workspace: workspace,
                      page: page,
                      enabled: true,
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
          ),
        ),
      );
      final canvas = find.byType(AnnotationCanvas);
      final start = tester.getTopLeft(canvas);
      final end = tester.getBottomRight(canvas);
      final size = end - start;
      await tester.runAsync(() async {
        final pointer = await tester.startGesture(
          start + Offset(size.dx * .25, size.dy * .5),
          kind: PointerDeviceKind.stylus,
        );
        await pointer.moveTo(start + Offset(size.dx * .75, size.dy * .5));
        await pointer.up();
      });
      await tester.pump();
      await tester.runAsync(() async {
        while (workspace.saving) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final stroke = workspace.store.snapshot.strokesFor(page).single;
      expect(stroke.points.first.x, closeTo(.25, .001));
      expect(stroke.points.first.y, closeTo(.5, .001));
      expect(stroke.points.last.x, closeTo(.75, .001));
      expect(turns, 0);
      expect(
        strokeHit(stroke, const Offset(100, 50), const Size(200, 100), 3),
        isTrue,
      );
      expect(
        strokeHit(stroke, const Offset(100, 90), const Size(200, 100), 3),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}
