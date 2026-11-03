import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

int _activeEditors = 0, _activeHandles = 0;
bool get readerTextEditorActive => _activeEditors > 0;
bool get readerTextHandleActive => _activeHandles > 0;
VoidCallback beginReaderTextEditing({bool blockPaperGestures = false}) {
  _activeEditors++;
  if (blockPaperGestures) _activeHandles++;
  var ended = false;
  return () {
    if (!ended) {
      ended = true;
      _activeEditors--;
      if (blockPaperGestures) _activeHandles--;
    }
  };
}

/// Shared by every mounted paper of one reader. Paper taps are resolved at up,
/// so a pan, pinch, popup or handle can never confirm a draft accidentally.
class ReaderTextEditorController extends ChangeNotifier {
  int argb = 0xffc12b32;
  double fontSizeFraction = 20 / 1024;
  bool editing = false;
  Object? _owner;
  VoidCallback? _releaseSelection, onEdit, onCancel;
  Future<bool> Function()? onDelete;
  Future<bool> Function()? onDone;
  Future<bool> Function(int)? onColor;
  void Function(double)? onFontSizePreview;
  Future<bool> Function()? onFontSizeCommit;
  bool _disposed = false;
  Future<bool>? _finishing, _formatting;
  bool get saving => _finishing != null || _formatting != null;
  bool availableTo(Object owner) => !editing || identical(_owner, owner);

  final selectionPointers = <int>{};

  /// Reflect a canvas gesture or history change without starting a new edit.
  void reflectFontSize(Object owner, double value) {
    if (!identical(_owner, owner) || fontSizeFraction == value) return;
    fontSizeFraction = value;
    _changed();
  }

  final _paperPointers = <int>{};
  int? _tapPointer;
  Offset? _tapOrigin;
  double _tapSlop = kTouchSlop;

  bool bind(
    Object owner, {
    required int argb,
    required bool editing,
    required double fontSizeFraction,
    required VoidCallback release,
    void Function(double)? onFontSizePreview,
    Future<bool> Function()? onFontSizeCommit,
    Future<bool> Function(int)? onColor,
    VoidCallback? onEdit,
    Future<bool> Function()? onDelete,
    VoidCallback? onCancel,
    Future<bool> Function()? onDone,
  }) {
    if (!availableTo(owner)) return false;
    if (!identical(_owner, owner)) {
      final old = _releaseSelection;
      _owner = null;
      _releaseSelection = null;
      old?.call();
    }
    _owner = owner;
    _releaseSelection = release;
    this.argb = argb;
    this.editing = editing;
    this.fontSizeFraction = fontSizeFraction;
    this.onFontSizePreview = onFontSizePreview;
    this.onFontSizeCommit = onFontSizeCommit;
    this.onColor = onColor;
    this.onEdit = onEdit;
    this.onDelete = onDelete;
    this.onCancel = onCancel;
    this.onDone = onDone;
    _changed();
    return true;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _releaseSelection = null;
    editing = false;
    onColor = null;
    onFontSizePreview = null;
    onFontSizeCommit = null;
    onEdit = onCancel = null;
    onDelete = null;
    onDone = null;
    cancelPaperTap();
    _paperPointers.clear();
    _changed();
  }

  Future<bool> finish() {
    if (readerTextHandleActive) return Future.value(false);
    if (_formatting != null) {
      return _formatting!.then((saved) => saved ? finish() : false);
    }
    if (_finishing != null) return _finishing!;
    final action = onDone;
    if (!editing || action == null) return Future.value(true);
    cancelPaperTap();
    final result = action();
    _finishing = result;
    _changed();
    return result.whenComplete(() {
      _finishing = null;
      _changed();
    });
  }

  void changeColor(int value) {
    if (saving || value == argb) return;
    cancelPaperTap();
    argb = value;
    final action = onColor;
    if (action != null) {
      final result = action(value);
      _formatting = result.whenComplete(() {
        _formatting = null;
        _changed();
      });
    }
    _changed();
  }

  void changeFontSizeFraction(double value) {
    if (saving || value == fontSizeFraction) return;
    cancelPaperTap();
    fontSizeFraction = value.clamp(8 / 1024, 96 / 1024);
    onFontSizePreview?.call(fontSizeFraction);
    _changed();
  }

