import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../library/page_count_service.dart';

/// One worker owns all metadata decoding, broad search and durable writes.
/// There is no enumeration or parsing of the application's score library.
Future<void> _songbookWorker((String, SendPort) input) async {
  final receive = ReceivePort();
  try {
    final store = await SongbookStore.open(input.$1);
    input.$2.send(receive.sendPort);
    await for (final message in receive) {
      final (int id, String method, Object? payload) =
          message as (int, String, Object?);
      try {
        Object? result;
        switch (method) {
          case 'load':
            final key = payload as PageMetadataKey;
            final existing = store.get(key);
            final index = existing ?? await store.carryManual(key);
            result = (index, existing == null && index != null);
          case 'save':
            final data =
                payload
                    as (PageMetadataKey, String?, String, int?, List<String>);
            result = await store.saveItem(
              data.$1,
              itemId: data.$2,
              title: data.$3,
              pageNumber: data.$4,
              ancestors: data.$5,
            );
          case 'outline':
            final data = payload as (PageMetadataKey, int, List<SongbookItem>);
            result = await store.mergeOutline(data.$1, data.$2, data.$3);
          case 'merge':
            result = await store.mergeRemote(payload as SongbookIndex);
          case 'bookKeys':
            result = [for (final index in store.indexes) index.key];
          case 'search':
            final (query, books, limit) =
                payload as (String, Set<PageMetadataKey>?, int);
            result = searchSongbooks(
              books == null ? store.indexes : books.map(store.get).nonNulls,
              query,
              limit: limit,
            );
          case 'changes':
            result = store.changes(payload as String?);
          case 'progress':
            final file = p.join(input.$1, 'peer-progress.json');
            if (payload != null) {
              await writeJson(file, payload as Map<String, Object?>);
            }
            result = await readJson(file) ?? <String, dynamic>{};
          default:
            throw StateError('Unknown songbook operation.');
        }
        input.$2.send((id, true, result));
      } catch (error) {
        input.$2.send((id, false, error.toString()));
      }
    }
  } catch (error) {
    input.$2.send((-1, false, error.toString()));
  } finally {
    receive.close();
  }
}

typedef SongbookOutlineReader = Future<(int, List<SongbookItem>)> Function(
  String path,
);

Future<(int, List<SongbookItem>)> _readPdfOutline(String path) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(
    path,
    useProgressiveLoading: true,
  );
  try {
    // pdfrx_engine 0.8.0: loadOutline uses PDFium _computeWithArena worker.
    // PdfDest.pageNumber is already one-based; no render/image calls occur.
    final outline = await document.loadOutline();
    final items = <SongbookItem>[];
    void append(List<PdfOutlineNode> nodes, List<String> ancestors) {
      for (final node in nodes) {
        if (items.length >= 10000 || ancestors.length >= 64) {
          throw const FormatException(
            'PDF outline exceeds the supported metadata limit.',
          );
        }
        final title = node.title.trim();
        if (title.isEmpty) {
          append(node.children, ancestors);
          continue;
        }
        final page = node.dest?.pageNumber;
        final signature = songbookItemSignature(title, page, ancestors);
        items.add(
          SongbookItem(
            id: 'p-$signature',
            title: title,
            pageNumber: page != null && page > 0 ? page : null,
            ancestors: List.unmodifiable(ancestors),
            sourceSignature: signature,
          ),
        );
        append(node.children, [...ancestors, title]);
      }
    }

    append(outline, []);
    return (document.pages.length, items);
  } finally {
    await document.dispose();
  }
}

class SongbookService extends ChangeNotifier {
  SongbookService({
    required this.directory,
    required this.resolve,
    this.outlineReader = _readPdfOutline,
    this.onLocalChange,
  });
  final String directory;
  final PageCountResolver resolve;
  final SongbookOutlineReader outlineReader;
  final VoidCallback? onLocalChange;
  Future<SendPort>? _starting;
  Isolate? _worker;
  ReceivePort? _replies;
  final _pending = <int, Completer<Object?>>{};
  final _loads = <PageMetadataKey, Future<SongbookIndex?>>{};
  int _next = 0;
  bool _closed = false;
  Future<void> _parses = Future.value();
  Future<void>? _syncing;
  int parses = 0;

