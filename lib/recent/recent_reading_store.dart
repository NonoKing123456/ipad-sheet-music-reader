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
  bool _disposed = false;
  Future<void> initialize() => _initializing ??= _load();
  Future<void> _load() async {
    try {
      if (!await file.exists() || await file.length() > maxBytes) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['version'] != 1) return;
      final loaded = <String, RecentReading>{};
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
      _entries = List.unmodifiable(
        loaded.values.toList()
          ..sort((a, b) => b.openedAt.compareTo(a.openedAt)),
      );
      if (!_disposed) notifyListeners();
    } catch (_) {
      /* Broken optional history never prevents library startup. */
    }
  }

  Future<void> record(RecentReading entry) async {
    await initialize();
    if (_disposed) return;
    final next = [entry, ..._entries.where((e) => e.entryId != entry.entryId)]
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    _entries = List.unmodifiable(next.take(limit));
    notifyListeners();
    _save();
  }

  Future<void> remove(String id) async {
    await initialize();
    if (_disposed) return;
    _entries = List.unmodifiable(_entries.where((e) => e.entryId != id));
    notifyListeners();
    _save();
  }

  void _save() {
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
        })
        .catchError((Object _) {
          /* Best effort; reading must remain usable. */
        });
  }

  Future<void> flush() async {
    await initialize();
    await _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
