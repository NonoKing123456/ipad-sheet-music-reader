import 'dart:math' as math;

import 'reader_presentation_policy.dart';

import '../theme/tokens.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'reader_stage.dart';

import 'package:flutter/scheduler.dart';

final _presentationClock = Stopwatch()..start();
Duration readerPresentationNow() => _presentationClock.elapsed;

typedef ReadyPageBuilder = Widget Function(
  int number,
  bool active,
  VoidCallback ready,
  ValueChanged<String?> failed,
);

class ReaderPageRenderError extends StatelessWidget {
  const ReaderPageRenderError({
    super.key,
    required this.message,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    return Material(
      color: tokens.dangerBg,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(ScoreSpace.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.dangerInk),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: tokens.dangerInk),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class ReaderPrewarmPage {
  const ReaderPrewarmPage({
    required this.documentKey,
    required this.aspect,
    required this.pageBuilder,
    this.retainDocument,
    this.releaseDocument,
  });
  final Object documentKey;
  final double aspect;
  final ReadyPageBuilder pageBuilder;
  final VoidCallback? retainDocument, releaseDocument;
}

/// Keeps a captured paper+annotation surface visible until the requested surface
/// can actually paint. At rest only the current page and neighbours are mounted;
/// a transition temporarily retains its outgoing surface as well.
class ReaderPageWindow extends StatefulWidget {
  const ReaderPageWindow({
    super.key,
    required this.pageNumber,
    required this.pageCount,
    required this.aspectFor,
    this.pageBuilder,
    this.readyPageBuilder,
    this.documentKey = 'document',
    this.direction = 1,
    this.onPresented,
    this.retainDocument,
    this.releaseDocument,
    this.holdPresentation = false,
    this.prewarm,
    this.requestedAt,
    this.presentationClock,
    this.forwardWindowOnly = false,
    this.surfaceBackground = Colors.white,
    this.paperWidthTransition = false,
    this.shortPageTransition = false,
    this.tabletPageTurn = false,
    this.onWillPresent,
    this.onWillPresentPage,
    this.onSelected,
  });
  final int pageNumber, pageCount;

  /// Zero is an explicit seek/outline jump. Adjacent turns keep their existing
  /// signed direction and animation, including cross-score prewarming.
  final int direction;
  final Object documentKey;
  final double Function(int) aspectFor;
  final Widget Function(int)? pageBuilder;
  final ReadyPageBuilder? readyPageBuilder;
  final void Function(Object document, int page)? onPresented;
  final VoidCallback? retainDocument, releaseDocument;
  final bool holdPresentation;
  final ReaderPrewarmPage? prewarm;
  final Duration? requestedAt;
  final Duration Function()? presentationClock;

  /// Desktop spreads use at most two groups (four actual paper surfaces).
  final bool forwardWindowOnly;
  final Color surfaceBackground;
  final bool paperWidthTransition;

  /// Desktop replacement uses one opaque group with a short settling movement.
  /// The callback resets its viewport in the same frame that reveals the group.
  final bool shortPageTransition;
  final bool tabletPageTurn;
  final VoidCallback? onWillPresent;

  /// Prepaint geometry for the exact surface being revealed, including a
  /// replacement during a rapid turn. Metadata persistence still uses
  /// [onPresented] after the selected surface has painted.
  final void Function(Object document, int page)? onWillPresentPage;

  /// Metadata selection for the frame being revealed. Persistence still waits
  /// for [onPresented], after an actual selected paint acknowledgement.
  final void Function(Object document, int page)? onSelected;
  @override
  State<ReaderPageWindow> createState() => _ReaderPageWindowState();
}

class _PageId {
  const _PageId(this.document, this.number);
  final Object document;
  final int number;
  @override
  bool operator ==(Object other) =>
      other is _PageId && other.document == document && other.number == number;
  @override
  int get hashCode => Object.hash(document, number);
}

class _Surface {
  _Surface(this.owner, this.number) {
    owner.retainDocument?.call();
  }
  ReaderPageWindow owner;
  final int number;
  bool ready = false;
  bool painted = false;
  Duration? readySince;
  String? error;
  int retry = 0;
  void dispose() => owner.releaseDocument?.call();
}

class _ReaderPageWindowState extends State<ReaderPageWindow>
    with SingleTickerProviderStateMixin {
  final _surfaces = <_PageId, _Surface>{};
  late final AnimationController _animation;
  late _PageId _requested, _displayed;
  _PageId? _incoming;
  int _direction = 1;
  bool _initialPresented = false;
  bool _reversing = false;
  bool _startScheduled = false;
  bool _settleRevealed = false;
  int _settleEpoch = 0;
  _PageId? _awaitingPaint;
  Duration _transitionStart = Duration.zero;
  bool _limited = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final limited = ReaderPresentationPolicy.limitedOf(context);
    if (_limited != limited) {
      _limited = limited;
      if (limited) {
        // A mode handoff retains the last committed paper, never two halves
        // of an unfinished turn plus another full destination window.
        _animation.stop();
        _settleEpoch++;
        if (_settleRevealed && _incoming != null) _displayed = _incoming!;
        _incoming = null;
        _settleRevealed = false;
        _startScheduled = false;
        _requested = _displayed;
      }
      _capture();
    }
  }

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: widget.tabletPageTurn
          ? ScoreMotion.tabletPageSettle
          : const Duration(milliseconds: 90),
    )..addStatusListener(_status);
    _requested = _displayed = _PageId(widget.documentKey, widget.pageNumber);
    _capture();
  }

