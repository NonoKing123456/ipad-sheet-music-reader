typedef StrokePathRebuilder = Map<String, List<List<NormalizedPoint>>> Function(
    List<AnnotationStroke> strokes);

enum AnnotationTool { pen, highlighter }

void requireNonEmptyId(String value, String name) {
  if (value.trim().isEmpty)
    throw ArgumentError.value(value, name, 'Must not be empty.');
}

class DocumentKey {
  DocumentKey({required this.entryId, required this.revisionId}) {
    requireNonEmptyId(entryId, 'entryId');
    requireNonEmptyId(revisionId, 'revisionId');
  }

  final String entryId;
  final String revisionId;

  Map<String, Object?> toJson() =>
      {'entryId': entryId, 'revisionId': revisionId};

  factory DocumentKey.fromJson(Map<String, dynamic> json) => DocumentKey(
      entryId: json['entryId'] as String,
      revisionId: json['revisionId'] as String);

  @override
  bool operator ==(Object other) =>
      other is DocumentKey &&
      other.entryId == entryId &&
      other.revisionId == revisionId;
  @override
  int get hashCode => Object.hash(entryId, revisionId);
}

class PageKey {
  PageKey(
      {required this.entryId,
      required this.revisionId,
      required this.pageNumber}) {
    requireNonEmptyId(entryId, 'entryId');
    requireNonEmptyId(revisionId, 'revisionId');
    if (pageNumber < 1)
      throw ArgumentError.value(pageNumber, 'pageNumber', 'Starts at 1.');
  }

  final String entryId;
  final String revisionId;
  final int pageNumber;

  DocumentKey get document =>
      DocumentKey(entryId: entryId, revisionId: revisionId);

  Map<String, Object?> toJson() => {
        'entryId': entryId,
        'revisionId': revisionId,
        'pageNumber': pageNumber,
      };
  factory PageKey.fromJson(Map<String, dynamic> json) => PageKey(
      entryId: json['entryId'] as String,
      revisionId: json['revisionId'] as String,
      pageNumber: json['pageNumber'] as int);

  @override
  bool operator ==(Object other) =>
      other is PageKey &&
      other.entryId == entryId &&
      other.revisionId == revisionId &&
      other.pageNumber == pageNumber;
  @override
  int get hashCode => Object.hash(entryId, revisionId, pageNumber);
}

class NormalizedPoint {
  NormalizedPoint(this.x, this.y) {
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw ArgumentError('Coordinates must be finite and between 0 and 1.');
    }
  }
  final double x;
  final double y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
  factory NormalizedPoint.fromJson(Map<String, dynamic> json) =>
      NormalizedPoint(
          (json['x'] as num).toDouble(), (json['y'] as num).toDouble());
  @override
  bool operator ==(Object other) =>
      other is NormalizedPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}

class StrokeStyle {
  StrokeStyle(
      {required this.tool, required this.argb, required this.widthFraction}) {
    if (argb < 0 || argb > 0xffffffff)
      throw ArgumentError.value(argb, 'argb', 'Requires ARGB32.');
    if (!widthFraction.isFinite || widthFraction <= 0 || widthFraction > 1) {
      throw ArgumentError.value(
          widthFraction, 'widthFraction', 'Must be in (0, 1].');
    }
  }
  final AnnotationTool tool;
  final int argb;

  /// A fraction of the unrotated page's shorter dimension.
  final double widthFraction;
  Map<String, Object?> toJson() => {
        'tool': tool.name,
        'argb': argb,
        'widthFraction': widthFraction,
      };
  factory StrokeStyle.fromJson(Map<String, dynamic> json) => StrokeStyle(
      tool: AnnotationTool.values.byName(json['tool'] as String),
      argb: json['argb'] as int,
      widthFraction: (json['widthFraction'] as num).toDouble());
}

class AnnotationStroke {
  AnnotationStroke(
      {required this.id,
      required this.style,
      required List<NormalizedPoint> points,
      required this.createdUtc,
      required this.updatedUtc,
      required this.version,
      this.deletedUtc})
      : points = List.unmodifiable(points) {
    requireNonEmptyId(id, 'strokeId');
    if (points.isEmpty)
      throw ArgumentError('A stroke needs at least one point.');
    if (version < 1) throw ArgumentError.value(version, 'version');
  }
  final String id;
  final StrokeStyle style;
  final List<NormalizedPoint> points;
  final DateTime createdUtc;
  final DateTime updatedUtc;
  final int version;
  final DateTime? deletedUtc;
  bool get isDeleted => deletedUtc != null;

