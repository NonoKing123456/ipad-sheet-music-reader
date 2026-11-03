import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// UI layout preference only. This deliberately does not override Flutter's
/// platform, so plugins and file/system operations continue to see Windows.
class DeviceLayoutController extends ChangeNotifier {
  DeviceLayoutController({bool simulateIpad = false}) {
    _simulateIpad = simulateIpad;
  }

  late bool _simulateIpad;
  bool get simulateIpad => _simulateIpad;

  void setSimulateIpad(bool value) {
    if (_simulateIpad == value) return;
    _simulateIpad = value;
    notifyListeners();
  }

  void toggle() => setSimulateIpad(!_simulateIpad);
}

class DeviceLayoutScope extends InheritedNotifier<DeviceLayoutController> {
  const DeviceLayoutScope({
    super.key,
    required DeviceLayoutController controller,
    required super.child,
  }) : super(notifier: controller);

  static DeviceLayoutController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceLayoutScope>()?.notifier;

  /// True when the shell and reader should use the compact tablet layout.
  static bool isCompact(BuildContext context) =>
      isSimulatedIpad(context) ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// True only for an explicitly enabled Windows preview.
  static bool isSimulatedIpad(BuildContext context) =>
      maybeOf(context)?.simulateIpad ?? false;
}

/// Constrains the complete app (including pushed routes and overlays) to an
/// iPad portrait canvas while previewing on a desktop display.
class DeviceLayoutCanvas extends StatelessWidget {
  const DeviceLayoutCanvas({
    super.key,
    required this.controller,
    required this.child,
  });

  final DeviceLayoutController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.simulateIpad) return child;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(
              constraints.maxWidth,
              constraints.maxHeight * 0.75,
            );
            final height = width / 0.75;
            final media = MediaQuery.of(context);
            return ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Center(
                child: SizedBox(
                  key: const ValueKey('ipad-preview-canvas'),
                  width: width,
                  height: height,
                  child: ClipRect(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: 768,
                        height: 1024,
                        child: MediaQuery(
                          data: media.copyWith(size: const Size(768, 1024)),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
