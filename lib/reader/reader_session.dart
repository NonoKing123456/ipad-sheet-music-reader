import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart'
    show ConcurrentCatalogWriteException;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:reader_state/reader_state.dart';

import 'reader_workspace.dart';
import 'reader_spreads.dart';

class ScoreTarget {
  const ScoreTarget({
    required this.entryId,
    required this.revisionId,
    required this.filePath,
    required this.displayPath,
    this.contentHash,
    this.parentFolderLabel,
    this.verifiedImmutable = false,
    this.validateBeforeRead,
  });
  final String entryId;
  final String revisionId;
  final String filePath;
  final String displayPath;
  final String? contentHash;
  final String? parentFolderLabel;

  /// Reserved for verified sync-replica objects; ordinary sources must be false.
  final bool verifiedImmutable;
  final Future<void> Function()? validateBeforeRead;
  DocumentKey get key => DocumentKey(entryId: entryId, revisionId: revisionId);
}

enum ScoreContentState {
  ready,
  notDownloaded,
  unprepared,
  readableOld,
  missing,
  sourceOffline,
}

/// Catalog identity does not imply that local bytes are ready to open.
class ScoreCatalogEntry {
  const ScoreCatalogEntry({
    required this.entryId,
    required this.displayPath,
    required this.state,
    this.parentFolderLabel,
    this.sourceId,
    this.sourceName = '谱库',
    this.bytes,
  });
  factory ScoreCatalogEntry.fromTarget(ScoreTarget target) => ScoreCatalogEntry(
    entryId: target.entryId,
    displayPath: target.displayPath,
    parentFolderLabel: target.parentFolderLabel,
    state: ScoreContentState.ready,
  );
  final String entryId, displayPath, sourceName;
  final String? parentFolderLabel, sourceId;
  final ScoreContentState state;
  final int? bytes;
  bool get readable =>
      state == ScoreContentState.ready ||
      state == ScoreContentState.readableOld;
  bool get needsPreparation =>
      state == ScoreContentState.notDownloaded ||
      state == ScoreContentState.unprepared ||
      state == ScoreContentState.readableOld;
  String get statusLabel => switch (state) {
    ScoreContentState.ready => '已准备',
    ScoreContentState.notDownloaded => '未下载',
    ScoreContentState.unprepared => '待准备',
    ScoreContentState.readableOld => '离线旧版可读，有更新待下载',
    ScoreContentState.missing => '源曲谱缺失',
    ScoreContentState.sourceOffline => '来源暂离线',
  };
}

typedef ScoreCatalogProvider = List<ScoreCatalogEntry> Function();
typedef ScorePreparation = Future<String> Function(Set<String> entryIds);

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
  final result = await Isolate.run(
    _ReadingCopyRequest(
      entryId: target.entryId,
      revisionId: target.revisionId,
      filePath: target.filePath,
      contentHash: target.contentHash,
      cacheDirectory: cacheDirectory,
    ).call,
  );
  debugPrint(
    'READER reading_copy mode=${result.mode} object_bytes=${result.bytes} copy_read_bytes=${result.copied} verification_read_bytes=${result.verified} content_read_bytes=${result.copied + result.verified} elapsed_ms=${watch.elapsedMilliseconds}',
  );
  return result.path;
}

typedef _ReadingCopyResult = ({
  String path,
  String mode,
  int bytes,
  int copied,
  int verified,
});

/// Only scalar file identity crosses the isolate boundary. ScoreTarget also
/// owns a read validator that can retain live controllers, futures and watchers.
class _ReadingCopyRequest {
  const _ReadingCopyRequest({
    required this.entryId,
    required this.revisionId,
    required this.filePath,
    required this.contentHash,
    required this.cacheDirectory,
  });
  final String entryId, revisionId, filePath, cacheDirectory;
  final String? contentHash;
  Future<_ReadingCopyResult> call() => _prepareReadingCopyWorker(this);
}

