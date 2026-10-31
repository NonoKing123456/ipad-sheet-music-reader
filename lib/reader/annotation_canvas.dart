import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:reader_state/reader_state.dart';

import 'reader_workspace.dart';

double _segmentDistance(Offset point, Offset a, Offset b) {
  final delta = b - a;
  final squared = delta.dx * delta.dx + delta.dy * delta.dy;
  if (squared == 0) return (point - a).distance;
  final t = (((point - a).dx * delta.dx + (point - a).dy * delta.dy) / squared)
      .clamp(0.0, 1.0);
  return (point - (a + delta * t)).distance;
}

bool strokeHit(
  AnnotationStroke stroke,
  Offset point,
  Size paperSize,
  double radius,
) {
  final points = stroke.points
      .map((p) => Offset(p.x * paperSize.width, p.y * paperSize.height))
      .toList();
  final distance =
      radius + stroke.style.widthFraction * paperSize.shortestSide / 2;
  if (points.length == 1) return (point - points.single).distance <= distance;
  for (var i = 1; i < points.length; i++) {
    if (_segmentDistance(point, points[i - 1], points[i]) <= distance) {
      return true;
    }
  }
  return false;
}

/// Must fill the actual paper rectangle, inside the same transform as the page.
class AnnotationCanvas extends StatefulWidget {
  const AnnotationCanvas({
    super.key,
    required this.workspace,
    required this.page,
    required this.enabled,
    required this.style,
    this.eraser = false,
  });
  final ReaderWorkspace workspace;
  final PageKey page;
  final bool enabled;
  final StrokeStyle style;
  final bool eraser;
  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  final Set<int> _pointers = {};
  final List<NormalizedPoint> _draft = [];
  final Set<String> _eraseIds = {};
  int? _pointer;
  StrokeStyle? _style;
  bool _blocked = false;

  @override
  void didUpdateWidget(AnnotationCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.eraser != widget.eraser) {
      _clear();
    }
  }

  void _clear() {
    _draft.clear();
    _eraseIds.clear();
    _pointer = null;
    _blocked = true;
  }

  void _sample(Offset position, Size size) {
    if (_blocked || size.isEmpty) return;
    final clamped = Offset(
      position.dx.clamp(0.0, size.width),
      position.dy.clamp(0.0, size.height),
    );
    if (widget.eraser) {
      for (final stroke in widget.workspace.store.snapshot.strokesFor(
        widget.page,
      )) {
        if (strokeHit(
          stroke,
          clamped,
          size,
          math.max(8, size.shortestSide * .018),
        )) {
          _eraseIds.add(stroke.id);
        }
      }
    } else {
      final point = NormalizedPoint(
        clamped.dx / size.width,
        clamped.dy / size.height,
      );
      if (_draft.isEmpty ||
          (Offset(_draft.last.x * size.width, _draft.last.y * size.height) -
                      clamped)
                  .distance >=
              .7) {
        _draft.add(point);
      }
    }
  }

  void _down(PointerDownEvent event, Size size) {
    if (!widget.enabled) return;
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      setState(_clear);
      return;
    }
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryButton) {
      return;
    }
    _blocked = false;
    _pointer = event.pointer;
    _style = widget.style;
    setState(() => _sample(event.localPosition, size));
  }

  void _up(PointerUpEvent event, Size size) {
    _pointers.remove(event.pointer);
    if (_pointer != event.pointer || _blocked) return;
    _sample(event.localPosition, size);
    final page = widget.page;
    if (widget.eraser) {
      final ids = List<String>.of(_eraseIds);
      unawaited(
        widget.workspace.edit((store) async {
          for (final id in ids) {
            await store.eraseStroke(page, id);
          }
        }),
      );
    } else if (_draft.isNotEmpty) {
      unawaited(widget.workspace.addStroke(page, _style!, List.of(_draft)));
    }
    setState(_clear);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.workspace,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final painter = CustomPaint(
          painter: AnnotationPainter(
            strokes: widget.workspace.store.snapshot.strokesFor(widget.page),
            pending: widget.workspace.pendingFor(widget.page),
            draft: List.of(_draft),
            draftStyle: _style ?? widget.style,
          ),
          child: const SizedBox.expand(),
        );
        if (!widget.enabled) return IgnorePointer(child: painter);
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _down(event, size),
            onPointerMove: (event) {
              if (_pointer == event.pointer && !_blocked) {
                setState(() => _sample(event.localPosition, size));
              }
            },
            onPointerUp: (event) => _up(event, size),
            onPointerCancel: (event) {
              _pointers.remove(event.pointer);
              setState(_clear);
            },
            child: painter,
          ),
        );
      },
    ),
  );
}

class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.strokes,
    required this.pending,
    required this.draft,
    required this.draftStyle,
  });
  final List<AnnotationStroke> strokes;
  final List<PendingStroke> pending;
  final List<NormalizedPoint> draft;
  final StrokeStyle draftStyle;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final stroke in strokes) {
      _stroke(canvas, size, stroke.style, stroke.points);
    }
    for (final stroke in pending) {
      _stroke(canvas, size, stroke.style, stroke.points);
    }
    _stroke(canvas, size, draftStyle, draft);
    canvas.restore();
  }

  void _stroke(
    Canvas canvas,
    Size size,
    StrokeStyle style,
    List<NormalizedPoint> points,
  ) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = Color(style.argb)
      ..strokeWidth = math.max(.5, style.widthFraction * size.shortestSide)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final start = Offset(
      points.first.x * size.width,
      points.first.y * size.height,
    );
    if (points.length == 1) {
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(start, paint.strokeWidth / 2, paint);
      return;
    }
    final path = Path()..moveTo(start.dx, start.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.x * size.width, point.y * size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter oldDelegate) => true;
}
