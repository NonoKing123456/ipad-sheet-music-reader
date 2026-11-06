/// The library's existing case-insensitive path order, with a stable case tie.
int compareLibraryPaths(String a, String b) {
  final insensitive = a.toLowerCase().compareTo(b.toLowerCase());
  return insensitive != 0 ? insensitive : a.compareTo(b);
}

enum EntryStatus { available, missing }

enum ContentAvailability { ready, deferred, unreadable }

enum FileAccess { ordinary, deferred }

enum ScanIssueStage { enumeration, metadata, content, link, identity, deferred }

class ScanIssue {
  const ScanIssue(this.relativePath, this.stage, this.message);

  final String relativePath;
  final ScanIssueStage stage;
  final String message;
}

class ContentRevision {
  const ContentRevision({
    required this.id,
    required this.contentHash,
    required this.size,
    required this.modifiedUtc,
    required this.observedUtc,
  });

  final String id;
  final String? contentHash;
  final int size;
  final DateTime modifiedUtc;
  final DateTime observedUtc;

  Map<String, Object?> toJson() => {
        'id': id,
        'contentHash': contentHash,
        'size': size,
        'modifiedUtc': modifiedUtc.toIso8601String(),
        'observedUtc': observedUtc.toIso8601String(),
      };

  factory ContentRevision.fromJson(Map<String, dynamic> json) =>
      ContentRevision(
        id: json['id'] as String,
        contentHash: json['contentHash'] as String?,
        size: json['size'] as int,
        modifiedUtc: DateTime.parse(json['modifiedUtc'] as String).toUtc(),
        observedUtc: DateTime.parse(json['observedUtc'] as String).toUtc(),
      );
}

class LibraryEntry {
  LibraryEntry({
    required this.id,
    required this.relativePath,
    required this.status,
    required this.availability,
    required List<ContentRevision> revisions,
    required this.currentRevisionId,
    required this.lastSeenUtc,
    this.platformFileId,
  }) : revisions = List.unmodifiable(revisions) {
    if (revisions.isEmpty ||
        !revisions.any((revision) => revision.id == currentRevisionId)) {
      throw ArgumentError('An entry must reference an existing revision.');
    }
  }

  final String id;
  final String relativePath;
  final EntryStatus status;
  final ContentAvailability availability;
  final List<ContentRevision> revisions;
  final String currentRevisionId;
  final DateTime lastSeenUtc;
  final String? platformFileId;

  ContentRevision get currentRevision =>
      revisions.firstWhere((revision) => revision.id == currentRevisionId);

  LibraryEntry copyWith({
    String? relativePath,
    EntryStatus? status,
    ContentAvailability? availability,
    List<ContentRevision>? revisions,
    String? currentRevisionId,
    DateTime? lastSeenUtc,
    String? platformFileId,
  }) =>
      LibraryEntry(
        id: id,
        relativePath: relativePath ?? this.relativePath,
        status: status ?? this.status,
        availability: availability ?? this.availability,
        revisions: revisions ?? this.revisions,
        currentRevisionId: currentRevisionId ?? this.currentRevisionId,
        lastSeenUtc: lastSeenUtc ?? this.lastSeenUtc,
        platformFileId: platformFileId ?? this.platformFileId,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'relativePath': relativePath,
        'status': status.name,
        'availability': availability.name,
        'revisions': revisions.map((revision) => revision.toJson()).toList(),
        'currentRevisionId': currentRevisionId,
        'lastSeenUtc': lastSeenUtc.toIso8601String(),
        'platformFileId': platformFileId,
      };

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
        id: json['id'] as String,
        relativePath: json['relativePath'] as String,
        status: EntryStatus.values.byName(json['status'] as String),
        availability:
            ContentAvailability.values.byName(json['availability'] as String),
        revisions: (json['revisions'] as List)
            .map((value) => ContentRevision.fromJson(
                Map<String, dynamic>.from(value as Map)))
            .toList(),
        currentRevisionId: json['currentRevisionId'] as String,
        lastSeenUtc: DateTime.parse(json['lastSeenUtc'] as String).toUtc(),
        platformFileId: json['platformFileId'] as String?,
      );
}

