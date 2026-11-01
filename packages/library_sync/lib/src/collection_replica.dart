import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'collection.dart';
import 'replica.dart';
import 'storage.dart';

class _CollectionPersistRequest {
  const _CollectionPersistRequest(this.path, this.index, this.resolved,
      this.selection, this.verified, this.readable);
  final String path;
  final CollectionIndex index;
  final Map<String, CatalogItem> resolved;
  final OfflineSelection selection;
  final Map<String, dynamic> verified;
  final List<CatalogItem> readable;
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
      'readable': readable.map((e) => e.toJson()).toList()
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

/// The v1 complete-manifest contract stays unchanged. This additive index can
/// commit metadata while only a selected subset has verified local objects.
class ReplicaCollectionView {
  ReplicaCollectionView._(this.objects);
  final ReplicaLibraryView objects;
  CollectionIndex? index;
  OfflineSelection selection = const OfflineSelection();
  final _ready = <String>{};
  final _resolved = <String, CatalogItem>{};
  final _readable = <String, CatalogItem>{};
  bool _dirty = false;
  LibrarySnapshot? _snapshot;
  CollectionDirectoryIndex? _directory;
  final _displayEntries = <String, LibraryEntry>{};
  int contentRevision = 0;
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

  int _generation = 0;
  int _journalBytes = 0;
  bool persistenceFailed = false;
  String get _path => p.join(objects.rootDirectory, 'collection-v2.json');
  String get _journalPath =>
      p.join(objects.rootDirectory, 'selected-resolutions-v2.log');
  bool isReady(CatalogItem item) =>
      _ready.contains('${item.entryId}/${item.revisionId}/${item.hash}');

  /// Current metadata in one pass, including journal resolutions. Unlike a
  /// repeated itemFor lookup this does not search the full index for every row.
  Iterable<CatalogItem> get currentItems sync* {
    for (final original in index?.entries ?? <CatalogItem>[]) {
      yield _resolved[original.entryId] ?? original;
    }
  }

  static Future<ReplicaCollectionView> open(ReplicaLibraryView objects) async {
    final view = ReplicaCollectionView._(objects);
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      final stored = await readJson(view._path);
      if (stored != null) {
        if (stored['schema'] != 2)
          throw const FormatException('Unsupported collection replica.');
        view.index = CollectionIndex.fromJson(asMap(stored['index']));
        view.selection = OfflineSelection.fromJson(stored['selection'] as List);
        objects.restoreVerificationCache(asMap(stored['verified'] ?? {}));
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
      }
      await view._replayJournal();
      await view.refreshReady();
      if (view.index != null) {
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

  Future<void> refreshReady() async {
    _ready.clear();
    final prior = Map<String, CatalogItem>.from(_readable);
    _readable.clear();
    for (final item in currentItems) {
      if (item.missing) {
        if (prior[item.entryId] case final old?) _readable[item.entryId] = old;
        continue;
      }
      CatalogItem? readable;
      if (item.hash != null && await objects.hasVerifiedObject(item.object)) {
        readable = item;
      } else {
        final old = prior[item.entryId];
        if (old != null &&
            old.sourceId == item.sourceId &&
            old.hash != null &&
            await objects.hasVerifiedObject(old.object)) {
          readable = old;
        }
      }
      if (readable != null) {
        _readable[item.entryId] = readable;
        _ready
            .add('${readable.entryId}/${readable.revisionId}/${readable.hash}');
      }
    }
    _snapshot = null;
    _displayEntries.clear();
    contentRevision++;
    await _prepareDirectory();
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
        if (record['collection'] == index?.id &&
            sourceByEntry[item.entryId] == item.sourceId) {
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

  Future<void> _journalResolution(CatalogItem item) async {
    final body = utf8
        .encode(jsonEncode({'collection': index!.id, 'item': item.toJson()}));
    if (body.length > 60 * 1024)
      throw const FormatException('Selected metadata is too large.');
    final bytes = utf8.encode(
        '${body.length}:${sha256.convert(body)}:${utf8.decode(body)}\n');
    if (_journalBytes + bytes.length > 32 * 1024 * 1024) await _persist();
    assertSafePath(objects.rootDirectory, _journalPath);
    final file = await File(_journalPath).open(mode: FileMode.append);
    try {
      await file.truncate(_journalBytes);
      await file.setPosition(_journalBytes);
      await file.writeFrom(bytes);
      await file.flush();
      _journalBytes += bytes.length;
    } finally {
      await file.close();
    }
    _resolved[item.entryId] = item;
    _dirty = true;
    _contentChanged(item);
    if (_directory == null) await _prepareDirectory();
  }

  Future<void> _persist() async {
    _generation++;
    if (index == null) return;
    final request = _CollectionPersistRequest(
        _path,
        index!,
        Map.of(_resolved),
        selection,
        objects.exportVerificationCache(),
        _readable.values.toList());
    index = await Isolate.run(request.call);
    for (final e in request.resolved.entries) {
      if (identical(_resolved[e.key], e.value)) _resolved.remove(e.key);
    }
    _snapshot = _snapshot?.withGeneration(_generation);
    _dirty = _resolved.isNotEmpty;
    persistenceFailed = false;
    // The full snapshot is durable before retiring its small recovery journal.
    try {
      assertSafePath(objects.rootDirectory, _journalPath);
      final journal = File(_journalPath);
      if (await journal.exists()) await journal.writeAsString('', flush: true);
      _journalBytes = 0;
    } on FileSystemException {
      persistenceFailed = true;
    }
  }

  Future<void> flush() async {
    if (index == null || !_dirty) return;
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      await _persist();
    } finally {
      await lease.close();
    }
  }

  void rememberResolved(CatalogItem item) {
    _dirty = true;
    _resolved[item.entryId] = item;
    _ready.add('${item.entryId}/${item.revisionId}/${item.hash}');
    _readable[item.entryId] = item;
    _contentChanged(item);
  }

  void _contentChanged(CatalogItem item) {
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

  Future<void> updateIndex(CollectionIndex next) async {
    if (index != null &&
        index!.id != next.id &&
        !(index!.legacyLibraryId != null &&
            index!.legacyLibraryId == next.legacyLibraryId)) {
      throw StateError('Collection belongs to another computer.');
    }
    final lease = await DirectoryLease.acquire(objects.rootDirectory);
    try {
      if (index == null && next.legacyLibraryId != null) {
        selection = selection.withRule(
            OfflineRule(sourceId: 'legacy', folder: '', selected: true));
      }
      index = next;
      _resolved.clear();
      await refreshReady();
      await _persist();
    } finally {
      await lease.close();
    }
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
      _ready.remove('${item.entryId}/${item.revisionId}/${item.hash}');
      _readable.remove(id);
      final current = itemFor(id);
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
