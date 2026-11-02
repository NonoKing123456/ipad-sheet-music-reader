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
  bool editing = false;
  Object? _owner;
  VoidCallback? _releaseSelection, onEdit, onDelete, onCancel;
  Future<bool> Function()? onDone;
  Future<bool> Function(int)? onColor;
  bool _disposed = false;
  Future<bool>? _finishing, _formatting;
  bool get saving => _finishing != null || _formatting != null;
  bool availableTo(Object owner) => !editing || identical(_owner, owner);
  final _paperPointers = <int>{};
  int? _tapPointer;
  Offset? _tapOrigin;
  double _tapSlop = kTouchSlop;

  bool bind(
    Object owner, {
    required int argb,
    required bool editing,
    required VoidCallback release,
    Future<bool> Function(int)? onColor,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
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
    onEdit = onDelete = onCancel = null;
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
  });
  final int argb;
  final ValueChanged<int>? onChanged;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (name, color) in [
        ('红色', 0xffc12b32),
        ('黑色', 0xff222222),
        ('蓝色', 0xff1c57ac),
        ('黄色', 0xffffc107),
        if (![0xffc12b32, 0xff222222, 0xff1c57ac, 0xffffc107].contains(argb))
          ('当前文字颜色', argb),
      ])
        Tooltip(
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
                    width: 36,
                    height: 36,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (argb == color)
                          Positioned.fill(
                            child: DecoratedBox(
                              key: ValueKey(
                                'annotation-color-selection-$color',
                              ),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xff52615c),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        SizedBox(
                          key: ValueKey('annotation-color-dot-$color'),
                          width: 28,
                          height: 28,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(color),
                              border: color == 0xffffffff
                                  ? Border.all(
                                      color: const Color(0xff9a9e9b),
                                      width: .75,
                                    )
                                  : null,
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
        if (!controller.editing && controller.onEdit != null)
          IconButton(
            tooltip: '编辑文字',
            onPressed: controller.onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
        if (controller.onDelete != null)
          IconButton(
            tooltip: '删除文字',
            onPressed: controller.saving ? null : controller.onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
      ],
    ),
  );
}
