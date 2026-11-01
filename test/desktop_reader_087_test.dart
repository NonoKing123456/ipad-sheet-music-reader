import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_continuous.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/sharp_pdf_page.dart';

import 'desktop_reader_fixture.dart' show desktopUntil, desktopSettle;

List<int> widePdf(int count) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(count, (i) => '${3 + i * 2} 0 R').join(' ')}] /Count $count >>',
  ];
  for (var i = 0; i < count; i++) {
    final stream =
        '.9 .94 .98 rg 0 0 600 180 re f\n0 g BT /F1 16 Tf 30 120 Td (Synthetic ${i + 1}) Tj ET\n';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 180] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add(
      '<< /Length ${ascii.encode(stream).length} >>\nstream\n${stream}endstream',
    );
  }
  final out = StringBuffer('%PDF-1.4\n'), offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final n in offsets) {
    out.write('${n.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

void main() {
  testWidgets(
    'continuous quarter-to-eight zoom shares button wheel pinch bounds, preserves focal point and paints bounded extra visible previews',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      final controller = ReaderContinuousController();
      final mounted = <int, int?>{};
      final presented = <int>[];
      var requested = 100, token = 0;
      StateSetter? update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ReaderContinuousView(
                documentKey: 'synthetic',
                pageCount: 820,
                aspectFor: (page) => page == 700 ? 30 : 4,
                controller: controller,
                requestedPage: requested,
                navigationToken: token,
                onPresented: presented.add,
                pageBuilder: (n, active, ready, failed) => _ZoomPaper(
                  number: n,
                  ready: ready,
                  budget: null,
                  register: (value) => mounted[n] = value,
                  remove: () => mounted.remove(n),
                ),
                previewPageBuilder: (n, budget, ready, failed) => _ZoomPaper(
                  number: n,
                  ready: ready,
                  budget: budget,
                  register: (value) => mounted[n] = value,
                  remove: () => mounted.remove(n),
                ),
              );
            },
          ),
        ),
      );
      Future<void> frames([int count = 8]) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      (int, double) at(Offset point) {
        for (final element in find.byType(_ZoomPaper).evaluate()) {
          final box = element.renderObject! as RenderBox,
              rect = box.localToGlobal(Offset.zero) & box.size;
          if (rect.contains(point)) {
            return (
              (element.widget as _ZoomPaper).number,
              (point.dy - rect.top) / rect.height,
            );
          }
        }
        throw StateError('No real paper at focal point');
      }

      Future<void> wheel(double delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: const Offset(450, 450),
            scrollDelta: Offset(0, delta),
          ),
        );
        await frames();
      }

      try {
        await frames();
        final before = at(const Offset(450, 450));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await wheel(9999);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(controller.scale, .25);
        final after = at(const Offset(450, 450));
        expect(after.$1, before.$1);
        expect(after.$2, closeTo(before.$2, .02));
        expect(
          mounted.values.where((x) => x == null).length,
          lessThanOrEqualTo(4),
        );
        final previews = mounted.values.whereType<int>().toList();
        expect(previews.length, greaterThan(4));
        expect(
          previews.reduce((a, b) => a + b),
          lessThanOrEqualTo(continuousPreviewPixels),
        );
        expect(previews.every((x) => x <= 256000), isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await wheel(-9999);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(controller.scale, 8);
        expect(at(const Offset(450, 450)).$1, before.$1);
        expect(
          mounted.values.where((x) => x == null).length,
          lessThanOrEqualTo(4),
        );
        controller.fit();
        await frames();
        final one = await tester.createGesture(pointer: 41),
            two = await tester.createGesture(pointer: 42);
        await one.down(const Offset(440, 450));
        await two.down(const Offset(460, 450));
        // Activate scaling by moving the two-finger focal point first.
        await one.moveTo(const Offset(440, 480));
        await two.moveTo(const Offset(460, 480));
        await frames();
        await one.moveTo(const Offset(100, 480));
        await two.moveTo(const Offset(800, 480));
        await frames();
        expect(controller.scale, 8);
        await one.moveTo(const Offset(449, 480));
        await two.moveTo(const Offset(451, 480));
        await frames();
        expect(controller.scale, .25);
        await one.up();
        await two.up();
        controller.zoom(.01);
        await frames();
        expect(controller.scale, .25);
        controller.zoom(1000);
        await frames();
        expect(controller.scale, 8);
        controller.fit();
        await frames();
        expect(controller.scale, 1);
        update!(() {
          requested = 700;
          token++;
        });
        await frames();
        expect(controller.anchor!.page, 700);
        expect(presented.last, 700);
        expect(
          mounted[700],
          isNull,
          reason: 'explicitly selected narrow page receives a high-res surface',
        );
        expect(mounted.containsKey(700), true);
        await frames();
        expect(
          presented.last,
          700,
          reason:
              'later ready neighbours do not replace latest navigation focus',
        );
        debugPrint(
          'DESKTOP_087 zoom_range=.25..8 wheel_pinch_buttons=true focal_stable=true high_surfaces<=4 extra_visible_preview_pixels<=2000000 virtualization820=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'formal grouped text and card blanks work; four arrows queue pages/spreads without repeats or stealing inputs/menus; low zoom PDF stays painted',
    (tester) async {
      tester.view.physicalSize = const Size(1360, 900);
      tester.view.devicePixelRatio = 1;
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reader-087-'),
      ))!;
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => dir.path,
      );
      final bytes = widePdf(20);
      await tester.runAsync(
        () => File('${dir.path}/wide.pdf').writeAsBytes(bytes),
      );
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      final target = ScoreTarget(
        entryId: 'synthetic',
        revisionId: 'r1',
        filePath: '${dir.path}/wide.pdf',
        displayPath: 'Synthetic.pdf',
        contentHash: sha256.convert(bytes).toString(),
      );
      final presented = <int>[];
      var loads = 0;
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
      }

      Future<void> page(int n) => desktopUntil(
        tester,
        () => presented.isNotEmpty && presented.last == n,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [readerRouteVisibility],
            home: LibraryReaderScreen(
              workspace: workspace,
              locate: (_) => target,
              initialTarget: target,
              onPresented: (p) => presented.add(p.pageNumber),
              loader: (t) async {
                loads++;
                return loadScore(t, cacheDirectory: '${dir.path}/cache');
              },
            ),
          ),
        );
        await page(1);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await page(2);
        await key(LogicalKeyboardKey.arrowDown);
        await key(LogicalKeyboardKey.arrowRight);
        await page(4);
        await tester.tap(find.byTooltip('跳到页码'));
        await desktopSettle(tester);
        await tester.tap(find.byType(TextFormField));
        await key(LogicalKeyboardKey.arrowLeft);
        await key(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(presented.last, 4);
        await tester.tap(find.text('取消'));
        await desktopSettle(tester);
        await tester.tap(find.text('双页'));
        await desktopUntil(
          tester,
          () => find.text('3–4 / 20').evaluate().isNotEmpty,
        );
        await key(LogicalKeyboardKey.arrowRight);
        await page(5);
        await key(LogicalKeyboardKey.arrowUp);
        await page(3);
        await key(LogicalKeyboardKey.arrowLeft);
        await page(1);
        await tester.tap(find.text('首页并排'));
        await desktopSettle(tester);
        final previous = presented.last;
        await key(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(presented.last, previous);
        await key(LogicalKeyboardKey.escape);
        await desktopSettle(tester);
        expect(
          find.text('首页独立'),
          findsNothing,
          reason: 'menu Escape restores the page context',
        );
        await tester.tap(find.text('首页并排').first);
        await desktopSettle(tester);
        await tester.tap(find.text('首页独立'));
        await desktopSettle(tester);
        await key(LogicalKeyboardKey.arrowRight);
        await page(2);
        await desktopUntil(
          tester,
          () => find.text('2–3 / 20').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('批注'));
        await desktopSettle(tester);
        expect(find.byType(AlertDialog), findsNothing);
        final card = find.byKey(const ValueKey('annotate-page-3'));
        final rect = tester.getRect(card);
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.right, lessThanOrEqualTo(1360 - 12));
        await tester.tapAt(rect.bottomRight - const Offset(8, 8));
        await desktopUntil(
          tester,
          () => find.text('完成').evaluate().isNotEmpty && presented.last == 3,
        );
        await tester.tap(find.text('完成'));
        await desktopUntil(
          tester,
          () => find.text('2–3 / 20').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('连续'));
        await page(3);
        await key(LogicalKeyboardKey.arrowDown);
        await page(4);
        await key(LogicalKeyboardKey.arrowLeft);
        await page(3);
        final continuous = tester.widget<ReaderContinuousView>(
          find.byType(ReaderContinuousView),
        );
        continuous.controller.zoom(.25);
        await desktopSettle(tester);
        List<SharpPdfPage> low() => tester
            .widgetList<SharpPdfPage>(find.byType(SharpPdfPage))
            .where((p) => p.previewPixels != null)
            .toList();
        await desktopUntil(
          tester,
          () =>
              low().isNotEmpty &&
              find
                  .byType(SharpPdfPage)
                  .evaluate()
                  .every(
                    (e) => find
                        .descendant(
                          of: find.byWidget(e.widget),
                          matching: find.byType(RawImage),
                        )
                        .evaluate()
                        .isNotEmpty,
                  ),
        );
        expect(
          tester
              .widgetList<SharpPdfPage>(find.byType(SharpPdfPage))
              .where((p) => p.previewPixels == null)
              .length,
          lessThanOrEqualTo(4),
        );
        var pixels = 0;
        for (final p in low()) {
          final images = tester
              .widgetList<RawImage>(
                find.descendant(
                  of: find.byWidget(p),
                  matching: find.byType(RawImage),
                ),
              )
              .toList();
          expect(images, hasLength(1));
          final image = images.single.image!;
          expect(
            image.width * image.height,
            lessThanOrEqualTo(p.previewPixels!),
          );
          pixels += image.width * image.height;
          final data = (await tester.runAsync(() => image.toByteData()))!;
          expect(
            data.getUint8(0),
            lessThan(250),
            reason: 'actual PDF content, not a white numbered placeholder',
          );
        }
        expect(pixels, lessThanOrEqualTo(continuousPreviewPixels));
        expect(loads, 1);
        debugPrint(
          'DESKTOP_087 whole_text_buttons=true page_card_blank_hit=true popover_margin>=12 four_arrows_ordered=true repeats_ignored=true input_menu_keys_preserved=true low_pdf_content=true low_pixels=$pixels loads=1',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await desktopUntil(tester, () => !workspace.saving);
        workspace.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        );
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _ZoomPaper extends StatefulWidget {
  const _ZoomPaper({
    required this.number,
    required this.ready,
    required this.budget,
    required this.register,
    required this.remove,
  });
  final int number;
  final int? budget;
  final VoidCallback ready, remove;
  final ValueChanged<int?> register;
  @override
  State<_ZoomPaper> createState() => _ZoomPaperState();
}

class _ZoomPaperState extends State<_ZoomPaper> {
  @override
  void initState() {
    super.initState();
    widget.register(widget.budget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.ready();
    });
  }

  @override
  void didUpdateWidget(covariant _ZoomPaper old) {
    super.didUpdateWidget(old);
    widget.register(widget.budget);
  }

  @override
  void dispose() {
    widget.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.budget == null ? Colors.blueGrey : Colors.lightBlueAccent,
    child: Text('${widget.number}'),
  );
}
