import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

int readerSeekDotCount(int pages, double width) =>
    math.min(pages, (width / ScoreLayout.dotsPitch).ceil());

/// Every actual page owns one 24dp cell. Presentation changes never recenter
/// the virtual strip during a gesture.
class ReaderPageSeekBar extends StatefulWidget {
  const ReaderPageSeekBar({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onSeek,
    this.onCancel,
    this.enabled = true,
    this.hitRegionKey,
  });
  final int currentPage, pageCount;
  final bool enabled;
  final GlobalKey? hitRegionKey;
  final void Function(int page, Object gesture) onSeek;
  final ValueChanged<Object>? onCancel;
  @override
  State<ReaderPageSeekBar> createState() => _ReaderPageSeekBarState();
}

class _ReaderPageSeekBarState extends State<ReaderPageSeekBar>
    with SingleTickerProviderStateMixin {
  int? _pointer, _preview, _lastSent;
  Object? _gesture;
  double _offset = 0, _width = 0, _pointerX = 0;
  double _from = 0, _to = 0;
  Timer? _edgeTimer;
  late final AnimationController _centering =
      AnimationController(vsync: this, duration: ScoreMotion.panel)
        ..addListener(() {
          setState(
            () => _offset =
                _from +
                (_to - _from) * Curves.easeOutCubic.transform(_centering.value),
          );
        });
  bool get _enabled => widget.enabled && widget.pageCount > 1;
  double get _maxOffset =>
      math.max(0, widget.pageCount * ScoreLayout.dotsPitch - _width);
  double get _centered =>
      ((widget.currentPage - .5) * ScoreLayout.dotsPitch - _width / 2).clamp(
        0.0,
        _maxOffset,
      );

  void _cancel() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    final gesture = _gesture;
    _pointer = _preview = _lastSent = null;
    _gesture = null;
    if (gesture != null) widget.onCancel?.call(gesture);
  }

  void _center() {
    if (_pointer != null || _width == 0) return;
    _from = _offset;
    _to = _centered;
    if (MediaQuery.disableAnimationsOf(context)) {
      _centering.stop();
      _offset = _to;
    } else {
      _centering.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant ReaderPageSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled || oldWidget.pageCount != widget.pageCount) _cancel();
    if (oldWidget.currentPage != widget.currentPage ||
        oldWidget.pageCount != widget.pageCount) {
      _center();
    }
  }

  @override
  void dispose() {
    _cancel();
    _centering.dispose();
    super.dispose();
  }

  void _move(double x) {
    _pointerX = x;
    final page =
        ((_offset + x.clamp(0.0, math.max(0, _width - .001))) /
                ScoreLayout.dotsPitch)
            .floor()
            .clamp(0, widget.pageCount - 1) +
        1;
    if (_preview != page) setState(() => _preview = page);
    final gesture = _gesture;
    if (page != _lastSent && gesture != null && _enabled) {
      _lastSent = page;
      widget.onSeek(page, gesture);
    }
    final edge = x < 0 || x > _width
        ? 0
        : x < ScoreLayout.dotsFadeEdge
        ? -1
        : x > _width - ScoreLayout.dotsFadeEdge
        ? 1
        : 0;
    if (edge == 0 || _maxOffset == 0) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
    } else {
      _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (_pointer == null) return;
        final direction = _pointerX < ScoreLayout.dotsFadeEdge ? -1 : 1;
        final next = (_offset + direction * 6 * ScoreLayout.dotsPitch * .016)
            .clamp(0.0, _maxOffset);
        if (next != _offset) {
          setState(() => _offset = next);
          _move(_pointerX);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(
        widget.pageCount * ScoreLayout.dotsPitch,
        math.min(
          ScoreLayout.dotsMaxWidth,
          math.max(0.0, constraints.maxWidth - 2 * ScoreSpace.xl),
        ),
      );
      if (_width != width) {
        _width = width;
        _offset = _centered;
      }
      final tokens = ScoreTokens.of(context);
      return Center(
        heightFactor: 1,
        child: SizedBox(
          key: widget.hitRegionKey,
          width: width,
          height: ScoreLayout.dotsHeight,
          child: Semantics(
            key: const ValueKey('page-indicator'),
            label: '页码',
            value: '${widget.currentPage} / ${widget.pageCount}',
            increasedValue:
                '${(widget.currentPage + 1).clamp(1, widget.pageCount)} / ${widget.pageCount}',
            decreasedValue:
                '${(widget.currentPage - 1).clamp(1, widget.pageCount)} / ${widget.pageCount}',
            onIncrease: !_enabled || widget.currentPage == widget.pageCount
                ? null
                : () => widget.onSeek(widget.currentPage + 1, Object()),
            onDecrease: !_enabled || widget.currentPage == 1
                ? null
                : () => widget.onSeek(widget.currentPage - 1, Object()),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                if (!_enabled ||
                    (event.kind != PointerDeviceKind.touch &&
                        event.kind != PointerDeviceKind.mouse)) {
                  return;
                }
                if (_pointer != null) {
                  setState(_cancel);
                  return;
                }
                _centering.stop();
                _pointer = event.pointer;
                _gesture = Object();
                _lastSent = widget.currentPage;
                _move(event.localPosition.dx);
              },
              onPointerMove: (event) {
                if (_pointer == event.pointer) _move(event.localPosition.dx);
              },
              onPointerUp: (event) {
                if (_pointer != event.pointer) return;
                _edgeTimer?.cancel();
                _edgeTimer = null;
                setState(() {
                  _pointer = _preview = _lastSent = null;
                  _gesture = null;
                });
                _center();
              },
              onPointerCancel: (event) {
                if (_pointer == event.pointer) {
                  setState(_cancel);
                  _center();
                }
              },
              child: IgnorePointer(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: ReaderPageDotsPainter(
                          page: _preview ?? widget.currentPage,
                          pages: widget.pageCount,
                          offset: _offset,
                          ink: tokens.ink300,
                          markerFill: tokens.pineBright,
                          markerOutline: tokens.pineBright,
                        ),
                      ),
                    ),
                    if (_preview != null)
                      Positioned(
                        top: -ScoreSpace.xl,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.paper0,
                              borderRadius: ScoreRadius.controlAll,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ScoreSpace.sm,
                                vertical: ScoreSpace.xs,
                              ),
                              child: Text(
                                '$_preview / ${widget.pageCount}',
                                style: ScoreText.caption.copyWith(
                                  color: tokens.ink900,
                                ),
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
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final first = (offset / ScoreLayout.dotsPitch).floor();
    final last = math.min(
      pages - 1,
      ((offset + size.width) / ScoreLayout.dotsPitch).ceil(),
    );
    for (var dot = first; dot <= last; dot++) {
      final x = (dot + .5) * ScoreLayout.dotsPitch - offset;
      final edgeAlpha = offset > 0 && x < ScoreLayout.dotsFadeEdge
          ? (x / ScoreLayout.dotsFadeEdge).clamp(0.0, 1.0)
          : offset + size.width < pages * ScoreLayout.dotsPitch &&
                x > size.width - ScoreLayout.dotsFadeEdge
          ? ((size.width - x) / ScoreLayout.dotsFadeEdge).clamp(0.0, 1.0)
          : 1.0;
      final active = dot + 1 == page;
      final center = Offset(x, size.height / 2);
      final paint = Paint()
        ..color = (active ? markerFill : ink).withValues(alpha: edgeAlpha);
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ReaderPageDotsPainter old) =>
      page != old.page ||
      pages != old.pages ||
      offset != old.offset ||
      ink != old.ink ||
      markerFill != old.markerFill;
}