  AnnotationStroke withDeletion(bool deleted, DateTime now) => AnnotationStroke(
        id: id,
        style: style,
        points: points,
        createdUtc: createdUtc,
        updatedUtc: now,
        version: version + 1,
        deletedUtc: deleted ? now : null,
      );
  Map<String, Object?> toJson() => {
        'id': id,
        'style': style.toJson(),
        'points': points.map((point) => point.toJson()).toList(),
        'createdUtc': createdUtc.toUtc().toIso8601String(),
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
        'version': version,
        'deletedUtc': deletedUtc?.toUtc().toIso8601String(),
      };
  factory AnnotationStroke.fromJson(Map<String, dynamic> json) =>
      AnnotationStroke(
        id: json['id'] as String,
        style: StrokeStyle.fromJson(
            Map<String, dynamic>.from(json['style'] as Map)),
        points: (json['points'] as List)
            .map((point) => NormalizedPoint.fromJson(
                Map<String, dynamic>.from(point as Map)))
            .toList(),
        createdUtc: DateTime.parse(json['createdUtc'] as String).toUtc(),
        updatedUtc: DateTime.parse(json['updatedUtc'] as String).toUtc(),
        version: json['version'] as int,
        deletedUtc: json['deletedUtc'] == null
            ? null
            : DateTime.parse(json['deletedUtc'] as String).toUtc(),
      );
}

class SetListItem {
  SetListItem(
      {required this.id,
      required this.entryId,
      required this.createdUtc,
      required this.updatedUtc,
      required this.version,
      this.removedUtc}) {
    requireNonEmptyId(id, 'itemId');
    requireNonEmptyId(entryId, 'entryId');
    if (version < 1) throw ArgumentError.value(version, 'version');
  }
  final String id;
  final String entryId;
  final DateTime createdUtc;
  final DateTime updatedUtc;
  final int version;
  final DateTime? removedUtc;
  bool get isRemoved => removedUtc != null;

  SetListItem withRemoval(DateTime now) => SetListItem(
      id: id,
      entryId: entryId,
      createdUtc: createdUtc,
      updatedUtc: now,
      version: version + 1,
      removedUtc: now);
  Map<String, Object?> toJson() => {
        'id': id,
        'entryId': entryId,
        'createdUtc': createdUtc.toUtc().toIso8601String(),
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
        'version': version,
        'removedUtc': removedUtc?.toUtc().toIso8601String(),
      };
  factory SetListItem.fromJson(Map<String, dynamic> json) => SetListItem(
        id: json['id'] as String,
        entryId: json['entryId'] as String,
        createdUtc: DateTime.parse(json['createdUtc'] as String).toUtc(),
        updatedUtc: DateTime.parse(json['updatedUtc'] as String).toUtc(),
        version: json['version'] as int,
        removedUtc: json['removedUtc'] == null
            ? null
            : DateTime.parse(json['removedUtc'] as String).toUtc(),
      );
}

class ScoreSetList {
  ScoreSetList(
      {required this.id,
      required this.name,
      required List<SetListItem> items,
      required this.createdUtc,
      required this.updatedUtc,
      required this.version,
      this.deletedUtc})
      : items = List.unmodifiable(items) {
    requireNonEmptyId(id, 'setListId');
    if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
    if (version < 1) throw ArgumentError.value(version, 'version');
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw ArgumentError('Set list item IDs must be unique.');
    }
  }
  final String id;
  final String name;
  final List<SetListItem> items;
  final DateTime createdUtc;
  final DateTime updatedUtc;
  final int version;
  final DateTime? deletedUtc;
  bool get isDeleted => deletedUtc != null;
  List<SetListItem> get activeItems =>
      List.unmodifiable(items.where((item) => !item.isRemoved));

  ScoreSetList updated(DateTime now,
          {String? name, List<SetListItem>? items, bool deleted = false}) =>
      ScoreSetList(
          id: id,
          name: name ?? this.name,
          items: items ?? this.items,
          createdUtc: createdUtc,
          updatedUtc: now,
          version: version + 1,
          deletedUtc: deleted ? now : deletedUtc);
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'items': items.map((item) => item.toJson()).toList(),
        'createdUtc': createdUtc.toUtc().toIso8601String(),
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
        'version': version,
        'deletedUtc': deletedUtc?.toUtc().toIso8601String(),
      };
  factory ScoreSetList.fromJson(Map<String, dynamic> json) => ScoreSetList(
        id: json['id'] as String,
        name: json['name'] as String,
        items: (json['items'] as List)
            .map((item) =>
                SetListItem.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        createdUtc: DateTime.parse(json['createdUtc'] as String).toUtc(),
        updatedUtc: DateTime.parse(json['updatedUtc'] as String).toUtc(),
        version: json['version'] as int,
        deletedUtc: json['deletedUtc'] == null
            ? null
            : DateTime.parse(json['deletedUtc'] as String).toUtc(),
      );
}