class LibrarySnapshot {
  LibrarySnapshot({
    required this.rootPath,
    required this.generation,
    required List<LibraryEntry> entries,
    required List<String> folders,
    required this.savedUtc,
  })  : entries = List.unmodifiable(entries),
        folders = List.unmodifiable(folders);

  LibrarySnapshot._replacement(
      {required this.rootPath,
      required this.generation,
      required this.entries,
      required this.folders,
      required this.savedUtc});

  final String rootPath;
  final int generation;
  final List<LibraryEntry> entries;
  final List<String> folders;
  final DateTime savedUtc;

  List<LibraryEntry>? _availableEntries;
  Map<String, LibraryEntry>? _entriesById;
  List<LibraryEntry> get availableEntries =>
      _availableEntries ??= List.unmodifiable(
          entries.where((entry) => entry.status == EntryStatus.available));

  Map<String, LibraryEntry> _indexEntries() {
    final result = <String, LibraryEntry>{};
    for (final entry in entries) {
      result.putIfAbsent(entry.id, () => entry);
    }
    return result;
  }

  LibraryEntry? entryById(String id) => (_entriesById ??= _indexEntries())[id];

  LibrarySnapshot withGeneration(int generation) {
    final next = LibrarySnapshot._replacement(
        rootPath: rootPath,
        generation: generation,
        entries: entries,
        folders: folders,
        savedUtc: savedUtc);
    next._entriesById = _entriesById;
    next._availableEntries = _availableEntries;
    return next;
  }

  /// Replace a bounded selected set with one immutable list/map copy.
  LibrarySnapshot replacingEntries(Iterable<LibraryEntry> replacements,
      {required int generation, required DateTime savedUtc}) {
    final changed = {for (final entry in replacements) entry.id: entry};
    for (final id in changed.keys) {
      if (entryById(id) == null) throw StateError('Unknown replacement entry.');
    }
    final next = LibrarySnapshot._replacement(
        rootPath: rootPath,
        generation: generation,
        entries: List.unmodifiable(
            [for (final entry in entries) changed[entry.id] ?? entry]),
        folders: folders,
        savedUtc: savedUtc);
    next._entriesById = Map.of(_entriesById!)..addAll(changed);
    if (_availableEntries != null &&
        changed.values
            .every((entry) => entryById(entry.id)!.status == entry.status)) {
      next._availableEntries = List.unmodifiable(
          [for (final entry in _availableEntries!) changed[entry.id] ?? entry]);
    }
    return next;
  }

  /// Replacing one ready/deferred revision preserves sibling object identities
  /// and lookup caches. Old immutable snapshots keep their own maps/lists.
  LibrarySnapshot replacingEntry(LibraryEntry replacement,
      {required int generation, required DateTime savedUtc}) {
    final previous = entryById(replacement.id);
    if (previous == null) throw StateError('Unknown replacement entry.');
    final next = LibrarySnapshot._replacement(
        rootPath: rootPath,
        generation: generation,
        entries: List.unmodifiable([
          for (final entry in entries)
            entry.id == replacement.id ? replacement : entry
        ]),
        folders: folders,
        savedUtc: savedUtc);
    next._entriesById = Map.of(_entriesById!)..[replacement.id] = replacement;
    if (_availableEntries != null && previous.status == replacement.status) {
      next._availableEntries = List.unmodifiable([
        for (final entry in _availableEntries!)
          entry.id == replacement.id ? replacement : entry,
      ]);
    }
    return next;
  }
}

