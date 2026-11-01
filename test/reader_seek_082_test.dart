import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_page_seek_bar.dart';
import 'package:score_reader/reader/reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';

import 'reader_fixture.dart';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue, reason: 'bounded ready/persistence operation');
  await tester.pump();
}

void main() {
  test('live seek coalesces only consecutive requests, preserves pedal order and item identity, cancels pending gesture and persists only presented page', () async {
    final dir = await Directory.systemTemp.createTemp('seek-order-082-');
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${dir.path}/state.json'),
    );
    final target = ScoreTarget(
      entryId: 'synthetic',
      revisionId: 'r1',
      filePath: 'synthetic.png',
      displayPath: 'synthetic.png',
    );
    final list = await workspace.store.createSetList('synthetic');
    final item = await workspace.store.addItem(list.id, target.entryId);
    final session = ReaderSession(
      workspace: workspace,
      locate: (_) => target,
      setListId: list.id,
      deferPositionPersistence: true,
      loader: (target) async => LoadedScore(target: target, pageCount: 820),
    );
    try {
      await session.open(target, itemId: item.id);
      final pages = <int>[];
      session.addListener(() => pages.add(session.page));
      final gesture = Object();
      final first = session.seek(100, gesture: gesture);
      unawaited(session.seek(200, gesture: gesture));
      unawaited(session.turn(NavigationDirection.forward));
      unawaited(session.seek(300, gesture: gesture));
      unawaited(session.seek(400, gesture: gesture));
      await first;
      expect(pages, [200, 201, 400]);
      expect(session.position!.setListItemId, item.id);
      expect(workspace.store.readingPosition(target.key), isNull);
      session.rememberPresented(
        PageKey(
          entryId: target.entryId,
          revisionId: target.revisionId,
          pageNumber: 201,
        ),
        820,
      );
      await workspace.flushPositions();
      expect(workspace.store.readingPosition(target.key)!.pageNumber, 201);
      final cancel = Object();
      final pending = session.seek(600, gesture: cancel);
      session.cancelSeek(cancel);
      await pending;
      expect(session.page, 400);
      // A new document selection retires the old gesture without losing the
      // selected set-list identity to the late request.
      final stale = Object();
      final queued = session.seek(800, gesture: stale);
      await session.open(
        target,
        itemId: item.id,
        pageNumber: 12,
        restore: false,
      );
      await queued;
      expect(session.page, 12);
      expect(session.position!.setListItemId, item.id);
      debugPrint(
        'SEEK_ORDER_082 sequence=200,201,400 consecutive_latest_only=true pedal_preserved=true presented_bookmark=201 cancel_and_stale=true',
      );
    } finally {
      session.dispose();
      workspace.dispose();
      await dir.delete(recursive: true);
    }
  });

  testWidgets(
    'actual overlay live-seeks before up for touch/mouse without ink; bottom stylus first point and mid-scrub pen preserve actual PageKey; hidden controls restore page gestures',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('seek-overlay-082-'),
      ))!;
      await writeSyntheticPaper(
        tester,
        '${dir.path}/synthetic.PNG',
        width: 81,
        height: 108,
      );
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final workspace = ReaderWorkspace(store);
      final target = ScoreTarget(
        entryId: 'synthetic',
        revisionId: 'r1',
        filePath: '${dir.path}/synthetic.PNG',
        displayPath: 'synthetic.PNG',
      );
      int visible() => tester
          .widget<ReaderPageSeekBar>(find.byType(ReaderPageSeekBar))
          .currentPage;
      Rect region() {
        final widget = tester.widget<ReaderPageSeekBar>(
          find.byType(ReaderPageSeekBar),
        );
        return tester.getRect(find.byKey(widget.hitRegionKey!));
      }

      List<AnnotationStroke> ink() => store.snapshot.pages.values
          .expand((v) => v.where((s) => !s.isDeleted))
          .toList();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryReaderScreen(
              workspace: workspace,
              locate: (_) => target,
              initialTarget: target,
              loader: (t) async =>
                  LoadedScore(target: t, pageCount: 820, imageAspect: .75),
            ),
          ),
        );
        await _until(
          tester,
          () => find.byType(ReaderPageSeekBar).evaluate().isNotEmpty,
        );
        await _until(
          tester,
          () => find.byType(AnnotationCanvas).evaluate().isNotEmpty,
        );
        final first = region();
        final finger = await tester.startGesture(
          Offset(first.left + 10, first.center.dy),
          pointer: 31,
          kind: PointerDeviceKind.touch,
        );
        await finger.moveTo(Offset(first.right - 10, first.center.dy));
        await _until(tester, () => visible() == 820);
        expect(
          tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .map((w) => w.painter)
              .whereType<ReaderPageDotsPainter>()
              .single
              .dotCount,
          60,
        );
        expect(
          find.byType(AnnotationCanvas).evaluate().length,
          lessThanOrEqualTo(5),
        );
        await finger.up();
        await tester.pump(const Duration(milliseconds: 150));
        expect(visible(), 820);
        expect(ink(), isEmpty);
        final second = region();
        final mouse = await tester.startGesture(
          Offset(second.right - 10, second.center.dy),
          pointer: 32,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(second.center);
        await _until(tester, () => visible() == 411);
        await mouse.up();
        await tester.pump(const Duration(milliseconds: 150));
        expect(visible(), 411);
        expect(ink(), isEmpty);
        final transform = tester
            .widget<ReaderInput>(find.byType(ReaderInput))
            .transform!;
        expect(transform.value, Matrix4.identity());
        final bottom = region().center;
        final pen = await tester.startGesture(
          bottom,
          pointer: 33,
          kind: PointerDeviceKind.stylus,
        );
        await tester.pump();
        expect(find.byType(ReaderPageSeekBar), findsNothing);
        final drafts = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<AnnotationPainter>()
            .where((p) => p.draft.isNotEmpty);
        expect(
          drafts,
          isNotEmpty,
          reason: 'first stylus point passes through the dot touch area',
        );
        await pen.moveBy(const Offset(6, -12));
        await pen.up();
        await _until(
          tester,
          () =>
              !workspace.saving &&
              find.byType(ReaderPageSeekBar).evaluate().isNotEmpty,
        );
        final captured = PageKey(
          entryId: target.entryId,
          revisionId: target.revisionId,
          pageNumber: 411,
        );
        expect(store.snapshot.strokesFor(captured), hasLength(1));
        final third = region();
        final scrub = await tester.startGesture(
          third.center,
          pointer: 34,
          kind: PointerDeviceKind.touch,
        );
        await scrub.moveTo(Offset(third.right - 10, third.center.dy));
        // No frame has submitted this pending target. Actual pen-down cancels it.
        final writing = await tester.startGesture(
          const Offset(400, 500),
          pointer: 35,
          kind: PointerDeviceKind.stylus,
        );
        await tester.pump();
        expect(find.byType(ReaderPageSeekBar), findsNothing);
        await writing.moveBy(const Offset(15, 10));
        await writing.up();
        await scrub.cancel();
        await _until(
          tester,
          () =>
              !workspace.saving &&
              find.byType(ReaderPageSeekBar).evaluate().isNotEmpty,
        );
        expect(visible(), 411);
        expect(store.snapshot.strokesFor(captured), hasLength(2));
        expect(ink(), hasLength(2));
        expect(find.textContaining('%'), findsNothing);
        expect(find.byTooltip('恢复整页'), findsOneWidget);
        final oldRegion = region();
        await tester.tap(find.byTooltip('收起阅读工具'));
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.byType(ReaderPageSeekBar), findsNothing);
        await tester.tapAt(Offset(oldRegion.right - 10, oldRegion.center.dy));
        await _until(
          tester,
          () => store.readingPosition(target.key)?.pageNumber == 412,
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'SEEK_OVERLAY_082 touch_mouse_live=true no_unintended_ink=true first_bottom_pen_captured=true mid_scrub_pen_page=411 dots_bound=60 hidden_region_restores_navigation=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _until(tester, () => !workspace.saving);
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'standalone single page uses the same transparent dots and top zoom controls with no percent',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('seek-single-082-'),
      ))!;
      await writeSyntheticPaper(tester, '${dir.path}/synthetic.PNG');
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(initialPath: '${dir.path}/synthetic.PNG'),
          ),
        );
        await _until(
          tester,
          () => find.byType(ReaderPageSeekBar).evaluate().isNotEmpty,
        );
        final dots = tester.widget<ReaderPageSeekBar>(
          find.byType(ReaderPageSeekBar),
        );
        expect(dots.pageCount, 1);
        expect(dots.currentPage, 1);
        expect(find.byTooltip('恢复整页'), findsOneWidget);
        expect(find.textContaining('%'), findsNothing);
        await tester.drag(find.byType(ReaderPageSeekBar), const Offset(200, 0));
        await tester.pump();
        expect(
          tester
              .widget<ReaderPageSeekBar>(find.byType(ReaderPageSeekBar))
              .currentPage,
          1,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'same-frame cancel then down schedules latest; normal up then pedal then down retains accepted ended seek',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('seek-lifecycle-082-'),
      ))!;
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final workspace = ReaderWorkspace(store);
      final a = ScoreTarget(
        entryId: 'A',
        revisionId: 'r',
        filePath: 'A.png',
        displayPath: 'A.png',
      );
      final b = ScoreTarget(
        entryId: 'B',
        revisionId: 'r',
        filePath: 'B.png',
        displayPath: 'B.png',
      );
      final list = (await tester.runAsync(
        () => store.createSetList('synthetic'),
      ))!;
      final item = (await tester.runAsync(
        () => store.addItem(list.id, a.entryId),
      ))!;
      await tester.runAsync(() => store.addItem(list.id, b.entryId));
      final gate = Completer<void>();
      var loadingB = false;
      final session = ReaderSession(
        workspace: workspace,
        locate: (id) => id == 'A' ? a : b,
        setListId: list.id,
        deferPositionPersistence: true,
        loader: (target) async {
          if (target.entryId == 'B') {
            loadingB = true;
            await gate.future;
          }
          return LoadedScore(
            target: target,
            pageCount: target.entryId == 'A' ? 5 : 3,
          );
        },
      );
      await session.open(a, itemId: item.id);
      final accepted = <(int, Object)>[], cancelled = <Object>[];
      final region = GlobalKey();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPageSeekBar(
              currentPage: 1,
              pageCount: 5,
              hitRegionKey: region,
              onSeek: (page, gesture) {
                accepted.add((page, gesture));
                unawaited(session.seek(page, gesture: gesture));
              },
              onCancel: (gesture) {
                cancelled.add(gesture);
                session.cancelSeek(gesture);
              },
            ),
          ),
        );
        final rect = tester.getRect(find.byKey(region));
        final left = rect.center - const Offset(12, 0),
            right = rect.center + const Offset(12, 0);
        void down(int pointer, Offset point) =>
            tester.binding.handlePointerEvent(
              PointerDownEvent(
                pointer: pointer,
                position: point,
                kind: PointerDeviceKind.touch,
              ),
            );
        void move(int pointer, Offset point) =>
            tester.binding.handlePointerEvent(
              PointerMoveEvent(
                pointer: pointer,
                position: point,
                kind: PointerDeviceKind.touch,
              ),
            );
        void up(int pointer, Offset point) => tester.binding.handlePointerEvent(
          PointerUpEvent(
            pointer: pointer,
            position: point,
            kind: PointerDeviceKind.touch,
          ),
        );
        down(71, left);
        move(71, right);
        tester.binding.handlePointerEvent(
          const PointerCancelEvent(pointer: 71, kind: PointerDeviceKind.touch),
        );
        down(72, left);
        move(72, right);
        await tester.pump();
        expect(accepted.map((event) => event.$1), [5]);
        await _until(tester, () => session.page == 5);
        up(72, right);
        final ended = accepted.single.$2;
        final pedal = session.turn(NavigationDirection.forward);
        await _until(tester, () => loadingB);
        down(73, rect.center);
        up(73, rect.center);
        expect(accepted.map((event) => event.$1), [5, 3]);
        expect(cancelled, isNot(contains(same(ended))));
        gate.complete();
        await _until(
          tester,
          () => session.current?.target.entryId == 'B' && !session.loading,
        );
        await pedal;
        expect(
          session.page,
          1,
          reason: 'accepted seek to A last page precedes pedal crossing to B; late A scrub is stale',
        );
        expect(cancelled, hasLength(1));
        expect(tester.takeException(), isNull);
        debugPrint(
          'SEEK_LIFECYCLE_082 same_frame_cancel_new_scheduled=true ended_seek_not_cancelled=true pedal_crossed_to_B=true late_A_seek_stale=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
