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

  final String rootPath;
  final int generation;
  final List<LibraryEntry> entries;
  final List<String> folders;
  final DateTime savedUtc;

  Iterable<LibraryEntry> get availableEntries =>
      entries.where((entry) => entry.status == EntryStatus.available);

  LibraryEntry? entryById(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }
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
