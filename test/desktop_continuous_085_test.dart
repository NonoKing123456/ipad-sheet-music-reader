import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_continuous.dart';

void main() {
  testWidgets(
    '820-page continuous view joins two paper edges, bounds surfaces, rejects evicted ready callbacks and restores zoomed anchor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      final controller = ReaderContinuousController();
      final active = <int, Object>{}, ready = <int, VoidCallback>{};
      final presented = <int>[];
      var constructed = 0, nextCalls = 0, requested = 1, token = 0;
      StateSetter? update;
      Widget host({ReaderScrollAnchor? anchor}) => MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ReaderContinuousView(
              documentKey: 'synthetic',
              pageCount: 820,
              aspectFor: (_) => .75,
              controller: controller,
              requestedPage: requested,
              navigationToken: token,
              initialAnchor: anchor,
              onPresented: presented.add,
              onNext: () => nextCalls++,
              pageBuilder: (number, isActive, done, failed) => _PaperProbe(
                key: ValueKey('probe-$number'),
                number: number,
                onMount: (id) {
                  active[number] = id;
                  constructed++;
                },
                onDispose: (id) {
                  if (identical(active[number], id)) active.remove(number);
                },
                install: (callback) => ready[number] = callback,
                onReady: done,
              ),
            );
          },
        ),
      );
      Future<void> frames([int count = 5]) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      ScrollController vertical() => tester
          .widget<ListView>(find.byKey(const ValueKey('continuous-page-list')))
          .controller!;
      void seek(int page) {
        update!(() {
          requested = page;
          token++;
        });
      }

      Future<void> wheel(double delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: const Offset(400, 400),
            scrollDelta: Offset(0, delta),
          ),
        );
        await frames();
      }

      try {
        await tester.pumpWidget(host());
        await frames();
        expect(active.length, lessThanOrEqualTo(4));
        expect(constructed, lessThanOrEqualTo(4));
        final staleOne = ready[1]!;
        ready[1]!();
        await frames();
        expect(presented, [1]);
        seek(700);
        await frames();
        expect(active.length, lessThanOrEqualTo(4));
        staleOne();
        await frames();
        expect(presented, [
          1,
        ], reason: 'old ready cannot pull a newer scroll intent back');
        ready[700]!();
        await frames();
        expect(presented.last, 700);
        final staleSeven = ready[700]!;
        seek(1);
        await frames();
        ready[1]!();
        await frames();
        expect(presented.last, 1);
        seek(700);
        await frames();
        staleSeven();
        await frames();
        expect(
          presented.last,
          1,
          reason: 'an evicted page must become ready again',
        );
        ready[700]!();
        await frames();
        expect(presented.last, 700);
        await wheel(800);
        ready[701]!();
        await frames();
        final tail = tester.getRect(find.byKey(const ValueKey('probe-700')));
        final head = tester.getRect(find.byKey(const ValueKey('probe-701')));
        expect(tail.bottom, inExclusiveRange(0, 1080));
        expect(head.top, inExclusiveRange(0, 1080));
        expect(head.top - tail.bottom, closeTo(16, .01));
        expect(presented.last, 701);
        final beforeControlWheel = vertical().offset;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await wheel(-120);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(controller.scale, greaterThan(1));
        expect(controller.scale, lessThan(1.5));
        expect(vertical().offset, isNot(beforeControlWheel));
        controller.fit();
        await frames();
        controller.zoom(1.5);
        await frames();
        expect(controller.scale, 1.5);
        final anchor = controller.anchor!, offset = vertical().offset;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(host(anchor: anchor));
        await frames();
        expect(
          vertical().offset,
          closeTo(offset, .01),
          reason: 'temporary single-page editing can restore the same continuous anchor and zoom',
        );
        expect(controller.scale, 1.5);
        expect(active.length, lessThanOrEqualTo(4));
        vertical().jumpTo(vertical().position.maxScrollExtent);
        await frames();
        final end = vertical().offset;
        await wheel(10000);
        expect(vertical().offset, end);
        expect(nextCalls, 0);
        expect(
          constructed,
          lessThan(40),
          reason: '820 pages are geometry only, not 820 decoded surfaces',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _PaperProbe extends StatefulWidget {
  const _PaperProbe({
    super.key,
    required this.number,
    required this.onMount,
    required this.onDispose,
    required this.install,
    required this.onReady,
  });
  final int number;
  final ValueChanged<Object> onMount, onDispose;
  final ValueChanged<VoidCallback> install;
  final VoidCallback onReady;
  @override
  State<_PaperProbe> createState() => _PaperProbeState();
}

class _PaperProbeState extends State<_PaperProbe> {
  final _id = Object();
  @override
  void initState() {
    super.initState();
    widget.onMount(_id);
    widget.install(widget.onReady);
  }

  @override
  void dispose() {
    widget.onDispose(_id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.number.isEven ? Colors.lightBlue : Colors.amber,
    child: Center(child: Text('Synthetic page ${widget.number}')),
  );
}
