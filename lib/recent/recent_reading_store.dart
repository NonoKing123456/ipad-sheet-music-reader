import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A small local history, separate from reader positions and sync state.
class RecentReading {
  const RecentReading({
    required this.entryId,
    required this.revisionId,
    required this.path,
    required this.contextLabel,
    required this.openedAt,
    this.pageCount,
  });
  final String entryId, revisionId, path, contextLabel;
  final DateTime openedAt;
  final int? pageCount;
  Map<String, Object?> toJson() => {
    'entryId': entryId,
    'revisionId': revisionId,
    'path': path,
    'context': contextLabel,
    'openedAt': openedAt.toUtc().toIso8601String(),
    'pageCount': pageCount,
  };
  factory RecentReading.fromJson(Map<String, dynamic> json) {
    final id = json['entryId'] as String,
        revision = json['revisionId'] as String;
    if (id.isEmpty || revision.isEmpty) throw const FormatException('identity');
    return RecentReading(
      entryId: id,
      revisionId: revision,
      path: json['path'] as String,
      contextLabel: json['context'] as String,
      openedAt: DateTime.parse(json['openedAt'] as String),
      pageCount: json['pageCount'] as int?,
    );
  }
}

typedef _History = ({List<RecentReading> entries, bool recoveredArchive});

class RecentReadingStore extends ChangeNotifier {
  RecentReadingStore(this.file);
  final File file;
  static const limit = 100;
  static const _oldMaxBytes = 256 * 1024;
  // Allow 100 deep Unicode paths and their folder labels while bounding JSON I/O.
  static const maxBytes = 32 * 1024 * 1024;
  List<RecentReading> _entries = const [];
  List<RecentReading> get entries => _entries;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  bool _disposed = false, _loaded = false, _dirty = false;
  bool _recoveredArchive = false;
  final _removedBeforeLoad = <String>{};
  (Object, StackTrace)? _loadFailure;
  Future<void> initialize() {
    if (_loaded) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<_History?> _read(File source, {bool legacyArchive = false}) async {
    try {
      if (legacyArchive &&
          await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return null;
      }
      final length = await source.length();
      if (legacyArchive && (length <= _oldMaxBytes || length > maxBytes)) {
        return null;
      }
      if (length > maxBytes) {
        throw const FileSystemException('History exceeds supported size');
      }
      final contents = await source.readAsString();
      if (contents.trim().isEmpty) return null;
      final json = jsonDecode(contents) as Map<String, dynamic>;
      if (json['version'] != 1) {
        throw const FormatException('Unsupported history version');
      }
      final rows = json['entries'] as List;
      if (legacyArchive && (rows.isEmpty || rows.length > limit)) return null;
      final entries = <RecentReading>[];
      for (final value in rows.take(limit)) {
        try {
          entries.add(RecentReading.fromJson(value as Map<String, dynamic>));
        } catch (_) {
          // Only migrate intact archives. Isolate bad rows in the current history.
          if (legacyArchive) return null;
        }
      }
      return (
        entries: entries,
        recoveredArchive: json['recoveredArchive'] == true,
      );
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      if (legacyArchive) return null;
      rethrow;
    } catch (error) {
      if (error is! FormatException && error is! TypeError) rethrow;
      if (!legacyArchive) await _moveAside(source, '${file.path}.corrupt');
      return null;
    }
  }

  Future<void> _moveAside(File source, String path) async {
    var target = path;
    var suffix = 1;
    while (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      target = '$path.${suffix++}';
    }
    await source.rename(target);
  }

  Future<void> _load() async {
    try {
      final current = await _read(file);
      final archive = File('${file.path}.corrupt');
      _recoveredArchive = current?.recoveredArchive ?? false;
      final legacy = _recoveredArchive
          ? null
          : await _read(archive, legacyArchive: true);
      final loaded = <String, RecentReading>{};
      for (final entry in [...?current?.entries, ...?legacy?.entries]) {
        final previous = loaded[entry.entryId];
        if (previous == null || entry.openedAt.isAfter(previous.openedAt)) {
          loaded[entry.entryId] = entry;
        }
      }
      for (final entry in _entries) {
        loaded[entry.entryId] = entry;
      }
      for (final id in _removedBeforeLoad) {
        loaded.remove(id);
      }
      final sorted = loaded.values.toList()
        ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
      final entries = List<RecentReading>.unmodifiable(sorted.take(limit));
      if (legacy != null) {
        // Commit the union and its marker together. A locked archive or a
        // restart after this write must not replay later removals.
        _recoveredArchive = true;
        await _writeSnapshot(entries);
        try {
          await _moveAside(archive, '${file.path}.recovered');
        } on FileSystemException {
          // The intact archive can stay in place once the marker is durable.
        }
      }
      _entries = entries;
      _removedBeforeLoad.clear();
      _loaded = true;
      _loadFailure = null;
    } catch (error, stack) {
      _loadFailure = (error, stack);
      return; // Keep the last copy and retry before accepting a disk write.
    }
    if (!_disposed) notifyListeners();
  }

  // Serialize each in-memory edit with its disk write. A later opening of the
  // same score may legitimately put it back in history after a removal.
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> record(RecentReading entry) {
    if (_disposed) return Future.value();
    return _enqueue(() async {
      await initialize();
      _removedBeforeLoad.remove(entry.entryId);
      final next = [entry, ..._entries.where((e) => e.entryId != entry.entryId)]
        ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
      _entries = List.unmodifiable(next.take(limit));
      _dirty = true;
      if (!_disposed) notifyListeners();
      if (_loaded) {
        try {
          await _writeSnapshot(_entries);
          _dirty = false;
        } on FileSystemException {
          // Reading continues; flush or the next edit retries this snapshot.
        }
      }
    });
  }

  Future<bool> remove(String id) {
    if (_disposed) return Future.value(false);
    return _enqueue(() async {
      await initialize();
      if (!_loaded) {
        // Remember a removal requested before its on-disk row can be read.
        // Visible in-memory rows remain available for an explicit retry.
        if (!_entries.any((entry) => entry.entryId == id)) {
          _removedBeforeLoad.add(id);
          _dirty = true;
        }
        return false;
      }
      final next = List<RecentReading>.unmodifiable(
        _entries.where((entry) => entry.entryId != id),
      );
      try {
        await _writeSnapshot(next);
      } on FileSystemException {
        return false;
      }
      _entries = next;
      _dirty = false;
      if (!_disposed) notifyListeners();
      return true;
    });
  }

  Future<void> _writeSnapshot(List<RecentReading> entries) async {
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        if (_recoveredArchive) 'recoveredArchive': true,
        'entries': entries.map((e) => e.toJson()).toList(),
      }),
    );
    if (bytes.length > maxBytes) {
      throw const FileSystemException('History exceeds supported size');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> flush() => _enqueue(() async {
    await initialize();
    if (!_loaded) {
      final failure = _loadFailure!;
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    if (_dirty) {
      await _writeSnapshot(_entries);
      _dirty = false;
    }
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
