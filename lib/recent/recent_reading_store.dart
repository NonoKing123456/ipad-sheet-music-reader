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

class RecentReadingStore extends ChangeNotifier {
  RecentReadingStore(this.file);
  final File file;
  static const limit = 100;
  static const maxBytes = 256 * 1024;
  List<RecentReading> _entries = const [];
  List<RecentReading> get entries => _entries;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  bool _disposed = false, _loaded = false, _dirty = false;
  int _revision = 0, _pendingWrites = 0;
  final _removedBeforeLoad = <String>{};
  (Object, StackTrace)? _loadFailure, _writeFailure;
  Future<void> initialize() {
    if (_loaded) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<void> _load() async {
    final loaded = <String, RecentReading>{};
    try {
      if (await file.length() > maxBytes) {
        throw const FormatException('History exceeds size limit');
      }
      final contents = await file.readAsString();
      final json = contents.trim().isEmpty
          ? {'version': 1, 'entries': <Object>[]}
          : jsonDecode(contents) as Map<String, dynamic>;
      if (json['version'] != 1) {
        throw const FormatException('Unsupported history version');
      }
      for (final value in (json['entries'] as List).take(limit)) {
        try {
          final entry = RecentReading.fromJson(
            Map<String, dynamic>.from(value as Map),
          );
          final previous = loaded[entry.entryId];
          if (previous == null || entry.openedAt.isAfter(previous.openedAt)) {
            loaded[entry.entryId] = entry;
          }
        } catch (_) {
          /* One invalid record does not hide valid history. */
        }
      }
    } on PathNotFoundException {
      // A missing history is safe to create; other read failures are not.
    } on FormatException catch (_) {
      // Unreadable content, not a transient I/O failure: keep a copy aside
      // and start a fresh history instead of never saving again.
      await _setAsideCorrupt();
    } on TypeError catch (_) {
      await _setAsideCorrupt();
    } catch (error, stack) {
      _loadFailure = (error, stack);
      return; // Keep startup usable, but never overwrite an unread history.
    }
    for (final entry in _entries) {
      loaded[entry.entryId] = entry;
    }
    for (final id in _removedBeforeLoad) {
      loaded.remove(id);
    }
    _removedBeforeLoad.clear();
    _entries = List.unmodifiable(
      (loaded.values.toList()..sort((a, b) => b.openedAt.compareTo(a.openedAt)))
          .take(limit),
    );
    _loaded = true;
    _loadFailure = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> _setAsideCorrupt() async {
    try {
      await file.rename('${file.path}.corrupt');
    } catch (_) {
      // Leaving the damaged file in place is safe: the next save replaces it.
    }
  }

  Future<void> record(RecentReading entry) async {
    await initialize();
    if (_disposed) return;
    _removedBeforeLoad.remove(entry.entryId);
    final next = [entry, ..._entries.where((e) => e.entryId != entry.entryId)]
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    _entries = List.unmodifiable(next.take(limit));
    _dirty = true;
    _revision++;
    notifyListeners();
    _save();
  }

  Future<void> remove(String id) async {
    await initialize();
    if (_disposed) return;
    if (!_loaded) _removedBeforeLoad.add(id);
    _entries = List.unmodifiable(_entries.where((e) => e.entryId != id));
    _dirty = true;
    _revision++;
    notifyListeners();
    _save();
  }

  void _save() {
    if (!_loaded) return;
    final revision = _revision;
    _pendingWrites++;
    final contents = jsonEncode({
      'version': 1,
      'entries': _entries.map((e) => e.toJson()).toList(),
    });
    _writes = _writes
        .then((_) async {
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(contents, flush: true);
          await temporary.rename(file.path);
          if (revision == _revision) _dirty = false;
          _writeFailure = null;
        })
        .catchError((Object error, StackTrace stack) {
          _writeFailure = (error, stack);
          // Keep the queue usable and the latest in-memory history dirty.
        })
        .whenComplete(() => _pendingWrites--);
  }

  Future<void> flush() async {
    await initialize();
    if (!_loaded) {
      final failure = _loadFailure!;
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    if (_dirty && _pendingWrites == 0) _save();
    await _writes;
    final failure = _writeFailure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
