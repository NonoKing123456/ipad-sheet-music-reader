import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:score_reader/reader/raster_plan.dart';
import 'package:score_reader/reader/sharp_pdf_page.dart';

class _Token implements PdfPageRenderCancellationToken {
  bool cancelled = false;
  @override
  bool get isCanceled => cancelled;
  @override
  void cancel() => cancelled = true;
}

class _Page implements PdfPage {
  _Page(this.pageNumber);
  @override
  final int pageNumber;
  final tokens = <_Token>[];
  @override
  PdfPageRenderCancellationToken createCancellationToken() {
    final token = _Token();
    tokens.add(token);
    return token;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final dpr in [1.0, 2.0]) {
    test(
      'physical PDF pixels follow DPR=$dpr and 1x/2x/4x, pan keeps paper coordinates',
      () {
        const paper = Size(600, 800);
        final base = planPageRaster(
          paper: paper,
          devicePixelRatio: dpr,
          zoom: 1,
        );
        expect(base.width, (600 * dpr * 1.2).floor());
        for (final zoom in [2.0, 4.0]) {
          final visible = Rect.fromLTWH(100, 150, 500 / zoom, 600 / zoom);
          final plan = planPageRaster(
            paper: paper,
            devicePixelRatio: dpr,
            zoom: zoom,
            visible: visible,
          );
          expect(plan.fullWidth, closeTo(600 * dpr * zoom * 1.2, 1));
          expect(plan.fullWidth, greaterThan(base.fullWidth));
          expect(plan.x, greaterThan(0));
          expect(plan.y, greaterThan(0));
          expect(
            plan.logicalRect.left * plan.fullWidth / paper.width,
            closeTo(plan.x, .00001),
          );
          expect(
            plan.logicalRect.top * plan.fullHeight / paper.height,
            closeTo(plan.y, .00001),
          );
          expect(plan.pixels, lessThanOrEqualTo(detailPixels));
        }
      },
    );
  }
  test('huge display requests and neighbouring pages have strict pixel/edge bounds', () {
    for (final zoom in [1.0, 2.0, 4.0]) {
      final detail = planPageRaster(
        paper: const Size(5000, 8000),
        devicePixelRatio: 3,
        zoom: zoom,
        visible: const Rect.fromLTWH(100, 100, 4000, 6000),
      );
      expect(detail.pixels, lessThanOrEqualTo(detailPixels));
      expect(detail.width, lessThanOrEqualTo(4096));
      expect(detail.height, lessThanOrEqualTo(4096));
      final neighbour = planPageRaster(
        paper: const Size(5000, 8000),
        devicePixelRatio: 3,
        zoom: zoom,
        neighbour: true,
      );
      expect(neighbour.pixels, lessThanOrEqualTo(neighbourPixels));
      expect(neighbour.width, lessThanOrEqualTo(1600));
      expect(neighbour.height, lessThanOrEqualTo(1600));
      expect(
        neighbour.samePixels(
          planPageRaster(
            paper: const Size(5000, 8000),
            devicePixelRatio: 3,
            zoom: 1,
            neighbour: true,
          ),
        ),
        isTrue,
      );
    }
  });
  test('image decode follows display and zoom beyond 2200 while respecting source and memory bounds', () {
    final fit = planImageDecode(
      source: const Size(5000, 7000),
      paper: const Size(500, 700),
      devicePixelRatio: 1,
      zoom: 1,
    );
    final zoomed = planImageDecode(
      source: const Size(5000, 7000),
      paper: const Size(500, 700),
      devicePixelRatio: 2,
      zoom: 4,
    );
    expect(fit.width, 600);
    expect(zoomed.width, greaterThan(2200));
    expect(zoomed.width * zoomed.height, lessThanOrEqualTo(12000000));
    final native = planImageDecode(
      source: const Size(1200, 1600),
      paper: const Size(600, 800),
      devicePixelRatio: 2,
      zoom: 4,
    );
    expect(native, const Size(1200, 1600));
  });

  testWidgets(
    'rapid zoom/pan, page replacement and disposal reject stale raster frames',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final transform = TransformationController();
      final viewport = GlobalKey();
      final page = _Page(1);
      final replacement = _Page(2);
      final pending = <Completer<ui.Image?>>[];
      final requests = <PageRasterPlan>[];
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.black, BlendMode.src);
      final picture = recorder.endRecording();
      final source = (await tester.runAsync(() => picture.toImage(8, 8)))!;
      picture.dispose();
      final delivered = <ui.Image>[];
      Future<ui.Image?> raster(
        PdfPage page,
        PageRasterPlan plan,
        PdfPageRenderCancellationToken token,
        bool neighbour,
      ) {
        requests.add(plan);
        if (plan.fullWidth <= 241) {
          final image = source.clone();
          delivered.add(image);
          return Future.value(image);
        }
        final future = Completer<ui.Image?>();
        pending.add(future);
        return future.future;
      }

