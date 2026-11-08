import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;

import 'page_metadata.dart';
import 'storage.dart';

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
String songbookItemSignature(String title, int? page, List<String> ancestors) =>
    _digest([title.trim(), page, ancestors]);

/// All destinations use actual, one-based PDF pages. A null page is a heading.
class SongbookItem {
  SongbookItem(
      {required this.id,
      required this.title,
      required this.pageNumber,
      this.ancestors = const [],
      this.manual = false,
      this.needsReview = false,
      this.sourceSignature,
      this.modified = 0});
  final String id, title;
  final int? pageNumber;
  final List<String> ancestors;
  final bool manual, needsReview;
  final String? sourceSignature;
  final int modified;
  late final PreparedSearchText _searchText =
      PreparedSearchText([...ancestors, title].join(' / '));
  bool get canNavigate => pageNumber != null && !needsReview;
  SongbookItem copyWith(
          {String? title,
          int? pageNumber,
          bool? needsReview,
          bool? manual,
          int? modified}) =>
      SongbookItem(
          id: id,
          title: title ?? this.title,
          pageNumber: pageNumber ?? this.pageNumber,
          ancestors: ancestors,
          manual: manual ?? this.manual,
          needsReview: needsReview ?? this.needsReview,
          sourceSignature: sourceSignature,
          modified: modified ?? this.modified);
  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'page': pageNumber,
        'ancestors': ancestors,
        'manual': manual,
        'needsReview': needsReview,
        'sourceSignature': sourceSignature,
        'modified': modified
      };
  factory SongbookItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'],
        title = json['title'],
        page = json['page'],
        parents = json['ancestors'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 2048 ||
        (page != null && (page is! int || page < 1 || page > 100000)) ||
        parents is! List ||
        parents.length > 64 ||
        parents.any((e) => e is! String || e.length > 2048) ||
        json['modified'] is! int ||
        (json['modified'] as int) < 0 ||
        (json['sourceSignature'] != null &&
            (json['sourceSignature'] is! String ||
                (json['sourceSignature'] as String).length > 128))) {
      throw const FormatException('Invalid songbook item.');
    }
    return SongbookItem(
        id: id,
        title: title,
        pageNumber: page as int?,
        ancestors: List<String>.unmodifiable(parents),
        manual: json['manual'] == true,
        needsReview: json['needsReview'] == true,
        modified: json['modified'] as int,
        sourceSignature: json['sourceSignature'] as String?);
  }
}

class SongbookIndex {
  SongbookIndex(
      {required this.key,
      required this.items,
      this.pageCount,
      this.extracted = false,
      this.outlineModified = 0,
      this.modified = 0});
  final PageMetadataKey key;
  final List<SongbookItem> items;
  final int? pageCount;
  final bool extracted;
  final int outlineModified;
  final int modified;
  String get digest => _digest(toJson());
  Map<String, Object?> toJson() => {
        ...key.toJson(),
        'items': items.map((e) => e.toJson()).toList(),
        'pages': pageCount,
        'extracted': extracted,
        'outlineModified': outlineModified,
        'modified': modified
      };
  factory SongbookIndex.fromJson(Map<String, dynamic> json) {
    final items = json['items'],
        pages = json['pages'],
        modified = json['modified'];
    if (items is! List ||
        items.length > 10000 ||
        (pages != null && (pages is! int || pages < 1 || pages > 100000)) ||
        modified is! int ||
        modified < 0 ||
        (json['outlineModified'] != null &&
            (json['outlineModified'] is! int ||
                (json['outlineModified'] as int) < 0))) {
      throw const FormatException('Invalid songbook index.');
    }
    final parsed = items.map((e) => SongbookItem.fromJson(asMap(e))).toList();
    if (parsed.map((e) => e.id).toSet().length != parsed.length) {
      throw const FormatException('Duplicate songbook item identity.');
    }
    return SongbookIndex(
        key: PageMetadataKey.fromJson(json),
        items: List.unmodifiable(parsed.map((e) => pages != null &&
                e.pageNumber != null &&
                e.pageNumber! > (pages as int)
            ? e.copyWith(needsReview: true)
            : e)),
        pageCount: pages as int?,
        extracted: json['extracted'] == true,
        outlineModified: json['outlineModified'] as int? ?? 0,
        modified: modified);
  }
}

class SongbookSearchHit {
  const SongbookSearchHit(this.key, this.item);
  final PageMetadataKey key;
  final SongbookItem item;
}

List<SongbookSearchHit> searchSongbooks(
    Iterable<SongbookIndex> indexes, String query,
    {PageMetadataKey? key, int limit = 100}) {
  final compiled = SearchQuery(query);
  if (query.trim().isEmpty || limit < 1) return [];
  final hits = <SongbookSearchHit>[];
  for (final index in indexes) {
    if (key != null && index.key != key) continue;
    for (final item in index.items) {
      // File names and source paths deliberately never enter this search text.
      if (compiled.matches(item._searchText)) {
        hits.add(SongbookSearchHit(index.key, item));
        if (hits.length >= limit) return hits;
      }
    }
  }
  return hits;
}

