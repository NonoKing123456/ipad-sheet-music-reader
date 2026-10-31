import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Clamp against actual paper edges and the unobstructed writing area. This
/// keeps the page reachable at 1x without changing its fit size or losing it.
Offset clampReaderPan({
  required Size viewport,
  required double scale,
  required Offset translation,
  double? pageAspect,
  EdgeInsets? obstruction,
}) {
  if (obstruction == null) {
    return Offset(
      translation.dx.clamp(viewport.width * (1 - scale), 0.0),
      translation.dy.clamp(viewport.height * (1 - scale), 0.0),
    );
  }
  final fitted = pageAspect == null
      ? viewport
      : applyBoxFit(BoxFit.contain, Size(pageAspect, 1), viewport).destination;
  final paper = Alignment.center.inscribe(fitted, Offset.zero & viewport);
  final left = math.min(obstruction.left, viewport.width * .45),
      right = math.min(obstruction.right, viewport.width * .45);
  final top = math.min(obstruction.top, viewport.height * .45),
      bottom = math.min(obstruction.bottom, viewport.height * .45);
  final mx = math.min(24.0, (viewport.width - left - right) / 4),
      my = math.min(24.0, (viewport.height - top - bottom) / 4);
  final ax = left + mx - paper.left * scale,
      bx = viewport.width - right - mx - paper.right * scale;
  final ay = top + my - paper.top * scale,
      by = viewport.height - bottom - my - paper.bottom * scale;
  return Offset(
    translation.dx.clamp(math.min(ax, bx), math.max(ax, bx)),
    translation.dy.clamp(math.min(ay, by), math.max(ay, by)),
  );
}

/// Shared reading input. Page turning is classified once at pointer-up, so a
/// swipe can never also become a tap. This layer does not distinguish a pedal
/// from a keyboard: both send ordinary PageUp/PageDown events.
class ReaderInput extends StatefulWidget {
  const ReaderInput({
    super.key,
    required this.child,
    required this.onPrevious,
    required this.onNext,
    this.enabled = true,
    this.allowPointerPageTurns = true,
    this.onCenterTap,
    this.transform,
    this.viewportKey,
    this.mouseInk = false,
    this.onTransformGestureChanged,
    this.panInsets,
    this.pageAspect,
  });

  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;
  final bool allowPointerPageTurns;
  final VoidCallback? onCenterTap;
  final TransformationController? transform;
  final GlobalKey? viewportKey;
  final bool mouseInk;
  final ValueChanged<bool>? onTransformGestureChanged;
  final EdgeInsets? panInsets;
  final double? pageAspect;

  @override
  State<ReaderInput> createState() => _ReaderInputState();
}

class _ReaderInputState extends State<ReaderInput> {
  final FocusNode _focus = FocusNode(debugLabel: 'reader-page-controls');
  final Set<int> _pointers = {};
  final Set<int> _inkPointers = {};
  final Map<int, Offset> _touches = {};
  double _pinchDistance = 1, _startScale = 1;
  Offset _sceneAnchor = Offset.zero, _lastTouch = Offset.zero;
  Size _size = Size.zero;
  bool _pinching = false;

  void _anchorPinch() {
    if (_touches.length != 2 || widget.transform == null) return;
    final a = _touches.values.first, b = _touches.values.last;
    _pinchDistance = (a - b).distance.clamp(1.0, double.infinity);
    _startScale = widget.transform!.value.getMaxScaleOnAxis();
    _sceneAnchor = widget.transform!.toScene((a + b) / 2);
    _pinching = true;
  }

  void _matrix(double scale, Offset translation) {
    final controller = widget.transform;
    if (controller == null) return;
    EdgeInsets? obstruction = widget.panInsets;
    if (obstruction != null) {
      final box =
          (widget.viewportKey?.currentContext?.findRenderObject() ??
                  context.findRenderObject())
              as RenderBox?;
      if (box != null && box.hasSize) {
        final origin = box.localToGlobal(Offset.zero),
            screen = MediaQuery.sizeOf(context);
        obstruction = EdgeInsets.fromLTRB(
          math.max(0, obstruction.left - origin.dx),
          math.max(0, obstruction.top - origin.dy),
          math.max(
            0,
            origin.dx + _size.width - (screen.width - obstruction.right),
          ),
          math.max(
            0,
            origin.dy + _size.height - (screen.height - obstruction.bottom),
          ),
        );
      }
    }
    final bounded = clampReaderPan(
      viewport: _size,
      scale: scale,
      translation: translation,
      pageAspect: widget.pageAspect,
      obstruction: obstruction,
    );
    controller.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(bounded.dx, bounded.dy, 0);
  }

