import 'dart:io';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'manifest.dart';

/// Additive v2 metadata. A known file can have no hash and no downloaded bytes.
class LibrarySourceInfo {
  const LibrarySourceInfo(this.id, this.name, {this.online = true});
  final String id, name;
  final bool online;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'online': online};
  factory LibrarySourceInfo.fromJson(Map<String, dynamic> j) =>
      LibrarySourceInfo(j['id'] as String, j['name'] as String,
          online: j['online'] as bool);
}

class CatalogItem {
  CatalogItem(
      {required this.sourceId,
      required this.entryId,
      required this.revisionId,
      required this.relativePath,
      required this.length,
      required this.format,
      this.hash,
      this.missing = false}) {
    validatePortablePath(relativePath);
    // Reuse the strict immutable object contract when content is known.
    ManifestEntry(
        entryId: entryId,
        revisionId: revisionId,
        relativePath: relativePath,
        hash: hash,
        length: length,
        format: format,
        missing: hash == null || missing);
  }
  final String sourceId, entryId, revisionId, relativePath, format;
  final int length;
  final String? hash;
  final bool missing;
  ManifestEntry get object => ManifestEntry(
      entryId: entryId,
      revisionId: revisionId,
      relativePath: relativePath,
      hash: hash,
      length: length,
      format: format,
      missing: missing);
  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'entryId': entryId,
        'revisionId': revisionId,
        'relativePath': relativePath,
        'length': length,
        'format': format,
        'hash': hash,
        'missing': missing
      };
  factory CatalogItem.fromJson(Map<String, dynamic> j) => CatalogItem(
      sourceId: j['sourceId'] as String,
      entryId: j['entryId'] as String,
      revisionId: j['revisionId'] as String,
      relativePath: j['relativePath'] as String,
      length: j['length'] as int,
      format: j['format'] as String,
      hash: j['hash'] as String?,
      missing: j['missing'] as bool);
}

class CollectionIndex {
  CollectionIndex(
      {required this.id,
      required this.sources,
      required this.entries,
      required this.folders,
      this.legacyLibraryId}) {
    if (id.isEmpty ||
        sources.map((s) => s.id).toSet().length != sources.length ||
        entries.map((e) => e.entryId).toSet().length != entries.length) {
      throw const FormatException('Invalid collection identity.');
    }
    final ids = sources.map((s) => s.id).toSet();
    for (final e in entries) {
      if (!ids.contains(e.sourceId))
        throw const FormatException('Unknown source.');
    }
    for (final e in folders.entries) {
      if (!ids.contains(e.key))
        throw const FormatException('Unknown source folders.');
      for (final path in e.value) {
        validatePortablePath(path, folder: true);
      }
    }
  }
  final String id;
  final String? legacyLibraryId;
  final List<LibrarySourceInfo> sources;
  final List<CatalogItem> entries;
  final Map<String, List<String>> folders;
  CatalogItem? entry(String id) {
    for (final item in entries) {
      if (item.entryId == id) return item;
    }
    return null;
  }

