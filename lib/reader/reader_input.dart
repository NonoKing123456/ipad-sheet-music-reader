import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  });

  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;
  final bool allowPointerPageTurns;

  @override
  State<ReaderInput> createState() => _ReaderInputState();
}

class _ReaderInputState extends State<ReaderInput> {
  final FocusNode _focus = FocusNode(debugLabel: 'reader-page-controls');
  final Set<int> _pointers = {};
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
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _cancelled = true;
      return;
    }
    _origin = event.localPosition;
    _greatestTravel = 0;
    _cancelled =
        !widget.enabled ||
        !widget.allowPointerPageTurns ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons != kPrimaryButton);
    _focus.requestFocus();
  }

  void _move(PointerMoveEvent event) {
    if (_origin != null) {
      final travel = (event.localPosition - _origin!).distance;
      if (travel > _greatestTravel) _greatestTravel = travel;
    }
  }

  void _up(PointerUpEvent event, double width) {
    final origin = _origin;
    _pointers.remove(event.pointer);
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
      delta.dx < 0 ? widget.onNext() : widget.onPrevious();
    } else if (_greatestTravel < 12 && delta.distance < 12) {
      final fraction = event.localPosition.dx / width;
      if (fraction < 0.35) widget.onPrevious();
      if (fraction > 0.65) widget.onNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) => Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: (event) => _up(event, constraints.maxWidth),
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            _cancelled = true;
            if (_pointers.isEmpty) _origin = null;
          },
          child: widget.child,
        ),
      ),
    );
  }
}
