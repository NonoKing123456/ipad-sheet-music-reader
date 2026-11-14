import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A destination prepares one full paper plus existing bounded visible previews.
/// The outgoing tree freezes its already visible surfaces until handoff.
/// Both trees still paint: an invisible/offstage destination cannot acknowledge
/// that it is ready to replace the old reading surface.
class ReaderPresentationPolicy extends InheritedWidget {
  const ReaderPresentationPolicy({
    super.key,
    required this.limited,
    this.frozen = false,
    required super.child,
  });
  final bool limited, frozen;
  static bool limitedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderPresentationPolicy>()
          ?.limited ??
      false;
  static bool frozenOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderPresentationPolicy>()
          ?.frozen ??
      false;
  @override
  bool updateShouldNotify(ReaderPresentationPolicy oldWidget) =>
      limited != oldWidget.limited || frozen != oldWidget.frozen;
}

/// Ready means decoded; this acknowledgement means a ready surface actually
/// participated in a frame. The callback runs after that frame has finished.
class ReaderPaintAcknowledgement extends SingleChildRenderObjectWidget {
  const ReaderPaintAcknowledgement({
    super.key,
    required this.onPainted,
    required super.child,
  });
  final VoidCallback? onPainted;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReaderPaintBox(onPainted);
  @override
  void updateRenderObject(BuildContext context, RenderProxyBox renderObject) {
    (renderObject as _ReaderPaintBox).onPainted = onPainted;
  }
}

class _ReaderPaintBox extends RenderProxyBox {
  _ReaderPaintBox(this._onPainted);
  VoidCallback? _onPainted;
  bool _pending = false;
  set onPainted(VoidCallback? value) {
    final needsAcknowledgement = _onPainted == null && value != null;
    _onPainted = value;
    if (needsAcknowledgement) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final callback = _onPainted;
    if (callback == null || _pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (attached) callback();
    });
  }
}