/// Durable metadata only: opening this store never opens a score or rasterizes PDF.
/// The application opens it and runs broad search in a background isolate.
class SongbookStore {
  SongbookStore._(this.directory);
  final String directory;
  final _indexes = <PageMetadataKey, SongbookIndex>{};
  final _sequences = <PageMetadataKey, int>{};
  int _sequence = 0;
  String _epoch = randomId(12);
  Future<void> _writes = Future.value();
  Iterable<SongbookIndex> get indexes => _indexes.values;
  int get sequence => _sequence;
  SongbookIndex? get(PageMetadataKey key) => _indexes[key];
  static Future<SongbookStore> open(String directory) async {
    final store = SongbookStore._(directory);
    await Directory(directory).create(recursive: true);
    final manifest = await readJson(p.join(directory, 'manifest.json'));
    if (manifest != null) {
      store._sequence = manifest['sequence'] as int;
      store._epoch = manifest['epoch'] as String;
    }
    // Only metadata that has actually been built/synced, never the score library.
    final records = <String>{};
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(r'^[a-f0-9]{64}\.json(?:\.backup)?$')
              .hasMatch(p.basename(entity.path))) continue;
      records.add(entity.path.replaceFirst(RegExp(r'\.backup$'), ''));
    }
    for (final path in records) {
      final record = await readJson(path);
      if (record == null) continue;
      final index = SongbookIndex.fromJson(asMap(record['index']));
      store._indexes[index.key] = index;
      final sequence = record['sequence'] as int;
      store._sequences[index.key] = sequence;
      if (sequence > store._sequence) store._sequence = sequence;
    }
    return store;
  }

  Future<T> _write<T>(Future<T> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<bool> put(SongbookIndex index) => _write(() async {
        if (utf8.encode(jsonEncode(index.toJson())).length > 3 * 1024 * 1024) {
          throw const FormatException(
              'Songbook index exceeds metadata budget.');
        }
        index =
            SongbookIndex.fromJson(Map<String, dynamic>.from(index.toJson()));
        if (_indexes[index.key]?.digest == index.digest) return false;
        final sequence = _sequence + 1;
        final path = p.join(directory, '${_digest(index.key.toJson())}.json');
        assertSafePath(directory, path);
        await writeJson(path, {'sequence': sequence, 'index': index.toJson()});
        _indexes[index.key] = index;
        _sequences[index.key] = sequence;
        _sequence = sequence;
        await writeJson(p.join(directory, 'manifest.json'),
            {'epoch': _epoch, 'sequence': _sequence});
        return true;
      });

  Future<SongbookIndex> saveItem(PageMetadataKey key,
      {String? itemId,
      required String title,
      required int pageNumber,
      List<String> ancestors = const []}) async {
    title = title.trim();
    final old = get(key);
    if (title.isEmpty ||
        title.length > 2048 ||
        pageNumber < 1 ||
        pageNumber > 100000 ||
        (old?.pageCount != null && pageNumber > old!.pageCount!)) {
      throw ArgumentError('请输入曲名及有效的实际PDF页码。');
    }
    final items = [...?old?.items];
    final selected =
        itemId == null ? -1 : items.indexWhere((e) => e.id == itemId);
    if (itemId != null && selected < 0) throw StateError('目录项已经改变，请重新选择。');
    final duplicate = items.indexWhere(
        (e) => e.title.trim() == title && e.pageNumber == pageNumber);
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final base = selected >= 0
        ? items[selected]
        : duplicate >= 0
            ? items[duplicate]
            : null;
    final item = SongbookItem(
        id: base?.id ??
            'm-${songbookItemSignature(title, pageNumber, ancestors)}',
        title: title,
        pageNumber: pageNumber,
        ancestors: base?.ancestors ?? ancestors,
        manual: true,
        needsReview: false,
        sourceSignature: base?.sourceSignature,
        modified: now);
    if (selected >= 0) {
      items[selected] = item;
      if (duplicate >= 0 && duplicate != selected) items.removeAt(duplicate);
    } else if (duplicate >= 0) {
      items[duplicate] = item;
    } else {
      items.add(item);
    }
    final result = SongbookIndex(
        key: key,
        items: List.unmodifiable(items),
        pageCount: old?.pageCount,
        extracted: old?.extracted ?? false,
        outlineModified: old?.outlineModified ?? 0,
        modified: now);
    await put(result);
    return result;
  }

  /// A new revision carries manual work as unverified; it never inherits the old
  /// revision's successful extraction bit or assumes page offsets are unchanged.
  Future<SongbookIndex?> carryManual(PageMetadataKey key) async {
    if (get(key) != null) return get(key);
    final previous = indexes.where((e) => e.key.entryId == key.entryId).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    if (previous.isEmpty) return null;
    final items = previous.first.items
        .where((e) => e.manual)
        .map((e) => e.copyWith(needsReview: true))
        .toList();
    if (items.isEmpty) return null;
    final result = SongbookIndex(
        key: key,
        items: List.unmodifiable(items),
        modified: previous.first.modified);
    await put(result);
    return result;
  }

  Future<SongbookIndex> mergeOutline(
      PageMetadataKey key, int pages, List<SongbookItem> native) async {
    final old = get(key);
    final manual =
        old?.items.where((e) => e.manual).toList() ?? <SongbookItem>[];
    final protected =
        manual.map((e) => e.sourceSignature).whereType<String>().toSet();
    final items = <SongbookItem>[];
    for (final item in native) {
      if (protected.contains(item.sourceSignature) ||
          manual.any(
              (e) => e.title == item.title && e.pageNumber == item.pageNumber))
        continue;
      if (items
          .any((e) => e.title == item.title && e.pageNumber == item.pageNumber))
        continue;
      items.add(item.copyWith(
          needsReview: item.pageNumber != null && item.pageNumber! > pages));
    }
    items.addAll(manual.map((e) => e.pageNumber != null && e.pageNumber! > pages
        ? e.copyWith(needsReview: true)
        : e));
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final result = SongbookIndex(
        key: key,
        items: List.unmodifiable(items),
        pageCount: pages,
        extracted: true,
        outlineModified: now,
        modified: now);
    await put(result);
    return result;
  }

  /// Per-item deterministic last edit wins; independent manual additions merge.
  Future<bool> mergeRemote(SongbookIndex incoming) async {
    final local = get(incoming.key);
    if (local == null) return put(incoming);
    final nativeBase = incoming.outlineModified > local.outlineModified ||
            incoming.outlineModified == local.outlineModified &&
                incoming.digest.compareTo(local.digest) > 0
        ? incoming
        : local;
    final chosen = <String, SongbookItem>{
      for (final e in nativeBase.items) e.id: e
    };
    for (final item in [
      ...local.items.where((e) => e.manual),
      ...incoming.items.where((e) => e.manual)
    ]) {
      final prior = chosen[item.id];
      if (prior == null ||
          item.manual && !prior.manual ||
          item.manual == prior.manual &&
              (item.modified > prior.modified ||
                  item.modified == prior.modified &&
                      jsonEncode(item.toJson())
                              .compareTo(jsonEncode(prior.toJson())) >
                          0)) chosen[item.id] = item;
    }
    final order = <String>{
      ...nativeBase.items.map((e) => e.id),
      ...chosen.keys
    };
    final items = order.map((id) => chosen[id]!).toList();
    // Suppress native originals of manually edited embedded entries on all peers.
    final protected = items
        .where((e) => e.manual)
        .map((e) => e.sourceSignature)
        .whereType<String>()
        .toSet();
    items
        .removeWhere((e) => !e.manual && protected.contains(e.sourceSignature));
    final dedup = <String, SongbookItem>{};
    for (final item in items) {
      final signature =
          songbookItemSignature(item.title, item.pageNumber, item.ancestors);
      final prior = dedup[signature];
      if (prior == null ||
          item.manual && !prior.manual ||
          item.modified > prior.modified) dedup[signature] = item;
    }
    return put(SongbookIndex(
        key: incoming.key,
        items: List.unmodifiable(dedup.values),
        pageCount:
            nativeBase.pageCount ?? local.pageCount ?? incoming.pageCount,
        extracted: local.extracted || incoming.extracted,
        outlineModified: nativeBase.outlineModified,
        modified: incoming.modified > local.modified
            ? incoming.modified
            : local.modified));
  }

  /// Cursor covers this metadata store only. Empty unchanged pages are O(known
  /// metadata), require no PDF access, and carry no file objects or ink state.
  Map<String, Object?> changes(String? cursor, {int limit = 8}) {
    final parts = cursor?.split(':');
    final after = parts?.length == 2 && parts!.first == _epoch
        ? int.tryParse(parts.last) ?? 0
        : 0;
    final keys = _sequences.keys
        .where((key) => _sequences[key]! > after)
        .toList()
      ..sort((a, b) => _sequences[a]!.compareTo(_sequences[b]!));
    final page = <PageMetadataKey>[];
    var bytes = 0;
    for (final key in keys.take(limit)) {
      final size = utf8.encode(jsonEncode(_indexes[key]!.toJson())).length;
      if (page.isNotEmpty && bytes + size > 3 * 1024 * 1024) break;
      page.add(key);
      bytes += size;
    }
    final sequence = page.isEmpty ? _sequence : _sequences[page.last]!;
    return {
      'cursor': '$_epoch:$sequence',
      'more': keys.length > page.length,
      'items': page.map((key) => _indexes[key]!.toJson()).toList()
    };
  }
}
