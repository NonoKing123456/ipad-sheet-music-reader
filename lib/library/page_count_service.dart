import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'windows_file_identity.dart';

class ScoreFileAppearance {
  const ScoreFileAppearance(
    this.label,
    this.icon,
    this.background,
    this.foreground,
  );
  final String label;
  final IconData icon;
  final Color background, foreground;
}

ScoreFileAppearance scoreFileAppearance(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.pdf' => const ScoreFileAppearance(
        'PDF',
        Icons.picture_as_pdf_outlined,
        Color(0xffe4e9ee),
        Color(0xff536777),
      ),
      '.jpg' || '.jpeg' => const ScoreFileAppearance(
        'JPG',
        Icons.image_outlined,
        Color(0xffe4ebe4),
        Color(0xff526b58),
      ),
      '.png' => const ScoreFileAppearance(
        'PNG',
        Icons.image_outlined,
        Color(0xffe1ebea),
        Color(0xff4c6b69),
      ),
      '.webp' => const ScoreFileAppearance(
        'WebP',
        Icons.image_outlined,
        Color(0xffe9e4ed),
        Color(0xff665b72),
      ),
      _ => const ScoreFileAppearance(
        '文件',
        Icons.description_outlined,
        Color(0xffe6eae7),
        Color(0xff53615b),
      ),
    };

class PageCountFile {
  const PageCountFile(this.path, this.root, {this.size, this.modifiedUtc});
  final String path, root;
  final int? size;
  final DateTime? modifiedUtc;
  bool same(PageCountFile? other) =>
      other != null &&
      path == other.path &&
      root == other.root &&
      size == other.size &&
      modifiedUtc == other.modifiedUtc;
}

typedef PageCountResolver = PageCountFile? Function(PageMetadataKey key);
typedef RemotePageCounts = Future<Map<PageMetadataKey, int>> Function(
  List<PageMetadataKey> keys,
);

/// Only interested rows enqueue work. Parsing uses PDFium's background worker;
/// no score raster, reading copy, materialization or catalogue write is needed.
class PageCountService {
  PageCountService({required this.resolve, this.cacheDirectory, this.remote});
  final PageCountResolver resolve;
  final String? cacheDirectory;
  final RemotePageCounts? remote;
  final _values = <PageMetadataKey, ValueNotifier<int?>>{};
  final _interest = <PageMetadataKey, int>{};
  final _queued = <PageMetadataKey, Completer<int?>>{};
  final _active = <PageMetadataKey, Future<int?>>{};
  final _unknown = <PageMetadataKey, PageCountFile?>{};
  bool _running = false, _closed = false;
  int parses = 0, maxConcurrent = 0;
  int _concurrent = 0;
  int _remoteEpoch = 0;
  Future<void>? _writes;

  ValueNotifier<int?> watch(PageMetadataKey key) {
    final value = _values.putIfAbsent(key, () => ValueNotifier(null));
    _interest.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (value.value == null) unawaited(lookup(key));
    return value;
  }

  void unwatch(PageMetadataKey key) {
    final n = (_interest[key] ?? 1) - 1;
    if (n > 0) {
      _interest[key] = n;
      return;
    }
    _interest.remove(key);
    _queued.remove(key)?.complete(null);
    _trim();
  }

  void remember(PageMetadataKey key, int count, {bool persist = true}) {
    if (_closed || count < 1 || count > 100000) return;
    _unknown.remove(key);
    _values.putIfAbsent(key, () => ValueNotifier(null)).value = count;
    if (persist) unawaited(_saveCache(key, count));
    _trim();
  }

  void _trim() {
    while (_unknown.length > 512) {
      _unknown.remove(_unknown.keys.first);
    }
    while (_values.length > 512) {
      final removable = _values.keys.where(
        (key) => !_interest.containsKey(key),
      );
      if (removable.isEmpty) break;
      _values.remove(removable.first)?.dispose();
    }
  }

  Future<int?> lookup(PageMetadataKey key) {
    if (_closed) return Future.value(null);
    if (_unknown.containsKey(key)) return Future.value(null);
    final known = _values[key]?.value;
    if (known != null) return Future.value(known);
    final running = _active[key];
    if (running != null) return running;
    final old = _queued[key];
    if (old != null) return old.future;
    // Native parsing is single flight, with only a small queue beyond rows.
    if (_queued.length >= 64) return Future.value(null);
    final done = Completer<int?>();
    _queued[key] = done;
    scheduleMicrotask(_drain);
    return done.future;
  }

