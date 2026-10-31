import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'models.dart';

String canonicalReaderJson(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sorted(v[k])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

// Versions and wall clocks are metadata, never distributed conflict authority.
Object? _semantic(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (![
          'version',
          'createdUtc',
          'updatedUtc',
          'generation',
          'mergeReceipts'
        ].contains(entry.key))
          entry.key: (entry.key == 'deletedUtc' || entry.key == 'removedUtc')
              ? entry.value != null
              : _semantic(entry.value)
    };
  }
  if (value is List) return value.map(_semantic).toList();
  return value;
}

bool _equal(Object? a, Object? b) =>
    canonicalReaderJson(_semantic(a)) == canonicalReaderJson(_semantic(b));

class ReaderMergeResult {
  const ReaderMergeResult(this.snapshot, this.conflicts);
  final ReaderSnapshot snapshot;

  /// All unresolved conflicts, including ones preserved from earlier syncs.
  final List<MergeConflict> conflicts;
}

ReaderMergeResult mergeReaderSnapshots(
    {required ReaderSnapshot base,
    required ReaderSnapshot local,
    required ReaderSnapshot remote,
    required String peerId,
    String? operationId}) {
  final conflicts = <String, MergeConflict>{
    for (final c in [
      ...base.conflicts,
      ...local.conflicts,
      ...remote.conflicts
    ])
      c.id: c
  };
  void conflict(
      String kind, String key, Map<String, Object?> a, Map<String, Object?> b) {
    final variants = [canonicalReaderJson(a), canonicalReaderJson(b)]..sort();
    final id = sha256
        .convert(utf8.encode(canonicalReaderJson([kind, key, variants])))
        .toString();
    conflicts.putIfAbsent(
        id,
        () => MergeConflict(
            id: id,
            kind: kind,
            objectKey: key,
            peerId: peerId,
            first: Map<String, Object?>.from(jsonDecode(variants[0]) as Map),
            second: Map<String, Object?>.from(jsonDecode(variants[1]) as Map)));
  }

  Map<String, Object?>? choose(String kind, String key, Map<String, Object?>? b,
      Map<String, Object?>? l, Map<String, Object?>? r) {
    // Absence never acts as a tombstone.
    if (l == null) return r ?? b;
    if (r == null) return l;
    if (_equal(l, r)) {
      return canonicalReaderJson(l).compareTo(canonicalReaderJson(r)) <= 0
          ? l
          : r;
    }
    if (_equal(l, b)) return r;
    if (_equal(r, b)) return l;
    conflict(kind, key, l, r);
    return canonicalReaderJson(l).compareTo(canonicalReaderJson(r)) <= 0
        ? l
        : r;
  }

  final pages = <PageKey, List<AnnotationStroke>>{};
  for (final page in {
    ...base.pages.keys,
    ...local.pages.keys,
    ...remote.pages.keys
  }) {
    Map<String, AnnotationStroke> index(ReaderSnapshot s) =>
        {for (final x in s.pages[page] ?? <AnnotationStroke>[]) x.id: x};
    final b = index(base), l = index(local), r = index(remote);
    final ids = {...b.keys, ...l.keys, ...r.keys}.toList()..sort();
    pages[page] = [
      for (final id in ids)
        AnnotationStroke.fromJson(Map<String, dynamic>.from(choose(
            'stroke',
            canonicalReaderJson([page.toJson(), id]),
            b[id]?.toJson(),
            l[id]?.toJson(),
            r[id]?.toJson())!))
    ];
  }

  Map<String, ScoreSetList> lists(ReaderSnapshot s) =>
      {for (final x in s.setLists) x.id: x};
  final bl = lists(base), ll = lists(local), rl = lists(remote);
  final listIds = {...bl.keys, ...ll.keys, ...rl.keys}.toList()..sort();
  final mergedLists = <ScoreSetList>[];
  for (final id in listIds) {
    final b = bl[id], l = ll[id], r = rl[id];
    if (l == null || r == null) {
      mergedLists.add(l ?? r ?? b!);
      continue;
    }
    final lj = l.toJson(), rj = r.toJson();
    final lc = !_equal(lj, b?.toJson()), rc = !_equal(rj, b?.toJson());
    final nameConflict =
        l.name != r.name && l.name != b?.name && r.name != b?.name;
    final deletionConflict = l.isDeleted != r.isDeleted && lc && rc;
    final oldOrder = b?.items.map((e) => e.id).toList() ?? <String>[];
    // Compare order only among existing IDs still present on each side;
    // appending distinct new IDs is independently mergeable.
    final shared = oldOrder
        .where((x) =>
            l.items.any((e) => e.id == x) && r.items.any((e) => e.id == x))
        .toSet();
    List<String> order(ScoreSetList? s) =>
        s?.items
            .where((e) => shared.contains(e.id))
            .map((e) => e.id)
            .toList() ??
        [];
    final bo = order(b), lo = order(l), ro = order(r);
    final lReordered = !_equal(bo, lo), rReordered = !_equal(bo, ro);
    final orderConflict = lReordered && rReordered && !_equal(lo, ro);
    if (nameConflict || deletionConflict || orderConflict) {
      conflict('setList', id, lj, rj);
    }
    final primary =
        canonicalReaderJson(lj).compareTo(canonicalReaderJson(rj)) <= 0 ? l : r;
    var representative = !lc
        ? r
        : !rc
            ? l
            : primary;
    String name;
    if (l.name == r.name || r.name == b?.name) {
      name = l.name;
    } else if (l.name == b?.name) {
      name = r.name;
    } else {
      name = primary.name;
    }
    Map<String, SetListItem> items(ScoreSetList? s) =>
        {for (final x in s?.items ?? <SetListItem>[]) x.id: x};
    final bi = items(b), li = items(l), ri = items(r);
    final itemIds = {...bi.keys, ...li.keys, ...ri.keys}.toList()..sort();
    final merged = {
      for (final itemId in itemIds)
        itemId: SetListItem.fromJson(Map<String, dynamic>.from(choose(
            'setListItem',
            '$id/$itemId',
            bi[itemId]?.toJson(),
            li[itemId]?.toJson(),
            ri[itemId]?.toJson())!))
    };
    final preferred = orderConflict || (lReordered && rReordered)
        ? primary
        : lReordered
            ? l
            : rReordered
                ? r
                : representative;
    final ordered = <String>[...preferred.items.map((x) => x.id)];
    ordered.addAll(itemIds.where((x) => !ordered.contains(x)));
    mergedLists.add(ScoreSetList(
        id: id,
        name: name,
        items: ordered.map((x) => merged[x]!).toList(),
        createdUtc: representative.createdUtc,
        updatedUtc: representative.updatedUtc,
        version: representative.version,
        deletedUtc: representative.deletedUtc));
  }
  final bookmarks = <DocumentKey, ReadingBookmark>{};
  for (final key in {
    ...base.bookmarks.keys,
    ...local.bookmarks.keys,
    ...remote.bookmarks.keys
  }) {
    bookmarks[key] = ReadingBookmark.fromJson(Map<String, dynamic>.from(choose(
        'bookmark',
        canonicalReaderJson(key.toJson()),
        base.bookmarks[key]?.toJson(),
        local.bookmarks[key]?.toJson(),
        remote.bookmarks[key]?.toJson())!));
  }
  final allConflicts = conflicts.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final snapshot = local.next(
      pages: pages,
      setLists: mergedLists,
      bookmarks: bookmarks,
      conflicts: allConflicts,
      mergeReceipts: {
        ...local.mergeReceipts,
        if (operationId != null) operationId
      });
  return ReaderMergeResult(snapshot, snapshot.conflicts);
}
