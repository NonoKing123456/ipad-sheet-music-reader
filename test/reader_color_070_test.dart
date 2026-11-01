import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/paper_color_sampler.dart';
import 'package:score_reader/reader/reader_input.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/sharp_file_image.dart';
import 'package:score_reader/reader/sharp_pdf_page.dart';
import 'package:score_reader/reader/reader_tool_button.dart';

const paperLeft = Color(0xffede3b7), paperRight = Color(0xffbee5d4);
Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (ready()) return;
  }
  expect(ready(), isTrue, reason: 'bounded fixture readiness');
}

Future<void> flush(WidgetTester tester, ReaderWorkspace workspace) async =>
    until(tester, () => !workspace.saving);
Future<ui.Image> paperImage(WidgetTester tester) async {
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawRect(const Rect.fromLTWH(0, 0, 320, 800), Paint()..color = paperLeft);
  c.drawRect(
    const Rect.fromLTWH(320, 0, 320, 800),
    Paint()..color = paperRight,
  );
  c.drawRect(
    const Rect.fromLTWH(30, 30, 90, 60),
    Paint()..blendMode = BlendMode.clear,
  );
  final picture = recorder.endRecording();
  final image = (await tester.runAsync(() => picture.toImage(640, 800)))!;
  picture.dispose();
  return image;
}

class GateSampler extends PaperColorSampler {
  bool gate = false, fail = false;
  var started = Completer<void>(), release = Completer<void>();
  void reset() {
    gate = true;
    started = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<Color?> sample(Object page, Offset point) async {
    if (fail) throw StateError('synthetic source read failure');
    final color = await super.sample(page, point);
    if (gate) {
      started.complete();
      await release.future;
      gate = false;
    }
    return color;
  }
}

Future<(Directory, ReaderWorkspace, ScoreTarget)> setup(
  WidgetTester tester,
) async {
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('paper-colors-'),
  ))!;
  final image = await paperImage(tester);
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  image.dispose();
  await tester.runAsync(
    () => File('${dir.path}/p.png').writeAsBytes(bytes!.buffer.asUint8List()),
  );
  final workspace = (await tester.runAsync(
    () async => ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${dir.path}/state.json'),
    ),
  ))!;
  final target = ScoreTarget(
    entryId: 'e',
    revisionId: 'r',
    filePath: '${dir.path}/p.png',
    displayPath: 'synthetic.png',
  );
  return (dir, workspace, target);
}

Finder canvasPage(int page) => find.byWidgetPredicate(
  (w) => w is AnnotationCanvas && w.page.pageNumber == page,
);
Future<void> mount(
  WidgetTester tester,
  ReaderWorkspace workspace,
  ScoreTarget target, {
  PaperColorSampler? sampler,
}) async {
  await tester.binding.setSurfaceSize(const Size(810, 1080));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryReaderScreen(
          workspace: workspace,
          locate: (_) => target,
          initialTarget: target,
          colorSampler: sampler,
          loader: (t) async =>
              LoadedScore(target: t, pageCount: 2, imageAspect: .8),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 25));
  });
  await until(tester, () => canvasPage(1).hitTestable().evaluate().isNotEmpty);
  await flush(tester, workspace);
}

Future<void> openTools(WidgetTester tester) async {
  final buttons = find.byType(ReaderSampleColorButton).hitTestable();
  if (buttons.evaluate().isEmpty) {
    await tester.tapAt(const Offset(405, 540));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
  }
}

