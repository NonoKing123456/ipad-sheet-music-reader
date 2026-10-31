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

/// Presentation state only. Durable changes always go through reader_state.
class ReaderWorkspace extends ChangeNotifier {
  ReaderWorkspace(this.store);
  final ReaderStateStore store;
  final List<PendingStroke> pending = [];
  String? error;
  int _operations = 0;
  bool _disposed = false;
  bool get saving => _operations > 0;
  int get unsavedCount => pending.where((stroke) => !stroke.saving).length;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Peer merges mutate the same store and invalidate its undo/redo history.
  void refreshFromStore() => _changed();

  Future<T?> edit<T>(Future<T> Function(ReaderStateStore) operation) async {
    _operations++;
    error = null;
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
  }

  List<PendingStroke> pendingFor(PageKey page) =>
      pending.where((stroke) => stroke.page == page).toList();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
