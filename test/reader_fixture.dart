import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> writeSyntheticPaper(
  WidgetTester tester,
  String path, {
  int width = 81,
  int height = 108,
}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  final image = (await tester.runAsync(() => picture.toImage(width, height)))!;
  picture.dispose();
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  image.dispose();
  await tester.runAsync(
    () => File(path).writeAsBytes(bytes!.buffer.asUint8List()),
  );
}

Future<void> settleReader(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  await tester.pump();
}
