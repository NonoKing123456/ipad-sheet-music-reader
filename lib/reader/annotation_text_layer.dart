import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader_state/reader_state.dart';

import 'annotation_canvas.dart';
import 'reader_workspace.dart';

/// Text uses the same paper coordinates and paint order as ink. Touch remains
/// available to the enclosing reader. Explicit T mode enables text editing.
class AnnotationTextLayer extends StatefulWidget {
  const AnnotationTextLayer({
    super.key,
    required this.workspace,
    required this.page,
    required this.enabled,
    required this.textTool,
    required this.style,
    this.eraser = false,
    this.eraserRadiusFraction = .018,
    this.suspended = false,
    this.mouseControlKey,
    this.onWritingChanged,
    this.selectionKey,
  });
  final ReaderWorkspace workspace;
  final PageKey page;
  final bool enabled, textTool, eraser, suspended;
  final StrokeStyle style;
  final double eraserRadiusFraction;
  final GlobalKey? mouseControlKey;
  final GlobalKey? selectionKey;
  final ValueChanged<bool>? onWritingChanged;
  @override
  State<AnnotationTextLayer> createState() => _AnnotationTextLayerState();
}

class _AnnotationTextLayerState extends State<AnnotationTextLayer> {
  final _actionsKey = GlobalKey();
  String? _selected;
  TextAnnotation? _original, _preview;
  TextAnnotation? _candidate;
  Offset? _origin;
  Offset? _globalOrigin;
  double _slop = kTouchSlop;
  final _touches = <int>{};
  int? _pointer;
  int _epoch = 0;
  bool _dragged = false, _editorOpen = false;
  bool get _enabled => widget.enabled && widget.textTool && !widget.suspended;
  Rect _bounds(TextAnnotation value, Size size) => textAnnotationBounds(
    value,
    size,
    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
  );

  TextAnnotation? get _selection =>
      _preview ??
      widget.workspace
          .annotationsFor(widget.page)
          .whereType<TextAnnotation>()
          .where((item) => item.id == _selected)
          .firstOrNull;

  void _cancelPointer({bool deferNotification = false}) {
    final writing = _pointer != null;
    _pointer = null;
    _origin = null;
    _globalOrigin = null;
    _original = _preview = null;
    _candidate = null;
    _dragged = false;
    if (writing) {
      final notify = widget.onWritingChanged;
      if (deferNotification) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => notify?.call(false),
        );
      } else {
        notify?.call(false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant AnnotationTextLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || !_enabled) {
      _epoch++;
      _selected = null;
      _touches.clear();
      _cancelPointer(deferNotification: true);
    }
  }

  @override
  void dispose() {
    _epoch++;
    _cancelPointer(deferNotification: true);
    super.dispose();
  }

  bool _inside(GlobalKey? key, Offset global) {
    final box = key?.currentContext?.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  void _down(PointerDownEvent event, Size size) {
    if (!_enabled ||
        size.isEmpty ||
        _editorOpen ||
        widget.workspace.savingAnnotations ||
        _inside(_actionsKey, event.position) ||
        ((event.kind == PointerDeviceKind.mouse ||
                event.kind == PointerDeviceKind.touch) &&
            _inside(widget.mouseControlKey, event.position))) {
      return;
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touches.add(event.pointer);
      if (_touches.length > 1) {
        setState(_cancelPointer);
        return;
      }
    }
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus &&
        event.kind != PointerDeviceKind.touch &&
        !(event.kind == PointerDeviceKind.mouse &&
            event.buttons == kPrimaryButton)) {
      return;
    }
    if (_pointer != null) return;
    final hit = widget.workspace
        .annotationsFor(widget.page)
        .reversed
        .whereType<TextAnnotation>()
        .where(
          (item) =>
              _bounds(item, size).inflate(6).contains(event.localPosition),
        )
        .firstOrNull;
    setState(() {
      _pointer = event.pointer;
      _origin = event.localPosition;
      _globalOrigin = event.position;
      _slop = event.kind == PointerDeviceKind.touch ? kTouchSlop : 6;
      _candidate = hit;
      _original = hit?.id == _selected ? hit : null;
      _dragged = false;
    });
    widget.onWritingChanged?.call(true);
  }

  TextAnnotation _fit(TextAnnotation value, Size size) {
    final bounds = _bounds(value, size);
    return value.revise(
      anchor: NormalizedPoint(
        value.anchor.x.clamp(0.0, math.max(0.0, 1 - bounds.width / size.width)),
        value.anchor.y.clamp(
          0.0,
          math.max(0.0, 1 - bounds.height / size.height),
        ),
      ),
      now: value.updatedUtc,
      version: value.version,
    );
  }

