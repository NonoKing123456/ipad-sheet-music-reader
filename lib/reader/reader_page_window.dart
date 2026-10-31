import 'dart:math' as math;

import 'package:flutter/material.dart';

typedef ReadyPageBuilder = Widget Function(
  int number,
  bool active,
  VoidCallback ready,
  ValueChanged<String?> failed,
);

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
  });
  final int pageNumber, pageCount, direction;
  final Object documentKey;
  final double Function(int) aspectFor;
  final Widget Function(int)? pageBuilder;
  final ReadyPageBuilder? readyPageBuilder;
  final void Function(Object document, int page)? onPresented;
  final VoidCallback? retainDocument, releaseDocument;
  final bool holdPresentation;
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
  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
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
    _trim();
  }

  void _trim() {
    final remove = _surfaces.keys
        .where(
          (id) =>
              id != _displayed &&
              id != _incoming &&
              !(id.document == widget.documentKey &&
                  (id.number - widget.pageNumber).abs() <= 1),
        )
        .toList();
    for (final id in remove) {
      _surfaces.remove(id)!.dispose();
    }
  }

  void _ready(_PageId id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_surfaces.containsKey(id)) return;
      setState(() {
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

  void _tryPresent() {
    if (widget.holdPresentation ||
        _incoming != null ||
        !(_surfaces[_requested]?.ready ?? false)) {
      return;
    }
    if (_displayed == _requested) {
      if (!_initialPresented) {
        _initialPresented = true;
        _notifyPresented();
      }
      return;
    }
    _direction = _requested.document == _displayed.document
        ? (_requested.number > _displayed.number ? 1 : -1)
        : widget.direction;
    _incoming = _requested;
    if (MediaQuery.disableAnimationsOf(context)) {
      _complete();
    } else {
      _animation.forward(from: 0);
    }
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
    if (status == AnimationStatus.completed && mounted) setState(_complete);
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
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Material(
                    color: const Color(0xffffedcf),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              _surfaces[_requested]!.error!,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              final s = _surfaces[_requested]!;
                              s.error = null;
                              s.ready = false;
                              s.retry++;
                            }),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
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
