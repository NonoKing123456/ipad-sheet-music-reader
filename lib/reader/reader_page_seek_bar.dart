import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

int readerSeekDotCount(int pages, double width) =>
    math.min(pages, (width / ScoreLayout.dotsPitch).ceil());

/// The input range is the whole PDF, independent of the raster/page window.
/// Short scores retain their existing dots; longer scores use a thin track.
class ReaderPageSeekBar extends StatefulWidget {
  const ReaderPageSeekBar({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onSeek,
    this.lastVisiblePage,
    this.onCancel,
    this.enabled = true,
    this.hitRegionKey,
  });
  final int currentPage, pageCount;

  /// Inclusive physical page at the end of the visible spread, if any.
  final int? lastVisiblePage;
  final bool enabled;
  final GlobalKey? hitRegionKey;
  final void Function(int page, Object gesture) onSeek;
  final ValueChanged<Object>? onCancel;
  @override
  State<ReaderPageSeekBar> createState() => _ReaderPageSeekBarState();
}

class _ReaderPageSeekBarState extends State<ReaderPageSeekBar> {
  int? _pointer, _preview, _lastSent;
  Object? _gesture;
  final _contacts = <int>{};
  double _width = 0;
  bool _dots = true;
  bool get _enabled => widget.enabled && widget.pageCount > 1;
  int get _pageCount => math.max(1, widget.pageCount);
  int get _currentPage => widget.currentPage.clamp(1, _pageCount);

  String _label(int page) {
    final first = page.clamp(1, _pageCount);
    final visibleEnd = (widget.lastVisiblePage ?? _currentPage).clamp(
      _currentPage,
      _pageCount,
    );
    final last = (first + visibleEnd - _currentPage).clamp(first, _pageCount);
    return last > first ? '$first–$last / $_pageCount' : '$first / $_pageCount';
  }

  void _cancel() {
    final gesture = _gesture;
    _pointer = _preview = _lastSent = null;
    _gesture = null;
    if (gesture != null) widget.onCancel?.call(gesture);
  }

  @override
  void didUpdateWidget(covariant ReaderPageSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled || oldWidget.pageCount != widget.pageCount) _cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _move(double x) {
    // Dot centres retain one cell per page. Both modes reach every page with
    // one continuous drag, and clamping lets a captured drag reach either end.
    final inset = _dots ? ScoreLayout.dotsPitch / 2 : 0.0;
    final span = _width - 2 * inset;
    final fraction = span <= 0 ? 0.0 : ((x - inset) / span).clamp(0.0, 1.0);
    final page = 1 + (fraction * (widget.pageCount - 1)).round();
    if (_preview != page) setState(() => _preview = page);
    final gesture = _gesture;
    if (page != _lastSent && gesture != null && _enabled) {
      _lastSent = page;
      widget.onSeek(page, gesture);
    }
  }

