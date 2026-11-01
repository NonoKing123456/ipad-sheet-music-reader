import 'dart:math' as math;

import 'package:flutter/material.dart';

enum ScoreFileIconState { ready, cloud, partial, update, unreadable, empty }

/// Shared library leading: 32px outline type icons with 14px corner status marks.
/// Labels and tooltips remain with the row that knows the actual availability.
class ScoreFileIcon extends StatelessWidget {
  const ScoreFileIcon({
    super.key,
    required this.path,
    this.state = ScoreFileIconState.ready,
  }) : isFolder = false;

  const ScoreFileIcon.folder({super.key, this.state = ScoreFileIconState.ready})
    : path = '',
      isFolder = true;

  final String path;
  final ScoreFileIconState state;
  final bool isFolder;

  static const localColor = Color(0xff356451);
  static const outlineColor = Color(0xff53645c);
  static const remoteColor = Color(0xff87908c);
  static const unreadableColor = Color(0xff9b5c52);

  bool get _image {
    final lower = path.toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.webp'].any(lower.endsWith);
  }

  @override
  Widget build(BuildContext context) {
    final outline = isFolder
        ? Icons.folder_outlined
        : _image
        ? Icons.image_outlined
        : Icons.description_outlined;
    final corner = switch (state) {
      ScoreFileIconState.ready => _CornerMark.check,
      ScoreFileIconState.cloud => _CornerMark.cloud,
      ScoreFileIconState.partial => _CornerMark.partial,
      ScoreFileIconState.update => _CornerMark.refresh,
      ScoreFileIconState.unreadable => _CornerMark.error,
      _ => null,
    };
    return ExcludeSemantics(
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          children: [
            Positioned(
              left: 4,
              top: 5,
              width: 32,
              height: 32,
              child: Icon(outline, size: 32, color: outlineColor),
            ),
            if (corner != null)
              Positioned(
                right: 2,
                bottom: 2,
                width: 18,
                height: 18,
                child: _CornerBadge(
                  key: ValueKey('score-file-corner-${corner.name}'),
                  mark: corner,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _CornerMark { check, cloud, partial, refresh, error }

class _CornerBadge extends StatelessWidget {
  const _CornerBadge({super.key, required this.mark});
  final _CornerMark mark;

  @override
  Widget build(BuildContext context) {
    final symbol = SizedBox(
      key: ValueKey('score-file-symbol-${mark.name}'),
      width: 14,
      height: 14,
      child: mark == _CornerMark.cloud
          ? const CustomPaint(painter: _CloudOutlinePainter())
          : mark == _CornerMark.partial
          ? const CustomPaint(painter: _PartialPainter())
          : DecoratedBox(
              decoration: BoxDecoration(
                color: mark == _CornerMark.error
                    ? ScoreFileIcon.unreadableColor
                    : ScoreFileIcon.localColor,
                shape: BoxShape.circle,
              ),
              child: Icon(
                mark == _CornerMark.check
                    ? Icons.check_rounded
                    : mark == _CornerMark.refresh
                    ? Icons.refresh_rounded
                    : Icons.priority_high_rounded,
                size: mark == _CornerMark.check ? 11 : 10,
                color: Colors.white,
              ),
            ),
    );
    if (mark == _CornerMark.cloud) {
      return Center(child: symbol);
    }
    return Center(
      child: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Center(child: symbol),
      ),
    );
  }
}

class _PartialPainter extends CustomPainter {
  const _PartialPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final circle = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: 6.2,
    );
    final p = Paint()..color = ScoreFileIcon.localColor;
    canvas.drawArc(circle, math.pi / 2, math.pi, true, p);
    canvas.drawOval(
      circle,
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _PartialPainter oldDelegate) => false;
}

class _CloudOutlinePainter extends CustomPainter {
  const _CloudOutlinePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final cloud = Path()
      ..moveTo(3.5, 10.8)
      ..cubicTo(.7, 10.8, .3, 6.6, 3.1, 6)
      ..cubicTo(3.7, 2.3, 9, 1.9, 10.4, 5.3)
      ..cubicTo(13.2, 5.1, 13.5, 10.8, 10.7, 10.8)
      ..close();
    final p = Paint()
      ..color = Colors.white
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(cloud, p);
    canvas.drawPath(
      cloud,
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4,
    );
    canvas.drawPath(
      cloud,
      p
        ..color = const Color(0xff4f6059)
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _CloudOutlinePainter oldDelegate) => false;
}
