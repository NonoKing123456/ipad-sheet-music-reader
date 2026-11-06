import 'dart:async';

import 'reader_text_editing.dart';
import 'reader_tool_button.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/device_layout.dart';
import '../theme/tokens.dart';
import 'reader_spreads.dart';

bool get isMobileReader =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;
bool get canPreviewReader => defaultTargetPlatform == TargetPlatform.windows;

/// Only the reader's exposed surround changes; score pixels retain their colour.
Color readerSurroundColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.black
    : ScoreTokens.of(context).paper2;

/// Tablet paper uses every available pixel; desktop retains its approved gutter.
EdgeInsets readerPagePadding(BuildContext context) =>
    DeviceLayoutScope.isCompact(context)
    ? EdgeInsets.zero
    : const EdgeInsets.all(ScoreLayout.pageGutter);

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

  bool tracks(Route<dynamic>? route) => _routes.contains(route);

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
final _readerStages = <_ReaderStageState>[];

class ReaderStageController {
  VoidCallback? _hide;
  void hideTools() => _hide?.call();
}

/// Visible chrome reserves its actual height; the remaining viewport fits paper.
class ReaderStage extends StatefulWidget {
  const ReaderStage({
    super.key,
    required this.contentBuilder,
    required this.top,
    required this.bottom,
    this.fitAspectFor,
    this.notices = const [],
    this.drawing = false,
    this.onViewportChanged,
    this.onToolsLayoutSettled,
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
    this.initiallyShowTools,
  });
  final Widget Function(VoidCallback toggleTools) contentBuilder;
  final Widget top, bottom;
  final double Function(Size viewport)? fitAspectFor;
  final List<Widget> notices;
  final bool drawing;
  final VoidCallback? onViewportChanged;
  final VoidCallback? onToolsLayoutSettled;
  final VoidCallback? onPrevious, onNext;
  final bool allowOverlayPageKeys;
  final bool blockArrowKeys;
  final ValueChanged<EdgeInsets>? onObstructionChanged;
  final ValueChanged<bool>? onToolsVisibilityChanged;
  final Future<bool> Function()? beforeHideTools;
  final bool hasReadablePage, loading;
  final String statusLabel;
  final ReaderStageController? controller;
  final bool? initiallyShowTools;
  @override
  State<ReaderStage> createState() => _ReaderStageState();
}

