import 'package:flutter/material.dart';

/// Reader controls share a quiet, round-ended, 24-unit line icon vocabulary.
enum ReaderGlyph {
  pen,
  highlighter,
  eraser,
  text,
  eyedropper,
  undo,
  redo,
  move,
  width,
  transform,
  playlistAdd,
}

class ReaderIcon extends StatelessWidget {
  const ReaderIcon(this.glyph, {super.key, this.size = 24, this.color});
  final ReaderGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ReaderIconPainter(
        glyph,
        color ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

class _ReaderIconPainter extends CustomPainter {
  const _ReaderIconPainter(this.glyph, this.color);
  final ReaderGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.55
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void line(double x, double y, double ex, double ey) =>
        canvas.drawLine(Offset(x, y), Offset(ex, ey), paint);
    void path(List<Offset> points, {bool close = false}) {
      final p = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        p.lineTo(point.dx, point.dy);
      }
      if (close) p.close();
      canvas.drawPath(p, paint);
    }

    switch (glyph) {
      case ReaderGlyph.pen:
        path(const [
          Offset(5, 15),
          Offset(15.5, 4.5),
          Offset(19.5, 8.5),
          Offset(9, 19),
          Offset(4, 20),
        ], close: true);
        line(13.5, 6.5, 17.5, 10.5);
        line(5, 15, 9, 19);
      case ReaderGlyph.highlighter:
        path(const [
          Offset(8, 14),
          Offset(15, 5),
          Offset(20, 9),
          Offset(13, 18),
        ], close: true);
        path(const [
          Offset(8, 14),
          Offset(6, 18),
          Offset(10, 20),
          Offset(13, 18),
        ]);
        line(4, 21, 17, 21);
      case ReaderGlyph.eraser:
        path(const [
          Offset(4, 14),
          Offset(12, 5),
          Offset(20, 12),
          Offset(13, 20),
          Offset(10, 20),
        ], close: true);
        line(8, 10, 16, 17);
        line(13, 20, 21, 20);
      case ReaderGlyph.text:
        line(5, 5, 19, 5);
        line(5, 5, 5, 8);
        line(19, 5, 19, 8);
        line(12, 5, 12, 20);
        line(8.5, 20, 15.5, 20);
      case ReaderGlyph.eyedropper:
        path(const [
          Offset(6, 15),
          Offset(14, 7),
          Offset(17, 10),
          Offset(9, 18),
          Offset(5, 19),
        ], close: true);
        line(12, 5, 19, 12);
        path(const [
          Offset(15, 7),
          Offset(18, 4),
          Offset(21, 7),
          Offset(18, 10),
        ]);
      case ReaderGlyph.undo:
      case ReaderGlyph.redo:
        if (glyph == ReaderGlyph.redo) {
          canvas.translate(24, 0);
          canvas.scale(-1, 1);
        }
        path(const [Offset(8, 5), Offset(4, 9), Offset(8, 13)]);
        canvas.drawPath(
          Path()
            ..moveTo(4, 9)
            ..lineTo(13, 9)
            ..cubicTo(21, 9, 21, 20, 13, 20)
            ..lineTo(10, 20),
          paint,
        );
      case ReaderGlyph.move:
        line(12, 3.5, 12, 20.5);
        line(3.5, 12, 20.5, 12);
        path(const [Offset(9, 6.5), Offset(12, 3.5), Offset(15, 6.5)]);
        path(const [Offset(9, 17.5), Offset(12, 20.5), Offset(15, 17.5)]);
        path(const [Offset(6.5, 9), Offset(3.5, 12), Offset(6.5, 15)]);
        path(const [Offset(17.5, 9), Offset(20.5, 12), Offset(17.5, 15)]);
      case ReaderGlyph.width:
        line(4, 12, 20, 12);
        path(const [Offset(7, 9), Offset(4, 12), Offset(7, 15)]);
        path(const [Offset(17, 9), Offset(20, 12), Offset(17, 15)]);
      case ReaderGlyph.transform:
        line(5, 19, 19, 5);
        path(const [Offset(13, 5), Offset(19, 5), Offset(19, 11)]);
        path(const [Offset(5, 13), Offset(5, 19), Offset(11, 19)]);
      case ReaderGlyph.playlistAdd:
        line(4, 6, 18, 6);
        line(4, 11, 14, 11);
        line(4, 16, 11, 16);
        line(18, 13, 18, 21);
        line(14, 17, 22, 17);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReaderIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
