import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/incremental_stroke_path.dart';
import 'package:score_reader/reader/reader_workspace.dart';

class _HeldInkWorkspace extends ReaderWorkspace {
  _HeldInkWorkspace(super.store);
  final _held = <(PendingStroke, Completer<void>)>[];
  @override
  Future<void> addStroke(
    PageKey page,
    StrokeStyle style,
    List<NormalizedPoint> points,
  ) {
    final stroke = PendingStroke(page, style, points);
    final done = Completer<void>();
    pending.add(stroke);
    _held.add((stroke, done));
    notifyListeners();
    return done.future;
  }

  Future<void> commitInk() async {
    for (final (stroke, done) in _held) {
      await store.addStroke(
        stroke.page,
        style: stroke.style,
        points: stroke.points,
      );
      pending.remove(stroke);
      done.complete();
    }
    _held.clear();
    notifyListeners();
  }
}

void main() {
  test('new ink keeps dots, short lines, explicit corners and exact final subpixel endpoint', () {
    final dot = IncrementalStrokePath(paperAspect: .8)
      ..add(NormalizedPoint(.2, .3));
    expect(dot.points, [NormalizedPoint(.2, .3)]);
    dot.add(NormalizedPoint(.2001, .3001));
    expect(dot.points, hasLength(1));
    dot.add(NormalizedPoint(.2001, .3001), exact: true);
    expect(dot.points, [
      NormalizedPoint(.2, .3),
      NormalizedPoint(.2001, .3001),
    ]);
    final corner = IncrementalStrokePath(paperAspect: .8);
    final samples = [
      NormalizedPoint(.1, .2),
      NormalizedPoint(.4, .2),
      NormalizedPoint(.4, .5),
    ];
    for (final sample in samples) {
      corner.add(sample);
    }
    expect(corner.points, samples);
    corner.add(NormalizedPoint(.3998, .5001), exact: true);
    expect(corner.points.first, samples.first);
    expect(corner.points.last, NormalizedPoint(.3998, .5001));
    expect(corner.points, contains(samples[1]));
  });

  test('midpoint ink reduces spatial jitter and follows a continuous bounded arc', () {
    final raw = [
      for (var i = 0; i < 90; i++)
        NormalizedPoint(.1 + i * .008, .5 + (i.isEven ? .0012 : -.0012)),
    ];
    final path = IncrementalStrokePath(paperAspect: 1);
    for (final p in raw) {
      path.add(p);
    }
    // Integrate squared displacement along actual line geometry, independent
    // of sampling density or the smoothing implementation.
    double rms(List<NormalizedPoint> points) {
      var energy = 0.0, width = 0.0;
      for (var i = 1; i < points.length; i++) {
        final a = points[i - 1], b = points[i];
        if (a.x < .14 || b.x > .75) continue;
        final dx = b.x - a.x, y0 = a.y - .5, y1 = b.y - .5;
        energy += dx * (y0 * y0 + y0 * y1 + y1 * y1) / 3;
        width += dx;
      }
      return math.sqrt(energy / width);
    }

    final ratio = rms(path.points) / rms(raw);
    expect(ratio, lessThan(.75));
    expect(path.points.first, raw.first);
    expect(path.points.last, raw.last);
    final arc = IncrementalStrokePath(paperAspect: 1);
    for (var i = 0; i <= 40; i++) {
      final angle = i * math.pi / 40;
      arc.add(
        NormalizedPoint(.5 + .3 * math.cos(angle), .5 + .3 * math.sin(angle)),
      );
    }
    var maxTurn = 0.0;
    for (var i = 1; i < arc.points.length; i++) {
      final p = arc.points[i];
      expect((Offset(p.x - .5, p.y - .5).distance - .3).abs(), lessThan(.001));
      final prev = arc.points[i - 1];
      final d = Offset(p.x - prev.x, p.y - prev.y);
      expect(d.distance, lessThan(.04));
      if (i > 1) {
        final before = arc.points[i - 2];
        final incoming = Offset(prev.x - before.x, prev.y - before.y);
        final turn = math.acos(
          ((d.dx * incoming.dx + d.dy * incoming.dy) /
                  (d.distance * incoming.distance))
              .clamp(-1.0, 1.0),
        );
        maxTurn = math.max(maxTurn, turn);
      }
    }
    expect(maxTurn, lessThan(.13));
    debugPrint(
      'INK_GEOMETRY jitter_rms_ratio=$ratio arc_max_turn=$maxTurn points=${arc.points.length}',
    );
  });

  test('long captured ink mutates only a bounded tail with adaptive straight sampling', () {
    final path = IncrementalStrokePath(paperAspect: .8);
    final buffer = path.points;
    final stable = <int, NormalizedPoint>{};
    var maxGrowth = 0;
    for (var i = 0; i < 4000; i++) {
      final count = buffer.length;
      final lastStableIndex = count - 2;
      final lastStable = lastStableIndex >= 0 ? buffer[lastStableIndex] : null;
      path.add(
        NormalizedPoint(
          .5 + .4 * math.sin(i * .018),
          .5 + .4 * math.cos(i * .023),
        ),
      );
      expect(path.points, same(buffer));
      maxGrowth = math.max(maxGrowth, buffer.length - count);
      expect(buffer.length - count, lessThanOrEqualTo(12));
      if (lastStable != null) expect(buffer[lastStableIndex], same(lastStable));
      if (i % 250 == 0 && buffer.length > 2) {
        stable[buffer.length - 2] = buffer[buffer.length - 2];
      }
    }
    for (final entry in stable.entries) {
      expect(buffer[entry.key], same(entry.value));
    }
    expect(
      buffer.every((p) => p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1),
      isTrue,
    );
    final straight = IncrementalStrokePath(paperAspect: .8);
    for (var i = 0; i < 800; i++) {
      straight.add(NormalizedPoint(.1 + i * .001, .5));
    }
    expect(straight.points, hasLength(800));
    debugPrint(
      'INK_INCREMENTAL inputs=4000 points=${buffer.length} max_growth=$maxGrowth straight_inputs=800 straight_points=${straight.points.length}',
    );
  });

  testWidgets(
    'captured smooth geometry is identical in live, pending, saved and reopened ink; local eraser/undo, cancel and page changes preserve it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ink-081-'),
      ))!;
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final workspace = _HeldInkWorkspace(store);
      final page = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1);
      final nextPage = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 2);
      final style = StrokeStyle(
        tool: AnnotationTool.pen,
        argb: 0xff223344,
        widthFraction: .002,
      );
      final historicalPoints = [
        NormalizedPoint(.1, .85),
        NormalizedPoint(.3, .82),
        NormalizedPoint(.6, .85),
      ];
      final historical = (await tester.runAsync(
        () => store.addStroke(page, style: style, points: historicalPoints),
      ))!;
      var visible = page, erasing = false;
      late StateSetter update;
      AnnotationPainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<AnnotationPainter>()
          .single;
      Future<void> flush() async {
        for (var i = 0; i < 200 && workspace.saving; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(workspace.saving, isFalse);
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, refresh) {
                update = refresh;
                return AnnotationCanvas(
                  workspace: workspace,
                  page: visible,
                  enabled: true,
                  style: style,
                  eraser: erasing,
                  eraserRadiusFraction: .012,
                );
              },
            ),
          ),
        );
        final pen = await tester.startGesture(
          const Offset(80, 400),
          pointer: 20,
          kind: PointerDeviceKind.stylus,
        );
        for (var i = 1; i <= 20; i++) {
          await pen.moveTo(Offset(80 + i * 28, 400 + (i.isEven ? 8 : -8)));
        }
        await tester.pump();
        final live = List<NormalizedPoint>.of(painter().draft);
        expect(live.length, greaterThan(21));
        expect(painter().strokes.single.points, historicalPoints);
        await pen.up();
        await tester.pump();
        expect(painter().draft, isEmpty);
        expect(painter().pending.single.points, live);
        debugPrint('INK_LIVE_PENDING points=${live.length}');
        await tester.runAsync(workspace.commitInk);
        await tester.pump();
        final saved = store.snapshot
            .strokesFor(page)
            .singleWhere((s) => s.id != historical.id);
        expect(saved.points, live);
        final reopened = (await tester.runAsync(
          () => ReaderStateStore.open(statePath: store.statePath),
        ))!;
        expect(
          reopened.snapshot
              .strokesFor(page)
              .singleWhere((s) => s.id == saved.id)
              .points,
          live,
        );
        expect(
          reopened.snapshot
              .strokesFor(page)
              .singleWhere((s) => s.id == historical.id)
              .points,
          historicalPoints,
        );
        final middle = live[live.length ~/ 2];
        final hit = Offset(middle.x * 800, middle.y * 1000);
        expect(strokeHit(saved, hit, const Size(800, 1000), 0), isTrue);
        update(() => erasing = true);
        await tester.pump();
        final eraser = await tester.startGesture(
          hit - const Offset(0, 60),
          pointer: 21,
          kind: PointerDeviceKind.stylus,
        );
        await eraser.moveTo(hit + const Offset(0, 60));
        await tester.pump();
        final preview = [
          for (final stroke in painter().strokes)
            List<NormalizedPoint>.of(stroke.points),
        ];
        expect(
          painter().strokes.any(
            (s) => strokeHit(s, hit, const Size(800, 1000), 0),
          ),
          isFalse,
        );
        await eraser.up();
        await flush();
        expect([
          for (final stroke in painter().strokes) stroke.points,
        ], preview);
        expect(
          store.snapshot
              .strokesFor(page)
              .singleWhere((s) => s.id == historical.id)
              .points,
          historicalPoints,
        );
        await tester.runAsync(() => store.undo(page));
        workspace.refreshFromStore();
        await tester.pump();
        expect(
          store.snapshot
              .strokesFor(page)
              .singleWhere((s) => s.id == saved.id)
              .points,
          live,
        );
        final undone = (await tester.runAsync(
          () => ReaderStateStore.open(statePath: store.statePath),
        ))!;
        expect(
          undone.snapshot
              .strokesFor(page)
              .singleWhere((s) => s.id == saved.id)
              .points,
          live,
        );
        update(() => erasing = false);
        await tester.pump();
        final cancel = await tester.startGesture(
          const Offset(100, 200),
          pointer: 22,
          kind: PointerDeviceKind.stylus,
        );
        await cancel.moveTo(const Offset(200, 230));
        await cancel.cancel();
        expect(workspace.pending, isEmpty);
        final stale = await tester.startGesture(
          const Offset(100, 200),
          pointer: 23,
          kind: PointerDeviceKind.stylus,
        );
        await stale.moveTo(const Offset(220, 230));
        update(() => visible = nextPage);
        await tester.pump();
        await stale.up();
        expect(workspace.pending, isEmpty);
        expect(store.snapshot.strokesFor(nextPage), isEmpty);
        expect(store.snapshot.strokesFor(page), hasLength(2));
        debugPrint(
          'INK_LIFECYCLE live=pending=saved=reopened points=${live.length}; eraser_preview=saved; undo=reopened; historical_unchanged=true; cancel_and_page_stale_not_saved=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
