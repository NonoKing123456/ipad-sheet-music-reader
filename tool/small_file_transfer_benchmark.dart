import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';

/// Synthetic loopback only. Never enumerates a user's library or app data.
class SyntheticSmallFiles implements LibrarySource, CollectionLibrarySource {
  SyntheticSmallFiles(this.root, this.sizes);
  final Directory root;
  final List<int> sizes;
  final hashes = <String, String>{};
  CatalogItem item(int i) => CatalogItem(
    sourceId: 'synthetic',
    entryId: '$i',
    revisionId: 'r$i',
    relativePath: '$i.pdf',
    length: sizes[i],
    format: 'pdf',
    hash: hashes['$i'],
  );
  Future<void> create() async {
    await root.create(recursive: true);
    for (var i = 0; i < sizes.length; i++) {
      final bytes = Uint8List(sizes[i]);
      for (var j = 0; j < bytes.length; j++) {
        bytes[j] = (i + j) % 251;
      }
      await File('${root.path}/$i.pdf').writeAsBytes(bytes);
    }
  }

  @override
  Future<CollectionIndex> index() async => CollectionIndex(
    id: 'synthetic',
    sources: const [LibrarySourceInfo('synthetic', 'Synthetic')],
    entries: List.generate(sizes.length, item),
    folders: const {
      'synthetic': [''],
    },
  );
  @override
  Future<CatalogItem> prepare(String id, String revision) async {
    final i = int.parse(id);
    if (revision != 'r$i') throw StateError('Revision changed');
    hashes[id] =
        (await sha256.bind(File('${root.path}/$i.pdf').openRead()).first)
            .toString();
    return item(i);
  }

  @override
  Future<Stream<List<int>>> openSelectedObject(
    String id,
    String revision,
  ) async {
    if (revision != 'r$id') throw StateError('Revision changed');
    return File('${root.path}/$id.pdf').openRead();
  }

  @override
  Future<SyncManifest> manifest() async => throw LibrarySourceNotReady();
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async =>
      throw StateError('No legacy source');
}

Future<void> main(List<String> arguments) async {
  int option(String name, int fallback) => int.parse(
    arguments
        .firstWhere(
          (arg) => arg.startsWith('--$name='),
          orElse: () => '--$name=$fallback',
        )
        .split('=')
        .last,
  );
  final count = option('files', 128),
      size = option('size', 1024),
      delay = option('rtt-ms', 0);
  final root = await Directory.systemTemp.createTemp(
    'synthetic-small-transfer-',
  );
  final source = SyntheticSmallFiles(
    Directory('${root.path}/source'),
    List.filled(count, size),
  );
  await source.create();
  final server = await SyncServer.start(
    source: source,
    collectionSource: source,
    readerStore: await ReaderStateStore.open(
      statePath: '${root.path}/reader.json',
    ),
    stateDirectory: '${root.path}/server',
  );
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final http = HttpClient();
  final requests = <String, int>{};
  proxy.listen((incoming) async {
    try {
      requests.update(incoming.uri.path, (v) => v + 1, ifAbsent: () => 1);
      if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
      final outgoing = await http.openUrl(
        incoming.method,
        server.uri.resolveUri(incoming.uri),
      );
      incoming.headers.forEach((name, values) {
        if (name != 'host' &&
            name != 'transfer-encoding' &&
            name != 'content-length') {
          outgoing.headers.set(name, values);
        }
      });
      await outgoing.addStream(incoming);
      final response = await outgoing.close();
      incoming.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (name != 'transfer-encoding' && name != 'content-length') {
          incoming.response.headers.set(name, values);
        }
      });
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
      stateDirectory: '${root.path}/client',
    );
    client.enableSmallFileBatches = !arguments.contains('--legacy');
    final replica = await ReplicaCollectionView.open(
      await ReplicaLibraryView.open(rootDirectory: '${root.path}/replica'),
    );
    await replica.select(
      OfflineRule(sourceId: 'synthetic', folder: '', selected: true),
    );
    requests.clear();
    final rssBefore = ProcessInfo.currentRss;
    var peakRss = rssBefore;
    final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
    });
    final watch = Stopwatch()..start();
    final result = await client.syncCollection(replica);
    watch.stop();
    sampler.cancel();
    final total = count * size;
    // ignore: avoid_print
    print(
      jsonEncode({
        'platform': Platform.operatingSystem,
        'synthetic': true,
        'files': count,
        'fileBytes': size,
        'injectedRequestLatencyMs': delay,
        'result': result.status.name,
        'downloaded': result.downloaded,
        'batching': client.enableSmallFileBatches,
        'metadataJournalFlushes': replica.metadataJournalFlushes,
        'elapsedMs': watch.elapsedMilliseconds,
        'MiBPerSecond': total / 1048576 / (watch.elapsedMicroseconds / 1000000),
        'requests': requests,
        'transferRequests': requests.entries
            .where((e) => e.key.contains('prepare') || e.key.contains('object'))
            .fold(0, (v, e) => v + e.value),
        'sampledRssGrowthBytes': peakRss - rssBefore,
      }),
    );
    if (result.status != LibrarySyncStatus.complete) exitCode = 1;
  } finally {
    await proxy.close(force: true);
    http.close(force: true);
    await server.close();
    await root.delete(recursive: true);
  }
}
