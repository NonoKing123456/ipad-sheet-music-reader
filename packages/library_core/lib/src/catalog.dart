import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

typedef FileAccessProbe = Future<FileAccess> Function(
    String absolutePath, FileStat stat);

/// A provider must return a stable OS identity, not a path or content hash.
typedef FileIdentityResolver = Future<String?> Function(
    String absolutePath, FileStat stat);

/// In-memory publication identity, never part of persisted or wire schemas.
class CatalogPublication {
  const CatalogPublication._(this.rootPath, this.statePath, this.generation,
      this._primary, this._backup);
  final String rootPath, statePath;
  final int generation;
  final (FileSystemEntityType, int, DateTime, DateTime, String?)? _primary,
      _backup;
  bool isSameAs(CatalogPublication other) =>
      rootPath == other.rootPath &&
      statePath == other.statePath &&
      generation == other.generation &&
      _primary == other._primary &&
      _backup == other._backup;
  bool _matches(CatalogPublication other) =>
      _primary != null && isSameAs(other);
}

class CatalogMaterialization {
  const CatalogMaterialization._(
      this.entry, this.base, this.after, this.savedUtc, this.fallback);
  final LibraryEntry entry;
  final CatalogPublication base, after;
  final DateTime savedUtc;

  /// A different persisted base requires a complete validated refresh.
  final LibraryCatalog? fallback;
}

/// Bounded selected-file commit; failures do not discard successful siblings.
class CatalogBatchMaterialization {
  const CatalogBatchMaterialization._(this.entries, this.failures, this.base,
      this.after, this.savedUtc, this.fallback);
  final Map<String, LibraryEntry> entries;
  final Map<String, String> failures;
  final CatalogPublication base, after;
  final DateTime savedUtc;
  final LibraryCatalog? fallback;
}

class LibraryCatalog {
  LibraryCatalog._(this.rootPath, this.statePath, this.fileAccessProbe,
      this.fileIdentityResolver, this.stateIdentityResolver)
      : _snapshot = LibrarySnapshot(
          rootPath: rootPath,
          generation: 0,
          entries: [],
          folders: [''],
          savedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        );

  static const _schemaVersion = 1;
  static const _supportedExtensions = {
    '.pdf',
    '.jpg',
    '.jpeg',
    '.png',
    '.webp'
  };
  static final _activeWriters = <String>{};
  static final _random = Random.secure();

  final String rootPath;
  final String statePath;
  final FileAccessProbe? fileAccessProbe;
  final FileIdentityResolver? fileIdentityResolver;
  final FileIdentityResolver? stateIdentityResolver;
  LibrarySnapshot _snapshot;
  (FileSystemEntityType, int, DateTime, DateTime, String?)? _stateStamp;
  (FileSystemEntityType, int, DateTime, DateTime, String?)? _backupStamp;
  LibrarySnapshot? _listedSnapshot;
  final _folderListings = <String, FolderListing>{};
  final _storageWarnings = <String>[];
  int contentHashOperations = 0, contentHashBytesRead = 0;
  int scanFileStatChecks = 0, scanDirectoryEnumerations = 0, scanPathTypeChecks = 0;
  int catalogReads = 0,
      catalogReadBytes = 0,
      catalogWrites = 0,
      catalogWriteBytes = 0;

  Future<String> _hashFile(File file) {
    contentHashOperations++;
    return sha256
        .bind(file.openRead().map((chunk) {
          contentHashBytesRead += chunk.length;
          return chunk;
        }))
        .first
        .then((digest) => digest.toString());
  }

  LibrarySnapshot get snapshot => _snapshot;
  CatalogPublication get publication => CatalogPublication._(
      rootPath, statePath, _snapshot.generation, _stateStamp, _backupStamp);
  List<String> get storageWarnings => List.unmodifiable(_storageWarnings);

  /// The source tree is read-only. All bookkeeping lives outside [rootPath].
  static Future<LibraryCatalog> open({
    required String rootPath,
    required String statePath,
    FileAccessProbe? fileAccessProbe,
    FileIdentityResolver? fileIdentityResolver,
    FileIdentityResolver? stateIdentityResolver,
  }) async {
    final root = await _canonicalize(rootPath);
    final state = await _canonicalize(statePath);
    if (_atOrWithin(root, state)) {
      throw ArgumentError.value(statePath, 'statePath',
          'Catalogue state must be outside the source.');
    }
    final catalog = LibraryCatalog._(root, state, fileAccessProbe,
        fileIdentityResolver, stateIdentityResolver);
    await catalog.reload();
    return catalog;
  }

  /// Reload after another process updates this catalogue. Does not scan files.
  Future<void> reload() => _withLock(() async {
        _snapshot = await _loadSnapshot();
      });