Future<void> beginNewSample(WidgetTester tester) async {
  final button = tester.widget<ReaderSampleColorButton>(
    find.byType(ReaderSampleColorButton),
  );
  await tester.tap(find.byType(ReaderSampleColorButton));
  await tester.pumpAndSettle();
  if (button.sample != null && !button.picking) {
    await tester.tap(find.text('重新吸色'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'eyedropper reads underlying source through ink and zoom/pan, transparent pixels become white, covering stroke persists and undoes',
    (tester) async {
      final (dir, workspace, target) = await setup(tester);
      try {
        await mount(tester, workspace, target);
        final page = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1);
        await tester.runAsync(
          () => workspace.store.addStroke(
            page,
            style: StrokeStyle(
              tool: AnnotationTool.pen,
              argb: 0xffff0000,
              widthFraction: .09,
            ),
            points: [NormalizedPoint(.55, .55), NormalizedPoint(.8, .55)],
          ),
        );
        workspace.refreshFromStore();
        await tester.pump();
        await openTools(tester);
        final input = tester.widget<ReaderInput>(find.byType(ReaderInput));
        input.transform!.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-405, -540, 0);
        await tester.pump();
        var box = tester.renderObject<RenderBox>(canvasPage(1));
        await beginNewSample(tester);
        await tester.pump();
        await tester.tapAt(
          box.localToGlobal(
            Offset(box.size.width * .65, box.size.height * .55),
          ),
        );
        await until(
          tester,
          () =>
              tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb ==
              paperRight.toARGB32(),
        );
        expect(workspace.store.snapshot.strokesFor(page), hasLength(1));
        expect(find.byType(PaperColorPickLayer), findsNothing);
        box = tester.renderObject<RenderBox>(canvasPage(1));
        final pen = await tester.startGesture(
          box.localToGlobal(Offset(box.size.width * .6, box.size.height * .55)),
          pointer: 50,
          kind: PointerDeviceKind.stylus,
        );
        await pen.moveTo(
          box.localToGlobal(Offset(box.size.width * .7, box.size.height * .55)),
        );
        await pen.up();
        await flush(tester, workspace);
        expect(
          workspace.store.snapshot.strokesFor(page).last.style.argb,
          paperRight.toARGB32(),
        );
        final reopened = (await tester.runAsync(
          () => ReaderStateStore.open(statePath: workspace.store.statePath),
        ))!;
        expect(
          reopened.snapshot.strokesFor(page).last.style.argb,
          paperRight.toARGB32(),
        );
        await tester.runAsync(() => workspace.store.undo(page));
        workspace.refreshFromStore();
        await tester.pump();
        expect(workspace.store.snapshot.strokesFor(page), hasLength(1));
        // The transparent patch is composited against white paper, not RGB zero.
        input.transform!.value = Matrix4.identity()
          ..setTranslationRaw(0, 140, 0);
        await tester.pump();
        await beginNewSample(tester);
        await tester.pump();
        box = tester.renderObject<RenderBox>(canvasPage(1));
        await tester.tapAt(
          box.localToGlobal(Offset(box.size.width * .1, box.size.height * .07)),
        );
        await until(
          tester,
          () =>
              tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb ==
              0xffffffff,
        );
        expect(find.text('1 / 2'), findsOneWidget);
        expect(workspace.store.snapshot.strokesFor(page), hasLength(1));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'cancelled and page-stale source reads do not change color or ink; failures preserve color and show a light message',
    (tester) async {
      final (dir, workspace, target) = await setup(tester);
      final sampler = GateSampler();
      try {
        await mount(tester, workspace, target, sampler: sampler);
        await openTools(tester);
        final old = tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb;
        Future<void> start() async {
          sampler.reset();
          await tester.tap(find.byTooltip('吸取谱面底色'));
          await tester.pump();
          final box = tester.renderObject<RenderBox>(canvasPage(1));
          await tester.tapAt(
            box.localToGlobal(
              Offset(box.size.width * .65, box.size.height * .55),
            ),
          );
          await until(tester, () => sampler.started.isCompleted);
        }

        await start();
        await tester.tap(find.byTooltip('取消吸色'));
        await tester.pump();
        sampler.release.complete();
        await until(
          tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb, old);
        await start();
        await tester.tap(find.byTooltip('蓝色'));
        await tester.pump();
        final manual = tester
            .widget<AnnotationCanvas>(canvasPage(1))
            .style
            .argb;
        sampler.release.complete();
        await until(
          tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(
          tester.widget<AnnotationCanvas>(canvasPage(1)).style.argb,
          manual,
        );
        expect(find.byType(PaperColorPickLayer), findsNothing);
        await start();
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await until(tester, () => find.text('2 / 2').evaluate().isNotEmpty);
        sampler.release.complete();
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<AnnotationCanvas>(canvasPage(2)).style.argb,
          manual,
        );
        sampler.fail = true;
        await tester.tap(find.byTooltip('吸取谱面底色'));
        await tester.pump();
        final box = tester.renderObject<RenderBox>(canvasPage(2));
        await tester.tapAt(box.localToGlobal(box.size.center(Offset.zero)));
        await until(tester, () => find.byTooltip('阅读状态').evaluate().isNotEmpty);
        await tester.tap(find.byTooltip('阅读状态'));
        await tester.pumpAndSettle();
        expect(find.text('底色读取失败，请重试。'), findsOneWidget);
        expect(
          tester.widget<AnnotationCanvas>(canvasPage(2)).style.argb,
          manual,
        );
        expect(
          workspace.store.snapshot.strokesFor(
            PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1),
          ),
          isEmpty,
        );
        expect(
          workspace.store.snapshot.strokesFor(
            PageKey(entryId: 'e', revisionId: 'r', pageNumber: 2),
          ),
          isEmpty,
        );
        expect(sampler.sourceCount, lessThanOrEqualTo(3));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'source crop clone survives renderer image disposal and bitmap letterbox is excluded',
    (tester) async {
      final image = await paperImage(tester);
      final future = samplePaperImage(image, const Offset(.65, .55));
      image.dispose();
      final result = await tester.runAsync(() => future);
      expect(result, paperRight);
      final (dir, workspace, target) = await setup(tester);
      final sampler = PaperColorSampler(),
          transform = TransformationController();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 800,
                height: 400,
                child: SharpFileImage(
                  path: target.filePath,
                  transform: transform,
                  colorSampler: sampler,
                  colorKey: 'image',
                ),
              ),
            ),
          ),
        );
        await until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        final outside = await tester.runAsync(
          () => sampler.sample('image', const Offset(.05, .5)),
        );
        expect(outside, isNull);
        final inside = await tester.runAsync(
          () => sampler.sample('image', const Offset(.55, .55)),
        );
        expect(inside, paperRight);
      } finally {
        await tester.pumpWidget(const SizedBox());
        expect(sampler.sourceCount, 0);
        transform.dispose();
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'PDF sampling uses its unannotated base and the exact painted detail region after zoom/pan',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final sampler = PaperColorSampler(),
          transform = TransformationController(),
          viewport = GlobalKey();
      final base = await paperImage(tester);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffabcdef), BlendMode.src);
      final picture = recorder.endRecording();
      final detail = (await tester.runAsync(() => picture.toImage(16, 16)))!;
      picture.dispose();
      var patches = 0;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderInput(
              viewportKey: viewport,
              transform: transform,
              onPrevious: () {},
              onNext: () {},
              child: Center(
                child: AspectRatio(
                  aspectRatio: .8,
                  child: SharpPdfPage(
                    page: _SamplePage(),
                    active: true,
                    transform: transform,
                    viewportKey: viewport,
                    colorSampler: sampler,
                    colorKey: 'pdf',
                    rasterizer: (page, plan, token, neighbour) async {
                      if (plan.x != 0 || plan.y != 0) {
                        patches++;
                        return detail.clone();
                      }
                      return base.clone();
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
        expect(
          await tester.runAsync(
            () => sampler.sample('pdf', const Offset(.65, .55)),
          ),
          paperRight,
        );
        transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-400, -300, 0);
        await until(
          tester,
          () => patches > 0 && find.byType(RawImage).evaluate().length == 2,
        );
        expect(
          await tester.runAsync(
            () => sampler.sample('pdf', const Offset(.5, .5)),
          ),
          const Color(0xffabcdef),
        );
        transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-100, -300, 0);
        expect(
          await tester.runAsync(
            () => sampler.sample('pdf', const Offset(.02, .5)),
          ),
          paperLeft,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        expect(sampler.sourceCount, 0);
        transform.dispose();
        base.dispose();
        detail.dispose();
      }
    },
  );
}

class _SampleToken implements PdfPageRenderCancellationToken {
  bool cancelled = false;
  @override
  bool get isCanceled => cancelled;
  @override
  void cancel() => cancelled = true;
}

class _SamplePage implements PdfPage {
  @override
  int get pageNumber => 1;
  @override
  PdfPageRenderCancellationToken createCancellationToken() => _SampleToken();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
