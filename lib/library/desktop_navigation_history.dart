import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopNavigationHistory extends NavigatorObserver {
  final _visits = <_Visit>[];
  int _cursor = -1;
  bool _moving = false;
  Future<void> _tail = Future.value();
  final _routes = <Route<dynamic>>[];

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;
  void attach() => FocusManager.instance.addEarlyKeyEventHandler(_key);
  void detach() => FocusManager.instance.removeEarlyKeyEventHandler(_key);
  KeyEventResult _key(KeyEvent event) {
    if (!_windows ||
        event is! KeyDownEvent ||
        _routes.isEmpty ||
        _routes.last is PopupRoute) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final back =
        key == LogicalKeyboardKey.browserBack ||
        (HardwareKeyboard.instance.isAltPressed &&
            key == LogicalKeyboardKey.arrowLeft);
    final forward =
        key == LogicalKeyboardKey.browserForward ||
        (HardwareKeyboard.instance.isAltPressed &&
            key == LogicalKeyboardKey.arrowRight);
    if (!back && !forward) return KeyEventResult.ignored;
    if (_cursor >= 0 && _visits[_cursor].blockKeys?.call() == true) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.widget is EditableText ||
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null ||
        MenuController.maybeOf(focus?.context ?? navigator!.context)?.isOpen ==
            true) {
      return KeyEventResult.ignored;
    }
    move(back ? -1 : 1);
    return KeyEventResult.handled;
  }

  void move(int direction) {
    _tail = _tail.then((_) => _move(direction)).catchError((Object _) {});
  }

  void _append(_Visit visit) {
    if (_moving) return;
    if (_cursor + 1 < _visits.length) {
      _visits.removeRange(_cursor + 1, _visits.length);
    }
    _visits.add(visit);
    if (_visits.length > 128) _visits.removeAt(0);
    _cursor = _visits.length - 1;
  }

  /// A search visit is amended for each character; page turns only amend the
  /// reading visit registered below. Neither produces a history entry per tick.
  void directory(
    Route<dynamic> route,
    Object state,
    VoidCallback restore, {
    bool replace = false,
  }) {
    if (!_windows || _moving || !_routes.contains(route)) return;
    if (_cursor >= 0 &&
        _visits[_cursor].route == route &&
        _visits[_cursor].directoryState == state) {
      return;
    }
    final visit = _Visit(route, null)
      ..directoryState = state
      ..restore = restore;
    if (replace && _cursor >= 0 && _visits[_cursor].route == route) {
      _visits[_cursor] = visit;
    } else if (_cursor >= 0 &&
        _visits[_cursor].route == route &&
        _visits[_cursor].directoryState == null) {
      _visits[_cursor] = visit;
    } else {
      _append(visit);
    }
  }

  void reader(
    Route<dynamic> route,
    Future<bool> Function() canLeave,
    Widget? Function() restore, {
    bool Function()? blockKeys,
  }) {
    final visit = _visits.where((v) => v.route == route).lastOrNull;
    if (visit == null) return;
    visit.canLeave = canLeave;
    visit.builder = restore;
    visit.blockKeys = blockKeys;
  }

  Future<void> _move(int direction) async {
    final next = _cursor + direction;
    if (next < 0 || next >= _visits.length || _routes.isEmpty) return;
    final current = _visits[_cursor], target = _visits[next];
    if (_routes.last is PopupRoute) return;
    if (current.canLeave != null && !await current.canLeave!()) return;
    final nav = navigator;
    if (nav == null || !nav.mounted) return;
    _moving = true;
    try {
      if (_routes.contains(target.route)) {
        // All visits to the directory reuse its mounted route and state.
        while (_routes.isNotEmpty && _routes.last != target.route) {
          final route = _routes.last;
          if (!nav.canPop()) return;
          nav.pop();
          // The observer is synchronous, including when pop animates.
          if (_routes.last == route) return;
        }
        target.restore?.call();
      } else {
        final page = target.builder?.call();
        if (page == null) return;
        final route = MaterialPageRoute<void>(builder: (_) => page);
        target.route = route;
        unawaited(nav.push(route));
      }
      _cursor = next;
    } finally {
      _moving = false;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_windows) return;
    if (previousRoute == null) {
      _routes.clear();
      _visits.clear();
      _cursor = -1;
    }
    _routes.add(route);
    if (route is MaterialPageRoute) {
      _append(_Visit(route, () => route.builder(navigator!.context)));
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    if (_moving || route is PopupRoute) return;
    for (var i = _cursor - 1; i >= 0; i--) {
      if (_visits[i].route == previousRoute) {
        _cursor = i;
        break;
      }
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);
}

class _Visit {
  _Visit(this.route, this.builder);
  Route<dynamic> route;
  Widget? Function()? builder;
  Object? directoryState;
  VoidCallback? restore;
  Future<bool> Function()? canLeave;
  bool Function()? blockKeys;
}

class DesktopHistoryScope extends InheritedWidget {
  const DesktopHistoryScope({
    super.key,
    required this.history,
    required super.child,
  });
  final DesktopNavigationHistory history;
  static DesktopNavigationHistory? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DesktopHistoryScope>()
      ?.history;
  @override
  bool updateShouldNotify(DesktopHistoryScope oldWidget) =>
      oldWidget.history != history;
}
