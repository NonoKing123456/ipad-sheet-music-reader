import 'dart:io';
import 'dart:convert';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'manifest.dart';
import 'collection_delta.dart';

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
      required List<LibrarySourceInfo> sources,
      required List<CatalogItem> entries,
      required Map<String, List<String>> folders,
      this.legacyLibraryId})
      : sources = List.unmodifiable(sources),
        entries = List.unmodifiable(entries),
        folders = Map.unmodifiable({
          for (final e in folders.entries)
            e.key: List<String>.unmodifiable(e.value)
        }) {
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
  late final Map<String, CatalogItem> _byId = {
    for (final item in entries) item.entryId: item
  };
  CatalogItem? entry(String id) => _byId[id];

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

/// Directory structure survives readiness changes. Built in a worker when full
/// metadata changes; one download updates only this entry's ancestor counters.
class CollectionDirectoryIndex {
  CollectionDirectoryIndex(
      List<LibrarySourceInfo> sources,
      List<CatalogItem> items,
      Map<String, CatalogItem> readable,
      Set<String> ready)
      : sourceNames = {for (final s in sources) s.id: s.name} {
    for (final item in items) {
      _descriptors[item.entryId] =
          (item.sourceId, item.relativePath, item.missing);
      if (item.missing) {
        missingIds.add(item.entryId);
        continue;
      }
      availableIds.add(item.entryId);
      final folder = p.posix.dirname(item.relativePath);
      (_byFolder[(item.sourceId, folder == '.' ? '' : folder)] ??= [])
          .add(item.entryId);
      searchText[item.entryId] =
          '${sourceNames[item.sourceId] ?? ''}/${item.relativePath}'
              .toLowerCase();
      update(item, readable[item.entryId], ready);
    }
  }
  final Map<String, String> sourceNames;
  final availableIds = <String>[];
  final missingIds = <String>[];
  final searchText = <String, String>{};
  final _byFolder = <(String, String), List<String>>{};
  final _descriptors = <String, (String, String, bool)>{};
  final _contributions = <String, (bool, bool, bool)>{};
  final _counts = <(String, String), (int, int, int, int)>{};
  int contentRevision = 0;
  int readableCount = 0;
  List<String> idsInFolder(String? source, String folder) =>
      _byFolder[(source, folder)] ?? const [];
  String? sourceForId(String id) => _descriptors[id]?.$1;
  (int, int, int, int) folderStatus(String source, String folder) =>
      _counts[(source, folder)] ?? (0, 0, 0, 0);

  void remove(String id) {
    final descriptor = _descriptors.remove(id);
    if (descriptor == null) return;
    availableIds.remove(id); missingIds.remove(id); searchText.remove(id);
    final folderPath = p.posix.dirname(descriptor.$2);
    _byFolder[(descriptor.$1, folderPath == '.' ? '' : folderPath)]?.remove(id);
    final prior = _contributions.remove(id);
    if (prior != null) {
      readableCount -= prior.$2 ? 1 : 0;
      var folder = folderPath == '.' ? '' : folderPath;
      while (true) {
        final key = (descriptor.$1, folder), before = _counts[(descriptor.$1, folder)]!;
        _counts[key] = (before.$1 - 1, before.$2 - (prior.$1 ? 1 : 0),
          before.$3 - (prior.$2 ? 1 : 0), before.$4 - (prior.$3 ? 1 : 0));
        if (folder.isEmpty) break;
        final slash = folder.lastIndexOf('/');
        folder = slash < 0 ? '' : folder.substring(0, slash);
      }
    }
    contentRevision++;
  }

  void replace(CatalogItem item, CatalogItem? readable, Set<String> ready) {
    final descriptor = (item.sourceId, item.relativePath, item.missing);
    if (_descriptors[item.entryId] != descriptor) {
      remove(item.entryId);
      _descriptors[item.entryId] = descriptor;
      if (item.missing) { missingIds.add(item.entryId); return; }
      availableIds.add(item.entryId);
      final folder = p.posix.dirname(item.relativePath);
      (_byFolder[(item.sourceId, folder == '.' ? '' : folder)] ??= []).add(item.entryId);
      searchText[item.entryId] = '${sourceNames[item.sourceId] ?? ''}/${item.relativePath}'.toLowerCase();
    }
    update(item, readable, ready);
  }

  bool update(CatalogItem item, CatalogItem? old, Set<String> ready) {
    if (_descriptors[item.entryId] !=
        (item.sourceId, item.relativePath, item.missing)) return false;
    if (item.missing) return true;
    bool isReady(CatalogItem value) =>
        ready.contains('${value.entryId}/${value.revisionId}/${value.hash}');
    final readable = old != null && isReady(old);
    final next = (
      isReady(item) || (readable && old.revisionId == item.revisionId),
      readable,
      readable && old.revisionId != item.revisionId
    );
    final prior = _contributions[item.entryId];
    if (prior == next) return true;
    _contributions[item.entryId] = next;
    final totalDelta = prior == null ? 1 : 0;
    final currentDelta = (next.$1 ? 1 : 0) - (prior?.$1 == true ? 1 : 0);
    final readableDelta = (next.$2 ? 1 : 0) - (prior?.$2 == true ? 1 : 0);
    final pendingDelta = (next.$3 ? 1 : 0) - (prior?.$3 == true ? 1 : 0);
    readableCount += readableDelta;
    var folder = p.posix.dirname(item.relativePath);
    if (folder == '.') folder = '';
    while (true) {
      final key = (item.sourceId, folder);
      final before = _counts[key] ?? (0, 0, 0, 0);
      _counts[key] = (
        before.$1 + totalDelta,
        before.$2 + currentDelta,
        before.$3 + readableDelta,
        before.$4 + pendingDelta
      );
      if (folder.isEmpty) break;
      final slash = folder.lastIndexOf('/');
      folder = slash < 0 ? '' : folder.substring(0, slash);
    }
    contentRevision++;
    return true;
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

/// Optional bounded source preparation. Missing results are isolated failures.
abstract interface class CollectionBatchPreparation {
  Future<Map<String, CatalogItem>> prepareMany(Map<String, String> selected);
}

/// Optional selected-object lookup; generic providers keep the complete-index
/// fallback. The authenticated request and object checks remain unchanged.
abstract interface class CollectionObjectLookup {
  Future<CatalogItem?> itemForObject(String entryId);
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
class CatalogCollectionSource
    implements
        CollectionLibrarySource,
        CollectionObjectLookup,
        CollectionBatchPreparation,
        CollectionVersionSource {
  const CatalogCollectionSource(
      {required this.id,
      required this.bindings,
      this.legacyLibraryId,
      this.onMaterialized,
      this.prepareEntry,
      this.prepareEntries});
  final String id;
  final String? legacyLibraryId;
  final List<CatalogSourceBinding> Function() bindings;
  final void Function()? onMaterialized;

  /// App hosts can coordinate foreground disk work with their background scan.
  /// The wire contract and the selected entry/revision checks stay unchanged.
  final Future<LibraryEntry> Function(String entryId, String revisionId)?
      prepareEntry;

  final Future<Map<String, LibraryEntry>> Function(
      Map<String, String> selected)? prepareEntries;

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
  String get catalogVersion => jsonEncode([
    id, legacyLibraryId,
    for (final s in bindings()) [s.id, s.name, s.online,
      s.catalog.rootPath, s.catalog.statePath, s.catalog.snapshot.generation,
      s.catalog.snapshot.savedUtc.microsecondsSinceEpoch]
  ]);

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
    final ready = prepareEntry == null
        ? await source.catalog.materialize(entry.id)
        : await prepareEntry!(entryId, revisionId);
    if (ready.id != entry.id ||
        ready.currentRevisionId != revisionId ||
        ready.availability != ContentAvailability.ready ||
        ready.currentRevision.contentHash == null) {
      throw StateError('Selected source changed while preparing.');
    }
    onMaterialized?.call();
    return _item(source, ready);
  }

  @override
  Future<Map<String, CatalogItem>> prepareMany(
      Map<String, String> selected) async {
    if (selected.isEmpty || selected.length > 64) {
      throw const FormatException('Invalid selected batch.');
    }
    final resolved = <String, (CatalogSourceBinding, LibraryEntry)>{};
    for (final request in selected.entries) {
      try {
        final owner = _resolve(request.key);
        if (owner.$1.online && owner.$2.currentRevisionId == request.value) {
          resolved[request.key] = owner;
        }
      } on StateError {/* Isolate unavailable siblings. */}
    }
    final valid = {for (final id in resolved.keys) id: selected[id]!};
    final ready = <String, LibraryEntry>{};
    if (prepareEntries != null && valid.isNotEmpty) {
      ready.addAll(await prepareEntries!(valid));
    } else if (prepareEntry != null) {
      for (final request in valid.entries) {
        try {
          ready[request.key] = await prepareEntry!(request.key, request.value);
        } catch (_) {/* Preserve the host's legacy coordination contract. */}
      }
    } else {
      final groups = <LibraryCatalog, Map<String, String>>{};
      for (final request in resolved.entries) {
        (groups[request.value.$1.catalog] ??= {})[request.value.$2.id] =
            selected[request.key]!;
      }
      for (final group in groups.entries) {
        final patch = await group.key
            .materializeManyForPublication(group.value, group.key.publication);
        for (final request in resolved.entries
            .where((e) => identical(e.value.$1.catalog, group.key))) {
          final entry = patch.entries[request.value.$2.id];
          if (entry != null) ready[request.key] = entry;
        }
      }
    }
    final result = <String, CatalogItem>{};
    for (final value in ready.entries) {
      final owner = resolved[value.key];
      if (owner == null) continue;
      final entry = value.value;
      if (entry.id == owner.$2.id &&
          entry.currentRevisionId == selected[value.key] &&
          entry.availability == ContentAvailability.ready &&
          entry.currentRevision.contentHash != null) {
        result[value.key] = _item(owner.$1, entry);
      }
    }
    if (result.isNotEmpty) onMaterialized?.call();
    return result;
  }

  @override
  Future<CatalogItem?> itemForObject(String entryId) async {
    try {
      final (source, entry) = _resolve(entryId);
      if (!source.online) return null;
      return _item(source, entry);
    } on StateError {
      return null;
    }
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
