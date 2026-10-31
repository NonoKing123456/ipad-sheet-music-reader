import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

enum ReaderTool { pen, highlighter, eraser }

extension ReaderToolAppearance on ReaderTool {
  String get label => switch (this) {
    ReaderTool.pen => '画笔',
    ReaderTool.highlighter => '荧光笔',
    ReaderTool.eraser => '橡皮',
  };
  IconData get icon => switch (this) {
    ReaderTool.pen => Icons.edit,
    ReaderTool.highlighter => Icons.highlight,
    ReaderTool.eraser => Icons.auto_fix_normal,
  };
  double get minSize => this == ReaderTool.pen ? 1 : 4;
  double get maxSize => this == ReaderTool.highlighter ? 64 : 48;
}

class ReaderToolButton extends StatefulWidget {
  const ReaderToolButton({
    super.key,
    required this.tool,
    required this.selected,
    required this.value,
    required this.onSelect,
    required this.onChanged,
  });
  final ReaderTool tool;
  final bool selected;
  final double value;
  final VoidCallback onSelect;
  final ValueChanged<double> onChanged;
  @override
  State<ReaderToolButton> createState() => _ReaderToolButtonState();
}

class _ReaderToolButtonState extends State<ReaderToolButton> {
  final _portal = OverlayPortalController(), _targetKey = GlobalKey();
  final _link = LayerLink();
  double _start = 1, _travel = 0;
  bool _dragging = false;
  double _stepValue(double direction) =>
      (widget.value + direction * math.max(1, widget.value * .15)).clamp(
        widget.tool.minSize,
        widget.tool.maxSize,
      );
  void _finish({bool cancel = false}) {
    if (!_dragging) return;
    if (cancel) widget.onChanged(_start);
    _dragging = false;
    _portal.hide();
  }

  Widget _feedback(BuildContext context) {
    final box = _targetKey.currentContext!.findRenderObject()! as RenderBox;
    final centre = box.localToGlobal(box.size.center(Offset.zero)).dx;
    final desired = centre - 62, width = MediaQuery.sizeOf(context).width;
    final dx = desired.clamp(8.0, math.max(8.0, width - 132)) - desired;
    return Positioned(
      left: 0,
      top: 0,
      width: 124,
      height: 62,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomCenter,
        followerAnchor: Alignment.topCenter,
        offset: Offset(dx, 6),
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xfffaf9f5),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.tool.label} ${widget.value.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 12),
              ),
              SizedBox(
                width: 86,
                height: 32,
                child: CustomPaint(
                  painter: _ToolPreview(widget.tool, widget.value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      onPressed: widget.onSelect,
      isSelected: widget.selected,
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        minimumSize: const Size(44, 44),
        maximumSize: const Size(44, 44),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: widget.selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: Icon(widget.tool.icon, size: 22),
    );
    final gesture = GestureDetector(
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (_) {
        _start = widget.value;
        _travel = 0;
        _dragging = true;
        widget.onSelect();
        _portal.show();
      },
      onHorizontalDragUpdate: (event) {
        _travel += event.delta.dx;
        final lo = math.log(widget.tool.minSize),
            span = math.log(widget.tool.maxSize / widget.tool.minSize);
        final fraction = ((math.log(_start) - lo) / span + _travel / 180).clamp(
          0.0,
          1.0,
        );
        widget.onChanged(math.exp(lo + span * fraction));
      },
      onHorizontalDragEnd: (_) => _finish(),
      onHorizontalDragCancel: () => _finish(cancel: true),
      child: ExcludeSemantics(child: button),
    );
    final accessible = Semantics(
      button: true,
      label: widget.tool.label,
      selected: widget.selected,
      value: widget.value.toStringAsFixed(1),
      increasedValue: _stepValue(1).toStringAsFixed(1),
      decreasedValue: _stepValue(-1).toStringAsFixed(1),
      onTap: widget.onSelect,
      onIncrease: () => widget.onChanged(_stepValue(1)),
      onDecrease: () => widget.onChanged(_stepValue(-1)),
      child: Tooltip(
        message: '${widget.tool.label}；左右拖动调大小',
        triggerMode: TooltipTriggerMode.manual,
        excludeFromSemantics: true,
        child: gesture,
      ),
    );
    return Listener(
      onPointerCancel: (_) => _finish(cancel: true),
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _feedback,
        child: CompositedTransformTarget(
          key: _targetKey,
          link: _link,
          child: accessible,
        ),
      ),
    );
  }
}

class _ToolPreview extends CustomPainter {
  _ToolPreview(this.tool, this.value);
  final ReaderTool tool;
  final double value;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff236459)
      ..strokeCap = StrokeCap.round;
    if (tool == ReaderTool.eraser) {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 1.5;
      canvas.drawCircle(
        size.center(Offset.zero),
        (value / 2).clamp(2.0, 14.0),
        paint,
      );
    } else {
      paint.strokeWidth = (value / 2).clamp(1.0, 24.0);
      canvas.drawLine(
        Offset(10, size.height / 2),
        Offset(size.width - 10, size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ToolPreview old) =>
      old.tool != tool || old.value != value;
}

/// The last successful sample belongs to the eyedropper, independently of the
/// active palette color. An empty swatch has a slash; white samples have a rim.
class ReaderSampleColorButton extends StatelessWidget {
  const ReaderSampleColorButton({
    super.key,
    required this.sample,
    required this.picking,
    required this.busy,
    required this.usingSample,
    required this.onPressed,
  });
  final Color? sample;
  final bool picking, busy, usingSample;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = picking
        ? '取消吸色'
        : sample == null
        ? '吸取谱面底色'
        : '底色画笔：使用此颜色或重新吸色';
    return Semantics(
      button: true,
      selected: picking || usingSample,
      label: label,
      value: sample == null ? '尚未吸色' : '最近吸取的颜色',
      onTap: onPressed,
      child: ExcludeSemantics(
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          isSelected: picking || usingSample,
          style: IconButton.styleFrom(
            fixedSize: const Size(44, 44),
            minimumSize: const Size(44, 44),
            maximumSize: const Size(44, 44),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: picking || usingSample
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: SizedBox.square(
            dimension: 30,
            child: Stack(
              children: [
                const Positioned(
                  left: 0,
                  top: 0,
                  child: Icon(Icons.colorize, size: 23),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    key: const ValueKey('sample-color-swatch'),
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      color: sample ?? Colors.transparent,
                      border: Border.all(
                        color: const Color(0xff52615c),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: sample == null
                        ? const Icon(
                            Icons.remove,
                            key: ValueKey('sample-color-empty'),
                            size: 12,
                          )
                        : null,
                  ),
                ),
                if (picking)
                  const Positioned(
                    right: 0,
                    top: 0,
                    child: Icon(Icons.add_circle, size: 11),
                  ),
                if (usingSample && !picking)
                  const Positioned(
                    right: 0,
                    top: 0,
                    child: Icon(Icons.check_circle, size: 11),
                  ),
                if (busy)
                  const Positioned.fill(
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
