import 'dart:math' as math;
import 'dart:ui';

/// A bounded PDFium request. Coordinates are in pixels of the virtual page;
/// logicalRect is its exact placement in the unchanged paper coordinate space.
class PageRasterPlan {
  const PageRasterPlan({
    required this.logicalRect,
    required this.fullWidth,
    required this.fullHeight,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final Rect logicalRect;
  final double fullWidth, fullHeight;
  final int x, y, width, height;
  int get pixels => width * height;
  bool samePixels(PageRasterPlan other) =>
      fullWidth == other.fullWidth &&
      fullHeight == other.fullHeight &&
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height;
  Map<String, Object> toJson() => {
    'fullWidth': fullWidth,
    'fullHeight': fullHeight,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

const activeBasePixels = 6000000;
const detailPixels = 8000000;
const neighbourPixels = 1000000;

PageRasterPlan planPageRaster({
  required Size paper,
  required double devicePixelRatio,
  required double zoom,
  Rect? visible,
  bool neighbour = false,
}) {
  final whole = Offset.zero & paper;
  final region = visible == null ? whole : visible.intersect(whole);
  assert(paper.width > 0 && paper.height > 0 && !region.isEmpty);
  final limit = neighbour
      ? neighbourPixels
      : visible == null
      ? activeBasePixels
      : detailPixels;
  final maxEdge = neighbour ? 1600 : 4096;
  final requested = devicePixelRatio * (neighbour ? 1 : zoom * 1.2);
  final density = math.min(
    requested,
    math.min(
      math.sqrt(limit / (region.width * region.height)),
      maxEdge / math.max(region.width, region.height),
    ),
  );
  final fullWidth = math.max(1, (paper.width * density).floor()).toDouble();
  final fullHeight = math.max(1, (paper.height * density).floor()).toDouble();
  final densityX = fullWidth / paper.width;
  final densityY = fullHeight / paper.height;
  final x = (region.left * densityX).floor();
  final y = (region.top * densityY).floor();
  final width = math.max(
    1,
    math.min(maxEdge, (region.width * densityX).floor()),
  );
  final height = math.max(
    1,
    math.min(
      limit ~/ width,
      math.min(maxEdge, (region.height * densityY).floor()),
    ),
  );
  return PageRasterPlan(
    logicalRect: Rect.fromLTWH(
      x / densityX,
      y / densityY,
      width / densityX,
      height / densityY,
    ),
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    x: x,
    y: y,
    width: width,
    height: height,
  );
}

/// Decode only the pixels the display/zoom can use; never enlarge source bytes.
Size planImageDecode({
  required Size source,
  required Size paper,
  required double devicePixelRatio,
  required double zoom,
}) {
  final desired = math.min(
    source.width / paper.width,
    source.height / paper.height,
  );
  final density = math.min(
    desired,
    math.min(
      devicePixelRatio * zoom * 1.2,
      math.min(
        math.sqrt(12000000 / (paper.width * paper.height)),
        8192 / math.max(paper.width, paper.height),
      ),
    ),
  );
  // At the native ceiling, floating-point multiplication followed by floor
  // must not turn an original 870x760 image into an unnecessary 869x759 resample.
  if (density >= desired * (1 - 1e-10)) return source;
  return Size(
    math.max(1, (paper.width * density).floor()).toDouble(),
    math.max(1, (paper.height * density).floor()).toDouble(),
  );
}
