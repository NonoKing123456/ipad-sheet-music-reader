import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'merge.dart';

class ReaderStateStore {
  ReaderStateStore._(this.statePath);

  final String statePath;
  static final _random = Random.secure();
  static final _activeFiles = <String>{};
  ReaderSnapshot _snapshot = ReaderSnapshot.empty();
  Future<void> _tail = Future.value();
  final _undo = <PageKey, List<List<_StrokeEdit>>>{};
  final _redo = <PageKey, List<List<_StrokeEdit>>>{};
  final _storageWarnings = <String>[];

  ReaderSnapshot get snapshot => _snapshot;

  /// The merge is evaluated inside the same queue/lock as local edits. An
  /// optional durable operation ID makes retries safe across process crashes.
  Future<ReaderMergeResult> mergeFromPeer(
          {required ReaderSnapshot base,
          required ReaderSnapshot remote,
          required String peerId,
          String? operationId}) =>
      _enqueue(() async {
        requireNonEmptyId(peerId, 'peerId');
        if (operationId != null &&
            _snapshot.mergeReceipts.contains(operationId)) {
          return ReaderMergeResult(_snapshot, _snapshot.conflicts);
        }
        final result = mergeReaderSnapshots(
            base: base,
            local: _snapshot,
            remote: remote,
            peerId: peerId,
            operationId: operationId);
        await _commit(result.snapshot);
        _undo.clear();
        _redo.clear();
        return result;
      });
  List<String> get storageWarnings => List.unmodifiable(_storageWarnings);
  bool canUndo(PageKey page) => _undo[page]?.isNotEmpty ?? false;
  bool canRedo(PageKey page) => _redo[page]?.isNotEmpty ?? false;

  static Future<ReaderStateStore> open({required String statePath}) async {
    final store = ReaderStateStore._(p.normalize(p.absolute(statePath)));
    await store.reload();
    return store;
  }

  /// Reloading clears session editing history. It does not discard tombstones.
  Future<void> reload() => _enqueue(() async {
        _snapshot = await _readSnapshot();
        _undo.clear();
        _redo.clear();
      }, checkGeneration: false);

  /// Commit one completed stroke, not each sampled pointer point.
  Future<AnnotationStroke> addStroke(
    PageKey page, {
    required StrokeStyle style,
    required List<NormalizedPoint> points,
  }) {
    final capturedPoints = List<NormalizedPoint>.of(points);
    return _enqueue(() async {
      final now = DateTime.now().toUtc();
      final stroke = AnnotationStroke(
          id: _newId(),
          style: style,
          points: capturedPoints,
          createdUtc: now,
          updatedUtc: now,
          version: 1);
      final pages = Map<PageKey, List<PageAnnotation>>.of(_snapshot.annotations);
      pages[page] = [...?pages[page], stroke];
      await _commit(_snapshot.next(annotations: pages));
      _undo
          .putIfAbsent(page, () => [])
          .add([_StrokeEdit(stroke.id, true, false)]);
      _redo.remove(page);
      return stroke;
    });
  }

  /// Erases the entire matching stroke. No effect for missing/deleted IDs.
  Future<bool> eraseStroke(PageKey page, String strokeId) => _enqueue(() async {
        final strokes = _snapshot.annotations[page] ?? [];
        final index = strokes
            .indexWhere((stroke) => stroke.id == strokeId && !stroke.isDeleted);
        if (index < 0) return false;
        await _changeDeletion(page, strokeId, true);
        _undo
            .putIfAbsent(page, () => [])
            .add([_StrokeEdit(strokeId, false, true)]);
        _redo.remove(page);
        return true;
      });

  TextAnnotation newText({required String text, required NormalizedPoint anchor,
      required int argb, double fontSizeFraction = 20 / 1024,
      double widthFraction = .45}) {
    final now = DateTime.now().toUtc();
    return TextAnnotation(id: _newId(), text: text, anchor: anchor, argb: argb,
        fontSizeFraction: fontSizeFraction, widthFraction: widthFraction,
        createdUtc: now, updatedUtc: now, version: 1);
  }

