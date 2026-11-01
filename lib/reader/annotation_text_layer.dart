import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:reader_state/reader_state.dart';

import 'annotation_canvas.dart';
import 'reader_text_editing.dart';
import 'reader_workspace.dart';

/// Paper-relative text. Only explicit T mode accepts finger/mouse text actions.
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
    this.transform,
    this.textControls,
    this.topControlsKey,
    this.viewportKey,
  });
  final ReaderWorkspace workspace;
  final PageKey page;
  final bool enabled, textTool, eraser, suspended;
  final StrokeStyle style;
  final double eraserRadiusFraction;
  final GlobalKey? mouseControlKey, selectionKey, topControlsKey, viewportKey;
  final TransformationController? transform;
  final ReaderTextEditorController? textControls;
  final ValueChanged<bool>? onWritingChanged;
  @override
  State<AnnotationTextLayer> createState() => _AnnotationTextLayerState();
}

enum _TextHandle { move, transform, width }

class _AnnotationTextLayerState extends State<AnnotationTextLayer>
    with WidgetsBindingObserver {
  final _fallbackControls = ReaderTextEditorController();
  ReaderTextEditorController get _controls =>
      widget.textControls ?? _fallbackControls;
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _inputKey = GlobalKey();
  final _handleKeys = {
    for (final handle in _TextHandle.values) handle: GlobalKey(),
  };
  String? _selected, _error;
  TextAnnotation? _original, _preview, _candidate, _editBase, _draft;
  Offset? _origin, _globalOrigin;
  double _slop = kTouchSlop;
  final _touches = <int>{};
  int? _pointer, _handlePointer;
  bool _dragged = false;
  _TextHandle? _handle;
  TextAnnotation? _handleBase;
  Offset? _handleOrigin;
  VoidCallback? _endEditing, _endHandle;
  Matrix4? _beforeReveal, _revealedTransform;
  bool _revealWaitingForPaint = false;
  double _nextSize = 20 / 1024;
  bool get _editorOpen => _draft != null;
  bool get _enabled => widget.enabled && widget.textTool && !widget.suspended;
  String? get _family => Theme.of(context).textTheme.bodyMedium?.fontFamily;
  Rect _frame(TextAnnotation value, Size size) =>
      textAnnotationFrame(value, size, fontFamily: _family);
  Rect _bounds(TextAnnotation value, Size size) =>
      textAnnotationBounds(value, size, fontFamily: _family);
  TextAnnotation? get _selection =>
      _preview ??
      widget.workspace
          .annotationsFor(widget.page)
          .whereType<TextAnnotation>()
          .where((item) => item.id == _selected)
          .firstOrNull;
  TextAnnotation? _editingValue(Size size) {
    final draft = _draft;
    if (draft == null) return null;
    final text = _controller.text;
    return draft.revise(
      text: text.trim().isEmpty || text.length > 8192 ? '输入文字' : text,
      now: draft.updatedUtc,
      version: draft.version,
    );
  }

  TextAnnotation _revise(
    TextAnnotation value, {
    NormalizedPoint? anchor,
    double? size,
    double? width,
    double? rotation,
    AnnotationTextFont? font,
  }) => value.revise(
    anchor: anchor,
    fontSizeFraction: size,
    widthFraction: width,
    rotation: rotation,
    font: font,
    now: value.updatedUtc,
    version: value.version,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.transform?.addListener(_transformChanged);
  }

  @override
  void didUpdateWidget(covariant AnnotationTextLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform?.removeListener(_transformChanged);
      widget.transform?.addListener(_transformChanged);
    }
    if (oldWidget.textControls != widget.textControls) {
      oldWidget.textControls?.release(this);
    }
    if (oldWidget.page != widget.page || !_enabled) {
      _closeEditor();
      _selected = null;
      _controls.release(this);
      _touches.clear();
      _cancelPointer(defer: true);
      _cancelHandle(defer: true);
    }
  }

  @override
  void dispose() {
    _closeEditor();
    _controls.release(this);
    WidgetsBinding.instance.removeObserver(this);
    widget.transform?.removeListener(_transformChanged);
    _cancelPointer(defer: true);
    _cancelHandle(defer: true);
    _controller.dispose();
    _focus.dispose();
    _fallbackControls.dispose();
    super.dispose();
  }

  void _transformChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _enabled) setState(() {});
    });
  }

  @override
  void didChangeMetrics() => _scheduleReveal();
  void _scheduleReveal() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealEditor());
  void _revealEditor() {
    if (!mounted || !_editorOpen || widget.transform == null) return;
    if (_revealWaitingForPaint) return;
    final box = _inputKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final media = MediaQuery.of(context), view = View.of(context);
    final corners = [
      Offset.zero,
      Offset(box.size.width, 0),
      Offset(0, box.size.height),
      box.size.bottomRight(Offset.zero),
    ].map(box.localToGlobal).toList();
    final rect = Rect.fromLTRB(
      corners.map((p) => p.dx).reduce(math.min),
      corners.map((p) => p.dy).reduce(math.min),
      corners.map((p) => p.dx).reduce(math.max),
      corners.map((p) => p.dy).reduce(math.max),
    );
    final tools = widget.topControlsKey?.currentContext?.findRenderObject();
    final viewport = widget.viewportKey?.currentContext?.findRenderObject();
    final viewportTop = viewport is RenderBox && viewport.hasSize
        ? viewport.localToGlobal(Offset.zero).dy
        : media.padding.top;
    final viewportBottom = viewport is RenderBox && viewport.hasSize
        ? viewport.localToGlobal(Offset(0, viewport.size.height)).dy
        : media.size.height;
    final toolsBottom = tools is RenderBox && tools.hasSize
        ? tools.localToGlobal(Offset(0, tools.size.height)).dy
        : viewportTop;
    final top = math.max(viewportTop, toolsBottom) + 12;
    final bottom =
        math.min(
          viewportBottom,
          media.size.height - view.viewInsets.bottom / view.devicePixelRatio,
        ) -
        12;
    final dy = rect.bottom > bottom
        ? bottom - rect.bottom
        : rect.top < top
        ? top - rect.top
        : 0.0;
    if (dy.abs() < .5) return;
    final transform = widget.transform!;
    _beforeReveal ??= transform.value.clone();
    final next = transform.value.clone();
    next.storage[13] += dy;
    _revealedTransform = next;
    _revealWaitingForPaint = true;
    transform.value = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealWaitingForPaint = false;
      _revealEditor();
    });
  }

  void _writingEnd({bool defer = false}) {
    final notify = widget.onWritingChanged;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => notify?.call(false));
    } else {
      notify?.call(false);
    }
  }

  void _cancelPointer({bool defer = false}) {
    final writing = _pointer != null;
    _pointer = null;
    _origin = _globalOrigin = null;
    _original = _preview = _candidate = null;
    _dragged = false;
    if (writing) _writingEnd(defer: defer);
  }

  void _cancelHandle({bool defer = false}) {
    if (_handlePointer != null) {
      if (_editorOpen && _handleBase != null) _draft = _handleBase;
      _writingEnd(defer: defer);
    }
    _endHandle?.call();
    _endHandle = null;
    _handlePointer = null;
    _handle = null;
    _handleBase = null;
    _handleOrigin = null;
    _preview = null;
  }

  bool _inside(GlobalKey? key, Offset global) {
    final box = key?.currentContext?.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  bool _primary(PointerDownEvent event) =>
      event.kind == PointerDeviceKind.touch ||
      event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus ||
      (event.kind == PointerDeviceKind.mouse &&
          event.buttons == kPrimaryButton);
  void _down(PointerDownEvent event, Size size) {
    if (!_enabled ||
        size.isEmpty ||
        _editorOpen ||
        _handlePointer != null ||
        !_controls.availableTo(this) ||
        widget.workspace.savingAnnotations ||
        _handleKeys.values.any((key) => _inside(key, event.position)) ||
        _inside(widget.mouseControlKey, event.position) ||
        !_primary(event)) {
      return;
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touches.add(event.pointer);
      if (_touches.length > 1) {
        setState(_cancelPointer);
        return;
      }
    }
    if (_pointer != null) return;
    final hit = widget.workspace
        .annotationsFor(widget.page)
        .reversed
        .whereType<TextAnnotation>()
        .where(
          (item) => textAnnotationHit(
            item,
            event.localPosition,
            size,
            fontFamily: _family,
          ),
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
    final dx = bounds.left < 0
        ? -bounds.left
        : bounds.right > size.width
        ? size.width - bounds.right
        : 0.0;
    final dy = bounds.top < 0
        ? -bounds.top
        : bounds.bottom > size.height
        ? size.height - bounds.bottom
        : 0.0;
    return _revise(
      value,
      anchor: NormalizedPoint(
        (value.anchor.x + dx / size.width).clamp(0.0, 1.0),
        (value.anchor.y + dy / size.height).clamp(0.0, 1.0),
      ),
    );
  }

  void _move(PointerMoveEvent event, Size size) {
    if (_pointer != event.pointer || _origin == null || _globalOrigin == null) {
      return;
    }
    if (!_dragged && (event.position - _globalOrigin!).distance < _slop) return;
    final delta = event.localPosition - _origin!;
    setState(() {
      _dragged = true;
      if (_original case final original?) {
        _preview = _fit(
          _revise(
            original,
            anchor: NormalizedPoint(
              (original.anchor.x + delta.dx / size.width).clamp(0.0, 1.0),
              (original.anchor.y + delta.dy / size.height).clamp(0.0, 1.0),
            ),
          ),
          size,
        );
      }
    });
  }

  void _up(PointerUpEvent event, Size size) {
    _touches.remove(event.pointer);
    if (_pointer != event.pointer) return;
    if (_globalOrigin != null &&
        (event.position - _globalOrigin!).distance >= _slop) {
      _dragged = true;
    }
    final moved = _dragged ? _preview : null, original = _original;
    final selected = !_dragged ? _candidate : null;
    final point = _candidate == null && !_dragged ? _origin : null;
    setState(() {
      _cancelPointer();
      if (selected != null) _selected = selected.id;
    });
    if (moved != null) {
      _bindSelection(moved, size);
      unawaited(
        widget.workspace.saveText(
          widget.page,
          moved,
          expected: TextEditBase(original),
        ),
      );
    } else if (selected != null) {
      _bindSelection(selected, size);
    }
    if (point != null) {
      _editor(
        size,
        anchor: NormalizedPoint(
          (point.dx / size.width).clamp(0.0, 1.0),
          (point.dy / size.height).clamp(0.0, 1.0),
        ),
      );
    }
  }

  void _releaseSelection() {
    if (mounted) {
      setState(() {
        _selected = null;
        _preview = null;
      });
    }
  }

  void _bindSelection(TextAnnotation value, Size size) {
    _controls.bind(
      this,
      font: value.font,
      editing: false,
      release: _releaseSelection,
      onEdit: () => _editor(size),
      onDelete: _deleteSelection,
      onFont: (font) {
        _editor(size);
        if (_editorOpen) _changeFont(font);
      },
    );
  }

  void _deleteSelection() {
    final value = _selection;
    if (value == null || widget.workspace.savingAnnotations) return;
    setState(() => _selected = null);
    _controls.release(this);
    unawaited(
      widget.workspace.saveText(
        widget.page,
        value.withDeletion(true, DateTime.now().toUtc()),
        expected: TextEditBase(value),
      ),
    );
  }

  void _closeEditor() {
    _cancelHandle(defer: true);
    _focus.unfocus();
    _draft = _editBase = null;
    _error = null;
    _endEditing?.call();
    _endEditing = null;
    _controls.release(this);
    final transform = widget.transform;
    if (_beforeReveal != null && transform?.value == _revealedTransform) {
      final previous = _beforeReveal!, revealed = _revealedTransform;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_editorOpen &&
            widget.transform == transform &&
            transform!.value == revealed) {
          transform.value = previous;
        }
      });
    }
    _beforeReveal = _revealedTransform = null;
    _revealWaitingForPaint = false;
  }

  void _changeFont(AnnotationTextFont font) {
    if (!_editorOpen) return;
    _controls.font = font;
    setState(() => _draft = _revise(_draft!, font: font));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editorOpen) {
        _focus.requestFocus();
        _revealEditor();
      }
    });
  }

  void _editor(Size size, {NormalizedPoint? anchor}) {
    if (_editorOpen || !_enabled || !_controls.availableTo(this)) return;
    final selected = anchor == null ? _selection : null;
    _editBase = selected;
    _controller.text = selected?.text ?? '';
    _draft =
        selected ??
        widget.workspace.store.newText(
          text: '输入文字',
          anchor: anchor!,
          argb: widget.style.argb,
          fontSizeFraction: _nextSize,
          font: _controls.font,
        );
    _draft = _fit(_draft!, size);
    final bound = _controls.bind(
      this,
      font: _draft!.font,
      editing: true,
      release: _releaseSelection,
      onFont: _changeFont,
      onCancel: () {
        setState(_closeEditor);
        if (_selection case final selected?) _bindSelection(selected, size);
      },
      onDone: () => _finishEditor(size),
    );
    if (!bound) {
      _draft = _editBase = null;
      return;
    }
    _endEditing = beginReaderTextEditing();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editorOpen) {
        _focus.requestFocus();
        _revealEditor();
      }
    });
  }

  void _finishEditor(Size size) {
    if (_controller.text.trim().isEmpty || _controller.text.length > 8192) {
      setState(
        () => _error = _controller.text.trim().isEmpty
            ? '请输入文字。'
            : '文字过长，请缩短至 8192 字以内。',
      );
      return;
    }
    final desired = _editingValue(size)!, base = _editBase;
    _nextSize = desired.fontSizeFraction;
    setState(() {
      _selected = desired.id;
      _closeEditor();
    });
    _bindSelection(desired, size);
    unawaited(
      widget.workspace.saveText(
        widget.page,
        desired,
        expected: TextEditBase(base),
      ),
    );
  }

  Offset _paperPoint(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global);
  void _handleDown(_TextHandle handle, PointerDownEvent event, Size size) {
    if (!_enabled ||
        !_primary(event) ||
        _handlePointer != null ||
        !_controls.availableTo(this) ||
        widget.workspace.savingAnnotations) {
      return;
    }
    final value = _editingValue(size) ?? _selection;
    if (value == null) return;
    _handlePointer = event.pointer;
    _handle = handle;
    _handleBase = value;
    _handleOrigin = _paperPoint(event.position);
    _cancelPointer();
    _endHandle = beginReaderTextEditing();
    widget.onWritingChanged?.call(true);
  }

  void _handleMove(PointerMoveEvent event, Size size) {
    if (_handlePointer != event.pointer ||
        _handleBase == null ||
        _handleOrigin == null) {
      return;
    }
    final base = _handleBase!, frame = _frame(_handleBase!, size);
    final point = _paperPoint(event.position), delta = point - _handleOrigin!;
    TextAnnotation value;
    switch (_handle!) {
      case _TextHandle.move:
        value = _fit(
          _revise(
            base,
            anchor: NormalizedPoint(
              (base.anchor.x + delta.dx / size.width).clamp(0.0, 1.0),
              (base.anchor.y + delta.dy / size.height).clamp(0.0, 1.0),
            ),
          ),
          size,
        );
      case _TextHandle.width:
        final projected =
            delta.dx * math.cos(base.rotation) +
            delta.dy * math.sin(base.rotation);
        final width = ((frame.width + projected) / size.width).clamp(
          .06,
          math.max(.06, 1 - base.anchor.x),
        );
        value = _revise(base, width: width.toDouble());
      case _TextHandle.transform:
        final from = _handleOrigin! - frame.center, to = point - frame.center;
        if (from.distance < 1 || to.distance < 1) return;
        final minFactor = math.max(
          8 / 1024 / base.fontSizeFraction,
          .06 / base.widthFraction,
        );
        final maxFactor = math.max(
          minFactor,
          [
            96 / 1024 / base.fontSizeFraction,
            1 / base.widthFraction,
            2 *
                math.min(frame.center.dx, size.width - frame.center.dx) /
                frame.width,
            2 *
                math.min(frame.center.dy, size.height - frame.center.dy) /
                frame.height,
          ].reduce(math.min),
        );
        final factor = (to.distance / from.distance).clamp(
          minFactor,
          maxFactor,
        );
        final angle =
            (base.rotation +
                    math.atan2(to.dy, to.dx) -
                    math.atan2(from.dy, from.dx) +
                    math.pi) %
                (math.pi * 2) -
            math.pi;
        value = _revise(
          base,
          size: base.fontSizeFraction * factor,
          width: base.widthFraction * factor,
          rotation: angle,
        );
        final nextFrame = _frame(value, size);
        value = _revise(
          value,
          anchor: NormalizedPoint(
            ((frame.center.dx - nextFrame.width / 2) / size.width).clamp(
              0.0,
              1.0,
            ),
            ((frame.center.dy - nextFrame.height / 2) / size.height).clamp(
              0.0,
              1.0,
            ),
          ),
        );
    }
    setState(() {
      if (_editorOpen) {
        _draft = value;
      } else {
        _preview = value;
      }
    });
  }

  void _handleUp(PointerUpEvent event, Size size) {
    if (_handlePointer != event.pointer) return;
    _handleMove(
      PointerMoveEvent(pointer: event.pointer, position: event.position),
      size,
    );
    final value = _editorOpen ? _draft : _preview, base = _handleBase;
    _endHandle?.call();
    _endHandle = null;
    _handlePointer = null;
    _handle = null;
    _handleBase = null;
    _handleOrigin = null;
    _writingEnd();
    if (_editorOpen) {
      setState(() {});
      _focus.requestFocus();
      return;
    }
    setState(() => _preview = null);
    if (value != null &&
        base != null &&
        canonicalReaderJson(value.geometry) !=
            canonicalReaderJson(base.geometry)) {
      _bindSelection(value, size);
      unawaited(
        widget.workspace.saveText(
          widget.page,
          value,
          expected: TextEditBase(base),
        ),
      );
    }
  }

  Matrix4 _rotationMatrix(Rect frame, double angle) => Matrix4.identity()
    ..translateByDouble(frame.width / 2, frame.height / 2, 0, 1)
    ..rotateZ(angle)
    ..translateByDouble(-frame.width / 2, -frame.height / 2, 0, 1);
  Widget _input(TextAnnotation value, Rect frame, Size size) => Positioned(
    left: frame.left,
    top: frame.top,
    width: frame.width,
    child: Transform(
      transform: _rotationMatrix(frame, value.rotation),
      child: MediaQuery.withNoTextScaling(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(44, math.min(240, size.height * .4)),
          ),
          child: TextField(
            key: _inputKey,
            controller: _controller,
            focusNode: _focus,
            style: textAnnotationStyle(value, size, fontFamily: _family),
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onTapOutside: (_) {},
            onChanged: (_) {
              setState(() {
                _error = null;
                _draft = _fit(_editingValue(size)!, size);
              });
              _scheduleReveal();
            },
            decoration: InputDecoration(
              hintText: '输入文字',
              isDense: true,
              filled: true,
              fillColor: const Color(0xe6ffffff),
              contentPadding: const EdgeInsets.only(bottom: 4),
              errorText: _error,
              border: const UnderlineInputBorder(),
            ),
          ),
        ),
      ),
    ),
  );
  double get _screenScale {
    final box = context.findRenderObject();
    return box is RenderBox
        ? box.getTransformTo(null).getMaxScaleOnAxis().clamp(.1, 20.0)
        : 1;
  }

  Widget _handleWidget(
    _TextHandle handle,
    TextAnnotation value,
    Rect frame,
    Size size,
    double scale,
  ) {
    final gap = 1 / scale;
    final local = switch (handle) {
      _TextHandle.move => frame.topLeft - Offset(24 * gap, 24 * gap),
      _TextHandle.transform => frame.bottomRight + Offset(16 * gap, 40 * gap),
      _TextHandle.width => frame.centerRight + Offset(36 * gap, 0),
    };
    final point = rotateTextPoint(local, frame.center, value.rotation);
    final side = 44 / scale;
    final centre = Offset(
      point.dx.clamp(side / 2, math.max(side / 2, size.width - side / 2)),
      point.dy.clamp(side / 2, math.max(side / 2, size.height - side / 2)),
    );
    final label = switch (handle) {
      _TextHandle.move => '移动文字',
      _TextHandle.transform => '缩放并旋转文字',
      _TextHandle.width => '调整换行宽度',
    };
    final icon = switch (handle) {
      _TextHandle.move => Icons.open_with,
      _TextHandle.transform => Icons.transform,
      _TextHandle.width => Icons.swap_horiz,
    };
    return Positioned(
      left: centre.dx - side / 2,
      top: centre.dy - side / 2,
      width: side,
      height: side,
      child: Listener(
        key: _handleKeys[handle],
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _handleDown(handle, e, size),
        onPointerMove: (e) => _handleMove(e, size),
        onPointerUp: (e) => _handleUp(e, size),
        onPointerCancel: (_) => setState(_cancelHandle),
        child: Tooltip(
          message: label,
          child: Semantics(
            label: label,
            button: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xfffaf9f5),
                borderRadius: BorderRadius.circular(8 / scale),
                border: Border.all(
                  color: const Color(0xff236459),
                  width: 1 / scale,
                ),
              ),
              child: Icon(
                icon,
                size: 22 / scale,
                color: const Color(0xff236459),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.workspace,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final value = _enabled ? (_editingValue(size) ?? _selection) : null;
        final frame = value == null ? null : _frame(value, size);
        final bounds = value == null ? null : _bounds(value, size);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _down(e, size),
          onPointerMove: (e) => _move(e, size),
          onPointerUp: (e) => _up(e, size),
          onPointerCancel: (e) {
            _touches.remove(e.pointer);
            if (_pointer == e.pointer) setState(_cancelPointer);
          },
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
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
                textPreview: _editorOpen ? null : _preview,
                hiddenTextId: _editorOpen ? _draft?.id : null,
              ),
              if (value != null && frame != null && bounds != null) ...[
                Positioned.fromRect(
                  rect: bounds,
                  child: IgnorePointer(
                    child: SizedBox(key: widget.selectionKey),
                  ),
                ),
                Positioned.fromRect(
                  rect: frame,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: value.rotation,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xff236459),
                            width: 1 / _screenScale,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_editorOpen) _input(value, frame, size),
                for (final handle in _TextHandle.values)
                  _handleWidget(handle, value, frame, size, _screenScale),
              ],
            ],
          ),
        );
      },
    ),
  );
}