  /// Metadata cache avoids re-hashing unchanged files. [verifyAll] explicitly
  /// rechecks their bytes, including same-size/same-timestamp replacements.
  /// Known deferred files remain deferred even during full verification.
  Future<ScanResult> rescan(
          {bool verifyAll = false,
          bool metadataOnly = false,
          Set<String>? dirtyPaths,
          bool Function()? shouldYield}) =>
      _withLock(() async {
        void checkpoint() {
          if (shouldYield?.call() == true) throw const CatalogScanYielded();
        }

        checkpoint();
        final disk = await matchesDisk() ? _snapshot : await _loadSnapshot();
        if (disk.generation != _snapshot.generation) {
          throw const ConcurrentCatalogWriteException(
              'The catalogue changed elsewhere; reload before rescanning.');
        }
        _snapshot = disk;
        checkpoint();
        final result = await _scan(
            verifyAll: verifyAll,
            metadataOnly: metadataOnly,
            dirtyPaths: dirtyPaths,
            checkpoint: checkpoint);
        checkpoint();
        await _saveSnapshot(result.snapshot);
        _snapshot = result.snapshot;
        return result;
      });

  /// Materialize one selected file without enumerating or hashing its siblings.
  /// Filling an unchanged unknown revision preserves its identity and references.
  Future<LibraryEntry> materialize(String entryId) async {
    return (await _materialize(entryId)).$1;
  }

  Future<(LibraryEntry, CatalogPublication)> _materialize(
      String entryId) async {
    final ready = await readyIfUnchanged(entryId);
    if (ready != null) return (ready, publication);
    return _withLock(() async {
      final disk = await matchesDisk() ? _snapshot : await _loadSnapshot();
      _snapshot = disk;
      final base = publication;
      final entry = _snapshot.entryById(entryId);
      if (entry == null || entry.status != EntryStatus.available) {
        throw StateError('Unknown or missing selected file.');
      }
      final path = await validatedPathFor(entry);
      final file = File(path), before = await File(path).stat();
      final current = entry.currentRevision;
      if (current.contentHash != null &&
          before.size == current.size &&
          before.modified.toUtc() == current.modifiedUtc &&
          entry.availability == ContentAvailability.ready) return (entry, base);
      if (await fileAccessProbe?.call(path, before) == FileAccess.deferred) {
        throw StateError('Selected file is not available on this computer.');
      }
      final hash = await _hashFile(file);
      final after = await file.stat();
      if (after.type != FileSystemEntityType.file ||
          after.size != before.size ||
          after.modified != before.modified ||
          await validatedPathFor(entry) != path) {
        throw const FileSystemException('Selected file changed while hashing.');
      }
      final now = DateTime.now().toUtc();
      final updated = _updateEntry(
          entry,
          _ObservedFile(entry.relativePath, after.size, after.modified.toUtc(),
              hash, ContentAvailability.ready, entry.platformFileId),
          now);
      final next = LibrarySnapshot(
          rootPath: rootPath,
          generation: _snapshot.generation + 1,
          entries: [
            for (final e in _snapshot.entries) e.id == entry.id ? updated : e
          ],
          folders: _snapshot.folders,
          savedUtc: now);
      await _saveSnapshot(next);
      _snapshot = next;
      return (updated, base);
    });
  }

  Future<CatalogMaterialization> materializeForPublication(
      String id, CatalogPublication expected) async {
    final (entry, base) = await _materialize(id);
    return CatalogMaterialization._(entry, base, publication,
        _snapshot.savedUtc, base._matches(expected) ? null : this);
  }

  /// Opened catalogue and writer lease are shared by at most 64 selections.
  /// Only those source files are checked/hashed; missing tombstones are retained.
  Future<CatalogBatchMaterialization> materializeManyForPublication(
      Map<String, String> selected, CatalogPublication expected) async {
    if (selected.isEmpty || selected.length > 64) {
      throw ArgumentError('Selected materialization requires 1..64 files.');
    }
    return _withLock(() async {
      _snapshot = await matchesDisk() ? _snapshot : await _loadSnapshot();
      final base = publication;
      final ready = <String, LibraryEntry>{},
          changed = <String, LibraryEntry>{};
      final failures = <String, String>{};
      final now = DateTime.now().toUtc();
      for (final request in selected.entries) {
        try {
          final entry = _snapshot.entryById(request.key);
          if (entry == null ||
              entry.status != EntryStatus.available ||
              entry.currentRevisionId != request.value) {
            throw StateError('Selected revision changed or is missing.');
          }
          final path = await validatedPathFor(entry);
          final file = File(path), before = await File(path).stat();
          final current = entry.currentRevision;
          if (current.contentHash != null &&
              before.size == current.size &&
              before.modified.toUtc() == current.modifiedUtc &&
              entry.availability == ContentAvailability.ready) {
            ready[entry.id] = entry;
            continue;
          }
          if (await fileAccessProbe?.call(path, before) ==
              FileAccess.deferred) {
            throw StateError(
                'Selected file is not available on this computer.');
          }
          final hash = await _hashFile(file);
          final after = await file.stat();
          if (after.type != FileSystemEntityType.file ||
              after.size != before.size ||
              after.modified != before.modified ||
              await validatedPathFor(entry) != path) {
            throw const FileSystemException(
                'Selected file changed while hashing.');
          }
          final updated = _updateEntry(
              entry,
              _ObservedFile(
                  entry.relativePath,
                  after.size,
                  after.modified.toUtc(),
                  hash,
                  ContentAvailability.ready,
                  entry.platformFileId),
              now);
          changed[entry.id] = updated;
          if (updated.currentRevisionId != request.value) {
            throw StateError('Selected revision changed while preparing.');
          }
          ready[entry.id] = updated;
        } catch (error) {
          failures[request.key] = error.toString();
        }
      }
      if (changed.isNotEmpty) {
        final next = _snapshot.replacingEntries(changed.values,
            generation: _snapshot.generation + 1, savedUtc: now);
        await _saveSnapshot(next);
        _snapshot = next;
      }
      return CatalogBatchMaterialization._(
          Map.unmodifiable(ready),
          Map.unmodifiable(failures),
          base,
          publication,
          _snapshot.savedUtc,
          base._matches(expected) ? null : this);
    });
  }

