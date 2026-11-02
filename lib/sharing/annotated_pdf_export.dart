import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:reader_state/reader_state.dart';

import '../reader/annotation_canvas.dart';
import 'streaming_image_pdf.dart';

typedef ExportAnnotations = List<PageAnnotation> Function(int pageNumber);

class ExportCancelled implements Exception {
  const ExportCancelled();
}

class ExportCancellation {
  bool _cancelled = false;
  PdfPageRenderCancellationToken? _render;
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    _render?.cancel();
  }

  void check() {
    if (_cancelled) throw const ExportCancelled();
  }
}

/// One page at a time, at most 8 MP. No page raster survives its write.
/// Output is a self-contained, flattened PDF with the same page sizes/order.
class AnnotatedPdfExporter {
  static const maxPixels = 8000000;
  static const dpi = 300.0;
  static const maxDimension = 8192;

  static Size rasterSize(Size points) {
    if (!points.width.isFinite || !points.height.isFinite || points.isEmpty) {
      throw const FormatException('Invalid source page dimensions.');
    }
    final scale = math.min(
      math.min(dpi / 72, math.sqrt(maxPixels / (points.width * points.height))),
      maxDimension / points.longestSide,
    );
    return Size(
      math.max(1, (points.width * scale).floor()).toDouble(),
      math.max(1, (points.height * scale).floor()).toDouble(),
    );
  }

  Future<File> export({
    required File original,
    required ExportAnnotations annotationsFor,
    required ExportCancellation cancellation,
    void Function(int complete, int total)? onProgress,
    String? textFontFamily,
  }) async {
    final output = File(
      p.join(
        original.parent.path,
        '${p.basenameWithoutExtension(original.path)}-批注.pdf',
      ),
    );
    final partial = File('${output.path}.partial');
    StreamingImagePdf? writer;
    PdfDocument? document;
    ui.Image? image;
    try {
      cancellation.check();
      if (p.extension(original.path).toLowerCase() == '.pdf') {
        await pdfrxFlutterInitialize();
        document = await PdfDocument.openFile(
          original.path,
          useProgressiveLoading: false,
        );
      } else {
        image = await _decodeImage(original.path);
      }
      final count = document?.pages.length ?? 1;
      if (count < 1) throw const FormatException('No pages to export.');
      // Freeze only annotation metadata; decoded page pixels never accumulate.
      final annotations = List.generate(
        count,
        (i) => List<PageAnnotation>.unmodifiable(annotationsFor(i + 1)),
      );
      writer = await StreamingImagePdf.open(partial);
      onProgress?.call(0, count);
      for (var i = 0; i < count; i++) {
        cancellation.check();
        ui.Image? base, composite;
        try {
          late Size pageSize, pixels;
          final page = document?.pages[i];
          if (page != null) {
            pageSize = Size(page.width, page.height);
            pixels = rasterSize(pageSize);
            cancellation._render = page.createCancellationToken();
            final rendered = await page.render(
              fullWidth: pixels.width,
              fullHeight: pixels.height,
              width: pixels.width.toInt(),
              height: pixels.height.toInt(),
              backgroundColor: 0xffffffff,
              cancellationToken: cancellation._render,
            );
            if (rendered == null) {
              cancellation.check();
              throw StateError('PDF render failed.');
            }
            try {
              base = await rendered.createImage();
            } finally {
              rendered.dispose();
            }
            cancellation._render = null;
          } else {
            base = image!;
            pixels = Size(base.width.toDouble(), base.height.toDouble());
            pageSize = _imagePageSize!;
          }
          cancellation.check();
          final recording = ui.PictureRecorder();
          final canvas = Canvas(recording);
          canvas.drawColor(const Color(0xffffffff), BlendMode.src);
          canvas.drawImageRect(
            base,
            Offset.zero & Size(base.width.toDouble(), base.height.toDouble()),
            Offset.zero & pixels,
            Paint(),
          );
          AnnotationPainter(
            strokes: annotations[i],
            pending: const [],
            draft: const [],
            draftStyle: StrokeStyle(
              tool: AnnotationTool.pen,
              argb: 0xff000000,
              widthFraction: .004,
            ),
            textFontFamily: textFontFamily,
          ).paint(canvas, pixels);
          final picture = recording.endRecording();
          try {
            composite = await picture.toImage(
              pixels.width.toInt(),
              pixels.height.toInt(),
            );
          } finally {
            picture.dispose();
          }
          if (identical(base, image)) image = null;
          base.dispose();
          base = null;
          cancellation.check();
          final rgba = await composite.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (rgba == null) throw StateError('Export pixel conversion failed.');
          final width = composite.width, height = composite.height;
          composite.dispose();
          composite = null;
          await writer.addPage(
            rgba: rgba,
            width: width,
            height: height,
            pageWidth: pageSize.width,
            pageHeight: pageSize.height,
            checkCancelled: cancellation.check,
          );
        } finally {
          if (base != null && !identical(base, image)) base.dispose();
          composite?.dispose();
          cancellation._render = null;
        }
        onProgress?.call(i + 1, count);
      }
      cancellation.check();
      await writer.finish();
      return await partial.rename(output.path);
    } catch (_) {
      await writer?.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      image?.dispose();
      await document?.dispose();
    }
  }

  Size? _imagePageSize;
  Future<ui.Image> _decodeImage(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final pageWidth = descriptor.width > descriptor.height ? 842.0 : 595.0;
      _imagePageSize = Size(
        pageWidth,
        pageWidth * descriptor.height / descriptor.width,
      );
      final scale = math.min(
        1.0,
        math.min(
          math.sqrt(maxPixels / (descriptor.width * descriptor.height)),
          maxDimension / math.max(descriptor.width, descriptor.height),
        ),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).floor()),
        targetHeight: math.max(1, (descriptor.height * scale).floor()),
      );
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
