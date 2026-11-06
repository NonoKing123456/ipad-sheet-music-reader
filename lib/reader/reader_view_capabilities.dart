import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import '../theme/device_layout.dart';
import 'reader_spreads.dart';

/// Reading capabilities are independent of the desktop window chrome. Tablet
/// spread availability follows the available canvas, including split view.
class ReaderViewCapabilities {
  const ReaderViewCapabilities({
    required this.compact,
    required this.landscape,
    required this.multipleModes,
  });

  factory ReaderViewCapabilities.of(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return ReaderViewCapabilities(
      compact: DeviceLayoutScope.isCompact(context),
      landscape: size.width > size.height,
      multipleModes:
          !DeviceLayoutScope.isCompact(context) ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          DeviceLayoutScope.isSimulatedIpad(context),
    );
  }

  final bool compact, landscape, multipleModes;
  bool supports(ReaderViewMode mode) =>
      mode == ReaderViewMode.single ||
      (multipleModes &&
          (mode != ReaderViewMode.spread || !compact || landscape));

  ReaderViewMode resolve(ReaderViewMode mode) =>
      supports(mode) ? mode : ReaderViewMode.single;
}
