import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'reader_spreads.dart';
import 'reader_stage.dart';

/// The formal desktop reader has one compact bar. Pinning it reserves space;
/// edge-hover only overlays it, so hovering never changes the paper's fit.
class DesktopReaderShell extends StatefulWidget {
  const DesktopReaderShell({
    super.key,
    required this.title,
    required this.pageLabel,
    required this.mode,
    required this.arrangement,
    required this.onMode,
    required this.onArrangement,
    required this.onPrevious,
    required this.onNext,
    required this.onBack,
    required this.onZoom,
    required this.onFit,
    required this.onJump,
    required this.contentBuilder,
    this.onAnnotate,
    this.onFinishEditing,
    this.editing = false,
    this.writing = false,
    this.annotationTools,
    this.bottom = const SizedBox.shrink(),
    this.notices = const [],
    this.statusLabel = '阅读状态',
    this.loading = false,
  });
  final String title, pageLabel, statusLabel;
  final bool editing, writing, loading;
  final ReaderViewMode mode;
  final FirstPageArrangement arrangement;
  final ValueChanged<ReaderViewMode> onMode;
  final ValueChanged<FirstPageArrangement> onArrangement;
  final VoidCallback onPrevious, onNext, onBack, onFit, onJump;
  final ValueChanged<double> onZoom;
  final VoidCallback? onAnnotate, onFinishEditing;
  final Widget? annotationTools;
  final Widget bottom;
  final List<Widget> notices;
  final Widget Function(VoidCallback toggleBar) contentBuilder;
  @override
  State<DesktopReaderShell> createState() => _DesktopReaderShellState();
}

