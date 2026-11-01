import 'dart:convert';
import 'dart:collection';
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
  final conflicts = <String, MergeConflict>{};
  for (final c in [...base.conflicts, ...local.conflicts, ...remote.conflicts]) {
    final prior = conflicts[c.id];
    conflicts[c.id] = prior != null && prior.kind == 'strokeOrder' && c.kind == 'strokeOrder'
        ? _unionOrderConflict(prior, c) : c;
  }
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

  final pages = <PageKey, List<PageAnnotation>>{};
  for (final page in {
    ...base.annotations.keys,
    ...local.annotations.keys,
    ...remote.annotations.keys
  }) {
    Map<String, PageAnnotation> index(ReaderSnapshot s) =>
        {for (final x in s.annotations[page] ?? <PageAnnotation>[]) x.id: x};
    final b = index(base), l = index(local), r = index(remote);
    final ids = {...b.keys, ...l.keys, ...r.keys};
    final merged = {
      for (final id in ids)
        id: PageAnnotation.fromJson(Map<String, dynamic>.from(choose(
            'stroke',
            canonicalReaderJson([page.toJson(), id]),
            b[id]?.toJson(),
            l[id]?.toJson(),
            r[id]?.toJson())!))
    };
    final before = base.annotations[page] ?? <PageAnnotation>[];
    final left = local.annotations[page] ?? <PageAnnotation>[];
    final right = remote.annotations[page] ?? <PageAnnotation>[];
    final ordered = _mergeStrokeOrder(before, left, right, ids, () {
      final knownGeometry = <String, Set<String>>{};
      void remember(Map<String, Object?> json) {
        final id = json['id'];
        if (id is String && _hasGeometry(json)) {
          knownGeometry.putIfAbsent(id, () => {}).add(_geometryKey(json));
        }
      }
      for (final stroke in merged.values) { remember(stroke.toJson()); }
      for (final prior in conflicts.values) {
        if (prior.kind == 'stroke') {
          remember(prior.first); remember(prior.second);
        } else if (prior.kind == 'strokeOrder') {
          for (final variant in [prior.first, prior.second]) {
            for (final json in variant['strokeVariants'] as List? ?? const []) {
              if (json is Map) remember(Map<String, Object?>.from(json));
            }
          }
        }
      }
      conflict('strokeOrder', canonicalReaderJson([page.toJson()]),
          _orderVariant(page, before, left, merged, knownGeometry),
          _orderVariant(page, before, right, merged, knownGeometry));
    });
    pages[page] = [for (final id in ordered) merged[id]!];
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
  _retainOrderGeometry(conflicts, pages, [base, local, remote]);
  final allConflicts = conflicts.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final snapshot = local.next(
      annotations: pages,
      setLists: mergedLists,
      bookmarks: bookmarks,
      conflicts: allConflicts,
      mergeReceipts: {
        ...local.mergeReceipts,
        if (operationId != null) operationId
      });
  return ReaderMergeResult(snapshot, snapshot.conflicts);
}


bool _hasGeometry(Map<String, Object?> value) =>
    (value['kind'] == 'text' && value['text'] is Map) ||
    (value['style'] is Map && value['points'] is List);

String _geometryKey(Map<String, Object?> stroke) => sha256
    .convert(utf8.encode(canonicalReaderJson(stroke['kind'] == 'text'
        ? ['text', stroke['text']]
        : [stroke['style'], stroke['points']])))
    .toString();

/// Order variants refer to the merged page/content conflicts, rather than
/// duplicating every sampled point. Only otherwise unavailable geometry is
/// included. Visibility and differing version counters allow either branch's
/// visual state to be reconstructed without treating clocks as order authority.
Map<String, Object?> _orderVariant(PageKey page, List<PageAnnotation> base,
    List<PageAnnotation> branch, Map<String, PageAnnotation> merged,
    Map<String, Set<String>> knownGeometry) {
  final refs = <String, String>{}, versions = <String, int>{};
  final missing = <Map<String, Object?>>[];
  for (final stroke in branch) {
    final json = stroke.toJson(), key = _geometryKey(stroke.toJson());
    refs[stroke.id] = key;
    versions[stroke.id] = stroke.version;
    if (!(knownGeometry[stroke.id]?.contains(key) ?? false)) missing.add(json);
  }
  return {
    'page': page.toJson(),
    'baseOrder': base.map((stroke) => stroke.id).toList(),
    'order': branch.map((stroke) => stroke.id).toList(),
    'deletedIds': branch.where((stroke) => stroke.isDeleted).map((stroke) => stroke.id).toList(),
    if (refs.isNotEmpty) 'geometryRefs': refs,
    if (versions.isNotEmpty) 'versions': versions,
    if (missing.isNotEmpty) 'strokeVariants': missing,
  };
}

