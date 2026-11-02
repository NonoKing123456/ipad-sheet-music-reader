import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/sharing/annotated_pdf_export.dart';

List<int> exportFixturePdf() {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>',
  ];
  for (var i = 0; i < 3; i++) {
    const commands =
        '.92 .97 .89 rg 0 0 120 160 re f .1 .3 .7 rg 10 120 30 20 re f';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 160] '
      '${i == 1 ? '/Rotate 90 ' : ''}/Resources << >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add(
      '<< /Length ${commands.length} >>\nstream\n$commands\nendstream',
    );
  }
  final out = StringBuffer('%PDF-1.4\n'), offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

List<PageAnnotation> exportFixtureAnnotations(int page) {
  final now = DateTime.utc(2026, 11, 2);
  return [
    AnnotationStroke(
      id: 'highlight-$page',
      style: StrokeStyle(
        tool: AnnotationTool.highlighter,
        argb: 0x60ffcc00,
        widthFraction: .08,
      ),
      points: [NormalizedPoint(.1, .38), NormalizedPoint(.82, .38)],
      createdUtc: now,
      updatedUtc: now,
      version: 1,
    ),
    TextAnnotation(
      id: 'text-$page',
      text: '渐强，cresc.\n慢一点！',
      anchor: NormalizedPoint(.16, .42),
      argb: 0xffa60020,
      fontSizeFraction: .07,
      widthFraction: .38,
      rotation: -.28,
      createdUtc: now,
      updatedUtc: now,
      version: 1,
    ),
    AnnotationStroke(
      id: 'pen-$page',
      style: StrokeStyle(
        tool: AnnotationTool.pen,
        argb: 0xff1234aa,
        widthFraction: .014,
      ),
      points: [
        NormalizedPoint(.14, .8),
        NormalizedPoint(.45, .88),
        NormalizedPoint(.76, .78),
      ],
      createdUtc: now,
      updatedUtc: now,
      version: 1,
    ),
  ];
}

