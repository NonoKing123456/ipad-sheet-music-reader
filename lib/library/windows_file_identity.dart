import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

final class _FileIdInfo extends Struct {
  @Uint64()
  external int volume;
  @Array(16)
  external Array<Uint8> id;
}

final _kernel = DynamicLibrary.open('kernel32.dll');
final _allocate = _kernel
    .lookupFunction<
      Pointer<Void> Function(Uint32, UintPtr),
      Pointer<Void> Function(int, int)
    >('LocalAlloc');
final _free = _kernel
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('LocalFree');
final _open = _kernel
    .lookupFunction<
      IntPtr Function(
        Pointer<Uint16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        IntPtr,
      ),
      int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');
final _info = _kernel
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('GetFileInformationByHandleEx');
final _close = _kernel
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _attributes = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Uint16>),
      int Function(Pointer<Uint16>)
    >('GetFileAttributesW');

/// Metadata-only check before optional PDF inspection; never hydrate a cloud
/// placeholder merely to decorate a directory row.
bool attributesAllowLocalMetadata(int value) =>
    value != 0xffffffff && value & (0x10 | 0x1000 | 0x40000 | 0x400000) == 0;

Future<bool> isLocallyReadableFile(String path) async {
  if (!Platform.isWindows) {
    return await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.file;
  }
  final native = path.length < 248 || path.startsWith('\\\\?\\')
      ? path
      : path.startsWith('\\\\')
      ? '\\\\?\\UNC\\${path.substring(2)}'
      : '\\\\?\\$path';
  if (native.length > 32767) return false;
  final name = _allocate(0x40, (native.length + 1) * 2).cast<Uint16>();
  if (name == nullptr) return false;
  try {
    name.asTypedList(native.length + 1).setAll(0, native.codeUnits);
    final value = _attributes(name);
    if (!attributesAllowLocalMetadata(value)) return false;
    // REPARSE_POINT also covers fully hydrated cloud files. Dart's no-follow
    // type labels every reparse tag as a link; compare the resolved path instead
    // so name-surrogate links/junction escapes remain excluded.
    return p.equals(p.absolute(path), await File(path).resolveSymbolicLinks());
  } finally {
    _free(name.cast());
  }
}

/// Attribute/ID access only: never hashes or hydrates content. Unsupported
/// volumes return null instead of guessing identity from names or size/mtime.
Future<String?> windowsFileIdentity(String path, FileStat stat) async {
  if (!Platform.isWindows || stat.type != FileSystemEntityType.file) {
    return null;
  }
  final nativePath = path.length < 248 || path.startsWith('\\\\?\\')
      ? path
      : path.startsWith('\\\\')
      ? '\\\\?\\UNC\\${path.substring(2)}'
      : '\\\\?\\$path';
  final units = nativePath.codeUnits;
  if (units.length > 32767) return null;
  final name = _allocate(0x40, (units.length + 1) * 2).cast<Uint16>();
  final data = _allocate(0x40, sizeOf<_FileIdInfo>());
  if (name == nullptr || data == nullptr) {
    if (name != nullptr) _free(name.cast());
    if (data != nullptr) _free(data);
    return null;
  }
  var handle = -1;
  try {
    name.asTypedList(units.length + 1).setAll(0, units);
    handle = _open(name, 0x80, 7, nullptr, 3, 0x00200000, 0);
    if (handle == -1 || _info(handle, 18, data, sizeOf<_FileIdInfo>()) == 0) {
      return null;
    }
    final id = data.cast<_FileIdInfo>().ref;
    return 'win:${id.volume.toRadixString(16)}:${List.generate(16, (i) => id.id[i].toRadixString(16).padLeft(2, '0')).join()}';
  } finally {
    if (handle != -1) _close(handle);
    _free(data);
    _free(name.cast());
  }
}