List<String> _mergeStrokeOrder(List<PageAnnotation> base,
    List<PageAnnotation> local, List<PageAnnotation> remote,
    Set<String> ids, void Function() conflict) {
  List<String> order(List<PageAnnotation> strokes) => strokes.map((s) => s.id).toList();
  final bo = order(base), lo = order(local), ro = order(remote);
  final baseRank = {for (var i = 0; i < bo.length; i++) bo[i]: i};
  final graph = <String, Set<String>>{};
  void chain(Map<String, Set<String>> edges, List<String> sequence) {
    for (var i = 1; i < sequence.length; i++) {
      edges.putIfAbsent(sequence[i - 1], () => {}).add(sequence[i]);
    }
  }
  chain(graph, bo);
  for (final branch in [lo, ro]) {
    chain(graph, branch);
    // A branch containing no base anchor is still derived from the shared
    // ancestor; absence is not deletion. A new prefix before known base ink is
    // likewise not silently accepted as evidence that it predates that ink.
    if (bo.isNotEmpty && branch.isNotEmpty && !baseRank.containsKey(branch.first)) {
      graph.putIfAbsent(bo.last, () => {}).add(branch.first);
    }
  }
  final normal = _topologicalStrokeOrder(ids, graph);
  if (normal != null) return normal;
  conflict();

  bool compatible(List<String> branch) {
    var previous = -1;
    final anchors = branch.where(baseRank.containsKey).toList();
    if (anchors.isNotEmpty && branch.first != anchors.first) return false;
    for (final id in anchors) {
      final rank = baseRank[id]!;
      if (rank <= previous) return false;
      previous = rank;
    }
    return true;
  }
  final candidates = [lo, ro].where(compatible).toList();
  candidates.sort((a, b) {
    final anchorsA = a.where(baseRank.containsKey).length;
    final anchorsB = b.where(baseRank.containsKey).length;
    final count = anchorsB.compareTo(anchorsA);
    return count != 0 ? count : canonicalReaderJson(a).compareTo(canonicalReaderJson(b));
  });
  final primary = candidates.isEmpty ? <String>[] : candidates.first;
  final hard = <String, Set<String>>{};
  chain(hard, bo); chain(hard, primary);
  if (bo.isNotEmpty && primary.isNotEmpty && !primary.any(baseRank.containsKey)) {
    hard.putIfAbsent(bo.last, () => {}).add(primary.first);
  }
  final primaryIds = primary.toSet();
  final preference = [...primary, ...bo.where((id) => !primaryIds.contains(id))];
  final rank = {for (var i = 0; i < preference.length; i++) preference[i]: i};
  // The fallback can break only conflicting soft edges. It keeps the complete
  // base and a base-compatible branch as hard constraints, identically when
  // local/remote are exchanged. Both original orders remain in the conflict.
  return _topologicalStrokeOrder(ids, graph, hard: hard, rank: rank)!;
}

