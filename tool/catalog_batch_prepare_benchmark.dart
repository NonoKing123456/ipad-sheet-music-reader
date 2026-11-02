import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';

/// Real catalogue/worker/storage/protocol code; synthetic files only. The old
/// cold path is limited to 32 selections to avoid writing 16 GB for no benefit.
class _Source
    implements
        LibrarySource,
        CollectionLibrarySource,
        CollectionObjectLookup,
        CollectionBatchPreparation {
  _Source(this.root, this.state, this.catalog);
  final String root, state;
  LibraryCatalog catalog;
  int workers = 0,
      reads = 0,
      readBytes = 0,
      writes = 0,
      writeBytes = 0,
      hashes = 0,
      hashBytes = 0,
      prepareMicros = 0;
  CatalogCollectionSource get delegate => CatalogCollectionSource(
    id: 'synthetic32',
    bindings: () => [CatalogSourceBinding('legacy', 'Synthetic', catalog)],
  );
  void _count(LibraryCatalog worker) {
    workers++;
    reads += worker.catalogReads;
    readBytes += worker.catalogReadBytes;
    writes += worker.catalogWrites;
    writeBytes += worker.catalogWriteBytes;
    hashes += worker.contentHashOperations;
    hashBytes += worker.contentHashBytesRead;
  }

  @override
  Future<CollectionIndex> index() => delegate.index();
  @override
  Future<CatalogItem?> itemForObject(String id) => delegate.itemForObject(id);
  CatalogItem _item(LibraryEntry entry) => CatalogItem(
    sourceId: 'legacy',
    entryId: entry.id,
    revisionId: entry.currentRevisionId,
    relativePath: entry.relativePath,
    length: entry.currentRevision.size,
    format: 'pdf',
    hash: entry.currentRevision.contentHash,
  );
  @override
  Future<CatalogItem> prepare(String id, String revision) async {
    final clock = Stopwatch()..start();
    try {
      var ready = await catalog.readyIfUnchanged(id);
      if (ready == null) {
        final worker = await LibraryCatalog.open(
          rootPath: root,
          statePath: state,
        );
        final patch = await worker.materializeForPublication(
          id,
          catalog.publication,
        );
        _count(worker);
        if (!await catalog.applyMaterialization(patch)) {
          throw StateError('Unexpected stale benchmark patch');
        }
        ready = patch.entry;
      }
      if (ready.currentRevisionId != revision) {
        throw StateError('Revision changed');
      }
      return _item(ready);
    } finally {
      prepareMicros += clock.elapsedMicroseconds;
    }
  }

  @override
  Future<Map<String, CatalogItem>> prepareMany(
    Map<String, String> selected,
  ) async {
    final clock = Stopwatch()..start();
    try {
      final ready = <String, CatalogItem>{};
      for (final request in selected.entries) {
        final entry = await catalog.readyIfUnchanged(request.key);
        if (entry != null && entry.currentRevisionId == request.value) {
          ready[request.key] = _item(entry);
        }
      }
      if (ready.length == selected.length) return ready;
      final worker = await LibraryCatalog.open(
        rootPath: root,
        statePath: state,
      );
      final patch = await worker.materializeManyForPublication(
        selected,
        catalog.publication,
      );
      _count(worker);
      if (!await catalog.applyBatchMaterialization(patch)) {
        throw StateError('Unexpected stale benchmark patch');
      }
      for (final entry in patch.entries.values) {
        ready[entry.id] = _item(entry);
      }
      return ready;
    } finally {
      prepareMicros += clock.elapsedMicroseconds;
    }
  }

  @override
  Future<Stream<List<int>>> openSelectedObject(String id, String revision) =>
      delegate.openSelectedObject(id, revision);
  @override
  Future<SyncManifest> manifest() async => throw LibrarySourceNotReady();
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async =>
      throw StateError('No legacy source');
}

