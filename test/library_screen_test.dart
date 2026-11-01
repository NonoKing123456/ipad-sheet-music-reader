import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/main.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:reader_state/reader_state.dart';

void main() {
  test('launch options isolate state without treating flags as a score', () {
    final absolute = p.join(Directory.systemTemp.path, 'qa-state');
    final options = LaunchOptions.parse(['--data-dir', absolute, 'score.pdf']);
    expect(options.initialPath, 'score.pdf');
    expect(options.dataDirectory!.path, absolute);
    expect(() => LaunchOptions.parse(['--data-dir']), throwsFormatException);
    expect(
      () => LaunchOptions.parse(['--data-dir', 'relative']),
      throwsFormatException,
    );
  });

  testWidgets(
    'search distinguishes identical names and reader receives stable IDs',
    (tester) async {
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('score-library-ui-'),
      ))!;
      final source = Directory(p.join(temporary.path, 'source'));
      for (final folder in ['老师整理', '演出版本']) {
        final file = File(p.join(source.path, folder, '同名谱.png'));
        await tester.runAsync(() async {
          await file.parent.create(recursive: true);
          await file.writeAsString('test-only-image');
        });
      }
      final controller = LibraryController(
        dataDirectory: Directory(p.join(temporary.path, 'state')),
        watchSource: false,
      );
      await tester.runAsync(() async {
        await controller.initialize();
        await controller.selectRoot(source.path);
      });
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(
            statePath: p.join(temporary.path, 'reader-state.json'),
          ),
        ))!,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryScreen(
            controller: controller,
            readerWorkspace: workspace,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '同名谱');
      await tester.pumpAndSettle();
      expect(find.text(p.join(source.path, '老师整理', '同名谱.png')), findsOneWidget);
      expect(find.text(p.join(source.path, '演出版本', '同名谱.png')), findsOneWidget);
      final selected = controller.visibleEntries.first;
      await tester.tap(
        find
            .descendant(of: find.byType(ListTile), matching: find.text('同名谱'))
            .first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
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
      await tester.pumpAndSettle();
      controller.dispose();
      workspace.dispose();
      await tester.runAsync(() => temporary.delete(recursive: true));
    },
  );
}