  /// Same publication and disk-generation guards as the one-entry worker patch.
  Future<bool> applyBatchMaterialization(
      CatalogBatchMaterialization patch) async {
    if (patch.fallback != null ||
        !publication._matches(patch.base) ||
        patch.after.generation < patch.base.generation ||
        patch.after.generation > patch.base.generation + 1 ||
        patch.after._primary != await _readStateStamp() ||
        (patch.after._backup != null &&
            patch.after._backup != await _readStateStamp('$statePath.backup')))
      return false;
    for (final entry in patch.entries.values) {
      final old = _snapshot.entryById(entry.id);
      if (old == null ||
          old.relativePath != entry.relativePath ||
          old.status != EntryStatus.available ||
          entry.status != old.status) return false;
    }
    if (!publication._matches(patch.base)) return false;
    if (patch.after._matches(patch.base)) return true;
    // A changed revision omitted from successes also needs the durable refresh.
    if (patch.failures.isNotEmpty) return false;
    _snapshot = _snapshot.replacingEntries(patch.entries.values,
        generation: patch.after.generation, savedUtc: patch.savedUtc);
    _listedSnapshot = null;
    _folderListings.clear();
    _stateStamp = patch.after._primary;
    _backupStamp = patch.after._backup;
    return true;
  }

  /// Apply only a worker-proven one-entry commit from our exact persisted base.
  /// A newer disk generation makes the patch unusable, rather than rolling it
  /// back or publishing a mixture of two catalogue generations.
  Future<bool> applyMaterialization(CatalogMaterialization patch) async {
    if (patch.fallback != null ||
        !publication._matches(patch.base) ||
        patch.after.generation < patch.base.generation ||
        patch.after.generation > patch.base.generation + 1 ||
        patch.after._primary != await _readStateStamp() ||
        (patch.after._backup != null &&
            patch.after._backup != await _readStateStamp('$statePath.backup')))
      return false;
    final old = _snapshot.entryById(patch.entry.id);
    if (!publication._matches(patch.base)) return false;
    if (old == null ||
        old.relativePath != patch.entry.relativePath ||
        old.status != EntryStatus.available ||
        patch.entry.status != old.status) return false;
    if (patch.after._matches(patch.base)) return true;
    final before = _snapshot;
    _snapshot = before.replacingEntry(patch.entry,
        generation: patch.after.generation, savedUtc: patch.savedUtc);
    if (identical(_listedSnapshot, before)) {
      final parent = _relativeKey(_parentPath(old.relativePath));
      final listing = _folderListings[parent];
      if (listing != null) {
        _folderListings[parent] =
            FolderListing(folders: listing.folders, entries: [
          for (final entry in listing.entries)
            entry.id == patch.entry.id ? patch.entry : entry
        ]);
      }
      _listedSnapshot = _snapshot;
    }
    _stateStamp = patch.after._primary;
    _backupStamp = patch.after._backup;
    return true;
  }

  /// A known revision needs no catalogue write. Check the actual source path
  /// and metadata at each read boundary, and reject this cache if the persisted
  /// catalogue was atomically replaced by a scan or another process.
  Future<LibraryEntry?> readyIfUnchanged(String entryId) async {
    final captured = _snapshot;
    final entry = captured.entryById(entryId);
    if (entry == null ||
        entry.status != EntryStatus.available ||
        entry.availability != ContentAvailability.ready ||
        entry.currentRevision.contentHash == null ||
        !await matchesDisk()) {
      return null;
    }
    final path = await validatedPathFor(entry);
    final stat = await File(path).stat();
    final revision = entry.currentRevision;
    if (stat.size != revision.size ||
        stat.modified.toUtc() != revision.modifiedUtc ||
        !identical(captured, _snapshot) ||
        !await matchesDisk()) return null;
    return entry;
  }

  Future<bool> matchesDisk() async =>
      _stateStamp != null &&
      _stateStamp == await _readStateStamp() &&
      (_backupStamp == null ||
          _backupStamp == await _readStateStamp('$statePath.backup'));

  Future<(FileSystemEntityType, int, DateTime, DateTime, String?)>
      _readStateStamp([String? path]) async {
    path ??= statePath;
    final stat = await File(path).stat();
    final identity = await stateIdentityResolver?.call(path, stat);
    return (stat.type, stat.size, stat.modified, stat.changed, identity);
  }

