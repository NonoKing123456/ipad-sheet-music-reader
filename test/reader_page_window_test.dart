import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_page_window.dart';

void main() {
  testWidgets(
    '820-page document mounts at most three pages, retains neighbours and isolates revisions',
    (tester) async {
      var serial = 0;
      final instances = <int, int>{};
      Future<void> show(int page, {String revision = 'r1'}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 600,
              height: 700,
              child: ReaderPageWindow(
                key: ValueKey(revision),
                pageNumber: page,
                pageCount: 820,
                aspectFor: (number) => number.isEven ? .5 : 1.5,
                pageBuilder: (number) =>
                    _Probe(number, () => ++serial, instances),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(1);
      expect(instances.keys.toSet(), {1, 2});
      final secondInstance = instances[2];
      await show(2);
      expect(instances.keys.toSet(), {1, 2, 3});
      expect(instances[2], secondInstance);
      final active = find.text('page 2').hitTestable();
      expect(active, findsOneWidget);
      final size = tester.getSize(active);
      expect(size.width / size.height, closeTo(.5, .001));
      await show(819);
      expect(instances.keys.toSet(), {818, 819, 820});
      await show(820);
      expect(instances.keys.toSet(), {819, 820});
      final oldLast = instances[820];
      await show(820, revision: 'r2');
      expect(instances.keys.toSet(), {819, 820});
      expect(instances[820], isNot(oldLast));
      expect(find.byType(IndexedStack), findsNothing);
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe(this.number, this.nextSerial, this.instances);
  final int number;
  final int Function() nextSerial;
  final Map<int, int> instances;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late final int serial;
  @override
  void initState() {
    super.initState();
    serial = widget.nextSerial();
    widget.instances[widget.number] = serial;
  }

  @override
  void dispose() {
    if (widget.instances[widget.number] == serial) {
      widget.instances.remove(widget.number);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox.expand(child: Text('page ${widget.number}'));
}
