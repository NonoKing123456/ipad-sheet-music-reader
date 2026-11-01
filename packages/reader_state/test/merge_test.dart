import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:test/test.dart';

final page = PageKey(entryId: 'entry', revisionId: 'revision', pageNumber: 1);
final now = DateTime.utc(2026);
final style = StrokeStyle(
    tool: AnnotationTool.pen, argb: 0xff000000, widthFraction: .003);
AnnotationStroke stroke(String id,
        {double x = .1, bool deleted = false, int version = 1}) =>
    AnnotationStroke(
        id: id,
        style: style,
        points: [NormalizedPoint(x, .2)],
        createdUtc: now,
        updatedUtc: now.add(Duration(days: version)),
        version: version,
        deletedUtc: deleted ? now : null);
SetListItem item(String id, {bool removed = false}) => SetListItem(
    id: id,
    entryId: 'entry-$id',
    createdUtc: now,
    updatedUtc: now,
    version: 1,
    removedUtc: removed ? now : null);
ScoreSetList list(String name, List<String> ids, {bool deleted = false}) =>
    ScoreSetList(
        id: 'list',
        name: name,
        items: ids.map(item).toList(),
        createdUtc: now,
        updatedUtc: now,
        version: 1,
        deletedUtc: deleted ? now : null);
ReaderSnapshot snap(
        {List<AnnotationStroke> strokes = const [], ScoreSetList? setList}) =>
    ReaderSnapshot(
        generation: 0,
        pages: {page: strokes},
        setLists: [if (setList != null) setList],
        bookmarks: {});
ReaderMergeResult merge(ReaderSnapshot b, ReaderSnapshot l, ReaderSnapshot r) =>
    mergeReaderSnapshots(base: b, local: l, remote: r, peerId: 'peer');