class _DesktopReaderShellState extends State<DesktopReaderShell>
    with TickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 200),
  );
  late final AnimationController _hoverAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final Listenable _animations = Listenable.merge([
    _animation,
    _hoverAnimation,
  ]);
  final _barKey = GlobalKey();
  bool _pinned = true, _hover = false, _menu = false, _measureScheduled = false;
  double _height = 56;
  void _pin(bool value) {
    if (value == _pinned) return;
    setState(() {
      _pinned = value;
      if (!value) {
        _hover = false;
        _menu = false;
      }
    });
    if (!value) _hoverAnimation.reverse();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = value ? 1 : 0;
    } else {
      value ? _animation.forward() : _animation.reverse();
    }
  }

  void _overlayChanged({bool? hover, bool? menu}) {
    if (!mounted) return;
    setState(() {
      if (hover != null) _hover = hover;
      if (menu != null) _menu = menu;
    });
    final show = _hover || _menu || widget.editing;
    if (MediaQuery.disableAnimationsOf(context)) {
      _hoverAnimation.value = show ? 1 : 0;
    } else {
      show ? _hoverAnimation.forward() : _hoverAnimation.reverse();
    }
  }

  void _toggle() {
    if (!widget.editing && !widget.writing) _pin(!_pinned);
  }

  @override
  void didUpdateWidget(covariant DesktopReaderShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing && !oldWidget.editing) {
      _pinned = true;
      _animation.forward();
    }
    _measure();
  }

  void _measure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null &&
          box.hasSize &&
          (_height - box.size.height).abs() > .5) {
        setState(() => _height = box.size.height);
      }
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    _hoverAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    final overlay = _hover || _menu || widget.editing;
    final bar = MouseRegion(
      onEnter: (_) => _overlayChanged(hover: true),
      onExit: (_) => _overlayChanged(hover: false),
      child: Material(
        key: _barKey,
        color: const Color(0xfffafafa),
        elevation: 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _toolbar(context),
            if (widget.editing && widget.annotationTools != null)
              widget.annotationTools!,
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _animations,
      child: widget.contentBuilder(_toggle),
      builder: (context, child) {
        final progress = Curves.easeOutCubic.transform(_animation.value);
        final presence = math.max(
          progress,
          Curves.easeOutCubic.transform(_hoverAnimation.value),
        );
        final visible = presence > .001;
        return Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                SizedBox(height: _height * progress),
                Expanded(child: child!),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 7,
              child: MouseRegion(
                key: const ValueKey('desktop-reader-hover-edge'),
                onEnter: (_) => _overlayChanged(hover: true),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_pinned && !overlay,
                child: ExcludeFocus(
                  excluding: !_pinned && !overlay,
                  child: Opacity(
                    opacity: presence,
                    child: Transform.translate(
                      offset: Offset(0, -_height * (1 - presence)),
                      child: bar,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.notices.isNotEmpty)
              Positioned(
                top: visible ? _height + 8 : 8,
                right: 8,
                child: ReaderStatusButton(
                  label: widget.statusLabel,
                  details: widget.notices,
                ),
              ),
            if (widget.loading)
              const Positioned(
                right: 18,
                bottom: 18,
                child: IgnorePointer(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            if (_pinned || overlay)
              Positioned(left: 0, right: 0, bottom: 18, child: widget.bottom),
          ],
        );
      },
    );
  }

  Widget _toolbar(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final labels = constraints.maxWidth >= 1000;
      Widget icon(IconData icon, String tooltip, VoidCallback action) =>
          IconButton(
            tooltip: tooltip,
            onPressed: widget.writing ? null : action,
            icon: Icon(icon, size: 21),
          );
      return SizedBox(
        key: const ValueKey('desktop-reader-toolbar'),
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 8),
            icon(Icons.arrow_back, '返回目录', widget.onBack),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            icon(Icons.chevron_left, '上一页', widget.onPrevious),
            TextButton(
              onPressed: widget.writing ? null : widget.onJump,
              child: Text(widget.pageLabel),
            ),
            icon(Icons.chevron_right, '下一页', widget.onNext),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '单页',
              isSelected: widget.mode == ReaderViewMode.single,
              onPressed: widget.writing || widget.editing
                  ? null
                  : () => widget.onMode(ReaderViewMode.single),
              icon: const Icon(Icons.description_outlined),
            ),
            if (labels) const Text('单页', style: TextStyle(fontSize: 13)),
            IconButton(
              tooltip: '双页',
              isSelected: widget.mode == ReaderViewMode.spread,
              onPressed: widget.writing || widget.editing
                  ? null
                  : () => widget.onMode(ReaderViewMode.spread),
              icon: const Icon(Icons.menu_book_outlined),
            ),
            if (labels) const Text('双页', style: TextStyle(fontSize: 13)),
            PopupMenuButton<FirstPageArrangement>(
              tooltip: '双页排列',
              enabled: !widget.writing && !widget.editing,
              onOpened: () => _overlayChanged(menu: true),
              onCanceled: () => _overlayChanged(menu: false),
              onSelected: (value) {
                _overlayChanged(menu: false);
                widget.onArrangement(value);
              },
              icon: const Icon(Icons.arrow_drop_down, size: 19),
              itemBuilder: (_) => [
                for (final value in FirstPageArrangement.values)
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        Icon(
                          widget.arrangement == value
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 19,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          value == FirstPageArrangement.alone
                              ? '第一页单独'
                              : '第1、2页并排',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '连续',
              isSelected: widget.mode == ReaderViewMode.continuous,
              onPressed: widget.writing || widget.editing
                  ? null
                  : () => widget.onMode(ReaderViewMode.continuous),
              icon: const Icon(Icons.view_agenda_outlined),
            ),
            if (labels) const Text('连续', style: TextStyle(fontSize: 13)),
            icon(Icons.remove, '缩小', () => widget.onZoom(1 / 1.25)),
            icon(Icons.fit_screen, '恢复整页', widget.onFit),
            icon(Icons.add, '放大', () => widget.onZoom(1.25)),
            if (widget.onAnnotate != null) ...[
              const SizedBox(width: 8),
              if (labels)
                OutlinedButton.icon(
                  onPressed: widget.writing ? null : widget.onAnnotate,
                  icon: Icon(
                    widget.editing ? Icons.check : Icons.edit_outlined,
                    size: 18,
                  ),
                  label: Text(widget.editing ? '完成' : '批注'),
                )
              else
                icon(
                  widget.editing ? Icons.check : Icons.edit_outlined,
                  widget.editing ? '完成批注' : '批注',
                  widget.onAnnotate!,
                ),
            ],
            icon(Icons.keyboard_arrow_up, '收起工具栏', () {
              widget.onFinishEditing?.call();
              _pin(false);
            }),
            const SizedBox(width: 8),
          ],
        ),
      );
    },
  );
}

/// A spread has one readiness boundary, while each real page retains its own
/// paint/annotation identity. A lone front/tail page keeps the pair's fit scale.
class ReaderSpreadSurface extends StatefulWidget {
  const ReaderSpreadSurface({
    super.key,
    required this.spread,
    required this.aspectFor,
    required this.pageBuilder,
    required this.onReady,
    required this.onError,
  });
  final ReaderSpread spread;
  final double Function(int) aspectFor;
  final Widget Function(int, VoidCallback, ValueChanged<String?>) pageBuilder;
  final VoidCallback onReady;
  final ValueChanged<String?> onError;
  @override
  State<ReaderSpreadSurface> createState() => _ReaderSpreadSurfaceState();
}

class _ReaderSpreadSurfaceState extends State<ReaderSpreadSurface> {
  final _ready = <int>{};
  void _rendered(int number) {
    _ready.add(number);
    if (widget.spread.pages.every(_ready.contains)) widget.onReady();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final number in widget.spread.pages) ...[
          if (number != widget.spread.first)
            SizedBox(width: constraints.maxHeight * .025),
          SizedBox(
            width: constraints.maxHeight * widget.aspectFor(number),
            height: constraints.maxHeight,
            child: ColoredBox(
              color: Colors.white,
              child: widget.pageBuilder(
                number,
                () => _rendered(number),
                widget.onError,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
