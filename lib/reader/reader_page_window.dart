import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  });
  final int pageNumber, pageCount, direction;
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
  Duration _transitionStart = Duration.zero;
  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
    )..addStatusListener(_status);
    _requested = _displayed = _PageId(widget.documentKey, widget.pageNumber);
    _capture();
  }

  @override
  void didUpdateWidget(ReaderPageWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _requested = _PageId(widget.documentKey, widget.pageNumber);
    _capture();
    _tryPresent();
  }

  void _capture() {
    _trim();
    for (
      var n = math.max(1, widget.pageNumber - 1);
      n <= math.min(widget.pageCount, widget.pageNumber + 1);
      n++
    ) {
      final id = _PageId(widget.documentKey, n);
      final surface = _surfaces[id];
      if (surface == null) {
        _surfaces[id] = _Surface(widget, n);
      } else {
        surface.owner = widget;
      }
    }
    final warm = widget.prewarm;
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

  void _trim() {
    final remove = _surfaces.keys
        .where(
          (id) =>
              id != _displayed &&
              id != _incoming &&
              !(id.document == widget.prewarm?.documentKey && id.number == 1) &&
              !(id.document == widget.documentKey &&
                  (id.number - widget.pageNumber).abs() <= 1),
        )
        .toList();
    for (final id in remove) {
      _surfaces.remove(id)!.dispose();
    }
  }

  Duration _now() =>
      widget.presentationClock?.call() ?? readerPresentationNow();
  void _ready(_PageId id) {
    final readyTime = _now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_surfaces.containsKey(id)) return;
      setState(() {
        _surfaces[id]!.readySince ??= readyTime;
        _surfaces[id]!.ready = true;
        _surfaces[id]!.error = null;
        _tryPresent();
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _failed(_PageId id, String? error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _surfaces.containsKey(id)) {
        setState(() => _surfaces[id]!.error = error);
      }
    });
  }

  int _directionFor(_PageId id) => id.document == _displayed.document
      ? (id.number > _displayed.number ? 1 : -1)
      : widget.direction;
  void _tryPresent() {
    if (widget.holdPresentation || !(_surfaces[_requested]?.ready ?? false)) {
      return;
    }
    if (_incoming != null) {
      if (_requested == _incoming && !_reversing) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _incoming = _requested;
        _reversing = false;
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
        _trim();
        if (!_startScheduled && (resume || !_animation.isAnimating)) {
          _animation.forward();
        }
      }
      return;
    }
    if (_displayed == _requested) {
      if (!_initialPresented) {
        _initialPresented = true;
        _notifyPresented();
      }
      return;
    }
    _direction = _directionFor(_requested);
    _incoming = _requested;
    _reversing = false;
    if (MediaQuery.disableAnimationsOf(context)) {
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

  void _launchAnimation() {
    final elapsed = (_now() - _transitionStart).inMicroseconds / 90000;
    _animation.forward(from: elapsed.clamp(0.0, 1.0));
  }

  void _notifyPresented() {
    final id = _displayed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _displayed == id) {
        _surfaces[id]?.owner.onPresented?.call(id.document, id.number);
      }
    });
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
        _trim();
        _tryPresent();
      });
    }
  }

  void _complete() {
    _displayed = _incoming!;
    _incoming = null;
    _initialPresented = true;
    _notifyPresented();
    _trim();
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
                          opacity: id == _displayed || id == _incoming ? 1 : 0,
                          child: Transform.translate(
                            offset: Offset(
                              _incoming == null
                                  ? 0
                                  : id == _incoming
                                  ? _direction * (1 - t) * constraints.maxWidth
                                  : id == _displayed
                                  ? -_direction * t * constraints.maxWidth
                                  : 0,
                              0,
                            ),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: _surfaces[id]!.owner.aspectFor(
                                  id.number,
                                ),
                                child: ColoredBox(
                                  color: Colors.white,
                                  child: _buildSurface(id),
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
                const Positioned(
                  key: ValueKey('reader-render-loading'),
                  right: 12,
                  bottom: 12,
                  child: Material(
                    color: Color(0xddeeeeee),
                    shape: CircleBorder(),
                    child: Padding(
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
    return Material(
      color: const Color(0xffffedcf),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: Text(surface.error!, textAlign: TextAlign.center)),
            TextButton(
              onPressed: () => setState(() {
                final s = surface;
                s.error = null;
                s.ready = false;
                s.readySince = null;
                s.retry++;
              }),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSurface(_PageId id) {
    final surface = _surfaces[id]!;
    final readyBuilder = surface.owner.readyPageBuilder;
    if (readyBuilder == null) {
      if (!surface.ready) _ready(id);
      return surface.owner.pageBuilder!(id.number);
    }
    return KeyedSubtree(
      key: ValueKey(surface.retry),
      child: readyBuilder(
        id.number,
        id == _requested || id == _displayed,
        () => _ready(id),
        (error) => _failed(id, error),
      ),
    );
  }
}