void main() {
  test(
      'schema 1 migrates without dropping marks and schema 2 persists conflicts',
      () async {
    final dir = await Directory.systemTemp.createTemp('reader-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final original = ReaderSnapshot(generation: 7, pages: {
      page: [stroke('original'), stroke('erased', deleted: true)]
    }, setLists: [
      ScoreSetList(
          id: 'legacy-list',
          name: 'legacy',
          items: [item('removed', removed: true), item('live')],
          createdUtc: now,
          updatedUtc: now,
          version: 2)
    ], bookmarks: {
      page.document: ReadingBookmark(
          document: page.document, pageNumber: 2, pageCount: 3, updatedUtc: now)
    });
    final json = original.toJson()..['schemaVersion'] = 1;
    json.remove('conflicts');
    json.remove('mergeReceipts');
    final path = p.join(dir.path, 'reader.json');
    await File(path).writeAsString(jsonEncode(json));
    final store = await ReaderStateStore.open(statePath: path);
    expect(store.snapshot.strokesFor(page).single.id, 'original');
    await store.mergeFromPeer(
        base: original,
        remote: snap(strokes: [stroke('remote')]),
        peerId: 'peer');
    final saved = jsonDecode(await File(path).readAsString()) as Map;
    expect(saved['schemaVersion'], 2);
    final reopened = (await ReaderStateStore.open(statePath: path)).snapshot;
    expect(reopened.strokesFor(page), hasLength(2));
    expect(reopened.strokesFor(page, includeDeleted: true), hasLength(3));
    expect(reopened.setLists.single.activeItems.single.id, 'live');
    expect(reopened.setLists.single.items.first.isRemoved, isTrue);
    expect(reopened.bookmarkFor(page.document)!.pageNumber, 2);
  });
  test('independent strokes union; absent records never erase', () {
    final b = snap(strokes: [stroke('base')]);
    final result = merge(b, snap(strokes: [stroke('base'), stroke('local')]),
        snap(strokes: [stroke('remote')]));
    expect(result.snapshot.strokesFor(page).map((x) => x.id),
        ['base', 'local', 'remote']);
    expect(result.conflicts, isEmpty);
  });
  test('tombstone wins an unchanged side and remains addressable', () {
    final b = snap(strokes: [stroke('a')]);
    final result =
        merge(b, b, snap(strokes: [stroke('a', deleted: true, version: 2)]));
    expect(result.snapshot.strokesFor(page), isEmpty);
    expect(
        result.snapshot.strokesFor(page, includeDeleted: true).single.isDeleted,
        isTrue);
    expect(result.conflicts, isEmpty);
  });
  test('metadata-only differences are not semantic conflicts', () {
    final result = merge(
        snap(strokes: [stroke('a')]),
        snap(strokes: [stroke('a', version: 2)]),
        snap(strokes: [stroke('a', version: 30)]));
    expect(result.conflicts, isEmpty);
  });
  test(
      'same stroke conflict keeps complete variants and deterministic durable identity',
      () {
    final b = snap(strokes: [stroke('a')]);
    final l = snap(strokes: [stroke('a', x: .3)]),
        r = snap(strokes: [stroke('a', x: .8)]);
    final result = merge(b, l, r);
    expect(result.conflicts, hasLength(1));
    final conflict = result.conflicts.single;
    expect(() => (conflict.first['points'] as List).clear(),
        throwsUnsupportedError);
    expect({
      AnnotationStroke.fromJson(Map<String, dynamic>.from(conflict.first))
          .points
          .single
          .x,
      AnnotationStroke.fromJson(Map<String, dynamic>.from(conflict.second))
          .points
          .single
          .x
    }, {
      .3,
      .8
    });
    expect(merge(b, r, l).conflicts.single.id, conflict.id);
    final restored = ReaderSnapshot.fromJson(
        Map<String, dynamic>.from(result.snapshot.toJson()));
    expect(restored.conflicts.single.id, conflict.id);
    expect(merge(b, restored, r).conflicts.map((c) => c.id).toSet(),
        {conflict.id});
  });
  test(
      'simultaneous list rename and reorder preserve full variants and all live items',
      () {
    final b = snap(setList: list('original', ['a', 'b', 'c']));
    final l = snap(setList: list('left', ['c', 'a', 'b', 'left-new']));
    final r = snap(setList: list('right', ['b', 'c', 'a', 'right-new']));
    final result = merge(b, l, r);
    expect(result.conflicts.where((c) => c.kind == 'setList'), hasLength(1));
    final conflict = result.conflicts.single;
    final variants = [conflict.first, conflict.second]
        .map((j) => ScoreSetList.fromJson(Map<String, dynamic>.from(j)))
        .toList();
    expect(variants.map((v) => v.name).toSet(), {'left', 'right'});
    expect(variants.map((v) => v.items.first.id).toSet(), {'b', 'c'});
    expect(result.snapshot.setLists.single.activeItems.map((i) => i.id).toSet(),
        {'a', 'b', 'c', 'left-new', 'right-new'});
    expect(
        canonicalReaderJson(merge(b, r, l).snapshot.setLists.single.toJson()),
        canonicalReaderJson(result.snapshot.setLists.single.toJson()));
  });
  test('independent append and name/order edits merge without false conflict',
      () {
    final b = snap(setList: list('original', ['a', 'b']));
    final result = merge(b, snap(setList: list('renamed', ['a', 'b', 'x'])),
        snap(setList: list('original', ['b', 'a', 'y'])));
    expect(result.conflicts, isEmpty);
    expect(result.snapshot.setLists.single.name, 'renamed');
    expect(result.snapshot.setLists.single.items.map((i) => i.id),
        ['b', 'a', 'y', 'x']);
  });
  test(
      'item tombstone and absent item differ; duplicate song IDs stay separate',
      () {
    final b = snap(setList: list('name', ['a', 'b']));
    final rList = b.setLists.single;
    final removed = ScoreSetList(
        id: rList.id,
        name: rList.name,
        items: [item('a', removed: true), item('b')],
        createdUtc: now,
        updatedUtc: now,
        version: 2);
    final result = merge(b, snap(setList: list('name', ['a', 'b', 'c'])),
        snap(setList: removed));
    expect(result.snapshot.setLists.single.activeItems.map((i) => i.id),
        ['b', 'c']);
    expect(result.snapshot.setLists.single.items, hasLength(3));
  });
  test('delete versus concurrent list edits retains recoverable variants', () {
    final b = snap(setList: list('name', ['a']));
    final result = merge(b, snap(setList: list('name', ['a'], deleted: true)),
        snap(setList: list('changed', ['a', 'b'])));
    expect(result.conflicts.single.kind, 'setList');
    expect(result.snapshot.setLists.single.items.map((x) => x.id).toSet(),
        {'a', 'b'});
  });
  test(
      'merge runs after queued local edits; receipts prevent replay overwriting later edits',
      () async {
    final dir = await Directory.systemTemp.createTemp('reader-merge-queue-');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'reader.json');
    final store = await ReaderStateStore.open(statePath: path);
    final add =
        store.addStroke(page, style: style, points: [NormalizedPoint(.2, .3)]);
    final merging = store.mergeFromPeer(
        base: ReaderSnapshot.empty(),
        remote: snap(strokes: [stroke('remote')]),
        peerId: 'peer',
        operationId: 'request');
    await add;
    await merging;
    expect(store.snapshot.strokesFor(page), hasLength(2));
    final localList = await store.createSetList('after');
    await store.renameSetList(localList.id, 'newer');
    final reopened = await ReaderStateStore.open(statePath: path);
    final generation = reopened.snapshot.generation;
    await reopened.mergeFromPeer(
        base: ReaderSnapshot.empty(),
        remote: ReaderSnapshot.empty(),
        peerId: 'peer',
        operationId: 'request');
    expect(reopened.snapshot.generation, generation);
    expect(reopened.snapshot.setListById(localList.id)!.name, 'newer');
  });
}