class ReadingBookmark {
  ReadingBookmark(
      {required this.document,
      required this.pageNumber,
      required this.pageCount,
      required this.updatedUtc}) {
    if (pageCount < 1 || pageNumber < 1 || pageNumber > pageCount) {
      throw ArgumentError('Reading position must be in the known page range.');
    }
  }
  final DocumentKey document;
  final int pageNumber;
  final int pageCount;
  final DateTime updatedUtc;
  Map<String, Object?> toJson() => {
        'document': document.toJson(),
        'pageNumber': pageNumber,
        'pageCount': pageCount,
        'updatedUtc': updatedUtc.toUtc().toIso8601String(),
      };
  factory ReadingBookmark.fromJson(Map<String, dynamic> json) =>
      ReadingBookmark(
        document: DocumentKey.fromJson(
            Map<String, dynamic>.from(json['document'] as Map)),
        pageNumber: json['pageNumber'] as int,
        pageCount: json['pageCount'] as int,
        updatedUtc: DateTime.parse(json['updatedUtc'] as String).toUtc(),
      );
}

/// Both complete competing records are retained for inspection/recovery by UI.
Object? _freezeConflictJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeConflictJson(entry.value)
    });
  }
  if (value is List)
    return List<Object?>.unmodifiable(value.map(_freezeConflictJson));
  return value;
}

class MergeConflict {
  MergeConflict(
      {required this.id,
      required this.kind,
      required this.objectKey,
      required this.peerId,
      required Map<String, Object?> first,
      required Map<String, Object?> second})
      : first = _freezeConflictJson(first) as Map<String, Object?>,
        second = _freezeConflictJson(second) as Map<String, Object?>;
  final String id;
  final String kind;
  final String objectKey;
  final String peerId;
  final Map<String, Object?> first;
  final Map<String, Object?> second;
  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'objectKey': objectKey,
        'peerId': peerId,
        'first': first,
        'second': second
      };
  factory MergeConflict.fromJson(Map<String, dynamic> json) => MergeConflict(
      id: json['id'] as String,
      kind: json['kind'] as String,
      objectKey: json['objectKey'] as String,
      peerId: json['peerId'] as String,
      first: Map<String, Object?>.from(json['first'] as Map),
      second: Map<String, Object?>.from(json['second'] as Map));
}

class ReaderSnapshot {
  static const schemaVersion = 2;

  ReaderSnapshot(
      {required this.generation,
      required Map<PageKey, List<AnnotationStroke>> pages,
      required List<ScoreSetList> setLists,
      required Map<DocumentKey, ReadingBookmark> bookmarks,
      List<MergeConflict> conflicts = const [],
      Set<String> mergeReceipts = const {}})
      : pages = Map.unmodifiable(pages.map((key, value) =>
            MapEntry(key, List<AnnotationStroke>.unmodifiable(value)))),
        setLists = List.unmodifiable(setLists),
        bookmarks = Map.unmodifiable(bookmarks),
        conflicts = List.unmodifiable(conflicts),
        mergeReceipts = Set.unmodifiable(mergeReceipts) {
    if (generation < 0) throw ArgumentError.value(generation, 'generation');
    final strokeIds = <String>{};
    for (final strokes in pages.values) {
      for (final stroke in strokes) {
        if (!strokeIds.add(stroke.id))
          throw ArgumentError('Duplicate stroke ID.');
      }
    }
    if (setLists.map((list) => list.id).toSet().length != setLists.length) {
      throw ArgumentError('Duplicate set list ID.');
    }
    final itemIds = <String>{};
    for (final list in setLists) {
      for (final item in list.items) {
        if (!itemIds.add(item.id))
          throw ArgumentError('Duplicate set list item ID.');
      }
    }
    for (final entry in bookmarks.entries) {
      if (entry.key != entry.value.document) {
        throw ArgumentError('Bookmark map key must match its document.');
      }
    }
  }
  factory ReaderSnapshot.empty() =>
      ReaderSnapshot(generation: 0, pages: {}, setLists: [], bookmarks: {});
  final int generation;
  final Map<PageKey, List<AnnotationStroke>> pages;
  final List<ScoreSetList> setLists;
  final Map<DocumentKey, ReadingBookmark> bookmarks;
  final List<MergeConflict> conflicts;

