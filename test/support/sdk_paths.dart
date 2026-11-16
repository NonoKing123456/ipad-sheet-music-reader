import 'dart:io';

import 'package:path/path.dart' as p;

/// Flutter tests run from flutter_tester; Dart tests run from the cached Dart SDK.
/// Both executables live below `<flutter>/bin/cache`.
final String flutterRootPath = _findFlutterRoot();

String _findFlutterRoot() {
  final configured = Platform.environment['FLUTTER_ROOT'];
  if (configured != null && configured.trim().isNotEmpty) {
    return p.normalize(p.absolute(configured));
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    if (p.basename(directory.path) == 'cache' &&
        p.basename(directory.parent.path) == 'bin') {
      return directory.parent.parent.path;
    }
    directory = directory.parent;
  }
  throw StateError(
    'Cannot locate Flutter from ${Platform.resolvedExecutable}; set FLUTTER_ROOT.',
  );
}

String get dartExecutablePath => p.join(
  flutterRootPath,
  'bin',
  'cache',
  'dart-sdk',
  'bin',
  Platform.isWindows ? 'dart.exe' : 'dart',
);

String get materialIconsFontPath => p.join(
  flutterRootPath,
  'bin',
  'cache',
  'artifacts',
  'material_fonts',
  'MaterialIcons-Regular.otf',
);