  void _down(PointerDownEvent event) {
    _contacts.add(event.pointer);
    if (_contacts.length > 1) {
      setState(_cancel);
      return;
    }
    if (!_enabled ||
        (event.kind != PointerDeviceKind.touch &&
            event.kind != PointerDeviceKind.mouse) ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons != kPrimaryButton)) {
      return;
    }
    _pointer = event.pointer;
    _gesture = Object();
    _lastSent = _currentPage;
    _move(event.localPosition.dx);
  }

  void _up(PointerEvent event, {bool cancelled = false}) {
    _contacts.remove(event.pointer);
    if (_pointer != event.pointer) return;
    setState(() {
      if (cancelled) {
        _cancel();
      } else {
        // A completed gesture's accepted target must survive a later pedal.
        _pointer = _preview = _lastSent = null;
        _gesture = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final dotWidth = math.min(
        ScoreLayout.dotsMaxWidth,
        math.max(0.0, constraints.maxWidth - 2 * ScoreSpace.xl),
      );
      _dots = _pageCount * ScoreLayout.dotsPitch <= dotWidth;
      _width = _dots
          ? _pageCount * ScoreLayout.dotsPitch
          : math.min(
              ReaderNavigationTokens.seekTrackMaxWidth,
              math.max(
                0.0,
                constraints.maxWidth -
                    2 * ReaderNavigationTokens.seekTrackHorizontalInset,
              ),
            );
      final tokens = ScoreTokens.of(context);
      final page = (_preview ?? _currentPage).clamp(1, _pageCount);
      final fraction = _pageCount <= 1
          ? 0.0
          : ((page - 1) / (_pageCount - 1)).clamp(0.0, 1.0);
      final tooltipCenter =
          (_width - ReaderNavigationTokens.seekTooltipWidth) / 2;
      final tooltipLeft =
          (fraction * _width - ReaderNavigationTokens.seekTooltipWidth / 2)
              .clamp(
                math.min(-ScoreSpace.xl, tooltipCenter),
                math.max(
                  tooltipCenter,
                  _width -
                      ReaderNavigationTokens.seekTooltipWidth +
                      ScoreSpace.xl,
                ),
              )
              .toDouble();
      return Center(
        heightFactor: 1,
        child: SizedBox(
          key: widget.hitRegionKey,
          width: _width,
          height: ScoreLayout.touchTarget,
          child: Semantics(
            key: const ValueKey('page-indicator'),
            label: '页码',
            value: _label(page),
            increasedValue: _label(page + 1),
            decreasedValue: _label(page - 1),
            onIncrease: !_enabled || page == _pageCount
                ? null
                : () => widget.onSeek(page + 1, Object()),
            onDecrease: !_enabled || page == 1
                ? null
                : () => widget.onSeek(page - 1, Object()),
            child: Listener(
              // The paper must receive a Pencil's very first point before
              // the surrounding reader hides this overlay. ReaderInput's
              // control-region guard excludes touch/mouse from page gestures.
              behavior: HitTestBehavior.translucent,
              onPointerDown: _down,
              onPointerMove: (event) {
                if (_pointer == event.pointer) _move(event.localPosition.dx);
              },
              onPointerUp: _up,
              onPointerCancel: (event) => _up(event, cancelled: true),
              child: IgnorePointer(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _dots
                            ? ReaderPageDotsPainter(
                                page: page,
                                pages: _pageCount,
                                ink: tokens.ink300,
                                markerFill: tokens.pineBright,
                                markerOutline: tokens.pineBright,
                              )
                            : ReaderPageTrackPainter(
                                fraction: fraction,
                                dragging: _preview != null,
                                ink: tokens.ink300,
                                marker: tokens.pineBright,
                              ),
                      ),
                    ),
                    if (_preview != null)
                      Positioned(
                        top: -ReaderNavigationTokens.seekTooltipOffset,
                        left: tooltipLeft,
                        child: ExcludeSemantics(
                          child: Container(
                            key: const ValueKey('reader-bottom-page-label'),
                            width: ReaderNavigationTokens.seekTooltipWidth,
                            height: ReaderNavigationTokens.seekTooltipHeight,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: tokens.paper0,
                              borderRadius: BorderRadius.circular(
                                ReaderNavigationTokens.seekTooltipRadius,
                              ),
                            ),
                            child: Text(
                              _label(page),
                              maxLines: 1,
                              style: ScoreText.caption.copyWith(
                                color: tokens.ink900,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class ReaderPageTrackPainter extends CustomPainter {
  const ReaderPageTrackPainter({
    required this.fraction,
    required this.dragging,
    required this.ink,
    required this.marker,
  });
  final double fraction;
  final bool dragging;
  final Color ink, marker;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(fraction * size.width, size.height / 2);
    final paint = Paint()
      ..strokeWidth = ReaderNavigationTokens.seekTrackHeight
      ..strokeCap = StrokeCap.round
      ..color = ink.withValues(alpha: .62);
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
    paint.color = marker.withValues(alpha: .9);
    canvas.drawLine(Offset(0, center.dy), center, paint);
    if (dragging) {
      canvas.drawCircle(
        center,
        ReaderNavigationTokens.seekHaloSize / 2,
        Paint()..color = marker.withValues(alpha: .12),
      );
    }
    canvas.drawCircle(
      center,
      ReaderNavigationTokens.seekThumbSize / 2,
      Paint()..color = marker,
    );
  }

  @override
  bool shouldRepaint(covariant ReaderPageTrackPainter old) =>
      fraction != old.fraction ||
      dragging != old.dragging ||
      ink != old.ink ||
      marker != old.marker;
}

class ReaderPageDotsPainter extends CustomPainter {
  const ReaderPageDotsPainter({
    required this.page,
    required this.pages,
    required this.ink,
    required this.markerFill,
    required this.markerOutline,
    this.offset = 0,
  });
  final int page, pages;
  final double offset;
  final Color ink, markerFill, markerOutline;
  int get dotCount => pages;
  @override
  void paint(Canvas canvas, Size size) {
    for (var dot = 0; dot < pages; dot++) {
      final center = Offset(
        (dot + .5) * ScoreLayout.dotsPitch,
        size.height / 2,
      );
      final active = dot + 1 == page;
      final paint = Paint()..color = active ? markerFill : ink;
      if (active) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: center,
              width: ScoreLayout.activeDotWidth,
              height: ScoreLayout.dotSize,
            ),
            const Radius.circular(ScoreLayout.dotSize / 2),
          ),
          paint,
        );
      } else {
        canvas.drawCircle(center, ScoreLayout.dotSize / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ReaderPageDotsPainter old) =>
      page != old.page ||
      pages != old.pages ||
      ink != old.ink ||
      markerFill != old.markerFill;
}