  /// Durable replay protection, committed with the merged data.
  final Set<String> mergeReceipts;
  List<AnnotationStroke> strokesFor(PageKey key,
          {bool includeDeleted = false}) =>
      List.unmodifiable((pages[key] ?? [])
          .where((stroke) => includeDeleted || !stroke.isDeleted));
  List<ScoreSetList> get activeSetLists =>
      List.unmodifiable(setLists.where((list) => !list.isDeleted));
  ReadingBookmark? bookmarkFor(DocumentKey key) => bookmarks[key];
  ScoreSetList? setListById(String id) {
    for (final list in setLists) {
      if (list.id == id) return list;
    }
    return null;
  }

  ReaderSnapshot next(
          {Map<PageKey, List<AnnotationStroke>>? pages,
          List<ScoreSetList>? setLists,
          Map<DocumentKey, ReadingBookmark>? bookmarks,
          List<MergeConflict>? conflicts,
          Set<String>? mergeReceipts}) =>
      ReaderSnapshot(
          generation: generation + 1,
          pages: pages ?? this.pages,
          setLists: setLists ?? this.setLists,
          bookmarks: bookmarks ?? this.bookmarks,
          conflicts: conflicts ?? this.conflicts,
          mergeReceipts: mergeReceipts ?? this.mergeReceipts);

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'generation': generation,
        'conflicts': conflicts.map((conflict) => conflict.toJson()).toList(),
        'mergeReceipts': mergeReceipts.toList()..sort(),
        'pages': pages.entries
            .map((entry) => {
                  'key': entry.key.toJson(),
                  'strokes':
                      entry.value.map((stroke) => stroke.toJson()).toList(),
                })
            .toList(),
        'setLists': setLists.map((list) => list.toJson()).toList(),
        'bookmarks':
            bookmarks.values.map((bookmark) => bookmark.toJson()).toList(),
      };

  factory ReaderSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 && json['schemaVersion'] != schemaVersion) {
      throw UnsupportedReaderSchemaException(json['schemaVersion']);
    }
    final pages = <PageKey, List<AnnotationStroke>>{};
    for (final raw in json['pages'] as List) {
      final page = Map<String, dynamic>.from(raw as Map);
      final key =
          PageKey.fromJson(Map<String, dynamic>.from(page['key'] as Map));
      if (pages.containsKey(key))
        throw const FormatException('Duplicate page key.');
      pages[key] = (page['strokes'] as List)
          .map((stroke) => AnnotationStroke.fromJson(
              Map<String, dynamic>.from(stroke as Map)))
          .toList();
    }
    final bookmarks = <DocumentKey, ReadingBookmark>{};
    for (final raw in json['bookmarks'] as List) {
      final bookmark =
          ReadingBookmark.fromJson(Map<String, dynamic>.from(raw as Map));
      if (bookmarks.containsKey(bookmark.document))
        throw const FormatException('Duplicate bookmark.');
      bookmarks[bookmark.document] = bookmark;
    }
    return ReaderSnapshot(
        generation: json['generation'] as int,
        pages: pages,
        setLists: (json['setLists'] as List)
            .map((list) =>
                ScoreSetList.fromJson(Map<String, dynamic>.from(list as Map)))
            .toList(),
        bookmarks: bookmarks,
        conflicts: (json['conflicts'] as List? ?? [])
            .map((value) =>
                MergeConflict.fromJson(Map<String, dynamic>.from(value as Map)))
            .toList(),
        mergeReceipts:
            (json['mergeReceipts'] as List? ?? []).cast<String>().toSet());
  }
}

class ReaderStorageException implements Exception {
  const ReaderStorageException(this.message);
  final String message;
  @override
  String toString() => 'ReaderStorageException: $message';
}

class UnsupportedReaderSchemaException implements Exception {
  const UnsupportedReaderSchemaException(this.version);
  final Object? version;
  @override
  String toString() => 'UnsupportedReaderSchemaException: $version';
}

class ConcurrentReaderWriteException implements Exception {
  const ConcurrentReaderWriteException(this.message);
  final String message;
  @override
  String toString() => 'ConcurrentReaderWriteException: $message';
}