List<String>? _topologicalStrokeOrder(Set<String> ids,
    Map<String, Set<String>> graph,
    {Map<String, Set<String>>? hard, Map<String, int>? rank}) {
  final incoming = {for (final id in ids) id: 0};
  final hardIncoming = {for (final id in ids) id: 0};
  for (final targets in graph.values) {
    for (final id in targets) { incoming[id] = incoming[id]! + 1; }
  }
  for (final targets in hard?.values ?? <Set<String>>[]) {
    for (final id in targets) { hardIncoming[id] = hardIncoming[id]! + 1; }
  }
  final ready = SplayTreeSet<String>()..addAll(ids.where((id) => incoming[id] == 0));
  final hardReady = SplayTreeSet<String>((a, b) {
    final comparison = (rank?[a] ?? ids.length).compareTo(rank?[b] ?? ids.length);
    return comparison != 0 ? comparison : a.compareTo(b);
  })..addAll(ids.where((id) => hardIncoming[id] == 0));
  final result = <String>[], emitted = <String>{};
  while (result.length < ids.length) {
    if (ready.isEmpty && hard == null) return null;
    if (ready.isEmpty && hardReady.isEmpty) throw StateError('Cyclic hard stroke order');
    final id = ready.isNotEmpty ? ready.first : hardReady.first;
    ready.remove(id); hardReady.remove(id); emitted.add(id); result.add(id);
    for (final next in graph[id] ?? <String>{}) {
      if (emitted.contains(next)) continue;
      incoming[next] = incoming[next]! - 1;
      if (incoming[next] == 0) ready.add(next);
    }
    for (final next in hard?[id] ?? <String>{}) {
      if (emitted.contains(next)) continue;
      hardIncoming[next] = hardIncoming[next]! - 1;
      if (hardIncoming[next] == 0) hardReady.add(next);
    }
  }
  return result;
}


/// An order conflict can outlive the page geometry it originally referenced.
/// Pin only referenced shapes that would otherwise disappear on this merge.
/// Existing conflict IDs/orders stay immutable; one archived shape can satisfy
/// references from several conflicts without duplicating a whole page.
void _retainOrderGeometry(Map<String, MergeConflict> conflicts,
    Map<PageKey, List<PageAnnotation>> pages, List<ReaderSnapshot> inputs) {
  final referenced = <(String, String)>{};
  for (final conflict in conflicts.values.where((c) => c.kind == 'strokeOrder')) {
    for (final variant in [conflict.first, conflict.second]) {
      for (final extra in variant['geometryAlternatives'] as List? ?? const []) {
        if (extra is Map && extra['id'] is String && extra['hash'] is String) {
          referenced.add((extra['id'] as String, extra['hash'] as String));
        }
      }
      final refs = variant['geometryRefs'];
      if (refs is Map) {
        for (final entry in refs.entries) {
          if (entry.key is String && entry.value is String) {
            referenced.add((entry.key as String, entry.value as String));
          }
        }
      }
    }
  }
  if (referenced.isEmpty) return;
  final ids = referenced.map((key) => key.$1).toSet();
  final available = <(String, String)>{};
  void present(Map<String, Object?> json) {
    final id = json['id'];
    if (id is String && ids.contains(id) && _hasGeometry(json)) {
      available.add((id, _geometryKey(json)));
    }
  }
  void variants(Iterable<MergeConflict> values, void Function(Map<String, Object?>) visit) {
    for (final conflict in values) {
      if (conflict.kind == 'stroke') {
        visit(conflict.first); visit(conflict.second);
      } else if (conflict.kind == 'strokeOrder') {
        for (final variant in [conflict.first, conflict.second]) {
          for (final json in variant['strokeVariants'] as List? ?? const []) {
            if (json is Map) visit(Map<String, Object?>.from(json));
          }
        }
      }
    }
  }
  for (final strokes in pages.values) {
    for (final stroke in strokes) { if (ids.contains(stroke.id)) present(stroke.toJson()); }
  }
  variants(conflicts.values, present);
  final missing = referenced.difference(available);
  if (missing.isEmpty) return;
  final missingIds = missing.map((key) => key.$1).toSet();
  final candidates = <(String, String), Map<String, Object?>>{};
  void candidate(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || !missingIds.contains(id) || !_hasGeometry(json)) return;
    final key = (id, _geometryKey(json));
    if (!missing.contains(key)) return;
    final prior = candidates[key];
    if (prior == null || canonicalReaderJson(json).compareTo(canonicalReaderJson(prior)) < 0) candidates[key] = json;
  }
  for (final input in inputs) {
    for (final strokes in input.annotations.values) {
      for (final stroke in strokes) { if (missingIds.contains(stroke.id)) candidate(stroke.toJson()); }
    }
    variants(input.conflicts, candidate);
  }
  for (final id in conflicts.keys.toList()..sort()) {
    final conflict = conflicts[id]!;
    if (conflict.kind != 'strokeOrder') continue;
    var changed = false;
    Map<String, Object?> pin(Map<String, Object?> original) {
      final refs = original['geometryRefs'];
      if (refs is! Map) return original;
      final added = <Map<String, Object?>>[];
      final wanted = <(String, String)>{
        for (final id in refs.keys.whereType<String>()) (id, refs[id].toString()),
        for (final extra in original['geometryAlternatives'] as List? ?? const [])
          if (extra is Map && extra['id'] is String && extra['hash'] is String)
            (extra['id'] as String, extra['hash'] as String),
      }.toList()..sort((a, b) {
        final id = a.$1.compareTo(b.$1); return id != 0 ? id : a.$2.compareTo(b.$2);
      });
      for (final key in wanted) {
        if (!missing.contains(key) || candidates[key] == null) continue;
        added.add(candidates[key]!); missing.remove(key); changed = true;
      }
      if (added.isEmpty) return original;
      return {...original, 'strokeVariants': _orderedGeometryVariants([
        ...original['strokeVariants'] as List? ?? const [], ...added,
      ])};
    }
    final first = pin(conflict.first), second = pin(conflict.second);
    if (changed) conflicts[id] = MergeConflict(id: conflict.id, kind: conflict.kind,
      objectKey: conflict.objectKey, peerId: conflict.peerId, first: first, second: second);
  }
}


