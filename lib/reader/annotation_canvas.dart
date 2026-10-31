import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reader_state/reader_state.dart';

import 'reader_workspace.dart';
import 'incremental_stroke_path.dart';

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

/// Subtracts a swept circular eraser analytically, including sparse fast moves.
/// Coordinates and radius are in the untransformed paper's logical pixels.
List<List<NormalizedPoint>> eraseStrokePath(
  List<NormalizedPoint> points,
  Size size,
  Offset from,
  Offset to,
  double radius,
) {
  Offset pixel(NormalizedPoint p) =>
      Offset(p.x * size.width, p.y * size.height);
  NormalizedPoint normal(Offset p) => NormalizedPoint(
    (p.dx / size.width).clamp(0.0, 1.0),
    (p.dy / size.height).clamp(0.0, 1.0),
  );
  if (points.length == 1) {
    return _segmentDistance(pixel(points.single), from, to) <= radius
        ? []
        : [points];
  }
  final result = <List<NormalizedPoint>>[];
  var touched = false;
  List<NormalizedPoint>? run;
  for (var i = 1; i < points.length; i++) {
    final a = pixel(points[i - 1]), d = pixel(points[i]) - a;
    final cuts = <(double, double)>[];
    void circle(Offset centre) {
      final q = a - centre;
      final aa = d.distanceSquared;
      if (aa == 0) {
        if (q.distance <= radius) cuts.add((0, 1));
        return;
      }
      final b = 2 * (q.dx * d.dx + q.dy * d.dy);
      final c = q.distanceSquared - radius * radius;
      final disc = b * b - 4 * aa * c;
      if (disc < 0) return;
      final lo = math.max(0.0, (-b - math.sqrt(disc)) / (2 * aa));
      final hi = math.min(1.0, (-b + math.sqrt(disc)) / (2 * aa));
      if (lo <= hi) cuts.add((lo, hi));
    }

    circle(from);
    circle(to);
    final e = to - from;
    final length = e.distance;
    if (length > 0) {
      final u = e / length;
      final q = a - from;
      var lo = 0.0, hi = 1.0;
      void bound(double value, double slope, double lower, double upper) {
        if (slope.abs() < 1e-12) {
          if (value < lower || value > upper) hi = -1;
        } else {
          final x = (lower - value) / slope, y = (upper - value) / slope;
          lo = math.max(lo, math.min(x, y));
          hi = math.min(hi, math.max(x, y));
        }
      }

      bound(q.dx * u.dx + q.dy * u.dy, d.dx * u.dx + d.dy * u.dy, 0, length);
      bound(
        q.dx * -u.dy + q.dy * u.dx,
        d.dx * -u.dy + d.dy * u.dx,
        -radius,
        radius,
      );
      if (lo <= hi) cuts.add((lo, hi));
    }
    cuts.removeWhere((cut) => cut.$2 - cut.$1 < 1e-9);
    if (cuts.isNotEmpty) touched = true;
    cuts.sort((x, y) => x.$1.compareTo(y.$1));
    final merged = <(double, double)>[];
    for (final cut in cuts) {
      if (merged.isEmpty || cut.$1 > merged.last.$2) {
        merged.add(cut);
      } else {
        final last = merged.removeLast();
        merged.add((last.$1, math.max(last.$2, cut.$2)));
      }
    }
    var cursor = 0.0;
    void keep(double lo, double hi) {
      if (hi - lo < 1e-9) return;
      final first = normal(a + d * lo), last = normal(a + d * hi);
      if (run == null ||
          (run!.last.x - first.x).abs() > 1e-9 ||
          (run!.last.y - first.y).abs() > 1e-9) {
        run = [first];
        result.add(run!);
      }
      if (run!.last != last) run!.add(last);
    }

    for (final cut in merged) {
      keep(cursor, cut.$1);
      run = null;
      cursor = math.max(cursor, cut.$2);
    }
    keep(cursor, 1);
    if (cursor >= 1) run = null;
  }
  return touched ? result : [points];
}

/// A composed view needs distinct temporary fragment IDs so the next queued
/// rebuild can address every fragment. Durable rebuilds still receive store IDs.
List<AnnotationStroke> _previewFragments(
  List<AnnotationStroke> strokes,
  Map<String, List<List<NormalizedPoint>>> replacements,
  String prefix,
) {
  final result = <AnnotationStroke>[];
  final used = {for (final stroke in strokes) stroke.id};
  var serial = 0;
  for (final stroke in strokes) {
    final paths = replacements[stroke.id];
    if (paths == null) {
      result.add(stroke);
      continue;
    }
    for (final points in paths.where((path) => path.isNotEmpty)) {
      var id = '$prefix-${serial++}';
      while (!used.add(id)) {
        id = '$prefix-${serial++}';
      }
      result.add(
        AnnotationStroke(
          id: id,
          style: stroke.style,
          points: points,
          createdUtc: stroke.createdUtc,
          updatedUtc: stroke.updatedUtc,
          version: stroke.version,
        ),
      );
    }
  }
  return result;
}