  @override
  void didUpdateWidget(ReaderPageWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _animation.duration = widget.tabletPageTurn
        ? ScoreMotion.tabletPageSettle
        : const Duration(milliseconds: 90);
    _requested = _PageId(widget.documentKey, widget.pageNumber);
    if (widget.direction == 0 && _incoming != null) {
      // Retire an obsolete transition before capturing the latest destination.
      // A desktop group already revealed is the paper the user currently sees.
      if (_settleRevealed) _displayed = _incoming!;
      _settleEpoch++;
      _animation.stop();
      _incoming = null;
      _settleRevealed = false;
      _reversing = false;
      _startScheduled = false;
    }
    _capture();
    _tryPresent();
  }

  void _capture() {
    if (widget.forwardWindowOnly &&
        _incoming != null &&
        _requested != _incoming &&
        _requested != _displayed) {
      return;
    }
    _trim();
    for (
      var n = math.max(1, widget.pageNumber - 1);
      n <= math.min(widget.pageCount, widget.pageNumber + 1);
      n++
    ) {
      if ((widget.forwardWindowOnly || _limited) &&
          !_inWindow(_PageId(widget.documentKey, n))) {
        continue;
      }
      final id = _PageId(widget.documentKey, n);
      final surface = _surfaces[id];
      if (surface == null) {
        _surfaces[id] = _Surface(widget, n);
      } else {
        surface.owner = widget;
      }
    }
    final warm = _canPrewarm ? widget.prewarm : null;
    if (warm != null) {
      final id = _PageId(warm.documentKey, 1);
      if (!(id.document == widget.documentKey &&
          (id.number - widget.pageNumber).abs() <= 1)) {
        final owner = ReaderPageWindow(
          documentKey: warm.documentKey,
          pageNumber: 1,
          pageCount: 1,
          aspectFor: (_) => warm.aspect,
          readyPageBuilder: warm.pageBuilder,
          retainDocument: warm.retainDocument,
          releaseDocument: warm.releaseDocument,
        );
        if (_surfaces.containsKey(id)) {
          _surfaces[id]!.owner = owner;
        } else {
          _surfaces[id] = _Surface(owner, 1);
        }
      }
    }
    _trim();
  }

  bool _inWindow(_PageId id) {
    if (_limited) return id == _requested;
    if (id.document != widget.documentKey) return false;
    if (!widget.forwardWindowOnly) {
      return (id.number - widget.pageNumber).abs() <= 1;
    }
    return id.number == widget.pageNumber ||
        (widget.prewarm == null &&
            _incoming == null &&
            _requested == _displayed &&
            id.number ==
                widget.pageNumber +
                    (widget.direction == 0
                        ? (widget.pageNumber == widget.pageCount ? -1 : 1)
                        : widget.direction));
  }

  bool get _canPrewarm =>
      !_limited &&
      (!widget.forwardWindowOnly ||
          (_incoming == null && _requested == _displayed));

  void _trim() {
    final remove = _surfaces.keys
        .where(
          (id) =>
              id != _displayed &&
              id != _incoming &&
              !(_canPrewarm &&
                  id.document == widget.prewarm?.documentKey &&
                  id.number == 1) &&
              !_inWindow(id),
        )
        .toList();
    for (final id in remove) {
      _surfaces.remove(id)!.dispose();
    }
  }

