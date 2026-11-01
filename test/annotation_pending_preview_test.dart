import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_workspace.dart';

/// Holds durable edits at the same PendingPathEdit boundary used by the real
/// workspace, and exposes commit/retirement as separately observable frames.
class _HeldWorkspace extends ReaderWorkspace {
  _HeldWorkspace(super.store);
  final _held = <(PendingPathEdit, Completer<void>)>[];
  int rebuildCalls = 0;
  @override
  Future<void> replacePaths(
    PageKey page,
    Map<String, List<List<NormalizedPoint>>> paths, {
    StrokePathRebuilder? rebuild,
  }) {
    final countedRebuild = rebuild == null
        ? null
        : (List<AnnotationStroke> strokes) {
            rebuildCalls++;
            return rebuild(strokes);
          };
    final edit = PendingPathEdit(page, paths, countedRebuild)..saving = true;
    final done = Completer<void>();
    pendingPaths.add(edit);
    _held.add((edit, done));
    notifyListeners();
    return done.future;
  }

  Future<void> commitHead() async {
    final edit = _held.first.$1;
    await store.replaceStrokePaths(
      edit.page,
      edit.paths,
      rebuild: edit.rebuild,
    );
    notifyListeners();
  }

  void retireHead() {
    final held = _held.removeAt(0);
    pendingPaths.remove(held.$1);
    held.$2.complete();
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'pending eraser previews compose both gaps through second move/lift and both durable commit boundaries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pending-erase-preview-'),
      ))!;
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final style = StrokeStyle(
        tool: AnnotationTool.pen,
        argb: 0xff112233,
        widthFraction: .004,
      );
      try {
        for (final commitWhileDown in [false, true]) {
          final workspace = _HeldWorkspace(store);
          final page = PageKey(
            entryId: commitWhileDown ? 'live' : 'queued',
            revisionId: 'r',
            pageNumber: 1,
          );
          await tester.runAsync(
            () => store.addStroke(
              page,
              style: style,
              points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
            ),
          );
          final generation = store.snapshot.generation;
          final phases = <(String, bool, bool)>[];
          void capture(String label) {
            final painter = tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((w) => w.painter)
                .whereType<AnnotationPainter>()
                .single;
            bool ink(double x) => painter.strokes.any(
              (s) => strokeHit(s, Offset(x, 500), const Size(1000, 1000), 0),
            );
            final left = ink(300), right = ink(700);
            phases.add((label, left, right));
            debugPrint(
              'ERASER_PENDING_PHASE live=$commitWhileDown $label leftInk=$left rightInk=$right paths=${painter.strokes.length}',
            );
            expect(
              ink(150) && ink(500) && ink(850),
              isTrue,
              reason: 'un-erased paper paths remain visible',
            );
            expect(
              painter.strokes.every((s) => s.style.argb == style.argb),
              isTrue,
            );
          }

          Future<void> commitFirst() async {
            await tester.runAsync(workspace.commitHead);
            await tester.pump();
            capture('first-commit-before-retire');
            workspace.retireHead();
            await tester.pump();
            capture('first-commit-after-retire');
          }

          try {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: AnnotationCanvas(
                    workspace: workspace,
                    page: page,
                    enabled: true,
                    style: style,
                    eraser: true,
                    eraserRadiusFraction: .02,
                  ),
                ),
              ),
            );
            final first = await tester.startGesture(
              const Offset(300, 300),
              pointer: 41,
              kind: PointerDeviceKind.stylus,
            );
            await first.moveTo(const Offset(300, 700));
            await first.up();
            await tester.pump();
            capture('first-up');
            final second = await tester.startGesture(
              const Offset(700, 300),
              pointer: 42,
              kind: PointerDeviceKind.stylus,
            );
            await second.moveTo(const Offset(700, 700));
            await tester.pump();
            capture('second-move');
            final rebuilds = workspace.rebuildCalls;
            for (var i = 0; i < 4; i++) {
              await second.moveBy(const Offset(0, 1));
              await tester.pump();
            }
            expect(
              workspace.rebuildCalls,
              rebuilds,
              reason: 'normal moves use incremental draft clipping, not replay every pending trace',
            );
            expect(
              store.snapshot.generation,
              generation,
              reason: 'previews do not write',
            );
            if (commitWhileDown) {
              await commitFirst();
              await second.moveTo(const Offset(700, 730));
              await tester.pump();
              capture('live-draft-after-id-change');
            }
            await second.up();
            await tester.pump();
            capture('second-up');
            expect(workspace.pendingPaths, hasLength(commitWhileDown ? 1 : 2));
            if (!commitWhileDown) await commitFirst();
            await tester.runAsync(workspace.commitHead);
            await tester.pump();
            capture('second-commit-before-retire');
            workspace.retireHead();
            await tester.pump();
            capture('second-commit-after-retire');
            expect(store.snapshot.generation, generation + 2);
            expect(store.snapshot.strokesFor(page), hasLength(3));
            expect(
              store.snapshot
                  .strokesFor(page)
                  .any((s) => s.id.startsWith('@preview')),
              isFalse,
            );
            expect(phases.first.$2, isFalse);
            expect(phases.first.$3, isTrue);
            for (final phase in phases.skip(1)) {
              expect(
                phase.$2,
                isFalse,
                reason: '${phase.$1}: left erased gap must never revive',
              );
              expect(
                phase.$3,
                isFalse,
                reason: '${phase.$1}: right erased gap must stay visible',
              );
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            workspace.dispose();
          }
        }
      } finally {
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