  /// Revalidate the actual path at read boundaries; no links outside the source.
  Future<String> validatedPathFor(LibraryEntry entry) async {
    final path = p.normalize(p.absolute(absolutePathFor(entry)));
    if (!_atOrWithin(rootPath, path) ||
        p.equals(rootPath, path) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FileSystemException(
          'Selected path is not a regular source file.');
    }
    final actual = p.normalize(await File(path).resolveSymbolicLinks());
    final root = p.normalize(await Directory(rootPath).resolveSymbolicLinks());
    if (!p.equals(root, rootPath) ||
        !p.equals(actual, path) ||
        !_atOrWithin(root, actual)) {
      throw const FileSystemException(
          'Selected path changed or contains a link.');
    }
    return actual;
  }

  List<LibraryEntry> search(String query, {String? withinFolder}) {
    final scope = _relativeScope(withinFolder ?? '');
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final rootName = p.basename(rootPath).toLowerCase();
    final results = _snapshot.availableEntries.where((entry) {
      if (!_inScope(scope, entry.relativePath)) return false;
      final text = '$rootName/${entry.relativePath}'.toLowerCase();
      return terms.every(text.contains);
    }).toList();
    results.sort((a, b) => compareLibraryPaths(a.relativePath, b.relativePath));
    return List.unmodifiable(results);
  }

  FolderListing listFolder([String relativePath = '']) {
    final folder = _relativeScope(relativePath);
    if (!identical(_listedSnapshot, _snapshot)) {
      final folders = <String, List<String>>{};
      final entries = <String, List<LibraryEntry>>{};
      for (final candidate in _snapshot.folders) {
        if (candidate.isNotEmpty) {
          (folders[_relativeKey(_parentPath(candidate))] ??= []).add(candidate);
        }
      }
      for (final entry in _snapshot.availableEntries) {
        (entries[_relativeKey(_parentPath(entry.relativePath))] ??= [])
            .add(entry);
      }
      _folderListings.clear();
      for (final key in {...folders.keys, ...entries.keys}) {
        final childFolders = folders[key] ?? [];
        final childEntries = entries[key] ?? [];
        childFolders.sort(compareLibraryPaths);
        childEntries
            .sort((a, b) => compareLibraryPaths(a.relativePath, b.relativePath));
        _folderListings[key] =
            FolderListing(folders: childFolders, entries: childEntries);
      }
      _listedSnapshot = _snapshot;
    }
    return _folderListings[_relativeKey(folder)] ??
        FolderListing(folders: [], entries: []);
  }

  String absolutePathFor(LibraryEntry entry) {
    final relative = _relativeScope(entry.relativePath);
    return p.joinAll([rootPath, ...relative.split('/')]);
  }

