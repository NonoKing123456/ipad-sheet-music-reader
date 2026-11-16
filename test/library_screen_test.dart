import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/library/library_widgets.dart';
import 'package:score_reader/main.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:reader_state/reader_state.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 650 && !ready(); attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(
    ready(),
    isTrue,
    reason: 'bounded library initialization and persistence',
  );
  await tester.pump();
}

void main() {
  test('launch options isolate state without treating flags as a score', () {
    final absolute = p.join(Directory.systemTemp.path, 'qa-state');
    final options = LaunchOptions.parse(['--data-dir', absolute, 'score.pdf']);
    expect(options.initialPath, 'score.pdf');
    expect(options.dataDirectory!.path, absolute);
    final ipad = LaunchOptions.parse([
      '--simulate-ipad',
      '--data-dir',
      absolute,
    ]);
    expect(ipad.simulateIpad, isTrue);
    expect(ipad.initialPath, isNull);
    expect(LaunchOptions.parse([]).simulateIpad, isFalse);
    expect(() => LaunchOptions.parse(['--data-dir']), throwsFormatException);
    expect(
      () => LaunchOptions.parse(['--data-dir', 'relative']),
      throwsFormatException,
    );
  });

  testWidgets(
    'search distinguishes identical names and reader receives stable IDs',
    (tester) async {
      debugPrint('LIBRARY_SMOKE_STAGE start');
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('score-library-ui-'),
      ))!;
      debugPrint('LIBRARY_SMOKE_STAGE temp_created');
      final source = Directory(p.join(temporary.path, 'source'));
      for (final folder in ['老师整理', '演出版本']) {
        final file = File(p.join(source.path, folder, '同名谱.png'));
        await tester.runAsync(() async {
          await file.parent.create(recursive: true);
          await file.writeAsString('test-only-image');
        });
      }
      debugPrint('LIBRARY_SMOKE_STAGE score_files_created');
      final controller = LibraryController(
        dataDirectory: Directory(p.join(temporary.path, 'state')),
        watchSource: false,
      );
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.selectRoot(source.path);
      });
      debugPrint('LIBRARY_SMOKE_STAGE catalog_initialized');
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(
            statePath: p.join(temporary.path, 'reader-state.json'),
          ),
        ))!,
      );
      debugPrint('LIBRARY_SMOKE_STAGE workspace_opened');
      await tester.runAsync(() => workspace.store.createSetList('浏览加入'));
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            controller: controller,
            readerWorkspace: workspace,
          ),
        ),
      );
      debugPrint('LIBRARY_SMOKE_STAGE library_pumped');
      await _until(tester, () => find.byTooltip('搜索').evaluate().isNotEmpty);
      debugPrint('LIBRARY_SMOKE_STAGE library_settled');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '同名谱');
      debugPrint('LIBRARY_SMOKE_STAGE search_entered');
      final scoreTitles = find.descendant(
        of: find.byType(LibraryFileRow),
        matching: find.text('同名谱', findRichText: true),
      );
      await _until(tester, () => scoreTitles.evaluate().length == 2);
      debugPrint('LIBRARY_SMOKE_STAGE search_settled');
      for (final folder in ['老师整理', '演出版本']) {
        expect(find.textContaining(' / $folder'), findsOneWidget);
      }
      final selected = controller.visibleEntries.first;
      expect(find.byTooltip('曲谱选项'), findsNWidgets(2));
      await tester.tap(find.byTooltip('曲谱选项').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入曲单'));
      await _until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      expect(find.byType(LibraryReaderScreen), findsNothing);
      await tester.tap(find.text('浏览加入'));
      await tester.pump();
      await tester.tap(find.text('加入所选曲单'));
      await _until(
        tester,
        () => !workspace.saving && find.byType(AlertDialog).evaluate().isEmpty,
      );
      expect(
        workspace
            .store
            .snapshot
            .activeSetLists
            .single
            .activeItems
            .single
            .entryId,
        selected.id,
      );
      expect(find.byType(LibraryReaderScreen), findsNothing);
      await tester.tap(scoreTitles.first);
      debugPrint('LIBRARY_SMOKE_STAGE score_tapped');
      await _until(
        tester,
        () => find.byType(LibraryReaderScreen).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 350));
      debugPrint('LIBRARY_SMOKE_STAGE reader_pumped');
      final reader = tester.widget<LibraryReaderScreen>(
        find.byType(LibraryReaderScreen),
      );
      expect(reader.initialTarget.entryId, selected.id);
      expect(reader.initialTarget.revisionId, selected.currentRevisionId);
      expect(
        reader.initialTarget.filePath,
        controller.absolutePathFor(selected),
      );
      await tester.pumpWidget(const SizedBox());
      debugPrint('LIBRARY_SMOKE_STAGE reader_removed');
      // Let unmounted reader loads and native file handles finish in real time.
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.runAsync(() async {
        await workspace.flushPositions();
        await workspace.waitForAnnotationWrites();
      });
      await _until(tester, () => !workspace.saving);
      debugPrint('LIBRARY_SMOKE_STAGE reader_settled_after_remove');
      controller.dispose();
      workspace.dispose();
      debugPrint('LIBRARY_SMOKE_STAGE controllers_disposed');
      await tester.runAsync(() async {
        final cleanup = Stopwatch()..start();
        while (true) {
          try {
            await temporary.delete(recursive: true);
            break;
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 32 ||
                cleanup.elapsed >= const Duration(seconds: 2)) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
      });
      debugPrint('LIBRARY_SMOKE_STAGE temp_deleted');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
