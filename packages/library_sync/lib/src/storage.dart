import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

String randomId([int bytes = 32]) => base64Url
    .encode(List.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

Map<String, dynamic> asMap(Object? value) =>
    Map<String, dynamic>.from(value as Map);

/// Resolve only the trusted application-support root supplied by the host.
/// OS aliases such as Apple's /var -> /private/var address the same directory.
/// Never use this for source folders, replicas, objects, or peer subdirectories:
/// those must still pass [assertSafePath] without following links.
Future<Directory> prepareTrustedStateRoot(Directory applicationRoot) async {
  await applicationRoot.create(recursive: true);
  final canonical = Directory(await applicationRoot.resolveSymbolicLinks());
  assertSafePath(canonical.path, canonical.path);
  return canonical;
}

/// State directories have one active owner; lock is held for the operation or
/// lifetime, including across separate Dart processes. Never lock source files.
class DirectoryLease {
  DirectoryLease._(this.key, this.handle);
  static final _active = <String>{};
  final String key;
  final RandomAccessFile handle;
  static Future<DirectoryLease> acquire(String root) async {
    final key = p.normalize(p.absolute(root));
    final normalized = Platform.isWindows ? key.toLowerCase() : key;
    if (!_active.add(normalized))
      throw StateError('Sync directory already in use.');
    RandomAccessFile? handle;
    try {
      assertSafePath(key, key);
      await Directory(key).create(recursive: true);
      assertSafePath(key, p.join(key, '.sync.lock'));
      handle =
          await File(p.join(key, '.sync.lock')).open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      return DirectoryLease._(normalized, handle);
    } catch (_) {
      await handle?.close();
      _active.remove(normalized);
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      await handle.unlock();
    } finally {
      await handle.close();
      _active.remove(key);
    }
  }
}

/// Reject links at every existing ancestor, including root and the final file.
/// App-private roots must not be writable by untrusted concurrent processes.
void assertSafePath(String root, String target) {
  final r = p.normalize(p.absolute(root)), t = p.normalize(p.absolute(target));
  if (r != t && !p.isWithin(r, t))
    throw const FormatException('Path escapes root.');
  var cursor = t;
  while (true) {
    if (FileSystemEntity.typeSync(cursor, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
          'Linked sync/source paths are forbidden.');
    }
    final parent = p.dirname(cursor);
    if (parent == cursor) break;
    cursor = parent;
  }
}

Future<Map<String, dynamic>?> readJson(String filePath) async {
  assertSafePath(p.dirname(filePath), filePath);
  final primary = File(filePath), backup = File('$filePath.backup');
  if (!await primary.exists() && !await backup.exists()) return null;
  Object? error;
  for (final file in [primary, backup]) {
    assertSafePath(p.dirname(filePath), file.path);
    if (!await file.exists()) continue;
    try {
      return asMap(jsonDecode(await file.readAsString()));
    } catch (e) {
      error = e;
    }
  }
  throw FormatException('Invalid sync state: $error');
}

Future<void> writeJson(String filePath, Map<String, Object?> json) async {
  final root = p.dirname(filePath);
  assertSafePath(root, filePath);
  await Directory(root).create(recursive: true);
  final temp = File('$filePath.tmp.${randomId(12)}');
  final primary = File(filePath), backup = File('$filePath.backup');
  assertSafePath(root, backup.path);
  await temp.writeAsString(jsonEncode(json), flush: true);
  try {
    if (await primary.exists()) {
      // Keep a valid prior generation; an invalid primary never replaces it.
      var valid = false;
      try {
        asMap(jsonDecode(await primary.readAsString()));
        valid = true;
      } catch (_) {}
      if (valid) {
        if (await backup.exists()) await backup.delete();
        await primary.rename(backup.path);
      } else {
        await primary.rename('$filePath.corrupt.${randomId(8)}');
      }
    }
    await temp.rename(filePath);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}