List<Map<String, Object?>> _orderedGeometryVariants(List values) {
  final unique = <String, Map<String, Object?>>{};
  for (final value in values) {
    if (value is! Map) continue;
    final json = Map<String, Object?>.from(value);
    if (json['id'] is! String || !_hasGeometry(json)) continue;
    final key = '${json['id']}/${_geometryKey(json)}';
    final prior = unique[key];
    if (prior == null || canonicalReaderJson(json).compareTo(canonicalReaderJson(prior)) < 0) unique[key] = json;
  }
  return [for (final key in unique.keys.toList()..sort()) unique[key]!];
}

MergeConflict _unionOrderConflict(MergeConflict a, MergeConflict b) {
  Map<String, Object?> identity(Map<String, Object?> value) => {
    for (final key in ['page', 'baseOrder', 'order', 'deletedIds']) key: value[key],
  };
  final same = canonicalReaderJson(identity(a.first)) == canonicalReaderJson(identity(b.first));
  final swapped = canonicalReaderJson(identity(a.first)) == canonicalReaderJson(identity(b.second));
  final rightFirst = !same && swapped ? b.second : b.first;
  final rightSecond = !same && swapped ? b.first : b.second;
  Map<String, Object?> unite(Map<String, Object?> x, Map<String, Object?> y) {
    final primary = canonicalReaderJson(x).compareTo(canonicalReaderJson(y)) <= 0 ? x : y;
    final refs = <String, String>{};
    final alternatives = <(String, String)>{};
    for (final value in [x, y]) {
      for (final extra in value['geometryAlternatives'] as List? ?? const []) {
        if (extra is Map && extra['id'] is String && extra['hash'] is String) alternatives.add((extra['id'] as String, extra['hash'] as String));
      }
      if (value['geometryRefs'] case final Map values) {
        for (final entry in values.entries) {
          if (entry.key is! String || entry.value is! String) continue;
          final id = entry.key as String, hash = entry.value as String, prior = refs[entry.key];
          if (prior != null && prior != hash) {
            alternatives.add((id, prior)); alternatives.add((id, hash));
          }
          refs[id] = prior == null || hash.compareTo(prior) < 0 ? hash : prior;
        }
      }
    }
    final extra = _orderedGeometryVariants([
      ...x['strokeVariants'] as List? ?? const [], ...y['strokeVariants'] as List? ?? const [],
    ]);
    final alternate = alternatives.where((key) => refs[key.$1] != key.$2).toList()
      ..sort((a, b) { final id = a.$1.compareTo(b.$1); return id != 0 ? id : a.$2.compareTo(b.$2); });
    return {...primary,
      if (refs.isNotEmpty) 'geometryRefs': refs,
      if (alternate.isNotEmpty) 'geometryAlternatives': [for (final key in alternate) {'id': key.$1, 'hash': key.$2}],
      if (extra.isNotEmpty) 'strokeVariants': extra,
    };
  }
  final primary = canonicalReaderJson(a.toJson()).compareTo(canonicalReaderJson(b.toJson())) <= 0 ? a : b;
  return MergeConflict(id: a.id, kind: a.kind, objectKey: primary.objectKey,
      peerId: primary.peerId, first: unite(a.first, rightFirst), second: unite(a.second, rightSecond));
}