  /// One confirmed text creation/edit/move/delete is one history operation.
  Future<TextAnnotation> saveText(PageKey page, TextAnnotation desired,
      {TextEditBase? expected}) {
    final base = expected?.value ?? (expected == null
        ? (_snapshot.annotations[page] ?? []).whereType<TextAnnotation>()
            .where((item) => item.id == desired.id).firstOrNull
        : null);
    return _enqueue(() async {
        final items = List<PageAnnotation>.of(_snapshot.annotations[page] ?? []);
        final index = items.indexWhere((item) => item.id == desired.id);
        final now = DateTime.now().toUtc();
        TextAnnotation next;
        TextAnnotation? previous;
        if (index < 0) {
          if (desired.isDeleted) throw StateError('Cannot delete an unknown text.');
          next = desired.revise(now: now, version: 1);
          items.add(next);
        } else {
          final original = items[index];
          if (original is! TextAnnotation) throw StateError('Annotation is not text.');
          previous = original;
          next = desired.revise(now: now, version: original.version + 1,
              deleted: desired.isDeleted);
          items[index] = next;
        }
        final pages = Map<PageKey, List<PageAnnotation>>.of(_snapshot.annotations);
        pages[page] = items;
        final current = (_snapshot.annotations[page] ?? [])
            .whereType<TextAnnotation>().where((item) => item.id == desired.id).firstOrNull;
        bool same(TextAnnotation? a, TextAnnotation? b) => a == null || b == null
            ? a == b
            : a.isDeleted == b.isDeleted &&
                canonicalReaderJson(a.geometry) == canonicalReaderJson(b.geometry);
        if (current != null && (same(current, next) || same(base, next))) {
          return current; // An unchanged confirmation cannot undo a peer edit.
        }
        if (!same(current, base) && !same(current, next)) {
          // A draft can outlive a peer merge or a failed save. Preserve its
          // captured semantic base; counters/clocks are not causal evidence.
          final basePages = Map<PageKey, List<PageAnnotation>>.of(_snapshot.annotations);
          basePages[page] = [for (final item in _snapshot.annotations[page] ?? <PageAnnotation>[])
            if (item.id != desired.id) item else if (base != null) base];
          final ancestor = ReaderSnapshot(generation: _snapshot.generation,
              annotations: basePages, setLists: _snapshot.setLists,
              bookmarks: _snapshot.bookmarks, conflicts: _snapshot.conflicts,
              mergeReceipts: _snapshot.mergeReceipts);
          final merged = mergeReaderSnapshots(base: ancestor, local: _snapshot,
              remote: _snapshot.next(annotations: pages), peerId: 'local-text-edit');
          await _commit(merged.snapshot);
          next = _snapshot.annotations[page]!.whereType<TextAnnotation>()
              .singleWhere((item) => item.id == desired.id);
        } else {
          await _commit(_snapshot.next(annotations: pages));
        }
        final edit = previous == null ? _StrokeEdit(next.id, true, false)
            : same(previous, next) ? null
            : _StrokeEdit(next.id, previous.isDeleted, next.isDeleted,
                beforeText: previous, afterText: next);
        if (edit != null) {
          _undo.putIfAbsent(page, () => []).add([edit]);
          _redo.remove(page);
        }
        return next;
      });
  }

  Future<bool> undo(PageKey page) => _enqueue(() async {
        final stack = _undo[page];
        if (stack == null || stack.isEmpty) return false;
        final edit = stack.last;
        await _changeDeletions(page, edit, undo: true);
        stack.removeLast();
        _redo.putIfAbsent(page, () => []).add(edit);
        return true;
      });

  Future<bool> redo(PageKey page) => _enqueue(() async {
        final stack = _redo[page];
        if (stack == null || stack.isEmpty) return false;
        final edit = stack.last;
        await _changeDeletions(page, edit, undo: false);
        stack.removeLast();
        _undo.putIfAbsent(page, () => []).add(edit);
        return true;
      });

  Future<void> _changeDeletion(PageKey page, String strokeId, bool deleted) =>
      _changeDeletions(page, [_StrokeEdit(strokeId, deleted, deleted)],
          undo: false);

  /// A local path erasure is one durable operation, represented entirely by
  /// existing schema-2 strokes and tombstones for old clients and peer merges.
  Future<bool> replaceStrokePaths(
          PageKey page, Map<String, List<List<NormalizedPoint>>> replacements,
          {StrokePathRebuilder? rebuild}) =>
      _enqueue(() async {
        final requested =
            rebuild?.call(_snapshot.strokesFor(page)) ?? replacements;
        final strokes = <PageAnnotation>[];
        final edits = <_StrokeEdit>[];
        final now = DateTime.now().toUtc();
        for (final original in _snapshot.annotations[page] ?? <PageAnnotation>[]) {
          final paths = requested[original.id];
          if (paths == null || original.isDeleted || original is! AnnotationStroke) {
            strokes.add(original);
            continue;
          }
          // Keep the tombstone as an order anchor and insert its replacement
          // fragments here, below every stroke that was painted above it.
          strokes.add(original.withDeletion(true, now));
          edits.add(_StrokeEdit(original.id, false, true));
          for (final points in paths.where((p) => p.isNotEmpty)) {
            final fragment = AnnotationStroke(
                id: _newId(),
                style: original.style,
                points: points,
                createdUtc: original.createdUtc,
                updatedUtc: now,
                version: 1);
            strokes.add(fragment);
            edits.add(_StrokeEdit(fragment.id, true, false));
          }
        }
        if (edits.isEmpty) return false;
        final pages = Map<PageKey, List<PageAnnotation>>.of(_snapshot.annotations);
        pages[page] = strokes;
        await _commit(_snapshot.next(annotations: pages));
        _undo.putIfAbsent(page, () => []).add(edits);
        _redo.remove(page);
        return true;
      });

