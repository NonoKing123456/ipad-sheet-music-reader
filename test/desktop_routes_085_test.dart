import 'dart:io';

// Transitive interface used only to substitute the existing file chooser in tests.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/main.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_screen.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/desktop_reader.dart';

import 'reader_fixture.dart';
import 'desktop_reader_fixture.dart' show desktopUntil, desktopSettle;

class _DesktopPicker extends FileSelectorPlatform {
  String? path;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => path == null ? null : XFile(path!);
}

void main() {
  testWidgets(
    'main initial path and chooser reuse registered PageKey; true external file uses the same read-only reader without new notes or bookmarks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desktop-routes-085-'),
      ))!;
      final root = (await tester.runAsync(
        () => Directory('${dir.path}/scores').create(),
      ))!;
      final known = '${root.path}/Known.PNG',
          outside = '${dir.path}/Outside.PNG';
      await writeSyntheticPaper(tester, known);
      await writeSyntheticPaper(tester, outside, width: 83);
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => dir.path,
      );
      final previous = FileSelectorPlatform.instance, picker = _DesktopPicker();
      FileSelectorPlatform.instance = picker;
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      await tester.runAsync(() async {
        await library.initialize();
        await library.selectRoot(root.path, metadataOnly: true);
      });
      final entry = library.snapshot!.availableEntries.single;
      final expected = PageKey(
        entryId: entry.id,
        revisionId: entry.currentRevisionId,
        pageNumber: 1,
      );
      await tester.runAsync(() async {
        final store = await ReaderStateStore.open(
          statePath: '${library.dataDirectory.path}/reader-state.json',
        );
        await store.addStroke(
          expected,
          style: StrokeStyle(
            tool: AnnotationTool.pen,
            argb: 0xff0000ff,
            widthFraction: .02,
          ),
          points: [NormalizedPoint(.2, .2)],
        );
      });
      try {
        await tester.pumpWidget(
          ScoreReaderApp(initialPath: known, libraryController: library),
        );
        await desktopUntil(
          tester,
          () => find.byType(LibraryReaderScreen).evaluate().isNotEmpty,
        );
        LibraryReaderScreen reader() => tester.widget<LibraryReaderScreen>(
          find.byType(LibraryReaderScreen),
        );
        await desktopUntil(
          tester,
          () =>
              reader().workspace.store.readingPosition(expected.document) !=
              null,
        );
        expect(reader().initialTarget.entryId, entry.id);
        expect(reader().allowAnnotations, isTrue);
        expect(
          reader().workspace.store.snapshot.strokesFor(expected),
          hasLength(1),
        );
        expect(find.byType(DesktopReaderShell), findsOneWidget);
        expect(find.byType(ReaderScreen), findsNothing);
        await tester.tap(find.byTooltip('返回目录'));
        await desktopSettle(tester);
        picker.path = known;
        await tester.tap(find.byTooltip('打开单份曲谱'));
        await desktopUntil(
          tester,
          () => find.byType(LibraryReaderScreen).evaluate().isNotEmpty,
        );
        expect(reader().initialTarget.entryId, entry.id);
        expect(
          reader().workspace.store.snapshot.strokesFor(expected),
          hasLength(1),
        );
        await tester.tap(find.byTooltip('返回目录'));
        await desktopSettle(tester);
        picker.path = outside;
        await tester.tap(find.byTooltip('打开单份曲谱'));
        await desktopUntil(
          tester,
          () =>
              find.byType(LibraryReaderScreen).evaluate().isNotEmpty &&
              !reader().allowAnnotations,
        );
        await desktopSettle(tester);
        expect(find.byType(DesktopReaderShell), findsOneWidget);
        expect(find.byType(ReaderScreen), findsNothing);
        expect(find.widgetWithText(OutlinedButton, '批注'), findsNothing);
        expect(
          reader().workspace.store.readingPosition(reader().initialTarget.key),
          isNull,
        );
        expect(
          reader().workspace.store.snapshot.strokesFor(expected),
          hasLength(1),
        );
        expect(
          reader().workspace.store.snapshot.annotations.keys.every(
            (key) => key.entryId == expected.entryId,
          ),
          isTrue,
        );
        expect(
          library.snapshot!.entries,
          hasLength(1),
          reason: 'external reading does not register a virtual source',
        );
        expect(
          readerRouteVisibility.isVisible(
            ModalRoute.of(tester.element(find.byType(LibraryReaderScreen))),
          ),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await desktopSettle(tester);
        library.dispose();
        FileSelectorPlatform.instance = previous;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        );
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
