import 'package:flutter/foundation.dart';
import 'package:reader_state/reader_state.dart';

class PendingStroke {
  PendingStroke(this.page, this.style, List<NormalizedPoint> points)
    : points = List.unmodifiable(points);
  final PageKey page;
  final StrokeStyle style;
  final List<NormalizedPoint> points;
  bool saving = false;
}

class PendingPathEdit {
  PendingPathEdit(this.page, this.paths, this.rebuild);
  final PageKey page;
  final StrokePathRebuilder? rebuild;
  final Map<String, List<List<NormalizedPoint>>> paths;
  bool saving = false;
}

/// Presentation state only. Durable changes always go through reader_state.
class ReaderWorkspace extends ChangeNotifier {
  ReaderWorkspace(this.store) : _seenGeneration = store.snapshot.generation;
  final ReaderStateStore store;
  final List<PendingStroke> pending = [];
  final List<PendingPathEdit> pendingPaths = [];
  String? error;
  int _operations = 0;
  int _positionOperations = 0;
  bool _disposed = false;
  int _seenGeneration;
  bool _bookmarkError = false;
  Future<void> _positionWrites = Future.value();
  Future<void> flushPositions() => _positionWrites;
  bool get saving => _operations > 0 || _positionOperations > 0;
  bool get savingAnnotations => _operations > 0;
  int get unsavedCount =>
      pending.where((stroke) => !stroke.saving).length +
      pendingPaths.where((edit) => !edit.saving).length;

  void _changed() {
    _seenGeneration = store.snapshot.generation;
    if (!_disposed) notifyListeners();
  }

  /// Peer merges mutate the same store and invalidate its undo/redo history.
  void refreshFromStore({bool force = false}) {
    if (force || _seenGeneration != store.snapshot.generation) _changed();
  }

  /// The session already reports a page change. Bookmark persistence must not
  /// rebuild the library and annotation tree again unless saving fails.
  Future<void> rememberPosition({
    required DocumentKey document,
    required int pageNumber,
    required int pageCount,
  }) {
    final write = _rememberPosition(document, pageNumber, pageCount);
    _positionWrites = Future.wait([_positionWrites, write]).then((_) {});
    return write;
  }

  Future<void> _rememberPosition(
    DocumentKey document,
    int pageNumber,
    int pageCount,
  ) async {
    _positionOperations++;
    try {
      await store.saveReadingPosition(
        document: document,
        pageNumber: pageNumber,
        pageCount: pageCount,
      );
      _seenGeneration = store.snapshot.generation;
      if (_bookmarkError) {
        error = null;
        _bookmarkError = false;
        _changed();
      }
    } catch (_) {
      error = '阅读位置保存失败，请检查磁盘空间和应用数据目录。已有批注未被清空。';
      _bookmarkError = true;
      _changed();
    } finally {
      _positionOperations--;
    }
  }

  Future<T?> edit<T>(Future<T> Function(ReaderStateStore) operation) async {
    _operations++;
    error = null;
    _bookmarkError = false;
    _changed();
    try {
      return await operation(store);
    } catch (failure, stack) {
      debugPrint('READER state_save_failed: $failure\n$stack');
      error = '保存失败。请检查磁盘空间和应用数据目录后重试；原谱未被更改。';
      return null;
    } finally {
      _operations--;
      _changed();
    }
  }

  Future<void> addStroke(
    PageKey page,
    StrokeStyle style,
    List<NormalizedPoint> points,
  ) async {
    final stroke = PendingStroke(page, style, points);
    pending.add(stroke);
    await _saveStroke(stroke);
  }

  Future<void> _saveStroke(PendingStroke stroke) async {
    if (stroke.saving) return;
    stroke.saving = true;
    final saved = await edit(
      (store) => store.addStroke(
        stroke.page,
        style: stroke.style,
        points: stroke.points,
      ),
    );
    stroke.saving = false;
    if (saved != null) pending.remove(stroke);
    _changed();
  }

  Future<void> retryStrokes() async {
    for (final stroke in List<PendingStroke>.of(pending)) {
      await _saveStroke(stroke);
    }
    for (final edit in List<PendingPathEdit>.of(pendingPaths)) {
      await _savePaths(edit);
    }
  }

  Future<void> replacePaths(
    PageKey page,
    Map<String, List<List<NormalizedPoint>>> paths, {
    StrokePathRebuilder? rebuild,
  }) async {
    final edit = PendingPathEdit(page, paths, rebuild);
    pendingPaths.add(edit);
    await _savePaths(edit);
  }

  Future<void> _savePaths(PendingPathEdit pathEdit) async {
    if (pathEdit.saving) return;
    pathEdit.saving = true;
    final saved = await edit(
      (store) => store.replaceStrokePaths(
        pathEdit.page,
        pathEdit.paths,
        rebuild: pathEdit.rebuild,
      ),
    );
    pathEdit.saving = false;
    if (saved != null) pendingPaths.remove(pathEdit);
    _changed();
  }

  List<PendingStroke> pendingFor(PageKey page) =>
      pending.where((stroke) => stroke.page == page).toList();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