  Future<bool> commitFontSize() {
    if (_formatting != null) return _formatting!;
    final action = onFontSizeCommit;
    if (action == null) return Future.value(true);
    cancelPaperTap();
    final result = action();
    _formatting = result.whenComplete(() {
      _formatting = null;
      _changed();
    });
    _changed();
    return _formatting!;
  }

  Future<bool> delete() {
    if (saving || onDelete == null) return Future.value(false);
    cancelPaperTap();
    final result = onDelete!();
    _formatting = result;
    _changed();
    return result.whenComplete(() {
      _formatting = null;
      _changed();
    });
  }

  void paperDown(PointerDownEvent event, {required bool blank}) {
    if (!editing ||
        saving ||
        readerTextHandleActive ||
        _paperPointers.contains(event.pointer) ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons != kPrimaryButton)) {
      return;
    }
    _paperPointers.add(event.pointer);
    if (_paperPointers.length != 1 || !blank) {
      cancelPaperTap();
      return;
    }
    _tapPointer = event.pointer;
    _tapOrigin = event.position;
    _tapSlop = event.kind == PointerDeviceKind.touch ? kTouchSlop : 6;
  }

  void paperMove(PointerMoveEvent event) {
    if (_tapPointer == event.pointer &&
        _tapOrigin != null &&
        (event.position - _tapOrigin!).distance >= _tapSlop) {
      cancelPaperTap();
    }
  }

  void paperUp(PointerUpEvent event) {
    final confirm =
        _tapPointer == event.pointer &&
        _tapOrigin != null &&
        (event.position - _tapOrigin!).distance < _tapSlop &&
        _paperPointers.length == 1;
    _paperPointers.remove(event.pointer);
    cancelPaperTap();
    if (confirm) unawaited(finish());
  }

  void paperCancel(int pointer) {
    _paperPointers.remove(pointer);
    cancelPaperTap();
  }

  void cancelPaperTap() {
    _tapPointer = null;
    _tapOrigin = null;
  }

  void _changed() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ReaderAnnotationColors extends StatelessWidget {
  const ReaderAnnotationColors({
    super.key,
    required this.argb,
    required this.onChanged,
    this.compact = false,
    this.showCustomColor = true,
  });
  final int argb;
  final ValueChanged<int>? onChanged;
  final bool compact;
  final bool showCustomColor;

  static const _palette = [
    ('黑色', 0xff222222),
    ('松绿', 0xff236459),
    ('赭红', 0xff9b5949),
    ('蓝色', 0xff1c57ac),
    ('黄色', 0xffffc107),
    ('紫色', 0xffa26f91),
  ];

  Widget _swatch(BuildContext context, String name, int color) => Tooltip(
    message: name,
    child: Semantics(
      button: true,
      selected: argb == color,
      label: name,
      child: InkResponse(
        onTap: onChanged == null ? null : () => onChanged!(color),
        radius: 20,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: SizedBox(
              width: compact ? 30 : 36,
              height: compact ? 30 : 36,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (argb == color)
                    Positioned.fill(
                      child: DecoratedBox(
                        key: ValueKey('annotation-color-selection-$color'),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.onSurface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    key: ValueKey('annotation-color-dot-$color'),
                    width: compact ? 24 : 28,
                    height: compact ? 24 : 28,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(color),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                          width: .75,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (name, color) in _palette) _swatch(context, name, color),
      if (showCustomColor && _palette.every((entry) => entry.$2 != argb))
        _swatch(context, '当前颜色', argb)
      else if (showCustomColor)
        const SizedBox(
          key: ValueKey('annotation-color-current-slot'),
          width: 44,
          height: 44,
        ),
    ],
  );
}

/// Part of the existing fixed top annotation bar. A paper tap is the primary
/// completion action; Escape cancels and existing text keeps an explicit delete.
class ReaderTextFormatControls extends StatelessWidget {
  const ReaderTextFormatControls({super.key, required this.controller});
  final ReaderTextEditorController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReaderAnnotationColors(
          argb: controller.argb,
          onChanged: controller.saving ? null : controller.changeColor,
        ),
      ],
    ),
  );
}
