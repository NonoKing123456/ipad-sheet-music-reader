import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// UI positions only. All rectangles remain in the text's unrotated paper
/// coordinates; the view rotates the complete target and its visual together.
enum TextHandleKind { move, transform, width }

class TextHandlePlacement {
  const TextHandlePlacement(this.hitRect, this.visualRect);
  final Rect hitRect, visualRect;
}

Map<TextHandleKind, TextHandlePlacement> layoutTextHandles({
  required Rect frame,
  required Rect viewport,
  required double rotation,
  required double scale,
  Offset? rotationCentre,
}) {
  final unit = 1 / scale, side = 44 * unit, visual = 24 * unit;
  TextHandlePlacement at(Offset hitTopLeft, Offset visualTopLeft) =>
      TextHandlePlacement(
        hitTopLeft & Size.square(side),
        visualTopLeft & Size.square(visual),
      );
  final left = frame.left,
      top = frame.top,
      right = frame.right,
      bottom = frame.bottom;
  // Frame includes the editor's outer padding. Anchor the visible controls
  // on its border while pushing most of each touch target outside the input.
  final cornerMove = at(
    Offset(left - 32 * unit, top - 32 * unit),
    Offset(left - 12 * unit, top - 12 * unit),
  );
  final edgeWidth = at(
    Offset(right - 12 * unit, frame.center.dy - 32 * unit),
    Offset(right - 12 * unit, frame.center.dy - 12 * unit),
  );
  final cornerTransform = at(
    Offset(right - 12 * unit, bottom - 12 * unit),
    Offset(right - 12 * unit, bottom - 12 * unit),
  );
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
      cornerMove,
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
      cornerTransform,
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
      edgeWidth,
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

  // A 48px control frame makes width and transform targets meet exactly.
  // Ignore only arithmetic noise at that shared edge, in screen-sized units.
  bool overlaps(Rect a, Rect b) {
    final intersection = a.intersect(b);
    final epsilon = 1e-7 * unit;
    return intersection.width > epsilon && intersection.height > epsilon;
  }

  Map<TextHandleKind, TextHandlePlacement>? best;
  var bestOverflow = double.infinity;
  for (final move in candidates[TextHandleKind.move]!) {
    for (final transform in candidates[TextHandleKind.transform]!) {
      if (overlaps(move.hitRect, transform.hitRect)) continue;
      for (final width in candidates[TextHandleKind.width]!) {
        if (overlaps(width.hitRect, move.hitRect) ||
            overlaps(width.hitRect, transform.hitRect)) {
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
  // When no candidate fully fits, retain the least overflowing separate targets.
  // The portal clips overflow to the actual reader viewport.
  return best!;
}