  void _move(PointerMoveEvent event, Size size) {
    if (_pointer != event.pointer || _origin == null || _globalOrigin == null) {
      return;
    }
    final delta = event.localPosition - _origin!;
    if (!_dragged && (event.position - _globalOrigin!).distance < _slop) return;
    setState(() {
      _dragged = true;
      final original = _original;
      if (original == null) return;
      _preview = _fit(
        original.revise(
          anchor: NormalizedPoint(
            (original.anchor.x + delta.dx / size.width).clamp(0.0, 1.0),
            (original.anchor.y + delta.dy / size.height).clamp(0.0, 1.0),
          ),
          now: original.updatedUtc,
          version: original.version,
        ),
        size,
      );
    });
  }

  void _up(PointerUpEvent event, Size size) {
    _touches.remove(event.pointer);
    if (_pointer != event.pointer) return;
    if (_globalOrigin != null &&
        (event.position - _globalOrigin!).distance >= _slop) {
      _dragged = true;
    }
    final moved = _dragged ? _preview : null;
    final original = _original;
    final selected = !_dragged ? _candidate : null;
    final newPoint = _candidate == null && !_dragged ? _origin : null;
    final page = widget.page;
    setState(() {
      _cancelPointer();
      if (selected != null) _selected = selected.id;
    });
    if (moved != null) {
      unawaited(
        widget.workspace.saveText(
          page,
          moved,
          expected: TextEditBase(original),
        ),
      );
    }
    if (newPoint != null) {
      unawaited(
        _editor(
          size,
          anchor: NormalizedPoint(
            (newPoint.dx / size.width).clamp(0.0, 1.0),
            (newPoint.dy / size.height).clamp(0.0, 1.0),
          ),
        ),
      );
    }
  }

  Future<void> _editor(Size size, {NormalizedPoint? anchor}) async {
    if (_editorOpen || !_enabled) return;
    final selected = anchor == null ? _selection : null;
    final page = widget.page, epoch = _epoch;
    _editorOpen = true;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _TextEditorDialog(initial: selected?.text ?? ''),
    );
    _editorOpen = false;
    if (!mounted ||
        !_enabled ||
        epoch != _epoch ||
        page != widget.page ||
        result == null ||
        result.trim().isEmpty) {
      return;
    }
    final text =
        selected?.revise(text: result, now: DateTime.now().toUtc()) ??
        widget.workspace.store.newText(
          text: result,
          anchor: anchor!,
          argb: widget.style.argb,
        );
    setState(() => _selected = text.id);
    await widget.workspace.saveText(
      page,
      _fit(text, size),
      expected: TextEditBase(selected),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.workspace,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final selected = _enabled ? _selection : null;
        final bounds = selected == null ? null : _bounds(selected, size);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _down(event, size),
          onPointerMove: (event) => _move(event, size),
          onPointerUp: (event) => _up(event, size),
          onPointerCancel: (event) {
            _touches.remove(event.pointer);
            if (_pointer == event.pointer) setState(_cancelPointer);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnnotationCanvas(
                workspace: widget.workspace,
                page: widget.page,
                enabled: widget.enabled && !widget.textTool,
                style: widget.style,
                eraser: widget.eraser,
                eraserRadiusFraction: widget.eraserRadiusFraction,
                mouseControlKey: widget.mouseControlKey,
                suspended: widget.suspended,
                onWritingChanged: widget.onWritingChanged,
                textPreview: _preview,
              ),
              if (bounds != null) ...[
                Positioned.fromRect(
                  rect: bounds.inflate(3),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: widget.selectionKey,
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xff236459)),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: bounds.left.clamp(0.0, math.max(0.0, size.width - 96)),
                  top: math.max(0.0, bounds.top - 48),
                  child: Material(
                    key: _actionsKey,
                    color: const Color(0xfffaf9f5),
                    borderRadius: BorderRadius.circular(8),
                    elevation: 2,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑文字',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: widget.workspace.savingAnnotations
                              ? null
                              : () => unawaited(_editor(size)),
                        ),
                        IconButton(
                          tooltip: '删除文字',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: widget.workspace.savingAnnotations
                              ? null
                              : () {
                                  final value = _selection;
                                  if (value == null) return;
                                  setState(() => _selected = null);
                                  unawaited(
                                    widget.workspace.saveText(
                                      widget.page,
                                      value.withDeletion(
                                        true,
                                        DateTime.now().toUtc(),
                                      ),
                                      expected: TextEditBase(value),
                                    ),
                                  );
                                },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

class _TextEditorDialog extends StatefulWidget {
  const _TextEditorDialog({required this.initial});
  final String initial;
  @override
  State<_TextEditorDialog> createState() => _TextEditorDialogState();
}

class _TextEditorDialogState extends State<_TextEditorDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('文字批注'),
    content: SizedBox(
      width: 320,
      child: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 6,
        maxLength: 8192,
        maxLengthEnforcement: MaxLengthEnforcement.truncateAfterCompositionEnds,
        decoration: InputDecoration(
          hintText: '输入文字',
          counterText: '',
          errorText: _error,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_controller.text.length > 8192) {
            setState(() => _error = '文字过长，请缩短。');
            return;
          }
          Navigator.pop(context, _controller.text);
        },
        child: const Text('完成'),
      ),
    ],
  );
}
