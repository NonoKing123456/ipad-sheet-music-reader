import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';

import 'offline_presentation_test.dart' show CountIo;

class _CountedItems extends ListBase<CatalogItem> {
  _CountedItems(this.items);
  final List<CatalogItem> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('fixed');
  @override
  CatalogItem operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, CatalogItem value) =>
      throw UnsupportedError('fixed');
}

void main() {
  testWidgets(
    'folder/source icons and download buttons follow none partial all removal and pending update from one cached ancestor summary',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 810));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('folders-082-'),
      ))!;
      final library = LibraryController(dataDirectory: dir, watchSource: false);
      await tester.runAsync(library.initialize);
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
      ))!;
      final workspace = ReaderWorkspace(store),
          sync = SyncController(
            library: library,
            workspace: ReaderWorkspace(store),
          );
      // Use one real workspace owner for the screen and controller.
      workspace.dispose();
      await tester.runAsync(sync.initialize);
      final bytes = utf8.encode('synthetic offline bytes');
      CatalogItem item(String id, String source, String path) => CatalogItem(
        sourceId: source,
        entryId: id,
        revisionId: 'r1',
        relativePath: path,
        length: bytes.length,
        hash: sha256.convert(bytes).toString(),
        format: 'png',
      );
      final a = item('a', 'A', 'foo/a.PNG'),
          b = item('b', 'A', 'foo/sub/b.PNG'),
          c = item('c', 'A', 'foobar/c.PNG'),
          d = item('d', 'B', 'foo/d.PNG');
      final entries = _CountedItems([a, b, c, d]);
      final index = CollectionIndex(
        id: 'synthetic-082',
        sources: const [
          LibrarySourceInfo('A', 'Source A'),
          LibrarySourceInfo('B', 'Source B'),
        ],
        entries: entries,
        folders: {
          'A': ['', 'foo', 'foo/sub', 'foobar', 'empty'],
          'B': ['', 'foo'],
        },
      );
      Future<void> refresh() async {
        sync.workspace.refreshFromStore(force: true);
        await tester.pump();
      }

      Future<void> receive(CatalogItem value) async {
        await tester.runAsync(() async {
          await sync.replica!.receiveObject(value.object, Stream.value(bytes));
          await sync.collection!.refreshReady();
        });
        await refresh();
      }

      Finder row(String folder) => find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.subtitle is Text &&
            (w.subtitle! as Text).data == folder,
      );
      Finder source(String name) => find.byWidgetPredicate(
        (w) =>
            w is ListTile && w.title is Text && (w.title! as Text).data == name,
      );
      void state(
        String sourceId,
        String folder,
        int total,
        int ready,
        int readable,
        int pending,
      ) {
        final value = sync.folderOfflineStatus(
          sourceId: sourceId,
          folder: folder,
        );
        expect(
          [
            value.total,
            value.currentReady,
            value.readable,
            value.pendingUpdate,
          ],
          [total, ready, readable, pending],
        );
      }

      try {
        await tester.runAsync(() => sync.collection!.updateIndex(index));
        entries.reads = 0;
        state('A', 'foo', 2, 0, 0, 0);
        expect(entries.reads, lessThanOrEqualTo(entries.length * 3));
        final afterBuild = entries.reads, io = CountIo();
        IOOverrides.runWithIOOverrides(() {
          for (var i = 0; i < 50; i++) {
            state('A', 'foo', 2, 0, 0, 0);
            state('A', 'foobar', 1, 0, 0, 0);
            state('B', 'foo', 1, 0, 0, 0);
          }
        }, io);
        expect(entries.reads, afterBuild);
        expect(io.types, 0);
        expect(io.stats, 0);
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineLibraryScreen(controller: sync, isHome: true),
          ),
        );
        expect(find.byTooltip('全部未下载 · 0 / 3 份'), findsWidgets);
        expect(tester.widget<ListTile>(row('foo')).trailing, isNotNull);
        expect(tester.widget<ListTile>(row('empty')).trailing, isNull);
        expect(find.byTooltip('空文件夹'), findsWidgets);
        await receive(a);
        state('A', '', 3, 1, 1, 0);
        state('A', 'foo', 2, 1, 1, 0);
        state('A', 'foobar', 1, 0, 0, 0);
        state('B', 'foo', 1, 0, 0, 0);
        expect(find.byTooltip('部分已下载 · 1 / 2 份'), findsWidgets);
        await receive(b);
        expect(tester.widget<ListTile>(row('foo')).trailing, isNull);
        expect(tester.widget<ListTile>(row('foobar')).trailing, isNotNull);
        await tester.tap(row('foo'));
        await tester.pump();
        expect(find.text('下载此文件夹'), findsNothing);
        expect(find.byTooltip('全部已下载 · 2 / 2 份'), findsWidgets);
        await tester.tap(find.byTooltip('上一级文件夹'));
        await tester.pump();
        await receive(c);
        expect(tester.widget<ListTile>(source('Source A')).trailing, isNull);
        expect(tester.widget<ListTile>(source('Source B')).trailing, isNotNull);
        expect(find.text('下载整个谱库'), findsNothing);
        expect(find.byTooltip('全部已下载 · 3 / 3 份'), findsWidgets);
        final rules = sync.collection!.selection.toJson().toString();
        await tester.runAsync(() => sync.removeOfflineDownload(a.entryId));
        await refresh();
        state('A', 'foo', 2, 1, 1, 0);
        expect(tester.widget<ListTile>(row('foo')).trailing, isNotNull);
        await receive(a);
        final revised = CatalogItem(
          sourceId: b.sourceId,
          entryId: b.entryId,
          revisionId: 'r2',
          relativePath: b.relativePath,
          length: b.length,
          format: b.format,
        );
        await tester.runAsync(
          () => sync.collection!.updateIndex(index.replacing(revised)),
        );
        await refresh();
        state('A', '', 3, 2, 3, 1);
        state('A', 'foo', 2, 1, 2, 1);
        expect(find.byTooltip('部分已下载 · 2 / 2 份已有离线副本，1 份待更新'), findsWidgets);
        expect(tester.widget<ListTile>(row('foo')).trailing, isNotNull);
        expect(tester.widget<ListTile>(source('Source A')).trailing, isNotNull);
        // Removing a download intentionally changes its selection. Merely reading
        // or hiding the buttons does not mutate those durable rules.
        final afterRemoval = sync.collection!.selection.toJson().toString();
        for (var i = 0; i < 10; i++) {
          sync.folderOfflineStatus(sourceId: 'A');
        }
        expect(sync.collection!.selection.toJson().toString(), afterRemoval);
        expect(rules, isNotEmpty);
        expect(tester.takeException(), isNull);
        debugPrint(
          'FOLDER_082 none->partial->all->remove->pending; source_and_ancestor_icons=true foo_not_foobar=true source_isolation=true cache_rescans=0 sync_fs_checks=0',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync.dispose();
        library.dispose();
        sync.workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
