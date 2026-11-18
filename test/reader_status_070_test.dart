import 'package:score_reader/reader/sharp_file_image.dart';
import 'package:score_reader/reader/reader_input.dart';

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_page_window.dart';
import 'package:score_reader/reader/reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';

import 'reader_color_070_test.dart' show setup, mount, until, flush, canvasPage;
import 'support/score_fixture.dart' show syntheticPdf;

// Painting is independent of annotation hit testing: v2 disables idle ink.
Finder _readablePaper() => find.byElementPredicate((element) {
  final widget = element.widget;
  if (widget is! SharpFileImage || !widget.active) return false;
  var visible = true;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget case Opacity(opacity: 0)) visible = false;
    if (ancestor.widget case Offstage(offstage: true)) visible = false;
    return visible;
  });
  return visible;
});

void main() {
  testWidgets(
    '31 unreadable neighbours identify the target and retry opens the last page of the previous score',
    (tester) async {
      final (dir, workspace, _) = await setup(tester);
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(provider, (_) async => dir.path);
      final targets = <String, ScoreTarget>{};
      final presented = <PageKey>[];
      final previousPdf = syntheticPdf(3);
      try {
        final list = (await tester.runAsync(() async {
          final list = await workspace.store.createSetList('合成曲单');
          for (final name in ['A', 'B', 'C']) {
            final bytes = name == 'A' ? previousPdf : syntheticPdf(1);
            final file = File('${dir.path}/$name.pdf');
            await file.writeAsBytes(name == 'B' ? bytes : [0]);
            targets[name] = ScoreTarget(
              entryId: name,
              revisionId: 'r1',
              filePath: file.path,
              displayPath: '排练/$name.pdf',
              contentHash: sha256.convert(bytes).toString(),
            );
            await workspace.store.addItem(list.id, name);
          }
          return workspace.store.snapshot.setListById(list.id)!;
        }))!;
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryReaderScreen(
              workspace: workspace,
              initialTarget: targets['B']!,
              locate: (id) => targets[id],
              setListId: list.id,
              itemId: list.activeItems[1].id,
              onPresented: presented.add,
            ),
          ),
        );
        await until(tester, () => presented.isNotEmpty);
        final start = presented.last;
        expect(start.entryId, 'B');
        expect(start.pageNumber, 1);
        Future<void> checkFailure(
          LogicalKeyboardKey key,
          String direction,
          String name,
        ) async {
          await tester.sendKeyEvent(key);
          final status = find.byTooltip('阅读状态');
          await until(tester, () => status.evaluate().isNotEmpty);
          if (status.hitTestable().evaluate().isEmpty) {
            await tester.tapAt(tester.getCenter(find.byType(ReaderInput)));
            await tester.pump(const Duration(milliseconds: 240));
          }
          await tester.tap(status.hitTestable());
          await tester.pumpAndSettle();
          final message = find.textContaining('${direction}一份曲谱暂时无法读取');
          expect(message, findsOneWidget);
          expect(tester.widget<Text>(message).data, contains('《$name》'));
          expect(presented.last, start);
        }

        await checkFailure(LogicalKeyboardKey.pageDown, '下', 'C');
        await tester.tap(find.byTooltip('关闭状态详情'));
        await tester.pumpAndSettle();
        await checkFailure(LogicalKeyboardKey.pageUp, '上', 'A');
        await tester.runAsync(
          () => File(targets['A']!.filePath).writeAsBytes(previousPdf),
        );
        await tester.tap(find.text('重试翻页'));
        await until(tester, () => presented.last.entryId == 'A');
        expect(presented.last.pageNumber, 3);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        messenger.setMockMethodCallHandler(provider, null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'real reader repeated boundary pedals stay silent; selected pen inks on the right page and failed save remains discoverable and retryable',
    (tester) async {
      final (dir, workspace, target) = await setup(tester);
      final state = File(workspace.store.statePath);
      final saved = File('${state.path}.hold');
      var blocked = false;
      try {
        await mount(tester, workspace, target);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        }
        await tester.pump();
        expect(find.textContaining('已经'), findsNothing);
        expect(find.byTooltip('阅读状态'), findsNothing);
        await flush(tester, workspace);
        if (find.byTooltip('批注').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(tester.getCenter(find.byType(ReaderInput)));
          await tester.pump(const Duration(milliseconds: 240));
        }
        await tester.tap(find.byTooltip('批注').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('画笔'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await state.rename(saved.path);
          await Directory(state.path).create();
          blocked = true;
        });
        final canvas = tester.renderObject<RenderBox>(canvasPage(2));
        final start = canvas.localToGlobal(canvas.size.center(Offset.zero));
        final pen = await tester.startGesture(
          start,
          kind: PointerDeviceKind.stylus,
        );
        await pen.moveBy(const Offset(45, 8));
        await pen.up();
        await until(tester, () => workspace.unsavedCount == 1);
        expect(find.textContaining('保存失败'), findsNothing);
        expect(find.byTooltip('1 项未保存').hitTestable(), findsOneWidget);
        expect(workspace.pending.single.page.pageNumber, 2);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        }
        await tester.pump();
        expect(find.textContaining('已经'), findsNothing);
        await tester.tap(find.byTooltip('1 项未保存'));
        await tester.pumpAndSettle();
        expect(find.textContaining('保存失败'), findsOneWidget);
        expect(find.text('重试保存'), findsOneWidget);
        await tester.runAsync(() async {
          await Directory(state.path).delete();
          await saved.rename(state.path);
          blocked = false;
        });
        await tester.tap(find.text('重试保存'));
        await until(
          tester,
          () => workspace.unsavedCount == 0 && !workspace.saving,
        );
        expect(workspace.error, isNull);
        expect(
          workspace.store.snapshot.strokesFor(
            PageKey(entryId: 'e', revisionId: 'r', pageNumber: 2),
          ),
          hasLength(1),
        );
        await tester.tap(find.byTooltip('关闭状态详情'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('1 笔未保存'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() async {
          if (blocked) await Directory(state.path).delete();
          await dir.delete(recursive: true);
        });
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'real reader load errors keep readable paper unobstructed and expose retry; first open failure stays explicit',
    (tester) async {
      final (dir, workspace, a) = await setup(tester);
      final list = (await tester.runAsync(
        () => workspace.store.createSetList('s'),
      ))!;
      final item = (await tester.runAsync(
        () => workspace.store.addItem(list.id, 'e'),
      ))!;
      await tester.runAsync(() => workspace.store.addItem(list.id, 'b'));
      final b = ScoreTarget(
        entryId: 'b',
        revisionId: 'r',
        filePath: a.filePath,
        displayPath: 'B.png',
      );
      var failB = true;
      Future<void> show({bool failFirst = false}) async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: LibraryReaderScreen(
                key: ValueKey(failFirst),
                workspace: workspace,
                initialTarget: a,
                locate: (id) => id == 'b' ? b : a,
                setListId: list.id,
                itemId: item.id,
                loader: (target) async {
                  if (failFirst || (target.entryId == 'b' && failB)) {
                    throw StateError('fixture unavailable');
                  }
                  return LoadedScore(
                    target: target,
                    pageCount: 1,
                    imageAspect: .8,
                  );
                },
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pump();
      }

      try {
        await show();
        await until(tester, () => _readablePaper().evaluate().isNotEmpty);
        await until(
          tester,
          () => workspace.store.readingPosition(a.key)?.pageNumber == 1,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        await until(tester, () => find.byTooltip('阅读状态').evaluate().isNotEmpty);
        expect(find.textContaining('下一份曲谱暂时无法读取'), findsNothing);
        expect(_readablePaper(), findsOneWidget);
        expect(tester.getSize(_readablePaper()).isEmpty, isFalse);
        expect(
          find.descendant(
            of: _readablePaper(),
            matching: find.byWidgetPredicate(
              (w) => w is RawImage && w.image != null,
            ),
          ),
          findsOneWidget,
        );
        await tester.tapAt(tester.getCenter(find.byType(ReaderInput)));
        await tester.pump(const Duration(milliseconds: 240));
        await tester.tap(find.byTooltip('阅读状态'));
        await tester.pumpAndSettle();
        expect(find.textContaining('下一份曲谱暂时无法读取'), findsOneWidget);
        failB = false;
        expect(
          find.text('重试翻页'),
          findsOneWidget,
          reason: 'load failure must retain an explicit retry action',
        );
        await tester.tap(find.text('重试翻页'));
        await until(tester, () => find.text('B').evaluate().isNotEmpty);
        await tester.tap(find.byTooltip('关闭状态详情'));
        await tester.pumpAndSettle();
        await show(failFirst: true);
        expect(find.textContaining('无法读取这份曲谱'), findsOneWidget);
        expect(find.text('重新打开'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'render error with old page uses reopenable compact entry; first render failure is explicit',
    (tester) async {
      var page = 1;
      final ready = <int, VoidCallback>{};
      final fail = <int, ValueChanged<String?>>{};
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPageWindow(
              pageNumber: page,
              pageCount: 2,
              aspectFor: (_) => .8,
              readyPageBuilder: (n, active, onReady, onError) {
                ready[n] = onReady;
                fail[n] = onError;
                return Text('paper$n');
              },
            ),
          ),
        ),
      );
      await show();
      fail[1]!('first unreadable');
      await tester.pump();
      await tester.pump();
      expect(find.text('first unreadable'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      ready[1]!();
      await tester.pump();
      await tester.pump();
      page = 2;
      await show();
      fail[2]!('next unreadable');
      await tester.pump();
      await tester.pump();
      expect(find.text('next unreadable'), findsNothing);
      expect(find.text('paper1').hitTestable(), findsOneWidget);
      final status = find.byTooltip('页面加载失败 · 查看并重试');
      expect(tester.getSize(status).width, lessThanOrEqualTo(48));
      await tester.tap(status);
      await tester.pumpAndSettle();
      expect(find.text('next unreadable'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭状态详情'));
      await tester.pumpAndSettle();
      await tester.tap(status);
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pump();
      ready[2]!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      await tester.tap(find.byTooltip('关闭状态详情'));
      await tester.pumpAndSettle();
      expect(status, findsNothing);
    },
  );

  testWidgets('standalone bitmap reader quietly ignores both boundaries', (
    tester,
  ) async {
    final (dir, workspace, target) = await setup(tester);
    try {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: ReaderScreen(initialPath: target.filePath)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      }
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('已经'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
