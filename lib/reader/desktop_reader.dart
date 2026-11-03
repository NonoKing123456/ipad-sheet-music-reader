import 'dart:math' as math;

import '../theme/tokens.dart';

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
    this.onMenuChanged,
    this.onFinishEditing,
    this.beforeHideTools,
    this.editing = false,
    this.writing = false,
    this.textEditing = false,
    this.annotationTools,
    this.actions = const [],
    this.primaryActions = const [],
    this.bottom = const SizedBox.shrink(),
    this.notices = const [],
    this.statusLabel = '阅读状态',
    this.loading = false,
  });
  final String title, pageLabel, statusLabel;
  final bool editing, writing, loading, textEditing;
  final ReaderViewMode mode;
  final FirstPageArrangement arrangement;
  final ValueChanged<ReaderViewMode> onMode;
  final ValueChanged<FirstPageArrangement> onArrangement;
  final VoidCallback onPrevious, onNext, onBack, onFit, onJump;
  final ValueChanged<double> onZoom;
  final VoidCallback? onAnnotate, onFinishEditing;
  final Future<bool> Function()? beforeHideTools;
  final ValueChanged<bool>? onMenuChanged;
  final Widget? annotationTools;
  final List<Widget> actions;
  final List<Widget> primaryActions;
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
  late final AnimationController _annotationRowAnimation = AnimationController(
    vsync: this,
    value: widget.editing && widget.annotationTools != null ? 1 : 0,
    duration: const Duration(milliseconds: 200),
  );
  late final Listenable _animations = Listenable.merge([
    _animation,
    _hoverAnimation,
    _annotationRowAnimation,
  ]);
  final _arrangementMenu = MenuController();
  final _arrangementFocus = FocusNode(debugLabel: 'spread arrangement');
  final _annotationFocus = FocusNode(debugLabel: 'annotation');
  final _toolbarScroll = ScrollController();
  bool _pinned = true, _hover = false, _menu = false, _toolbarOverflow = false;
  static const double _mainBarHeight = 56, _annotationRowHeight = 52;
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
    if (menu != null) widget.onMenuChanged?.call(menu);
    final show = _hover || _menu || widget.editing;
    if (MediaQuery.disableAnimationsOf(context)) {
      _hoverAnimation.value = show ? 1 : 0;
    } else {
      show ? _hoverAnimation.forward() : _hoverAnimation.reverse();
    }
  }

  Future<void> _toggle() async {
    if (widget.writing) return;
    if (_pinned &&
        widget.beforeHideTools != null &&
        !await widget.beforeHideTools!()) {
      return;
    }
    if (mounted) _pin(!_pinned);
  }

  @override
  void didUpdateWidget(covariant DesktopReaderShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing && !oldWidget.editing) {
      _pinned = true;
      _animation.forward();
    }
    final hadAnnotationRow =
        oldWidget.editing && oldWidget.annotationTools != null;
    final hasAnnotationRow = widget.editing && widget.annotationTools != null;
    if (!hadAnnotationRow && hasAnnotationRow) {
      _annotationRowAnimation.forward();
    } else if (hadAnnotationRow && !hasAnnotationRow) {
      _annotationRowAnimation.reverse();
    }
    if (oldWidget.mode == ReaderViewMode.spread &&
        widget.mode != ReaderViewMode.spread &&
        _arrangementMenu.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _arrangementMenu.close();
      });
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _hoverAnimation.dispose();
    _annotationRowAnimation.dispose();
    _arrangementFocus.dispose();
    _annotationFocus.dispose();
    _toolbarScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _hover || _menu || widget.editing;
    final bar = AnimatedBuilder(
      animation: _annotationRowAnimation,
      builder: (context, _) {
        final rowProgress = _annotationRowAnimation.value;
        final keepAnnotationSlot = widget.editing || rowProgress > 0;
        return MouseRegion(
          onEnter: (_) => _overlayChanged(hover: true),
          onExit: (_) => _overlayChanged(hover: false),
          child: Material(
            key: const ValueKey('desktop-reader-toolbar'),
            color: Theme.of(context).colorScheme.surface,
            elevation: 1,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _toolbar(context),
                if (keepAnnotationSlot)
                  IgnorePointer(
                    ignoring: !widget.editing,
                    child: ExcludeFocus(
                      excluding: !widget.editing,
                      child: ExcludeSemantics(
                        excluding: !widget.editing,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            heightFactor: rowProgress,
                            child: SizedBox(
                              height: _annotationRowHeight,
                              child:
                                  widget.annotationTools ??
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
        final barHeight =
            _mainBarHeight +
            _annotationRowHeight * _annotationRowAnimation.value;
        final paperTop = barHeight * progress;
        return Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                SizedBox(height: paperTop),
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
                      offset: Offset(0, -barHeight * (1 - presence)),
                      child: bar,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.notices.isNotEmpty)
              Positioned(
                top: paperTop + 8,
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
            Positioned(left: 0, right: 0, bottom: 18, child: widget.bottom),
          ],
        );
      },
    );
  }

  Widget _group(BuildContext context, List<Widget> children) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: ScoreTokens.of(context).ink500),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  Widget _toolbar(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final disabled = widget.writing;
      final navigation = _group(context, [
        _ReaderBarButton(
          icon: Icons.chevron_left,
          tooltip: '上一页',
          onPressed: disabled ? null : widget.onPrevious,
        ),
        _ReaderBarButton(
          icon: Icons.chevron_right,
          tooltip: '下一页',
          onPressed: disabled ? null : widget.onNext,
        ),
      ]);
      final modes = SegmentedButton<ReaderViewMode>(
        segments: const [
          ButtonSegment(
            value: ReaderViewMode.single,
            icon: Icon(Icons.description_outlined, size: 18),
            label: Text('单页'),
          ),
          ButtonSegment(
            value: ReaderViewMode.spread,
            icon: Icon(Icons.menu_book_outlined, size: 18),
            label: Text('双页'),
          ),
          ButtonSegment(
            value: ReaderViewMode.continuous,
            icon: Icon(Icons.view_agenda_outlined, size: 18),
            label: Text('连续'),
          ),
        ],
        selected: {widget.mode},
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(76, 44),
          visualDensity: VisualDensity.standard,
          textStyle: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontSize: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onSelectionChanged: disabled || widget.editing
            ? null
            : (values) => widget.onMode(values.single),
      );
      final arrangement = MenuAnchor(
        controller: _arrangementMenu,
        childFocusNode: _arrangementFocus,
        reservedPadding: const EdgeInsets.all(12),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            Theme.of(context).colorScheme.surface,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(
            BorderSide(color: ScoreTokens.of(context).ink500),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          elevation: const WidgetStatePropertyAll(6),
          shadowColor: const WidgetStatePropertyAll(Color(0x24000000)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        ),
        consumeOutsideTap: true,
        alignmentOffset: const Offset(0, 8),
        onOpen: () => _overlayChanged(menu: true),
        onClose: () => _overlayChanged(menu: false),
        menuChildren: [
          for (final value in FirstPageArrangement.values)
            MenuItemButton(
              onPressed: () {
                _arrangementMenu.close();
                widget.onArrangement(value);
              },
              leadingIcon: Icon(
                value == FirstPageArrangement.alone
                    ? Icons.first_page
                    : Icons.menu_book_outlined,
                size: 20,
              ),
              trailingIcon: widget.arrangement == value
                  ? const Icon(Icons.check, size: 18)
                  : null,
              child: Text(
                value == FirstPageArrangement.alone ? '首页独立' : '首页并排',
              ),
            ),
        ],
        builder: (context, controller, _) => _ReaderBarButton(
          label: widget.arrangement == FirstPageArrangement.alone
              ? (widget.mode == ReaderViewMode.spread ? '首页独立' : '双页排列')
              : (widget.mode == ReaderViewMode.spread ? '首页并排' : '双页排列'),
          icon: Icons.expand_more,
          trailingIcon: true,
          tooltip: '双页排列',
          focusNode: _arrangementFocus,
          onPressed:
              disabled || widget.editing || widget.mode != ReaderViewMode.spread
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
        ),
      );
      final annotate = _ReaderBarButton(
        icon: widget.editing ? Icons.check : Icons.edit_outlined,
        label: widget.editing ? '完成' : '批注',
        focusNode: _annotationFocus,
        tooltip: widget.editing ? '完成批注' : '批注',
        filled: true,
        onPressed: disabled ? null : widget.onAnnotate,
      );
      final back = _ReaderBarButton(
        icon: Icons.arrow_back,
        tooltip: '返回目录',
        onPressed: widget.writing ? null : widget.onBack,
      );
      final collapse = _ReaderBarButton(
        icon: Icons.keyboard_arrow_up,
        tooltip: '收起工具栏',
        onPressed: widget.writing || widget.textEditing
            ? null
            : () async {
                _arrangementMenu.close();
                if (widget.beforeHideTools != null &&
                    !await widget.beforeHideTools!()) {
                  return;
                }
                if (mounted) _pin(false);
              },
      );
      final title = Text(
        widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      );
      final viewControls = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          modes,
          const SizedBox(width: 8),
          SizedBox(width: 128, child: arrangement),
        ],
      );
      final readingControls = <Widget>[
        navigation,
        const SizedBox(width: 10),
        viewControls,
      ];
      final documentActions = <Widget>[
        ...widget.primaryActions,
        if (widget.primaryActions.isNotEmpty) const SizedBox(width: 8),
        if (widget.onAnnotate != null) annotate,
        const SizedBox(width: 4),
        collapse,
        if (widget.actions.isNotEmpty) ...[
          const SizedBox(width: 8),
          ...widget.actions,
        ],
      ];
      final titleWidth = constraints.maxWidth < 1200
          ? math.min(120.0, math.max(88.0, (constraints.maxWidth - 200) * .22))
          : math.min(280.0, 120 + (constraints.maxWidth - 1200) * .3);
      Widget scrollControls(List<Widget> children) =>
          NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              final overflow = notification.metrics.maxScrollExtent > 1;
              if (_toolbarOverflow != overflow) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _toolbarOverflow != overflow) {
                    setState(() => _toolbarOverflow = overflow);
                  }
                });
              }
              return false;
            },
            child: Scrollbar(
              controller: _toolbarScroll,
              thumbVisibility: _toolbarOverflow,
              child: SingleChildScrollView(
                key: const ValueKey('desktop-toolbar-scroll'),
                controller: _toolbarScroll,
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
          );
      final leading = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          back,
          const SizedBox(width: 8),
          SizedBox(width: titleWidth, child: title),
        ],
      );
      return SizedBox(
        key: const ValueKey('desktop-reader-main-row'),
        height: _mainBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: constraints.maxWidth >= 1000
              ? NavigationToolbar(
                  leading: leading,
                  middle: scrollControls(readingControls),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: documentActions,
                  ),
                  centerMiddle: true,
                  middleSpacing: 16,
                )
              : Row(
                  children: [
                    leading,
                    const SizedBox(width: 8),
                    Expanded(
                      child: scrollControls([
                        ...readingControls,
                        const SizedBox(width: 10),
                        ...documentActions,
                      ]),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

class _ReaderBarButton extends StatelessWidget {
  const _ReaderBarButton({
    this.icon,
    this.label,
    required this.tooltip,
    this.onPressed,
    this.filled = false,
    this.trailingIcon = false,
    this.focusNode,
  });
  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled, trailingIcon;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final contents = <Widget>[
      if (icon != null && !trailingIcon) Icon(icon, size: 19),
      if (icon != null && label != null && !trailingIcon)
        const SizedBox(width: 6),
      if (label != null)
        Flexible(
          fit: FlexFit.loose,
          child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      if (icon != null && trailingIcon) ...[
        const SizedBox(width: 5),
        Icon(icon, size: 18),
      ],
    ];
    final style = TextButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 10 : 12),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
    return Tooltip(
      message: tooltip,
      child: filled
          ? FilledButton.tonal(
              focusNode: focusNode,
              onPressed: onPressed,
              style: style,
              child: Row(mainAxisSize: MainAxisSize.min, children: contents),
            )
          : TextButton(
              focusNode: focusNode,
              onPressed: onPressed,
              style: style,
              child: Row(mainAxisSize: MainAxisSize.min, children: contents),
            ),
    );
  }
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
