import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_input.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required VoidCallback previous,
    required VoidCallback next,
    Widget? child,
    VoidCallback? center,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderInput(
            onPrevious: previous,
            onNext: next,
            onCenterTap: center,
            child: child ?? const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('held pedal turns once; release and press turns again', (
    tester,
  ) async {
    var page = 2;
    await mount(tester, previous: () => page--, next: () => page++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
    expect(page, 3);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
    expect(page, 3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(page, 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    expect(page, 3);
  });

  testWidgets(
    'central tap toggles tools once and pinch never toggles or turns',
    (tester) async {
      var tools = 0, turns = 0;
      await mount(
        tester,
        previous: () => turns++,
        next: () => turns++,
        center: () => tools++,
      );
      await tester.tapAt(const Offset(400, 300));
      expect(tools, 1);
      expect(turns, 0);
      final one = await tester.startGesture(const Offset(250, 300), pointer: 1);
      final two = await tester.startGesture(const Offset(550, 300), pointer: 2);
      await one.moveBy(const Offset(-80, 0));
      await two.moveBy(const Offset(80, 0));
      await one.up();
      await two.up();
      expect(tools, 1);
      expect(turns, 0);
    },
  );

  testWidgets('two complete fast presses both count', (tester) async {
    var turns = 0;
    await mount(tester, previous: () {}, next: () => turns++);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(turns, 2);
  });

  testWidgets('left and right taps work; a swipe produces only one turn', (
    tester,
  ) async {
    var page = 3;
    await mount(tester, previous: () => page--, next: () => page++);
    await tester.tapAt(const Offset(60, 300));
    expect(page, 2);
    await tester.tapAt(const Offset(740, 300));
    expect(page, 3);
    await tester.dragFrom(const Offset(600, 300), const Offset(-300, 0));
    expect(page, 4);
    await tester.dragFrom(const Offset(200, 300), const Offset(300, 0));
    expect(page, 3);
    await tester.tapAt(const Offset(400, 300));
    expect(page, 3);
  });

  testWidgets('vertical drag and multi-touch do not turn pages', (
    tester,
  ) async {
    var turns = 0;
    await mount(tester, previous: () => turns++, next: () => turns++);
    await tester.dragFrom(const Offset(500, 200), const Offset(0, 200));
    expect(turns, 0);
    final first = await tester.startGesture(const Offset(200, 250), pointer: 1);
    final second = await tester.startGesture(
      const Offset(500, 250),
      pointer: 2,
    );
    await first.moveBy(const Offset(-100, 0));
    await second.moveBy(const Offset(100, 0));
    await first.up();
    await second.up();
    expect(turns, 0);
  });

  testWidgets('focused text editing does not receive reading actions', (
    tester,
  ) async {
    var turns = 0;
    await mount(
      tester,
      previous: () => turns++,
      next: () => turns++,
      child: const Column(
        children: [
          TextField(),
          Expanded(child: SizedBox.expand()),
        ],
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '谱名');
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '谱名',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    expect(turns, 0);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '谱名',
    );
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(turns, 1);
  });

  testWidgets('modified page keys are left to the platform', (tester) async {
    var turns = 0;
    await mount(tester, previous: () => turns++, next: () => turns++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(turns, 0);
  });
}