void main() {
  test('raster budget covers large and extreme-aspect pages', () {
    for (final size in [
      const Size(595, 842),
      const Size(20000, 40000),
      const Size(1, 1000000000),
    ]) {
      final pixels = AnnotatedPdfExporter.rasterSize(size);
      expect(
        pixels.width * pixels.height,
        lessThanOrEqualTo(AnnotatedPdfExporter.maxPixels),
      );
      expect(
        pixels.longestSide,
        lessThanOrEqualTo(AnnotatedPdfExporter.maxDimension),
      );
    }
  });

  testWidgets(
    'flattened PDF matches original plus ink, highlight and rotated wrapped text, including a 90 degree page',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('annotated-export-'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => root.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProvider,
          null,
        ),
      );
      await tester.runAsync(() async {
        final source = File('${root.path}/原谱.pdf');
        final bytes = exportFixturePdf();
        await source.writeAsBytes(bytes);
        final progress = <int>[];
        final output = await AnnotatedPdfExporter().export(
          original: source,
          annotationsFor: exportFixtureAnnotations,
          cancellation: ExportCancellation(),
          textFontFamily: 'Roboto',
          onProgress: (complete, total) {
            expect(total, 3);
            progress.add(complete);
          },
        );
        expect(output.path.endsWith('原谱-批注.pdf'), isTrue);
        expect(progress, [0, 1, 2, 3]);
        expect(await source.readAsBytes(), bytes);
        final original = await PdfDocument.openFile(source.path);
        final exported = await PdfDocument.openFile(output.path);
        try {
          expect(exported.pages.length, 3);
          expect(original.pages[1].width, 160);
          expect(original.pages[1].height, 120);
          for (var i = 0; i < 3; i++) {
            final page = original.pages[i], actual = exported.pages[i];
            expect(actual.width, page.width);
            expect(actual.height, page.height);
            final pixels = AnnotatedPdfExporter.rasterSize(
              Size(page.width, page.height),
            );
            final base = (await page.render(
              width: pixels.width.toInt(),
              height: pixels.height.toInt(),
              fullWidth: pixels.width,
              fullHeight: pixels.height,
            ))!;
            final baseImage = await base.createImage();
            base.dispose();
            final recorder = ui.PictureRecorder();
            // A separate direct reader painter is the expected visible page.
            final expectedCanvas = Canvas(recorder);
            expectedCanvas.drawImage(baseImage, Offset.zero, Paint());
            AnnotationPainter(
              strokes: exportFixtureAnnotations(i + 1),
              pending: const [],
              draft: const [],
              draftStyle: StrokeStyle(
                tool: AnnotationTool.pen,
                argb: 0xff000000,
                widthFraction: .004,
              ),
              textFontFamily: 'Roboto',
            ).paint(expectedCanvas, pixels);
            final picture = recorder.endRecording();
            final expected = await picture.toImage(
              pixels.width.toInt(),
              pixels.height.toInt(),
            );
            picture.dispose();
            baseImage.dispose();
            final rendered = (await actual.render(
              width: pixels.width.toInt(),
              height: pixels.height.toInt(),
              fullWidth: pixels.width,
              fullHeight: pixels.height,
            ))!;
            final result = await rendered.createImage();
            rendered.dispose();
            final expectedData = (await expected.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final resultData = (await result.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            var totalError = 0, largeErrors = 0;
            for (var pixel = 0; pixel < expectedData.length; pixel++) {
              final error = (expectedData[pixel] - resultData[pixel]).abs();
              totalError += error;
              if (error > 8) largeErrors++;
            }
            expect(totalError / expectedData.length, lessThan(.4));
            expect(largeErrors / expectedData.length, lessThan(.005));
            if (const bool.fromEnvironment('CAPTURE_SHARE_PREVIEW') && i < 2) {
              final directory = Directory('artifacts/qa/theme-share31');
              await directory.create(recursive: true);
              await File('${directory.path}/annotated-export-page-${i + 1}.png')
                  .writeAsBytes(
                    (await result.toByteData(format: ui.ImageByteFormat.png))!
                        .buffer
                        .asUint8List(),
                  );
              await output.copy('${directory.path}/synthetic-annotated.pdf');
            }
            expected.dispose();
            result.dispose();
          }
        } finally {
          await original.dispose();
          await exported.dispose();
        }

        final cancelSource = File('${root.path}/取消.pdf');
        await cancelSource.writeAsBytes(bytes);
        final cancellation = ExportCancellation();
        await expectLater(
          AnnotatedPdfExporter().export(
            original: cancelSource,
            annotationsFor: exportFixtureAnnotations,
            cancellation: cancellation,
            onProgress: (complete, _) {
              if (complete == 1) cancellation.cancel();
            },
          ),
          throwsA(isA<ExportCancelled>()),
        );
        expect(await File('${root.path}/取消-批注.pdf.partial').exists(), isFalse);
        expect(await File('${root.path}/取消-批注.pdf').exists(), isFalse);
        await expectLater(
          AnnotatedPdfExporter().export(
            original: cancelSource,
            annotationsFor: (_) => throw StateError('annotation read failed'),
            cancellation: ExportCancellation(),
          ),
          throwsStateError,
        );
        expect(await File('${root.path}/取消-批注.pdf.partial').exists(), isFalse);
      });
    },
  );

  testWidgets(
    'image export uses A4 width and contains its original colour pixels',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('image-export-'),
      ))!;
      addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(const Color(0xffbedac4), BlendMode.src);
        final picture = recorder.endRecording(),
            image = await picture.toImage(40, 20);
        picture.dispose();
        final original = File('${root.path}/图像.png');
        await original.writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
        final output = await AnnotatedPdfExporter().export(
          original: original,
          annotationsFor: (_) => const [],
          cancellation: ExportCancellation(),
        );
        final pdf = await PdfDocument.openFile(output.path);
        try {
          expect(pdf.pages.length, 1);
          expect(pdf.pages.single.width, 842);
          expect(pdf.pages.single.height, 421);
          final raster = (await pdf.pages.single.render(
            width: 40,
            height: 20,
            fullWidth: 40,
            fullHeight: 20,
          ))!;
          expect(raster.pixels.take(4).toList(), [0xc4, 0xda, 0xbe, 0xff]);
          raster.dispose();
        } finally {
          await pdf.dispose();
        }
      });
    },
  );
}
