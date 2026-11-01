import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_page_window.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/paper_color_sampler.dart';
import 'package:score_reader/reader/sharp_file_image.dart';

import 'reader_fixture.dart';

void main() {
  testWidgets(
    'ready page first visible within one 16ms frame, same-direction retarget ends within 100ms and reversal is continuous',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final origin = tester.binding.clock.now();
      Duration now() => tester.binding.clock.now().difference(origin);
      var page = 1;
      Duration? requested;
      final ready = <int, VoidCallback>{};
      final shown = <int>[];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: ReaderPageWindow(
            documentKey: 'score',
            pageNumber: page,
            pageCount: 5,
            requestedAt: requested,
            presentationClock: now,
            aspectFor: (_) => 1,
            onPresented: (_, n) => shown.add(n),
            readyPageBuilder: (n, active, onReady, failed) {
              ready[n] = onReady;
              return ColoredBox(
                key: ValueKey('paper$n'),
                color: n.isEven ? Colors.blue : Colors.red,
                child: Text('ink$n'),
              );
            },
          ),
        ),
      );
      await show();
      ready[1]!();
      ready[2]!();
      await tester.pump();
      await tester.pump();
      expect(shown, [1]);
      final start = now();
      requested = now();
      page = 2;
      await tester.pump(const Duration(milliseconds: 16));
      await show();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('paper2'))).dx,
        lessThan(800),
      );
      expect(now() - start, const Duration(milliseconds: 16));
      expect(shown, [1]);
      ready[3]!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final x = tester.getCenter(find.byKey(const ValueKey('paper2'))).dx;
      requested = now();
      page = 3;
      await show();
      expect(
        tester.getCenter(find.byKey(const ValueKey('paper3'))).dx,
        closeTo(x, .001),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump();
      debugPrint(
        'SPEED_FRAME_RESULT first_visible_ms=16 complete_ms=${(now() - start).inMilliseconds}',
      );
      expect(shown, [1, 3]);
      expect(now() - start, const Duration(milliseconds: 96));
      requested = now();
      page = 2;
      await show();
      await tester.pump(const Duration(milliseconds: 30));
      final before = tester.getCenter(find.byKey(const ValueKey('paper3'))).dx;
      requested = now();
      page = 3;
      await show();
      expect(
        tester.getCenter(find.byKey(const ValueKey('paper3'))).dx,
        closeTo(before, .001),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      expect(
        tester.getCenter(find.byKey(const ValueKey('paper3'))).dx,
        closeTo(400, .001),
      );
      expect(shown, [
        1,
        3,
      ], reason: 'uncompleted incoming page is never bookmarked');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'last ready page prewarms only next score and reuses its actual first-page renderer before opening the following score',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('next-prewarm-'),
      ))!;
      final workspace = (await tester.runAsync(
        () async => ReaderWorkspace(
          await ReaderStateStore.open(statePath: '${dir.path}/s.json'),
        ),
      ))!;
      for (final name in ['A', 'B', 'C']) {
        await writeSyntheticPaper(tester, '${dir.path}/$name.png');
      }
      late ScoreSetList list;
      late SetListItem first;
      await tester.runAsync(() async {
        list = await workspace.store.createSetList('synthetic');
        first = await workspace.store.addItem(list.id, 'A');
        await workspace.store.addItem(list.id, 'B');
        await workspace.store.addItem(list.id, 'C');
      });
      ScoreTarget target(String id) => ScoreTarget(
        entryId: id,
        revisionId: 'r',
        filePath: '${dir.path}/$id.png',
        displayPath: '$id.png',
      );
      final clockStart = tester.binding.clock.now();
      final loads = <String, int>{};
      final sampler = PaperColorSampler();
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: target,
                initialTarget: target('A'),
                setListId: list.id,
                itemId: first.id,
                colorSampler: sampler,
                presentationClock: () =>
                    tester.binding.clock.now().difference(clockStart),
                loader: (t) async {
                  loads[t.entryId] = (loads[t.entryId] ?? 0) + 1;
                  return LoadedScore(target: t, pageCount: 1, imageAspect: .75);
                },
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        Finder image(String id) => find.byWidgetPredicate(
          (w) => w is SharpFileImage && w.path == target(id).filePath,
        );
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 6)),
          );
          if (image('B').evaluate().isNotEmpty &&
              find
                  .descendant(of: image('B'), matching: find.byType(RawImage))
                  .evaluate()
                  .isNotEmpty) {
            break;
          }
        }
        expect(loads, {'A': 1, 'B': 1});
        expect(image('C'), findsNothing);
        final warmed = image('B').evaluate().single;
        expect(workspace.store.readingPosition(target('B').key), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump(const Duration(milliseconds: 16));
        expect(identical(image('B').evaluate().single, warmed), isTrue);
        expect(
          tester.getTopLeft(image('B')).dx,
          lessThan(810),
          reason:
              'prewarmed target is actually visible in the first 16ms frame',
        );
        await tester.pump(const Duration(milliseconds: 100));
        await settleReader(tester);
        expect(loads['B'], 1);
        expect(loads['C'], 1);
        expect(sampler.sourceCount, lessThanOrEqualTo(4));
        expect(find.text('B.png'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 100 && workspace.saving; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  test('adopted prewarm does not restart an obsolete foreground load; cached prewarm validates access', () async {
    final dir = await Directory.systemTemp.createTemp('prewarm-adopt-');
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${dir.path}/s.json'),
    );
    final list = await workspace.store.createSetList('s');
    final first = await workspace.store.addItem(list.id, 'A');
    await workspace.store.addItem(list.id, 'B');
    var allowed = true, checks = 0, loads = 0;
    ScoreTarget target(String id) => ScoreTarget(
      entryId: id,
      revisionId: 'r',
      filePath: 'synthetic',
      displayPath: id,
      validateBeforeRead: id != 'B'
          ? null
          : () async {
              checks++;
              if (!allowed) throw StateError('revoked');
            },
    );
    final gate = Completer<void>(), started = Completer<void>();
    final session = ReaderSession(
      workspace: workspace,
      locate: target,
      setListId: list.id,
      loader: (t) async {
        if (t.entryId == 'B') {
          loads++;
          if (loads == 1) {
            started.complete();
            await gate.future;
          }
        }
        return LoadedScore(target: t, pageCount: 1);
      },
    );
    try {
      await session.open(target('A'), itemId: first.id, restore: false);
      final warm = session.prewarmNext();
      await started.future;
      final turn = session.turn(NavigationDirection.forward);
      await session.open(target('X'), restore: false);
      gate.complete();
      await warm;
      await turn;
      expect(loads, 1);
      expect(session.current!.target.entryId, 'X');
      await session.open(target('A'), itemId: first.id, restore: false);
      expect(await session.prewarmNext(), isNotNull);
      allowed = false;
      expect(await session.prewarmNext(), isNull);
      expect(checks, 1);
      expect(session.message, isNull);
      for (var i = 0; i < 4; i++) {
        await session.turn(NavigationDirection.backward);
      }
      expect(session.page, 1);
      expect(session.message, isNull);
    } finally {
      session.dispose();
      await workspace.flushPositions();
      workspace.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('obsolete next-score load is discarded and prewarm failure never reports an early playing error', () async {
    final dir = await Directory.systemTemp.createTemp('prewarm-cancel-');
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${dir.path}/s.json'),
    );
    final list = await workspace.store.createSetList('s');
    final first = await workspace.store.addItem(list.id, 'A');
    await workspace.store.addItem(list.id, 'B');
    ScoreTarget target(String id) => ScoreTarget(
      entryId: id,
      revisionId: 'r',
      filePath: 'synthetic',
      displayPath: id,
    );
    final gate = Completer<void>(), started = Completer<void>();
    var disposed = 0, loads = 0;
    var fail = false;
    final session = ReaderSession(
      workspace: workspace,
      locate: target,
      setListId: list.id,
      loader: (target) async {
        if (target.entryId == 'B') {
          loads++;
          if (loads == 1) {
            started.complete();
            await gate.future;
          }
          if (fail) throw StateError('background unavailable');
        }
        return _TrackedScore(
          target: target,
          pageCount: target.entryId == 'A' ? 2 : 1,
          onDispose: () => disposed++,
        );
      },
    );
    try {
      await session.open(
        target('A'),
        itemId: first.id,
        pageNumber: 2,
        restore: false,
      );
      final warm = session.prewarmNext();
      await started.future;
      expect(session.loading, isFalse);
      expect(session.message, isNull);
      await session.turn(NavigationDirection.backward);
      gate.complete();
      expect(await warm, isNull);
      expect(disposed, 1);
      expect(session.cachedDocumentCount, 1);
      await session.turn(NavigationDirection.forward);
      fail = true;
      expect(await session.prewarmNext(), isNull);
      expect(session.message, isNull);
      expect(session.loading, isFalse);
      expect(session.cachedDocumentCount, 1);
      fail = false;
      await session.turn(NavigationDirection.forward);
      expect(session.position!.entryId, 'B');
      expect(loads, 3);
      expect(session.cachedDocumentCount, lessThanOrEqualTo(3));
    } finally {
      session.dispose();
      await workspace.flushPositions();
      workspace.dispose();
      await dir.delete(recursive: true);
    }
  });
}

class _TrackedScore extends LoadedScore {
  _TrackedScore({
    required super.target,
    required super.pageCount,
    required this.onDispose,
  });
  final VoidCallback onDispose;
  @override
  Future<void> dispose() async {
    onDispose();
    await super.dispose();
  }
}
