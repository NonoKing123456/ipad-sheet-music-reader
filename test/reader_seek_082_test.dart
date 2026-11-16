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
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/reader_tool_button.dart';
import 'package:score_reader/theme/device_layout.dart';

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
    'iPad dots live-seek with touch and mouse; pen keeps page ownership and hidden controls restore page gestures',
    (tester) async {
      const surface = Size(810, 1080);
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1;
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        return tester.binding.setSurfaceSize(null);
      });
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
      final layout = DeviceLayoutController(simulateIpad: true);
      var presented = false;
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
          DeviceLayoutScope(
            controller: layout,
            child: MaterialApp(
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: (_) => target,
                initialTarget: target,
                onPresented: (_) => presented = true,
                loader: (t) async =>
                    LoadedScore(target: t, pageCount: 820, imageAspect: .75),
              ),
            ),
          ),
        );
        await _until(
          tester,
          () =>
              presented && find.byType(AnnotationCanvas).evaluate().isNotEmpty,
        );
        await tester.tapAt(tester.getRect(find.byType(ReaderInput)).center);
        await tester.pumpAndSettle();
        expect(find.byTooltip('批注'), findsOneWidget);
        expect(find.byTooltip('完成批注'), findsNothing);
        await tester.tap(find.byTooltip('批注'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('完成批注'), findsOneWidget);
        final first = region();
        expect(
          first.bottom,
          lessThanOrEqualTo(surface.height),
          reason: 'expanded page dots must be on screen',
        );
        final finger = await tester.startGesture(
          Offset(first.left + 10, first.center.dy),
          pointer: 31,
          kind: PointerDeviceKind.touch,
        );
        await finger.moveTo(Offset(first.right - .001, first.center.dy));
        await _until(tester, () => visible() == 820);
        final seekBar = tester.widget<ReaderPageSeekBar>(
          find.byType(ReaderPageSeekBar),
        );
        final actualDotBound = readerSeekDotCount(
          820,
          tester.getSize(find.byKey(seekBar.hitRegionKey!)).width,
        );
        expect(actualDotBound, inInclusiveRange(1, 60));
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
        // Pen contact hides the page indicator. Starting within its transparent
        // hit area must still deliver the first stylus point to the paper.
        await tester.tap(find.byKey(const ValueKey(ReaderTool.pen)));
        await tester.pump();
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
        await _until(tester, () => !workspace.saving);
        final captured = PageKey(
          entryId: target.entryId,
          revisionId: target.revisionId,
          pageNumber: 411,
        );
        expect(store.snapshot.strokesFor(captured), hasLength(1));
        expect(store.readingPosition(target.key)?.pageNumber, 411);
        expect(ink(), hasLength(1));
        expect(find.textContaining('%'), findsNothing);
        await tester.tap(find.byTooltip('完成批注'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('批注'), findsOneWidget);
        // Completion exits annotation mode; the center tap hides reader controls.
        await tester.tapAt(tester.getRect(find.byType(ReaderInput)).center);
        await tester.pumpAndSettle();
        final input = tester.getRect(find.byType(ReaderInput));
        expect(
          find.byType(ReaderPageSeekBar),
          findsNothing,
          reason:
              'quiet mode removes navigation until tools are opened (7f163cf)',
        );
        await tester.tapAt(Offset(input.right - 10, input.center.dy));
        await _until(
          tester,
          () => store.readingPosition(target.key)?.pageNumber == 412,
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'SEEK_OVERLAY_082 touch_mouse_live=true no_unintended_ink=true first_bottom_pen_captured=true annotation_page=411 dots_bound=$actualDotBound hidden_tools_restore_right_page_gesture=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _until(tester, () => !workspace.saving);
        workspace.dispose();
        layout.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('simulated iPad single page keeps its page indicator inert', (
    tester,
  ) async {
    const surface = Size(810, 1080);
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(surface);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('seek-single-082-'),
    ))!;
    await writeSyntheticPaper(tester, '${dir.path}/synthetic.PNG');
    final store = (await tester.runAsync(
      () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
    ))!;
    final workspace = ReaderWorkspace(store);
    final target = ScoreTarget(
      entryId: 'single-seek',
      revisionId: 'r1',
      filePath: '${dir.path}/synthetic.PNG',
      displayPath: 'synthetic.PNG',
    );
    final layout = DeviceLayoutController(simulateIpad: true);
    var presented = false;
    try {
      await tester.pumpWidget(
        DeviceLayoutScope(
          controller: layout,
          child: MaterialApp(
            home: LibraryReaderScreen(
              workspace: workspace,
              locate: (_) => target,
              initialTarget: target,
              onPresented: (_) => presented = true,
              loader: (t) async =>
                  LoadedScore(target: t, pageCount: 1, imageAspect: .75),
            ),
          ),
        ),
      );
      await _until(tester, () => presented);
      await tester.tapAt(tester.getRect(find.byType(ReaderInput)).center);
      await tester.pumpAndSettle();
      expect(find.byTooltip('批注'), findsOneWidget);
      expect(find.byTooltip('完成批注'), findsNothing);
      await tester.tap(find.byTooltip('批注'));
      await tester.pumpAndSettle();
      final dots = tester.widget<ReaderPageSeekBar>(
        find.byType(ReaderPageSeekBar),
      );
      expect(dots.pageCount, 1);
      expect(dots.currentPage, 1);
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
      while (workspace.saving) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      workspace.dispose();
      layout.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.binding.setSurfaceSize(null);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
        // Use the ends of the seek region so this test genuinely requests
        // page 1 -> page 5. A 24px wiggle around the midpoint only maps to an
        // interior page and made the lifecycle assertion depend on an
        // impossible endpoint request.
        final left = rect.centerLeft + const Offset(10, 0),
            right = rect.centerRight - const Offset(10, 0);
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
        // Live callbacks are synchronous. The first gesture was accepted then
        // cancelled before the session drained; only the second may navigate.
        expect(accepted.map((event) => event.$1), [5, 5]);
        expect(cancelled, contains(same(accepted.first.$2)));
        await _until(tester, () => session.page == 5);
        up(72, right);
        final ended = accepted.last.$2;
        final pedal = session.turn(NavigationDirection.forward);
        await _until(tester, () => loadingB);
        down(73, rect.center);
        up(73, rect.center);
        expect(accepted.map((event) => event.$1), [5, 5, 3]);
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
