import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/reader_page_number_button.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_text_layer.dart';
import 'package:score_reader/reader/desktop_reader.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_continuous.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_spreads.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/sharp_pdf_page.dart';

import 'support/sdk_paths.dart';

List<int> desktopPdf(int count) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(count, (i) => '${3 + i * 2} 0 R').join(' ')}] /Count $count >>',
  ];
  for (var i = 0; i < count; i++) {
    final stream =
        '${i.isEven ? '.96 .96 .96' : '.9 .94 .98'} rg 0 0 600 800 re f\n0 g BT /F1 24 Tf 60 720 Td (Synthetic page ${i + 1}) Tj ET\n';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add(
      '<< /Length ${ascii.encode(stream).length} >>\nstream\n${stream}endstream',
    );
  }
  final out = StringBuffer('%PDF-1.4\n'), offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

Future<void> desktopUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 650 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue, reason: 'bounded desktop render/persistence');
  await tester.pump();
}

Future<void> desktopSettle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
}

Future<ui.Image> captureDesktop(WidgetTester tester, GlobalKey key) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
}

Finder shownAnnotation(PageKey page) => find.byElementPredicate((element) {
  final widget = element.widget;
  if (widget is! AnnotationTextLayer || widget.page != page) return false;
  var shown = true;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget case Opacity(opacity: final opacity)
        when opacity == 0) {
      shown = false;
    }
    if (ancestor.widget case Offstage(offstage: true)) shown = false;
    return shown;
  });
  return shown;
});

