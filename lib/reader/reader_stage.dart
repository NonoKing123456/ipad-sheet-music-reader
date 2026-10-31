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
  });
  final Widget Function(VoidCallback toggleTools) contentBuilder;
  final Widget top, bottom;
  final List<Widget> notices;
  final bool drawing;
  final VoidCallback? onViewportChanged;
  final VoidCallback? onPrevious, onNext;
  final bool allowOverlayPageKeys;
  @override
  State<ReaderStage> createState() => _ReaderStageState();
}

class _ReaderStageState extends State<ReaderStage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late bool _tools = !isMobileReader;
  Size? _viewport;
  late final AnimationController _animation;
  late final Animation<double> _curve;
  bool _reduceMotion = false;
  void _toggle() => _show(!_tools);
  void _show(bool show) {
    setState(() => _tools = show);
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
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
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _animatedTools(widget.top, const Offset(0, -1)),
                  ...widget.notices,
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
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