/// Immutable hierarchy shared by both directory views. Building visible row
/// metadata is linear in folders; widget creation can stay viewport-limited.
class FolderHierarchy {
  FolderHierarchy(Iterable<String> folders) {
    for (final folder in folders) {
      if (folder.isEmpty) continue;
      final slash = folder.lastIndexOf('/');
      final parent = slash < 0 ? '' : folder.substring(0, slash);
      (_children[parent] ??= []).add(folder);
    }
    for (final children in _children.values) {
      children.sort();
    }
  }
  final _children = <String, List<String>>{};
  List<String> childrenOf(String folder) => _children[folder] ?? const [];

  List<FolderTreeRow> visibleRows(Set<String> collapsed) {
    final result = <FolderTreeRow>[];
    final pending = <FolderTreeRow>[
      for (final root in childrenOf('').reversed) FolderTreeRow(root, 1),
    ];
    while (pending.isNotEmpty) {
      final row = pending.removeLast();
      result.add(row);
      if (!collapsed.contains(row.path)) {
        for (final child in childrenOf(row.path).reversed) {
          pending.add(FolderTreeRow(child, row.depth + 1));
        }
      }
    }
    return result;
  }
}

class FolderTreeRow {
  const FolderTreeRow(this.path, this.depth);
  final String path;
  final int depth;
}

class InferredMove {
  const InferredMove({
    required this.entryId,
    required this.oldPath,
    required this.newPath,
    required this.evidence,
  });

  final String entryId;
  final String oldPath;
  final String newPath;
  final String evidence;
}

class MoveAmbiguity {
  MoveAmbiguity({
    required this.contentHash,
    required List<String> missingEntryIds,
    required List<String> newEntryIds,
  })  : missingEntryIds = List.unmodifiable(missingEntryIds),
        newEntryIds = List.unmodifiable(newEntryIds);

  final String contentHash;
  final List<String> missingEntryIds;
  final List<String> newEntryIds;
}

class ScanResult {
  ScanResult({
    required this.snapshot,
    required List<ScanIssue> issues,
    required List<InferredMove> inferredMoves,
    required List<MoveAmbiguity> ambiguities,
    required List<String> addedEntryIds,
    required List<String> modifiedEntryIds,
    required List<String> restoredEntryIds,
    required List<String> missingEntryIds,
    required this.hasIncompleteAreas,
  })  : issues = List.unmodifiable(issues),
        inferredMoves = List.unmodifiable(inferredMoves),
        ambiguities = List.unmodifiable(ambiguities),
        addedEntryIds = List.unmodifiable(addedEntryIds),
        modifiedEntryIds = List.unmodifiable(modifiedEntryIds),
        restoredEntryIds = List.unmodifiable(restoredEntryIds),
        missingEntryIds = List.unmodifiable(missingEntryIds);

  final LibrarySnapshot snapshot;
  final List<ScanIssue> issues;
  final List<InferredMove> inferredMoves;
  final List<MoveAmbiguity> ambiguities;
  final List<String> addedEntryIds;
  final List<String> modifiedEntryIds;
  final List<String> restoredEntryIds;
  final List<String> missingEntryIds;
  final bool hasIncompleteAreas;
}

class FolderListing {
  FolderListing(
      {required List<String> folders, required List<LibraryEntry> entries})
      : folders = List.unmodifiable(folders),
        entries = List.unmodifiable(entries);

  /// Paths are relative to the library root and use '/' on every platform.
  final List<String> folders;
  final List<LibraryEntry> entries;
}

class CatalogStorageException implements Exception {
  const CatalogStorageException(this.message);
  final String message;
  @override
  String toString() => 'CatalogStorageException: $message';
}

class ConcurrentCatalogWriteException implements Exception {
  const ConcurrentCatalogWriteException(this.message);
  final String message;
  @override
  String toString() => 'ConcurrentCatalogWriteException: $message';
}

/// Cooperative cancellation before a background scan commits. No snapshot was
/// published; the caller may coalesce and reschedule the scan while idle.
class CatalogScanYielded implements Exception {
  const CatalogScanYielded();
}
