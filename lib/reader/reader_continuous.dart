import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'reader_page_window.dart';

class ReaderScrollAnchor {
  const ReaderScrollAnchor(this.page, this.fraction, this.horizontalFraction);
  final int page;
  final double fraction, horizontalFraction;
}

class ReaderContinuousController {
  double scale = 1;
  ReaderScrollAnchor? anchor;
  ValueChanged<double>? _zoom;
  void zoom(double factor) {
    final next = (scale * factor).clamp(1.0, 4.0);
    if (_zoom != null) {
      _zoom!(next);
    } else {
      scale = next;
    }
  }

  void fit() {
    if (_zoom != null) {
      _zoom!(1);
    } else {
      scale = 1;
    }
  }
}

/// Continuous PDF reading uses geometry for all pages, raster surfaces only for
/// the four pages nearest the viewport. Wheel input stops quietly at each end.
class ReaderContinuousView extends StatefulWidget {
  const ReaderContinuousView({
    super.key,
    required this.documentKey,
    required this.pageCount,
    required this.aspectFor,
    required this.pageBuilder,
    required this.controller,
    required this.requestedPage,
    required this.navigationToken,
    required this.onPresented,
    this.initialAnchor,
    this.onCenterTap,
    this.onPrevious,
    this.onNext,
    this.controlKey,
    this.viewportKey,
    this.retainDocument,
    this.releaseDocument,
  });
  final Object documentKey;
  final int pageCount, requestedPage, navigationToken;
  final double Function(int) aspectFor;
  final ReadyPageBuilder pageBuilder;
  final ReaderContinuousController controller;
  final ReaderScrollAnchor? initialAnchor;
  final ValueChanged<int> onPresented;
  final VoidCallback? onCenterTap, onPrevious, onNext;
  final GlobalKey? controlKey, viewportKey;
  final VoidCallback? retainDocument, releaseDocument;
  @override
  State<ReaderContinuousView> createState() => _ReaderContinuousViewState();
}

class _ReaderContinuousViewState extends State<ReaderContinuousView> {
  final _vertical = ScrollController(), _horizontal = ScrollController();
  final _mounted = <int, Object>{};
  final _ready = <int>{};
  Set<int> _window = {};
  Set<int> _visible = {};
  Size _viewport = Size.zero;
  double _paperWidth = 0;
  List<double> _prefix = [0], _heights = [];
  bool _scheduled = false, _layoutPending = true, _ignoredGesture = false;
  ReaderScrollAnchor? _pendingAnchor;
  (int, double, Offset, double)? _pendingZoom;
  int? _reported;
  double _gestureScale = 1;
  late final ValueChanged<double> _zoomCallback = _zoomFromController;
  void _zoomFromController(double value) => _zoom(value, null);
  @override
  void initState() {
    super.initState();
    widget.retainDocument?.call();
    _pendingAnchor =
        widget.initialAnchor ?? ReaderScrollAnchor(widget.requestedPage, 0, 0);
    widget.controller._zoom = _zoomCallback;
    _vertical.addListener(_schedule);
  }