  Duration _now() =>
      widget.presentationClock?.call() ?? readerPresentationNow();
  bool _currentSurface(_PageId id, _Surface surface, int retry) =>
      identical(_surfaces[id], surface) && surface.retry == retry;

  void _ready(_PageId id, _Surface surface, int retry) {
    final readyTime = _now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_currentSurface(id, surface, retry)) return;
      setState(() {
        _surfaces[id]!.readySince ??= readyTime;
        _surfaces[id]!.ready = true;
        _surfaces[id]!.error = null;
        _tryPresent();
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _failed(_PageId id, _Surface surface, int retry, String? error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentSurface(id, surface, retry)) {
        setState(() => _surfaces[id]!.error = error);
      }
    });
  }

  int _directionFor(_PageId id) => id.document == _displayed.document
      ? (id.number > _displayed.number ? 1 : -1)
      : widget.direction;
  bool _geometryPresentationScheduled = false;
  void _tryPresent() {
    // Geometry listeners can include ancestors of this surface. Publish the
    // exact target before the next build, never from a descendant's build.
    if ((widget.onWillPresentPage != null || widget.onWillPresent != null) &&
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
      if (!_geometryPresentationScheduled) {
        _geometryPresentationScheduled = true;
        SchedulerBinding.instance.scheduleFrameCallback((_) {
          _geometryPresentationScheduled = false;
          if (mounted) setState(_tryPresent);
        });
      }
      return;
    }
    if (widget.holdPresentation) return;
    if (widget.direction == 0 && _requested != _displayed) {
      if (!(_surfaces[_requested]?.ready ?? false)) return;
      // Only an explicit jump uses this path. Keep the old paper until the
      // latest destination is decoded, then replace it in one frame.
      _preparePresentation(_requested);
      _surfaces[_requested]!.owner.onSelected?.call(
        _requested.document,
        _requested.number,
      );
      _incoming = _requested;
      _complete();
      return;
    }
    if (widget.shortPageTransition) {
      _trySettle();
      return;
    }
    // A bounded spread cannot mount a third group until its incoming group is
    // released. Reverse an obsolete incoming group before waiting for the new
    // target; otherwise a quick opposite key would first present the old target.
    if (widget.forwardWindowOnly &&
        _incoming != null &&
        _requested != _incoming &&
        (_requested == _displayed || _directionFor(_requested) != _direction)) {
      if (_startScheduled && !_animation.isAnimating) {
        _incoming = null;
        _reversing = false;
        widget.forwardWindowOnly ? _capture() : _trim();
        _tryPresent();
      } else if (!_reversing) {
        _reversing = true;
        _animation.reverse();
      }
      return;
    }
    if (!(_surfaces[_requested]?.ready ?? false)) return;
    if (_incoming != null) {
      if (_requested == _incoming && !_reversing) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _incoming = _requested;
        _reversing = false;
        _preparePresentation(_incoming!);
        _complete();
        return;
      }
      if (_requested == _displayed || _directionFor(_requested) != _direction) {
        if (_startScheduled && !_animation.isAnimating) {
          _incoming = null;
          _reversing = false;
          _trim();
          _tryPresent();
          return;
        }
        if (!_reversing) {
          _reversing = true;
          _animation.reverse();
        }
      } else {
        // Replace an unpresented incoming target at its existing offset. This
        // consumes no extra animation duration and never bookmarks the skipped page.
        final resume = _reversing;
        _incoming = _requested;
        _reversing = false;
        _preparePresentation(_incoming!);
        _trim();
        if (!_startScheduled && (resume || !_animation.isAnimating)) {
          _animation.forward();
        }
      }
      return;
    }
    if (_displayed == _requested) {
      if (!_initialPresented) {
        _preparePresentation(_displayed);
        _initialPresented = true;
        _notifyPresented();
      }
      return;
    }
    _direction = _directionFor(_requested);
    _incoming = _requested;
    _reversing = false;
    if (MediaQuery.disableAnimationsOf(context) ||
        (widget.forwardWindowOnly && widget.direction == 0)) {
      _preparePresentation(_incoming!);
      _complete();
    } else {
      final requested = widget.requestedAt ?? _now();
      final ready = _surfaces[_requested]!.readySince ?? requested;
      final start = requested > ready ? requested : ready;
      _transitionStart = start;
      _animation.value = 0;
      if (SchedulerBinding.instance.schedulerPhase ==
              SchedulerPhase.postFrameCallbacks ||
          SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
        if (!_startScheduled) {
          _startScheduled = true;
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            _startScheduled = false;
            if (mounted && _incoming != null && !_reversing) _launchAnimation();
          });
        }
      } else {
        _launchAnimation();
      }
    }
  }

  void _trySettle() {
    if (_incoming != null) {
      if (_requested == _incoming) return;
      // Keep the group that has actually become visible while preparing the
      // latest request. Never bounce back to an obsolete outgoing group.
      _settleEpoch++;
      _startScheduled = false;
      _animation.stop();
      if (_settleRevealed) {
        _displayed = _incoming!;
        _initialPresented = true;
      }
      _incoming = null;
      _settleRevealed = false;
      _capture();
    }
    if (!(_surfaces[_requested]?.ready ?? false)) return;
    if (_displayed == _requested) {
      if (!_initialPresented) {
        _preparePresentation(_displayed);
        _initialPresented = true;
        _notifyPresented();
      }
      return;
    }
    _incoming = _requested;
    _direction = _directionFor(_requested);
    _settleRevealed = false;
    final epoch = ++_settleEpoch;
    _startScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (!mounted || epoch != _settleEpoch || _incoming != _requested) return;
      _startScheduled = false;
      setState(() {
        // This callback runs before build/paint, so the new paper and its fit
        // transform become visible together. Hidden decoded neighbours do not
        // have to paint before they may be selected.
        _preparePresentation(_incoming!);
        _settleRevealed = true;
        final selected = _incoming!;
        _surfaces[selected]!.owner.onSelected?.call(
          selected.document,
          selected.number,
        );
        if (MediaQuery.disableAnimationsOf(context) || widget.direction == 0) {
          _complete();
        } else {
          _animation.forward(from: 0);
        }
      });
    });
  }

  void _painted(_PageId id, _Surface surface, int retry) {
    if (!mounted || !_currentSurface(id, surface, retry) || !surface.ready) {
      return;
    }
    surface.painted = true;
    if (_awaitingPaint == id && _displayed == id && _incoming == null) {
      _notifyPresented();
    }
  }

  void _preparePresentation(_PageId id) {
    widget.onWillPresent?.call();
    _surfaces[id]?.owner.onWillPresentPage?.call(id.document, id.number);
  }

  void _launchAnimation() {
    _preparePresentation(_incoming!);
    final elapsed = (_now() - _transitionStart).inMicroseconds / 90000;
    _animation.forward(from: elapsed.clamp(0.0, 1.0));
  }

  void _notifyPresented() {
    final id = _displayed;
    if (!(_surfaces[id]?.painted ?? false)) {
      _awaitingPaint = id;
      return;
    }
    _awaitingPaint = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _displayed == id && _requested == id) {
        _surfaces[id]?.owner.onPresented?.call(id.document, id.number);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _status(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed &&
        _incoming != null &&
        !_reversing) {
      setState(_complete);
    } else if (status == AnimationStatus.dismissed &&
        _incoming != null &&
        _reversing) {
      setState(() {
        _incoming = null;
        _reversing = false;
        widget.forwardWindowOnly ? _capture() : _trim();
        _tryPresent();
      });
    }
  }

  void _complete() {
    _displayed = _incoming!;
    _incoming = null;
    _settleRevealed = false;
    _initialPresented = true;
    _notifyPresented();
    widget.forwardWindowOnly ? _capture() : _trim();
    _tryPresent();
  }

  @override
  void dispose() {
    _animation.dispose();
    for (final s in _surfaces.values) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_animation.value);
          double fittedWidth(_PageId id) => math.min(
            constraints.maxWidth,
            constraints.maxHeight * _surfaces[id]!.owner.aspectFor(id.number),
          );
          final distance = widget.paperWidthTransition && _incoming != null
              ? (fittedWidth(_displayed) + fittedWidth(_incoming!)) / 2
              : constraints.maxWidth;
          final settledVisible = _incoming != null && _settleRevealed
              ? _incoming!
              : _displayed;
          final order =
              _surfaces.keys
                  .where((id) => id != _displayed && id != _incoming)
                  .toList()
                ..add(_displayed);
          if (_incoming != null) order.add(_incoming!);
          return Stack(
            fit: StackFit.expand,
            children: [
              for (final id in order)
                if (_surfaces.containsKey(id))
                  Positioned.fill(
                    key: ValueKey(id),
                    child: IgnorePointer(
                      ignoring:
                          id != _displayed ||
                          _incoming != null ||
                          !_surfaces[id]!.ready,
                      child: ExcludeSemantics(
                        excluding: id != _displayed,
                        child: Opacity(
                          opacity: widget.shortPageTransition
                              ? (id == settledVisible ? 1 : 0)
                              : (id == _displayed || id == _incoming ? 1 : 0),
                          child: Transform.translate(
                            offset: Offset(
                              widget.shortPageTransition
                                  ? (id == _incoming && _settleRevealed
                                        ? _direction *
                                              (1 - t) *
                                              (widget.tabletPageTurn
                                                  ? ScoreSpace.xl
                                                  : 10)
                                        : 0)
                                  : _incoming == null
                                  ? 0
                                  : id == _incoming
                                  ? _direction * (1 - t) * distance
                                  : id == _displayed
                                  ? -_direction * t * distance
                                  : 0,
                              0,
                            ),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: _surfaces[id]!.owner.aspectFor(
                                  id.number,
                                ),
                                child: ColoredBox(
                                  color: _surfaces[id]!.owner.surfaceBackground,
                                  child: _observePaint(id, _buildSurface(id)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              if (_requested != _displayed &&
                  _incoming == null &&
                  !(_surfaces[_requested]?.ready ?? false) &&
                  _surfaces[_requested]?.error == null)
                Positioned(
                  key: const ValueKey('reader-render-loading'),
                  right: 12,
                  bottom: 12,
                  child: Material(
                    color: ScoreTokens.of(context).paper0,
                    shape: const CircleBorder(),
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: '正在准备下一页',
                        ),
                      ),
                    ),
                  ),
                ),
              if (_incoming == null && _surfaces[_requested]?.error != null)
                Positioned(
                  key: const ValueKey('reader-render-error'),
                  left: (_surfaces[_displayed]?.ready ?? false) ? null : 16,
                  right: 16,
                  bottom: 16,
                  child: (_surfaces[_displayed]?.ready ?? false)
                      ? ReaderStatusButton(
                          label: '页面加载失败 · 查看并重试',
                          details: [_renderErrorDetails()],
                        )
                      : _renderErrorDetails(),
                ),
            ],
          );
        },
      ),
    ),
  );

  Widget _renderErrorDetails() {
    final surface = _surfaces[_requested]!;
    return ReaderPageRenderError(
      message: surface.error!,
      onRetry: () => setState(() {
        surface.error = null;
        surface.ready = false;
        surface.painted = false;
        surface.readySince = null;
        surface.retry++;
      }),
    );
  }

  Widget _buildSurface(_PageId id) {
    final surface = _surfaces[id]!;
    final retry = surface.retry;
    final readyBuilder = surface.owner.readyPageBuilder;
    if (readyBuilder == null) {
      if (!surface.ready) _ready(id, surface, retry);
      return surface.owner.pageBuilder!(id.number);
    }
    return KeyedSubtree(
      key: ValueKey(surface.retry),
      child: readyBuilder(
        id.number,
        id == _requested || id == _displayed,
        () => _ready(id, surface, retry),
        (error) => _failed(id, surface, retry, error),
      ),
    );
  }

  Widget _observePaint(_PageId id, Widget child) {
    final surface = _surfaces[id]!, retry = surface.retry;
    return _PaintedSurface(
      onPainted: surface.ready ? () => _painted(id, surface, retry) : null,
      child: child,
    );
  }
}

/// Decoded readiness also works for hidden prewarming. Presentation is a
/// separate acknowledgement after the selected group has participated in paint.
class _PaintedSurface extends SingleChildRenderObjectWidget {
  const _PaintedSurface({required this.onPainted, required super.child});
  final VoidCallback? onPainted;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PaintedSurfaceBox(onPainted);
  @override
  void updateRenderObject(
    BuildContext context,
    _PaintedSurfaceBox renderObject,
  ) {
    renderObject.onPainted = onPainted;
  }
}

class _PaintedSurfaceBox extends RenderProxyBox {
  _PaintedSurfaceBox(this._onPainted);
  VoidCallback? _onPainted;
  set onPainted(VoidCallback? value) {
    final needsAcknowledgement = _onPainted == null && value != null;
    _onPainted = value;
    if (needsAcknowledgement) markNeedsPaint();
  }

  bool _pending = false;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final callback = _onPainted;
    if (callback == null || _pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      callback();
    });
  }
}