  CollectionIndex replacing(CatalogItem item) => CollectionIndex(
      id: id,
      legacyLibraryId: legacyLibraryId,
      sources: sources,
      folders: folders,
      entries: [for (final e in entries) e.entryId == item.entryId ? item : e]);
  Map<String, Object?> toJson() => {
        'protocol': 2,
        'id': id,
        'legacyLibraryId': legacyLibraryId,
        'sources': sources.map((s) => s.toJson()).toList(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'folders': folders
      };
  factory CollectionIndex.fromJson(Map<String, dynamic> j) {
    if (j['protocol'] != 2)
      throw const FormatException('Unsupported collection.');
    return CollectionIndex(
        id: j['id'] as String,
        legacyLibraryId: j['legacyLibraryId'] as String?,
        sources: (j['sources'] as List)
            .map((s) =>
                LibrarySourceInfo.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList(),
        entries: (j['entries'] as List)
            .map((e) =>
                CatalogItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        folders: (j['folders'] as Map)
            .map((k, v) => MapEntry(k as String, (v as List).cast<String>())));
  }
}

bool folderContains(String folder, String path) =>
    folder.isEmpty || path == folder || path.startsWith('$folder/');

class OfflineRule {
  OfflineRule(
      {required this.sourceId,
      required this.selected,
      this.folder,
      this.entryId}) {
    if ((folder == null) == (entryId == null))
      throw const FormatException('Invalid selection.');
    if (folder != null) validatePortablePath(folder!, folder: true);
  }
  final String sourceId;
  final String? folder, entryId;
  final bool selected;
  bool matches(CatalogItem item) =>
      item.sourceId == sourceId &&
      (entryId == item.entryId ||
          (folder != null && folderContains(folder!, item.relativePath)));
  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'folder': folder,
        'entryId': entryId,
        'selected': selected
      };
  factory OfflineRule.fromJson(Map<String, dynamic> j) => OfflineRule(
      sourceId: j['sourceId'] as String,
      folder: j['folder'] as String?,
      entryId: j['entryId'] as String?,
      selected: j['selected'] as bool);
}

/// Empty means zero downloads. A selected empty folder explicitly means all of
/// that one source; last matching rules support folder/file overrides.
class OfflineSelection {
  const OfflineSelection([this.rules = const []]);
  final List<OfflineRule> rules;
  bool includes(CatalogItem item) {
    var value = false;
    for (final rule in rules) {
      if (rule.matches(item)) value = rule.selected;
    }
    return value;
  }

  OfflineSelection withRule(OfflineRule next) => OfflineSelection([
        for (final rule in rules)
          if (!(rule.sourceId == next.sourceId &&
              rule.folder == next.folder &&
              rule.entryId == next.entryId))
            rule,
        next,
      ]);
  List<Map<String, Object?>> toJson() => rules.map((r) => r.toJson()).toList();
  factory OfflineSelection.fromJson(List<dynamic> j) => OfflineSelection(j
      .map((r) => OfflineRule.fromJson(Map<String, dynamic>.from(r as Map)))
      .toList());
}

abstract interface class CollectionLibrarySource {
  Future<CollectionIndex> index();
  Future<CatalogItem> prepare(String entryId, String revisionId);
  Future<Stream<List<int>>> openSelectedObject(
      String entryId, String revisionId);
}

String collectionEntryId(String sourceId, String localId) =>
    sourceId == 'legacy' ? localId : '$sourceId:$localId';

class CatalogSourceBinding {
  const CatalogSourceBinding(this.id, this.name, this.catalog,
      {this.online = true});
  final String id, name;
  final LibraryCatalog catalog;
  final bool online;
}

/// Live bindings avoid retaining old catalog snapshots after background scans.
class CatalogCollectionSource implements CollectionLibrarySource {
  const CatalogCollectionSource(
      {required this.id,
      required this.bindings,
      this.legacyLibraryId,
      this.onMaterialized});
  final String id;
  final String? legacyLibraryId;
  final List<CatalogSourceBinding> Function() bindings;
  final void Function()? onMaterialized;

  CatalogItem _item(CatalogSourceBinding source, LibraryEntry entry) =>
      CatalogItem(
          sourceId: source.id,
          entryId: collectionEntryId(source.id, entry.id),
          revisionId: entry.currentRevisionId,
          relativePath: entry.relativePath,
          length: entry.currentRevision.size,
          hash: entry.currentRevision.contentHash,
          format:
              p.posix.extension(entry.relativePath).substring(1).toLowerCase(),
          missing: entry.status == EntryStatus.missing);

  @override
  Future<CollectionIndex> index() async {
    final current = bindings();
    return CollectionIndex(id: id, legacyLibraryId: legacyLibraryId, sources: [
      for (final s in current) LibrarySourceInfo(s.id, s.name, online: s.online)
    ], entries: [
      for (final s in current)
        for (final e in s.catalog.snapshot.entries) _item(s, e)
    ], folders: {
      for (final s in current) s.id: s.catalog.snapshot.folders
    });
  }

  (CatalogSourceBinding, LibraryEntry) _resolve(String id) {
    for (final source in bindings()) {
      final localId = source.id == 'legacy'
          ? id
          : id.startsWith('${source.id}:')
              ? id.substring(source.id.length + 1)
              : null;
      if (localId == null) continue;
      final entry = source.catalog.snapshot.entryById(localId);
      if (entry != null && entry.status == EntryStatus.available)
        return (source, entry);
    }
    throw StateError('Unknown selected object.');
  }

  @override
  Future<CatalogItem> prepare(String entryId, String revisionId) async {
    final (source, entry) = _resolve(entryId);
    if (!source.online || entry.currentRevisionId != revisionId) {
      throw StateError('Selected source changed or is offline.');
    }
    final ready = await source.catalog.materialize(entry.id);
    onMaterialized?.call();
    return _item(source, ready);
  }

  @override
  Future<Stream<List<int>>> openSelectedObject(
      String entryId, String revisionId) async {
    final (source, entry) = _resolve(entryId);
    if (!source.online ||
        entry.currentRevisionId != revisionId ||
        entry.currentRevision.contentHash == null ||
        entry.availability != ContentAvailability.ready) {
      throw StateError('Selected object is not ready.');
    }
    final path = await source.catalog.validatedPathFor(entry);
    final stat = await File(path).stat();
    if (stat.size != entry.currentRevision.size ||
        stat.modified.toUtc() != entry.currentRevision.modifiedUtc) {
      throw StateError('Selected source changed.');
    }
    return File(path).openRead();
  }
}