  Future<void> _drain() async {
    if (_running || _closed) return;
    _running = true;
    try {
      while (_queued.isNotEmpty && !_closed) {
        final first = _queued.keys.first;
        final input = resolve(first);
        final remoteEpoch = _remoteEpoch;
        final keys = input == null
            ? _queued.keys
                  .where((key) => resolve(key) == null)
                  .take(16)
                  .toList()
            : [first];
        final jobs = {for (final key in keys) key: _queued.remove(key)!};
        for (final job in jobs.entries) {
          _active[job.key] = job.value.future;
        }
        final counts = <PageMetadataKey, int>{};
        try {
          if (input == null) {
            final missing = <PageMetadataKey>[];
            for (final key in keys) {
              final cached = await _readCache(key);
              if (cached != null) {
                counts[key] = cached;
              } else {
                missing.add(key);
              }
            }
            if (!_closed && missing.isNotEmpty) {
              final received = await remote?.call(missing) ?? {};
              for (final key in missing) {
                final count = received[key];
                if (!_closed &&
                    remoteEpoch == _remoteEpoch &&
                    count != null &&
                    count > 0 &&
                    count <= 100000) {
                  counts[key] = count;
                  await _saveCache(key, count);
                }
              }
            }
          } else {
            final count = await _readLocal(first, input);
            if (count != null) counts[first] = count;
          }
        } catch (error) {
          debugPrint('LIBRARY page_count_unknown kind=${error.runtimeType}');
        }
        for (final job in jobs.entries) {
          final key = job.key, count = counts[key];
          _active.remove(key);
          final changedConnection =
              input == null && remoteEpoch != _remoteEpoch;
          if (!_closed) {
            if (count != null) {
              remember(key, count, persist: false);
            } else if (!changedConnection) {
              _unknown[key] = input;
            }
          }
          if (!job.value.isCompleted) {
            job.value.complete(_closed ? null : count);
          }
          if (!_closed && changedConnection && _interest.containsKey(key)) {
            unawaited(lookup(key));
          }
        }
        _trim();
      }
    } finally {
      _running = false;
    }
  }

  void refreshVisible() {
    if (_closed) return;
    for (final key in _interest.keys) {
      final input = resolve(key);
      if (_values[key]?.value == null &&
          input != null &&
          (!_unknown.containsKey(key) || !input.same(_unknown[key]))) {
        _unknown.remove(key);
        unawaited(lookup(key));
      }
    }
    _trim();
  }

  void connectionChanged() {
    _remoteEpoch++;
    for (final key in _interest.keys) {
      if (_values[key]?.value == null && resolve(key) == null) {
        _unknown.remove(key);
        unawaited(lookup(key));
      }
    }
  }

  File? _cache(PageMetadataKey key) => cacheDirectory == null
      ? null
      : File(
          p.join(
            cacheDirectory!,
            '${sha256.convert(utf8.encode(jsonEncode(key.toJson())))}.json',
          ),
        );

