import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'manifest.dart';
import 'storage.dart';

class SyncCancelled implements Exception {
  const SyncCancelled();
  @override
  String toString() => 'Sync cancelled.';
}

class SyncCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void check() {
    if (_cancelled) throw const SyncCancelled();
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

enum LibrarySyncStatus { complete, partial, cancelled }

/// Object counts, not byte percentages. Complete is emitted only after commit.
enum LibrarySyncPhase { transferring, committing, complete }

class LibrarySyncProgress {
  const LibrarySyncProgress(this.phase, this.processed, this.total);
  final LibrarySyncPhase phase;

  /// Verified downloads and reused complete objects in this operation.
  final int processed;

  /// Non-missing targets in the manifest fetched for this operation.
  final int total;
}

enum LibrarySyncFailure {
  differentLibrary,
  sourceNotReady,
  connection,
  authentication,
  integrity,
  localStorage,
  cancelled,
  unknown
}

/// A received object failed its declared length or content hash check.
class LibraryContentIntegrityException extends FormatException {
  const LibraryContentIntegrityException()
      : super('Object length or SHA-256 mismatch.');
}

class LibrarySyncResult {
  const LibrarySyncResult(this.status, this.downloaded,
      [this.error, this.failure]);
  final LibrarySyncStatus status;
  final int downloaded;

  /// Safe application-facing failure; never contains an auth token.
  final String? error;

  /// Null on success; callers can use this without parsing [error].
  final LibrarySyncFailure? failure;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Cumulative work performed by this view, including its initial open.
/// Local hash reads exclude metadata checks and bytes received from the peer.
class ReplicaVerificationStats {
  const ReplicaVerificationStats(
      {required this.localHashOperations,
      required this.localHashBytesRead,
      required this.downloadObjectsVerified,
      required this.downloadBytesReceived,
      required this.cachedObjectsReused});
  final int localHashOperations;
  final int localHashBytesRead;
  final int downloadObjectsVerified;
  final int downloadBytesReceived;
  final int cachedObjectsReused;
}

class _VerifiedObject {
  const _VerifiedObject(this.hash, this.length, this.modifiedMicros, this.mode);
  final String hash;
  final int length, modifiedMicros, mode;
  bool matches(ManifestEntry e, FileStat stat) =>
      hash == e.hash &&
      length == e.length &&
      length == stat.size &&
      modifiedMicros == stat.modified.microsecondsSinceEpoch &&
      mode == stat.mode &&
      stat.type == FileSystemEntityType.file;
  Map<String, Object?> toJson() => {
        'hash': hash,
        'length': length,
        'modifiedMicros': modifiedMicros,
        'mode': mode
      };
  factory _VerifiedObject.fromJson(Map<String, dynamic> json) {
    final result = _VerifiedObject(
        json['hash'] as String,
        json['length'] as int,
        json['modifiedMicros'] as int,
        json['mode'] as int);
    if (result.length < 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.hash)) {
      throw const FormatException('Invalid object verification record.');
    }
    return result;
  }
}

class ReplicaLibraryView {
  ReplicaLibraryView._(this.rootDirectory);
  final String rootDirectory;
  SyncManifest? _manifest;
  int _generation = 0;
  DateTime _savedUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final _ready = <String>{};
  LibrarySnapshot? _presentation;
  final _entryIndex = <String, LibraryEntry>{};
  final _manifestIndex = <String, ManifestEntry>{};
  final _presentationPaths = <String, String>{};
  final _verified = <String, _VerifiedObject>{};
  bool _verificationDirty = false;
  int _localHashOperations = 0, _localHashBytesRead = 0;
  int _downloadObjectsVerified = 0, _downloadBytesReceived = 0;
  int _cachedObjectsReused = 0;
  ReplicaVerificationStats get verificationStats => ReplicaVerificationStats(
      localHashOperations: _localHashOperations,
      localHashBytesRead: _localHashBytesRead,
      downloadObjectsVerified: _downloadObjectsVerified,
      downloadBytesReceived: _downloadBytesReceived,
      cachedObjectsReused: _cachedObjectsReused);
  SyncManifest? get manifest => _manifest;
  Map<String, Object?> exportVerificationCache() => {
        for (final e in _verified.entries) e.key: e.value.toJson(),
      };
  void restoreVerificationCache(Map<String, dynamic> records) {
    for (final e in records.entries) {
      try {
        if (p.basename(e.key) == e.key) {
          _verified[e.key] = _VerifiedObject.fromJson(asMap(e.value));
        }
      } catch (_) {
        /* Invalid metadata falls back to actual byte verification. */
      }
    }
  }

