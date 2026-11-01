import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late String statePath;
  late ReaderStateStore store;
  final firstPage =
      PageKey(entryId: 'entry-A', revisionId: 'revision-1', pageNumber: 1);
  final secondPage =
      PageKey(entryId: 'entry-A', revisionId: 'revision-1', pageNumber: 2);
  final newRevision =
      PageKey(entryId: 'entry-A', revisionId: 'revision-2', pageNumber: 1);
  final style = StrokeStyle(
      tool: AnnotationTool.pen, argb: 0xff112233, widthFraction: 0.003);

  Future<AnnotationStroke> add(PageKey page, {List<NormalizedPoint>? points}) =>
      store.addStroke(page,
          style: style,
          points: points ?? [NormalizedPoint(0, 0), NormalizedPoint(1, 1)]);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-state-test-');
    statePath = p.join(temporary.path, 'state', 'reader.json');
    store = await ReaderStateStore.open(statePath: statePath);
  });

  tearDown(() async {
    // Only this freshly-created dedicated temporary tree is removed.
    await temporary.delete(recursive: true);
  });

  test('coordinates validate finite page bounds and preserve exact corners',
      () {
    expect(NormalizedPoint(0, 1), NormalizedPoint(0, 1));
    for (final value in [
      -0.01,
      1.01,
      double.nan,
      double.infinity,
      -double.infinity
    ]) {
      expect(() => NormalizedPoint(value, 0.5), throwsArgumentError);
      expect(() => NormalizedPoint(0.5, value), throwsArgumentError);
    }
    expect(() => PageKey(entryId: 'A', revisionId: 'r', pageNumber: 0),
        throwsArgumentError);
    expect(
        () => StrokeStyle(
            tool: AnnotationTool.pen, argb: -1, widthFraction: 0.01),
        throwsArgumentError);
    expect(
        () => StrokeStyle(
            tool: AnnotationTool.pen, argb: 0xffffffff, widthFraction: 0),
        throwsArgumentError);
    expect(
        () => StrokeStyle(
            tool: AnnotationTool.pen,
            argb: 0xffffffff,
            widthFraction: double.nan),
        throwsArgumentError);
  });

  test('one completed stroke makes one commit and supports single-point dots',
      () async {
    final stroke = await add(firstPage, points: [NormalizedPoint(0.5, 0.5)]);
    expect(store.snapshot.generation, 1);
    expect(stroke.points, [NormalizedPoint(0.5, 0.5)]);
    expect(stroke.style.argb, 0xff112233);
    expect(stroke.style.widthFraction, 0.003);
    expect(store.snapshot.strokesFor(firstPage).single.id, stroke.id);
  });

  test('point list is captured before an asynchronous queued save', () async {
    final points = [NormalizedPoint(0.2, 0.3)];
    final saving = add(firstPage, points: points);
    points.add(NormalizedPoint(0.9, 0.9));
    final stroke = await saving;
    expect(stroke.points, [NormalizedPoint(0.2, 0.3)]);
    expect(
        () => stroke.points.add(NormalizedPoint(0, 0)), throwsUnsupportedError);
  });

  test('empty stroke rejects without committing and queue remains usable',
      () async {
    await expectLater(add(firstPage, points: []), throwsArgumentError);
    expect(store.snapshot.generation, 0);
    expect(store.canUndo(firstPage), isFalse);
    await add(firstPage);
    expect(store.snapshot.strokesFor(firstPage), hasLength(1));
  });

  test('page and revision isolate strokes, and old revision survives reopening',
      () async {
    final old = await add(firstPage);
    await add(secondPage);
    await add(newRevision);
    final otherEntry =
        PageKey(entryId: 'entry-B', revisionId: 'revision-1', pageNumber: 1);
    expect(store.snapshot.strokesFor(otherEntry), isEmpty);
    expect(store.snapshot.strokesFor(firstPage).single.id, old.id);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.snapshot.strokesFor(firstPage).single.id, old.id);
    expect(reopened.snapshot.strokesFor(secondPage), hasLength(1));
    expect(reopened.snapshot.strokesFor(newRevision), hasLength(1));
  });

  test('pen and highlighter style survive persistence without pressure data',
      () async {
    final highlighter = StrokeStyle(
        tool: AnnotationTool.highlighter,
        argb: 0x66ffff00,
        widthFraction: 0.03);
    final stroke = await store.addStroke(firstPage,
        style: highlighter,
        points: [NormalizedPoint(0.1, 0.2), NormalizedPoint(0.7, 0.2)]);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    final loaded = reopened.snapshot.strokesFor(firstPage).single;
    expect(loaded.id, stroke.id);
    expect(loaded.style.tool, AnnotationTool.highlighter);
    expect(loaded.style.argb, 0x66ffff00);
    expect(loaded.style.widthFraction, 0.03);
    expect(loaded.points, stroke.points);
  });

  test('add undo and redo preserve stroke ID while updating tombstone version',
      () async {
    final stroke = await add(firstPage);
    expect(store.canUndo(firstPage), isTrue);
    expect(await store.undo(firstPage), isTrue);
    expect(store.snapshot.strokesFor(firstPage), isEmpty);
    final tombstone =
        store.snapshot.strokesFor(firstPage, includeDeleted: true).single;
    expect(tombstone.id, stroke.id);
    expect(tombstone.isDeleted, isTrue);
    expect(tombstone.version, 2);
    expect(store.canRedo(firstPage), isTrue);
    expect(await store.redo(firstPage), isTrue);
    final restored = store.snapshot.strokesFor(firstPage).single;
    expect(restored.id, stroke.id);
    expect(restored.version, 3);
    expect(restored.isDeleted, isFalse);
  });

  test(
      'whole-stroke erase undo/redo and no-op erasure do not affect other strokes',
      () async {
    final first = await add(firstPage);
    final second = await add(firstPage);
    final generation = store.snapshot.generation;
    expect(await store.eraseStroke(firstPage, 'not-there'), isFalse);
    expect(store.snapshot.generation, generation);
    expect(await store.eraseStroke(firstPage, first.id), isTrue);
    expect(store.snapshot.strokesFor(firstPage).single.id, second.id);
    expect(await store.eraseStroke(firstPage, first.id), isFalse);
    expect(await store.undo(firstPage), isTrue);
    expect(store.snapshot.strokesFor(firstPage).map((stroke) => stroke.id),
        [first.id, second.id]);
    expect(await store.redo(firstPage), isTrue);
    expect(store.snapshot.strokesFor(firstPage).single.id, second.id);
  });

  test('undo stacks are page-specific and new edit drops only that redo branch',
      () async {
    final a = await add(firstPage);
    await add(secondPage);
    await store.undo(firstPage);
    expect(store.snapshot.strokesFor(secondPage), hasLength(1));
    expect(store.canRedo(firstPage), isTrue);
    await add(firstPage);
    expect(await store.redo(firstPage), isFalse);
    expect(
        store.snapshot
            .strokesFor(firstPage, includeDeleted: true)
            .firstWhere((stroke) => stroke.id == a.id)
            .isDeleted,
        isTrue);
    expect(await store.undo(secondPage), isTrue);
    expect(store.snapshot.strokesFor(secondPage), isEmpty);
  });

  test(
      'reopen keeps current marks and deletion records but clears session history',
      () async {
    final a = await add(firstPage);
    await add(firstPage);
    await store.eraseStroke(firstPage, a.id);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.snapshot.strokesFor(firstPage), hasLength(1));
    expect(reopened.snapshot.strokesFor(firstPage, includeDeleted: true),
        hasLength(2));
    expect(reopened.canUndo(firstPage), isFalse);
    expect(await reopened.undo(firstPage), isFalse);
    expect(await reopened.redo(firstPage), isFalse);
  });

  test('quick queued additions cannot overwrite each other', () async {
    final futures = List.generate(
        24, (i) => add(firstPage, points: [NormalizedPoint(i / 24, 0.5)]));
    final strokes = await Future.wait(futures);
    expect(store.snapshot.strokesFor(firstPage).map((stroke) => stroke.id),
        strokes.map((stroke) => stroke.id));
    expect(store.snapshot.generation, 24);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.snapshot.strokesFor(firstPage), hasLength(24));
  });

  test('undo immediately queued behind a stroke sees the committed edit',
      () async {
    final adding = add(firstPage);
    final undoing = store.undo(firstPage);
    final stroke = await adding;
    expect(await undoing, isTrue);
    expect(store.snapshot.generation, 2);
    expect(store.snapshot.strokesFor(firstPage), isEmpty);
    expect(store.snapshot.strokesFor(firstPage, includeDeleted: true).single.id,
        stroke.id);
  });

  test(
      'set list duplicates have independent stable item IDs and no source operations',
      () async {
    final list = await store.createSetList('  排练曲单  ');
    expect(list.name, '排练曲单');
    final first = await store.addItem(list.id, 'same-entry');
    final second = await store.addItem(list.id, 'same-entry');
    expect(first.id, isNot(second.id));
    expect(
        store.snapshot
            .setListById(list.id)!
            .activeItems
            .map((item) => item.entryId),
        ['same-entry', 'same-entry']);
    expect(await store.removeItem(list.id, first.id), isTrue);
    expect(
        store.snapshot.setListById(list.id)!.activeItems.single.id, second.id);
    final removed = store.snapshot
        .setListById(list.id)!
        .items
        .firstWhere((item) => item.id == first.id);
    expect(removed.isRemoved, isTrue);
    expect(removed.entryId, 'same-entry');
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.snapshot.setListById(list.id)!.activeItems.single.id,
        second.id);
    expect(reopened.snapshot.setListById(list.id)!.items, hasLength(2));
  });

  test(
      'set list reorder uses final visible index upward/downward and first/last',
      () async {
    final list = await store.createSetList('演出');
    final a = await store.addItem(list.id, 'A');
    final b = await store.addItem(list.id, 'B');
    final c = await store.addItem(list.id, 'C');
    final d = await store.addItem(list.id, 'D');
    List<String> order() => store.snapshot
        .setListById(list.id)!
        .activeItems
        .map((item) => item.entryId)
        .toList();
    await store.reorderItem(list.id, a.id, 3);
    expect(order(), ['B', 'C', 'D', 'A']);
    await store.reorderItem(list.id, a.id, 0);
    expect(order(), ['A', 'B', 'C', 'D']);
    await store.reorderItem(list.id, c.id, 1);
    expect(order(), ['A', 'C', 'B', 'D']);
    await store.removeItem(list.id, c.id);
    await store.reorderItem(list.id, d.id, 0);
    expect(order(), ['D', 'A', 'B']);
    final generation = store.snapshot.generation;
    await store.reorderItem(list.id, b.id, 2);
    expect(store.snapshot.generation, generation);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(
        reopened.snapshot
            .setListById(list.id)!
            .activeItems
            .map((item) => item.id),
        [d.id, a.id, b.id]);
  });

  test(
      'invalid reorder/name fails without losing state and later actions succeed',
      () async {
    final list = await store.createSetList('演出');
    final item = await store.addItem(list.id, 'A');
    final generation = store.snapshot.generation;
    await expectLater(store.reorderItem(list.id, item.id, 1), throwsRangeError);
    await expectLater(store.renameSetList(list.id, ' '), throwsArgumentError);
    expect(store.snapshot.generation, generation);
    await store.renameSetList(list.id, '新曲单');
    expect(store.snapshot.setListById(list.id)!.name, '新曲单');
  });

  test('deleting set list keeps tombstone and its entry references', () async {
    final list = await store.createSetList('演出');
    await store.addItem(list.id, 'A');
    expect(await store.deleteSetList(list.id), isTrue);
    expect(store.snapshot.activeSetLists, isEmpty);
    expect(store.snapshot.setListById(list.id)!.items.single.entryId, 'A');
    expect(await store.deleteSetList(list.id), isFalse);
    await expectLater(store.addItem(list.id, 'B'), throwsArgumentError);
    expect(
        (await ReaderStateStore.open(statePath: statePath))
            .snapshot
            .setListById(list.id)!
            .isDeleted,
        isTrue);
  });

  test('reading positions validate page range and isolate revisions', () async {
    final old = firstPage.document;
    final next = newRevision.document;
    await store.saveReadingPosition(document: old, pageNumber: 4, pageCount: 5);
    await store.saveReadingPosition(
        document: next, pageNumber: 1, pageCount: 2);
    final generation = store.snapshot.generation;
    await expectLater(
        store.saveReadingPosition(document: old, pageNumber: 6, pageCount: 5),
        throwsArgumentError);
    expect(store.snapshot.generation, generation);
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.readingPosition(old)!.pageNumber, 4);
    expect(reopened.readingPosition(next)!.pageNumber, 1);
    expect(
        reopened
            .readingPosition(DocumentKey(entryId: 'missing', revisionId: 'r')),
        isNull);
  });

  test(
      'rapid reading position saves serialize and identical position is a no-op',
      () async {
    final operations = List.generate(
        20,
        (index) => store.saveReadingPosition(
            document: firstPage.document,
            pageNumber: index + 1,
            pageCount: 20));
    await Future.wait(operations);
    expect(store.readingPosition(firstPage.document)!.pageNumber, 20);
    expect(store.snapshot.generation, 20);
    await store.saveReadingPosition(
        document: firstPage.document, pageNumber: 20, pageCount: 20);
    expect(store.snapshot.generation, 20);
    expect(
        (await ReaderStateStore.open(statePath: statePath))
            .readingPosition(firstPage.document)!
            .pageNumber,
        20);
  });

  test(
      'write failure does not commit memory or editing history; queue recovers',
      () async {
    await add(firstPage);
    final generation = store.snapshot.generation;
    final parent = Directory(p.dirname(statePath));
    final relocated =
        await parent.rename(p.join(temporary.path, 'temporarily-unavailable'));
    await File(parent.path).writeAsString('blocking-directory');
    try {
      await expectLater(add(firstPage), throwsA(isA<FileSystemException>()));
      expect(store.snapshot.generation, generation);
      expect(store.snapshot.strokesFor(firstPage), hasLength(1));
    } finally {
      await File(parent.path).delete();
      await relocated.rename(parent.path);
    }
    await add(firstPage);
    expect(store.snapshot.strokesFor(firstPage), hasLength(2));
    await store.undo(firstPage);
    expect(store.snapshot.strokesFor(firstPage), hasLength(1));
  });

  test('corrupt primary recovers previous valid generation with warning',
      () async {
    final first = await add(firstPage);
    await add(firstPage);
    await File(statePath).writeAsString('{broken');
    final recovered = await ReaderStateStore.open(statePath: statePath);
    expect(recovered.storageWarnings, isNotEmpty);
    expect(recovered.snapshot.strokesFor(firstPage).single.id, first.id);
    await recovered.createSetList('恢复后继续');
    expect(
        (await ReaderStateStore.open(statePath: statePath))
            .snapshot
            .activeSetLists
            .single
            .name,
        '恢复后继续');
  });

  test(
      'invalid state without valid backup fails rather than silently clearing marks',
      () async {
    await add(firstPage);
    await File(statePath).writeAsString('{broken');
    await expectLater(ReaderStateStore.open(statePath: statePath),
        throwsA(isA<ReaderStorageException>()));
  });

  test('unsupported primary schema is not silently downgraded to older backup',
      () async {
    await add(firstPage);
    await add(secondPage);
    final document = Map<String, dynamic>.from(
        jsonDecode(await File(statePath).readAsString()) as Map);
    document['schemaVersion'] = 999;
    await File(statePath).writeAsString(jsonEncode(document));
    await expectLater(
        ReaderStateStore.open(statePath: statePath),
        throwsA(isA<ReaderStorageException>().having((error) => error.message,
            'message', contains('Unsupported reader schema'))));
    expect(
        (jsonDecode(await File(statePath).readAsString())
            as Map)['schemaVersion'],
        999);
  });

  test(
      'public JSON roundtrip exposes stable IDs, versions, points and tombstones',
      () async {
    final stroke = await add(firstPage);
    await store.eraseStroke(firstPage, stroke.id);
    final list = await store.createSetList('可序列化曲单');
    final item = await store.addItem(list.id, 'entry-A');
    await store.removeItem(list.id, item.id);
    await store.saveReadingPosition(
        document: firstPage.document, pageNumber: 2, pageCount: 3);
    final json = store.snapshot.toJson();
    expect(json['schemaVersion'], ReaderSnapshot.schemaVersion);
    final rehydrated = ReaderSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(json)) as Map));
    final savedStroke =
        rehydrated.strokesFor(firstPage, includeDeleted: true).single;
    expect(savedStroke.id, stroke.id);
    expect(savedStroke.version, 2);
    expect(savedStroke.isDeleted, isTrue);
    expect(savedStroke.points, stroke.points);
    final removedItem = rehydrated.setListById(list.id)!.items.single;
    expect(removedItem.id, item.id);
    expect(removedItem.entryId, 'entry-A');
    expect(removedItem.isRemoved, isTrue);
    expect(rehydrated.bookmarkFor(firstPage.document)!.pageNumber, 2);
  });

  test('public JSON parser rejects invalid imported page coordinates',
      () async {
    await add(firstPage);
    final json = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(store.snapshot.toJson())) as Map);
    final page = (json['pages'] as List).single as Map;
    final stroke = (page['strokes'] as List).single as Map;
    final point = (stroke['points'] as List).first as Map;
    point['x'] = 1.5;
    expect(() => ReaderSnapshot.fromJson(json), throwsArgumentError);
  });

  test('stale instance must reload; reload clears stale session history',
      () async {
    final other = await ReaderStateStore.open(statePath: statePath);
    await add(firstPage);
    await expectLater(other.createSetList('旧窗口'),
        throwsA(isA<ConcurrentReaderWriteException>()));
    expect(other.snapshot.generation, 0);
    await other.reload();
    await other.createSetList('重载后');
    expect(other.snapshot.strokesFor(firstPage), hasLength(1));
    expect(other.canUndo(firstPage), isFalse);
    await expectLater(
        store.undo(firstPage), throwsA(isA<ConcurrentReaderWriteException>()));
    expect(store.canUndo(firstPage), isTrue);
  });

  test('concurrent distinct stores fail explicitly rather than overwriting',
      () async {
    final other = await ReaderStateStore.open(statePath: statePath);
    final first = store.createSetList('窗口一');
    final second = other.createSetList('窗口二');
    await expectLater(second, throwsA(isA<ConcurrentReaderWriteException>()));
    await first;
    final reopened = await ReaderStateStore.open(statePath: statePath);
    expect(reopened.snapshot.activeSetLists.single.name, '窗口一');
  });
}
