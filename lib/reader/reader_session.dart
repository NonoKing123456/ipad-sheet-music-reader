import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:reader_state/reader_state.dart';

import 'reader_workspace.dart';

class ScoreTarget {
  const ScoreTarget({
    required this.entryId,
    required this.revisionId,
    required this.filePath,
    required this.displayPath,
    this.contentHash,
    this.verifiedImmutable = false,
    this.validateBeforeRead,
  });
  final String entryId;
  final String revisionId;
  final String filePath;
  final String displayPath;
  final String? contentHash;

  /// Reserved for verified sync-replica objects; ordinary sources must be false.
  final bool verifiedImmutable;
  final Future<void> Function()? validateBeforeRead;
  DocumentKey get key => DocumentKey(entryId: entryId, revisionId: revisionId);
}

class LoadedScore {
  LoadedScore({
    required this.target,
    required this.pageCount,
    this.pdf,
    this.imageAspect = 1,
    this.renderPath,
  });
  final ScoreTarget target;
  final int pageCount;
  final PdfDocument? pdf;
  final double imageAspect;
  final String? renderPath;
  int _leases = 0;
  bool _disposeRequested = false;
  void retain() => _leases++;
  void release() {
    _leases--;
    if (_leases == 0 && _disposeRequested) unawaited(pdf?.dispose());
  }

  DocumentMetadata get metadata => DocumentMetadata.ready(
    entryId: target.entryId,
    revisionId: target.revisionId,
    pageCount: pageCount,
  );
  double aspectFor(int page) => pdf == null
      ? imageAspect
      : pdf!.pages[page - 1].width / pdf!.pages[page - 1].height;
  Future<void> dispose() async {
    _disposeRequested = true;
    if (_leases == 0) await pdf?.dispose();
  }
}

typedef ScoreLoader = Future<LoadedScore> Function(ScoreTarget target);
typedef ScoreLocator = ScoreTarget? Function(String entryId);

