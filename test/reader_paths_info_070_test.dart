import 'package:crypto/crypto.dart';
import 'package:library_sync/library_sync.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/offline_library_screen.dart';

import 'reader_fixture.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/score_path_label.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/reader/set_lists_screen.dart';
import 'package:score_reader/reader/raster_plan.dart';

import 'reader_color_070_test.dart' show setup, mount, until, flush;

void main() {
  test('parent path labels support Windows and POSIX without changing full score identity or matching path', () {
    expect(scoreParentFolder('root.png'), '谱库根目录');
    expect(scoreParentFolder('Band/Live/Girl.png'), 'Band/Live');
    expect(scoreParentFolder(r'Band\Live\Girl.png'), 'Band/Live');
    expect(scoreParentFolder(r'C:\Music\Band\Girl.png'), 'C:/Music/Band');
    final target = ScoreTarget(
      entryId: 'e',
      revisionId: 'r',
      filePath: 'synthetic',
      displayPath: r'C:\Music\root.png',
      parentFolderLabel: scoreParentFolder('root.png'),
    );
    expect(target.parentFolderLabel, '谱库根目录');
    expect(target.displayPath, contains('root.png'));
  });
  test('native ceiling preserves every original pixel at DPR2 fit and zoom while large-source decode remains bounded', () {
    for (final source in [const Size(870, 760), const Size(902, 720)]) {
      for (final view in [const Size(810, 1080), const Size(1080, 810)]) {
        final paper = applyBoxFit(BoxFit.contain, source, view).destination;
        for (final zoom in [1.0, 2.0, 4.0]) {
          expect(
            planImageDecode(
              source: source,
              paper: paper,
              devicePixelRatio: 2,
              zoom: zoom,
            ),
            source,
          );
        }
      }
    }
    final large = planImageDecode(
      source: const Size(10000, 14000),
      paper: const Size(500, 700),
      devicePixelRatio: 2,
      zoom: 4,
    );
    expect(large.width * large.height, lessThanOrEqualTo(12000000));
    expect(large.longestSide, lessThanOrEqualTo(8192));
  });
  testWidgets(
    'set-list detail and add/search rows show only parent folders while retaining filename search',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('parent-labels-'),
      ))!;
      final workspace = (await tester.runAsync(
        () async => ReaderWorkspace(
          await ReaderStateStore.open(statePath: '${dir.path}/s.json'),
        ),
      ))!;
      late ScoreSetList list;
      await tester.runAsync(() async {
        list = await workspace.store.createSetList('set');
        await workspace.store.addItem(list.id, 'a');
        await workspace.store.addItem(list.id, 'b');
      });
      final targets = [
        ScoreTarget(
          entryId: 'a',
          revisionId: 'r',
          filePath: 'synthetic',
          displayPath: 'root.png',
        ),
        ScoreTarget(
          entryId: 'b',
          revisionId: 'r',
          filePath: 'synthetic',
          displayPath: 'Band/nested.png',
        ),
      ];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SetListsScreen(
              workspace: workspace,
              locate: (id) => targets.firstWhere((t) => t.entryId == id),
              targets: () => targets,
            ),
          ),
        );
        await tester.tap(find.text('set'));
        await tester.pumpAndSettle();
        expect(find.text('谱库根目录'), findsOneWidget);
        expect(find.text('Band'), findsOneWidget);
        expect(find.text('Band/nested.png'), findsNothing);
        await tester.tap(find.text('添加曲谱'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'nested.png');
        await tester.pump();
        expect(find.text('nested.png'), findsWidgets);
        expect(find.text('Band'), findsWidgets);
        expect(find.text('Band/nested.png'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'Windows and offline root/search list subtitles contain parent folders only; directory rows retain their directory path',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('actual-path-rows-'),
      ))!;
      final scores = Directory('${dir.path}/scores'),
          data = Directory('${dir.path}/data');
      await tester.runAsync(
        () => Directory('${scores.path}/Band').create(recursive: true),
      );
      await writeSyntheticPaper(tester, '${scores.path}/root.png');
      await writeSyntheticPaper(tester, '${scores.path}/Band/nested.png');
      final library = LibraryController(
        dataDirectory: data,
        watchSource: false,
      );
      final workspace = (await tester.runAsync(
        () async => ReaderWorkspace(
          await ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ),
      ))!;
      SyncController? sync;
      try {
        await tester.runAsync(() async {
          await library.initialize();
          await library.selectRoot(scores.path);
        });
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: LibraryScreen(
                controller: library,
                readerWorkspace: workspace,
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await until(tester, () => find.text('root').evaluate().isNotEmpty);
        expect(find.text('scores · 谱库根目录'), findsOneWidget);
        expect(find.text('Band'), findsWidgets);
        await tester.enterText(find.byType(TextField).first, 'nested.png');
        await tester.pump();
        expect(find.text('nested'), findsOneWidget);
        expect(find.text('scores · Band'), findsOneWidget);
        expect(find.text('Band/nested.png'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        sync = SyncController(library: library, workspace: workspace);
        await tester.runAsync(sync.initialize);
        final bytes = (await tester.runAsync(
          () => File('${scores.path}/root.png').readAsBytes(),
        ))!;
        final entries = [
          for (final item in [('a', 'root.png'), ('b', 'Band/nested.png')])
            ManifestEntry(
              entryId: item.$1,
              revisionId: 'r',
              relativePath: item.$2,
              hash: sha256.convert(bytes).toString(),
              length: bytes.length,
              format: 'png',
              missing: false,
            ),
        ];
        await tester.runAsync(() async {
          for (final entry in entries) {
            await sync!.replica!.receiveObject(entry, Stream.value(bytes));
          }
          await sync!.replica!.commitManifest(
            SyncManifest(
              libraryId: 'synthetic',
              entries: entries,
              folders: ['', 'Band'],
            ),
          );
        });
        await tester.pumpWidget(
          MaterialApp(home: OfflineLibraryScreen(controller: sync)),
        );
        expect(find.text('root'), findsOneWidget);
        expect(find.textContaining('原谱库 · 谱库根目录'), findsOneWidget);
        expect(find.text('Band'), findsWidgets);
        await tester.enterText(find.byType(TextField).first, 'nested.png');
        await tester.pump();
        expect(find.text('nested'), findsOneWidget);
        expect(find.textContaining('原谱库 · Band'), findsOneWidget);
        expect(find.text('Band/nested.png'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync?.dispose();
        await flush(tester, workspace);
        workspace.dispose();
        library.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'image information copies only current display data and the existing short file fingerprint',
    (tester) async {
      final (dir, workspace, base) = await setup(tester);
      final target = ScoreTarget(
        entryId: base.entryId,
        revisionId: base.revisionId,
        filePath: base.filePath,
        displayPath: 'private-name-not-for-copy.png',
        contentHash:
            'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      try {
        await mount(tester, workspace, target);
        expect(find.textContaining('实际载入：'), findsNothing);
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('图片信息'));
        await tester.pumpAndSettle();
        expect(find.textContaining('源图：640×800'), findsOneWidget);
        await tester.tap(find.text('复制显示数据'));
        await tester.pump();
        expect(copied, contains('abcdef012345'));
        expect(copied, contains('实际载入：640×800'));
        expect(copied, contains('DPR：'));
        expect(copied, isNot(contains('private-name')));
        expect(copied, isNot(contains(dir.path)));
        expect(copied, isNot(contains('6789abcdef')));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flush(tester, workspace);
        workspace.dispose();
        await tester.binding.setSurfaceSize(null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
