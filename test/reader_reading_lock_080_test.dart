import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_input.dart';

void main() {
  testWidgets(
    'reading fit stays centered; zoom allows bounded single and two finger pan, pinch back to fit and fast turns survive',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final size in [const Size(810, 1080), const Size(1080, 810)]) {
        await tester.binding.setSurfaceSize(size);
        final transform = TransformationController();
        var turns = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderInput(
              transform: transform,
              pageAspect: .8,
              panInsets: const EdgeInsets.only(top: 140, bottom: 100),
              onPrevious: () => turns--,
              onNext: () => turns++,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        );
        final fitted = applyBoxFit(
          BoxFit.contain,
          const Size(.8, 1),
          size,
        ).destination;
        final paper = Alignment.center.inscribe(fitted, Offset.zero & size);
        void bounded() {
          final m = transform.value;
          final shown = MatrixUtils.transformRect(m, paper);
          expect(shown.top, lessThanOrEqualTo(.001));
          expect(shown.bottom, greaterThanOrEqualTo(size.height - .001));
          expect(shown.left, lessThanOrEqualTo(.001));
          expect(shown.right, greaterThanOrEqualTo(size.width - .001));
        }

        Future<void> single(int id, Offset delta) async {
          final finger = await tester.startGesture(
            size.center(Offset.zero),
            pointer: id,
          );
          await finger.moveBy(delta);
          await finger.up();
          await tester.pump();
        }

        Future<void> parallel(int id, Offset delta) async {
          final a = await tester.startGesture(
            size.center(Offset.zero) - const Offset(60, 0),
            pointer: id,
          );
          final b = await tester.startGesture(
            size.center(Offset.zero) + const Offset(60, 0),
            pointer: id + 1,
          );
          await a.moveBy(delta);
          await b.moveBy(delta);
          await a.up();
          await b.up();
          await tester.pump();
        }

        await single(10, const Offset(0, 250));
        expect(transform.value, Matrix4.identity());
        await parallel(20, const Offset(0, 180));
        expect(transform.value, Matrix4.identity());

        void zoomed() =>
            transform.value = Matrix4.diagonal3Values(2, 2, 1)
              ..setTranslationRaw(-size.width / 2, -size.height / 2, 0);
        zoomed();
        final before = transform.value.storage[13];
        await single(30, const Offset(0, 100));
        expect(transform.value.storage[13], greaterThan(before));
        bounded();
        await single(31, const Offset(5000, 5000));
        bounded();
        expect(transform.value.storage[13] + paper.top * 2, closeTo(0, .001));
        await single(32, const Offset(-5000, -5000));
        bounded();
        expect(
          transform.value.storage[13] + paper.bottom * 2,
          closeTo(size.height, .001),
        );
        zoomed();
        await parallel(40, const Offset(0, 150));
        expect(transform.value.getMaxScaleOnAxis(), closeTo(2, .001));
        expect(transform.value.storage[13], greaterThan(before));
        bounded();
        expect(turns, 0);

        transform.value = Matrix4.identity();
        final a = await tester.startGesture(
          const Offset(100, 220),
          pointer: 50,
        );
        final b = await tester.startGesture(
          const Offset(200, 220),
          pointer: 51,
        );
        await a.moveBy(const Offset(-40, 40));
        await b.moveBy(const Offset(40, 40));
        expect(transform.value.getMaxScaleOnAxis(), closeTo(1.8, .001));
        bounded();
        await a.moveTo(const Offset(100, 220));
        await b.moveTo(const Offset(200, 220));
        expect(transform.value, Matrix4.identity());
        await a.up();
        await b.up();
        await single(60, const Offset(-120, 0));
        expect(turns, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump(const Duration(milliseconds: 90));
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        expect(turns, 2);
        await tester.pumpWidget(const SizedBox());
        transform.dispose();
      }
    },
  );
}
