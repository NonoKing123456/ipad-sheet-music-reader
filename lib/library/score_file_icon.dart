import 'dart:math' as math;

import 'package:flutter/material.dart';

enum ScoreFileIconState { ready, cloud, partial, update, unreadable, empty }

/// Shared library leading: solid local content, outlined remote content.
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
    final solid = isFolder
        ? Icons.folder
        : _image
        ? Icons.image
        : Icons.description;
    final half =
        state == ScoreFileIconState.partial ||
        state == ScoreFileIconState.update;
    final corner = switch (state) {
      ScoreFileIconState.cloud => _CornerMark.cloud,
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Icon(
                    state == ScoreFileIconState.ready ? solid : outline,
                    size: 32,
                    color: state == ScoreFileIconState.ready
                        ? localColor
                        : state == ScoreFileIconState.unreadable
                        ? unreadableColor
                        : remoteColor,
                  ),
                  if (half)
                    ClipRect(
                      clipper: const _LeftHalfClipper(),
                      child: Icon(solid, size: 32, color: localColor),
                    ),
                ],
              ),
            ),
            if (corner != null)
              Positioned(
                right: 1,
                bottom: 3,
                width: 16,
                height: 14,
                child: CustomPaint(
                  key: ValueKey('score-file-corner-${corner.name}'),
                  painter: _CornerPainter(
                    corner,
                    Theme.of(context).colorScheme.surface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LeftHalfClipper extends CustomClipper<Rect> {
  const _LeftHalfClipper();
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);
  @override
  bool shouldReclip(covariant _LeftHalfClipper oldClipper) => false;
}

enum _CornerMark { cloud, refresh, error }

class _CornerPainter extends CustomPainter {
  const _CornerPainter(this.mark, this.surface);
  final _CornerMark mark;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (mark == _CornerMark.cloud) {
      final cloud = Path()
        ..moveTo(4, 11)
        ..cubicTo(.3, 11, .3, 6.2, 3.8, 5.6)
        ..cubicTo(4.5, .8, 11, .6, 12.4, 5)
        ..cubicTo(16.7, 4.8, 17, 11, 12.5, 11)
        ..close();
      // Only the cloud silhouette clears the paper edge; there is no badge base.
      canvas.drawPath(cloud, p..color = surface);
      canvas.drawPath(
        cloud,
        p
          ..style = PaintingStyle.stroke
          ..color = ScoreFileIcon.remoteColor,
      );
      return;
    }
    final path = Path();
    if (mark == _CornerMark.refresh) {
      path
        ..addArc(
          const Rect.fromLTWH(2.5, 1.5, 11, 11),
          -.35 * math.pi,
          1.7 * math.pi,
        )
        ..moveTo(12.9, 1.2)
        ..lineTo(12.9, 4.5)
        ..lineTo(9.6, 4.5);
    } else {
      path
        ..moveTo(8, 2)
        ..lineTo(8, 8)
        ..moveTo(8, 11.6)
        ..lineTo(8, 11.7);
    }
    canvas.drawPath(
      path,
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = surface,
    );
    canvas.drawPath(
      path,
      p
        ..strokeWidth = mark == _CornerMark.error ? 2 : 1.5
        ..color = mark == _CornerMark.error
            ? ScoreFileIcon.unreadableColor
            : ScoreFileIcon.localColor,
    );
  }

  @override
  bool shouldRepaint(covariant _CornerPainter oldDelegate) =>
      oldDelegate.mark != mark || oldDelegate.surface != surface;
}