  Future<int?> _readCache(PageMetadataKey key, {String? stamp}) async {
    final cache = _cache(key);
    if (cache == null) return null;
    try {
      for (final path in [cache.path, '${cache.path}.backup']) {
        assertSafePath(cacheDirectory!, path);
        final file = File(path);
        if (await file.exists() && await file.length() > 1024) return null;
      }
      final value = await readJson(cache.path), count = value?['pages'];
      if (value?['entryId'] != key.entryId ||
          value?['revisionId'] != key.revisionId) {
        return null;
      }
      if (stamp != null &&
          value?['stamp'] != null &&
          value?['stamp'] != stamp) {
        return null;
      }
      return count is int && count > 0 && count <= 100000 ? count : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache(PageMetadataKey key, int count, {String? stamp}) {
    final cache = _cache(key);
    if (cache == null) return Future.value();
    final next = (_writes ?? Future<void>.value())
        .then((_) async {
          assertSafePath(cacheDirectory!, cache.path);
          await writeJson(cache.path, {
            ...key.toJson(),
            'pages': count,
            'stamp': stamp,
          });
        })
        .catchError((Object _) {
          /* Optional display cache can be recomputed. */
        });
    _writes = next;
    return next;
  }

  Future<int?> _readLocal(PageMetadataKey key, PageCountFile input) async {
    // A previously confirmed count belongs to this immutable revision even if
    // its source is now offline. It grants no permission to read score content.
    final known = await _readCache(key);
    if (known != null && input.same(resolve(key))) return known;
    if (!await isLocallyReadableFile(input.path)) return null;
    final path = await File(input.path).resolveSymbolicLinks();
    if (!p.isWithin(input.root, path)) return null;
    final file = File(path), before = await File(path).stat();
    if (before.type != FileSystemEntityType.file ||
        (input.size != null && before.size != input.size) ||
        (input.modifiedUtc != null &&
            before.modified.toUtc() != input.modifiedUtc)) {
      return null;
    }
    final stamp = '${before.size}/${before.modified.microsecondsSinceEpoch}';
    PdfDocument? document;
    int count;
    _concurrent++;
    if (_concurrent > maxConcurrent) maxConcurrent = _concurrent;
    try {
      parses++;
      await pdfrxFlutterInitialize();
      document = await PdfDocument.openFile(path, useProgressiveLoading: true);
      count = document.pages.length;
    } finally {
      await document?.dispose();
      _concurrent--;
    }
    final after = await file.stat();
    if (_closed ||
        count < 1 ||
        count > 100000 ||
        !input.same(resolve(key)) ||
        before.size != after.size ||
        before.modified != after.modified ||
        path != await File(input.path).resolveSymbolicLinks()) {
      return null;
    }
    await _saveCache(key, count, stamp: stamp);
    return count;
  }

  void dispose() {
    _closed = true;
    for (final value in _queued.values) {
      value.complete(null);
    }
    _queued.clear();
    for (final value in _values.values) {
      value.dispose();
    }
    _values.clear();
  }
}

class ScoreFileMetadata extends StatefulWidget {
  const ScoreFileMetadata({
    super.key,
    required this.entryId,
    required this.revisionId,
    required this.path,
    this.service,
  });
  final String entryId, revisionId, path;
  final PageCountService? service;
  @override
  State<ScoreFileMetadata> createState() => _ScoreFileMetadataState();
}

class _ScoreFileMetadataState extends State<ScoreFileMetadata> {
  ValueNotifier<int?>? _value;
  PageMetadataKey get _key =>
      PageMetadataKey(widget.entryId, widget.revisionId);
  bool get _pdf => p.extension(widget.path).toLowerCase() == '.pdf';
  bool get _image => const [
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
  ].contains(p.extension(widget.path).toLowerCase());
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    if (_pdf) _value = widget.service?.watch(_key);
  }

  @override
  void didUpdateWidget(covariant ScoreFileMetadata old) {
    super.didUpdateWidget(old);
    if (old.entryId != widget.entryId ||
        old.revisionId != widget.revisionId ||
        old.path != widget.path ||
        old.service != widget.service) {
      if (p.extension(old.path).toLowerCase() == '.pdf') {
        old.service?.unwatch(PageMetadataKey(old.entryId, old.revisionId));
      }
      _value = null;
      _bind();
    }
  }

  @override
  void dispose() {
    if (_pdf) widget.service?.unwatch(_key);
    super.dispose();
  }

  Widget _label(int? count) {
    final appearance = scoreFileAppearance(widget.path);
    final extension = appearance.label;
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final countLabel = Tooltip(
      message: count == null ? '尚未取得页数' : '$count页',
      child: Text(
        count == null
            ? compact
                  ? '—'
                  : '待获取'
            : '$count页',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: compact ? 12 : 13,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    return Semantics(
      label: count == null ? '$extension，尚未取得页数' : '$extension，$count页',
      child: SizedBox(
        width: compact ? 84 : 100,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: dark
                    ? Color.alphaBlend(
                        appearance.foreground.withValues(alpha: .28),
                        scheme.surfaceContainerHigh,
                      )
                    : appearance.background,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                extension,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: dark
                      ? Color.lerp(appearance.foreground, scheme.onSurface, .78)
                      : appearance.foreground,
                ),
              ),
            ),
            SizedBox(width: compact ? 4 : 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: countLabel),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _image
      ? _label(1)
      : _value == null
      ? _label(null)
      : ValueListenableBuilder<int?>(
          valueListenable: _value!,
          builder: (_, value, _) => _label(value),
        );
}

/// Hidden actions keep their physical column so mixed offline states align.
class ScoreFileTrailing extends StatelessWidget {
  const ScoreFileTrailing({
    super.key,
    required this.metadata,
    required this.menuAction,
  });
  final Widget metadata, menuAction;
  static const width = 160.0;
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return SizedBox(
      width: compact ? 128 : width,
      child: Row(
        children: [
          SizedBox(width: compact ? 84 : 100, child: metadata),
          if (!compact) const SizedBox(width: 12),
          SizedBox(width: compact ? 44 : 48, child: menuAction),
        ],
      ),
    );
  }
}
