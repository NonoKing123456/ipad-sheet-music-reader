import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// UI positions only. All rectangles remain in the text's unrotated paper
/// coordinates; the view rotates the complete target and its visual together.
enum TextHandleKind { move, transform, width }

class TextHandlePlacement {
  const TextHandlePlacement(this.hitRect, this.visualRect);
  final Rect hitRect, visualRect;
}

/// A destructive action stays separate from both the input and the three
/// manipulation targets, with the same screen-sized hit area.
TextHandlePlacement layoutTextDelete({
  required Rect frame,
  required Rect viewport,
  required double rotation,
  required double scale,
  required Iterable<TextHandlePlacement> handles,
  Offset? rotationCentre,
}) {
  final u = 1 / scale, side = 44 * u;
  final candidates = [
    Offset(frame.left, frame.bottom + 2 * u),
    Offset(frame.left - 46 * u, frame.center.dy - 22 * u),
    Offset(frame.left, frame.top - 46 * u),
    Offset(frame.right - side, frame.top - 46 * u),
    Offset(frame.left - 46 * u, frame.bottom + 2 * u),
    Offset(frame.right + 2 * u, frame.top - 46 * u),
    Offset(frame.left - 46 * u, frame.top - 46 * u),
    Offset(frame.right + 2 * u, frame.bottom + 2 * u),
  ];
  final pivot = rotationCentre ?? frame.center;
  double overflow(Rect rect) {
    var result = 0.0;
    for (final point in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      final d = point - pivot;
      final p =
          pivot +
          Offset(
            d.dx * math.cos(rotation) - d.dy * math.sin(rotation),
            d.dx * math.sin(rotation) + d.dy * math.cos(rotation),
          );
      result +=
          math.max(0, viewport.left - p.dx) +
          math.max(0, p.dx - viewport.right) +
          math.max(0, viewport.top - p.dy) +
          math.max(0, p.dy - viewport.bottom);
    }
    return result;
  }

  Rect? best;
  var score = double.infinity;
  for (final point in candidates) {
    final rect = point & Size.square(side);
    if (rect.overlaps(frame) || handles.any((h) => h.hitRect.overlaps(rect))) {
      continue;
    }
    final value = overflow(rect);
    if (value < score) {
      best = rect;
      score = value;
    }
    if (value < .001) break;
  }
  final hit = best!;
  return TextHandlePlacement(hit, hit.deflate(8 * u));
}

Map<TextHandleKind, TextHandlePlacement> layoutTextHandles({
  required Rect frame,
  required Rect viewport,
  required double rotation,
  required double scale,
  Offset? rotationCentre,
}) {
  final unit = 1 / scale, side = 44 * unit, visual = 28 * unit;
  TextHandlePlacement at(Offset hitTopLeft, Offset visualTopLeft) =>
      TextHandlePlacement(
        hitTopLeft & Size.square(side),
        visualTopLeft & Size.square(visual),
      );
  final left = frame.left,
      top = frame.top,
      right = frame.right,
      bottom = frame.bottom;
  final aboveLeft = at(
    Offset(left, top - 46 * unit),
    Offset(left, top - 32 * unit),
  );
  final aboveRight = at(
    Offset(right - side, top - 46 * unit),
    Offset(right - visual, top - 32 * unit),
  );
  final belowLeft = at(
    Offset(left, bottom + 2 * unit),
    Offset(left, bottom + 4 * unit),
  );
  final belowRight = at(
    Offset(right - side, bottom + 2 * unit),
    Offset(right - visual, bottom + 4 * unit),
  );
  final leftTop = at(
    Offset(left - 46 * unit, top),
    Offset(left - 32 * unit, top),
  );
  final leftBottom = at(
    Offset(left - 46 * unit, bottom - side),
    Offset(left - 32 * unit, bottom - visual),
  );
  final rightTop = at(
    Offset(right + 2 * unit, top),
    Offset(right + 4 * unit, top),
  );
  final rightBottom = at(
    Offset(right + 2 * unit, bottom - side),
    Offset(right + 4 * unit, bottom - visual),
  );
  final diagonalMove = at(
    Offset(left - side, top - side),
    Offset(left - 32 * unit, top - 32 * unit),
  );
  final rightMiddle = at(
    Offset(right + 2 * unit, frame.center.dy - 22 * unit),
    Offset(right + 4 * unit, frame.center.dy - 14 * unit),
  );
  final leftMiddle = at(
    Offset(left - 46 * unit, frame.center.dy - 22 * unit),
    Offset(left - 32 * unit, frame.center.dy - 14 * unit),
  );
  final candidates = {
    TextHandleKind.move: [
      diagonalMove,
      aboveLeft,
      leftTop,
      aboveRight,
      belowLeft,
      rightTop,
      leftBottom,
      belowRight,
    ],
    TextHandleKind.transform: [
      belowRight,
      rightBottom,
      belowLeft,
      aboveRight,
      leftBottom,
      rightTop,
      aboveLeft,
      leftTop,
    ],
    TextHandleKind.width: [
      rightMiddle,
      rightTop,
      rightBottom,
      belowRight,
      aboveRight,
      leftMiddle,
      belowLeft,
      aboveLeft,
    ],
  };
  final cosine = math.cos(rotation), sine = math.sin(rotation);
  final pivot = rotationCentre ?? frame.center;
  Offset rotate(Offset p) {
    final d = p - pivot;
    return pivot +
        Offset(d.dx * cosine - d.dy * sine, d.dx * sine + d.dy * cosine);
  }

  final overflowCache = <TextHandlePlacement, double>{};
  double overflow(TextHandlePlacement placement) =>
      overflowCache.putIfAbsent(placement, () {
        var result = 0.0;
        for (final point in [
          placement.hitRect.topLeft,
          placement.hitRect.topRight,
          placement.hitRect.bottomLeft,
          placement.hitRect.bottomRight,
        ]) {
          final p = rotate(point);
          result +=
              math.max(0, viewport.left - p.dx) +
              math.max(0, p.dx - viewport.right) +
              math.max(0, viewport.top - p.dy) +
              math.max(0, p.dy - viewport.bottom);
        }
        return result;
      });

  Map<TextHandleKind, TextHandlePlacement>? best;
  var bestOverflow = double.infinity;
  for (final move in candidates[TextHandleKind.move]!) {
    for (final transform in candidates[TextHandleKind.transform]!) {
      if (move.hitRect.overlaps(transform.hitRect)) continue;
      for (final width in candidates[TextHandleKind.width]!) {
        if (width.hitRect.overlaps(move.hitRect) ||
            width.hitRect.overlaps(transform.hitRect)) {
          continue;
        }
        final total = overflow(move) + overflow(transform) + overflow(width);
        if (total < bestOverflow) {
          bestOverflow = total;
          best = {
            TextHandleKind.move: move,
            TextHandleKind.transform: transform,
            TextHandleKind.width: width,
          };
          if (total < .001) return best;
        }
      }
    }
  }
  // An offscreen text edge stays offscreen rather than pushing its target onto
  // the input. The portal clips overflow to the actual reader viewport.
  return best!;
}