  Future<ScanResult> _scan(
      {required bool verifyAll,
      required bool metadataOnly,
      Set<String>? dirtyPaths,
      required void Function() checkpoint}) async {
    final now = DateTime.now().toUtc();
    final previousByPath = <String, LibraryEntry>{};
    for (final entry in _snapshot.entries) {
      final key = _relativeKey(entry.relativePath);
      final existing = previousByPath[key];
      if (existing == null ||
          (entry.status == EntryStatus.available &&
              existing.status != EntryStatus.available) ||
          (entry.status == existing.status &&
              entry.lastSeenUtc.isAfter(existing.lastSeenUtc))) {
        previousByPath[key] = entry;
      }
    }

    // Paths are portable relative scopes. Unknown/overflow events use null.
    final scopes = dirtyPaths?.toSet();
    if (scopes != null) {
      for (final path in scopes) {
        if (path.contains('\\') || path.contains(':') || path.contains('\u0000') || p.posix.isAbsolute(path) ||
            p.posix.normalize(path) != (path.isEmpty ? '.' : path) ||
            path.split('/').any((part) => part == '..' || part == '.')) {
          throw const FormatException('Invalid dirty path.');
        }
      }
    }
    bool inDirtyScope(String path) => scopes == null || scopes.any((scope) => _inScope(scope,path));
    final observed = <_ObservedFile>[];
    final folders = <String>{''};
    final failedAreas = <String>{};
    final protectedFiles = <String>{};
    final issues = <ScanIssue>[];

    Future<void> visit(Directory directory, String relativeDirectory,
        [List<FileSystemEntity>? selectedChildren]) async {
      checkpoint();
      folders.add(relativeDirectory);
      List<FileSystemEntity> children;
      try {
        if (selectedChildren == null) scanDirectoryEnumerations++;
        children = selectedChildren ?? await directory.list(followLinks: false).toList();
      } on FileSystemException catch (error) {
        failedAreas.add(relativeDirectory);
        issues.add(ScanIssue(
            relativeDirectory, ScanIssueStage.enumeration, error.message));
        return;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in children) {
        checkpoint();
        final relative = p
            .relative(entity.path, from: rootPath)
            .split(p.separator)
            .join('/');
        if (entity is Link) {
          // Do not traverse junctions/symlinks, including external targets.
          failedAreas.add(relative);
          issues.add(ScanIssue(relative, ScanIssueStage.link,
              'Symbolic link was not followed.'));
          continue;
        }
        if (entity is Directory) {
          await visit(entity, relative);
          continue;
        }
        if (entity is! File ||
            !_supportedExtensions
                .contains(p.extension(entity.path).toLowerCase())) {
          continue;
        }
        FileStat stat;
        try {
          scanFileStatChecks++;
          stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) {
            throw const FileSystemException('File disappeared during scan.');
          }
        } on FileSystemException catch (error) {
          protectedFiles.add(relative);
          issues
              .add(ScanIssue(relative, ScanIssueStage.metadata, error.message));
          continue;
        }
        final previous = previousByPath[_relativeKey(relative)];
        final modified = stat.modified.toUtc();
        final sameMetadata = previous != null &&
            previous.currentRevision.size == stat.size &&
            previous.currentRevision.modifiedUtc == modified;
        var availability = ContentAvailability.ready;
        String? hash;
        String? platformFileId;
        try {
          final probe = fileAccessProbe;
          if (metadataOnly &&
              !(sameMetadata && previous.currentRevision.contentHash != null)) {
            availability = ContentAvailability.deferred;
          } else if (probe != null &&
              await probe(entity.path, stat) == FileAccess.deferred) {
            availability = ContentAvailability.deferred;
            hash = sameMetadata ? previous.currentRevision.contentHash : null;
            issues.add(ScanIssue(relative, ScanIssueStage.deferred,
                'File content was deferred by the caller access probe.'));
          } else if (!verifyAll &&
              sameMetadata &&
              previous.currentRevision.contentHash != null) {
            hash = previous.currentRevision.contentHash;
          } else {
            hash = await _hashFile(entity);
            scanFileStatChecks++;
            final after = await entity.stat();
            if (after.size != stat.size || after.modified.toUtc() != modified) {
              throw const FileSystemException('File changed while hashing.');
            }
          }
        } catch (error) {
          hash = null;
          availability = ContentAvailability.unreadable;
          issues.add(ScanIssue(relative, ScanIssueStage.content, '$error'));
        }
        final identityResolver = fileIdentityResolver;
        if (identityResolver != null) {
          try {
            platformFileId = await identityResolver(entity.path, stat);
          } catch (error) {
            issues.add(ScanIssue(relative, ScanIssueStage.identity, '$error'));
          }
        }
        observed.add(_ObservedFile(
            relative, stat.size, modified, hash, availability, platformFileId));
      }
    }

