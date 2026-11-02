import 'dart:async';

import 'reader_text_editing.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get isMobileReader =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;
bool get canPreviewReader => defaultTargetPlatform == TargetPlatform.windows;

/// Root navigation visibility distinguishes opaque pages from local popups.
class ReaderRouteVisibilityObserver extends NavigatorObserver
    with ChangeNotifier {
  final _routes = <Route<dynamic>>[];
  bool isVisible(Route<dynamic>? route) {
    final index = route == null ? -1 : _routes.indexOf(route);
    if (index < 0) return false;
    return !_routes
        .skip(index + 1)
        .any((next) => next is ModalRoute && next.opaque);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) _routes.clear();
    _routes.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) _routes.removeAt(index);
    if (newRoute != null) {
      _routes.insert(index < 0 ? _routes.length : index, newRoute);
    }
    notifyListeners();
  }
}

final readerRouteVisibility = ReaderRouteVisibilityObserver();
const _readerActivityChannel = MethodChannel('score_reader/reader_activity');
int _readerWakeSerial = 0;

class ReaderStageController {
  VoidCallback? _hide;
  void hideTools() => _hide?.call();
}

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
    this.blockArrowKeys = false,
    this.onObstructionChanged,
    this.onToolsVisibilityChanged,
    this.beforeHideTools,
    this.hasReadablePage = false,
    this.statusLabel = '阅读状态',
    this.loading = false,
    this.controller,
  });
  final Widget Function(VoidCallback toggleTools) contentBuilder;
  final Widget top, bottom;
  final List<Widget> notices;
  final bool drawing;
  final VoidCallback? onViewportChanged;
  final VoidCallback? onPrevious, onNext;
  final bool allowOverlayPageKeys;
  final bool blockArrowKeys;
  final ValueChanged<EdgeInsets>? onObstructionChanged;
  final ValueChanged<bool>? onToolsVisibilityChanged;
  final Future<bool> Function()? beforeHideTools;
  final bool hasReadablePage, loading;
  final String statusLabel;
  final ReaderStageController? controller;
  @override
  State<ReaderStage> createState() => _ReaderStageState();
}

class _ReaderStageState extends State<ReaderStage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late bool _tools = !isMobileReader;
  Size? _viewport;
  final _topKey = GlobalKey();
  EdgeInsets? _reportedObstruction;
  bool _measurementScheduled = false;
  late final AnimationController _animation;
  late final Animation<double> _curve;
  bool _reduceMotion = false;
  final _wakeToken = 'reader-${++_readerWakeSerial}';
  ModalRoute<dynamic>? _route;
  bool _wakeHeld = false;
  bool _foreground =
      (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
      AppLifecycleState.resumed;
  late final VoidCallback _hideFromButton = _hideTools;
  void _hideTools() => _show(false);

  void _setWake(bool value) {
    if (defaultTargetPlatform != TargetPlatform.iOS || value == _wakeHeld) {
      return;
    }
    _wakeHeld = value;
    unawaited(
      _readerActivityChannel
          .invokeMethod<void>('setReaderActive', {
            'token': _wakeToken,
            'active': value,
          })
          .catchError((Object _) {
            debugPrint('READER keep_awake_unavailable');
          }),
    );
  }

  void _updateWake() => _setWake(
    widget.hasReadablePage &&
        _foreground &&
        readerRouteVisibility.isVisible(_route),
  );

  @override
  void didUpdateWidget(covariant ReaderStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (identical(oldWidget.controller?._hide, _hideFromButton)) {
        oldWidget.controller?._hide = null;
      }
      widget.controller?._hide = _hideFromButton;
    }
    _updateWake();
  }

  void _toggle() => _show(!_tools);
  Future<void> _show(bool show) async {
    if (!show &&
        widget.beforeHideTools != null &&
        !await widget.beforeHideTools!()) {
      return;
    }
    if (!mounted) return;
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
    _route = ModalRoute.of(context);
    _updateWake();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _animation.value = _tools ? 1 : 0;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._hide = _hideFromButton;
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
    _animation.addListener(_measureObstruction);
    WidgetsBinding.instance.addObserver(this);
    readerRouteVisibility.addListener(_updateWake);
    FocusManager.instance.addEarlyKeyEventHandler(_pageKey);
    _immerse();
  }

  KeyEventResult _pageKey(KeyEvent event) {
    if (readerTextEditorActive) return KeyEventResult.ignored;
    final arrowPrevious =
        defaultTargetPlatform == TargetPlatform.windows &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowUp);
    final arrowNext =
        defaultTargetPlatform == TargetPlatform.windows &&
        (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowDown);
    final arrow = arrowPrevious || arrowNext;
    if (arrow && widget.blockArrowKeys) return KeyEventResult.ignored;
    if (!mounted ||
        (!(ModalRoute.of(context)?.isCurrent ?? true) &&
            (!widget.allowOverlayPageKeys || arrow))) {
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
    final action = event.logicalKey == LogicalKeyboardKey.pageDown || arrowNext
        ? widget.onNext
        : event.logicalKey == LogicalKeyboardKey.pageUp || arrowPrevious
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
    _foreground = state == AppLifecycleState.resumed;
    _updateWake();
    if (_foreground) _immerse();
  }

  @override
  void dispose() {
    if (identical(widget.controller?._hide, _hideFromButton)) {
      widget.controller?._hide = null;
    }
    _setWake(false);
    readerRouteVisibility.removeListener(_updateWake);
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
      final value = EdgeInsets.only(
        top: !_tools || top == null || !top.hasSize
            ? 0
            : top.localToGlobal(Offset(0, top.size.height)).dy,
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
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _animatedTools(
                    KeyedSubtree(key: _topKey, child: widget.top),
                    const Offset(0, -1),
                  ),
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
              top: false,
              child: _animatedTools(
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: widget.bottom,
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
