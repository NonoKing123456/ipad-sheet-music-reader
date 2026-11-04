import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/reader_icons.dart';
import '../theme/tokens.dart';

enum ScoreFileIconState { ready, cloud, partial, update, unreadable, empty }

/// The same 36dp container is used for every type and every offline state.
class ScoreFileIcon extends StatelessWidget {
  const ScoreFileIcon({
    super.key,
    required this.path,
    this.state = ScoreFileIconState.ready,
    this.showBadge = true,
  }) : isFolder = false;
  const ScoreFileIcon.folder({
    super.key,
    this.state = ScoreFileIconState.ready,
    this.showBadge = true,
  }) : path = '',
       isFolder = true;
  final String path;
  final ScoreFileIconState state;
  final bool isFolder, showBadge;

  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    final image = const [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
    ].any(path.toLowerCase().endsWith);
    final badge = showBadge && state != ScoreFileIconState.empty;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: ScoreLayout.fileIconContainer,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: ReaderIcon(
                isFolder
                    ? ReaderGlyph.folder
                    : image
                    ? ReaderGlyph.image
                    : ReaderGlyph.file,
                size: ScoreLayout.fileIconVisual,
                color: isFolder || !image ? tokens.pine : tokens.ink500,
              ),
            ),
            if (badge)
              Positioned(
                right: -2,
                bottom: -2,
                width: ScoreLayout.badgeVisual + ScoreLayout.badgeHalo * 2,
                height: ScoreLayout.badgeVisual + ScoreLayout.badgeHalo * 2,
                child: Container(
                  key: ValueKey(
                    'score-file-corner-${state == ScoreFileIconState.update ? 'check' : state.name}',
                  ),
                  padding: const EdgeInsets.all(ScoreLayout.badgeHalo),
                  decoration: BoxDecoration(
                    color: tokens.paper1,
                    shape: BoxShape.circle,
                  ),
                  child:
                      state == ScoreFileIconState.cloud ||
                          state == ScoreFileIconState.unreadable
                      ? ReaderIcon(
                          ReaderGlyph.cloud,
                          size: ScoreLayout.badgeVisual,
                          color: state == ScoreFileIconState.unreadable
                              ? tokens.dangerInk
                              : tokens.ink500,
                        )
                      : state == ScoreFileIconState.partial
                      ? CustomPaint(painter: _PartialPainter(tokens.pine))
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.pine,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: ReaderIcon(
                              ReaderGlyph.check,
                              size: 11,
                              color: tokens.onBrand,
                            ),
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PartialPainter extends CustomPainter {
  const _PartialPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final circle = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: 6.2,
    );
    final p = Paint()..color = color;
    canvas.drawArc(circle, -math.pi / 2, math.pi, true, p);
    canvas.drawOval(
      circle,
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_PartialPainter oldDelegate) => oldDelegate.color != color;
}
