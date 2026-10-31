import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:reader_state/reader_state.dart';

/// Smooths only newly captured ink. The polyline is the geometry shared by the
/// live painter, persistence and eraser; stored strokes never pass through here.
///
/// A midpoint quadratic becomes stable when the next input arrives. Only the
/// single, exact pen-tip tail is replaced, with at most 12 curve subdivisions.
/// Error and corner thresholds use a canonical 1024-pixel paper short edge, so
/// viewport size, orientation and zoom do not change the normalized trajectory.
class IncrementalStrokePath {
  IncrementalStrokePath({required double paperAspect})
    : _size = paperAspect >= 1
          ? Size(1024 * paperAspect, 1024)
          : Size(1024, 1024 / paperAspect);

  final Size _size;
  final List<NormalizedPoint> points = [];
  Offset? _before, _previous;
  Offset? _anchor;
  int _stableLength = 0;

  Offset _pixel(NormalizedPoint point) =>
      Offset(point.x * _size.width, point.y * _size.height);

  void _append(Offset point) {
    final normalized = NormalizedPoint(
      (point.dx / _size.width).clamp(0.0, 1.0),
      (point.dy / _size.height).clamp(0.0, 1.0),
    );
    if (points.isEmpty || points.last != normalized) points.add(normalized);
  }

  void add(NormalizedPoint point, {bool exact = false}) {
    final current = _pixel(point);
    final previous = _previous;
    if (previous == null) {
      _append(current);
      _previous = _anchor = current;
      _stableLength = points.length;
      return;
    }
    final outgoing = current - previous;
    if (outgoing.distance < (exact ? 1e-9 : .7)) return;

    // The latest point is the only provisional part of the path. Removing it
    // does not copy or revisit the stable prefix, even during a long stroke.
    points.length = _stableLength;
    final before = _before;
    if (before != null) {
      final incoming = previous - before;
      final sharpCorner =
          incoming.distance >= 4 &&
          outgoing.distance >= 4 &&
          incoming.dx * outgoing.dx + incoming.dy * outgoing.dy <=
              incoming.distance * outgoing.distance * .5;
      if (sharpCorner) {
        _append(previous);
        _anchor = previous;
      } else {
        final start = _anchor!;
        final end = (previous + current) / 2;
        // Distance of control from chord bounds the quadratic's flattening
        // error. Straight movement needs one segment; curvature adds samples.
        final chord = end - start;
        final flatness = chord.distance < 1e-9
            ? (previous - start).distance
            : ((previous.dx - start.dx) * chord.dy -
                          (previous.dy - start.dy) * chord.dx)
                      .abs() /
                  chord.distance;
        final steps = math.sqrt(flatness / .2).ceil().clamp(1, 12);
        for (var step = 1; step <= steps; step++) {
          final t = step / steps, u = 1 - t;
          _append(start * (u * u) + previous * (2 * u * t) + end * (t * t));
        }
        _anchor = end;
      }
      _stableLength = points.length;
    }
    _append(current);
    _before = previous;
    _previous = current;
  }
}
