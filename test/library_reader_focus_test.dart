import 'package:score_reader/reader/reader_tool_button.dart';

import 'reader_fixture.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';

void main() {
  Future<void> mountReader(WidgetTester tester) async {
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('reader-focus-'),
    ))!;
    final workspace = (await tester.runAsync(() async {
      final store = await ReaderStateStore.open(
        statePath: p.join(temporary.path, 'state.json'),
      );
      return ReaderWorkspace(store);
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        for (var i = 0; workspace.saving && i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        workspace.dispose();
        await temporary.delete(recursive: true);
      });
    });
    await writeSyntheticPaper(tester, p.join(temporary.path, 'fake.png'));
    final target = ScoreTarget(
      entryId: 'e',
      revisionId: 'r',
      filePath: p.join(temporary.path, 'fake.png'),
      displayPath: 'focus-test/fake.png',
    );
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(
          home: LibraryReaderScreen(
            workspace: workspace,
            locate: (_) => target,
            initialTarget: target,
            // Page metadata is synthetic; rendering is not part of this focus test.
            loader: (target) async =>
                LoadedScore(target: target, pageCount: 4, imageAspect: .75),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await settleReader(tester);
    expect(find.text('1 / 4'), findsOneWidget);
  }

  Future<void> mouseClick(WidgetTester tester, Finder control) async {
    await tester.tap(control, kind: PointerDeviceKind.mouse);
    await tester.pump();
    debugPrint(
      'FOCUS_REGRESSION mouse primary=${FocusManager.instance.primaryFocus?.debugLabel}',
    );
  }

  Future<void> pageKey(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.runAsync(() async {
      await tester.sendKeyEvent(key);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await settleReader(tester);
  }

  testWidgets(
    'mouse zoom keeps pedal active without touching paper and ignores held repeats',
    (tester) async {
      await mountReader(tester);
      await mouseClick(tester, find.byTooltip('放大'));
      expect(find.text('125%'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await settleReader(tester);
      expect(find.text('2 / 4'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'annotation tool and color mouse clicks retain pedal navigation',
    (tester) async {
      await mountReader(tester);
      await mouseClick(
        tester,
        find.byKey(const ValueKey(ReaderTool.highlighter)),
      );
      await pageKey(tester, LogicalKeyboardKey.pageDown);
      expect(find.text('2 / 4'), findsOneWidget);
      await mouseClick(tester, find.byTooltip('蓝色'));
      await pageKey(tester, LogicalKeyboardKey.pageDown);
      expect(find.text('3 / 4'), findsOneWidget);
      await mouseClick(tester, find.byTooltip('放大'));
      await pageKey(tester, LogicalKeyboardKey.pageDown);
      expect(find.text('4 / 4'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'modal text editing and modal buttons keep page keys away from the reader',
    (tester) async {
      await mountReader(tester);
      final context = tester.element(find.byType(LibraryReaderScreen));
      final text = TextEditingController(text: '谱名');
      addTearDown(text.dispose);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('焦点检查'),
            content: TextField(controller: text, autofocus: true),
            actions: [TextButton(onPressed: () {}, child: const Text('弹窗操作'))],
          ),
        ),
      );
      // The metadata-only fake score may leave a background image spinner;
      // settle only the modal transition, rather than unrelated page rendering.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(text.text, '谱名');
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(find.text('1 / 4'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '谱名',
      );
      await mouseClick(tester, find.text('弹窗操作'));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(find.text('1 / 4'), findsOneWidget);
      expect(find.text('焦点检查'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