void main() {
  test('spread A/B grouping and mixed ordered steps keep image boundary, item identity and actual bookmarks', () async {
    for (final arrangement in FirstPageArrangement.values) {
      final groups = ReaderSpreads(
        pageCount: 5,
        doublePage: true,
        arrangement: arrangement,
      );
      expect(
        [for (var i = 1; i <= groups.count; i++) groups.at(i).pages.toList()],
        arrangement == FirstPageArrangement.paired
            ? [
                [1, 2],
                [3, 4],
                [5],
              ]
            : [
                [1],
                [2, 3],
                [4, 5],
              ],
      );
      expect(groups.forPage(3).contains(3), isTrue);
    }
    final dir = await Directory.systemTemp.createTemp('desktop-spreads-085-');
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${dir.path}/state.json'),
    );
    final list = await workspace.store.createSetList('Synthetic');
    final a = await workspace.store.addItem(list.id, 'a');
    await workspace.store.addItem(list.id, 'b');
    final c = await workspace.store.addItem(list.id, 'c');
    ScoreTarget target(String id) => ScoreTarget(
      entryId: id,
      revisionId: 'r1',
      filePath: 'unused',
      displayPath: '$id.pdf',
    );
    final gate = Completer<void>(), started = Completer<void>();
    final session = ReaderSession(
      workspace: workspace,
      locate: target,
      setListId: list.id,
      deferPositionPersistence: true,
      loader: (target) async {
        if (target.entryId == 'b') {
          started.complete();
          await gate.future;
        }
        return LoadedScore(
          target: target,
          pageCount: target.entryId == 'a'
              ? 5
              : target.entryId == 'b'
              ? 1
              : 4,
        );
      },
    );
    FirstPageArrangement arrangement(String id) =>
        id == 'c' ? FirstPageArrangement.alone : FirstPageArrangement.paired;
    try {
      await session.open(
        target('a'),
        itemId: a.id,
        pageNumber: 2,
        restore: false,
      );
      final shown = <String>[];
      session.addListener(
        () => shown.add('${session.position?.entryId}/${session.page}'),
      );
      await session.turnSpread(NavigationDirection.forward, arrangement);
      expect(session.page, 3);
      await session.turnSpread(NavigationDirection.forward, arrangement);
      expect(session.page, 5);
      final crossing = session.turnSpread(
        NavigationDirection.forward,
        arrangement,
      );
      await started.future;
      final staleSeek = session.seek(1, gesture: Object());
      final single = session.turn(NavigationDirection.forward);
      final spread = session.turnSpread(
        NavigationDirection.forward,
        arrangement,
      );
      gate.complete();
      await Future.wait([crossing, staleSeek, single, spread]);
      expect(shown, contains('b/1'));
      expect(session.position!.setListItemId, c.id);
      expect(session.page, 2);
      expect(workspace.store.readingPosition(target('c').key), isNull);
      session.rememberPresented(session.pageKey!, 4);
      await workspace.flushPositions();
      expect(workspace.store.readingPosition(target('c').key)!.pageNumber, 2);
      await session.turnSpread(NavigationDirection.backward, arrangement);
      expect(session.page, 1);
      await session.turnSpread(NavigationDirection.backward, arrangement);
      expect(session.position!.entryId, 'b');
      await session.turnSpread(NavigationDirection.backward, arrangement);
      expect(session.position!.entryId, 'a');
      expect(session.page, 5);
    } finally {
      session.dispose();
      await workspace.flushPositions();
      workspace.dispose();
      await dir.delete(recursive: true);
    }
  });

  testWidgets(
    'shared desktop reader defaults to mouse reading, shows per-page ink, preserves spread focus and header hover fit, then edits the selected page',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desktop-native-085-'),
      ))!;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => dir.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProvider,
          null,
        ),
      );
      await tester.runAsync(() async {
        if (File('C:/Windows/Fonts/msyh.ttc').existsSync()) {
          final font = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
          for (final family in ['Ahem', 'Roboto']) {
            await (FontLoader(
              family,
            )..addFont(Future.value(ByteData.sublistView(font)))).load();
          }
        }
        final icons = await File(materialIconsFontPath).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons)))).load();
      });
      final bytes = desktopPdf(5);
      final file = '${dir.path}/synthetic.pdf';
      await tester.runAsync(() => File(file).writeAsBytes(bytes));
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      final target = ScoreTarget(
        entryId: 'score',
        revisionId: 'r1',
        filePath: file,
        displayPath: 'Synthetic.pdf',
        contentHash: sha256.convert(bytes).toString(),
      );
      PageKey page(int n) =>
          PageKey(entryId: 'score', revisionId: 'r1', pageNumber: n);
      await tester.runAsync(() async {
        for (final (number, color) in [(1, 0xff0000ff), (2, 0xffff0000)]) {
          await workspace.store.addStroke(
            page(number),
            style: StrokeStyle(
              tool: AnnotationTool.pen,
              argb: color,
              widthFraction: .04,
            ),
            points: [NormalizedPoint(.5, .5)],
          );
          await workspace.store.addStroke(
            page(number),
            style: StrokeStyle(
              tool: AnnotationTool.pen,
              argb: color,
              widthFraction: .025,
            ),
            points: [NormalizedPoint(.5, number == 1 ? .92 : .08)],
          );
        }
      });
      var loads = 0;
      final presented = <PageKey>[];
      final boundary = GlobalKey();
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              navigatorObservers: [readerRouteVisibility],
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: (_) => target,
                initialTarget: target,
                onPresented: presented.add,
                loader: (value) async {
                  loads++;
                  return loadScore(value, cacheDirectory: '${dir.path}/cache');
                },
              ),
            ),
          ),
        );
        await desktopUntil(
          tester,
          () => workspace.store.readingPosition(target.key) != null,
        );
        debugPrint('DESKTOP_085 native first presented');
        expect(find.byType(DesktopReaderShell), findsOneWidget);
        expect(find.byTooltip('文字批注'), findsNothing);
        expect(find.byTooltip('开发预览（模拟平板）'), findsNothing);
        final before = workspace.store.snapshot.strokesFor(page(1)).length;
        await tester.tapAt(const Offset(680, 500));
        await tester.pump();
        await tester.pumpAndSettle();
        debugPrint('DESKTOP_085 center hidden');
        expect(workspace.store.snapshot.strokesFor(page(1)).length, before);
        final hiddenRect = tester.getRect(find.byType(SharpPdfPage).first);
        expect(hiddenRect.top, closeTo(8, .01));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(680, 300));
        await mouse.moveTo(const Offset(680, 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        debugPrint('DESKTOP_085 hover shown');
        expect(
          tester.getRect(find.byType(SharpPdfPage).first),
          hiddenRect,
          reason: 'hover overlays without fitting paper again',
        );
        // 1a595b0: v2 has explicit center-toggle chrome, without hover reveal.
        expect(find.byTooltip('返回曲库').hitTestable(), findsNothing);
        await tester.tapAt(const Offset(680, 500));
        await tester.pumpAndSettle();
        await tester.tap(find.text('双页'));
        await desktopUntil(
          tester,
          () =>
              shownAnnotation(page(2)).evaluate().isNotEmpty &&
              find
                  .byKey(const ValueKey('reader-arrangement-button'))
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.tap(
          find.byKey(const ValueKey('reader-arrangement-button')),
        );
        await desktopSettle(tester);
        debugPrint('DESKTOP_085 menu opened');
        await mouse.moveTo(const Offset(1000, 135));
        await tester.pump();
        expect(find.text('首页单独'), findsOneWidget);
        await tester.tap(
          find.byKey(
            const ValueKey((
              'reader-arrangement-option',
              FirstPageArrangement.paired,
            )),
          ),
        );
        await desktopSettle(tester);
        await mouse.moveTo(const Offset(680, 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        await tester.tapAt(const Offset(680, 500));
        await desktopSettle(tester);
        await tester.tapAt(const Offset(680, 500));
        await desktopSettle(tester);
        await tester.tap(find.text('双页'));
        await desktopUntil(
          tester,
          () => shownAnnotation(page(2)).evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(loads, 1);
        expect(
          find.byType(SharpPdfPage).evaluate().length,
          lessThanOrEqualTo(4),
        );
        final image = await captureDesktop(tester, boundary);
        final png = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        if (const bool.fromEnvironment('WRITE_QA_EVIDENCE')) {
          await tester.runAsync(() async {
            final file = File(
              'artifacts/qa/desktop-reader-085/shared-reader-spread.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png.buffer.asUint8List());
          });
        }
        final data = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final pixels = data.buffer.asUint8List();
        for (final (number, channel) in [(1, 2), (2, 0)]) {
          final surface = shownAnnotation(page(number)).first;
          final center = tester.getCenter(surface);
          final index =
              (center.dy.floor() * image.width + center.dx.floor()) * 4;
          expect(pixels[index + channel], greaterThan(200));
          expect(
            pixels[index + (channel == 0 ? 2 : 0)],
            lessThan(60),
            reason: 'each paper paints its own stored ink',
          );
        }
        image.dispose();
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await desktopUntil(
          tester,
          () => workspace.store.readingPosition(target.key)?.pageNumber == 3,
        );
        await tester.tap(
          find.byKey(const ValueKey('reader-arrangement-button')),
        );
        await desktopSettle(tester);
        await tester.tap(find.text('首页单独'));
        await desktopSettle(tester);
        await tester.tap(find.text('单页'));
        await desktopSettle(tester);
        expect(workspace.store.readingPosition(target.key)!.pageNumber, 3);
        await tester.tap(find.text('双页'));
        await desktopSettle(tester);
        await tester.tap(find.byTooltip('批注'));
        await desktopSettle(tester);
        // a9a84fd: annotate directly on either spread page, with an explicit tool.
        await tester.tap(find.byTooltip('画笔'));
        await desktopUntil(
          tester,
          () => find.byTooltip('文字批注').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await desktopUntil(
          tester,
          () =>
              shownAnnotation(page(3)).evaluate().length == 1 &&
              shownAnnotation(page(2)).evaluate().length == 1,
        );
        final paper = shownAnnotation(page(3)).first;
        final point = tester.getRect(paper).centerLeft + const Offset(80, 40);
        final pen = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await pen.down(point);
        await pen.moveBy(const Offset(30, 0));
        await pen.up();
        await desktopUntil(
          tester,
          () =>
              !workspace.saving &&
              workspace.store.snapshot.strokesFor(page(3)).isNotEmpty,
        );
        expect(workspace.store.snapshot.strokesFor(page(1)).length, before);
        expect(workspace.store.snapshot.strokesFor(page(2)).length, 2);
        await tester.tap(find.byTooltip('完成批注'));
        await desktopSettle(tester);
        expect(find.byTooltip('文字批注'), findsNothing);
        expect(loads, 1);
        presented.clear();
        await tester.tap(find.text('连续'));
        await desktopUntil(
          tester,
          () =>
              find.byType(ReaderContinuousView).evaluate().isNotEmpty &&
              presented.isNotEmpty &&
              presented.last == page(3),
        );
        await tester.tap(find.byType(ReaderPageNumberButton));
        await desktopSettle(tester);
        await tester.enterText(find.byType(TextField), '1');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await desktopUntil(
          tester,
          () => presented.isNotEmpty && presented.last == page(1),
        );
        await desktopUntil(
          tester,
          () => find.byType(AlertDialog).evaluate().isEmpty,
        );
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: Offset(680, 500),
            scrollDelta: Offset(0, 1400),
          ),
        );
        await desktopUntil(tester, () => presented.last == page(2));
        final tail = tester.getRect(shownAnnotation(page(1)).first),
            head = tester.getRect(shownAnnotation(page(2)).first);
        expect(tail.bottom, inExclusiveRange(56, 900));
        expect(head.top, inExclusiveRange(56, 900));
        expect(head.top - tail.bottom, closeTo(16, .01));
        expect(
          find.byType(SharpPdfPage).evaluate().length,
          lessThanOrEqualTo(4),
        );
        final continuousImage = await captureDesktop(tester, boundary);
        final continuousPixels = (await tester.runAsync(
          () => continuousImage.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!.buffer.asUint8List();
        for (final (rect, fraction, channel) in [
          (tail, .92, 2),
          (head, .08, 0),
        ]) {
          final point = Offset(
            rect.center.dx,
            rect.top + rect.height * fraction,
          );
          final at =
              (point.dy.floor() * continuousImage.width + point.dx.floor()) * 4;
          expect(continuousPixels[at + channel], greaterThan(200));
          expect(continuousPixels[at + (channel == 0 ? 2 : 0)], lessThan(60));
        }
        final continuousPng = (await tester.runAsync(
          () => continuousImage.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        if (const bool.fromEnvironment('WRITE_QA_EVIDENCE')) {
          await tester.runAsync(
            () => File(
              'artifacts/qa/desktop-reader-085/shared-reader-continuous.png',
            ).writeAsBytes(continuousPng.buffer.asUint8List()),
          );
        }
        continuousImage.dispose();
        final continuousWidget = tester.widget<ReaderContinuousView>(
          find.byType(ReaderContinuousView),
        );
        final anchor = continuousWidget.controller.anchor!;
        final offset = tester
            .widget<ListView>(
              find.byKey(const ValueKey('continuous-page-list')),
            )
            .controller!
            .offset;
        await tester.tap(find.byTooltip('批注'));
        await desktopSettle(tester);
        await desktopUntil(
          tester,
          () =>
              shownAnnotation(page(2)).evaluate().length == 1 &&
              find.byType(ReaderContinuousView).evaluate().isEmpty,
        );
        await tester.tap(find.byTooltip('文字批注'));
        await tester.pump();
        final textPaper = tester.getRect(shownAnnotation(page(2)).first);
        await tester.tapAt(
          textPaper.topLeft +
              Offset(textPaper.width * .3, textPaper.height * .35),
        );
        await desktopSettle(tester);
        await tester.enterText(find.byType(TextField), '中英文, punctuation；');
        await tester.tapAt(const Offset(20, 600));
        await desktopUntil(
          tester,
          () =>
              !workspace.saving &&
              workspace.store.snapshot
                  .annotationsFor(page(2))
                  .whereType<TextAnnotation>()
                  .isNotEmpty &&
              find.byType(AlertDialog).evaluate().isEmpty,
        );
        presented.clear();
        await tester.tap(find.byTooltip('完成批注'));
        await desktopUntil(
          tester,
          () =>
              find.byType(ReaderContinuousView).evaluate().isNotEmpty &&
              presented.isNotEmpty &&
              presented.last == page(2),
        );
        expect(
          tester
              .widget<ListView>(
                find.byKey(const ValueKey('continuous-page-list')),
              )
              .controller!
              .offset,
          closeTo(offset, .01),
        );
        expect(
          tester
              .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
              .controller
              .anchor!
              .page,
          anchor.page,
        );
        expect(
          workspace.store.snapshot
              .annotationsFor(page(2))
              .whereType<TextAnnotation>()
              .single
              .text,
          '中英文, punctuation；',
        );
        expect(workspace.store.snapshot.strokesFor(page(1)).length, before);
        expect(loads, 1);
        await mouse.removePointer();
      } finally {
        await tester.pumpWidget(const SizedBox());
        await desktopUntil(tester, () => !workspace.saving);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
