import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/sharp_file_image.dart';

import 'reader_fixture.dart';

Future<void> until082(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue, reason: 'bounded decode operation completes');
  await tester.pump();
}

class _DecodeCall {
  _DecodeCall(this.name, this.target);
  final String name;
  final Size target;
  final done = Completer<void>();
}

class _SlowDecode {
  final calls = <_DecodeCall>[];
  var active = 0, peak = 0;
  Future<ui.Image> call(
    String name,
    ui.ImageDescriptor descriptor,
    Size target,
  ) async {
    active++;
    if (active > peak) peak = active;
    final call = _DecodeCall(name, target);
    calls.add(call);
    await call.done.future;
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec(
        targetWidth: target.width.toInt(),
        targetHeight: target.height.toInt(),
      );
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      active--;
    }
  }
}

void main() {
  testWidgets(
    'zoom coalesces latest, retains visible image and leases old source until cancelled native job finishes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('image-082-'),
      ))!;
      await writeSyntheticPaper(
        tester,
        '${dir.path}/A.PNG',
        width: 512,
        height: 768,
      );
      await tester.runAsync(
        () => File('${dir.path}/A.PNG').copy('${dir.path}/B.PNG'),
      );
      final transform = TransformationController();
      final slow = _SlowDecode();
      var path = '${dir.path}/A.PNG', rendered = 0;
      late StateSetter update;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, refresh) {
                update = refresh;
                return Center(
                  child: SizedBox(
                    width: 200,
                    height: 300,
                    child: SharpFileImage(
                      path: path,
                      transform: transform,
                      onRendered: () => rendered++,
                      decodeForTesting: (descriptor, target) =>
                          slow.call('active', descriptor, target),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await until082(tester, () => slow.calls.length == 1);
        slow.calls[0].done.complete();
        await until082(tester, () => rendered == 1);
        final original = tester.widget<RawImage>(find.byType(RawImage)).image;
        transform.value = Matrix4.diagonal3Values(1.2, 1.2, 1);
        update(() {});
        await until082(tester, () => slow.calls.length == 2);
        for (final scale in [1.4, 1.6, 2.0]) {
          transform.value = Matrix4.diagonal3Values(scale, scale, 1);
          update(() {});
          await tester.pump();
        }
        expect(slow.calls, hasLength(2));
        expect(
          tester.widget<RawImage>(find.byType(RawImage)).image,
          same(original),
        );
        slow.calls[1].done.complete();
        await until082(tester, () => slow.calls.length == 3);
        expect(slow.calls.last.target, const Size(480, 720));
        slow.calls[2].done.complete();
        await until082(tester, () => rendered == 3);
        transform.value = Matrix4.diagonal3Values(3, 3, 1);
        update(() {});
        await until082(tester, () => slow.calls.length == 4);
        update(() => path = '${dir.path}/B.PNG');
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpWidget(const SizedBox());
        slow.calls[3].done.complete();
        await until082(tester, () => slow.active == 0);
        expect(slow.calls, hasLength(4));
        expect(slow.peak, 1);
        expect(
          rendered,
          3,
          reason: 'retired path never publishes its final native frame',
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'IMAGE_082 latest=480x720 peak=1 old_visible=true retired_source_decode_completed=true stale_callback=false',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        transform.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'global decode starts foreground before queued neighbour and drops retired queued source',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('image-priority-082-'),
      ))!;
      await writeSyntheticPaper(
        tester,
        '${dir.path}/synthetic.PNG',
        width: 512,
        height: 768,
      );
      final slow = _SlowDecode(), transform = TransformationController();
      late StateSetter update;
      var added = false, keepB = true;
      Widget image(String name, bool active) => SizedBox(
        width: 100,
        height: 150,
        child: SharpFileImage(
          key: ValueKey(name),
          path: '${dir.path}/synthetic.PNG',
          transform: transform,
          active: active,
          decodeForTesting: (descriptor, target) =>
              slow.call(name, descriptor, target),
        ),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, refresh) {
                update = refresh;
                return Row(
                  children: [
                    image('A', true),
                    if (added) ...[
                      if (keepB) image('retired-neighbour', false),
                      image('foreground', true),
                      image('neighbour', false),
                    ],
                  ],
                );
              },
            ),
          ),
        );
        await until082(tester, () => slow.calls.length == 1);
        update(() => added = true);
        for (var i = 0; i < 10; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        update(() => keepB = false);
        await tester.pump();
        slow.calls[0].done.complete();
        await until082(tester, () => slow.calls.length == 2);
        expect(slow.calls[1].name, 'foreground');
        slow.calls[1].done.complete();
        await until082(tester, () => slow.calls.length == 3);
        expect(slow.calls[2].name, 'neighbour');
        await tester.pumpWidget(const SizedBox());
        slow.calls[2].done.complete();
        await until082(tester, () => slow.active == 0);
        expect(slow.peak, 1);
        expect(slow.calls.map((c) => c.name), ['A', 'foreground', 'neighbour']);
        expect(tester.takeException(), isNull);
        debugPrint(
          'IMAGE_PRIORITY_082 native_peak=1 order=A,foreground,neighbour retired_queued_source_dropped=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        transform.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'uppercase bitmap metadata uses descriptor without decoding synthetic oversized damaged pixels',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('image-metadata-082-'),
      ))!;
      await writeSyntheticPaper(
        tester,
        '${dir.path}/metadata.PNG',
        width: 8,
        height: 12,
      );
      try {
        await tester.runAsync(() async {
          final file = File('${dir.path}/metadata.PNG');
          final bytes = await file.readAsBytes();
          final header = ByteData.sublistView(bytes);
          header.setUint32(16, 5954);
          header.setUint32(20, 8929);
          var crc = 0xffffffff;
          for (final byte in bytes.sublist(12, 29)) {
            crc ^= byte;
            for (var bit = 0; bit < 8; bit++) {
              crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
            }
          }
          header.setUint32(29, (crc ^ 0xffffffff) & 0xffffffff);
          await file.writeAsBytes(bytes);
          final loaded = await loadScore(
            ScoreTarget(
              entryId: 'synthetic',
              revisionId: 'r',
              filePath: file.path,
              displayPath: 'synthetic.PNG',
              verifiedImmutable: true,
            ),
            cacheDirectory: dir.path,
          );
          expect(loaded.pageCount, 1);
          expect(loaded.imageAspect, 5954 / 8929);
          await loaded.dispose();
        });
      } finally {
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