Future<void> main(List<String> arguments) async {
  final directory = await Directory.systemTemp.createTemp(
    'synthetic-catalog32-',
  );
  final root = await Directory('${directory.path}/source').create();
  try {
    final metadata = <int, (int, DateTime, String)>{};
    for (final id in [
      ...List.generate(32, (i) => i),
      ...List.generate(512, (i) => i + 8638),
    ]) {
      final bytes = Uint8List((300 + (id * 137 % 601)) * 1024);
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = (id + j) % 251;
      }
      final file = await File('${root.path}/$id.pdf').writeAsBytes(bytes);
      metadata[id] = (
        bytes.length,
        (await file.stat()).modified.toUtc(),
        sha256.convert(bytes).toString(),
      );
    }
    final epoch = DateTime.utc(2026, 10, 1);
    final entries = List.generate(53461, (id) {
      final data = metadata[id];
      final revision = 'synthetic-revision-$id';
      final older = ContentRevision(
        id: 'old-synthetic-revision-$id',
        contentHash: 'a' * 64,
        size: 300 * 1024,
        modifiedUtc: epoch,
        observedUtc: epoch,
      );
      return LibraryEntry(
        id: 'synthetic-entry-$id',
        relativePath: '$id.pdf',
        status: id >= 31165 ? EntryStatus.missing : EntryStatus.available,
        availability: id < 8638
            ? ContentAvailability.ready
            : ContentAvailability.deferred,
        revisions: [
          older,
          ContentRevision(
            id: revision,
            contentHash: id < 8638 ? data?.$3 ?? 'b' * 64 : null,
            size: data?.$1 ?? (300 + (id * 137 % 601)) * 1024,
            modifiedUtc: data?.$2 ?? epoch,
            observedUtc: epoch,
          ),
        ],
        currentRevisionId: revision,
        lastSeenUtc: epoch,
      );
    });
    final seed = jsonEncode({
      'schemaVersion': 1,
      'rootPath': root.path,
      'generation': 1,
      'savedUtc': epoch.toIso8601String(),
      'folders': [''],
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });
    final seedBytes = utf8.encode(seed).length;
    final results = <Map<String, Object?>>[];
    for (final run in [
      (false, false, 32),
      (true, false, 32),
      (false, true, 32),
      (true, true, 32),
      (true, false, 512),
    ]) {
      final (bulk, ready, count) = run;
      final label =
          '${bulk ? 'bulk32' : 'legacy31'}-${ready ? 'ready' : 'cold'}-$count';
      final state = File('${directory.path}/$label/catalog.json');
      await state.parent.create(recursive: true);
      await state.writeAsString(seed, flush: true);
      final source = _Source(
        root.path,
        state.path,
        await LibraryCatalog.open(rootPath: root.path, statePath: state.path),
      );
      final server = await SyncServer.start(
        source: source,
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${directory.path}/$label/reader.json',
        ),
        stateDirectory: '${directory.path}/$label/server',
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient(), requests = <String, int>{};
      proxy.listen((incoming) async {
        try {
          requests.update(incoming.uri.path, (n) => n + 1, ifAbsent: () => 1);
          final outgoing = await http.openUrl(
            incoming.method,
            server.uri.resolveUri(incoming.uri),
          );
          incoming.headers.forEach((key, values) {
            if (![
              'host',
              'content-length',
              'transfer-encoding',
            ].contains(key)) {
              outgoing.headers.set(key, values);
            }
          });
          await outgoing.addStream(incoming);
          final response = await outgoing.close();
          incoming.response.statusCode = response.statusCode;
          await incoming.response.addStream(response);
          await incoming.response.close();
        } catch (_) {
          await incoming.response.close().catchError((Object _) {});
        }
      });
      try {
        final client = await SyncClient.pair(
          baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: proxy.port),
          code: server.createPairingCode(),
          stateDirectory: '${directory.path}/$label/client',
        );
        client.enableSmallFileBatches = bulk;
        final replica = await ReplicaCollectionView.open(
          await ReplicaLibraryView.open(
            rootDirectory: '${directory.path}/$label/replica',
          ),
        );
        // Only one rule plus an explicit ID set: selection matching is O(1).
        await replica.select(
          OfflineRule(sourceId: 'legacy', folder: '', selected: true),
        );
        final ids = {
          for (var i = 0; i < count; i++)
            'synthetic-entry-${i + (ready ? 0 : 8638)}',
        };
        requests.clear();
        final clock = Stopwatch()..start();
        final result = await client.syncCollection(
          replica,
          onlyEntryIds: ids,
          onProgress: (_) {
            if (replica.index != null) replica.snapshot;
          },
        );
        clock.stop();
        final record = <String, Object?>{
          'case': label,
          'platform': Platform.operatingSystem,
          'synthetic': true,
          'catalogEntries': 53461,
          'active': 31165,
          'missingTombstones': 22296,
          'initialReady': 8638,
          'initialCold': 22527,
          'seedCatalogBytes': seedBytes,
          'selected': count,
          'selectedSizeKiB': '300..900',
          'replicaSnapshotWarmed': true,
          'status': result.status.name,
          'downloaded': result.downloaded,
          'elapsedMs': clock.elapsedMilliseconds,
          'sourcePrepareMs': source.prepareMicros / 1000,
          'workerLoads': source.workers,
          'catalogReads': source.reads,
          'catalogReadBytes': source.readBytes,
          'catalogWrites': source.writes,
          'catalogWriteBytes': source.writeBytes,
          'contentHashes': source.hashes,
          'contentHashBytes': source.hashBytes,
          'metadataCheckpoints': replica.metadataJournalFlushes,
          'requests': requests,
          'finalEntries': source.catalog.snapshot.entries.length,
          'finalMissing': source.catalog.snapshot.entries
              .where((e) => e.status == EntryStatus.missing)
              .length,
        };
        results.add(record);
        // ignore: avoid_print
        print(jsonEncode(record));
        if (result.status != LibrarySyncStatus.complete ||
            result.downloaded != count ||
            source.hashes != (ready ? 0 : count) ||
            source.catalog.snapshot.entries.length != 53461 ||
            source.catalog.snapshot.entries
                    .where((e) => e.status == EntryStatus.missing)
                    .length !=
                22296) {
          throw StateError('Benchmark integrity assertion failed');
        }
      } finally {
        await proxy.close(force: true);
        http.close(force: true);
        await server.close();
      }
    }
    final output = arguments
        .where((value) => value.startsWith('--output='))
        .firstOrNull;
    if (output != null) {
      await File(output.substring(9)).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'cases': results,
          'boundary': 'Synthetic Windows loopback; no injected latency; no iPad/network speed claim. Legacy cold uses 32 selections only.',
        }),
      );
    }
  } finally {
    // This newly created synthetic workspace is the only deletion target.
    if (!directory.absolute.path.startsWith(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
    )) {
      throw StateError('Unexpected benchmark cleanup root');
    }
    await directory.delete(recursive: true);
  }
}