/// Listens to system stylus events only. Desktop mouse writing is explicitly a
/// Windows development aid; touch always belongs to reading/transform gestures.
class AnnotationCanvas extends StatefulWidget {
  const AnnotationCanvas({
    super.key,
    required this.workspace,
    required this.page,
    required this.enabled,
    required this.style,
    this.eraser = false,
    this.eraserRadiusFraction = .018,
    this.onWritingChanged,
    this.suspended = false,
  });
  final ReaderWorkspace workspace;
  final PageKey page;
  final bool enabled;
  final StrokeStyle style;
  final bool eraser;
  final bool suspended;
  final double eraserRadiusFraction;
  final ValueChanged<bool>? onWritingChanged;
  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  final Set<int> _touches = {};
  IncrementalStrokePath? _path;
  List<NormalizedPoint> get _draft => _path?.points ?? const [];
  final List<List<NormalizedPoint>> _segments = [];
  final Map<String, List<List<NormalizedPoint>>> _replacements = {};
  final _sweeps = <(Offset, Offset)>[];
  ReaderSnapshot? _previewSnapshot;
  PageKey? _previewPage;
  Size? _previewSize;
  List<PendingPathEdit> _previewEdits = const [];
  List<AnnotationStroke> _previewBase = const [];
  int? _pointer;
  StrokeStyle? _style;
  bool _erasing = false;
  double _radius = .018;
  Offset? _cursor, _previousErase;
  bool get _paused => widget.suspended || _touches.length > 1;

