import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/directory_navigation.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/library/library_widgets.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';

class _CountRefresh extends SyncController {
  _CountRefresh({required super.library, required super.workspace});
  int refreshes = 0;
  @override
  bool get paired => true;
  @override
  Future<void> synchronize({Set<String>? onlyEntryIds}) async {
    refreshes++;
    phase = SyncPhase.complete;
  }
}

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 600 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue);
  await tester.pump();
}

void main() {
  testWidgets(
    'directory magnifier expands only the header, closes to same folder, keeps scope and has full 48px parent and direct refresh at supported minimum sizes',
    (tester) async {
      final ipad = defaultTargetPlatform == TargetPlatform.iOS;
      // Approved v2.1 §3.1: iPad W>=640; Windows client >=720x560.
      await tester.binding.setSurfaceSize(
        ipad ? const Size(640, 844) : const Size(720, 560),
      );
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('directory-nav-084-'),
      ))!;
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      _CountRefresh? sync;
      try {
        await tester.runAsync(() async {
          await library.initialize();
          if (!ipad) {
            for (final relative in [
              'One/Gig/Nested/Blue First.png',
              'One/Different/Blue Elsewhere.png',
              'Two/Blue OtherSource.png',
            ]) {
              final file = File('${dir.path}/$relative');
              await file.parent.create(recursive: true);
              await file.writeAsString('synthetic metadata only');
            }
            await library.addSource('${dir.path}/One');
            while (library.scanning) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            final source = library.selectedSourceId;
            await library.addSource('${dir.path}/Two');
            while (library.scanning) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            library.setSource(source);
            library.setFolder('Gig/Nested');
          } else {
            sync = _CountRefresh(library: library, workspace: workspace);
            await sync!.initialize();
            await sync!.collection!.updateIndex(
              CollectionIndex(
                id: 'demo',
                sources: const [
                  LibrarySourceInfo('one', 'One'),
                  LibrarySourceInfo('two', 'Two'),
                ],
                folders: const {
                  'one': ['', 'Gig', 'Gig/Nested', 'Different'],
                  'two': [''],
                },
                entries: [
                  CatalogItem(
                    sourceId: 'one',
                    entryId: 'first',
                    revisionId: 'r',
                    relativePath: 'Gig/Nested/Blue First.png',
                    length: 100,
                    format: 'png',
                  ),
                  CatalogItem(
                    sourceId: 'one',
                    entryId: 'elsewhere',
                    revisionId: 'r',
                    relativePath: 'Different/Blue Elsewhere.png',
                    length: 100,
                    format: 'png',
                  ),
                  CatalogItem(
                    sourceId: 'two',
                    entryId: 'other',
                    revisionId: 'r',
                    relativePath: 'Blue OtherSource.png',
                    length: 100,
                    format: 'png',
                  ),
                ],
              ),
            );
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: ipad
                ? OfflineLibraryScreen(controller: sync!, isHome: true)
                : LibraryScreen(
                    controller: library,
                    readerWorkspace: workspace,
                  ),
          ),
        );
        await tester.pumpAndSettle();
        if (ipad) {
          await tester.tap(find.text('Gig').first);
          await tester.pump();
          await tester.tap(find.text('Nested'));
          await tester.pump();
        }
        expect(find.byType(TextField), findsNothing);
        expect(find.textContaining('份可读离线曲谱'), findsNothing);
        expect(find.textContaining('已离线 '), findsNothing);
        final parent = find.byKey(const ValueKey('directory-parent-button'));
        expect(tester.getSize(parent).height, 48);
        String currentCrumb() => tester
            .widget<Text>(
              find.byKey(const ValueKey('directory-breadcrumb-current')),
            )
            .data!;
        expect(currentCrumb(), 'Nested');
        expect(
          find.byKey(const ValueKey('directory-breadcrumb-Gig')),
          findsOneWidget,
        );
        if (ipad) {
          // ba4cfc6 moved this direct synchronization action to navigation.
          await tester.tap(find.byTooltip('打开来源'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('立即同步'));
          await tester.pump();
          expect(sync!.refreshes, 1);
          expect(
            find.byType(SyncScreen),
            findsNothing,
            reason: 'refresh updates directly',
          );
          await tester.tapAt(const Offset(630, 600));
          await tester.pumpAndSettle();
        } else {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        }
        if (ipad) {
          await tester.tap(find.byTooltip('搜索'));
          await tester.pump();
        }
        expect(find.byType(DirectorySearchField), findsOneWidget);
        expect(
          find.descendant(
            of: find.byWidgetPredicate((w) => w is SizedBox && w.height == 56),
            matching: find.byType(TextField),
          ),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Blue');
        await tester.pump();
        Finder result(String title) => find.text(title, findRichText: true);
        expect(result('Blue First'), findsOneWidget);
        expect(result('Blue Elsewhere'), findsOneWidget);
        expect(result('Blue OtherSource'), findsOneWidget);
        await tester.tap(find.byTooltip('搜索范围'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckedPopupMenuItem<bool>));
        await tester.pumpAndSettle();
        await tester.pump();
        expect(result('Blue First'), findsOneWidget);
        expect(result('Blue Elsewhere'), findsNothing);
        expect(result('Blue OtherSource'), findsNothing);
        await tester.tap(find.byTooltip('关闭搜索'));
        await tester.pump();
        expect(find.byType(TextField), findsNothing);
        expect(currentCrumb(), 'Nested');
        expect(
          find.byKey(const ValueKey('directory-breadcrumb-Gig')),
          findsOneWidget,
        );
        if (!ipad) {
          expect(library.currentFolder, 'Gig/Nested');
          expect(library.query, isEmpty);
        }
        await tester.tap(parent);
        await tester.pump();
        expect(currentCrumb(), 'Gig');
        if (!ipad) {
          expect(library.currentFolder, 'Gig');
          await tester.tap(find.byTooltip('打开来源'));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byTooltip('曲库操作'),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(LibrarySidebar),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(find.byTooltip('曲库操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('刷新谱库'));
          await until(tester, () => !library.scanning);
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'supported minimum layout must not overflow',
        );
        debugPrint(
          'DIRECTORY_UI_084 platform=${ipad ? 'iPad' : 'Windows'} header_search_only=true full_parent48=true scope_cross_source_preserved=true close_restores_folder=true direct_refresh=true supported_minimum_no_overflow=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync?.dispose();
        workspace.dispose();
        library.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.iOS,
    }),
  );
}
