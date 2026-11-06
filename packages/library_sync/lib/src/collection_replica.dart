import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'collection.dart';
import 'collection_delta.dart';
import 'replica.dart';
import 'storage.dart';

class _CollectionPersistRequest {
  const _CollectionPersistRequest(this.path, this.index, this.resolved,
      this.selection, this.verified, this.readable, this.cursor, this.cursorOwner, this.pending);
  final String path;
  final CollectionIndex index;
  final Map<String, CatalogItem> resolved;
  final OfflineSelection selection;
  final Map<String, dynamic> verified;
  final List<CatalogItem> readable;
  final String? cursor, cursorOwner;
  final Set<String> pending;
  Future<CollectionIndex> call() async {
    final next = resolved.isEmpty
        ? index
        : CollectionIndex(
            id: index.id,
            legacyLibraryId: index.legacyLibraryId,
            sources: index.sources,
            folders: index.folders,
            entries: [for (final e in index.entries) resolved[e.entryId] ?? e]);
    await writeJson(path, {
      'schema': 2,
      'index': next.toJson(),
      'selection': selection.toJson(),
      'verified': verified,
      'readable': readable.map((e) => e.toJson()).toList(),
      'deltaCursor': cursor, 'deltaOwner': cursorOwner, 'deltaPending': pending.toList()
    });
    next.entry(''); // Build the immutable lookup before transferring it back.
    return next;
  }
}

class _CollectionDirectoryRequest {
  const _CollectionDirectoryRequest(
      this.sources, this.items, this.readable, this.ready);
  final List<LibrarySourceInfo> sources;
  final List<CatalogItem> items;
  final Map<String, CatalogItem> readable;
  final Set<String> ready;
  CollectionDirectoryIndex call() =>
      CollectionDirectoryIndex(sources, items, readable, ready);
}

class _CachedCollectionOpenRequest {
  const _CachedCollectionOpenRequest(this.rootDirectory);
  final String rootDirectory;
  Future<ReplicaCollectionView> call() async {
    final objects = await ReplicaLibraryView.open(
        rootDirectory: rootDirectory, deferVerification: true);
    return ReplicaCollectionView.open(objects, deferVerification: true);
  }
}

/// The v1 complete-manifest contract stays unchanged. This additive index can
/// commit metadata while only a selected subset has verified local objects.
class ReplicaCollectionView {
  ReplicaCollectionView._(this.objects);
  final ReplicaLibraryView objects;
  CollectionIndex? index;
  OfflineSelection selection = const OfflineSelection();
  String? deltaCursor, deltaOwner;
  final _deltaPending = <String>{};
  Set<String> get pendingDeltaEntryIds => Set.unmodifiable(_deltaPending);

  /// Clear only after the corresponding objects have been atomically received.
  void completeDeltaEntries(Iterable<String> ids) {
    for (final id in ids) { if (_deltaPending.remove(id)) { _dirty = true; _deltaTouched.add(id); } }
  }
  final _ready = <String>{};
  final _resolved = <String, CatalogItem>{};
  final _readable = <String, CatalogItem>{};
  bool _dirty = false;
  LibrarySnapshot? _snapshot;
  CollectionDirectoryIndex? _directory;
  final _displayEntries = <String, LibraryEntry>{};
  int contentRevision = 0;
  List<CatalogItem> _pendingVerification = const [];
  int _verificationCursor = 0, _verificationEpoch = 0;
  bool get backgroundVerificationPending =>
      _verificationCursor < _pendingVerification.length;
  bool get hasPendingPersistence => _dirty;
  CollectionDirectoryIndex get directory =>
      _directory ??= _directoryRequest().call();
  _CollectionDirectoryRequest _directoryRequest() =>
      _CollectionDirectoryRequest(
          index?.sources ?? const [],
          currentItems.toList(growable: false),
          Map.of(_readable),
          Set.of(_ready));
  Future<void> _prepareDirectory() async {
    final request = _directoryRequest();
    _directory = await Isolate.run(request.call);
  }

  final _deltaTouched = <String>{};
  int _deltaJournalBytes = 0, _deltaJournalRecords = 0;
  int metadataDeltaBytesWritten = 0, metadataCheckpoints = 0;
  String get _deltaJournalPath => p.join(objects.rootDirectory, 'collection-delta-v1.log');
  int _generation = 0;
  int _journalBytes = 0;
  final _durableResolutions = <String, String>{};
  int metadataJournalFlushes = 0;
  String _resolutionKey(CatalogItem item) => jsonEncode(item.toJson());
  bool persistenceFailed = false;
  String get _path => p.join(objects.rootDirectory, 'collection-v2.json');
  String get _journalPath =>
      p.join(objects.rootDirectory, 'selected-resolutions-v2.log');
  bool isReady(CatalogItem item) {
    final readable = _readable[item.entryId];
    return _ready.contains('${item.entryId}/${item.revisionId}/${item.hash}') &&
      readable != null && readable.revisionId == item.revisionId &&
      readable.hash == item.hash && readable.length == item.length && readable.format == item.format;
  }