class _ReaderStageState extends State<ReaderStage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late bool _tools = !isMobileReader;
  double _statusTopInset = 0;
  double? _lastNativeTopInset;
  Size? _safeAreaSize;
  bool? _lastCompact;
  Size? _viewport;
  final _topKey = GlobalKey();
  EdgeInsets? _reportedObstruction;
  EdgeInsets? _reportedPanInsets;
  bool _measurementScheduled = false;
  late final AnimationController _animation;
  late final Animation<double> _eased;
  late Animation<double> _curve;
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

  bool get _routeVisible => readerRouteVisibility.tracks(_route)
      ? readerRouteVisibility.isVisible(_route)
      : (_route?.isCurrent ?? true);

  void _updateWake() {
    _setWake(widget.hasReadablePage && _foreground && _routeVisible);
    _updateSystemUi();
  }

  void _routeVisibilityChanged() {
    _lastSystemOverlays = null;
    _updateWake();
  }

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
    if (show == _tools) return;
    if (!show &&
        widget.beforeHideTools != null &&
        !await widget.beforeHideTools!()) {
      return;
    }
    if (!mounted) return;
    final from = _curve.value;
    setState(() {
      _tools = show;
      _curve = Tween<double>(begin: from, end: show ? 1 : 0).animate(_eased);
    });
    widget.onToolsVisibilityChanged?.call(show);
    _updateSystemUi();
    _animation.value = 0;
    if (_reduceMotion) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    // A hidden iOS status bar reports zero later than our UI request. Keep the
    // last real inset through that hide/show round trip, but never carry it
    // across rotation or split-view geometry. First-use and changed insets are
    // retargeted by the compositor from its actual currently painted rectangle.
    if (_safeAreaSize != media.size ||
        media.viewPadding.top > 0 ||
        (_tools && _lastNativeTopInset != media.viewPadding.top)) {
      _statusTopInset = media.viewPadding.top;
    }
    _lastNativeTopInset = media.viewPadding.top;
    _safeAreaSize = media.size;
    final compact = DeviceLayoutScope.isCompact(context);
    if (_lastCompact != compact) {
      final initialLayout = _lastCompact == null;
      _lastCompact = compact;
      _tools = widget.initiallyShowTools ?? !compact;
      _curve = AlwaysStoppedAnimation(_tools ? 1 : 0);
      _animation.value = 1;
      if (!initialLayout) widget.onToolsVisibilityChanged?.call(_tools);
    }
    _route = ModalRoute.of(context);
    _updateWake();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _animation.value = 1;
  }

  @override
  void initState() {
    super.initState();
    _readerStages.add(this);
    widget.controller?._hide = _hideFromButton;
    _animation = AnimationController(
      vsync: this,
      duration: ScoreMotion.panel,
      value: 1,
    );
    _eased = CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic);
    _curve = AlwaysStoppedAnimation(_tools ? 1 : 0);
    _animation.addListener(_measureObstruction);
    _animation.addStatusListener(_toolsAnimationStatus);
    WidgetsBinding.instance.addObserver(this);
    readerRouteVisibility.addListener(_routeVisibilityChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_pageKey);
  }

  void _toolsAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onToolsLayoutSettled?.call();
    });
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
    final pagePrevious = event.logicalKey == LogicalKeyboardKey.pageUp;
    final pageNext = event.logicalKey == LogicalKeyboardKey.pageDown;
    if (widget.blockArrowKeys && (arrow || pagePrevious || pageNext)) {
      return KeyEventResult.ignored;
    }
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
    if (arrow &&
        (focus?.findAncestorWidgetOfExactType<ReaderSizeButton>() != null ||
            focus?.findAncestorWidgetOfExactType<Slider>() != null)) {
      return KeyEventResult.ignored;
    }
    if (arrow &&
        focus
                ?.findAncestorWidgetOfExactType<
                  SegmentedButton<ReaderViewMode>
                >() !=
            null) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final action = pageNext || arrowNext
        ? widget.onNext
        : pagePrevious || arrowPrevious
        ? widget.onPrevious
        : null;
    if (action == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) action();
    return KeyEventResult.handled;
  }

  List<SystemUiOverlay>? _lastSystemOverlays;
  void _updateSystemUi() {
    if (isMobileReader) {
      final hideStatus =
          defaultTargetPlatform == TargetPlatform.iOS &&
          widget.hasReadablePage &&
          !_tools &&
          _foreground &&
          _routeVisible;
      final overlays = hideStatus
          ? const [SystemUiOverlay.bottom]
          : SystemUiOverlay.values;
      if (listEquals(_lastSystemOverlays, overlays)) return;
      _lastSystemOverlays = overlays;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: overlays,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateWake();
    // The OS can reset its overlays while backgrounded or presenting a share
    // sheet. Reassert this reader's current chrome state on resume.
    if (_foreground) {
      _lastSystemOverlays = null;
      _updateSystemUi();
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller?._hide, _hideFromButton)) {
      widget.controller?._hide = null;
    }
    _setWake(false);
    readerRouteVisibility.removeListener(_routeVisibilityChanged);
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_pageKey);
    _animation.removeStatusListener(_toolsAnimationStatus);
    _animation.dispose();
    _readerStages.remove(this);
    if (isMobileReader) {
      // A nested reader may be popped above another fullscreen reader. Its
      // disposal must restore that visible reader rather than showing status
      // chrome over it after Navigator's didPop notification already ran.
      final owners = _readerStages.reversed.where(
        (stage) => stage.mounted && stage._foreground && stage._routeVisible,
      );
      if (owners.isNotEmpty) {
        final owner = owners.first;
        owner._lastSystemOverlays = null;
        owner._updateSystemUi();
      } else {
        unawaited(
          SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: SystemUiOverlay.values,
          ),
        );
      }
    }
    super.dispose();
  }

  void _measureObstruction() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final top = _topKey.currentContext?.findRenderObject() as RenderBox?;
      final topHeight = top == null || !top.hasSize ? 0.0 : top.size.height;
      final obstruction = EdgeInsets.only(top: topHeight * _curve.value);
      _reportedObstruction = obstruction;
      // The content viewport already starts below chrome. Passing its global
      // bottom as an obstruction would compensate the same header twice.
      const panInsets = EdgeInsets.zero;
      if (panInsets != _reportedPanInsets) {
        _reportedPanInsets = panInsets;
        widget.onObstructionChanged?.call(panInsets);
      }
    });
  }

  SystemUiOverlayStyle _systemOverlayStyle(BuildContext context, Size size) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final aspectFor = widget.fitAspectFor;
      var paperCoversTop = false;
      if (widget.hasReadablePage && !_tools && aspectFor != null) {
        final paper = applyBoxFit(
          BoxFit.contain,
          Size(aspectFor(size), 1),
          size,
        ).destination;
        // Native status text is black over a page filling the top edge. When
        // aspect-preserving fit exposes dark surround, keep its text readable.
        paperCoversTop =
            paper.width >= size.width - precisionErrorTolerance &&
            paper.height >= size.height - precisionErrorTolerance;
      }
      return dark && !paperCoversTop
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark;
    }
    return dark
        ? SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.black,
            systemNavigationBarColor: Colors.black,
          )
        : SystemUiOverlayStyle.dark;
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('reader-surround'),
    color: readerSurroundColor(context),
    child: SafeArea(
      // Only controls consume safe insets on tablet. Paper extends beneath
      // the native status bar and home indicator without cropping its content.
      top: !DeviceLayoutScope.isCompact(context),
      bottom: !DeviceLayoutScope.isCompact(context),
      left: !DeviceLayoutScope.isCompact(context),
      right: !DeviceLayoutScope.isCompact(context),
      maintainBottomViewPadding: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          _measureObstruction();
          if (_viewport != null && _viewport != size) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onViewportChanged?.call();
            });
          }
          _viewport = size;
          final content = widget.contentBuilder(_toggle);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: _systemOverlayStyle(context, size),
            child: Stack(
              key: const ValueKey('reading-viewport'),
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      heightFactor: _tools ? 1 : 0,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: defaultTargetPlatform == TargetPlatform.iOS
                              ? _statusTopInset
                              : MediaQuery.paddingOf(context).top,
                        ),
                        child: SafeArea(
                          top: false,
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
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, available) => ReaderChromeViewport(
                          key: const ValueKey('reader-content-inset'),
                          topInset: constraints.maxHeight - available.maxHeight,
                          fitAspectFor: widget.fitAspectFor,
                          pagePadding: readerPagePadding(context),
                          transition: _curve,
                          transitionTarget: _tools ? 1 : 0,
                          child: content,
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.hasReadablePage && widget.notices.isNotEmpty)
                  Positioned(
                    top: _tools
                        ? (_reportedObstruction?.top ??
                                  ScoreLayout.readerHeaderHeight +
                                      ScoreLayout.annotationBarHeight) +
                              ScoreSpace.sm
                        : ScoreSpace.sm,
                    right: ScoreSpace.sm,
                    child: SafeArea(
                      child: ReaderStatusButton(
                        label: widget.statusLabel,
                        details: widget.notices,
                      ),
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
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: _animatedTools(
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: ScoreLayout.dotsBottom,
                        ),
                        child: widget.bottom,
                      ),
                      const Offset(0, 1),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
  Widget _animatedTools(Widget child, Offset from) => IgnorePointer(
    ignoring: !_tools,
    child: ExcludeFocus(
      excluding: !_tools,
      child: ExcludeSemantics(
        excluding: !_tools,
        child: FadeTransition(
          opacity: _curve,
          child: AnimatedBuilder(
            animation: _curve,
            child: child,
            builder: (context, child) => Transform.translate(
              offset: from * (ScoreSpace.sm * (1 - _curve.value)),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Lay the real reader out once at its destination size, then paint the same
/// paper, annotations and handles through one compositor-only transition.
/// Chrome and paper share one clock. A late native inset or a reversed gesture
/// starts from the rectangle already on screen, rather than restarting a fit.
class ReaderChromeViewport extends StatefulWidget {
  const ReaderChromeViewport({
    super.key,
    required this.topInset,
    required this.child,
    this.fitAspectFor,
    this.pagePadding = const EdgeInsets.all(ScoreLayout.pageGutter),
    this.transition,
    this.transitionTarget,
  });
  final double topInset;
  final Widget child;
  final double Function(Size viewport)? fitAspectFor;
  final EdgeInsets pagePadding;
  final Animation<double>? transition;
  final double? transitionTarget;
  @override
  State<ReaderChromeViewport> createState() => _ReaderChromeViewportState();
}

class _ReaderChromeViewportState extends State<ReaderChromeViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    value: 1,
    duration: ScoreMotion.panel,
  );
  Size? _layoutSize;
  double _fromInset = 0, _toInset = 0;
  Rect? _fromPaper, _toPaper;
  bool _externalClock = false;
  double _clockStart = 0, _clockEnd = 1;

  double get _progress {
    if (!_externalClock) {
      return Curves.easeOutCubic.transform(_animation.value);
    }
    final distance = _clockEnd - _clockStart;
    if (distance.abs() < precisionErrorTolerance) return 1;
    return ((widget.transition!.value - _clockStart) / distance).clamp(0, 1);
  }

  Rect _paperRect(Size viewport) {
    final aspect = widget.fitAspectFor;
    if (aspect == null) {
      // Continuous paper keeps its width and scroll anchor. Only its origin
      // moves; fitting the entire scrolling document would change its zoom.
      return Rect.fromLTWH(0, widget.topInset, viewport.width, 1);
    }
    final inner = Size(
      (viewport.width - widget.pagePadding.horizontal).clamp(
        1,
        double.infinity,
      ),
      (viewport.height - widget.pagePadding.vertical).clamp(1, double.infinity),
    );
    final fitted = Alignment.center.inscribe(
      applyBoxFit(BoxFit.contain, Size(aspect(inner), 1), inner).destination,
      Offset.zero & inner,
    );
    return fitted.shift(
      Offset(widget.pagePadding.left, widget.topInset + widget.pagePadding.top),
    );
  }

  void _layout(Size size, bool reduceMotion) {
    final paper = _paperRect(size);
    if (_layoutSize == null) {
      _fromPaper = _toPaper = paper;
      _fromInset = _toInset = widget.topInset;
    } else if (_layoutSize != size || _toInset != widget.topInset) {
      final progress = _progress;
      _fromPaper = Rect.lerp(_fromPaper, _toPaper, progress)!;
      _fromInset += (_toInset - _fromInset) * progress;
      _toPaper = paper;
      _toInset = widget.topInset;
      final clock = widget.transition, target = widget.transitionTarget;
      _externalClock =
          clock != null &&
          target != null &&
          (clock.value - target).abs() > precisionErrorTolerance;
      if (_externalClock) {
        _clockStart = clock!.value;
        _clockEnd = target!;
      } else {
        _animation.forward(from: 0);
      }
    } else if (_toPaper != paper) {
      // Document/page presentation owns changes to paper aspect. A toolbar
      // transition must not introduce an additional page-change animation.
      _fromPaper = _toPaper = paper;
    }
    _layoutSize = size;
    if (reduceMotion) {
      _externalClock = false;
      _animation.value = 1;
      _fromPaper = _toPaper;
      _fromInset = _toInset;
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      _layout(size, MediaQuery.disableAnimationsOf(context));
      return AnimatedBuilder(
        animation: Listenable.merge([_animation, widget.transition]),
        child: widget.child,
        builder: (context, child) {
          final progress = _progress;
          final visual = Rect.lerp(_fromPaper, _toPaper, progress)!;
          final destination = _toPaper!;
          final scale = visual.height / destination.height;
          final offset =
              visual.topLeft -
              Offset(0, widget.topInset) -
              (destination.topLeft - Offset(0, widget.topInset)) * scale;
          final inset = _fromInset + (_toInset - _fromInset) * progress;
          return ClipRect(
            clipper: _ReaderChromeClip(
              Rect.fromLTRB(
                0,
                inset - widget.topInset,
                size.width,
                size.height,
              ),
            ),
            child: Transform(
              key: const ValueKey('reader-chrome-compositor'),
              transform: progress == 1
                  ? Matrix4.identity()
                  : (Matrix4.diagonal3Values(scale, scale, 1)
                      ..setTranslationRaw(offset.dx, offset.dy, 0)),
              child: child,
            ),
          );
        },
      );
    },
  );
}

class _ReaderChromeClip extends CustomClipper<Rect> {
  const _ReaderChromeClip(this.rect);
  final Rect rect;
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_ReaderChromeClip oldClipper) => rect != oldClipper.rect;
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
