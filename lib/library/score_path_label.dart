import 'package:path/path.dart' as p;

/// Presentation only: callers retain the complete identity/search path.
String scoreParentFolder(String path) {
  final folder = p.posix.dirname(path.replaceAll('\\', '/'));
  return folder == '.' || folder.isEmpty ? '谱库根目录' : folder;
}
