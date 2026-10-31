import 'dart:io';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'storage.dart';

const supportedFormats = {'pdf', 'jpg', 'jpeg', 'png', 'webp'};
void validatePortablePath(String path, {bool folder = false}) {
  if (folder && path.isEmpty) return;
  if (path.isEmpty ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\u0000') ||
      path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw const FormatException('Invalid portable library path.');
  }
}

class ManifestEntry {
  ManifestEntry(
      {required this.entryId,
      required this.revisionId,
      required this.relativePath,
      required this.hash,
      required this.length,
      required this.format,
      required this.missing}) {
    if (entryId.isEmpty || revisionId.isEmpty || length < 0)
      throw const FormatException('Invalid object identity.');
    validatePortablePath(relativePath);
    if (!supportedFormats.contains(format) ||
        p.posix.extension(relativePath).toLowerCase() != '.$format') {
      throw const FormatException('Unsupported or mismatched file format.');
    }
    if (hash != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash!)) {
      throw const FormatException('Invalid SHA-256.');
    }
    if (!missing && hash == null)
      throw const FormatException('Available content requires a hash.');
  }
  final String entryId, revisionId, relativePath, format;
  final String? hash;
  final int length;
  final bool missing;
  Map<String, Object?> toJson() => {
        'entryId': entryId,
        'revisionId': revisionId,
        'relativePath': relativePath,
        'hash': hash,
        'length': length,
        'format': format,
        'missing': missing
      };
  factory ManifestEntry.fromJson(Map<String, dynamic> j) => ManifestEntry(
      entryId: j['entryId'] as String,
      revisionId: j['revisionId'] as String,
      relativePath: j['relativePath'] as String,
      hash: j['hash'] as String?,
      length: j['length'] as int,
      format: j['format'] as String,
      missing: j['missing'] as bool);
}

class SyncManifest {
  SyncManifest(
      {required this.libraryId,
      required List<ManifestEntry> entries,
      required List<String> folders})
      : entries = List.unmodifiable(entries),
        folders = List.unmodifiable(folders) {
    if (libraryId.isEmpty ||
        entries.map((e) => e.entryId).toSet().length != entries.length) {
      throw const FormatException(
          'Invalid library identity or duplicate entries.');
    }
    for (final f in folders) {
      validatePortablePath(f, folder: true);
    }
  }
  final String libraryId;
  final List<ManifestEntry> entries;
  final List<String> folders;
  ManifestEntry? entry(String entryId, String revisionId) {
    for (final e in entries) {
      if (e.entryId == entryId && e.revisionId == revisionId) return e;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'protocol': 1,
        'libraryId': libraryId,
        'entries': entries.map((e) => e.toJson()).toList(),
        'folders': folders
      };
  factory SyncManifest.fromJson(Map<String, dynamic> j) {
    if (j['protocol'] != 1)
      throw const FormatException('Unsupported sync protocol.');
    return SyncManifest(
        libraryId: j['libraryId'] as String,
        entries: (j['entries'] as List)
            .map((e) => ManifestEntry.fromJson(asMap(e)))
            .toList(),
        folders: (j['folders'] as List).cast<String>());
  }
}

/// A source cannot currently supply a complete offline manifest.
/// No source paths or other diagnostic details are exposed to the peer.
class LibrarySourceNotReady extends StateError {
  LibrarySourceNotReady() : super('Source library is not ready for sync.');
}

abstract interface class LibrarySource {
  Future<SyncManifest> manifest();
  Future<Stream<List<int>>> openObject(String entryId, String revisionId);
}

class CatalogLibrarySource implements LibrarySource {
  CatalogLibrarySource({required this.catalog, required this.libraryId});
  final LibraryCatalog catalog;

  /// Persist this ID in application configuration; never derive it from a path.
  final String libraryId;
  @override
  Future<SyncManifest> manifest() async {
    final snapshot = catalog.snapshot;
    return SyncManifest(
        libraryId: libraryId,
        folders: snapshot.folders,
        entries: snapshot.entries.map((e) {
          final r = e.currentRevision;
          if (e.status == EntryStatus.available &&
              (e.availability != ContentAvailability.ready ||
                  r.contentHash == null)) {
            throw LibrarySourceNotReady();
          }
          return ManifestEntry(
              entryId: e.id,
              revisionId: r.id,
              relativePath: e.relativePath,
              hash: r.contentHash,
              length: r.size,
              format:
                  p.posix.extension(e.relativePath).substring(1).toLowerCase(),
              missing: e.status == EntryStatus.missing);
        }).toList());
  }

  @override
  Future<Stream<List<int>>> openObject(
      String entryId, String revisionId) async {
    final e = catalog.snapshot.entryById(entryId);
    if (e == null ||
        e.currentRevisionId != revisionId ||
        e.status != EntryStatus.available ||
        e.availability != ContentAvailability.ready) {
      throw StateError('Object is not allowlisted.');
    }
    final path = catalog.absolutePathFor(e);
    assertSafePath(catalog.snapshot.rootPath, path);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('Source is not a regular file.');
    }
    return File(path).openRead();
  }
}