  @override
  void didUpdateWidget(covariant ReaderContinuousView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationToken != widget.navigationToken) {
      _pendingAnchor = ReaderScrollAnchor(widget.requestedPage, 0, 0);
      _pendingZoom = null;
      _layoutPending = true;
      _schedule();
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller._zoom, _zoomCallback)) {
      widget.controller._zoom = null;
    }
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
    widget.releaseDocument?.call();
  }

  double get _offset => _vertical.hasClients ? _vertical.offset : 0;
  int _indexAt(double position) {
    var low = 0, high = widget.pageCount;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (_prefix[mid] <= position) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return low.clamp(0, widget.pageCount - 1);
  }

  bool _insideControl(Offset global) {
    final box = widget.controlKey?.currentContext?.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  ReaderScrollAnchor _anchor() {
    final index = _indexAt(_offset);
    final horizontal =
        _horizontal.hasClients && _horizontal.position.maxScrollExtent > 0
        ? _horizontal.offset / _horizontal.position.maxScrollExtent
        : 0.0;
    return ReaderScrollAnchor(
      index + 1,
      ((_offset - _prefix[index]) / (_heights[index] + 16)).clamp(0.0, 1.0),
      horizontal,
    );
  }

  void _jump(double offset) {
    if (!_vertical.hasClients) return;
    _vertical.jumpTo(offset.clamp(0.0, _vertical.position.maxScrollExtent));
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_vertical.hasClients || _heights.isEmpty) return;
      final zoom = _pendingZoom, anchor = _pendingAnchor;
      _pendingZoom = null;
      _pendingAnchor = null;
      if (zoom != null) {
        final index = zoom.$1.clamp(0, widget.pageCount - 1);
        _jump(_prefix[index] + 8 + zoom.$2 * _heights[index] - zoom.$3.dy);
        if (_horizontal.hasClients) {
          _horizontal.jumpTo(
            (16 + zoom.$4 * _paperWidth - zoom.$3.dx).clamp(
              0.0,
              _horizontal.position.maxScrollExtent,
            ),
          );
        }
      } else if (anchor != null) {
        final index = (anchor.page - 1).clamp(0, widget.pageCount - 1);
        _jump(_prefix[index] + anchor.fraction * (_heights[index] + 16));
        if (_horizontal.hasClients) {
          _horizontal.jumpTo(
            (anchor.horizontalFraction * _horizontal.position.maxScrollExtent)
                .clamp(0.0, _horizontal.position.maxScrollExtent),
          );
        }
      }
      _layoutPending = false;
      widget.controller.anchor = _anchor();
      final visible = <int, double>{};
      final start = _indexAt(_offset);
      for (
        var i = start;
        i < widget.pageCount && _prefix[i] < _offset + _viewport.height;
        i++
      ) {
        final top = _prefix[i] + 8, bottom = top + _heights[i];
        visible[i + 1] = math.max(
          0,
          math.min(bottom, _offset + _viewport.height) - math.max(top, _offset),
        );
      }
      final priority = visible.keys.toList()
        ..sort((a, b) {
          final area = visible[b]!.compareTo(visible[a]!);
          return area == 0 ? a.compareTo(b) : area;
        });
      final primary = priority.isEmpty ? start + 1 : priority.first;
      final nextWindow = priority.take(4).toSet();
      for (
        var distance = 0;
        nextWindow.length < math.min(4, widget.pageCount);
        distance++
      ) {
        for (final page in [primary + distance, primary - distance]) {
          if (page >= 1 && page <= widget.pageCount && nextWindow.length < 4) {
            nextWindow.add(page);
          }
        }
      }
      final nextVisible = visible.keys.toSet();
      if (!setEquals(nextWindow, _window) ||
          !setEquals(nextVisible, _visible)) {
        setState(() {
          _window = nextWindow;
          _visible = nextVisible;
        });
      }
      if (!_layoutPending && _ready.contains(primary) && primary != _reported) {
        _reported = primary;
        widget.onPresented(primary);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _zoom(double value, Offset? focalPoint) {
    if (_heights.isEmpty || (value - widget.controller.scale).abs() < .0001) {
      return;
    }
    final focal = focalPoint ?? _viewport.center(Offset.zero);
    final index = _indexAt(_offset + focal.dy);
    final fraction =
        ((_offset + focal.dy - _prefix[index] - 8) / _heights[index]).clamp(
          0.0,
          1.0,
        );
    final horizontalOffset = _horizontal.hasClients ? _horizontal.offset : 0.0;
    final fractionX = (horizontalOffset + focal.dx - 16) / _paperWidth;
    setState(() {
      _pendingZoom = (index, fraction, focal, fractionX);
      _pendingAnchor = null;
      _layoutPending = true;
      widget.controller.scale = value.clamp(1.0, 4.0);
    });
    _schedule();
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _insideControl(event.position)) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoom(
          (widget.controller.scale * math.exp(-event.scrollDelta.dy / 360))
              .clamp(1.0, 4.0),
          event.localPosition,
        );
      } else {
        _jump(_offset + event.scrollDelta.dy);
        if (event.scrollDelta.dx != 0 && _horizontal.hasClients) {
          _horizontal.jumpTo(
            (_horizontal.offset + event.scrollDelta.dx).clamp(
              0.0,
              _horizontal.position.maxScrollExtent,
            ),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width =
          math.max(1.0, constraints.maxWidth - 32) * widget.controller.scale;
      if (_paperWidth != width || _heights.length != widget.pageCount) {
        if (_heights.isNotEmpty &&
            _pendingAnchor == null &&
            _pendingZoom == null) {
          _pendingAnchor = _anchor();
        }
        _paperWidth = width;
        _prefix = [0];
        _heights = [];
        for (var page = 1; page <= widget.pageCount; page++) {
          final height = _paperWidth / widget.aspectFor(page);
          _heights.add(height);
          _prefix.add(_prefix.last + height + 16);
        }
        _layoutPending = true;
        _schedule();
      }
      _viewport = constraints.biggest;
      final contentWidth = math.max(constraints.maxWidth, _paperWidth + 32);
      return Listener(
        key: widget.viewportKey,
        behavior: HitTestBehavior.opaque,
        onPointerSignal: _signal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            if (_insideControl(details.globalPosition)) return;
            final x = details.localPosition.dx / _viewport.width;
            if (x >= .35 && x <= .65) {
              widget.onCenterTap?.call();
            } else if (x < .35) {
              widget.onPrevious?.call();
            } else {
              widget.onNext?.call();
            }
          },
          onScaleStart: (details) {
            _ignoredGesture = _insideControl(details.focalPoint);
            _gestureScale = widget.controller.scale;
          },
          onScaleUpdate: (details) {
            if (_ignoredGesture) return;
            if (details.pointerCount >= 2) {
              _zoom(
                (_gestureScale * details.scale).clamp(1.0, 4.0),
                details.localFocalPoint,
              );
            } else {
              _jump(_offset - details.focalPointDelta.dy);
            }
          },
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: SizedBox(
              width: contentWidth,
              height: constraints.maxHeight,
              child: ListView.builder(
                key: const ValueKey('continuous-page-list'),
                controller: _vertical,
                physics: const NeverScrollableScrollPhysics(),
                scrollCacheExtent: ScrollCacheExtent.pixels(_viewport.height * .6),
                itemCount: widget.pageCount,
                itemExtentBuilder: (index, _) => _heights[index] + 16,
                itemBuilder: (context, index) {
                  final number = index + 1;
                  return Center(
                    child: SizedBox(
                      width: _paperWidth,
                      height: _heights[index],
                      child: _window.contains(number)
                          ? _ContinuousPaper(
                              key: ValueKey((widget.documentKey, number)),
                              number: number,
                              active:
                                  _prefix[index] < _offset + _viewport.height &&
                                  _prefix[index + 1] > _offset,
                              builder: widget.pageBuilder,
                              mounted: (token) {
                                _mounted[number] = token;
                                _ready.remove(number);
                              },
                              unmounted: (token) {
                                if (identical(_mounted[number], token)) {
                                  _mounted.remove(number);
                                  _ready.remove(number);
                                }
                              },
                              ready: (token) {
                                if (mounted &&
                                    identical(_mounted[number], token)) {
                                  _ready.add(number);
                                  _schedule();
                                }
                              },
                            )
                          : ColoredBox(
                              color: Colors.white,
                              child: Center(
                                child: Text(
                                  '$number',
                                  style: const TextStyle(color: Colors.black38),
                                ),
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ContinuousPaper extends StatefulWidget {
  const _ContinuousPaper({
    super.key,
    required this.number,
    required this.active,
    required this.builder,
    required this.mounted,
    required this.unmounted,
    required this.ready,
  });
  final int number;
  final bool active;
  final ReadyPageBuilder builder;
  final ValueChanged<Object> mounted, unmounted, ready;
  @override
  State<_ContinuousPaper> createState() => _ContinuousPaperState();
}

class _ContinuousPaperState extends State<_ContinuousPaper> {
  final _token = Object();
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.mounted(_token);
  }

  @override
  void dispose() {
    widget.unmounted(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ColoredBox(
        color: Colors.white,
        child: widget.builder(
          widget.number,
          widget.active,
          () => widget.ready(_token),
          (error) {
            if (mounted && error != _error) setState(() => _error = error);
          },
        ),
      ),
      if (_error != null) Center(child: Text(_error!)),
    ],
  );
}