  Future<void> _changeDeletions(PageKey page, List<_StrokeEdit> edits,
      {required bool undo}) async {
    final strokes = List<PageAnnotation>.of(_snapshot.annotations[page] ?? []);
    final now = DateTime.now().toUtc();
    for (final edit in edits) {
      final index = strokes.indexWhere((stroke) => stroke.id == edit.strokeId);
      if (index < 0)
        throw StateError('Stroke history no longer matches state; reload.');
      final current = strokes[index];
      final text = undo ? edit.beforeText : edit.afterText;
      if (text != null) {
        if (current is! TextAnnotation) throw StateError('Text history type changed.');
        strokes[index] = text.revise(now: now, version: current.version + 1,
            deleted: undo ? edit.beforeDeleted : edit.afterDeleted);
      } else {
        strokes[index] = current.withDeletion(
            undo ? edit.beforeDeleted : edit.afterDeleted, now);
      }
    }
    final pages = Map<PageKey, List<PageAnnotation>>.of(_snapshot.annotations);
    pages[page] = strokes;
    await _commit(_snapshot.next(annotations: pages));
  }

  Future<ScoreSetList> createSetList(String name) => _enqueue(() async {
        final now = DateTime.now().toUtc();
        final list = ScoreSetList(
            id: _newId(),
            name: name.trim(),
            items: [],
            createdUtc: now,
            updatedUtc: now,
            version: 1);
        await _commit(_snapshot.next(setLists: [..._snapshot.setLists, list]));
        return list;
      });

  Future<ScoreSetList> renameSetList(String listId, String name) =>
      _enqueue(() async {
        final list = _requireList(listId);
        if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
        if (list.name == name.trim()) return list;
        final next = list.updated(DateTime.now().toUtc(), name: name.trim());
        await _replaceList(next);
        return next;
      });

  Future<bool> deleteSetList(String listId) => _enqueue(() async {
        final list = _snapshot.setListById(listId);
        if (list == null || list.isDeleted) return false;
        await _replaceList(list.updated(DateTime.now().toUtc(), deleted: true));
        return true;
      });

  Future<SetListItem> addItem(String listId, String entryId) =>
      _enqueue(() async {
        final list = _requireList(listId);
        final now = DateTime.now().toUtc();
        final item = SetListItem(
            id: _newId(),
            entryId: entryId,
            createdUtc: now,
            updatedUtc: now,
            version: 1);
        await _replaceList(list.updated(now, items: [...list.items, item]));
        return item;
      });

  Future<bool> removeItem(String listId, String itemId) => _enqueue(() async {
        final list = _requireList(listId);
        final index = list.items
            .indexWhere((item) => item.id == itemId && !item.isRemoved);
        if (index < 0) return false;
        final now = DateTime.now().toUtc();
        final items = list.items.toList();
        items[index] = items[index].withRemoval(now);
        await _replaceList(list.updated(now, items: items));
        return true;
      });

  /// [targetIndex] is the final index among active items. E.g. moving A to 2 in
  /// [A,B,C] yields [B,C,A]; adapt Flutter's insertion-slot callback accordingly.
  Future<ScoreSetList> reorderItem(
          String listId, String itemId, int targetIndex) =>
      _enqueue(() async {
        final list = _requireList(listId);
        final visible = list.activeItems.toList();
        final current = visible.indexWhere((item) => item.id == itemId);
        if (current < 0)
          throw ArgumentError.value(itemId, 'itemId', 'No active item.');
        if (targetIndex < 0 || targetIndex >= visible.length) {
          throw RangeError.index(targetIndex, visible, 'targetIndex');
        }
        if (current == targetIndex) return list;
        final moved = visible.removeAt(current);
        visible.insert(targetIndex, moved);
        final next = list.updated(DateTime.now().toUtc(),
            items: [...visible, ...list.items.where((item) => item.isRemoved)]);
        await _replaceList(next);
        return next;
      });