      Future<void> mount(PdfPage current) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 500,
                child: InteractiveViewer(
                  key: viewport,
                  transformationController: transform,
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: SizedBox(
                      width: 200,
                      height: 300,
                      child: SharpPdfPage(
                        page: current,
                        active: true,
                        transform: transform,
                        viewportKey: viewport,
                        rasterizer: raster,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await mount(page);
      await tester.pump();
      transform.value = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(-200, -250, 0);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(pending, hasLength(1));
      transform.value = Matrix4.diagonal3Values(4, 4, 1)
        ..setTranslationRaw(-600, -750, 0);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(pending, hasLength(2));
      final newest = source.clone();
      delivered.add(newest);
      pending[1].complete(newest);
      await tester.pump();
      final old = source.clone();
      pending[0].complete(old);
      await tester.pump();
      expect(old.debugDisposed, isTrue);
      expect(
        tester.widgetList<RawImage>(find.byType(RawImage)).last.image,
        same(newest),
      );
      transform.value = Matrix4.diagonal3Values(4, 4, 1)
        ..setTranslationRaw(-700, -800, 0);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(requests.last.x, greaterThan(0));
      final beforeReplacement = pending.last;
      await mount(replacement);
      await tester.pump();
      final stale = source.clone();
      beforeReplacement.complete(stale);
      await tester.pump();
      expect(stale.debugDisposed, isTrue);
      expect(page.tokens.every((token) => token.isCanceled), isTrue);
      final afterDisposal = pending.last;
      await tester.pumpWidget(const SizedBox());
      final disposed = source.clone();
      afterDisposal.complete(disposed);
      await tester.pump();
      expect(disposed.debugDisposed, isTrue);
      expect(replacement.tokens.every((token) => token.isCanceled), isTrue);
      expect(delivered.every((image) => image.debugDisposed), isTrue);
      source.dispose();
      transform.dispose();
    },
  );
  testWidgets(
    'neighbour base survives activation, pending high resolution, demotion and viewport upgrade',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final transform = TransformationController(), viewport = GlobalKey();
      final page = _Page(1);
      final pending = <Completer<ui.Image?>>[];
      final delivered = <ui.Image>[];
      final errors = <String?>[];
      Future<ui.Image?> raster(
        PdfPage page,
        PageRasterPlan plan,
        PdfPageRenderCancellationToken token,
        bool neighbour,
      ) {
        final c = Completer<ui.Image?>();
        pending.add(c);
        return c.future;
      }

      Future<ui.Image> frame(Color color) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final picture = recorder.endRecording();
        final image = (await tester.runAsync(() => picture.toImage(8, 8)))!;
        picture.dispose();
        delivered.add(image);
        return image;
      }

      Future<void> show(bool active, double width) => tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(
            key: viewport,
            child: Center(
              child: SizedBox(
                width: width,
                height: 500,
                child: SharpPdfPage(
                  page: page,
                  active: active,
                  transform: transform,
                  viewportKey: viewport,
                  rasterizer: raster,
                  onError: errors.add,
                ),
              ),
            ),
          ),
        ),
      );
      await show(false, 300);
      await tester.pump();
      final base = await frame(Colors.red);
      pending[0].complete(base);
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(base));
      await show(true, 300);
      await tester.pump();
      expect(base.debugDisposed, isFalse);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(base));
      await show(false, 300);
      await tester.pump();
      expect(base.debugDisposed, isFalse);
      await show(true, 500);
      await tester.pump();
      expect(base.debugDisposed, isFalse);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(base));
      final high = await frame(Colors.blue);
      pending.last.complete(high);
      await tester.pump();
      await tester.pump();
      expect(base.debugDisposed, isTrue);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(high));
      final errorsBefore = errors.whereType<String>().length;
      transform.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      pending.last.completeError(StateError('synthetic detail failure'));
      await tester.pump();
      await tester.pump();
      expect(high.debugDisposed, isFalse);
      expect(
        tester.widgetList<RawImage>(find.byType(RawImage)).first.image,
        same(high),
      );
      expect(errors.whereType<String>().length, errorsBefore);
      final failedRequestCount = pending.length;
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(
        pending.length,
        failedRequestCount,
        reason: 'failed optional detail must not hot-loop',
      );
      transform.value = Matrix4.diagonal3Values(2.1, 2.1, 1);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(pending.length, greaterThan(failedRequestCount));
      final patch = await frame(Colors.green);
      pending.last.complete(patch);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widgetList<RawImage>(find.byType(RawImage)).last.image,
        same(patch),
      );
      await show(false, 500);
      await tester.pump();
      expect(high.debugDisposed, isFalse);
      await tester.pumpWidget(const SizedBox());
      for (final c in pending.where((c) => !c.isCompleted)) {
        final stale = await frame(Colors.black);
        c.complete(stale);
      }
      await tester.pump();
      expect(delivered.every((image) => image.debugDisposed), isTrue);
      transform.dispose();
    },
  );
}
