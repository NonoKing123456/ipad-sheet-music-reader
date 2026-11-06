import 'dart:convert';

import 'collection.dart';
import 'storage.dart';

/// Providers expose a cheap publication stamp, independent of library size.
/// The stamp must change for entries, sources, folders and online status.
abstract interface class CollectionVersionSource {
  String get catalogVersion;
}

bool sameCatalogItem(CatalogItem a, CatalogItem b) =>
    a.sourceId == b.sourceId &&
    a.entryId == b.entryId &&
    a.revisionId == b.revisionId &&
    a.relativePath == b.relativePath &&
    a.length == b.length &&
    a.format == b.format &&
    a.hash == b.hash &&
    a.missing == b.missing;

class CollectionDelta {
  CollectionDelta(
      {required this.collectionId,
      required this.fromCursor,
      required this.cursor,
      required this.upserts,
      required this.removed,
      required this.sources,
      required this.folders,
      this.legacyLibraryId});
  final String collectionId, fromCursor, cursor;
  final String? legacyLibraryId;
  final List<CatalogItem> upserts;
  final Set<String> removed;
  final List<LibrarySourceInfo> sources;
  final Map<String, List<String>> folders;
  factory CollectionDelta.between(CollectionIndex before, CollectionIndex after,
          String from, String cursor) =>
      CollectionDelta(
          collectionId: after.id,
          legacyLibraryId: after.legacyLibraryId,
          fromCursor: from,
          cursor: cursor,
          sources: after.sources,
          folders: after.folders,
          upserts: [
            for (final item in after.entries)
              if (before.entry(item.entryId) == null ||
                  !sameCatalogItem(before.entry(item.entryId)!, item))
                item
          ],
          removed: {
            for (final item in before.entries)
              if (after.entry(item.entryId) == null) item.entryId
          });
  Map<String, Object?> toJson() => {
        'protocol': 1,
        'collectionId': collectionId,
        'legacyLibraryId': legacyLibraryId,
        'fromCursor': fromCursor,
        'cursor': cursor,
        'upserts': upserts.map((e) => e.toJson()).toList(),
        'removed': removed.toList(),
        'sources': sources.map((s) => s.toJson()).toList(),
        'folders': folders
      };
  factory CollectionDelta.fromJson(Map<String, dynamic> j) {
    if (j['protocol'] != 1) throw const FormatException('Invalid delta.');
    final delta = CollectionDelta(
        collectionId: j['collectionId'] as String,
        legacyLibraryId: j['legacyLibraryId'] as String?,
        fromCursor: j['fromCursor'] as String,
        cursor: j['cursor'] as String,
        upserts: (j['upserts'] as List)
            .map((e) => CatalogItem.fromJson(asMap(e)))
            .toList(),
        removed: (j['removed'] as List).cast<String>().toSet(),
        sources: (j['sources'] as List)
            .map((s) => LibrarySourceInfo.fromJson(asMap(s)))
            .toList(),
        folders: asMap(j['folders'])
            .map((k, v) => MapEntry(k, (v as List).cast<String>())));
    if (delta.cursor.isEmpty ||
        delta.cursor.length > 128 ||
        delta.fromCursor.length > 128 ||
        delta.upserts.length + delta.removed.length > 250000 ||
        delta.upserts.map((e) => e.entryId).toSet().length !=
            delta.upserts.length ||
        delta.upserts.any((e) => delta.removed.contains(e.entryId))) {
      throw const FormatException('Invalid delta identities.');
    }
    return delta;
  }
}

class CollectionRefreshResult {
  const CollectionRefreshResult(this.changedEntryIds,
      {this.fullFallback = false, this.unchanged = false});
  final Set<String> changedEntryIds;
  final bool fullFallback, unchanged;
}

/// One durable metadata checkpoint includes its cursor and bounded journal.
/// Only changed publications are diffed; head polls never encode/hash snapshots.
class CollectionChangeJournal {
  CollectionChangeJournal(this.path);
  final String path;
  CollectionIndex? _index;
  String? _version;
  String _cursor = '';
  final _history = <CollectionDelta>[];
  bool _loaded = false;
  String get cursor => _cursor;
  CollectionIndex get index => _index!;

  Future<void> refresh(CollectionLibrarySource source) async {
    if (!_loaded) {
      _loaded = true;
      try {
        final stored = await readJson(path);
        if (stored != null && stored['schema'] == 1) {
          _index = CollectionIndex.fromJson(asMap(stored['index']));
          _version = stored['version'] as String?;
          _cursor = stored['cursor'] as String;
          _history.addAll((stored['history'] as List)
              .map((e) => CollectionDelta.fromJson(asMap(e))));
        }
      } on FormatException {
        _index = null;
        _history.clear();
      }
    }
    final version = source is CollectionVersionSource
        ? (source as CollectionVersionSource).catalogVersion
        : null;
    if (version != null && _index != null && version == _version) return;
    final next = await source.index();
    // Providers without a lightweight stamp retain legacy full-catalogue behavior.
    if (version == null &&
        _index != null &&
        jsonEncode(_index!.toJson()) == jsonEncode(next.toJson())) return;
    final cursor = randomId();
    final history = <CollectionDelta>[..._history];
    if (_index != null && _index!.id == next.id) {
      final delta = CollectionDelta.between(_index!, next, _cursor, cursor);
      if (utf8.encode(jsonEncode(delta.toJson())).length <= 512 * 1024) {
        history.add(delta);
      } else {
        history.clear();
      }
    } else {
      history.clear();
    }
    while (history.length > 32 ||
        utf8
                .encode(jsonEncode(history.map((d) => d.toJson()).toList()))
                .length >
            4 * 1024 * 1024) {
      history.removeAt(0);
    }
    await writeJson(path, {
      'schema': 1,
      'version': version,
      'cursor': cursor,
      'index': next.toJson(),
      'history': history.map((d) => d.toJson()).toList()
    });
    _index = next;
    _version = version;
    _cursor = cursor;
    _history
      ..clear()
      ..addAll(history);
  }

  CollectionDelta? changes(String since) {
    if (since == _cursor)
      return CollectionDelta(
          collectionId: index.id,
          legacyLibraryId: index.legacyLibraryId,
          fromCursor: since,
          cursor: cursor,
          upserts: [],
          removed: {},
          sources: index.sources,
          folders: index.folders);
    final start = _history.indexWhere((d) => d.fromCursor == since);
    if (start < 0) return null;
    final upserts = <String, CatalogItem>{}, removed = <String>{};
    var expected = since;
    for (final delta in _history.skip(start)) {
      if (delta.fromCursor != expected) return null;
      for (final id in delta.removed) {
        upserts.remove(id);
        removed.add(id);
      }
      for (final item in delta.upserts) {
        removed.remove(item.entryId);
        upserts[item.entryId] = item;
      }
      expected = delta.cursor;
    }
    final result = CollectionDelta(
        collectionId: index.id,
        legacyLibraryId: index.legacyLibraryId,
        fromCursor: since,
        cursor: cursor,
        upserts: upserts.values.toList(),
        removed: removed,
        sources: index.sources,
        folders: index.folders);
    return utf8.encode(jsonEncode(result.toJson())).length > 512 * 1024
        ? null
        : result;
  }
}
