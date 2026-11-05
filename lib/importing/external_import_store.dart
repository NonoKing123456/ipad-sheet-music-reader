import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../reader/reader_session.dart';

typedef ImportCopy = Future<void> Function(String source, String destination);

enum ImportDisposition { temporary, retained, saved }

class ImportedScore {
  const ImportedScore({
    required this.id,
    required this.name,
    required this.extension,
    required this.hash,
    required this.receivedAt,
    required this.disposition,
    this.originId,
    this.savedPath,
    this.catalogEntryId,
    this.catalogRevisionId,
    this.mirrorPending = false,
  });
  final String id, name, extension, hash;
  final DateTime receivedAt;
  final ImportDisposition disposition;
  final String? originId, savedPath, catalogEntryId, catalogRevisionId;
  final bool mirrorPending;
  bool get saved => disposition == ImportDisposition.saved;
  ImportedScore changed({
    ImportDisposition? disposition,
    String? savedPath,
    String? catalogEntryId,
    String? catalogRevisionId,
    bool? mirrorPending,
  }) => ImportedScore(
    id: id,
    name: name,
    extension: extension,
    hash: hash,
    receivedAt: receivedAt,
    originId: originId,
    disposition: disposition ?? this.disposition,
    savedPath: savedPath ?? this.savedPath,
    catalogEntryId: catalogEntryId ?? this.catalogEntryId,
    catalogRevisionId: catalogRevisionId ?? this.catalogRevisionId,
    mirrorPending: mirrorPending ?? this.mirrorPending,
  );
  Map<String, Object?> toJson() => {
    'schema': 1,
    'id': id,
    'name': name,
    'extension': extension,
    'hash': hash,
    'receivedAt': receivedAt.toIso8601String(),
    'disposition': disposition.name,
    'originId': originId,
    'savedPath': savedPath,
    'catalogEntryId': catalogEntryId,
    'catalogRevisionId': catalogRevisionId,
    'mirrorPending': mirrorPending,
  };
  factory ImportedScore.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(json['id'] as String? ?? '') ||
        !ExternalImportStore.extensions.contains(json['extension'])) {
      throw const FormatException('Invalid import record');
    }
    return ImportedScore(
      id: json['id'] as String,
      name: json['name'] as String,
      extension: json['extension'] as String,
      hash: json['hash'] as String,
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      disposition: ImportDisposition.values.byName(
        json['disposition'] as String,
      ),
      originId: json['originId'] as String?,
      savedPath: json['savedPath'] as String?,
      catalogEntryId: json['catalogEntryId'] as String?,
      catalogRevisionId: json['catalogRevisionId'] as String?,
      mirrorPending: json['mirrorPending'] == true,
    );
  }
}

/// Owns copies only. Catalog identities and the sync replica are never edited.
class ExternalImportStore extends ChangeNotifier {
  ExternalImportStore(this.directory, {required this.copyToNewFile});
  static const extensions = {'.pdf', '.jpg', '.jpeg', '.png', '.webp'};
  final Directory directory;
  final ImportCopy copyToNewFile;
  final _records = <String, ImportedScore>{};
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  List<ImportedScore> get records =>
      _records.values.toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  Directory get draftsDirectory => Directory(p.join(directory.path, 'drafts'));
  Directory get localLibrary =>
      Directory(p.join(directory.parent.path, 'local-imports', 'files'));
  ImportedScore? byId(String id) => _records[id];
  ImportedScore? byOrigin(String id) =>
      _records.values.where((r) => r.originId == id).firstOrNull;
  ImportedScore? bySavedPath(String path) => _records.values
      .where(
        (r) =>
            r.savedPath != null &&
            p.equals(p.normalize(r.savedPath!), p.normalize(path)),
      )
      .firstOrNull;
  String draftPath(ImportedScore score) =>
      p.join(draftsDirectory.path, score.id, 'source${score.extension}');
  String pathFor(ImportedScore score) => score.savedPath ?? draftPath(score);
  ScoreTarget target(ImportedScore score, {bool useCatalogIdentity = true}) =>
      ScoreTarget(
        entryId: useCatalogIdentity && score.catalogEntryId != null
            ? score.catalogEntryId!
            : 'import-${score.id}',
        revisionId: useCatalogIdentity && score.catalogRevisionId != null
            ? score.catalogRevisionId!
            : score.hash,
        filePath: pathFor(score),
        displayPath: score.name,
        contentHash: score.hash,
        parentFolderLabel: score.saved
            ? '本机导入 · ${p.basename(p.dirname(score.savedPath!))}'
            : '本机暂存 · 尚未保存到谱库',
      );

  Future<T> _serial<T>(Future<T> Function() operation) {
    final work = _tail.then((_) => operation());
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    await draftsDirectory.create(recursive: true);
    await localLibrary.create(recursive: true);
    await for (final entity in draftsDirectory.list(followLinks: false)) {
      if (entity is! Directory ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(p.basename(entity.path))) {
        continue;
      }
      final record = File(p.join(entity.path, 'record.json'));
      try {
        final score = ImportedScore.fromJson(
          jsonDecode(await record.readAsString()) as Map<String, dynamic>,
        );
        if (score.id != p.basename(entity.path)) continue;
        // A killed reader is a recoverable draft, never an automatic deletion.
        _records[score.id] = score.disposition == ImportDisposition.temporary
            ? score.changed(disposition: ImportDisposition.retained)
            : score;
        if (score.saved) await cleanupSavedPayload(score.id);
      } catch (_) {
        // Keep unreadable records/copies on disk for recovery; do not erase them.
      }
    }
    _changed();
  }

