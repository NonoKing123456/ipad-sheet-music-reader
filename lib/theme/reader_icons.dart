import 'package:flutter/material.dart';

import 'tokens.dart';

/// Paths generated offline from the approved v2 icons.svg (24-unit viewBox).
/// Existing annotation glyph names are retained for call-site compatibility.
enum ReaderGlyph {
  search,
  chevronLeft,
  chevronRight,
  chevronDown,
  chevronUp,
  sun,
  moon,
  folder,
  file,
  plus,
  share,
  more,
  sync,
  check,
  cloud,
  pause,
  play,
  pen,
  highlighter,
  eraser,
  eyedropper,
  text,
  undo,
  redo,
  trash,
  list,
  grid,
  sort,
  close,
  back,
  ipad,
  downloadList,
  copy,
  wifi,
  signature,
  plusbox,
  image,
  move,
  transform,
  width,
  book,
  grip,
  playlistAdd,
}

class ReaderIcon extends StatelessWidget {
  const ReaderIcon(
    this.glyph, {
    super.key,
    this.size = ScoreLayout.iconVisual,
    this.color,
  });
  final ReaderGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ReaderIconPainter(
        glyph,
        color ?? IconTheme.of(context).color ?? ScoreTokens.of(context).ink700,
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
      ..strokeWidth = ScoreLayout.iconStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case ReaderGlyph.search:
        canvas.drawOval(
          Rect.fromCircle(center: Offset(11, 11), radius: 7),
          paint,
        );
        final path1 = Path()
          ..moveTo(16.5, 16.5)
          ..lineTo(21, 21);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.chevronLeft:
        final path0 = Path()
          ..moveTo(15, 5)
          ..lineTo(8, 12)
          ..lineTo(15, 19);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.chevronRight:
        final path0 = Path()
          ..moveTo(9, 5)
          ..lineTo(16, 12)
          ..lineTo(9, 19);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.chevronDown:
        final path0 = Path()
          ..moveTo(6, 9)
          ..lineTo(12, 15)
          ..lineTo(18, 9);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.chevronUp:
        final path0 = Path()
          ..moveTo(6, 15)
          ..lineTo(12, 9)
          ..lineTo(18, 15);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.sun:
        canvas.drawOval(
          Rect.fromCircle(center: Offset(12, 12), radius: 4.2),
          paint,
        );
        final path1 = Path()
          ..moveTo(12, 2.5)
          ..lineTo(12, 4.5)
          ..moveTo(12, 19.5)
          ..lineTo(12, 21.5)
          ..moveTo(2.5, 12)
          ..lineTo(4.5, 12)
          ..moveTo(19.5, 12)
          ..lineTo(21.5, 12)
          ..moveTo(5.2, 5.2)
          ..lineTo(6.6, 6.6)
          ..moveTo(17.4, 17.4)
          ..lineTo(18.8, 18.8)
          ..moveTo(18.8, 5.2)
          ..lineTo(17.4, 6.6)
          ..moveTo(6.6, 17.4)
          ..lineTo(5.2, 18.8);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.moon:
        final path0 = Path()
          ..moveTo(20, 14.5)
          ..cubicTo(
            18.9385263,
            18.5483035,
            15.1168733,
            21.2446936,
            10.947002,
            20.8873968,
          )
          ..cubicTo(
            6.77713071,
            20.5301001,
            3.46989991,
            17.2228693,
            3.11260315,
            13.052998,
          )
          ..cubicTo(2.75530639, 8.88312669, 5.4516965, 5.0614737, 9.5, 4)
          ..cubicTo(
            6.60050517,
            6.89949495,
            6.60050522,
            11.600505,
            9.50000011,
            14.4999999,
          )
          ..cubicTo(12.399495, 17.3994948, 17.100505, 17.3994948, 20, 14.5)
          ..close();
        canvas.drawPath(path0, paint);
      case ReaderGlyph.folder:
        final path0 = Path()
          ..moveTo(3, 7.2)
          ..cubicTo(3, 5.98497355, 3.98497355, 5, 5.2, 5)
          ..lineTo(9.1, 5)
          ..cubicTo(9.7, 5, 10.2, 5.2, 10.6, 5.7)
          ..lineTo(12, 7.4)
          ..lineTo(18.8, 7.4)
          ..cubicTo(20.0150264, 7.4, 21, 8.38497355, 21, 9.6)
          ..lineTo(21, 17.8)
          ..cubicTo(21, 19.0150264, 20.0150264, 20, 18.8, 20)
          ..lineTo(5.2, 20)
          ..cubicTo(3.98497355, 20, 3, 19.0150264, 3, 17.8)
          ..lineTo(3, 7.2)
          ..close();
        canvas.drawPath(
          path0,
          Paint()..color = color.withValues(alpha: color.a * .14),
        );
        canvas.drawPath(path0, paint..strokeWidth = 1.5);
        paint.strokeWidth = ScoreLayout.iconStroke;
      case ReaderGlyph.file:
        final path0 = Path()
          ..moveTo(6, 3.4)
          ..lineTo(13.2, 3.4)
          ..lineTo(19, 9.2)
          ..lineTo(19, 20.6)
          ..lineTo(6, 20.6)
          ..lineTo(6, 3.4)
          ..close();
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(13.2, 3.4)
          ..lineTo(13.2, 9.2)
          ..lineTo(19, 9.2);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.plus:
        final path0 = Path()
          ..moveTo(12, 5)
          ..lineTo(12, 19)
          ..moveTo(5, 12)
          ..lineTo(19, 12);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.share:
        final path0 = Path()
          ..moveTo(12, 3)
          ..lineTo(12, 14);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(8.2, 6.6)
          ..lineTo(12, 2.8)
          ..lineTo(15.8, 6.6);
        canvas.drawPath(path1, paint);
        final path2 = Path()
          ..moveTo(5.5, 12.5)
          ..lineTo(5.5, 19)
          ..cubicTo(5.5, 19.8836556, 6.2163444, 20.6, 7.1, 20.6)
          ..lineTo(16.9, 20.6)
          ..cubicTo(17.7836556, 20.6, 18.5, 19.8836556, 18.5, 19)
          ..lineTo(18.5, 12.5);
        canvas.drawPath(path2, paint);
      case ReaderGlyph.more:
        canvas.drawOval(
          Rect.fromCircle(center: Offset(6, 12), radius: 1.5),
          Paint()..color = color.withValues(alpha: color.a * 1),
        );
        canvas.drawOval(
          Rect.fromCircle(center: Offset(12, 12), radius: 1.5),
          Paint()..color = color.withValues(alpha: color.a * 1),
        );
        canvas.drawOval(
          Rect.fromCircle(center: Offset(18, 12), radius: 1.5),
          Paint()..color = color.withValues(alpha: color.a * 1),
        );
      case ReaderGlyph.sync:
        final path0 = Path()
          ..moveTo(20, 12)
          ..cubicTo(
            19.9989927,
            15.1706488,
            18.1255635,
            18.0415045,
            15.2237403,
            19.3191729,
          )
          ..cubicTo(12.3219171, 20.5968413, 8.93936086, 20.0401882, 6.6, 17.9);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(4, 12)
          ..cubicTo(
            4.00100726,
            8.82935121,
            5.87443646,
            5.95849555,
            8.7762597,
            4.6808271,
          )
          ..cubicTo(11.6780829, 3.40315866, 15.0606391, 3.9598118, 17.4, 6.1);
        canvas.drawPath(path1, paint);
        final path2 = Path()
          ..moveTo(17.6, 2.6)
          ..lineTo(17.6, 6.5)
          ..lineTo(13.7, 6.5)
          ..moveTo(6.4, 21.4)
          ..lineTo(6.4, 17.5)
          ..lineTo(10.3, 17.5);
        canvas.drawPath(path2, paint);
      case ReaderGlyph.check:
        final path0 = Path()
          ..moveTo(5, 12.8)
          ..lineTo(9.2, 17)
          ..lineTo(19, 6.8);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.cloud:
        final path0 = Path()
          ..moveTo(7.2, 18.5)
          ..lineTo(16.8, 18.5)
          ..cubicTo(19.009139, 18.5828427, 20.8671573, 16.859139, 20.95, 14.65)
          ..cubicTo(21.0328427, 12.440861, 19.309139, 10.5828427, 17.1, 10.5)
          ..cubicTo(
            16.117863,
            8.18423481,
            13.712143,
            6.8074845,
            11.217977,
            7.13382398,
          )
          ..cubicTo(8.72381097, 7.46016346, 6.75328083, 9.40950724, 6.4, 11.9)
          ..cubicTo(
            4.88507864,
            12.4226954,
            3.94082068,
            13.9322778,
            4.13365887,
            15.5231929,
          )
          ..cubicTo(4.32649705, 17.1141079, 5.60407039, 18.3543774, 7.2, 18.5)
          ..close();
        canvas.drawPath(path0, paint);
      case ReaderGlyph.pause:
        final path0 = Path()
          ..moveTo(9.5, 5.5)
          ..lineTo(9.5, 18.5)
          ..moveTo(14.5, 5.5)
          ..lineTo(14.5, 18.5);
        canvas.drawPath(path0, paint..strokeWidth = 2.2);
        paint.strokeWidth = ScoreLayout.iconStroke;
      case ReaderGlyph.play:
        final path0 = Path()
          ..moveTo(8, 4.8)
          ..lineTo(19, 12)
          ..lineTo(8, 19.2)
          ..lineTo(8, 4.8)
          ..close();
        canvas.drawPath(
          path0,
          Paint()..color = color.withValues(alpha: color.a * 1),
        );
        canvas.drawPath(path0, paint);
      case ReaderGlyph.pen:
        final path0 = Path()
          ..moveTo(4, 20.2)
          ..lineTo(8.4, 19.2)
          ..lineTo(18.3, 9.3)
          ..cubicTo(19.1284271, 8.47157288, 19.1284271, 7.12842712, 18.3, 6.3)
          ..cubicTo(17.4715729, 5.47157288, 16.1284271, 5.47157288, 15.3, 6.3)
          ..lineTo(5.4, 16.2)
          ..lineTo(4, 20.2)
          ..close();
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(15.4, 5.6)
          ..lineTo(18.4, 8.6);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.highlighter:
        final path0 = Path()
          ..moveTo(5, 20)
          ..lineTo(19, 20);
        canvas.drawPath(path0, paint..strokeWidth = 2.4);
        paint.strokeWidth = ScoreLayout.iconStroke;
        final path1 = Path()
          ..moveTo(8, 16.4)
          ..lineTo(15.6, 5.4)
          ..cubicTo(16.1887671, 4.55752212, 17.3407538, 4.33598622, 18.2, 4.9)
          ..lineTo(18.9, 5.4)
          ..cubicTo(19.7087353, 6.01932149, 19.8851827, 7.16622959, 19.3, 8)
          ..lineTo(11, 18.9)
          ..lineTo(8, 16.4)
          ..close();
        canvas.drawPath(
          path1,
          Paint()..color = color.withValues(alpha: color.a * .16),
        );
        canvas.drawPath(path1, paint);
      case ReaderGlyph.eraser:
        final path0 = Path()
          ..moveTo(8.8, 20.5)
          ..lineTo(20, 20.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(4.6, 15.6)
          ..lineTo(12.2, 7.7)
          ..cubicTo(12.8974188, 7.02691118, 14.0025812, 7.02691118, 14.7, 7.7)
          ..lineTo(18.4, 11.3)
          ..cubicTo(19.0730888, 11.9974188, 19.0730888, 13.1025812, 18.4, 13.8)
          ..lineTo(12.8, 19.6)
          ..lineTo(7.2, 19.6)
          ..lineTo(4.6, 15.6)
          ..close();
        canvas.drawPath(path1, paint);
      case ReaderGlyph.eyedropper:
        final path0 = Path()
          ..moveTo(14.2, 4.9)
          ..lineTo(19.1, 9.8);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(16.6, 2.7)
          ..cubicTo(
            17.0503245,
            2.24810916,
            17.6620365,
            1.99410743,
            18.3,
            1.99410743,
          )
          ..cubicTo(18.9379635, 1.99410743, 19.5496755, 2.24810916, 20, 2.7)
          ..lineTo(21.2, 3.9)
          ..cubicTo(
            21.6518908,
            4.35032449,
            21.9058926,
            4.96203645,
            21.9058926,
            5.6,
          )
          ..cubicTo(21.9058926, 6.23796355, 21.6518908, 6.84967551, 21.2, 7.3)
          ..lineTo(19.7, 8.8)
          ..lineTo(15, 4.1)
          ..lineTo(16.6, 2.7)
          ..close();
        canvas.drawPath(path1, paint);
        final path2 = Path()
          ..moveTo(14.9, 6.1)
          ..lineTo(5.4, 15.6)
          ..lineTo(4.3, 20)
          ..lineTo(8.7, 18.9)
          ..lineTo(18.2, 9.4);
        canvas.drawPath(path2, paint);
      case ReaderGlyph.text:
        final path0 = Path()
          ..moveTo(5, 6.6)
          ..lineTo(5, 5)
          ..lineTo(19, 5)
          ..lineTo(19, 6.6)
          ..moveTo(12, 5)
          ..lineTo(12, 19)
          ..moveTo(9, 19)
          ..lineTo(15, 19);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.undo:
        final path0 = Path()
          ..moveTo(4.5, 9.5)
          ..lineTo(14.3, 9.5)
          ..cubicTo(17.0614237, 9.5, 19.3, 11.7385763, 19.3, 14.5)
          ..cubicTo(19.3, 17.2614237, 17.0614237, 19.5, 14.3, 19.5)
          ..lineTo(10.3, 19.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(8.3, 5.6)
          ..lineTo(4.4, 9.5)
          ..lineTo(8.3, 13.4);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.redo:
        final path0 = Path()
          ..moveTo(19.5, 9.5)
          ..lineTo(9.7, 9.5)
          ..cubicTo(6.93857625, 9.5, 4.7, 11.7385763, 4.7, 14.5)
          ..cubicTo(4.7, 17.2614237, 6.93857625, 19.5, 9.7, 19.5)
          ..lineTo(13.7, 19.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(15.7, 5.6)
          ..lineTo(19.6, 9.5)
          ..lineTo(15.7, 13.4);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.trash:
        final path0 = Path()
          ..moveTo(4.5, 6.5)
          ..lineTo(19.5, 6.5)
          ..moveTo(9.5, 6.5)
          ..lineTo(9.5, 4.2)
          ..lineTo(14.5, 4.2)
          ..lineTo(14.5, 6.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(6.5, 6.5)
          ..lineTo(7.4, 19.5)
          ..lineTo(16.6, 19.5)
          ..lineTo(17.5, 6.5);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.list:
        final path0 = Path()
          ..moveTo(4, 7)
          ..lineTo(20, 7)
          ..moveTo(4, 12)
          ..lineTo(20, 12)
          ..moveTo(4, 17)
          ..lineTo(20, 17);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.grid:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(4, 4, 6.5, 6.5),
            Radius.circular(1.4),
          ),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(13.5, 4, 6.5, 6.5),
            Radius.circular(1.4),
          ),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(4, 13.5, 6.5, 6.5),
            Radius.circular(1.4),
          ),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(13.5, 13.5, 6.5, 6.5),
            Radius.circular(1.4),
          ),
          paint,
        );
      case ReaderGlyph.sort:
        final path0 = Path()
          ..moveTo(7, 4.5)
          ..lineTo(7, 19.5)
          ..moveTo(4, 16.5)
          ..lineTo(7, 19.5)
          ..lineTo(10, 16.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(14, 8)
          ..lineTo(20, 8)
          ..moveTo(14, 12.5)
          ..lineTo(18.5, 12.5)
          ..moveTo(14, 17)
          ..lineTo(17, 17);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.close:
        final path0 = Path()
          ..moveTo(6, 6)
          ..lineTo(18, 18)
          ..moveTo(18, 6)
          ..lineTo(6, 18);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.back:
        final path0 = Path()
          ..moveTo(20, 12)
          ..lineTo(4.5, 12);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(10, 5.5)
          ..lineTo(4, 12)
          ..lineTo(10, 18.5);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.ipad:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(5, 2.5, 14, 19),
            Radius.circular(2.2),
          ),
          paint,
        );
        final path1 = Path()
          ..moveTo(10.5, 19)
          ..lineTo(13.5, 19);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.downloadList:
        final path0 = Path()
          ..moveTo(4, 6.5)
          ..lineTo(15, 6.5)
          ..moveTo(4, 12)
          ..lineTo(15, 12)
          ..moveTo(4, 17.5)
          ..lineTo(11, 17.5);
        canvas.drawPath(path0, paint);
        final path1 = Path()
          ..moveTo(18.5, 10.5)
          ..lineTo(18.5, 19.5)
          ..moveTo(16, 17.5)
          ..lineTo(18.5, 20)
          ..lineTo(21, 17.5);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.copy:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(8.5, 8.5, 11, 11),
            Radius.circular(1.8),
          ),
          paint,
        );
        final path1 = Path()
          ..moveTo(15.5, 8.5)
          ..lineTo(15.5, 5.5)
          ..cubicTo(15.5, 4.50588745, 14.6941125, 3.7, 13.7, 3.7)
          ..lineTo(6.3, 3.7)
          ..cubicTo(5.30588745, 3.7, 4.5, 4.50588745, 4.5, 5.5)
          ..lineTo(4.5, 12.9)
          ..cubicTo(4.5, 13.8941125, 5.30588745, 14.7, 6.3, 14.7)
          ..lineTo(8.5, 14.7);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.wifi:
        final path0 = Path()
          ..moveTo(3, 9.2)
          ..cubicTo(8.2049295, 4.83174039, 15.7950705, 4.83174039, 21, 9.2)
          ..moveTo(6.4, 12.9)
          ..cubicTo(9.67859377, 10.294088, 14.3214062, 10.294088, 17.6, 12.9)
          ..moveTo(9.7, 16.4)
          ..cubicTo(11.0970308, 15.4856756, 12.9029692, 15.4856756, 14.3, 16.4);
        canvas.drawPath(path0, paint);
        canvas.drawOval(
          Rect.fromCircle(center: Offset(12, 19.6), radius: 1.2),
          Paint()..color = color.withValues(alpha: color.a * 1),
        );
      case ReaderGlyph.signature:
        final path0 = Path()
          ..moveTo(4, 18)
          ..lineTo(4, 15)
          ..moveTo(9, 18)
          ..lineTo(9, 12)
          ..moveTo(14, 18)
          ..lineTo(14, 9)
          ..moveTo(19, 18)
          ..lineTo(19, 6);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.plusbox:
      case ReaderGlyph.playlistAdd:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(4, 4, 16, 16),
            Radius.circular(3),
          ),
          paint,
        );
        final path1 = Path()
          ..moveTo(12, 8.5)
          ..lineTo(12, 15.5)
          ..moveTo(8.5, 12)
          ..lineTo(15.5, 12);
        canvas.drawPath(path1, paint);
      case ReaderGlyph.image:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(3, 4, 18, 16),
            Radius.circular(2),
          ),
          paint,
        );
        canvas.drawOval(
          Rect.fromCircle(center: Offset(8, 9), radius: 1.5),
          paint,
        );
        final path2 = Path()
          ..moveTo(4, 18)
          ..lineTo(9, 13)
          ..lineTo(13, 16)
          ..lineTo(16, 12)
          ..lineTo(21, 18);
        canvas.drawPath(path2, paint);
      case ReaderGlyph.move:
        final path0 = Path()
          ..moveTo(12, 2)
          ..lineTo(12, 22)
          ..moveTo(2, 12)
          ..lineTo(22, 12)
          ..moveTo(9, 5)
          ..lineTo(12, 2)
          ..lineTo(15, 5)
          ..moveTo(9, 19)
          ..lineTo(12, 22)
          ..lineTo(15, 19)
          ..moveTo(5, 9)
          ..lineTo(2, 12)
          ..lineTo(5, 15)
          ..moveTo(19, 9)
          ..lineTo(22, 12)
          ..lineTo(19, 15);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.transform:
        final path0 = Path()
          ..moveTo(5, 11)
          ..cubicTo(
            4.95837394,
            8.1373191,
            6.66419836,
            5.53783324,
            9.30695239,
            4.43668573,
          )
          ..cubicTo(11.9497064, 3.33553822, 14.9966378, 3.95470914, 17, 6)
          ..lineTo(20, 9)
          ..moveTo(20, 3)
          ..lineTo(20, 9)
          ..lineTo(14, 9)
          ..moveTo(4, 21)
          ..lineTo(11, 14)
          ..moveTo(4, 15)
          ..lineTo(4, 21)
          ..lineTo(10, 21);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.width:
        final path0 = Path()
          ..moveTo(3, 4)
          ..lineTo(3, 20)
          ..moveTo(21, 4)
          ..lineTo(21, 20)
          ..moveTo(5, 12)
          ..lineTo(19, 12)
          ..moveTo(8, 9)
          ..lineTo(5, 12)
          ..lineTo(8, 15)
          ..moveTo(16, 9)
          ..lineTo(19, 12)
          ..lineTo(16, 15);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.book:
        final path0 = Path()
          ..moveTo(3, 5)
          ..lineTo(10, 5)
          ..cubicTo(10.7706241, 5.06314262, 11.4871115, 5.42138631, 12, 6)
          ..cubicTo(12.5128885, 5.42138631, 13.2293759, 5.06314262, 14, 5)
          ..lineTo(21, 5)
          ..lineTo(21, 20)
          ..lineTo(14, 20)
          ..cubicTo(13.2293759, 20.0631426, 12.5128885, 20.4213863, 12, 21)
          ..cubicTo(11.4871115, 20.4213863, 10.7706241, 20.0631426, 10, 20)
          ..lineTo(3, 20)
          ..lineTo(3, 5)
          ..close()
          ..moveTo(12, 6)
          ..lineTo(12, 21);
        canvas.drawPath(path0, paint);
      case ReaderGlyph.grip:
        final path0 = Path()
          ..moveTo(9, 6)
          ..lineTo(9.01, 6)
          ..moveTo(15, 6)
          ..lineTo(15.01, 6)
          ..moveTo(9, 12)
          ..lineTo(9.01, 12)
          ..moveTo(15, 12)
          ..lineTo(15.01, 12)
          ..moveTo(9, 18)
          ..lineTo(9.01, 18)
          ..moveTo(15, 18)
          ..lineTo(15.01, 18);
        canvas.drawPath(path0, paint..strokeWidth = 3);
        paint.strokeWidth = ScoreLayout.iconStroke;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReaderIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
