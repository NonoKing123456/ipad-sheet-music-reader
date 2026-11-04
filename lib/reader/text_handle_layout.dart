import 'package:flutter/painting.dart';

import '../theme/tokens.dart';

/// UI positions only, in the text's unrotated paper coordinates.
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
  // Anchors stay attached to the frame, including on short one-line drafts.
  // Overlapping circular targets are resolved by distance, never paint order.
  final hit = ScoreLayout.textHandleHit / scale;
  final visual = ScoreLayout.textHandleVisual / scale;
  TextHandlePlacement at(Offset centre) => TextHandlePlacement(
    Rect.fromCenter(center: centre, width: hit, height: hit),
    Rect.fromCenter(center: centre, width: visual, height: visual),
  );
  return {
    TextHandleKind.move: at(frame.bottomLeft),
    TextHandleKind.width: at(frame.centerRight),
    TextHandleKind.transform: at(frame.bottomRight),
  };
}

/// [point], centres and radius must use the same coordinate space. A target
/// owns only its nearest circular region, even when several 44dp boxes overlap.
TextHandleKind? hitTestTextHandle({
  required Offset point,
  required Map<TextHandleKind, Offset> centres,
  required double radius,
}) {
  TextHandleKind? nearest;
  var distance = radius * radius;
  for (final handle in TextHandleKind.values) {
    final centre = centres[handle];
    if (centre == null) continue;
    final delta = (point - centre).distanceSquared;
    if (delta <= distance && (nearest == null || delta < distance)) {
      nearest = handle;
      distance = delta;
    }
  }
  return nearest;
}
