import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reader_state/reader_state.dart';

import 'annotation_canvas.dart';
import 'reader_text_editing.dart';
import 'reader_workspace.dart';
import 'text_rotation_snap.dart';
import 'text_handle_layout.dart';

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

class _AnnotationTextLayerState extends State<AnnotationTextLayer>
    with WidgetsBindingObserver {
  final _fallbackControls = ReaderTextEditorController();
  final _handlePortal = OverlayPortalController();
  ReaderTextEditorController get _controls =>
      widget.textControls ?? _fallbackControls;
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _inputKey = GlobalKey();
  final _handleKeys = {
    for (final handle in TextHandleKind.values) handle: GlobalKey(),
  };
  String? _selected, _error;
  TextAnnotation? _original, _preview, _candidate, _editBase, _draft;
  Offset? _origin, _globalOrigin;
  double _slop = kTouchSlop;
  final _touches = <int>{};
  final _paperSessionPointers = <int>{};
  Size _lastSize = Size.zero;
  bool _committing = false;
  int? _pointer, _handlePointer;
  bool _dragged = false;
  TextHandleKind? _handle;
  final _rotationSnap = TextRotationSnap();
  bool _handleMoved = false;
  TextAnnotation? _handleBase;
  Offset? _handleOrigin;
  VoidCallback? _endEditing, _endHandle;
  Matrix4? _beforeReveal, _revealedTransform;
  bool _revealWaitingForPaint = false;
  double _nextSize = 20 / 1024;
  bool _automaticNewWidth = false;
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
    int? argb,
  }) => value.revise(
    anchor: anchor,
    fontSizeFraction: size,
    widthFraction: width,
    rotation: rotation,
    font: font,
    argb: argb,
    now: value.updatedUtc,
    version: value.version,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.transform?.addListener(_transformChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handlePortal.show();
    });
    _focus.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          !_committing) {
        if (_controller.value.composing.isValid &&
            !_controller.value.composing.isCollapsed) {
          return KeyEventResult.ignored;
        }
        _cancelEditor();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
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
    if (oldWidget.page != widget.page || !widget.enabled || !widget.textTool) {
      _closeEditor();
      _selected = null;
      _controls.release(this);
      _touches.clear();
      _cancelPointer(defer: true);
      _cancelHandle(defer: true);
    } else if (!oldWidget.suspended && widget.suspended) {
      _controls.cancelPaperTap();
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
    _rotationSnap.reset();
    _handleMoved = false;
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
    if (widget.textTool && _controls.editing) {
      if (readerTextHandleActive ||
          !_primary(event) ||
          _inside(widget.topControlsKey, event.position) ||
          _inside(widget.mouseControlKey, event.position)) {
        return;
      }
      final blank =
          !_inside(_inputKey, event.position) &&
          !_handleKeys.values.any((key) => _inside(key, event.position));
      _paperSessionPointers.add(event.pointer);
      _controls.paperDown(event, blank: blank);
      return;
    }
    if (!_enabled ||
        size.isEmpty ||
        _editorOpen ||
        _handlePointer != null ||
        _committing ||
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
    if (_paperSessionPointers.contains(event.pointer)) {
      _controls.paperMove(event);
      return;
    }
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
    if (_paperSessionPointers.remove(event.pointer)) {
      _controls.paperUp(event);
      return;
    }
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
      argb: value.argb,
      editing: false,
      release: _releaseSelection,
      onEdit: () => _editor(size),
      onDelete: _deleteSelection,
      onColor: _colorSelection,
    );
  }

  Future<bool> _colorSelection(int argb) async {
    final value = _selection;
    if (value == null || value.argb == argb) return true;
    final desired = _revise(value, argb: argb);
    final saved = await widget.workspace.saveText(
      widget.page,
      desired,
      expected: TextEditBase(value),
    );
    if (!saved && mounted) {
      _editor(_lastSize);
      setState(() => _error = '未能保存，内容已保留。请再次点谱面重试。');
    }
    return saved;
  }

  Future<bool> _changeColor(int argb) async {
    if (!_editorOpen || _committing) return false;
    _controls.argb = argb;
    setState(() => _draft = _revise(_draft!, argb: argb));
    _focus.requestFocus();
    return true;
  }

  void _cancelEditor() {
    if (!_editorOpen || _committing) return;
    setState(_closeEditor);
    if (_selection case final selected?) _bindSelection(selected, _lastSize);
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
    _automaticNewWidth = false;
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

  Rect _visiblePaper(Size size) {
    final paper = context.findRenderObject();
    final viewport = widget.viewportKey?.currentContext?.findRenderObject();
    if (paper is! RenderBox ||
        !paper.hasSize ||
        viewport is! RenderBox ||
        !viewport.hasSize) {
      return Offset.zero & size;
    }
    final visible = Rect.fromPoints(
      paper.globalToLocal(viewport.localToGlobal(Offset.zero)),
      paper.globalToLocal(
        viewport.localToGlobal(viewport.size.bottomRight(Offset.zero)),
      ),
    );
    final result = visible.intersect(Offset.zero & size);
    return result.isEmpty ? Offset.zero & size : result;
  }

  TextAnnotation _sizeNewDraft(TextAnnotation value, Size size) {
    final visible = _visiblePaper(size), scale = _screenScale;
    final margin = 4 / scale;
    final limit = math.max(
      1.0,
      math.min(size.width * .30, visible.width * .33),
    );
    final fontHeight = value.fontSizeFraction * size.shortestSide;
    final initial = (fontHeight * 7 + 12 / scale).clamp(90.0, 120.0);
    final painter = TextPainter(
      text: TextSpan(
        text: _controller.text,
        style: textAnnotationStyle(value, size, fontFamily: _family),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final measured = painter.width + 12 / scale;
    painter.dispose();
    final width = math.min(limit, math.max(initial, measured));
    var result = _fit(_revise(value, width: width / size.width), size);
    final left = visible.left + margin;
    final right = math.max(left, visible.right - margin - width);
    result = _revise(
      result,
      anchor: NormalizedPoint(
        ((result.anchor.x * size.width).clamp(left, right) / size.width).clamp(
          0.0,
          1.0,
        ),
        result.anchor.y,
      ),
    );
    return result;
  }

  void _editor(Size size, {NormalizedPoint? anchor}) {
    if (_editorOpen || !_enabled || !_controls.availableTo(this)) return;
    final selected = anchor == null ? _selection : null;
    _editBase = selected;
    _automaticNewWidth = selected == null;
    _controller.text = selected?.text ?? '';
    _draft =
        selected ??
        widget.workspace.store.newText(
          text: '输入文字',
          anchor: anchor!,
          argb: _controls.argb | 0xff000000,
          fontSizeFraction: _nextSize,
        );
    if (selected == null) _draft = _sizeNewDraft(_draft!, size);
    final bound = _controls.bind(
      this,
      argb: _draft!.argb,
      editing: true,
      release: _releaseSelection,
      onColor: _changeColor,
      onCancel: _cancelEditor,
      onDelete: selected == null ? null : _deleteEditing,
      onDone: () => _finishEditor(_lastSize),
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

  Future<bool> _finishEditor(Size size) async {
    if (!_editorOpen) return true;
    if (_controller.text.trim().isEmpty) {
      if (_editBase != null) return _deleteEditing();
      _cancelEditor();
      return true;
    }
    if (_controller.text.length > 8192) {
      setState(() => _error = '文字过长，请缩短至 8192 字以内。');
      return false;
    }
    final desired = _editingValue(size)!, base = _editBase;
    setState(() => _committing = true);
    final saved = await widget.workspace.saveText(
      widget.page,
      desired,
      expected: TextEditBase(base),
    );
    if (!mounted) return saved;
    setState(() => _committing = false);
    if (!saved) {
      setState(() => _error = '未能保存，内容已保留。请再次点谱面重试。');
      _focus.requestFocus();
      return false;
    }
    _nextSize = desired.fontSizeFraction;
    setState(() {
      _selected = desired.id;
      _closeEditor();
    });
    _bindSelection(desired, _lastSize);
    return true;
  }

  Future<bool> _deleteEditing() async {
    final base = _editBase;
    if (base == null || _committing) return false;
    setState(() => _committing = true);
    final saved = await widget.workspace.saveText(
      widget.page,
      base.withDeletion(true, DateTime.now().toUtc()),
      expected: TextEditBase(base),
    );
    if (!mounted) return saved;
    setState(() {
      _committing = false;
      if (saved) {
        _selected = null;
        _closeEditor();
      } else {
        _error = '未能保存，内容已保留。请再次点谱面重试。';
      }
    });
    return saved;
  }

  Offset _paperPoint(Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global);
  void _handleDown(TextHandleKind handle, PointerDownEvent event, Size size) {
    if (!_enabled ||
        !_primary(event) ||
        _handlePointer != null ||
        _committing ||
        !_controls.availableTo(this) ||
        widget.workspace.savingAnnotations) {
      return;
    }
    final value = _editingValue(size) ?? _selection;
    if (value == null) return;
    _handlePointer = event.pointer;
    _handle = handle;
    _rotationSnap.reset();
    _handleMoved = false;
    _handleBase = value;
    _handleOrigin = _paperPoint(event.position);
    _cancelPointer();
    _controls.cancelPaperTap();
    _endHandle = beginReaderTextEditing(blockPaperGestures: true);
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
    if (!_handleMoved && delta.distance * _screenScale < 2) return;
    _handleMoved = true;
    if (_editorOpen &&
        (_handle == TextHandleKind.width ||
            _handle == TextHandleKind.transform)) {
      _automaticNewWidth = false;
    }
    TextAnnotation value;
    switch (_handle!) {
      case TextHandleKind.move:
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
      case TextHandleKind.width:
        final projected =
            delta.dx * math.cos(base.rotation) +
            delta.dy * math.sin(base.rotation);
        final width = ((frame.width + projected) / size.width).clamp(
          .06,
          math.max(.06, 1 - base.anchor.x),
        );
        value = _revise(base, width: width.toDouble());
      case TextHandleKind.transform:
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
          rotation: _rotationSnap.update(angle),
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
    _rotationSnap.reset();
    _handleMoved = false;
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
            readOnly: _committing,
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
                final value = _editingValue(size)!;
                _draft = _automaticNewWidth
                    ? _sizeNewDraft(value, size)
                    : _fit(value, size);
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

  Widget _handleOverlay(
    BuildContext overlayContext,
    TextAnnotation value,
    Rect frame,
    Size size,
    double scale,
  ) {
    final paper = context.findRenderObject();
    final overlay = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    if (paper is! RenderBox ||
        !paper.hasSize ||
        overlay is! RenderBox ||
        !overlay.hasSize) {
      return const SizedBox.shrink();
    }
    final media = MediaQuery.of(overlayContext), view = View.of(overlayContext);
    final viewportBox = widget.viewportKey?.currentContext?.findRenderObject();
    final viewport = viewportBox is RenderBox && viewportBox.hasSize
        ? Rect.fromPoints(
            viewportBox.localToGlobal(Offset.zero),
            viewportBox.localToGlobal(
              viewportBox.size.bottomRight(Offset.zero),
            ),
          )
        : Offset.zero & media.size;
    final tools = widget.topControlsKey?.currentContext?.findRenderObject();
    final top = tools is RenderBox && tools.hasSize
        ? math.max(
            viewport.top,
            tools.localToGlobal(Offset(0, tools.size.height)).dy,
          )
        : viewport.top;
    final visible = Rect.fromLTRB(
      math.max(0, viewport.left),
      top,
      math.min(media.size.width, viewport.right),
      math.min(
        viewport.bottom,
        media.size.height - view.viewInsets.bottom / view.devicePixelRatio,
      ),
    );
    if (visible.isEmpty) return const SizedBox.shrink();
    final paperViewport = Rect.fromPoints(
      paper.globalToLocal(visible.topLeft),
      paper.globalToLocal(visible.bottomRight),
    );
    // The editable underline has four pixels of bottom padding. Keep target
    // geometry outside that padding as well as outside the painted text.
    final controlFrame = _editorOpen
        ? Rect.fromLTRB(frame.left, frame.top, frame.right, frame.bottom + 4)
        : frame;
    final placements = layoutTextHandles(
      frame: controlFrame,
      rotationCentre: frame.center,
      viewport: paperViewport,
      rotation: value.rotation,
      scale: scale,
    );
    final clipRect = Rect.fromPoints(
      overlay.globalToLocal(visible.topLeft),
      overlay.globalToLocal(visible.bottomRight),
    );
    return Stack(
      children: [
        Positioned.fromRect(
          rect: clipRect,
          child: ClipRect(
            child: Stack(
              children: [
                for (final handle in TextHandleKind.values)
                  _handleWidget(
                    handle,
                    value,
                    frame,
                    size,
                    scale,
                    placements[handle]!,
                    paper,
                    overlay,
                    clipRect.topLeft,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _handleWidget(
    TextHandleKind handle,
    TextAnnotation value,
    Rect frame,
    Size size,
    double scale,
    TextHandlePlacement placement,
    RenderBox paper,
    RenderBox overlay,
    Offset clipOrigin,
  ) {
    final point = rotateTextPoint(
      placement.hitRect.center,
      frame.center,
      value.rotation,
    );
    final centre =
        overlay.globalToLocal(paper.localToGlobal(point)) - clipOrigin;
    final visualOffset =
        (placement.visualRect.topLeft - placement.hitRect.topLeft) * scale;
    final label = switch (handle) {
      TextHandleKind.move => '移动文字',
      TextHandleKind.transform => '缩放并旋转文字',
      TextHandleKind.width => '调整换行宽度',
    };
    final icon = switch (handle) {
      TextHandleKind.move => Icons.open_with,
      TextHandleKind.transform => Icons.rotate_right,
      TextHandleKind.width => Icons.swap_horiz,
    };
    return Positioned(
      left: centre.dx - 22,
      top: centre.dy - 22,
      width: 44,
      height: 44,
      child: Transform.rotate(
        angle: value.rotation,
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
              child: Stack(
                children: [
                  Positioned(
                    left: visualOffset.dx,
                    top: visualOffset.dy,
                    width: 28,
                    height: 28,
                    child: DecoratedBox(
                      key: ValueKey('text-handle-visual-${handle.name}'),
                      decoration: BoxDecoration(
                        color: const Color(0xfffaf9f5),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: const Color(0xff52615c)),
                      ),
                      child: Icon(
                        icon,
                        size: 16,
                        color: const Color(0xff52615c),
                      ),
                    ),
                  ),
                ],
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
        _lastSize = size;
        final value = widget.enabled && widget.textTool
            ? (_editingValue(size) ?? _selection)
            : null;
        final frame = value == null ? null : _frame(value, size);
        final bounds = value == null ? null : _bounds(value, size);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (_) => _controls.cancelPaperTap(),
          onPointerDown: (e) => _down(e, size),
          onPointerMove: (e) => _move(e, size),
          onPointerUp: (e) => _up(e, size),
          onPointerCancel: (e) {
            if (_paperSessionPointers.remove(e.pointer)) {
              _controls.paperCancel(e.pointer);
            }
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
                if (_handle == TextHandleKind.transform &&
                    _rotationSnap.guideAngle != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: const ValueKey('text-rotation-guide'),
                        painter: _RotationGuide(
                          frame.center,
                          math.max(frame.width, frame.height) / 2 +
                              36 / _screenScale,
                          _rotationSnap.guideAngle!,
                          _screenScale,
                        ),
                      ),
                    ),
                  ),
              ],
              OverlayPortal(
                controller: _handlePortal,
                overlayChildBuilder: (overlayContext) =>
                    value == null || frame == null
                    ? const SizedBox.shrink()
                    : _handleOverlay(
                        overlayContext,
                        value,
                        frame,
                        size,
                        _screenScale,
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _RotationGuide extends CustomPainter {
  const _RotationGuide(this.centre, this.length, this.angle, this.scale);
  final Offset centre;
  final double length, angle, scale;
  @override
  void paint(Canvas canvas, Size size) {
    final vertical = math.sin(angle).abs() > .5;
    final direction = vertical ? const Offset(0, 1) : const Offset(1, 0);
    final paint = Paint()
      ..color = const Color(0xaa39796d)
      ..strokeWidth = 1 / scale;
    for (var distance = -length; distance < length; distance += 8 / scale) {
      canvas.drawLine(
        centre + direction * distance,
        centre + direction * math.min(length, distance + 4 / scale),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RotationGuide old) =>
      old.centre != centre ||
      old.length != length ||
      old.angle != angle ||
      old.scale != scale;
}
