import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../theme/reader_icons.dart';
import 'reader_spreads.dart';
import 'reader_stage.dart';
import 'reader_tool_button.dart';

/// Reading and annotation rows reserve only their visible height.
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
    this.documentMenu = const [],
    this.bottom = const SizedBox.shrink(),
    this.notices = const [],
    this.statusLabel = '阅读状态',
    this.loading = false,
    this.onObstructionChanged,
    this.fitAspectFor,
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
  final ValueChanged<EdgeInsets>? onObstructionChanged;
  final double Function(Size viewport)? fitAspectFor;
  final Widget? annotationTools;
  final List<Widget> actions, primaryActions, notices, documentMenu;
  final Widget bottom;
  final Widget Function(VoidCallback toggleBar) contentBuilder;
  @override
  State<DesktopReaderShell> createState() => _DesktopReaderShellState();
}

class _DesktopReaderShellState extends State<DesktopReaderShell>
    with SingleTickerProviderStateMixin {
  bool _shown = true, _reserveBar = true;
  final _topKey = GlobalKey();
  final _arrangementMenu = MenuController();
  final _readingControls = ScrollController();
  EdgeInsets? _lastObstruction;
  bool _measuring = false;
  double _barHeight = ScoreLayout.readerHeaderHeight;
  late final AnimationController _animation =
      AnimationController(vsync: this, value: 1, duration: ScoreMotion.panel)
        ..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && _reserveBar) {
            setState(() => _reserveBar = false);
          }
        });
  Future<void> _toggle() async {
    if (widget.writing) return;
    if (_shown &&
        widget.beforeHideTools != null &&
        !await widget.beforeHideTools!()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _shown = !_shown;
      if (_shown) _reserveBar = true;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = _shown ? 1 : 0;
    } else {
      _shown ? _animation.forward() : _animation.reverse();
    }
  }

  @override
  void didUpdateWidget(covariant DesktopReaderShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing && !oldWidget.editing && !_shown) {
      _shown = _reserveBar = true;
      _animation.forward();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _readingControls.dispose();
    super.dispose();
  }

  void _measure() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      // The native content viewport is now below the toolbar, so no extra
      // global-top obstruction is attached to its local pan coordinates.
      const insets = EdgeInsets.zero;
      final box = _topKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.size.height != _barHeight) {
        setState(() => _barHeight = box.size.height);
      }
      if (insets != _lastObstruction) {
        _lastObstruction = insets;
        widget.onObstructionChanged?.call(insets);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _measure();
    final bar = Material(
      key: _topKey,
      color: ScoreTokens.of(context).paper0,
      child: Column(
        key: const ValueKey('desktop-reader-chrome'),
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolbar(context),
          if (widget.editing && widget.annotationTools != null)
            widget.annotationTools!,
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              ClipRect(
                child: Align(
                  heightFactor: _reserveBar ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_shown,
                    child: ExcludeFocus(
                      excluding: !_shown,
                      child: ExcludeSemantics(
                        excluding: !_shown,
                        child: AnimatedBuilder(
                          animation: _animation,
                          child: bar,
                          builder: (context, child) {
                            final progress = Curves.easeOutCubic.transform(
                              _animation.value,
                            );
                            return Opacity(
                              opacity: progress,
                              child: Transform.translate(
                                offset: Offset(
                                  0,
                                  -ScoreSpace.sm * (1 - progress),
                                ),
                                child: child,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, available) => ReaderChromeViewport(
                    key: const ValueKey('desktop-reader-content-inset'),
                    topInset: constraints.maxHeight - available.maxHeight,
                    fitAspectFor: widget.fitAspectFor,
                    child: widget.contentBuilder(_toggle),
                  ),
                ),
              ),
            ],
          ),
          if (widget.notices.isNotEmpty)
            Positioned(
              top: (_shown ? _barHeight : 0) + ScoreSpace.sm,
              right: ScoreSpace.sm,
              child: ReaderStatusButton(
                label: widget.statusLabel,
                details: widget.notices,
              ),
            ),
          if (widget.loading)
            const Positioned(
              right: ScoreLayout.readerStatusInset,
              bottom: ScoreLayout.readerStatusInset,
              child: IgnorePointer(
                child: SizedBox.square(
                  dimension: ScoreLayout.readerStatusIndicatorSize,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: ScoreLayout.dotsBottom,
            child: IgnorePointer(
              ignoring: !_shown,
              child: ExcludeSemantics(
                excluding: !_shown,
                child: FadeTransition(
                  opacity: _animation,
                  child: widget.bottom,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final t = ScoreTokens.of(context);
      final disabled = widget.writing;
      final modes = DecoratedBox(
        decoration: BoxDecoration(
          color: t.paper2,
          borderRadius: ScoreRadius.cardAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ScoreSpace.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in ReaderViewMode.values) ...[
                if (mode != ReaderViewMode.values.first)
                  const SizedBox(width: ScoreSpace.xs),
                SizedBox(
                  height: ScoreLayout.desktopTarget,
                  child: TextButton(
                    onPressed: disabled || widget.editing
                        ? null
                        : () => widget.onMode(mode),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: ScoreSpace.md,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      splashFactory: NoSplash.splashFactory,
                      backgroundColor: widget.mode == mode
                          ? t.paper0
                          : Colors.transparent,
                      foregroundColor: widget.mode == mode
                          ? t.ink900
                          : t.ink500,
                      textStyle: Theme.of(context).textTheme.labelLarge,
                      shape: const RoundedRectangleBorder(
                        borderRadius: ScoreRadius.controlAll,
                      ),
                    ),
                    child: Text(switch (mode) {
                      ReaderViewMode.single => '单页',
                      ReaderViewMode.spread => '双页',
                      ReaderViewMode.continuous => '连续',
                    }),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      final arrangementLabel = widget.arrangement == FirstPageArrangement.alone
          ? '首页单独'
          : '1、2页并排';
      final arrangement = MenuAnchor(
        controller: _arrangementMenu,
        onOpen: () => widget.onMenuChanged?.call(true),
        onClose: () => widget.onMenuChanged?.call(false),
        style: const MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(ScoreLayout.menuWidth, 0)),
        ),
        menuChildren: [
          for (final value in FirstPageArrangement.values)
            MenuItemButton(
              key: ValueKey(('reader-arrangement-option', value)),
              onPressed: disabled || widget.editing
                  ? null
                  : () {
                      _arrangementMenu.close();
                      widget.onArrangement(value);
                    },
              trailingIcon: value == widget.arrangement
                  ? const Icon(Icons.check, size: ScoreLayout.iconVisual)
                  : null,
              child: Text(
                value == FirstPageArrangement.alone ? '首页单独' : '1、2页并排',
              ),
            ),
        ],
        builder: (context, controller, _) => Tooltip(
          message: '双页排列：$arrangementLabel',
          child: SizedBox(
            height: ScoreLayout.desktopTarget,
            child: TextButton(
              key: const ValueKey('reader-arrangement-button'),
              onPressed: disabled || widget.editing
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.md),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: Theme.of(context).textTheme.labelLarge,
                foregroundColor: t.pineDeep,
                backgroundColor: t.pineWash,
                splashFactory: NoSplash.splashFactory,
                shape: const RoundedRectangleBorder(
                  borderRadius: ScoreRadius.controlAll,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(arrangementLabel),
                  const SizedBox(width: ScoreSpace.xs),
                  const ReaderIcon(
                    ReaderGlyph.chevronDown,
                    size: ScoreLayout.readerTitleChevron,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final stacked = constraints.maxWidth < ScoreLayout.windowsSidebarMin;
      final showAnnotationCaption =
          constraints.maxWidth >= ScoreLayout.windowsSidebarMin;
      final actions = <Widget>[
        TextButton(
          onPressed: disabled ? null : widget.onJump,
          style: TextButton.styleFrom(
            foregroundColor: t.ink500,
            minimumSize: const Size(0, ScoreLayout.desktopTarget),
            padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
            textStyle: Theme.of(context).textTheme.labelLarge,
            splashFactory: NoSplash.splashFactory,
          ),
          child: Text(widget.pageLabel),
        ),
        if (widget.onAnnotate != null)
          ReaderActionButton(
            label: widget.editing ? '完成批注' : '批注',
            caption: showAnnotationCaption
                ? (widget.editing ? '完成批注' : '批注')
                : null,
            icon: const ReaderIcon(
              ReaderGlyph.pen,
              size: ScoreLayout.iconVisual,
            ),
            onPressed: disabled ? null : widget.onAnnotate,
            selected: widget.editing,
            target: ScoreLayout.desktopTarget,
            width: !showAnnotationCaption
                ? ScoreLayout.desktopTarget
                : widget.editing
                ? ScoreLayout.readerAnnotationDoneButtonWidth
                : ScoreLayout.readerAnnotationButtonWidth,
          ),
        ...widget.primaryActions,
        ...widget.actions,
      ];
      double textWidth(String text) => (TextPainter(
        text: TextSpan(
          text: text,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout()).width;
      final modeWidth =
          ['单页', '双页', '连续'].map(textWidth).fold<double>(0, (a, b) => a + b) +
          6 * ScoreSpace.md +
          4 * ScoreSpace.xs;
      final arrangementWidth = widget.mode != ReaderViewMode.spread
          ? 0.0
          : ScoreSpace.sm +
                textWidth(arrangementLabel) +
                2 * ScoreSpace.md +
                ScoreSpace.xs +
                ScoreLayout.readerTitleChevron;
      final actionWidth =
          textWidth(widget.pageLabel) +
          2 * ScoreSpace.sm +
          (widget.onAnnotate == null
              ? 0
              : !showAnnotationCaption
              ? ScoreLayout.desktopTarget
              : widget.editing
              ? ScoreLayout.readerAnnotationDoneButtonWidth
              : ScoreLayout.readerAnnotationButtonWidth) +
          (widget.primaryActions.length + widget.actions.length) *
              ScoreLayout.desktopTarget +
          (actions.length - 1) * ScoreSpace.xs;
      final titleWidth = math.min(
        ScoreLayout.readerTitleMaxWidth,
        math.max(
          0.0,
          constraints.maxWidth -
              2 * ScoreSpace.lg -
              ScoreLayout.desktopTarget -
              2 * ScoreSpace.sm -
              (stacked ? 0 : modeWidth + arrangementWidth) -
              actionWidth,
        ),
      );
      final viewControls = SingleChildScrollView(
        key: const ValueKey('reader-view-controls'),
        controller: _readingControls,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            modes,
            if (widget.mode == ReaderViewMode.spread) ...[
              const SizedBox(width: ScoreSpace.sm),
              arrangement,
            ],
          ],
        ),
      );
      final heading = Container(
        key: const ValueKey('desktop-reader-main-row'),
        height: ScoreLayout.readerHeaderHeight,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.hair2)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
        child: Row(
          children: [
            ReaderActionButton(
              label: '返回曲库',
              icon: const ReaderIcon(
                ReaderGlyph.back,
                size: ScoreLayout.iconVisual,
              ),
              target: ScoreLayout.desktopTarget,
              onPressed: disabled ? null : widget.onBack,
            ),
            const SizedBox(width: ScoreSpace.sm),
            if (titleWidth >= ScoreSpace.xxl)
              SizedBox(
                width: titleWidth,
                child: MenuAnchor(
                  style: const MenuStyle(
                    minimumSize: WidgetStatePropertyAll(
                      Size(ScoreLayout.menuWidth, 0),
                    ),
                  ),
                  menuChildren: widget.documentMenu,
                  onOpen: () => widget.onMenuChanged?.call(true),
                  onClose: () => widget.onMenuChanged?.call(false),
                  builder: (context, controller, _) => Semantics(
                    button: true,
                    label: '${widget.title}，曲谱操作',
                    child: Tooltip(
                      message: widget.title,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: disabled || widget.documentMenu.isEmpty
                            ? null
                            : () => controller.isOpen
                                  ? controller.close()
                                  : controller.open(),
                        child: SizedBox(
                          key: const ValueKey('reader-title-menu'),
                          height: ScoreLayout.readerTitleMenuHitHeight,
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: t.ink900,
                                        fontWeight: FontWeight.w500,
                                      ),
                                ),
                              ),
                              const SizedBox(width: ScoreSpace.xs),
                              const ReaderIcon(
                                ReaderGlyph.chevronDown,
                                size: ScoreLayout.readerTitleChevron,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: ScoreSpace.sm),
            if (stacked) const Spacer() else Expanded(child: viewControls),
            for (var i = 0; i < actions.length; i++) ...[
              if (i != 0) const SizedBox(width: ScoreSpace.xs),
              actions[i],
            ],
          ],
        ),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          heading,
          if (stacked)
            SizedBox(
              height: ScoreLayout.readerHeaderHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: viewControls,
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Aspect presented to the existing page window, including a fixed 16dp gap.
/// Lone first/tail sheets retain the pair's original reserved fit width.
double readerSpreadAspect(
  Size viewport,
  ReaderSpread spread,
  double Function(int) aspectFor,
) {
  final sum = aspectFor(spread.first) + aspectFor(spread.last);
  final height = math.min(
    viewport.height,
    math.max(0.0, viewport.width - ScoreLayout.spreadGap) / sum,
  );
  return height <= 0 ? sum : sum + ScoreLayout.spreadGap / height;
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
    builder: (context, constraints) {
      final pages = widget.spread.pages.toList();
      final aspects = pages.map(widget.aspectFor).toList();
      final sum = aspects.fold<double>(0, (a, b) => a + b);
      final gap = pages.length > 1 ? ScoreLayout.spreadGap : 0.0;
      final height = math.min(
        constraints.maxHeight,
        math.max(0.0, constraints.maxWidth - gap) / sum,
      );
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < pages.length; i++) ...[
              if (i != 0) const SizedBox(width: ScoreLayout.spreadGap),
              SizedBox(
                width: height * aspects[i],
                height: height,
                child: ColoredBox(
                  color: Colors.white,
                  child: widget.pageBuilder(
                    pages[i],
                    () => _rendered(pages[i]),
                    widget.onError,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
