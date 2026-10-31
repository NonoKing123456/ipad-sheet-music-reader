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
  bool verticalLocked = false,
}) {
  final fitted = pageAspect == null
      ? viewport
      : applyBoxFit(BoxFit.contain, Size(pageAspect, 1), viewport).destination;
  final paper = Alignment.center.inscribe(fitted, Offset.zero & viewport);
  (double, double) normalBounds(double start, double end, double extent) {
    if ((end - start) * scale <= extent) {
      final centered = extent / 2 - (start + end) * scale / 2;
      return (centered, centered);
    }
    return (extent - end * scale, -start * scale);
  }

  final (minX, maxX) = normalBounds(paper.left, paper.right, viewport.width);
  var (minY, maxY) = normalBounds(paper.top, paper.bottom, viewport.height);
  if (obstruction != null) {
    final top = math.min(obstruction.top, viewport.height * .45),
        bottom = math.min(obstruction.bottom, viewport.height * .45);
    final margin = math.min(24.0, (viewport.height - top - bottom) / 4);
    minY = math.min(
      minY,
      viewport.height - bottom - margin - paper.bottom * scale,
    );
    maxY = math.max(maxY, top + margin - paper.top * scale);
  }
  return Offset(
    translation.dx.clamp(minX, maxX),
    verticalLocked
        ? viewport.height * (1 - scale) / 2
        : translation.dy.clamp(minY, maxY),
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
    this.editing = false,
    this.gestureGeneration = 0,
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
  final bool editing;
  final int gestureGeneration;

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
  Axis? _singleAxis;
  int _touchGeneration = 0;

  @override
  void didUpdateWidget(covariant ReaderInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing != widget.editing ||
        oldWidget.gestureGeneration != widget.gestureGeneration) {
      final transforming = _touches.length >= 2;
      final generation = ++_touchGeneration;
      _pointers.clear();
      _touches.clear();
      _origin = null;
      _pinching = false;
      _singleAxis = null;
      _cancelled = true;
      if (transforming) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _touchGeneration) {
            widget.onTransformGestureChanged?.call(false);
          }
        });
      }
    }
  }

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
    EdgeInsets? obstruction = widget.editing ? widget.panInsets : null;
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
      verticalLocked: !widget.editing && scale <= 1.000001,
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
    if (_pointers.length == 1) {
      _touchGeneration++;
      _singleAxis = null;
    }
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
          (widget.editing || controller.value.getMaxScaleOnAxis() > 1.000001)) {
        final m = controller.value;
        final scale = m.getMaxScaleOnAxis();
        var delta = event.localPosition - _lastTouch;
        if (scale <= 1.000001 && _origin != null) {
          final travel = event.localPosition - _origin!;
          if (_singleAxis == null && travel.distance >= 12) {
            if (travel.dy.abs() > travel.dx.abs() * 1.2) {
              _singleAxis = Axis.vertical;
              delta = travel;
            } else if (travel.dx.abs() > travel.dy.abs() * 1.2) {
              _singleAxis = Axis.horizontal;
            }
          }
          if (_singleAxis == Axis.vertical) delta = Offset(0, delta.dy);
        }
        if (scale > 1.000001 || _singleAxis == Axis.vertical) {
          _matrix(scale, Offset(m.storage[12], m.storage[13]) + delta);
          _cancelled = true;
        }
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