  @override
  void didUpdateWidget(AnnotationCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || !widget.enabled) _clear();
    if (!oldWidget.suspended && widget.suspended) {
      _finishSegment();
      _previousErase = null;
      _cursor = null;
    }
  }

  void _clear() {
    final writing = _pointer != null;
    _path = null;
    _segments.clear();
    _replacements.clear();
    _sweeps.clear();
    _pointer = null;
    _cursor = null;
    _previousErase = null;
    if (writing) widget.onWritingChanged?.call(false);
  }

  void _finishSegment() {
    if (_draft.isNotEmpty) _segments.add(List.of(_draft));
    _path = null;
  }

  void _ensurePreviewBase(Size size) {
    final snapshot = widget.workspace.store.snapshot;
    final edits = widget.workspace.pendingPaths
        .where((edit) => edit.page == widget.page)
        .toList(growable: false);
    if (identical(snapshot, _previewSnapshot) &&
        _previewPage == widget.page &&
        _previewSize == size &&
        listEquals(edits, _previewEdits)) {
      return;
    }
    _previewSnapshot = snapshot;
    _previewPage = widget.page;
    _previewSize = size;
    _previewEdits = edits;
    var strokes = snapshot.strokesFor(widget.page);
    for (var index = 0; index < edits.length; index++) {
      final edit = edits[index];
      final paths = edit.rebuild?.call(strokes) ?? edit.paths;
      strokes = _previewFragments(strokes, paths, '@preview-pending-$index');
    }
    _previewBase = List.unmodifiable(strokes);
    // A commit can replace IDs underneath a live draft. Replay that draft once
    // against the new base, then resume incremental clipping on normal moves.
    _replacements.clear();
    if (_erasing) {
      for (final sweep in _sweeps) {
        _erasePreviewSweep(sweep.$1, sweep.$2, size);
      }
    }
  }

  void _erasePreviewSweep(Offset from, Offset to, Size size) {
    final radius = size.shortestSide * _radius;
    for (final stroke in _previewBase) {
      final paths = _replacements[stroke.id] ?? [stroke.points];
      final next = <List<NormalizedPoint>>[];
      for (final path in paths) {
        next.addAll(
          eraseStrokePath(
            path,
            size,
            from,
            to,
            radius + stroke.style.widthFraction * size.shortestSide / 2,
          ),
        );
      }
      final unchanged =
          next.length == 1 &&
          paths.length == 1 &&
          listEquals(next.single, paths.single);
      if (!unchanged) _replacements[stroke.id] = next;
    }
  }

  void _sample(Offset position, Size size, {bool exact = false}) {
    if (_paused || size.isEmpty) return;
    final clamped = Offset(
      position.dx.clamp(0.0, size.width),
      position.dy.clamp(0.0, size.height),
    );
    _cursor = clamped;
    if (_erasing) {
      final from = _previousErase ?? clamped;
      _ensurePreviewBase(size);
      _sweeps.add((from, clamped));
      _erasePreviewSweep(from, clamped, size);
      _previousErase = clamped;
    } else {
      final point = NormalizedPoint(
        clamped.dx / size.width,
        clamped.dy / size.height,
      );
      (_path ??= IncrementalStrokePath(
        paperAspect: size.aspectRatio,
      )).add(point, exact: exact);
    }
  }

  void _down(PointerDownEvent event, Size size) {
    if (event.kind == PointerDeviceKind.touch) {
      _touches.add(event.pointer);
      if (_paused) {
        _finishSegment();
        _previousErase = null;
        _cursor = null;
        setState(() {});
      }
      return;
    }
    final pen =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    final desktopMouse =
        defaultTargetPlatform == TargetPlatform.windows &&
        event.kind == PointerDeviceKind.mouse &&
        event.buttons == kPrimaryButton;
    if (!widget.enabled || _pointer != null || (!pen && !desktopMouse)) return;
    _pointer = event.pointer;
    _style = widget.style;
    _erasing = widget.eraser || event.kind == PointerDeviceKind.invertedStylus;
    _radius = widget.eraserRadiusFraction;
    widget.onWritingChanged?.call(true);
    setState(() => _sample(event.localPosition, size));
  }

  void _up(PointerUpEvent event, Size size) {
    if (_touches.remove(event.pointer)) return;
    if (_pointer != event.pointer) return;
    _sample(event.localPosition, size, exact: true);
    final page = widget.page;
    if (_erasing && _sweeps.isNotEmpty) {
      final replacements = Map<String, List<List<NormalizedPoint>>>.from(
        _replacements,
      );
      final sweeps = List<(Offset, Offset)>.of(_sweeps);
      final radius = size.shortestSide * _radius;
      unawaited(
        widget.workspace.replacePaths(
          page,
          replacements,
          rebuild: (strokes) {
            final result = <String, List<List<NormalizedPoint>>>{};
            for (final stroke in strokes) {
              var paths = <List<NormalizedPoint>>[stroke.points];
              for (final sweep in sweeps) {
                paths = [
                  for (final path in paths)
                    ...eraseStrokePath(
                      path,
                      size,
                      sweep.$1,
                      sweep.$2,
                      radius +
                          stroke.style.widthFraction * size.shortestSide / 2,
                    ),
                ];
              }
              if (paths.length != 1 ||
                  !listEquals(paths.single, stroke.points)) {
                result[stroke.id] = paths;
              }
            }
            return result;
          },
        ),
      );
    } else if (!_erasing) {
      _finishSegment();
      for (final points in _segments) {
        unawaited(widget.workspace.addStroke(page, _style!, points));
      }
    }
    setState(_clear);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.workspace,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _ensurePreviewBase(size);
        final strokes = _previewFragments(
          _previewBase,
          _replacements,
          '@preview-draft',
        );
        final painter = CustomPaint(
          painter: AnnotationPainter(
            strokes: strokes,
            pending: widget.workspace.pendingFor(widget.page),
            draft: _draft,
            draftSegments: List.of(_segments),
            draftStyle: _style ?? widget.style,
            eraserPosition: _erasing ? _cursor : null,
            eraserRadius: size.shortestSide * _radius,
          ),
          child: const SizedBox.expand(),
        );
        if (!widget.enabled) return IgnorePointer(child: painter);
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _down(e, size),
            onPointerMove: (e) {
              if (_pointer == e.pointer) {
                setState(() => _sample(e.localPosition, size));
              }
            },
            onPointerUp: (e) => _up(e, size),
            onPointerCancel: (e) {
              _touches.remove(e.pointer);
              if (_pointer == e.pointer) setState(_clear);
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
    this.draftSegments = const [],
    this.eraserPosition,
    this.eraserRadius = 0,
  });
  final List<AnnotationStroke> strokes;
  final List<PendingStroke> pending;
  final List<NormalizedPoint> draft;
  final StrokeStyle draftStyle;
  final List<List<NormalizedPoint>> draftSegments;
  final Offset? eraserPosition;
  final double eraserRadius;

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
    for (final segment in draftSegments) {
      _stroke(canvas, size, draftStyle, segment);
    }
    _stroke(canvas, size, draftStyle, draft);
    if (eraserPosition != null) {
      canvas.drawCircle(
        eraserPosition!,
        eraserRadius,
        Paint()..color = const Color(0x22334f66),
      );
      canvas.drawCircle(
        eraserPosition!,
        eraserRadius,
        Paint()
          ..color = const Color(0xff334f66)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
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