  Future<ReadingBookmark> saveReadingPosition(
          {required DocumentKey document,
          required int pageNumber,
          required int pageCount}) =>
      _enqueue(() async {
        final bookmark = ReadingBookmark(
            document: document,
            pageNumber: pageNumber,
            pageCount: pageCount,
            updatedUtc: DateTime.now().toUtc());
        final existing = _snapshot.bookmarkFor(document);
        if (existing != null &&
            existing.pageNumber == pageNumber &&
            existing.pageCount == pageCount) {
          return existing;
        }
        final positions =
            Map<DocumentKey, ReadingBookmark>.of(_snapshot.bookmarks);
        positions[document] = bookmark;
        await _commit(_snapshot.next(bookmarks: positions));
        return bookmark;
      });

  ReadingBookmark? readingPosition(DocumentKey document) =>
      _snapshot.bookmarkFor(document);

  ScoreSetList _requireList(String id) {
    final list = _snapshot.setListById(id);
    if (list == null || list.isDeleted)
      throw ArgumentError.value(id, 'listId', 'No active set list.');
    return list;
  }

  Future<void> _replaceList(ScoreSetList list) => _commit(_snapshot.next(
      setLists: _snapshot.setLists
          .map((old) => old.id == list.id ? list : old)
          .toList()));

  Future<void> _commit(ReaderSnapshot next) async {
    await _writeSnapshot(next);
    _snapshot = next;
  }

  /// Queue evaluation itself, not just file writing: each action sees the state
  /// committed by its predecessor. A failed action does not poison the queue.
  Future<T> _enqueue<T>(Future<T> Function() action,
      {bool checkGeneration = true}) {
    final operation = _tail.then((_) => _withFileLock(() async {
          if (checkGeneration) {
            final disk = await _readSnapshot();
            if (disk.generation != _snapshot.generation) {
              throw const ConcurrentReaderWriteException(
                  'State changed elsewhere; reload before modifying.');
            }
          }
          return action();
        }));
    _tail = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    return operation;
  }

  Future<T> _withFileLock<T>(Future<T> Function() action) async {
    final key = Platform.isWindows ? statePath.toLowerCase() : statePath;
    if (!_activeFiles.add(key)) {
      throw const ConcurrentReaderWriteException(
          'Another store is writing this state file.');
    }
    RandomAccessFile? handle;
    var locked = false;
    try {
      await Directory(p.dirname(statePath)).create(recursive: true);
      handle = await File('$statePath.lock').open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException catch (error) {
        throw ConcurrentReaderWriteException(
            'State lock is held: ${error.message}');
      }
      return await action();
    } finally {
      try {
        if (handle != null) {
          try {
            if (locked) await handle.unlock();
          } finally {
            await handle.close();
          }
        }
      } finally {
        _activeFiles.remove(key);
      }
    }
  }

  Future<ReaderSnapshot> _decode(File file) async => ReaderSnapshot.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map));

  Future<ReaderSnapshot> _readSnapshot() async {
    final primary = File(statePath);
    final backup = File('$statePath.backup');
    final hasPrimary = await primary.exists();
    final hasBackup = await backup.exists();
    if (!hasPrimary && !hasBackup) return ReaderSnapshot.empty();
    Object? primaryError;
    if (hasPrimary) {
      try {
        return await _decode(primary);
      } on UnsupportedReaderSchemaException catch (error) {
        throw ReaderStorageException(
            'Unsupported reader schema ${error.version}; refusing to restore an older backup.');
      } catch (error) {
        primaryError = error;
      }
    }
    if (hasBackup) {
      try {
        final recovered = await _decode(backup);
        final warning =
            'Recovered reader generation ${recovered.generation} from backup; '
            'the most recent operation may need review.';
        if (!_storageWarnings.contains(warning)) _storageWarnings.add(warning);
        return recovered;
      } catch (error) {
        throw ReaderStorageException(
            'Reader primary and backup are invalid. Primary: $primaryError; backup: $error');
      }
    }
    throw ReaderStorageException(
        'Reader state is invalid and has no backup: $primaryError');
  }

  Future<void> _writeSnapshot(ReaderSnapshot snapshot) async {
    final primary = File(statePath);
    final backup = File('$statePath.backup');
    final temporary = File('$statePath.tmp.${_newId()}');
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    try {
      if (await primary.exists()) {
        var valid = false;
        try {
          await _decode(primary);
          valid = true;
        } catch (_) {}
        if (valid) {
          if (await backup.exists()) await backup.delete();
          await primary.rename(backup.path);
        } else {
          await primary.rename('$statePath.corrupt.${_newId()}');
        }
      }
      await temporary.rename(statePath);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
      '${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

class _StrokeEdit {
  const _StrokeEdit(this.strokeId, this.beforeDeleted, this.afterDeleted,
      {this.beforeText, this.afterText});
  final String strokeId;
  final bool beforeDeleted;
  final bool afterDeleted;
  final TextAnnotation? beforeText, afterText;
}