Future<String> prepareReadingCopy(
  ScoreTarget target,
  String cacheDirectory,
) async {
  final watch = Stopwatch()..start();
  final result = await Isolate.run(() async {
    if (target.contentHash == null) {
      throw const FormatException('Unverified revision');
    }
    final key = sha256
        .convert(utf8.encode('${target.entryId}/${target.revisionId}'))
        .toString();
    final copy = File(
      p.join(
        cacheDirectory,
        '$key${p.extension(target.filePath).toLowerCase()}',
      ),
    );
    final marker = File('${copy.path}.verified.json');
    var copiedBytes = 0;
    var verifiedBytes = 0;
    Future<String> contentHash(File file) async {
      final hash = await sha256
          .bind(
            file.openRead().map((chunk) {
              verifiedBytes += chunk.length;
              return chunk;
            }),
          )
          .first;
      return hash.toString();
    }

    Future<void> markVerified() async {
      final stat = await copy.stat();
      final temporaryMarker = File('${marker.path}.tmp');
      await temporaryMarker.writeAsString(
        jsonEncode({
          'hash': target.contentHash,
          'size': stat.size,
          'modified': stat.modified.toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await temporaryMarker.rename(marker.path);
    }

    if (await copy.exists()) {
      final stat = await copy.stat();
      try {
        final verified =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        if (verified['hash'] == target.contentHash &&
            verified['size'] == stat.size &&
            verified['modified'] == stat.modified.toUtc().toIso8601String()) {
          return (
            path: copy.path,
            mode: 'warm',
            bytes: stat.size,
            copied: copiedBytes,
            verified: verifiedBytes,
          );
        }
      } catch (_) {
        /* A missing marker is repaired only after content verification. */
      }
      if (await contentHash(copy) == target.contentHash) {
        await markVerified();
        return (
          path: copy.path,
          mode: 'reverified',
          bytes: stat.size,
          copied: copiedBytes,
          verified: verifiedBytes,
        );
      }
    }
    await copy.parent.create(recursive: true);
    final temporary = File(
      '${copy.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await File(target.filePath)
          .openRead()
          .map((chunk) {
            copiedBytes += chunk.length;
            return chunk;
          })
          .pipe(temporary.openWrite());
      if (await contentHash(temporary) != target.contentHash) {
        throw const FormatException('Source revision changed during load');
      }
      await temporary.rename(copy.path);
      await markVerified();
      return (
        path: copy.path,
        mode: 'cold',
        bytes: (await copy.stat()).size,
        copied: copiedBytes,
        verified: verifiedBytes,
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  debugPrint(
    'READER reading_copy mode=${result.mode} object_bytes=${result.bytes} copy_read_bytes=${result.copied} verification_read_bytes=${result.verified} content_read_bytes=${result.copied + result.verified} elapsed_ms=${watch.elapsedMilliseconds}',
  );
  return result.path;
}

Future<LoadedScore> loadScore(
  ScoreTarget target, {
  required String cacheDirectory,
}) async {
  await target.validateBeforeRead?.call();
  final readingPath = target.verifiedImmutable
      ? target.filePath
      : await prepareReadingCopy(target, cacheDirectory);
  if (p.extension(target.filePath).toLowerCase() == '.pdf') {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(readingPath);
    if (document.pages.isEmpty) {
      await document.dispose();
      throw const FormatException('Empty PDF');
    }
    return LoadedScore(
      target: target,
      pageCount: document.pages.length,
      pdf: document,
      renderPath: readingPath,
    );
  }
  final codec = await ui.instantiateImageCodec(
    await File(readingPath).readAsBytes(),
    targetWidth: 2200,
    allowUpscaling: false,
  );
  try {
    final frame = await codec.getNextFrame();
    final aspect = frame.image.width / frame.image.height;
    frame.image.dispose();
    return LoadedScore(
      target: target,
      pageCount: 1,
      imageAspect: aspect,
      renderPath: readingPath,
    );
  } finally {
    codec.dispose();
  }
}

/// Ordered, bounded runs retain boundary presses: Next/Next/Previous is never
/// reduced arithmetically. Each accepted independent press is consumed once.
class ReaderNavigationQueue {
  static const maxRuns = 128;
  static const maxPresses = 1024;
  final List<_NavigationRun> _runs = [];
  int _presses = 0;
  bool get isEmpty => _runs.isEmpty;
  int get length => _presses;
  int get runCount => _runs.length;
  bool add(NavigationDirection direction) {
    final extendsLast = _runs.isNotEmpty && _runs.last.direction == direction;
    if (_presses >= maxPresses || (!extendsLast && _runs.length >= maxRuns)) {
      return false;
    }
    if (extendsLast) {
      _runs.last.count++;
    } else {
      _runs.add(_NavigationRun(direction));
    }
    _presses++;
    return true;
  }

  NavigationDirection? take() {
    if (_runs.isEmpty) return null;
    final run = _runs.first;
    final direction = run.direction;
    if (--run.count == 0) _runs.removeAt(0);
    _presses--;
    return direction;
  }

  void clear() {
    _runs.clear();
    _presses = 0;
  }
}

class _NavigationRun {
  _NavigationRun(this.direction);
  final NavigationDirection direction;
  int count = 1;
}

/// Serializes complete input presses and replays metadataRequired once loaded.
/// Selecting another score cancels old asynchronous requests before they commit.
class ReaderSession extends ChangeNotifier {
  ReaderSession({
    required this.workspace,
    required this.locate,
    this.setListId,
    this.deferPositionPersistence = false,
    ScoreLoader? loader,
  }) : _loader =
           loader ??
           ((target) => loadScore(
             target,
             cacheDirectory: p.join(
               p.dirname(workspace.store.statePath),
               'reading-cache',
             ),
           ));
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final String? setListId;
  final bool deferPositionPersistence;
  final ScoreLoader _loader;
  final Map<DocumentKey, LoadedScore> _cache = {};
  bool _disposed = false;
  int _epoch = 0;
  bool loading = false;
  String? message;
  LoadedScore? current;
  ReadingPosition? position;
  int get page => position?.pageNumber ?? 1;
  PageKey? get pageKey => position?.pageKey;
  bool _sourceChanged = false;
  bool get sourceChanged => _sourceChanged;
  bool _updateSourceStatus() {
    final current = this.current;
    if (current == null) return false;
    final latest = locate(current.target.entryId);
    final changed =
        latest == null || latest.revisionId != current.target.revisionId;
    final different = changed != _sourceChanged;
    _sourceChanged = changed;
    return different;
  }

  void refreshSource() {
    if (_updateSourceStatus()) _changed();
  }

  List<SetListItem> get queue => setListId == null
      ? []
      : (workspace.store.snapshot.setListById(setListId!)?.activeItems ?? []);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<LoadedScore?> _get(ScoreTarget target, int epoch) async {
    final cached = _cache[target.key];
    if (cached != null) {
      await target.validateBeforeRead?.call();
      return cached;
    }
    final loaded = await _loader(target);
    if (_disposed || epoch != _epoch) {
      await loaded.dispose();
      return null;
    }
    _cache[target.key] = loaded;
    return loaded;
  }

  Future<void> open(
    ScoreTarget target, {
    String? itemId,
    int? pageNumber,
    bool restore = true,
  }) async {
    final epoch = ++_epoch;
    _pendingTurns.clear();
    _navigationTask = null;
    loading = true;
    message = null;
    _changed();
    try {
      final loaded = await _get(target, epoch);
      if (loaded == null || _disposed || epoch != _epoch) return;
      final bookmark = restore
          ? workspace.store.readingPosition(target.key)
          : null;
      final page = (pageNumber ?? bookmark?.pageNumber ?? 1).clamp(
        1,
        loaded.pageCount,
      );
      current = loaded;
      _updateSourceStatus();
      position = ReadingPosition(
        entryId: target.entryId,
        revisionId: target.revisionId,
        pageNumber: page,
        setListItemId: itemId,
      );
      _savePosition();
    } catch (failure, stack) {
      debugPrint('READER load_failed: $failure\n$stack');
      if (!_disposed && epoch == _epoch) {
        message = '无法读取这份曲谱。请检查文件是否完整、已下载到本机且未受密码保护。';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> turn(NavigationDirection direction) {
    if (!_pendingTurns.add(direction)) {
      message = '翻页操作过密，已保留先前请求；请稍候再翻。';
      _changed();
      return _navigationTask ?? Future<void>.value();
    }
    return _navigationTask ??= _drainTurns(_epoch);
  }

  final _pendingTurns = ReaderNavigationQueue();
  Future<void>? _navigationTask;
  Future<void> _drainTurns(int epoch) async {
    try {
      while (!_disposed && epoch == _epoch && !_pendingTurns.isEmpty) {
        await _turn(_pendingTurns.take()!, epoch);
      }
    } finally {
      if (epoch == _epoch) _navigationTask = null;
    }
  }

  Map<String, DocumentMetadata> _metadata() {
    final ids = {
      if (position != null) position!.entryId,
      ...queue.map((item) => item.entryId),
    };
    return {for (final id in ids) id: _forEntry(id)};
  }

  DocumentMetadata _forEntry(String id) {
    final target = locate(id);
    if (target == null) return DocumentMetadata.missing(id);
    final loaded = _cache[target.key];
    if (loaded != null) return loaded.metadata;
    if (position?.entryId == id && position?.revisionId != target.revisionId) {
      // Give the pure navigator enough information to reject stale content.
      return DocumentMetadata.ready(
        entryId: id,
        revisionId: target.revisionId,
        pageCount: 1,
      );
    }
    return DocumentMetadata.unknown(id);
  }

  Future<void> _turn(NavigationDirection direction, int epoch) async {
    if (_disposed || epoch != _epoch || position == null || current == null) {
      return;
    }
    final request = NavigationRequest(current: position!, direction: direction);
    var result = ReaderNavigator.resolve(
      request,
      queue: queue,
      documents: _metadata(),
    );
    if (result.status == NavigationStatus.metadataRequired) {
      final target = locate(result.requiredEntryId!);
      if (target == null) {
        message = '曲单中的目标曲谱暂时缺失，请返回谱库检查。';
        _changed();
        return;
      }
      loading = true;
      message = null;
      _changed();
      try {
        final loaded = await _get(target, epoch);
        if (loaded == null || _disposed || epoch != _epoch) return;
        result = ReaderNavigator.resolve(
          request,
          queue: queue,
          documents: _metadata(),
        );
      } catch (failure, stack) {
        debugPrint('READER navigation_load_failed: $failure\n$stack');
        if (!_disposed && epoch == _epoch) {
          message = '下一份曲谱暂时无法读取，已停留在当前页。请检查文件后重试。';
        }
        return;
      } finally {
        if (!_disposed && epoch == _epoch) {
          loading = false;
          _changed();
        }
      }
    }
    if (_disposed || epoch != _epoch) return;
    if (result.didMove) {
      final target = locate(result.position.entryId);
      if (target == null || !_cache.containsKey(target.key)) return;
      current = _cache[target.key];
      _updateSourceStatus();
      position = result.position;
      message = null;
      _savePosition();
      _trimCache();
    } else {
      message = switch (result.status) {
        NavigationStatus.boundary =>
          direction == NavigationDirection.forward ? '已经到最后一页' : '已经到第一页',
        NavigationStatus.missingTarget => '曲单中的目标曲谱暂时缺失，已停留在当前页。',
        NavigationStatus.staleRevision => '这份曲谱已被替换。请返回谱库打开新版；旧批注仍保留在旧版本。',
        _ => '曲单已变化，请返回曲单重新打开。',
      };
    }
    _changed();
  }

  void _savePosition() {
    if (deferPositionPersistence) return;
    final position = this.position!;
    final count = current!.pageCount;
    unawaited(
      workspace.rememberPosition(
        document: position.pageKey.document,
        pageNumber: position.pageNumber,
        pageCount: count,
      ),
    );
  }

  void rememberPresented(PageKey page, int pageCount) {
    unawaited(
      workspace.rememberPosition(
        document: page.document,
        pageNumber: page.pageNumber,
        pageCount: pageCount,
      ),
    );
  }

  void _trimCache() {
    while (_cache.length > 3) {
      final key = _cache.keys.firstWhere((key) => key != current!.target.key);
      final old = _cache.remove(key)!;
      unawaited(old.dispose());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    for (final loaded in _cache.values) {
      unawaited(loaded.dispose());
    }
    _cache.clear();
    super.dispose();
  }
}
