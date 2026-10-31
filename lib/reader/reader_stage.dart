import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get isMobileReader =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;
bool get canPreviewReader => defaultTargetPlatform == TargetPlatform.windows;

/// Controls float above the unchanged full viewport. They never resize paper.
class ReaderStage extends StatefulWidget {
  const ReaderStage({
    super.key,
    required this.contentBuilder,
    required this.top,
    required this.bottom,
    this.notices = const [],
    this.drawing = false,
    this.onViewportChanged,
    this.onPrevious,
    this.onNext,
    this.allowOverlayPageKeys = false,
    this.onObstructionChanged,
    this.onToolsVisibilityChanged,
    this.hasReadablePage = false,
    this.statusLabel = '阅读状态',
    this.loading = false,
  });
  final Widget Function(VoidCallback toggleTools) contentBuilder;
  final Widget top, bottom;
  final List<Widget> notices;
  final bool drawing;
  final VoidCallback? onViewportChanged;
  final VoidCallback? onPrevious, onNext;
  final bool allowOverlayPageKeys;
  final ValueChanged<EdgeInsets>? onObstructionChanged;
  final ValueChanged<bool>? onToolsVisibilityChanged;
  final bool hasReadablePage, loading;
  final String statusLabel;
  @override
  State<ReaderStage> createState() => _ReaderStageState();
}

class _ReaderStageState extends State<ReaderStage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late bool _tools = !isMobileReader;
  Size? _viewport;
  final _topKey = GlobalKey(), _bottomKey = GlobalKey();
  EdgeInsets? _reportedObstruction;
  bool _measurementScheduled = false;
  late final AnimationController _animation;
  late final Animation<double> _curve;
  bool _reduceMotion = false;
  void _toggle() => _show(!_tools);
  void _show(bool show) {
    setState(() => _tools = show);
    widget.onToolsVisibilityChanged?.call(show);
    if (_reduceMotion) {
      _animation.value = show ? 1 : 0;
    } else {
      show ? _animation.forward() : _animation.reverse();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _animation.value = _tools ? 1 : 0;
  }

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: _tools ? 1 : 0,
    );
    _curve = CurvedAnimation(
      parent: _animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_pageKey);
    _immerse();
  }

  KeyEventResult _pageKey(KeyEvent event) {
    if (!mounted ||
        (!(ModalRoute.of(context)?.isCurrent ?? true) &&
            !widget.allowOverlayPageKeys)) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.widget is EditableText ||
        focus?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final action = event.logicalKey == LogicalKeyboardKey.pageDown
        ? widget.onNext
        : event.logicalKey == LogicalKeyboardKey.pageUp
        ? widget.onPrevious
        : null;
    if (action == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) action();
    return KeyEventResult.handled;
  }

  void _immerse() {
    if (isMobileReader) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          defaultTargetPlatform == TargetPlatform.iOS
              ? SystemUiMode.manual
              : SystemUiMode.immersiveSticky,
          overlays: const [],
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _immerse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_pageKey);
    _animation.dispose();
    if (isMobileReader) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        ),
      );
    }
    super.dispose();
  }

  void _measureObstruction() {
    if (widget.onObstructionChanged == null || _measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final top = _topKey.currentContext?.findRenderObject() as RenderBox?;
      final bottom =
          _bottomKey.currentContext?.findRenderObject() as RenderBox?;
      final value = EdgeInsets.only(
        top: top?.size.height ?? 0,
        bottom: bottom?.size.height ?? 0,
      );
      if (value != _reportedObstruction) {
        _reportedObstruction = value;
        widget.onObstructionChanged?.call(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      _measureObstruction();
      if (_viewport != null && _viewport != size) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onViewportChanged?.call();
        });
      }
      _viewport = size;
      return Stack(
        key: const ValueKey('reading-viewport'),
        fit: StackFit.expand,
        children: [
          widget.contentBuilder(_toggle),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              key: _topKey,
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _animatedTools(widget.top, const Offset(0, -1)),
                  if (!widget.hasReadablePage) ...widget.notices,
                ],
              ),
            ),
          ),
          if (widget.hasReadablePage && widget.notices.isNotEmpty)
            Positioned(
              top: _tools ? (_reportedObstruction?.top ?? 120) + 8 : 8,
              right: 8,
              child: SafeArea(
                child: ReaderStatusButton(
                  label: widget.statusLabel,
                  details: widget.notices,
                ),
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              key: _bottomKey,
              top: false,
              child: _animatedTools(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 4),
                        child: IconButton.filledTonal(
                          tooltip: '收起阅读工具',
                          onPressed: () => _show(false),
                          icon: const Icon(Icons.fullscreen),
                        ),
                      ),
                    ),
                    widget.bottom,
                  ],
                ),
                const Offset(0, 1),
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _animatedTools(Widget child, Offset from) => IgnorePointer(
    ignoring: !_tools,
    child: ExcludeFocus(
      excluding: !_tools,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: from,
            end: Offset.zero,
          ).animate(_curve),
          child: child,
        ),
      ),
    ),
  );
}

/// A persistent, small entry keeps recoverable problems discoverable without
/// covering readable music. Details close without clearing the underlying state.
class ReaderStatusButton extends StatefulWidget {
  const ReaderStatusButton({
    super.key,
    required this.label,
    required this.details,
  });
  final String label;
  final List<Widget> details;

  @override
  State<ReaderStatusButton> createState() => _ReaderStatusButtonState();
}

class _ReaderStatusButtonState extends State<ReaderStatusButton> {
  late final _details = ValueNotifier((
    label: widget.label,
    widgets: widget.details,
  ));
  bool _open = false;

  @override
  void didUpdateWidget(covariant ReaderStatusButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    scheduleMicrotask(() {
      if (mounted) {
        _details.value = (label: widget.label, widgets: widget.details);
      }
    });
  }

  @override
  void dispose() {
    if (_open) {
      scheduleMicrotask(() {
        if (_open) {
          _details.value = (label: '状态已更新', widgets: const <Widget>[]);
        }
      });
    } else {
      _details.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    tooltip: widget.label,
    icon: const Icon(Icons.info_outline),
    onPressed: () async {
      if (_open) return;
      _open = true;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 16),
            child: ValueListenableBuilder(
              valueListenable: _details,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(value.label),
                    trailing: IconButton(
                      tooltip: '关闭状态详情',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  ...value.widgets,
                  if (value.widgets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('已处理，可继续阅读。'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      _open = false;
      if (!mounted) _details.dispose();
    },
  );
}
