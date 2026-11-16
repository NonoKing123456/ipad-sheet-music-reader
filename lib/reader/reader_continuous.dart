import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'reader_page_window.dart';
import 'reader_presentation_policy.dart';
import 'reader_text_editing.dart';
import '../theme/tokens.dart';

class ReaderScrollAnchor {
  const ReaderScrollAnchor(this.page, this.fraction, this.horizontalFraction);
  final int page;
  final double fraction, horizontalFraction;
}

const continuousMinScale = .25, continuousMaxScale = 8.0;
const continuousPreviewPixels = 2000000;

typedef ContinuousPreviewBuilder = Widget Function(
  int page,
  int pixelBudget,
  VoidCallback ready,
  ValueChanged<String?> failed,
);

class ReaderContinuousController {
  double scale = 1;
  ReaderScrollAnchor? anchor;
  ValueChanged<double>? _zoom;
  void zoom(double factor) {
    final next = (scale * factor).clamp(continuousMinScale, continuousMaxScale);
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
    this.previewPageBuilder,
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
    this.rasterPageLimit = 4,
    this.touchPanHorizontal = false,
    this.edgeToEdge = false,
    this.touchInk = false,
    this.textTool = false,
    this.navigationBlocked = false,
    this.onTransformGestureChanged,
  });
  final Object documentKey;
  final int pageCount, requestedPage, navigationToken;
  final double Function(int) aspectFor;
  final ReadyPageBuilder pageBuilder;
  final ContinuousPreviewBuilder? previewPageBuilder;
  final ReaderContinuousController controller;
  final ReaderScrollAnchor? initialAnchor;
  final ValueChanged<int> onPresented;
  final VoidCallback? onCenterTap, onPrevious, onNext;
  final GlobalKey? controlKey, viewportKey;
  final VoidCallback? retainDocument, releaseDocument;

  /// Tablet limits decoded page residency while retaining the same geometry,
  /// navigation and low-resolution previews for every visible page.
  final int rasterPageLimit;
  final bool touchPanHorizontal;
  final bool edgeToEdge;
  final bool touchInk, textTool, navigationBlocked;
  final ValueChanged<bool>? onTransformGestureChanged;
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
  // A short, zoomed-out document is centered rather than stranded at one edge.
  double get _verticalCenterInset =>
      _prefix.isEmpty ? 0 : math.max(0, (_viewport.height - _prefix.last) / 2);
  double get _sideInset => widget.edgeToEdge ? 0 : ScoreSpace.lg;
  double get _pageTopInset => widget.edgeToEdge ? 0 : ScoreSpace.sm;
  double _extent(int index) => _prefix[index + 1] - _prefix[index];
  double get _paperLeft =>
      (math.max(_viewport.width, _paperWidth + 2 * _sideInset) - _paperWidth) /
      2;
  int get _previewBudget => math.min(
    256000,
    continuousPreviewPixels ~/ math.max(1, _visible.difference(_window).length),
  );
  List<double> _prefix = [0], _heights = [];
  bool _scheduled = false, _layoutPending = true, _ignoredGesture = false;
  ReaderScrollAnchor? _pendingAnchor;
  (int, double, Offset, double)? _pendingZoom;
  int? _reported;
  int? _requestedPresentation;
  int? _navigationFocus;
  double _gestureScale = 1;
  (int, double, double)? _gestureAnchor;
  int _gesturePointers = 0;
  final _contacts = <int>{}, _pens = <int>{}, _touches = <int>{};
  bool _blockedPointerSequence = false;
  Offset? _tapOrigin;
  bool _tapMoved = false;
  final _painted = <int>{};
  bool _limited = false, _frozen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final limited = ReaderPresentationPolicy.limitedOf(context);
    final frozen = ReaderPresentationPolicy.frozenOf(context);
    if (_limited != limited || _frozen != frozen) {
      _limited = limited;
      _frozen = frozen;
      if (frozen) {
        // Drop only offscreen prefetch. Every already visible full surface or
        // low-resolution preview stays in place, with unchanged scroll geometry.
        _window = _window.intersection(_visible);
      } else {
        _schedule();
      }
    }
  }

  void _pointerDown(PointerDownEvent event) {
    if (_contacts.isEmpty) {
      _blockedPointerSequence = false;
      _tapOrigin = event.localPosition;
      _tapMoved = false;
    }
    _contacts.add(event.pointer);
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _pens.add(event.pointer);
      _blockedPointerSequence = true;
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touches.add(event.pointer);
      if (_touches.length == 2 && _pens.isEmpty) {
        widget.onTransformGestureChanged?.call(true);
      }
    }
  }

  void _pointerEnd(PointerEvent event) {
    final transforming = _touches.length >= 2;
    _contacts.remove(event.pointer);
    _pens.remove(event.pointer);
    _touches.remove(event.pointer);
    if (transforming && _touches.length < 2) {
      widget.onTransformGestureChanged?.call(false);
    }
  }

  void _anchorGesture(Offset focal) {
    if (_heights.isEmpty) return;
    final index = _indexAt(_offset + focal.dy);
    final fraction =
        ((_offset +
                    focal.dy -
                    _prefix[index] -
                    _pageTopInset -
                    _verticalCenterInset) /
                _heights[index])
            .clamp(0.0, 1.0);
    final x = _horizontal.hasClients ? _horizontal.offset : 0.0;
    final fractionX = ((x + focal.dx - _paperLeft) / _paperWidth).clamp(
      0.0,
      1.0,
    );
    _gestureAnchor = (index, fraction, fractionX);
  }

  void _transformGesture(double scale, Offset focal) {
    final anchor = _gestureAnchor;
    if (anchor == null) return;
    setState(() {
      _pendingZoom = (anchor.$1, anchor.$2, focal, anchor.$3);
      _pendingAnchor = null;
      _layoutPending = true;
      widget.controller.scale = scale.clamp(
        continuousMinScale,
        continuousMaxScale,
      );
    });
    _schedule();
  }

  late final ValueChanged<double> _zoomCallback = _zoomFromController;
  void _zoomFromController(double value) {
    _zoom(value, null);
  }

  @override
  void initState() {
    super.initState();
    widget.retainDocument?.call();
    _pendingAnchor =
        widget.initialAnchor ?? ReaderScrollAnchor(widget.requestedPage, 0, 0);
    _requestedPresentation = widget.requestedPage;
    _navigationFocus = widget.requestedPage;
    widget.controller._zoom = _zoomCallback;
    _vertical.addListener(_schedule);
  }

  @override
  void didUpdateWidget(covariant ReaderContinuousView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationToken != widget.navigationToken) {
      _pendingAnchor = ReaderScrollAnchor(widget.requestedPage, 0, 0);
      _requestedPresentation = widget.requestedPage;
      _navigationFocus = widget.requestedPage;
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
    position -= _verticalCenterInset;
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
      ((_offset - _prefix[index] - _verticalCenterInset) / _extent(index))
          .clamp(0.0, 1.0),
      horizontal,
    );
  }

  void _jump(double offset) {
    if (!_vertical.hasClients) return;
    _vertical.jumpTo(offset.clamp(0.0, _vertical.position.maxScrollExtent));
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted || _frozen) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _frozen || !_vertical.hasClients || _heights.isEmpty) {
        return;
      }
      final zoom = _pendingZoom, anchor = _pendingAnchor;
      _pendingZoom = null;
      _pendingAnchor = null;
      if (zoom != null) {
        final index = zoom.$1.clamp(0, widget.pageCount - 1);
        _jump(
          _prefix[index] +
              _verticalCenterInset +
              _pageTopInset +
              zoom.$2 * _heights[index] -
              zoom.$3.dy,
        );
        if (_horizontal.hasClients) {
          _horizontal.jumpTo(
            (_paperLeft + zoom.$4 * _paperWidth - zoom.$3.dx).clamp(
              0.0,
              _horizontal.position.maxScrollExtent,
            ),
          );
        }
      } else if (anchor != null) {
        final index = (anchor.page - 1).clamp(0, widget.pageCount - 1);
        _jump(
          _prefix[index] +
              _verticalCenterInset +
              anchor.fraction * _extent(index),
        );
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
        i < widget.pageCount &&
            _prefix[i] + _verticalCenterInset < _offset + _viewport.height;
        i++
      ) {
        final top = _prefix[i] + _verticalCenterInset + _pageTopInset,
            bottom = top + _heights[i];
        final area = math.max(
          0.0,
          math.min(bottom, _offset + _viewport.height) - math.max(top, _offset),
        );
        // A page whose tail is above the viewport's inter-page gap cannot
        // paint here and must not participate in the destination paint gate.
        if (area > 0) visible[i + 1] = area;
      }
      final priority = visible.keys.toList()
        ..sort((a, b) {
          final area = visible[b]!.compareTo(visible[a]!);
          return area == 0 ? a.compareTo(b) : area;
        });
      final primary = priority.isEmpty ? start + 1 : priority.first;
      final navigationFocus = _navigationFocus;
      final nextWindow = <int>{
        if (navigationFocus != null && visible.containsKey(navigationFocus))
          navigationFocus,
        ...priority,
      }.take(_limited ? 1 : widget.rasterPageLimit).toSet();
      for (
        var distance = 0;
        nextWindow.length <
            math.min(_limited ? 1 : widget.rasterPageLimit, widget.pageCount);
        distance++
      ) {
        for (final page in [primary + distance, primary - distance]) {
          if (page >= 1 &&
              page <= widget.pageCount &&
              nextWindow.length < (_limited ? 1 : widget.rasterPageLimit)) {
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
      final requested = _requestedPresentation;
      final presented =
          navigationFocus != null && visible.containsKey(navigationFocus)
          ? navigationFocus
          : primary;
      if (!_layoutPending &&
          _ready.contains(presented) &&
          _painted.contains(presented) &&
          (!_limited ||
              _visible.every(
                (page) => _ready.contains(page) && _painted.contains(page),
              )) &&
          (presented != _reported || requested != null)) {
        _requestedPresentation = null;
        _reported = presented;
        widget.onPresented(presented);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _zoom(double value, Offset? focalPoint) {
    if (_heights.isEmpty || (value - widget.controller.scale).abs() < .0001) {
      return;
    }
    final focal = focalPoint ?? _viewport.center(Offset.zero);
    _navigationFocus = null;
    _requestedPresentation = null;
    final index = _indexAt(_offset + focal.dy);
    final fraction =
        ((_offset +
                    focal.dy -
                    _prefix[index] -
                    _pageTopInset -
                    _verticalCenterInset) /
                _heights[index])
            .clamp(0.0, 1.0);
    final horizontalOffset = _horizontal.hasClients ? _horizontal.offset : 0.0;
    final fractionX = ((horizontalOffset + focal.dx - _paperLeft) / _paperWidth)
        .clamp(0.0, 1.0);
    setState(() {
      _pendingZoom = (index, fraction, focal, fractionX);
      _pendingAnchor = null;
      _layoutPending = true;
      widget.controller.scale = value.clamp(
        continuousMinScale,
        continuousMaxScale,
      );
    });
    _schedule();
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _insideControl(event.position)) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _requestedPresentation = null;
      _navigationFocus = null;
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoom(
          (widget.controller.scale * math.exp(-event.scrollDelta.dy / 360))
              .clamp(continuousMinScale, continuousMaxScale),
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
          math.max(1.0, constraints.maxWidth - 2 * _sideInset) *
          widget.controller.scale;
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
          final gap = widget.edgeToEdge && page == widget.pageCount
              ? 0
              : ScoreSpace.lg;
          _prefix.add(_prefix.last + height + gap);
        }
        _layoutPending = true;
        _schedule();
      }
      _viewport = constraints.biggest;
      final contentWidth = math.max(
        constraints.maxWidth,
        _paperWidth + 2 * _sideInset,
      );
      return Listener(
        key: widget.viewportKey,
        behavior: HitTestBehavior.opaque,
        onPointerSignal: _signal,
        onPointerDown: _pointerDown,
        onPointerMove: (event) {
          if (_tapOrigin != null &&
              (event.localPosition - _tapOrigin!).distance > 8) {
            _tapMoved = true;
          }
        },
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            if (_tapMoved ||
                _insideControl(details.globalPosition) ||
                _blockedPointerSequence ||
                widget.navigationBlocked ||
                widget.touchInk ||
                widget.textTool ||
                readerTextEditorActive ||
                readerTextHandleActive) {
              return;
            }
            final x = details.localPosition.dx / _viewport.width;
            final center = x >= .35 && x <= .65;
            if (center) {
              widget.onCenterTap?.call();
            } else if (x < .35) {
              widget.onPrevious?.call();
            } else {
              widget.onNext?.call();
            }
          },
          onScaleStart: (details) {
            _ignoredGesture =
                _insideControl(details.focalPoint) ||
                _blockedPointerSequence ||
                widget.navigationBlocked ||
                readerTextEditorActive ||
                readerTextHandleActive;
            _gesturePointers = details.pointerCount;
            _anchorGesture(details.localFocalPoint);
            if (!_ignoredGesture) {
              _requestedPresentation = null;
              _navigationFocus = null;
            }
            _gestureScale = widget.controller.scale;
          },
          onScaleUpdate: (details) {
            if (_ignoredGesture ||
                _blockedPointerSequence ||
                widget.navigationBlocked ||
                readerTextHandleActive ||
                readerTextEditorActive) {
              return;
            }
            if (details.pointerCount >= 2) {
              if (_gesturePointers < 2) {
                _anchorGesture(
                  details.localFocalPoint - details.focalPointDelta,
                );
              }
              _transformGesture(
                (_gestureScale * details.scale).clamp(
                  continuousMinScale,
                  continuousMaxScale,
                ),
                details.localFocalPoint,
              );
            } else {
              if (widget.touchInk || widget.textTool || _gesturePointers >= 2) {
                return;
              }
              _jump(_offset - details.focalPointDelta.dy);
              if (widget.touchPanHorizontal && _horizontal.hasClients) {
                _horizontal.jumpTo(
                  (_horizontal.offset - details.focalPointDelta.dx).clamp(
                    0.0,
                    _horizontal.position.maxScrollExtent,
                  ),
                );
              }
            }
            _gesturePointers = details.pointerCount;
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
                padding: _verticalCenterInset > 0
                    ? EdgeInsets.symmetric(vertical: _verticalCenterInset)
                    : widget.edgeToEdge
                    ? EdgeInsets.zero
                    : null,
                physics: const NeverScrollableScrollPhysics(),
                scrollCacheExtent: ScrollCacheExtent.pixels(
                  _viewport.height * .6,
                ),
                itemCount: widget.pageCount,
                itemExtentBuilder: (index, _) => _extent(index),
                itemBuilder: (context, index) {
                  final number = index + 1;
                  final preview =
                      !_window.contains(number) &&
                      _visible.contains(number) &&
                      widget.previewPageBuilder != null;
                  return Align(
                    alignment: widget.edgeToEdge
                        ? Alignment.topCenter
                        : Alignment.center,
                    child: SizedBox(
                      width: _paperWidth,
                      height: _heights[index],
                      child: _window.contains(number) || preview
                          ? _ContinuousPaper(
                              key: ValueKey((widget.documentKey, number)),
                              number: number,
                              preview: preview,
                              active:
                                  _prefix[index] + _verticalCenterInset <
                                      _offset + _viewport.height &&
                                  _prefix[index + 1] + _verticalCenterInset >
                                      _offset,
                              builder: preview
                                  ? (number, active, ready, failed) =>
                                        widget.previewPageBuilder!(
                                          number,
                                          _previewBudget,
                                          ready,
                                          failed,
                                        )
                                  : widget.pageBuilder,
                              mounted: (token) {
                                _mounted[number] = token;
                                _ready.remove(number);
                                _painted.remove(number);
                              },
                              unmounted: (token) {
                                if (identical(_mounted[number], token)) {
                                  _mounted.remove(number);
                                  _ready.remove(number);
                                  _painted.remove(number);
                                }
                              },
                              painted: (token) {
                                if (mounted &&
                                    identical(_mounted[number], token) &&
                                    _ready.contains(number)) {
                                  _painted.add(number);
                                  _schedule();
                                }
                              },
                              ready: (token) {
                                if (mounted &&
                                    identical(_mounted[number], token)) {
                                  if (!_ready.contains(number)) {
                                    setState(() => _ready.add(number));
                                  }
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
    required this.preview,
    required this.builder,
    required this.mounted,
    required this.unmounted,
    required this.ready,
    required this.painted,
  });
  final int number;
  final bool active, preview;
  final ReadyPageBuilder builder;
  final ValueChanged<Object> mounted, unmounted, ready, painted;
  @override
  State<_ContinuousPaper> createState() => _ContinuousPaperState();
}

class _ContinuousPaperState extends State<_ContinuousPaper> {
  final _token = Object();
  String? _error;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    widget.mounted(_token);
  }

  @override
  void didUpdateWidget(covariant _ContinuousPaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview != widget.preview) {
      _ready = false;
      widget.mounted(_token);
    }
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
      ReaderPaintAcknowledgement(
        onPainted: _ready ? () => widget.painted(_token) : null,
        child: ColoredBox(
          color: Colors.white,
          child: widget.builder(
            widget.number,
            widget.active,
            () {
              if (mounted && !_ready) setState(() => _ready = true);
              widget.ready(_token);
            },
            (error) {
              if (mounted && error != _error) setState(() => _error = error);
            },
          ),
        ),
      ),
      if (_error != null) Center(child: Text(_error!)),
    ],
  );
}