Future<_ReadingCopyResult> _prepareReadingCopyWorker(
  _ReadingCopyRequest request,
) async {
  if (request.contentHash == null) {
    throw const FormatException('Unverified revision');
  }
  final key = sha256
      .convert(utf8.encode('${request.entryId}/${request.revisionId}'))
      .toString();
  final copy = File(
    p.join(
      request.cacheDirectory,
      '$key${p.extension(request.filePath).toLowerCase()}',
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
        'hash': request.contentHash,
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
      if (verified['hash'] == request.contentHash &&
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
    if (await contentHash(copy) == request.contentHash) {
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
    await File(request.filePath)
        .openRead()
        .map((chunk) {
          copiedBytes += chunk.length;
          return chunk;
        })
        .pipe(temporary.openWrite());
    if (await contentHash(temporary) != request.contentHash) {
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
  // Metadata only: decoding a frame here used to allocate a redundant bitmap
  // before the reader's budgeted renderer decoded the same file again.
  final buffer = await ui.ImmutableBuffer.fromFilePath(readingPath);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return LoadedScore(
      target: target,
      pageCount: 1,
      imageAspect: descriptor.width / descriptor.height,
      renderPath: readingPath,
    );
  } finally {
    descriptor?.dispose();
    buffer.dispose();
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
  Future<LoadedScore?>? _warmFuture;
  DocumentKey? _warmKey, _warmWanted;
  int _warmEpoch = 0;
  int _epoch = 0;
  bool loading = false;
  String? message;
  LoadedScore? current;
  ReadingPosition? position;
  int get page => position?.pageNumber ?? 1;
  PageKey? get pageKey => position?.pageKey;
  bool _sourceChanged = false;
  bool get sourceChanged => _sourceChanged;
  int get cachedDocumentCount => _cache.length;
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
    final warming = _warmFuture;
    if (warming != null && _warmKey == target.key && _warmEpoch == epoch) {
      _warmWanted = target.key;
      final loaded = await warming;
      if (loaded != null) {
        await target.validateBeforeRead?.call();
        return loaded;
      }
    }
    if (_disposed || epoch != _epoch) return null;
    final loaded = await _loader(target);
    if (_disposed || epoch != _epoch) {
      await loaded.dispose();
      return null;
    }
    _cache[target.key] = loaded;
    return loaded;
  }

  void cancelPrewarm() {
    _warmWanted = null;
  }

  ScoreTarget? get nextPrewarmTarget => nextPrewarmTargetFor();

  /// A two-page terminal spread may have N-1 as its focused page. Callers may
  /// supply its actually presented last page without changing navigation focus.
  ScoreTarget? nextPrewarmTargetFor({int? lastVisiblePage}) {
    if (_disposed ||
        current == null ||
        position == null ||
        (lastVisiblePage ?? page) != current!.pageCount) {
      return null;
    }
    final items = queue,
        index = queue.indexWhere((item) => item.id == position!.setListItemId);
    if (index < 0 || index + 1 >= items.length) return null;
    final target = locate(items[index + 1].entryId);
    return target;
  }

  Future<LoadedScore?> prewarmNext({int? lastVisiblePage}) async {
    final target = nextPrewarmTargetFor(lastVisiblePage: lastVisiblePage);
    if (target == null) return null;
    _warmWanted = target.key;
    final cached = _cache[target.key];
    if (cached != null) {
      final epoch = _epoch;
      try {
        await target.validateBeforeRead?.call();
        return !_disposed && epoch == _epoch && _warmWanted == target.key
            ? cached
            : null;
      } catch (_) {
        debugPrint('READER next_prewarm_unavailable');
        return null;
      }
    }
    final pending = _warmFuture;
    if (pending != null) {
      final originPosition = position;
      if (_warmKey == target.key && _warmEpoch == _epoch) return pending;
      await pending;
      if (_disposed ||
          !identical(position, originPosition) ||
          _warmWanted != target.key) {
        return null;
      }
      return prewarmNext(lastVisiblePage: lastVisiblePage);
    }
    final epoch = _epoch;
    _warmEpoch = epoch;
    _warmKey = target.key;
    late final Future<LoadedScore?> job;
    job = () async {
      try {
        final loaded = await _loader(target);
        if (_disposed || epoch != _epoch || _warmWanted != target.key) {
          await loaded.dispose();
          return null;
        }
        _cache[target.key] = loaded;
        _trimCache();
        return loaded;
      } catch (_) {
        debugPrint('READER next_prewarm_unavailable');
        return null;
      } finally {
        if (identical(_warmFuture, job)) {
          _warmFuture = null;
          _warmKey = null;
        }
      }
    }();
    _warmFuture = job;
    return job;
  }

  Future<void> open(
    ScoreTarget target, {
    String? itemId,
    int? pageNumber,
    bool restore = true,
  }) async {
    final epoch = ++_epoch;
    cancelPrewarm();
    _pendingTurns.clear();
    _pendingActions.clear();
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
        message = failure is ConcurrentCatalogWriteException
            ? '目录正在更新，请稍后重试。'
            : '无法打开曲谱，请重试。';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        _changed();
      }
    }
  }

  Future<void> turn(NavigationDirection direction) {
    if (_pendingActions.length >= ReaderNavigationQueue.maxPresses ||
        !_pendingTurns.add(direction)) {
      message = '翻页处理中，请稍候。';
      _changed();
      return _navigationTask ?? Future<void>.value();
    }
    _pendingActions.addLast(direction);
    return _navigationTask ??= _drainTurns(_epoch);
  }

  Future<void> turnSpread(
    NavigationDirection direction,
    FirstPageArrangement Function(String entryId) arrangementFor,
  ) {
    if (_pendingActions.length >= ReaderNavigationQueue.maxPresses) {
      message = '翻页处理中，请稍候。';
      _changed();
      return _navigationTask ?? Future.value();
    }
    _pendingActions.addLast(_SpreadStep(direction, arrangementFor));
    return _navigationTask ??= _drainTurns(_epoch);
  }

  /// Live scrubbing replaces only consecutive pending requests from the same
  /// gesture. Independent pedal steps remain ordered between seek requests.
  Future<void> seek(int pageNumber, {required Object gesture}) {
    final document = current, position = this.position;
    if (document == null || position == null || _disposed) {
      return Future.value();
    }
    final target = pageNumber.clamp(1, document.pageCount);
    final last = _pendingActions.isEmpty ? null : _pendingActions.last;
    if (last is _PageSeek &&
        identical(last.gesture, gesture) &&
        last.document == document.target.key &&
        last.itemId == position.setListItemId) {
      last.page = target;
    } else {
      if (_pendingActions.length >= ReaderNavigationQueue.maxPresses) {
        return Future.value();
      }
      _pendingActions.addLast(
        _PageSeek(document.target.key, position.setListItemId, target, gesture),
      );
    }
    return _navigationTask ??= _drainTurns(_epoch);
  }

  void cancelSeek(Object gesture) {
    _pendingActions.removeWhere(
      (action) => action is _PageSeek && identical(action.gesture, gesture),
    );
  }

  final _pendingActions = Queue<Object>();
  final _pendingTurns = ReaderNavigationQueue();
  Future<void>? _navigationTask;
  Future<void> _drainTurns(int epoch) async {
    await Future<void>.value();
    try {
      while (!_disposed && epoch == _epoch && _pendingActions.isNotEmpty) {
        final action = _pendingActions.removeFirst();
        if (action is NavigationDirection) {
          await _turn(_pendingTurns.take()!, epoch);
        } else if (action is _SpreadStep &&
            current != null &&
            position != null) {
          final grouping = ReaderSpreads(
            pageCount: current!.pageCount,
            doublePage: true,
            arrangement: action.arrangementFor(position!.entryId),
          );
          final next = grouping.adjacent(
            page,
            action.direction == NavigationDirection.forward ? 1 : -1,
          );
          if (next != null) {
            final previous = position!;
            position = ReadingPosition(
              entryId: previous.entryId,
              revisionId: previous.revisionId,
              pageNumber: next,
              setListItemId: previous.setListItemId,
            );
            cancelPrewarm();
            _savePosition();
            _changed();
          } else {
            final previous = position!;
            await _turn(
              action.direction,
              epoch,
              from: ReadingPosition(
                entryId: previous.entryId,
                revisionId: previous.revisionId,
                setListItemId: previous.setListItemId,
                pageNumber: action.direction == NavigationDirection.forward
                    ? current!.pageCount
                    : 1,
              ),
            );
          }
        } else if (action is _PageSeek &&
            current?.target.key == action.document &&
            position?.setListItemId == action.itemId) {
          position = ReadingPosition(
            entryId: action.document.entryId,
            revisionId: action.document.revisionId,
            pageNumber: action.page,
            setListItemId: action.itemId,
          );
          cancelPrewarm();
          _savePosition();
          _changed();
        }
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

  Future<void> _turn(
    NavigationDirection direction,
    int epoch, {
    ReadingPosition? from,
  }) async {
    if (_disposed || epoch != _epoch || position == null || current == null) {
      return;
    }
    final request = NavigationRequest(
      current: from ?? position!,
      direction: direction,
    );
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
      cancelPrewarm();
      message = null;
      _savePosition();
      _trimCache();
    } else if (result.status != NavigationStatus.boundary) {
      message = switch (result.status) {
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

  /// Continuous scrolling follows an already painted page, rather than queuing
  /// a seek that would pull a newer wheel/dots intent back to an old callback.
  void followPresentedPage(PageKey visible) {
    final currentPosition = position;
    if (_disposed ||
        loading ||
        _navigationTask != null ||
        _pendingActions.isNotEmpty ||
        currentPosition == null ||
        current?.target.key != visible.document ||
        currentPosition.pageNumber == visible.pageNumber) {
      return;
    }
    position = ReadingPosition(
      entryId: visible.entryId,
      revisionId: visible.revisionId,
      pageNumber: visible.pageNumber,
      setListItemId: currentPosition.setListItemId,
    );
    _savePosition();
    _changed();
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
    cancelPrewarm();
    _epoch++;
    for (final loaded in _cache.values) {
      unawaited(loaded.dispose());
    }
    _cache.clear();
    super.dispose();
  }
}

class _PageSeek {
  _PageSeek(this.document, this.itemId, this.page, this.gesture);
  final DocumentKey document;
  final String? itemId;
  final Object gesture;
  int page;
}

class _SpreadStep {
  const _SpreadStep(this.direction, this.arrangementFor);
  final NavigationDirection direction;
  final FirstPageArrangement Function(String entryId) arrangementFor;
}