  String get _indexPath => p.join(rootDirectory, 'manifest.json');
  static Future<ReplicaLibraryView> open(
      {required String rootDirectory, bool verifyAll = false}) async {
    final result = ReplicaLibraryView._(p.normalize(p.absolute(rootDirectory)));
    final lease = await DirectoryLease.acquire(result.rootDirectory);
    try {
      await result._reloadAndVerify(verifyAll: verifyAll);
      return result;
    } finally {
      await lease.close();
    }
  }

  /// Explicit full integrity check, including bytes whose size/mtime match the
  /// cache. Reload under the lease so a stale view cannot overwrite a newer
  /// committed manifest when updating its verification records.
  Future<ReplicaVerificationStats> verifyAll() async {
    final lease = await DirectoryLease.acquire(rootDirectory);
    try {
      await _reloadAndVerify(verifyAll: true);
      return verificationStats;
    } finally {
      await lease.close();
    }
  }

  Future<void> _reloadAndVerify({required bool verifyAll}) async {
    _presentation = null;
    final json = await readJson(_indexPath);
    _ready.clear();
    _verified.clear();
    _verificationDirty = false;
    if (json != null) {
      if (json['schema'] != 1)
        throw const FormatException('Unsupported replica schema.');
      _manifest = SyncManifest.fromJson(asMap(json['manifest']));
      _generation = json['generation'] as int;
      _savedUtc = DateTime.parse(json['savedUtc'] as String).toUtc();
      if (json['verificationSchema'] == 1 && json['verifiedObjects'] is Map) {
        for (final entry in asMap(json['verifiedObjects']).entries) {
          try {
            _verified[entry.key] = _VerifiedObject.fromJson(asMap(entry.value));
          } catch (_) {
            _verificationDirty = true;
          }
        }
      } else {
        _verificationDirty = true;
      }
      for (final e in _manifest!.entries.where((e) => !e.missing)) {
        if (await hasVerifiedObject(e, verifyAll: verifyAll))
          _ready.add(objectPath(e));
      }
      if (_verificationDirty) {
        await writeJson(
            _indexPath, _indexJson(_manifest!, _generation, _savedUtc));
        _verificationDirty = false;
      }
    } else {
      _manifest = null;
      _generation = 0;
      _savedUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  Map<String, Object?> _indexJson(
          SyncManifest manifest, int generation, DateTime savedUtc) =>
      {
        'schema': 1,
        'generation': generation,
        'savedUtc': savedUtc.toIso8601String(),
        'manifest': manifest.toJson(),
        'verificationSchema': 1,
        'verifiedObjects': {
          for (final entry in _verified.entries) entry.key: entry.value.toJson()
        }
      };

  String _verificationKey(ManifestEntry e) => p.basename(objectPath(e));
  void _forget(ManifestEntry e) {
    if (_ready.remove(_objectPath(e))) _presentation = null;
    if (_verified.remove(_verificationKey(e)) != null)
      _verificationDirty = true;
  }

  void _remember(ManifestEntry e, FileStat stat) {
    if (stat.type != FileSystemEntityType.file ||
        stat.size != e.length ||
        e.hash == null) {
      _forget(e);
      return;
    }
    final key = _verificationKey(e);
    if (_verified[key]?.matches(e, stat) == true) return;
    _verified[key] = _VerifiedObject(
        e.hash!, stat.size, stat.modified.microsecondsSinceEpoch, stat.mode);
    _verificationDirty = true;
    if (_manifest?.entries.any((existing) =>
                existing.entryId == e.entryId &&
                existing.revisionId == e.revisionId &&
                existing.hash == e.hash) ==
            true &&
        _ready.add(_objectPath(e))) {
      _presentation = null;
    }
  }

  String objectPath(ManifestEntry e) {
    final path = _objectPath(e);
    assertSafePath(rootDirectory, path);
    return path;
  }

  // Pure metadata calculation. I/O boundaries still use objectPath's guard.
  String _objectPath(ManifestEntry e) {
    final identity = sha256
        .convert(utf8.encode(jsonEncode([e.entryId, e.revisionId, e.hash])))
        .toString();
    final path = p.join(rootDirectory, 'objects', '$identity.${e.format}');
    return path;
  }

  LibraryEntry? entryById(String id) {
    snapshot;
    return _entryIndex[id];
  }

  /// Metadata only; call validateForRead before opening this path.
  String presentationPathFor(String entryId) {
    snapshot;
    return _presentationPaths[entryId] ??
        (throw StateError('Unknown replica object.'));
  }

  Future<void> validateForRead(String entryId, String revisionId) async {
    snapshot;
    final entry = _manifestIndex[entryId];
    if (entry == null ||
        entry.missing ||
        entry.revisionId != revisionId ||
        !await hasVerifiedObject(entry)) {
      throw StateError('Object is unavailable locally.');
    }
  }

  Future<bool> hasVerifiedObject(ManifestEntry e,
      {bool verifyAll = false}) async {
    final file = File(objectPath(e));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      _forget(e);
      return false;
    }
    try {
      final before = await file.stat();
      if (before.size != e.length || e.hash == null) {
        _forget(e);
        return false;
      }
      if (!verifyAll &&
          _verified[_verificationKey(e)]?.matches(e, before) == true) {
        _cachedObjectsReused++;
        return true;
      }
      _localHashOperations++;
      Stream<List<int>> countedBytes() async* {
        await for (final chunk in file.openRead()) {
          _localHashBytesRead += chunk.length;
          yield chunk;
        }
      }

      final hash = (await sha256.bind(countedBytes()).first).toString();
      final after = await file.stat();
      final stable = _VerifiedObject(e.hash!, before.size,
              before.modified.microsecondsSinceEpoch, before.mode)
          .matches(e, after);
      if (hash != e.hash || !stable) {
        _forget(e);
        return false;
      }
      _remember(e, after);
      return true;
    } on FileSystemException {
      _forget(e);
      return false;
    }
  }

  /// Transfer into a private temporary file. A failure never replaces a valid
  /// previous object; immutable objects are retained across manifest changes.
  Future<void> receiveObject(ManifestEntry e, Stream<List<int>> bytes,
      {SyncCancellation? cancellation}) async {
    if (e.missing) throw StateError('Cannot download missing content.');
    cancellation?.check();
    final destination = objectPath(e);
    await Directory(p.dirname(destination)).create(recursive: true);
    assertSafePath(rootDirectory, destination);
    final temporary = File('$destination.part.${randomId(12)}');
    final file = await temporary.open(mode: FileMode.writeOnly);
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var length = 0;
    var closed = false;
    try {
      await for (final chunk in bytes) {
        cancellation?.check();
        length += chunk.length;
        _downloadBytesReceived += chunk.length;
        if (length > e.length) throw const LibraryContentIntegrityException();
        hash.add(chunk);
        await file.writeFrom(chunk);
      }
      hash.close();
      cancellation?.check();
      if (length != e.length || digest.value.toString() != e.hash) {
        throw const LibraryContentIntegrityException();
      }
      _downloadObjectsVerified++;
      await file.flush();
      await file.close();
      closed = true;
      assertSafePath(rootDirectory, destination);
      if (await File(destination).exists()) {
        if (await hasVerifiedObject(e)) return;
        await File(destination).rename('$destination.corrupt.${randomId(8)}');
      }
      await temporary.rename(destination);
      _remember(e, await File(destination).stat());
    } finally {
      if (!closed) await file.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> commitManifest(SyncManifest next,
      {SyncCancellation? cancellation}) async {
    if (_manifest != null && _manifest!.libraryId != next.libraryId) {
      throw StateError(
          'Replica belongs to another library. Use a new directory.');
    }
    final ready = <String>{};
    for (final e in next.entries.where((e) => !e.missing)) {
      cancellation?.check();
      if (!await hasVerifiedObject(e))
        throw StateError('Manifest contains incomplete content.');
      ready.add(objectPath(e));
    }
    cancellation?.check();
    final now = DateTime.now().toUtc();
    await writeJson(_indexPath, _indexJson(next, _generation + 1, now));
    _verificationDirty = false;
    _manifest = next;
    _generation++;
    _savedUtc = now;
    _presentation = null;
    _ready
      ..clear()
      ..addAll(ready);
  }

  LibrarySnapshot get snapshot {
    if (_presentation case final cached?) return cached;
    _entryIndex.clear();
    _manifestIndex.clear();
    _presentationPaths.clear();
    final entries = <LibraryEntry>[];
    for (final e in _manifest?.entries ?? <ManifestEntry>[]) {
      final path = _objectPath(e);
      final entry = LibraryEntry(
        id: e.entryId,
        relativePath: e.relativePath,
        status: e.missing ? EntryStatus.missing : EntryStatus.available,
        availability: !e.missing && _ready.contains(path)
            ? ContentAvailability.ready
            : ContentAvailability.unreadable,
        revisions: [
          ContentRevision(
              id: e.revisionId,
              contentHash: e.hash,
              size: e.length,
              modifiedUtc: _savedUtc,
              observedUtc: _savedUtc)
        ],
        currentRevisionId: e.revisionId,
        lastSeenUtc: _savedUtc,
      );
      entries.add(entry);
      _entryIndex[e.entryId] = entry;
      _manifestIndex[e.entryId] = e;
      _presentationPaths[e.entryId] = path;
    }
    return _presentation = LibrarySnapshot(
        rootPath: rootDirectory,
        generation: _generation,
        savedUtc: _savedUtc,
        folders: _manifest?.folders ?? const [''],
        entries: entries);
  }

  List<LibraryEntry> search(String query, {String? withinFolder}) {
    final scope = withinFolder ?? '';
    validatePortablePath(scope, folder: true);
    final terms = query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    final result = snapshot.availableEntries
        .where((e) =>
            (scope.isEmpty || e.relativePath.startsWith('$scope/')) &&
            terms.every(e.relativePath.toLowerCase().contains))
        .toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return List.unmodifiable(result);
  }

  FolderListing listFolder([String relativePath = '']) {
    validatePortablePath(relativePath, folder: true);
    String parent(String path) =>
        p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
    return FolderListing(
        folders: snapshot.folders
            .where((f) => f.isNotEmpty && parent(f) == relativePath)
            .toList()
          ..sort(),
        entries: search('', withinFolder: relativePath)
            .where((e) => parent(e.relativePath) == relativePath)
            .toList());
  }

  String absolutePathFor(LibraryEntry entry) {
    final e = ManifestEntry(
        entryId: entry.id,
        revisionId: entry.currentRevisionId,
        relativePath: entry.relativePath,
        hash: entry.currentRevision.contentHash,
        length: entry.currentRevision.size,
        format:
            p.posix.extension(entry.relativePath).substring(1).toLowerCase(),
        missing: false);
    final path = objectPath(e);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Object is unavailable locally.');
    }
    return path;
  }
}