  /// Current metadata in one pass, including journal resolutions. Unlike a
  /// repeated itemFor lookup this does not search the full index for every row.
  Iterable<CatalogItem> get currentItems sync* {
    for (final original in index?.entries ?? <CatalogItem>[]) {
      yield _resolved[original.entryId] ?? original;
    }
  }

  /// Restore the last durable directory and verified identities in a worker.
  /// No object leaf is inspected before publication. Unknown files stay deferred,
  /// and validateForRead remains mandatory even for restored ready entries.
  static Future<ReplicaCollectionView> restoreCached(
          {required String rootDirectory}) =>
      Isolate.run(_CachedCollectionOpenRequest(rootDirectory).call);

  static Future<ReplicaCollectionView> open(ReplicaLibraryView objects,
      {bool deferVerification = false}) async {
    final view = ReplicaCollectionView._(objects);
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      final stored = await readJson(view._path);
      if (stored != null) {
        if (stored['schema'] != 2)
          throw const FormatException('Unsupported collection replica.');
        view.index = CollectionIndex.fromJson(asMap(stored['index']));
        view.selection = OfflineSelection.fromJson(stored['selection'] as List);
        view.deltaCursor = stored['deltaCursor'] as String?;
        view.deltaOwner = stored['deltaOwner'] as String?;
        view._deltaPending.addAll((stored['deltaPending'] as List? ?? const []).cast<String>());
        final verificationBefore = objects.verificationRevision;
        objects.restoreVerificationCache(asMap(stored['verified'] ?? {}));
        view._dirty = objects.verificationRevision != verificationBefore;
        final owners = {
          for (final e in view.index!.entries) e.entryId: e.sourceId
        };
        for (final raw in stored['readable'] as List? ?? const []) {
          final item = CatalogItem.fromJson(asMap(raw));
          if (owners[item.entryId] == item.sourceId && item.hash != null) {
            view._readable[item.entryId] = item;
          }
        }
      } else if (objects.manifest case final old?) {
        view._dirty = true; // The legacy migration has not been persisted yet.
        view.index = CollectionIndex(
            id: old.libraryId,
            legacyLibraryId: old.libraryId,
            sources: const [
              LibrarySourceInfo('legacy', '原谱库', online: false)
            ],
            entries: [
              for (final e in old.entries)
                CatalogItem(
                    sourceId: 'legacy',
                    entryId: e.entryId,
                    revisionId: e.revisionId,
                    relativePath: e.relativePath,
                    length: e.length,
                    format: e.format,
                    hash: e.hash,
                    missing: e.missing)
            ],
            folders: {
              'legacy': old.folders
            });
        view.selection = OfflineSelection(
            [OfflineRule(sourceId: 'legacy', folder: '', selected: true)]);
        if (deferVerification) {
          for (final item in view.index!.entries) {
            if (!item.missing && objects.hasCachedVerification(item.object)) {
              view._readable[item.entryId] = item;
            }
          }
        }
      }
      await view._replayDeltaJournal();
      await view._replayJournal();
      if (deferVerification) {
        view._restoreCachedReady();
        view._directory = view._directoryRequest().call();
        view.index?.entry(''); // Transfer the lookup with the worker result.
      } else {
        await view.refreshReady();
      }
      if (!deferVerification && view.index != null && view._dirty) {
        try {
          await view._persist();
        } on FileSystemException {
          view.persistenceFailed = true;
        }
      }
      return view;
    } finally {
      await lease.close();
    }
  }

  void _restoreCachedReady() {
    final prior = Map<String, CatalogItem>.from(_readable);
    _readable.clear();
    final pending = <CatalogItem>[];
    for (final current in currentItems) {
      final old = prior[current.entryId];
      if (current.missing) {
        if (old != null) _readable[current.entryId] = old;
        continue;
      }
      if (current.hash != null) pending.add(current);
      if (old != null &&
          old.sourceId == current.sourceId &&
          old.hash != null &&
          !(old.revisionId == current.revisionId &&
              old.hash == current.hash &&
              (old.length != current.length || old.format != current.format)) &&
          objects.hasCachedVerification(old.object)) {
        _readable[current.entryId] = old;
        _ready.add(_readyKey(old));
      } else if (old != null) {
        _dirty = true;
      }
    }
    _pendingVerification = pending;
  }

  String _readyKey(CatalogItem item) =>
      '${item.entryId}/${item.revisionId}/${item.hash}';

  void _cancelPendingVerification() {
    _verificationEpoch++;
    _pendingVerification = const [];
    _verificationCursor = 0;
  }

  /// At most [limit] current objects plus their previous-readable fallbacks.
  /// This does not hold a metadata lease across I/O: a foreground sync may start
  /// at any await. Its identity epoch invalidates the entire stale batch before
  /// publication. Fingerprints are keyed by immutable object identity.
  /// Only changed rows update directory counters; persistence is coalesced by
  /// the owner after the recovery pass, never once per batch.
  Future<bool> verifyNextBatch(
      {int limit = 32, SyncCancellation? cancellation}) async {
    if (limit < 1 || limit > 64) throw ArgumentError.value(limit, 'limit');
    cancellation?.check();
    if (!backgroundVerificationPending) return false;
    final epoch = _verificationEpoch;
    final end =
        (_verificationCursor + limit).clamp(0, _pendingVerification.length);
    final candidates = _pendingVerification.sublist(_verificationCursor, end);
    final verificationBefore = objects.verificationRevision;
    try {
      final verified = await objects.verifyObjects(
          [for (final item in candidates) item.object],
          cancellation: cancellation, preserveOnIoError: true);
      if (epoch != _verificationEpoch) return false;
      cancellation?.check();
      final fallbacks = <CatalogItem>[];
      for (var i = 0; i < candidates.length; i++) {
        final item = candidates[i];
        final old = _readable[item.entryId];
        if (!verified[i] && old != null && !_sameItem(old, item)) {
          fallbacks.add(old);
        }
      }
      final fallbackVerified = await objects.verifyObjects(
          [for (final item in fallbacks) item.object],
          cancellation: cancellation, preserveOnIoError: true);
      if (epoch != _verificationEpoch) return false;
      cancellation?.check();
      final fallbackById = {
        for (var i = 0; i < fallbacks.length; i++)
          if (fallbackVerified[i]) fallbacks[i].entryId: fallbacks[i]
      };
      for (var i = 0; i < candidates.length; i++) {
        final item = candidates[i];
        if (!_sameItem(itemFor(item.entryId), item)) continue;
        final before = _readable[item.entryId];
        final next = verified[i] ? item : fallbackById[item.entryId];
        if (next == null ? before == null : _sameItem(before, next)) continue;
        if (before != null) _ready.remove(_readyKey(before));
        if (next == null) {
          _readable.remove(item.entryId);
        } else {
          _readable[item.entryId] = next;
          _ready.add(_readyKey(next));
        }
        if (next == null && selection.includes(item)) _deltaPending.add(item.entryId);
        else if (next != null && _sameItem(next,item)) completeDeltaEntries([item.entryId]);
        _dirty = true;
        // A cached full snapshot is invalidated once, not cloned for every row.
        _snapshot = null;
        _contentChanged(item);
      }
      _verificationCursor = end;
      return backgroundVerificationPending;
    } finally {
      // Earlier objects may have refreshed fingerprints before a later read
      // failed or foreground work cancelled this uncommitted batch.
      if (objects.verificationRevision != verificationBefore) _dirty = true;
    }
  }

  Future<void> refreshReady() async {
    _cancelPendingVerification();
    final verificationBefore = objects.verificationRevision;
    _ready.clear();
    final prior = Map<String, CatalogItem>.from(_readable);
    _readable.clear();
    final items = currentItems.toList(growable: false);
    final candidates = [
      for (final item in items)
        if (!item.missing && item.hash != null) item
    ];
    final verified = await objects
        .verifyObjects([for (final item in candidates) item.object]);
    for (var i = 0; i < candidates.length; i++) {
      if (verified[i]) _readable[candidates[i].entryId] = candidates[i];
    }
    final fallbacks = <CatalogItem>[];
    for (final item in items) {
      if (item.missing) {
        if (prior[item.entryId] case final old?) _readable[item.entryId] = old;
        continue;
      }
      final old = prior[item.entryId];
      if (!_readable.containsKey(item.entryId) &&
          old != null &&
          old.sourceId == item.sourceId &&
          old.hash != null &&
          (old.revisionId != item.revisionId ||
              old.hash != item.hash ||
              old.length != item.length ||
              old.format != item.format)) {
        fallbacks.add(old);
      }
    }
    final fallbackVerified = await objects
        .verifyObjects([for (final item in fallbacks) item.object]);
    for (var i = 0; i < fallbacks.length; i++) {
      if (fallbackVerified[i]) _readable[fallbacks[i].entryId] = fallbacks[i];
    }
    for (final item in items.where((item) => !item.missing)) {
      final readable = _readable[item.entryId];
      if (readable != null)
        _ready
            .add('${readable.entryId}/${readable.revisionId}/${readable.hash}');
    }
    if (objects.verificationRevision != verificationBefore ||
        prior.length != _readable.length ||
        _readable.entries
            .any((entry) => !_sameItem(prior[entry.key], entry.value)))
      _dirty = true;
    _snapshot = null;
    _displayEntries.clear();
    contentRevision++;
    await _prepareDirectory();
  }

  bool _sameItem(CatalogItem? a, CatalogItem b) =>
      a != null &&
      a.entryId == b.entryId &&
      a.sourceId == b.sourceId &&
      a.revisionId == b.revisionId &&
      a.hash == b.hash &&
      a.length == b.length &&
      a.relativePath == b.relativePath &&
      a.format == b.format &&
      a.missing == b.missing;

  Future<void> _appendDeltaRecord(Map<String, Object?> record) async {
    final body = utf8.encode(jsonEncode(record));
    if (body.length > 16 * 1024 * 1024) throw const FormatException('Delta checkpoint too large.');
    final frame = utf8.encode('${body.length}:${sha256.convert(body)}:${utf8.decode(body)}\n');
    assertSafePath(objects.rootDirectory, _deltaJournalPath);
    final file = await File(_deltaJournalPath).open(mode: FileMode.append);
    try {
      await file.truncate(_deltaJournalBytes); await file.setPosition(_deltaJournalBytes);
      await file.writeFrom(frame); await file.flush();
      _deltaJournalBytes += frame.length; _deltaJournalRecords++;
      metadataDeltaBytesWritten += frame.length; metadataJournalFlushes++;
    } finally { await file.close(); }
  }

  Future<void> _flushIncremental() async {
    if (!_dirty || index == null) return;
    final touched = Set<String>.of(_deltaTouched);
    final items = [for (final id in touched) if (itemFor(id) case final item?) item];
    final readable = [for (final id in touched) if (_readable[id] case final item?) item];
    await _appendDeltaRecord({'kind': 'state', 'collection': index!.id,
      'cursor': deltaCursor, 'owner': deltaOwner,
      'items': items.map((e) => e.toJson()).toList(),
      'readable': readable.map((e) => e.toJson()).toList(),
      'touched': touched.toList(),
      'verified': objects.exportSelectedVerificationCache([
        for (final item in [...items, ...readable]) if (item.hash != null) item.object]),
      'pending': _deltaPending.toList(), 'selection': selection.toJson()});
    _deltaTouched.removeAll(touched); _dirty = false;
  }

  Future<void> _replayDeltaJournal() async {
    assertSafePath(objects.rootDirectory, _deltaJournalPath);
    final file = File(_deltaJournalPath);
    if (!await file.exists()) return;
    if (await file.length() > 32 * 1024 * 1024) throw const FormatException('Delta journal too large.');
    final bytes = await file.readAsBytes();
    var start = 0;
    for (var end = 0; end < bytes.length; end++) {
      if (bytes[end] != 10) continue;
      try {
        final line = utf8.decode(bytes.sublist(start, end));
        final a = line.indexOf(':'), b = line.indexOf(':', a + 1);
        if (a < 1 || b != a + 65) break;
        final body = utf8.encode(line.substring(b + 1));
        if (body.length != int.parse(line.substring(0, a)) ||
            sha256.convert(body).toString() != line.substring(a + 1,b)) break;
        final record = asMap(jsonDecode(utf8.decode(body)));
        if (record['kind'] == 'delta') {
          final delta = CollectionDelta.fromJson(asMap(record['delta']));
          // A completed checkpoint may have been followed by a crash before
          // journal retirement. Its already-covered cursor is idempotent.
          if (delta.cursor != deltaCursor) {
            if (delta.fromCursor != deltaCursor || delta.collectionId != index?.id ||
                record['owner'] != deltaOwner) break;
            final updates = {for (final item in delta.upserts) item.entryId: item};
            final existing = {for (final item in index!.entries) item.entryId};
            index = CollectionIndex(id: delta.collectionId, legacyLibraryId: delta.legacyLibraryId,
              sources: delta.sources, folders: delta.folders, entries: [
                for (final item in index!.entries) if (!delta.removed.contains(item.entryId))
                  updates[item.entryId] ?? _resolved[item.entryId] ?? item,
                for (final item in delta.upserts) if (!existing.contains(item.entryId)) item]);
            selection = OfflineSelection.fromJson(record['selection'] as List);
            for (final id in delta.removed) { _resolved.remove(id); _readable.remove(id); _deltaPending.remove(id); }
            for (final item in delta.upserts) {
              _resolved.remove(item.entryId);
              if (!item.missing && selection.includes(item)) _deltaPending.add(item.entryId);
              else _deltaPending.remove(item.entryId);
            }
            deltaCursor = delta.cursor;
          }
        } else if (record['kind'] == 'state') {
          if (record['collection'] != index?.id || record['cursor'] != deltaCursor ||
              record['owner'] != deltaOwner) break;
          for (final raw in record['items'] as List) {
            final item = CatalogItem.fromJson(asMap(raw));
            if (index?.entry(item.entryId)?.sourceId == item.sourceId) _resolved[item.entryId] = item;
          }
          for (final id in (record['touched'] as List).cast<String>()) { _readable.remove(id); }
          for (final raw in record['readable'] as List) {
            final item = CatalogItem.fromJson(asMap(raw));
            if (index?.entry(item.entryId)?.sourceId == item.sourceId) _readable[item.entryId] = item;
          }
          objects.restoreVerificationCache(asMap(record['verified']));
          _deltaPending..clear()..addAll((record['pending'] as List).cast<String>());
          selection = OfflineSelection.fromJson(record['selection'] as List);
        } else { break; }
      } catch (_) { break; }
      start = end + 1; _deltaJournalBytes = start; _deltaJournalRecords++;
    }
  }

  Future<void> _replayJournal() async {
    final file = File(_journalPath);
    assertSafePath(objects.rootDirectory, file.path);
    if (!await file.exists()) return;
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('Selected resolution journal is too large.');
    }
    final bytes = await file.readAsBytes();
    final sourceByEntry = {
      for (final e in index?.entries ?? <CatalogItem>[]) e.entryId: e.sourceId
    };
    var start = 0;
    for (var end = 0; end < bytes.length; end++) {
      if (bytes[end] != 10) continue;
      if (end - start > 65536) break;
      try {
        final line = utf8.decode(bytes.sublist(start, end));
        final a = line.indexOf(':'), b = line.indexOf(':', a + 1);
        if (a < 1 || b != a + 65) break;
        final body = utf8.encode(line.substring(b + 1));
        if (body.length != int.parse(line.substring(0, a)) ||
            sha256.convert(body).toString() != line.substring(a + 1, b)) break;
        final record = asMap(jsonDecode(utf8.decode(body)));
        final item = CatalogItem.fromJson(asMap(record['item']));
        final current = index?.entry(item.entryId);
        if (record['collection'] == index?.id &&
            sourceByEntry[item.entryId] == item.sourceId && current != null &&
            current.revisionId == item.revisionId && current.relativePath == item.relativePath &&
            current.length == item.length && current.format == item.format &&
            (current.hash == null || current.hash == item.hash)) {
          _resolved[item.entryId] = item;
          _dirty = true;
        }
      } catch (_) {
        break;
      }
      start = end + 1;
      _journalBytes = start;
    }
  }

  Future<void> _journalResolution(CatalogItem item) =>
      _journalResolutions([item]);

  /// One metadata checkpoint for a bounded transport batch. Each object still
  /// gets its own SHA check, flushed temporary file and atomic rename.
  Future<void> prepareReceiveBatch(List<CatalogItem> items) async {
    items = items
        .where(
            (item) => _durableResolutions[item.entryId] != _resolutionKey(item))
        .toList();
    if (items.isEmpty) return;
    if (items.length > 64)
      throw ArgumentError('Resolution batch exceeds limit.');
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      await _journalResolutions(items);
    } finally {
      await lease.close();
    }
  }

  Future<void> _journalResolutions(List<CatalogItem> items) async {
    final combined = <int>[];
    for (final item in items) {
      final body = utf8
          .encode(jsonEncode({'collection': index!.id, 'cursor': deltaCursor, 'item': item.toJson()}));
      if (body.length > 60 * 1024)
        throw const FormatException('Selected metadata is too large.');
      final bytes = utf8.encode(
          '${body.length}:${sha256.convert(body)}:${utf8.decode(body)}\n');
      combined.addAll(bytes);
    }
    if (_journalBytes + combined.length > 32 * 1024 * 1024) await _persist();
    assertSafePath(objects.rootDirectory, _journalPath);
    final file = await File(_journalPath).open(mode: FileMode.append);
    try {
      await file.truncate(_journalBytes);
      await file.setPosition(_journalBytes);
      await file.writeFrom(combined);
      await file.flush();
      metadataJournalFlushes++;
      _journalBytes += combined.length;
    } finally {
      await file.close();
    }
    _verificationEpoch++;
    for (final item in items) {
      _durableResolutions[item.entryId] = _resolutionKey(item);
      _resolved[item.entryId] = item;
      _dirty = true;
      _contentChanged(item);
    }
    if (_directory == null) await _prepareDirectory();
  }

  Future<void> _persist() async {
    _generation++;
    metadataCheckpoints++;
    if (index == null) return;
    final request = _CollectionPersistRequest(
        _path,
        index!,
        Map.of(_resolved),
        selection,
        objects.exportVerificationCache(),
        _readable.values.toList(), deltaCursor, deltaOwner, Set.of(_deltaPending));
    index = await Isolate.run(request.call);
    for (final e in request.resolved.entries) {
      if (identical(_resolved[e.key], e.value)) _resolved.remove(e.key);
    }
    _snapshot = _snapshot?.withGeneration(_generation);
    _dirty = _resolved.isNotEmpty;
    persistenceFailed = false;
    _durableResolutions.clear();
    // The full snapshot is durable before retiring its small recovery journal.
    try {
      assertSafePath(objects.rootDirectory, _journalPath);
      final journal = File(_journalPath);
      if (await journal.exists()) await journal.writeAsString('', flush: true);
      _journalBytes = 0;
      assertSafePath(objects.rootDirectory, _deltaJournalPath);
      final deltaJournal = File(_deltaJournalPath);
      if (await deltaJournal.exists()) await deltaJournal.writeAsString('', flush: true);
      _deltaJournalBytes = 0; _deltaJournalRecords = 0; _deltaTouched.clear();
    } on FileSystemException {
      persistenceFailed = true;
    }
  }

  Future<void> flush() async {
    if (index == null || !_dirty) return;
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      if (deltaCursor != null && _deltaJournalBytes < 4 * 1024 * 1024 && _deltaJournalRecords < 128) {
        await _flushIncremental();
      } else { await _persist(); }
    } finally {
      await lease.close();
    }
  }

  void rememberResolved(CatalogItem item) {
    _verificationEpoch++;
    _dirty = true;
    _resolved[item.entryId] = item;
    _ready.add('${item.entryId}/${item.revisionId}/${item.hash}');
    _readable[item.entryId] = item;
    _contentChanged(item);
  }

  void _contentChanged(CatalogItem item) {
    _deltaTouched.add(item.entryId);
    contentRevision++;
    _displayEntries.remove(item.entryId);
    if (_directory != null &&
        !_directory!.update(item, _readable[item.entryId], _ready)) {
      _directory = null;
    }
    if (_snapshot != null) {
      final updated = entryForDisplay(item.entryId);
      if (updated != null && _snapshot!.entryById(item.entryId) != null) {
        _snapshot = _snapshot!.replacingEntry(updated,
            generation: _generation, savedUtc: _snapshot!.savedUtc);
      } else {
        _snapshot = null;
      }
    }
  }

  LibraryEntry? entryForDisplay(String id) {
    final cached = _displayEntries[id];
    if (cached != null) return cached;
    final current = itemFor(id);
    if (current == null) return null;
    final shown = current.missing ? current : _readable[id] ?? current;
    return _displayEntries[id] = LibraryEntry(
        id: id,
        relativePath: current.relativePath,
        status: current.missing ? EntryStatus.missing : EntryStatus.available,
        availability: isReady(shown)
            ? ContentAvailability.ready
            : ContentAvailability.deferred,
        revisions: [
          ContentRevision(
              id: shown.revisionId,
              contentHash: shown.hash,
              size: shown.length,
              modifiedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              observedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
        ],
        currentRevisionId: shown.revisionId,
        lastSeenUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
  }

  Future<void> updateIndex(CollectionIndex next, {String? cursor, String? owner}) async {
    final before = index;
    if (before != null && before.id != next.id &&
        !(before.legacyLibraryId != null && before.legacyLibraryId == next.legacyLibraryId)) {
      throw StateError('Collection belongs to another computer.');
    }
    final empty = CollectionIndex(id: next.id, legacyLibraryId: next.legacyLibraryId,
      sources: [], entries: [], folders: {});
    final delta = CollectionDelta.between(before ?? empty, next, deltaCursor ?? '', cursor ?? '');
    await applyDelta(delta, owner: owner, fullFallback: true);
  }

  /// Metadata changes preserve every unrelated ready object and directory count.
  /// Only changed identities are inspected; baseline fallback uses the same path.
  Future<void> applyDelta(CollectionDelta delta, {String? owner, bool fullFallback = false}) async {
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    final priorIndex = index, priorSnapshot = _snapshot, priorDirectory = _directory;
    final priorCursor = deltaCursor, priorOwner = deltaOwner;
    final priorSelection = selection, priorDirty = _dirty;
    final priorGeneration = _generation, priorRevision = contentRevision;
    final priorResolved = fullFallback ? Map.of(_resolved) : null;
    final priorReadable = fullFallback ? Map.of(_readable) : null;
    final priorReady = fullFallback ? Set.of(_ready) : null;
    final priorPending = fullFallback ? Set.of(_deltaPending) : null;
    final priorDisplay = fullFallback ? Map.of(_displayEntries) : null;
    final priorDurable = fullFallback ? Map.of(_durableResolutions) : null;
    final priorTouched = fullFallback ? Set.of(_deltaTouched) : null;
    final priorVerification = fullFallback ? _pendingVerification.skip(_verificationCursor).toList() : null;
    try {
      final before = index;
      if (before != null && before.id != delta.collectionId &&
          !(fullFallback && before.legacyLibraryId != null &&
            before.legacyLibraryId == delta.legacyLibraryId)) {
        throw StateError('Collection belongs to another computer.');
      }
      if (!fullFallback && (delta.fromCursor != deltaCursor || owner != deltaOwner)) {
        throw StateError('Catalogue cursor changed while applying delta.');
      }
      final changed = {for (final item in delta.upserts) item.entryId, ...delta.removed};
      final replacements = {for (final item in delta.upserts) item.entryId: item};
      final existing = before?.entries ?? const <CatalogItem>[];
      final oldIds = {for (final item in existing) item.entryId};
      final next = CollectionIndex(id: delta.collectionId, legacyLibraryId: delta.legacyLibraryId,
        sources: delta.sources, folders: delta.folders, entries: [
          for (final item in existing)
            if (!delta.removed.contains(item.entryId))
              replacements[item.entryId] ?? _resolved[item.entryId] ?? item,
          for (final item in delta.upserts) if (!oldIds.contains(item.entryId)) item
        ]);
      final verified = <String>{};
      for (final item in delta.upserts) {
        if (!item.missing && item.hash != null && await objects.hasVerifiedObject(item.object)) {
          verified.add(item.entryId);
        }
      }
      if (!fullFallback) {
        await _appendDeltaRecord({'kind': 'delta', 'delta': delta.toJson(), 'owner': owner,
          'selection': selection.toJson()});
      }
      final remaining = _pendingVerification.skip(_verificationCursor)
          .where((item) => !changed.contains(item.entryId)).toList();
      _verificationEpoch++; _verificationCursor = 0; _pendingVerification = remaining;
      if (before == null && next.legacyLibraryId != null) {
        selection = selection.withRule(OfflineRule(sourceId: 'legacy', folder: '', selected: true));
      }
      final sourcesChanged = jsonEncode(before?.sources.map((s) => s.toJson()).toList()) !=
          jsonEncode(next.sources.map((s) => s.toJson()).toList());
      if (sourcesChanged || fullFallback) _directory = null;
      for (final id in delta.removed) {
        final old = _readable.remove(id);
        if (old != null) _ready.remove(_readyKey(old));
        _resolved.remove(id); _durableResolutions.remove(id);
        _displayEntries.remove(id); _deltaPending.remove(id); _directory?.remove(id);
      }
      index = next;
      _deltaTouched.addAll(changed);
      for (final item in delta.upserts) {
        final old = _readable[item.entryId];
        _resolved.remove(item.entryId); _durableResolutions.remove(item.entryId);
        if (verified.contains(item.entryId)) {
          if (old != null) _ready.remove(_readyKey(old));
          _readable[item.entryId] = item; _ready.add(_readyKey(item));
        } else if (old != null && (old.sourceId != item.sourceId ||
            (!item.missing && item.hash != null &&
              old.revisionId == item.revisionId && old.hash == item.hash))) {
          _ready.remove(_readyKey(old)); _readable.remove(item.entryId);
        }
        _displayEntries.remove(item.entryId);
        _directory?.replace(item, _readable[item.entryId], _ready);
        if (!item.missing && selection.includes(item) && !isReady(item)) _deltaPending.add(item.entryId);
        else _deltaPending.remove(item.entryId);
      }
      if (fullFallback) {
        // Older replicas have no durable pending-ID field. Seed their existing
        // selected incomplete rows once, using restored readiness without I/O.
        for (final item in currentItems) {
          if (!item.missing && selection.includes(item) && !isReady(item)) {
            _deltaPending.add(item.entryId);
          }
        }
      }
      if (owner != null) { deltaCursor = delta.cursor; deltaOwner = owner; }
      else { deltaCursor = null; deltaOwner = null; }
      _snapshot = null; contentRevision++; _dirty = true;
      if (_directory == null) await _prepareDirectory();
      if (fullFallback || _deltaJournalBytes >= 4 * 1024 * 1024 || _deltaJournalRecords >= 128) {
        await _persist();
      } else { await _flushIncremental(); }
    } catch (_) {
      if (fullFallback) {
        index = priorIndex; _snapshot = priorSnapshot; _directory = priorDirectory;
        deltaCursor = priorCursor; deltaOwner = priorOwner; selection = priorSelection;
        _dirty = priorDirty; _generation = priorGeneration; contentRevision = priorRevision;
        _resolved..clear()..addAll(priorResolved!);
        _readable..clear()..addAll(priorReadable!);
        _ready..clear()..addAll(priorReady!);
        _deltaPending..clear()..addAll(priorPending!);
        _displayEntries..clear()..addAll(priorDisplay!);
        _durableResolutions..clear()..addAll(priorDurable!);
        _deltaTouched..clear()..addAll(priorTouched!);
        _verificationEpoch++; _verificationCursor = 0; _pendingVerification = priorVerification!;
      }
      rethrow;
    } finally { await lease.close(); }
  }

  Future<void> importLegacy() async {
    final old = objects.manifest;
    if (old == null) return;
    final prior = index;
    if (prior != null && prior.legacyLibraryId != old.libraryId) {
      throw StateError('Legacy source belongs to another collection.');
    }
    await updateIndex(CollectionIndex(
        id: prior?.id ?? old.libraryId,
        legacyLibraryId: old.libraryId,
        sources: [
          const LibrarySourceInfo('legacy', '原谱库'),
          ...?prior?.sources.where((s) => s.id != 'legacy')
        ],
        entries: [
          for (final e in old.entries)
            CatalogItem(
                sourceId: 'legacy',
                entryId: e.entryId,
                revisionId: e.revisionId,
                relativePath: e.relativePath,
                length: e.length,
                format: e.format,
                hash: e.hash,
                missing: e.missing),
          ...?prior?.entries.where((e) => e.sourceId != 'legacy')
        ],
        folders: {
          ...?prior?.folders,
          'legacy': old.folders
        }));
  }

  Future<void> select(OfflineRule rule) => selectMany([rule]);

  /// Apply explicit item selections in one durable write; unrelated rules keep
  /// their order and intent. Last rule still wins exactly as before.
  Future<void> selectMany(Iterable<OfflineRule> rules) async {
    final updates = <(String, String?, String?), OfflineRule>{};
    for (final rule in rules) {
      final key = (rule.sourceId, rule.folder, rule.entryId);
      updates.remove(key);
      updates[key] = rule;
    }
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      selection = OfflineSelection([
        for (final old in selection.rules)
          if (!updates.containsKey((old.sourceId, old.folder, old.entryId)))
            old,
        ...updates.values,
      ]);
      // A deliberate selection change may include old metadata without any
      // remote delta. Queue those missing objects using cached readiness only.
      _deltaPending.removeWhere((id) {
        final item = itemFor(id); return item == null || !selection.includes(item);
      });
      for (final item in currentItems) {
        if (!item.missing && selection.includes(item) && !isReady(item)) _deltaPending.add(item.entryId);
      }
      await _persist();
    } finally {
      await lease.close();
    }
  }

  Future<void> receive(CatalogItem item, Stream<List<int>> bytes,
      {SyncCancellation? cancellation}) async {
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      cancellation?.check();
      if (_durableResolutions[item.entryId] != _resolutionKey(item))
        await _journalResolution(item);
      await objects.receiveObject(item.object, bytes,
          cancellation: cancellation);
      cancellation?.check();
      rememberResolved(item);
    } finally {
      await lease.close();
    }
  }

  Future<void> removeDownload(String entryId) async {
    final item = readableItemFor(entryId);
    if (item == null || item.hash == null) return;
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      final file = File(objects.objectPath(item.object));
      if (await file.exists()) await file.delete();
      selection = selection.withRule(OfflineRule(
          sourceId: item.sourceId, entryId: entryId, selected: false));
      _readable.remove(entryId);
      await refreshReady();
      await _persist();
    } finally {
      await lease.close();
    }
  }

  CatalogItem? itemFor(String id) => _resolved[id] ?? index?.entry(id);
  CatalogItem? readableItemFor(String id) => _readable[id];
  String presentationPathFor(String id) =>
      objects.objectPath((readableItemFor(id) ?? itemFor(id))!.object);
  Future<void> validateForRead(String id, String revision) async {
    final item = readableItemFor(id);
    if (item == null ||
        itemFor(id)?.missing != false ||
        item.revisionId != revision ||
        item.missing ||
        item.hash == null) {
      throw StateError('Selected download revision is unavailable.');
    }
    if (!await objects.hasVerifiedObject(item.object)) {
      _dirty = true;
      _ready.remove('${item.entryId}/${item.revisionId}/${item.hash}');
      _readable.remove(id);
      final current = itemFor(id);
      if (current != null && selection.includes(current)) _deltaPending.add(id);
      if (current != null) _contentChanged(current);
      throw StateError('Selected download is unavailable.');
    }
  }

  LibrarySnapshot get snapshot => _snapshot ??= LibrarySnapshot(
          rootPath: objects.rootDirectory,
          generation: _generation,
          savedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          folders:
              (index?.folders.values.expand((f) => f).toSet() ?? {''}).toList(),
          entries: [
            for (final original in index?.entries ?? <CatalogItem>[])
              for (final current in [_resolved[original.entryId] ?? original])
                for (final e in [
                  current.missing
                      ? current
                      : _readable[current.entryId] ?? current
                ])
                  LibraryEntry(
                    id: e.entryId,
                    relativePath: current.relativePath,
                    status: current.missing
                        ? EntryStatus.missing
                        : EntryStatus.available,
                    availability: isReady(e)
                        ? ContentAvailability.ready
                        : ContentAvailability.deferred,
                    revisions: [
                      ContentRevision(
                          id: e.revisionId,
                          contentHash: e.hash,
                          size: e.length,
                          modifiedUtc: DateTime.fromMillisecondsSinceEpoch(0,
                              isUtc: true),
                          observedUtc: DateTime.fromMillisecondsSinceEpoch(0,
                              isUtc: true))
                    ],
                    currentRevisionId: e.revisionId,
                    lastSeenUtc:
                        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
                  )
          ]);
}
