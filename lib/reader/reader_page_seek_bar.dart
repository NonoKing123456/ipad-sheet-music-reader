import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

int readerSeekDotCount(int pages, double width) =>
    math.min(pages.clamp(1, 60), math.max(1, ((width - 24) / 18).floor() + 1));

/// Floating dots; the transparent touch area never resizes paper.
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

class _ReaderPageSeekBarState extends State<ReaderPageSeekBar> {
  int? _pointer, _preview, _pending, _lastSent;
  Object? _gesture;
  int _epoch = 0;
  bool _scheduled = false;
  bool get _enabled => widget.enabled && widget.pageCount > 1;
  void _cancel() {
    _epoch++;
    _scheduled = false;
    _pointer = _preview = _pending = _lastSent = null;
    final gesture = _gesture;
    _gesture = null;
    if (gesture != null) widget.onCancel?.call(gesture);
  }

  void _emitPending() {
    final target = _pending, gesture = _gesture;
    _pending = null;
    if (target != null && target != _lastSent && gesture != null && _enabled) {
      _lastSent = target;
      widget.onSeek(target, gesture);
    }
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

  void _move(double x, double width) {
    final dots = readerSeekDotCount(widget.pageCount, width);
    final length = (dots - 1) * 18.0;
    final left = (width - length) / 2;
    final page =
        (1 +
                ((x - left) / math.max(1, length)).clamp(0.0, 1.0) *
                    (widget.pageCount - 1))
            .round();
    setState(() => _preview = page);
    _pending = page;
    if (_scheduled) return;
    _scheduled = true;
    final epoch = _epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _epoch) return;
      _scheduled = false;
      _emitPending();
    });
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: SizedBox(
        key: widget.hitRegionKey,
        height: 56,
        child: LayoutBuilder(
          builder: (_, constraints) {
            final width = constraints.maxWidth;
            return Semantics(
              key: const ValueKey('page-indicator'),
              label: '页码',
              value: '${widget.currentPage} / ${widget.pageCount}',
              child: Listener(
                behavior: HitTestBehavior.translucent,
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
                  _cancel();
                  _pointer = event.pointer;
                  _gesture = Object();
                  _lastSent = widget.currentPage;
                  _move(event.localPosition.dx, width);
                },
                onPointerMove: (event) {
                  if (_pointer == event.pointer) {
                    _move(event.localPosition.dx, width);
                  }
                },
                onPointerUp: (event) {
                  if (_pointer == event.pointer) {
                    _emitPending();
                    setState(() {
                      _epoch++;
                      _scheduled = false;
                      _pointer = null;
                      _preview = null;
                      _gesture = null;
                    });
                  }
                },
                onPointerCancel: (event) {
                  if (_pointer == event.pointer) setState(_cancel);
                },
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: ReaderPageDotsPainter(
                            page: widget.currentPage,
                            pages: widget.pageCount,
                          ),
                        ),
                      ),
                      if (_preview != null)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Text(
                            '$_preview / ${widget.pageCount}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xff52615c),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class ReaderPageDotsPainter extends CustomPainter {
  const ReaderPageDotsPainter({required this.page, required this.pages});
  final int page, pages;
  int get dotCount => pages.clamp(1, 60);
  @override
  void paint(Canvas canvas, Size size) {
    final dots = readerSeekDotCount(pages, size.width),
        length = (dots - 1) * 18.0;
    final left = (size.width - length) / 2;
    final ink = Paint()..color = const Color(0x9952615c);
    for (var dot = 0; dot < dots; dot++) {
      final x = dots == 1 ? size.width / 2 : left + length * dot / (dots - 1);
      canvas.drawCircle(Offset(x, 28), 3, ink);
    }
    final progress = pages <= 1 ? .5 : (page - 1) / (pages - 1);
    final centre = Offset(
      pages <= 1 ? size.width / 2 : left + length * progress,
      28,
    );
    canvas.drawCircle(centre, 5, Paint()..color = Colors.white);
    canvas.drawCircle(
      centre,
      5,
      Paint()
        ..color = const Color(0xff52615c)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant ReaderPageDotsPainter oldDelegate) =>
      page != oldDelegate.page || pages != oldDelegate.pages;
}