  Future<void> _persist(ImportedScore score) async {
    final folder = Directory(p.join(draftsDirectory.path, score.id));
    await folder.create(recursive: true);
    final target = File(p.join(folder.path, 'record.json'));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(score.toJson()), flush: true);
    await temp.rename(target.path);
    _records[score.id] = score;
    _changed();
  }

  Future<ImportedScore> receive(
    String source, {
    String? name,
    String? originId,
  }) => _serial(() async {
    final existing = originId == null ? null : byOrigin(originId);
    if (existing != null) return existing;
    final original = File(source);
    final actual = await original.resolveSymbolicLinks();
    final stat = await File(actual).stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      throw const FormatException('文件为空或不是文件');
    }
    final safeName = p.basename(
      (name ?? p.basename(source)).replaceAll('\\', '/'),
    );
    final extension = p.extension(safeName).toLowerCase();
    if (!extensions.contains(extension)) {
      throw const FormatException('仅支持 PDF、JPG、PNG、WebP');
    }
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final folder = Directory(p.join(draftsDirectory.path, id));
    await folder.create(recursive: true);
    final copy = File(p.join(folder.path, 'source$extension'));
    try {
      await original.copy(copy.path);
      final after = await original.stat();
      if (after.size != stat.size ||
          after.modified != stat.modified ||
          await copy.length() != stat.size) {
        throw const FileSystemException('复制期间源文件发生变化');
      }
      final hash = await _hashFile(copy.path);
      final score = ImportedScore(
        id: id,
        name: safeName,
        extension: extension,
        hash: hash,
        receivedAt: DateTime.now().toUtc(),
        disposition: ImportDisposition.temporary,
        originId: originId,
      );
      await _persist(score);
      return score;
    } catch (_) {
      if (p.isWithin(draftsDirectory.path, folder.path)) {
        await folder.delete(recursive: true);
      }
      rethrow;
    }
  });
  Future<void> retain(String id) => _serial(() async {
    final score = _records[id]!;
    if (!score.saved) {
      await _persist(score.changed(disposition: ImportDisposition.retained));
    }
  });
  Future<void> completeMirror(String id) => _serial(() async {
    final score = _records[id]!;
    if (score.mirrorPending) {
      await _persist(score.changed(mirrorPending: false));
    }
  });

  /// Called only after the active reader leaves, or during the next cold start.
  Future<void> cleanupSavedPayload(String id) async {
    final score = _records[id];
    if (score?.saved != true) return;
    try {
      final temporary = File(draftPath(score!));
      if (await temporary.exists()) await temporary.delete();
    } catch (_) {
      /* A cleanup failure must not turn a completed save into failure. */
    }
  }

  Future<void> remove(String id) => _serial(() async {
    final score = _records[id];
    if (score == null) return;
    // Removing a saved entry from this list must not delete a user library file.
    if (score.saved) throw StateError('已保存的曲谱请在本机目录管理');
    final folder = Directory(p.join(draftsDirectory.path, id));
    if (!p.isWithin(draftsDirectory.path, folder.path)) {
      throw StateError('Unsafe import path');
    }
    await folder.delete(recursive: true);
    _records.remove(id);
    _changed();
  });

  /// The native copier must create a new destination and refuse an existing one.
  /// A savedPath is journaled before the temporary payload can be removed.
  Future<ImportedScore> save(
    String id,
    Directory destination, {
    Future<(String, String)?> Function(String path)? catalogIdentity,
    Future<void> Function(ImportedScore score)? beforeCleanup,
  }) => _serial(() async {
    var score = _records[id]!;
    if (score.saved) return score;
    final actual = await destination.resolveSymbolicLinks();
    final folder = Directory(actual);
    final source = draftPath(score);
    String? saved;
    // A previous interrupted attempt is reused after checking its bytes.
    if (score.savedPath != null &&
        p.equals(p.dirname(score.savedPath!), actual) &&
        await File(score.savedPath!).exists() &&
        await _hashFile(score.savedPath!) == score.hash) {
      saved = score.savedPath;
    }
    if (saved == null) {
      final basename = p
          .basenameWithoutExtension(score.name)
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
      for (var index = 1; index <= 10000; index++) {
        final candidate = p.join(
          folder.path,
          '$basename${index == 1 ? '' : ' ($index)'}${score.extension}',
        );
        if (await FileSystemEntity.type(candidate, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        try {
          await copyToNewFile(source, candidate);
          saved = candidate;
          break;
        } on ImportDestinationExists {
          continue;
        }
      }
      if (saved == null) throw const FileSystemException('无法生成不重名的文件名');
      if (await _hashFile(saved) != score.hash) {
        throw const FileSystemException('保存副本校验失败，临时稿已保留');
      }
      score = score.changed(savedPath: saved);
      await _persist(score);
    }
    final identity = await catalogIdentity?.call(saved);
    score = score.changed(
      catalogEntryId: identity?.$1,
      catalogRevisionId: identity?.$2,
    );
    await beforeCleanup?.call(score);
    score = score.changed(
      disposition: ImportDisposition.saved,
      mirrorPending: score.catalogEntryId != null,
    );
    await _persist(score);
    return score;
  });
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ImportDestinationExists implements Exception {
  const ImportDestinationExists();
}

Future<String> _hashFile(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);