  Future<SendPort> _start() => _starting ??= () async {
    if (_closed) throw StateError('Songbook service closed.');
    final ready = Completer<SendPort>();
    final replies = _replies = ReceivePort();
    replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is (int, bool, Object?)) {
        if (message.$1 == -1) {
          final error = StateError('${message.$3}');
          if (!ready.isCompleted) ready.completeError(error);
          for (final done in _pending.values) {
            done.completeError(error);
          }
          _pending.clear();
          return;
        }
        final done = _pending.remove(message.$1);
        if (message.$2) {
          done?.complete(message.$3);
        } else {
          done?.completeError(StateError('${message.$3}'));
        }
      }
    });
    try {
      _worker = await Isolate.spawn(_songbookWorker, (
        directory,
        replies.sendPort,
      ));
      if (_closed) throw StateError('Songbook service closed.');
      return await ready.future;
    } catch (_) {
      // A later search can reopen the index once storage is available again.
      _worker?.kill();
      replies.close();
      _starting = null;
      rethrow;
    }
  }();

  Future<T> _call<T>(String method, Object? payload) async {
    final port = await _start();
    if (_closed) throw StateError('Songbook service closed.');
    final id = ++_next, done = Completer<Object?>();
    _pending[id] = done;
    port.send((id, method, payload));
    return (await done.future) as T;
  }

  Future<SongbookIndex?> load(PageMetadataKey key, {bool reread = false}) {
    final running = _loads[key];
    if (running != null) return running;
    final task = _load(key, reread);
    _loads[key] = task;
    task.then(
      (_) => _loads.remove(key),
      onError: (Object _, StackTrace _) {
        _loads.remove(key);
      },
    );
    return task;
  }

  Future<SongbookIndex?> _load(PageMetadataKey key, bool reread) async {
    final (cached, carriedManual) = await _call<(SongbookIndex?, bool)>(
      'load',
      key,
    );
    if (carriedManual && !_closed) notifyListeners();
    if (cached?.extracted == true && !reread) return cached;
    final input = resolve(key);
    if (input == null || p.extension(input.path).toLowerCase() != '.pdf') {
      return cached;
    }
    final done = Completer<SongbookIndex?>();
    // The separate PDF document is metadata-only and single flight. Reader
    // page rendering and its existing limited prefetch queue are untouched.
    _parses = _parses.then((_) async {
      try {
        if (_closed || !input.same(resolve(key))) {
          done.complete(cached);
          return;
        }
        final file = File(input.path);
        final actual = await file.resolveSymbolicLinks();
        if (!p.isWithin(input.root, actual)) {
          throw StateError('PDF outside source.');
        }
        final before = await file.stat();
        if (before.type != FileSystemEntityType.file ||
            input.size != null && before.size != input.size ||
            input.modifiedUtc != null &&
                before.modified.toUtc() != input.modifiedUtc) {
          throw StateError('PDF revision changed.');
        }
        parses++;
        final (pages, items) = await outlineReader(actual);
        final after = await file.stat();
        if (_closed ||
            !input.same(resolve(key)) ||
            before.size != after.size ||
            before.modified != after.modified ||
            actual != await file.resolveSymbolicLinks()) {
          throw StateError('PDF revision changed during indexing.');
        }
        final index = await _call<SongbookIndex>('outline', (
          key,
          pages,
          items,
        ));
        if (!_closed) {
          notifyListeners();
          onLocalChange?.call();
        }
        done.complete(index);
      } catch (error, stack) {
        // Failed extraction is never persisted as an empty successful outline.
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<SongbookIndex> saveItem(
    PageMetadataKey key, {
    String? itemId,
    required String title,
    required int? pageNumber,
    List<String> ancestors = const [],
  }) async {
    final index = await _call<SongbookIndex>('save', (
      key,
      itemId,
      title,
      pageNumber,
      ancestors,
    ));
    if (!_closed) {
      notifyListeners();
      onLocalChange?.call();
    }
    return index;
  }

  /// Resolve scope against indexed books only, without walking the file library.
  Future<Set<PageMetadataKey>> indexedBooksWhere(
    bool Function(PageMetadataKey) include,
  ) async => (await _call<List<PageMetadataKey>>(
    'bookKeys',
    null,
  )).where(include).toSet();

  Future<List<SongbookSearchHit>> search(
    String query, {
    PageMetadataKey? key,
    int limit = 100,
  }) => searchBooks(query, key == null ? null : {key}, limit: limit);

  Future<List<SongbookSearchHit>> searchBooks(
    String query,
    Set<PageMetadataKey>? books, {
    int limit = 100,
  }) => _call<List<SongbookSearchHit>>('search', (
    query,
    books,
    limit.clamp(1, 1000),
  ));

  /// Called only behind the sync server's existing peer authentication.
  Future<Map<String, Object?>> exchange(
    Map<String, dynamic> request, {
    required bool Function(PageMetadataKey) allowed,
  }) async {
    final raw = request['items'];
    if (raw is! List ||
        raw.length > 8 ||
        (request['cursor'] != null &&
            (request['cursor'] is! String ||
                (request['cursor'] as String).length > 128))) {
      throw const FormatException('Invalid songbook metadata page.');
    }
    var changed = false;
    for (final item in raw) {
      final incoming = SongbookIndex.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
      if (!allowed(incoming.key)) continue;
      changed = await _call<bool>('merge', incoming) || changed;
    }
    final page = await _call<Map<String, Object?>>(
      'changes',
      request['cursor'],
    );
    page['items'] = (page['items'] as List)
        .where(
          (e) => allowed(
            PageMetadataKey.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        )
        .toList();
    if (changed && !_closed) notifyListeners();
    return page;
  }

  /// Uploads and downloads only changed index metadata, including books without
  /// offline PDF bytes. Per-peer cursors survive restart; old peers return null.
  Future<void> synchronize(
    SyncClient client, {
    required bool Function(PageMetadataKey) allowed,
    SyncCancellation? cancellation,
  }) {
    return _syncing ??= _synchronize(
      client,
      allowed,
      cancellation,
    ).whenComplete(() => _syncing = null);
  }

  Future<void> _synchronize(
    SyncClient client,
    bool Function(PageMetadataKey) allowed,
    SyncCancellation? cancellation,
  ) async {
    final progress = await _call<Map<String, dynamic>>('progress', null);
    final namespace = client.backgroundTransferNamespace;
    final saved = progress[namespace] as Map? ?? {};
    String? upload = saved['upload'] as String?,
        remote = saved['remote'] as String?;
    bool moreUpload = true, moreRemote = true, changed = false;
    while (moreUpload || moreRemote) {
      cancellation?.check();
      final local = await _call<Map<String, Object?>>('changes', upload);
      final response = await client.songbookMetadata({
        'cursor': remote,
        'items': (local['items'] as List)
            .where(
              (e) => allowed(
                PageMetadataKey.fromJson(Map<String, dynamic>.from(e as Map)),
              ),
            )
            .toList(),
      });
      if (response == null) return;
      final raw = response['items'];
      if (raw is! List ||
          raw.length > 8 ||
          response['cursor'] is! String ||
          response['more'] is! bool) {
        throw const FormatException('Invalid songbook metadata reply.');
      }
      for (final item in raw) {
        final index = SongbookIndex.fromJson(
          Map<String, dynamic>.from(item as Map),
        );
        if (allowed(index.key)) {
          changed = await _call<bool>('merge', index) || changed;
        }
      }
      upload = local['cursor'] as String;
      remote = response['cursor'] as String;
      moreUpload = local['more'] == true;
      moreRemote = response['more'] == true;
      final next = {'upload': upload, 'remote': remote};
      if (jsonEncode(progress[namespace]) != jsonEncode(next)) {
        progress[namespace] = next;
        await _call<Object?>('progress', progress);
      }
    }
    if (changed && !_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _worker?.kill(priority: Isolate.immediate);
    _replies?.close();
    for (final done in _pending.values) {
      done.completeError(StateError('Songbook service closed.'));
    }
    _pending.clear();
    super.dispose();
  }
}