    scanPathTypeChecks++;
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      failedAreas.add('');
      issues.add(const ScanIssue(
          '', ScanIssueStage.link, 'Library root is unavailable or became a symbolic link.'));
    } else if (scopes == null || scopes.contains('')) {
      await visit(Directory(rootPath), '');
    } else {
      final ordered = scopes.toList()..sort((a,b) => a.length.compareTo(b.length));
      final visited = <String>[];
      for (final scope in ordered) {
        if (visited.any((area) => _inScope(area,scope))) continue;
        visited.add(scope);
        var safe = true;
        var current = rootPath;
        final parts = scope.split('/');
        // Check every ancestor without following links before touching a leaf.
        for (var i=0;i<parts.length;i++) {
          current = p.join(current, parts[i]);
          scanPathTypeChecks++;
          final type = await FileSystemEntity.type(current, followLinks:false);
          if (type == FileSystemEntityType.notFound) {
            // Absence needs an accessible parent. Permission or I/O failures
            // protect this scope rather than manufacturing missing tombstones.
            try {
              scanDirectoryEnumerations++;
              final siblings = await Directory(p.dirname(current)).list(followLinks:false).toList();
              if (siblings.any((entry) => _relativeKey(p.basename(entry.path)) == _relativeKey(p.basename(current)))) {
                failedAreas.add(scope); safe = false; break;
              }
            } on FileSystemException catch (error) {
              failedAreas.add(scope);
              issues.add(ScanIssue(scope,ScanIssueStage.enumeration,error.message));
              safe = false; break;
            }
          }
          if (type == FileSystemEntityType.link) {
            failedAreas.add(scope);
            issues.add(ScanIssue(scope,ScanIssueStage.link,'Symbolic link was not followed.'));
            safe = false; break;
          }
          if (i < parts.length-1 && type != FileSystemEntityType.directory) {
            if (type != FileSystemEntityType.notFound) {
              failedAreas.add(scope);
              issues.add(ScanIssue(scope,ScanIssueStage.metadata,'Parent directory is unavailable.'));
            }
            safe = false; break;
          }
          if (i == parts.length-1) {
            if (type == FileSystemEntityType.directory) await visit(Directory(current),scope);
            else if (type == FileSystemEntityType.file) {
              final parent = p.posix.dirname(scope);
              await visit(Directory(p.dirname(current)),parent == '.' ? '' : parent,[File(current)]);
            } else if (type != FileSystemEntityType.notFound) {
              failedAreas.add(scope);
              issues.add(ScanIssue(scope,ScanIssueStage.metadata,'File is unavailable.'));
            }
          }
        }
        if (!safe) continue;
      }
    }

    bool absenceConfirmed(LibraryEntry entry) =>
        inDirtyScope(entry.relativePath) &&
        !protectedFiles.any(
            (file) => _relativeKey(file) == _relativeKey(entry.relativePath)) &&
        !failedAreas.any((area) => _inScope(area, entry.relativePath));

    // Keep directory metadata in areas which could not be enumerated.
    for (final oldFolder in _snapshot.folders) {
      if (!inDirtyScope(oldFolder) || failedAreas.any((area) => _inScope(area, oldFolder))) {
        folders.add(oldFolder);
      }
    }

    for (final file in observed) {
      var folder = p.posix.dirname(file.relativePath);
      while (folder != '.' && folder.isNotEmpty) {
        folders.add(folder); folder = p.posix.dirname(folder);
      }
    }
    final matchedIds = <String>{};
    final matchedPaths = <String>{};
    final entries = <LibraryEntry>[];
    final added = <String>[];
    final modified = <String>[];
    final restored = <String>[];
    final missing = <String>[];
    final moves = <InferredMove>[];

    void match(LibraryEntry old, _ObservedFile file, {String? moveEvidence}) {
      final updated = _updateEntry(old, file, now);
      entries.add(updated);
      matchedIds.add(old.id);
      matchedPaths.add(_relativeKey(file.relativePath));
      if (updated.currentRevisionId != old.currentRevisionId) {
        modified.add(old.id);
      }
      if (old.status == EntryStatus.missing) restored.add(old.id);
      if (moveEvidence != null) {
        moves.add(InferredMove(
          entryId: old.id,
          oldPath: old.relativePath,
          newPath: file.relativePath,
          evidence: moveEvidence,
        ));
      }
    }

    for (final file in observed) {
      checkpoint();
      final old = previousByPath[_relativeKey(file.relativePath)];
      if (old != null) match(old, file);
    }

    // A provider-supplied stable OS identity can disambiguate duplicate bytes.
    final oldByIdentity =
        _groupEntries(_snapshot.entries, (entry) => entry.platformFileId);
    final newByIdentity =
        _groupObserved(observed, (file) => file.platformFileId);
    for (final file in observed) {
      if (matchedPaths.contains(_relativeKey(file.relativePath))) continue;
      final identity = file.platformFileId;
      if (identity == null) continue;
      final oldMatches = oldByIdentity[identity] ?? [];
      final newMatches = newByIdentity[identity] ?? [];
      if (oldMatches.length == 1 && newMatches.length == 1) {
        final old = oldMatches.single;
        if (!matchedIds.contains(old.id) && absenceConfirmed(old)) {
          match(old, file, moveEvidence: 'platformFileId');
        }
      }
    }

    final oldByHash = _groupEntries(
        _snapshot.entries, (entry) => entry.currentRevision.contentHash);
    final newByHash = _groupObserved(observed, (file) => file.contentHash);
    // Unknown bytes or incomplete folders cannot establish global uniqueness.
    final contentComplete = (scopes == null || scopes.contains('')) && failedAreas.isEmpty &&
        protectedFiles.isEmpty &&
        observed.every((file) =>
            file.contentHash != null &&
            file.availability == ContentAvailability.ready);
    if (contentComplete) {
      for (final file in observed) {
        if (matchedPaths.contains(_relativeKey(file.relativePath))) continue;
        final hash = file.contentHash;
        if (hash == null) continue;
        final oldMatches = oldByHash[hash] ?? [];
        final newMatches = newByHash[hash] ?? [];
        if (oldMatches.length == 1 && newMatches.length == 1) {
          final old = oldMatches.single;
          if (!matchedIds.contains(old.id) && absenceConfirmed(old)) {
            match(old, file, moveEvidence: 'uniqueContentHash');
          }
        }
      }
    }

    final newEntryIdsByHash = <String, List<String>>{};
    for (final file in observed) {
      if (matchedPaths.contains(_relativeKey(file.relativePath))) continue;
      final revision = _revision(file, now);
      final entry = LibraryEntry(
        id: _newId(),
        relativePath: file.relativePath,
        status: EntryStatus.available,
        availability: file.availability,
        revisions: [revision],
        currentRevisionId: revision.id,
        lastSeenUtc: now,
        platformFileId: file.platformFileId,
      );
      entries.add(entry);
      added.add(entry.id);
      if (file.contentHash != null) {
        newEntryIdsByHash
            .putIfAbsent(file.contentHash!, () => [])
            .add(entry.id);
      }
    }

    final missingIdsByHash = <String, List<String>>{};
    for (final old in _snapshot.entries) {
      if (matchedIds.contains(old.id)) continue;
      if (absenceConfirmed(old)) {
        entries.add(old.copyWith(status: EntryStatus.missing));
        if (old.status != EntryStatus.missing) missing.add(old.id);
        final hash = old.currentRevision.contentHash;
        if (hash != null) {
          missingIdsByHash.putIfAbsent(hash, () => []).add(old.id);
        }
      } else {
        entries.add(old);
      }
    }

    final ambiguities = <MoveAmbiguity>[];
    for (final hash in newEntryIdsByHash.keys) {
      final oldIds = missingIdsByHash[hash];
      if (oldIds != null && oldIds.isNotEmpty) {
        ambiguities.add(MoveAmbiguity(
          contentHash: hash,
          missingEntryIds: oldIds,
          newEntryIds: newEntryIdsByHash[hash]!,
        ));
      }
    }
    entries.sort((a, b) => compareLibraryPaths(a.relativePath, b.relativePath));
    final orderedFolders = folders.toList()..sort(compareLibraryPaths);
    return ScanResult(
      snapshot: LibrarySnapshot(
        rootPath: rootPath,
        generation: _snapshot.generation + 1,
        entries: entries,
        folders: orderedFolders,
        savedUtc: now,
      ),
      issues: issues,
      inferredMoves: moves,
      ambiguities: ambiguities,
      addedEntryIds: added,
      modifiedEntryIds: modified,
      restoredEntryIds: restored,
      missingEntryIds: missing,
      hasIncompleteAreas: failedAreas.isNotEmpty || protectedFiles.isNotEmpty,
    );
  }

  LibraryEntry _updateEntry(
      LibraryEntry old, _ObservedFile file, DateTime now) {
    final current = old.currentRevision;
    final metadataSame =
        current.size == file.size && current.modifiedUtc == file.modifiedUtc;
    final sameContent =
        file.contentHash != null && file.contentHash == current.contentHash;
    final enrichUnknown =
        current.contentHash == null && file.contentHash != null && metadataSame;
    final preserveUnknown = file.contentHash == null &&
        (metadataSame || file.availability == ContentAvailability.unreadable);
    final revisions = old.revisions.toList();
    var revisionId = current.id;
    if (sameContent || enrichUnknown) {
      final index =
          revisions.indexWhere((revision) => revision.id == current.id);
      revisions[index] = _revision(file, now, id: current.id);
    } else if (!preserveUnknown) {
      final next = _revision(file, now);
      revisions.add(next);
      revisionId = next.id;
    }
    return old.copyWith(
      relativePath: file.relativePath,
      status: EntryStatus.available,
      availability: file.availability,
      revisions: revisions,
      currentRevisionId: revisionId,
      lastSeenUtc: now,
      platformFileId: file.platformFileId,
    );
  }

  ContentRevision _revision(_ObservedFile file, DateTime now, {String? id}) =>
      ContentRevision(
        id: id ?? _newId(),
        contentHash: file.contentHash,
        size: file.size,
        modifiedUtc: file.modifiedUtc,
        observedUtc: now,
      );

  Future<T> _withLock<T>(Future<T> Function() action) async {
    final key = _absoluteKey(statePath);
    if (!_activeWriters.add(key)) {
      throw const ConcurrentCatalogWriteException(
          'This catalogue already has an operation in progress.');
    }
    RandomAccessFile? handle;
    var locked = false;
    try {
      await Directory(p.dirname(statePath)).create(recursive: true);
      handle = await File('$statePath.lock').open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException catch (error) {
        throw ConcurrentCatalogWriteException(
            'Another process holds the catalogue lock: ${error.message}');
      }
      return await action();
    } finally {
      try {
        if (handle != null) {
          try {
            if (locked) await handle.unlock();
          } finally {
            await handle.close();
          }
        }
      } finally {
        _activeWriters.remove(key);
      }
    }
  }

  Future<LibrarySnapshot> _loadSnapshot() async {
    final primary = File(statePath);
    final backup = File('$statePath.backup');
    final hasPrimary = await primary.exists();
    final hasBackup = await backup.exists();
    if (!hasPrimary && !hasBackup) {
      return LibrarySnapshot(
          rootPath: rootPath,
          generation: 0,
          entries: [],
          folders: [''],
          savedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    Object? primaryFailure;
    final primaryObserved = await _readStateStamp();
    if (hasPrimary) {
      try {
        final before = await _readStateStamp();
        final decoded = await _decodeSnapshot(primary);
        final after = await _readStateStamp();
        if (before != after)
          throw const ConcurrentCatalogWriteException(
              'The catalogue changed while it was being read.');
        _stateStamp = after;
        _backupStamp = null;
        return decoded;
      } catch (error) {
        primaryFailure = error;
      }
    }
    if (hasBackup) {
      try {
        final before = await _readStateStamp(backup.path);
        final recovered = await _decodeSnapshot(backup);
        final after = await _readStateStamp(backup.path);
        if (before != after || primaryObserved != await _readStateStamp()) {
          throw const ConcurrentCatalogWriteException(
              'Recovered catalogue changed while reading.');
        }
        _stateStamp = primaryObserved;
        _backupStamp = after;
        final warning = 'Recovered catalogue generation '
            '${recovered.generation} from backup; primary was missing or invalid.';
        if (!_storageWarnings.contains(warning)) _storageWarnings.add(warning);
        return recovered;
      } catch (backupError) {
        throw CatalogStorageException('Primary and backup could not be read. '
            'Primary: $primaryFailure; backup: $backupError');
      }
    }
    throw CatalogStorageException(
        'Catalogue is invalid and has no valid backup: $primaryFailure');
  }

  Future<LibrarySnapshot> _decodeSnapshot(File file) async {
    final encoded = await file.readAsString();
    catalogReads++;
    catalogReadBytes += await file.length();
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    if (json['schemaVersion'] != _schemaVersion) {
      throw const CatalogStorageException('Unsupported catalogue schema.');
    }
    if (_absoluteKey(json['rootPath'] as String) != _absoluteKey(rootPath)) {
      throw const CatalogStorageException(
          'The state file belongs to a different library root.');
    }
    final entries = (json['entries'] as List)
        .map((value) =>
            LibraryEntry.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    final ids = <String>{};
    for (final entry in entries) {
      _relativeScope(entry.relativePath);
      if (entry.id.isEmpty || !ids.add(entry.id)) {
        throw const CatalogStorageException('Duplicate or empty entry ID.');
      }
    }
    final folders = (json['folders'] as List).cast<String>();
    for (final folder in folders) {
      _relativeScope(folder);
    }
    return LibrarySnapshot(
      rootPath: rootPath,
      generation: json['generation'] as int,
      entries: entries,
      folders: folders,
      savedUtc: DateTime.parse(json['savedUtc'] as String).toUtc(),
    );
  }

  Future<void> _saveSnapshot(LibrarySnapshot snapshot) async {
    final primary = File(statePath);
    final backup = File('$statePath.backup');
    final temporary = File('$statePath.tmp.${_newId()}');
    final encoded = jsonEncode({
      'schemaVersion': _schemaVersion,
      'rootPath': rootPath,
      'generation': snapshot.generation,
      'savedUtc': snapshot.savedUtc.toIso8601String(),
      'folders': snapshot.folders,
      'entries': snapshot.entries.map((entry) => entry.toJson()).toList(),
    });
    await temporary.writeAsString(encoded, flush: true);
    catalogWrites++;
    catalogWriteBytes += await temporary.length();
    try {
      if (await primary.exists()) {
        var primaryValid = _backupStamp == null && await matchesDisk();
        if (!primaryValid) {
          try {
            await _decodeSnapshot(primary);
            primaryValid = true;
          } catch (_) {
            // Preserve the valid backup when replacing a corrupt primary.
          }
        }
        if (primaryValid) {
          if (await backup.exists()) await backup.delete();
          await primary.rename(backup.path);
        } else {
          await primary.rename('$statePath.corrupt.${_newId()}');
        }
      }
      await temporary.rename(statePath);
      _stateStamp = await _readStateStamp();
      _backupStamp = null;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<String> _canonicalize(String path) async {
    final absolute = p.normalize(p.absolute(path));
    final type = await FileSystemEntity.type(absolute);
    if (type != FileSystemEntityType.notFound) {
      return p.normalize(await File(absolute).resolveSymbolicLinks());
    }
    final parent = p.dirname(absolute);
    if (parent == absolute) return absolute;
    return p.join(await _canonicalize(parent), p.basename(absolute));
  }

  static String _absoluteKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static String _relativeKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static bool _atOrWithin(String root, String candidate) {
    final rootKey = _absoluteKey(root);
    final candidateKey = _absoluteKey(candidate);
    return rootKey == candidateKey || p.isWithin(rootKey, candidateKey);
  }

  static String _relativeScope(String value) {
    final normalized = p.posix.normalize(value.replaceAll('\\', '/'));
    if (p.posix.isAbsolute(normalized) ||
        p.windows.isAbsolute(value) ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw ArgumentError.value(
          value, 'relativePath', 'Must remain in library.');
    }
    return normalized == '.' ? '' : normalized;
  }

  static bool _inScope(String folder, String candidate) {
    final parent = _relativeKey(folder);
    final path = _relativeKey(candidate);
    return parent.isEmpty || path == parent || path.startsWith('$parent/');
  }

  static String _parentPath(String path) {
    final parent = p.posix.dirname(path);
    return parent == '.' ? '' : parent;
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
      '${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  static Map<String, List<LibraryEntry>> _groupEntries(
      Iterable<LibraryEntry> entries, String? Function(LibraryEntry) value) {
    final groups = <String, List<LibraryEntry>>{};
    for (final entry in entries) {
      final key = value(entry);
      if (key != null) groups.putIfAbsent(key, () => []).add(entry);
    }
    return groups;
  }

  static Map<String, List<_ObservedFile>> _groupObserved(
      Iterable<_ObservedFile> files, String? Function(_ObservedFile) value) {
    final groups = <String, List<_ObservedFile>>{};
    for (final file in files) {
      final key = value(file);
      if (key != null) groups.putIfAbsent(key, () => []).add(file);
    }
    return groups;
  }
}

class _ObservedFile {
  const _ObservedFile(this.relativePath, this.size, this.modifiedUtc,
      this.contentHash, this.availability, this.platformFileId);

  final String relativePath;
  final int size;
  final DateTime modifiedUtc;
  final String? contentHash;
  final ContentAvailability availability;
  final String? platformFileId;
}