  Offset? _origin;
  bool _cancelled = false;
  double _greatestTravel = 0;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _editingText {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.widget is EditableText ||
        context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || _editingText) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final previous = event.logicalKey == LogicalKeyboardKey.pageUp;
    final next = event.logicalKey == LogicalKeyboardKey.pageDown;
    if (!previous && !next) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      previous ? widget.onPrevious() : widget.onNext();
    }
    return KeyEventResult.handled;
  }

  void _down(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus ||
        (widget.mouseInk && event.kind == PointerDeviceKind.mouse)) {
      _inkPointers.add(event.pointer);
      if (_pointers.isNotEmpty) _cancelled = true;
      return;
    }
    _pointers.add(event.pointer);
    if (event.kind == PointerDeviceKind.touch) {
      _touches[event.pointer] = event.localPosition;
      _lastTouch = event.localPosition;
      _anchorPinch();
      if (_touches.length == 2) widget.onTransformGestureChanged?.call(true);
    }
    if (_pointers.length > 1) {
      _cancelled = true;
      return;
    }
    _origin = event.localPosition;
    _greatestTravel = 0;
    _cancelled =
        !widget.enabled ||
        _inkPointers.isNotEmpty ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons != kPrimaryButton);
    _focus.requestFocus();
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.contains(event.pointer)) return;
    if (_touches.containsKey(event.pointer)) {
      _touches[event.pointer] = event.localPosition;
      final controller = widget.transform;
      if (controller != null && _touches.length == 2) {
        final a = _touches.values.first, b = _touches.values.last;
        final scale = (_startScale * (a - b).distance / _pinchDistance).clamp(
          1.0,
          4.0,
        );
        _matrix(scale, (a + b) / 2 - _sceneAnchor * scale);
      } else if (controller != null &&
          !_pinching &&
          _inkPointers.isEmpty &&
          _touches.length == 1 &&
          controller.value.getMaxScaleOnAxis() > 1.01) {
        final m = controller.value;
        _matrix(
          m.getMaxScaleOnAxis(),
          Offset(m.storage[12], m.storage[13]) +
              event.localPosition -
              _lastTouch,
        );
        _cancelled = true;
      }
      _lastTouch = event.localPosition;
    }
    if (_origin != null) {
      final travel = (event.localPosition - _origin!).distance;
      if (travel > _greatestTravel) _greatestTravel = travel;
    }
  }

  void _up(PointerUpEvent event, double width) {
    if (_inkPointers.remove(event.pointer)) return;
    if (!_pointers.contains(event.pointer)) return;
    final origin = _origin;
    _pointers.remove(event.pointer);
    if (_touches.length == 2 && _touches.containsKey(event.pointer)) {
      widget.onTransformGestureChanged?.call(false);
    }
    _touches.remove(event.pointer);
    if (_touches.isEmpty) _pinching = false;
    if (_cancelled ||
        origin == null ||
        _pointers.isNotEmpty ||
        !widget.enabled) {
      if (_pointers.isEmpty) _origin = null;
      return;
    }
    final delta = event.localPosition - origin;
    _origin = null;
    if (delta.dx.abs() >= 48 && delta.dx.abs() > delta.dy.abs() * 1.4) {
      if (widget.allowPointerPageTurns) {
        delta.dx < 0 ? widget.onNext() : widget.onPrevious();
      }
    } else if (_greatestTravel < 12 && delta.distance < 12) {
      final fraction = event.localPosition.dx / width;
      if (fraction >= 0.35 && fraction <= 0.65) widget.onCenterTap?.call();
      if (widget.allowPointerPageTurns) {
        if (fraction < 0.35) widget.onPrevious();
        if (fraction > 0.65) widget.onNext();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = constraints.biggest;
          final content = widget.transform == null
              ? widget.child
              : ClipRect(
                  key: widget.viewportKey,
                  child: AnimatedBuilder(
                    animation: widget.transform!,
                    child: widget.child,
                    builder: (_, child) => Transform(
                      alignment: Alignment.topLeft,
                      transform: widget.transform!.value,
                      child: child,
                    ),
                  ),
                );
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: (event) => _up(event, constraints.maxWidth),
            onPointerCancel: (event) {
              _inkPointers.remove(event.pointer);
              _pointers.remove(event.pointer);
              if (_touches.length == 2 && _touches.containsKey(event.pointer)) {
                widget.onTransformGestureChanged?.call(false);
              }
              _touches.remove(event.pointer);
              if (_touches.isEmpty) _pinching = false;
              _cancelled = true;
              if (_pointers.isEmpty) _origin = null;
            },
            child: content,
          );
        },
      ),
    );
  }
}
