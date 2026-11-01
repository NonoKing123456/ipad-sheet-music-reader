import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';

import 'reader_fixture.dart';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/reader/sharp_pdf_page.dart';
import 'package:score_reader/reader/sharp_file_image.dart';
import 'package:score_reader/sync/sync_controller.dart';

class RealLoopback extends HttpOverrides {}

List<int> syntheticPdf() {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Contents 4 0 R >>',
    '<< /Length 23 >>\nstream\n0.9 g 0 0 200 300 re f\nendstream',
  ];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(out.toString()).length;
  out.write('xref\n0 5\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return ascii.encode(out.toString());
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue);
}

Future<LibraryCatalog> seedCatalog(
  Directory root,
  String state,
  int count, {
  int folderCount = 2313,
}) async {
  await root.create(recursive: true);
  final now = DateTime.utc(2026, 1, 1);
  final first = File(
    '${root.path}/folder-0/Synthetic-score-title-for-scale-evidence-000000-only-local-probe.png',
  );
  await first.parent.create(recursive: true);
  await first.writeAsBytes(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
    ),
  );
  final stat = await first.stat();
  final entries = List.generate(count, (i) {
    final n = i.toRadixString(16).padLeft(46, '0');
    return LibraryEntry(
      id: n,
      relativePath:
          'folder-${i % folderCount}/Synthetic-score-title-for-scale-evidence-${i.toString().padLeft(6, '0')}-only-local-probe.${i == 0 ? 'png' : 'pdf'}',
      status: EntryStatus.available,
      availability: ContentAvailability.deferred,
      revisions: [
        ContentRevision(
          id: 'r$n',
          contentHash: null,
          size: i == 0 ? stat.size : 1234,
          modifiedUtc: i == 0 ? stat.modified.toUtc() : now,
          observedUtc: now,
        ),
      ],
      currentRevisionId: 'r$n',
      lastSeenUtc: now,
    );
  });
  await File(state).writeAsString(
    jsonEncode({
      'schemaVersion': 1,
      'rootPath': root.path,
      'generation': 1,
      'savedUtc': now.toIso8601String(),
      'folders': ['', for (var i = 0; i < folderCount; i++) 'folder-$i'],
      'entries': [for (final e in entries) e.toJson()],
    }),
  );
  return LibraryCatalog.open(rootPath: root.path, statePath: state);
}

enum PageFault { none, disconnect, mixed, repeated, excessive, expire }

/// A real HTTP relay observes bounded replies and injects one transport fault;
/// production client/server parsing, authentication and persistence stay real.
class CatalogRelay {
  CatalogRelay(this.upstream);
  final Uri upstream;
  late HttpServer server;
  final client = HttpClient();
  PageFault fault = PageFault.none;
  bool oldServer = false;
  int pages = 0, maxPageBytes = 0, legacyCatalogRequests = 0;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final paged = request.uri.path == '/v2/catalog-page';
        if (paged && oldServer) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/v2/catalog') legacyCatalogRequests++;
        final outgoing = await client.openUrl(
          request.method,
          upstream.resolve(request.uri.toString()),
        );
        request.headers.forEach((name, values) {
          if (name != HttpHeaders.hostHeader &&
              name != HttpHeaders.contentLengthHeader &&
              name != HttpHeaders.transferEncodingHeader) {
            outgoing.headers.set(name, values);
          }
        });
        await outgoing.addStream(request);
        final response = await outgoing.close();
        var bytes = await response.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        if (paged && response.statusCode == 200) {
          pages++;
          if (bytes.length > maxPageBytes) maxPageBytes = bytes.length;
          final page = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          if (fault == PageFault.excessive) {
            page['totalRecords'] = 250001;
            bytes = utf8.encode(jsonEncode(page));
          } else if (page['offset'] != 0) {
            if (fault == PageFault.disconnect) {
              (await request.response.detachSocket(writeHeaders: false))
                  .destroy();
              return;
            }
            if (fault == PageFault.mixed) page['snapshot'] = 'foreign-snapshot';
            if (fault == PageFault.repeated) page['offset'] = 0;
            bytes = utf8.encode(jsonEncode(page));
          } else if (fault == PageFault.expire) {
            await Future<void>.delayed(const Duration(milliseconds: 1500));
          }
        }
        request.response.statusCode = response.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.add(bytes);
        await request.response.close();
      } catch (_) {
        await request.response.close().catchError((Object _) {});
      }
    });
  }

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
  Future<void> close() async {
    await server.close(force: true);
    client.close(force: true);
  }
}

Future<({int status, Map<String, dynamic>? page})> rawCatalog(
  Uri base,
  String token, [
  Map<String, String>? query,
]) async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(
      base.resolve('/v2/catalog-page').replace(queryParameters: query),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    return (
      status: response.statusCode,
      page: response.statusCode == 200
          ? jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>
          : null,
    );
  } finally {
    http.close(force: true);
  }
}

void main() {
  testWidgets(
    'Windows watched legacy PNG and new metadata-only PDF really render through validated reading copies',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 810));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-open-084-'),
      ))!;
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => dir.path,
      );
      final oldRoot = (await tester.runAsync(
        () => Directory('${dir.path}/old').create(),
      ))!;
      final newRoot = (await tester.runAsync(
        () => Directory('${dir.path}/new').create(),
      ))!;
      await writeSyntheticPaper(tester, '${oldRoot.path}/Old.PNG');
      await tester.runAsync(
        () => File('${newRoot.path}/New.pdf').writeAsBytes(syntheticPdf()),
      );
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: true,
      );
      await tester.runAsync(() async {
        await library.initialize();
        await library.selectRoot(oldRoot.path);
        await library.addSource(newRoot.path);
        while (library.scanning) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final original = library.snapshot!.entries.singleWhere(
        (e) => e.relativePath == 'New.pdf',
      );
      final oldEntry = library.snapshot!.entries.singleWhere(
        (e) => e.relativePath == 'Old.PNG',
      );
      expect(original.currentRevision.contentHash, isNull);
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/app/reader.json'),
        ))!,
      );
      final captured = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
        previousDebugPrint(message, wrapWidth: wrapWidth);
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryScreen(
              controller: library,
              readerWorkspace: workspace,
            ),
          ),
        );
        await pumpUntil(tester, () => find.text('New').evaluate().isNotEmpty);
        await tester.tap(find.text('New'));
        await pumpUntil(
          tester,
          () =>
              workspace.store.readingPosition(
                    DocumentKey(
                      entryId: original.id,
                      revisionId: original.currentRevisionId,
                    ),
                  ) !=
                  null ||
              captured.any((m) => m.contains('load_failed')),
        );
        expect(captured.any((m) => m.contains('load_failed')), isFalse);
        expect(find.byType(SharpPdfPage), findsWidgets);
        expect(
          captured.any((m) => m.contains('reading_copy mode=cold')),
          isTrue,
        );
        final newPage =
            tester
                    .widget<SharpPdfPage>(find.byType(SharpPdfPage).first)
                    .colorKey
                as PageKey;
        expect(newPage.entryId, original.id);
        expect(newPage.revisionId, original.currentRevisionId);
        expect(newPage.pageNumber, 1);
        final after = library.snapshot!.entries.singleWhere(
          (e) => e.id == original.id,
        );
        expect(after.currentRevision.contentHash, isNotNull);
        expect(after.currentRevisionId, original.currentRevisionId);
        final readerContext = tester.element(find.byType(LibraryReaderScreen));
        Navigator.of(readerContext).pop();
        await pumpUntil(
          tester,
          () =>
              find.byType(LibraryReaderScreen).evaluate().isEmpty &&
              !library.scanning,
        );
        library.setSource('legacy');
        await tester.pump();
        captured.clear();
        await tester.tap(find.text('Old'));
        await pumpUntil(
          tester,
          () =>
              workspace.store.readingPosition(
                    DocumentKey(
                      entryId: oldEntry.id,
                      revisionId: oldEntry.currentRevisionId,
                    ),
                  ) !=
                  null ||
              captured.any((m) => m.contains('load_failed')),
        );
        expect(captured.any((m) => m.contains('load_failed')), isFalse);
        expect(find.byType(SharpFileImage), findsWidgets);
        expect(
          captured.any((m) => m.contains('reading_copy mode=cold')),
          isTrue,
        );
        final image = tester.widget<SharpFileImage>(
          find.byType(SharpFileImage).first,
        );
        expect(image.path, contains('reading-cache'));
        expect(image.path, isNot('${oldRoot.path}/Old.PNG'));
        await tester.runAsync(() async {
          expect(
            await File('${newRoot.path}/New.pdf').readAsBytes(),
            syntheticPdf(),
          );
        });
        debugPrint(
          'LOCAL_OPEN_FIXED watched_sources=true new_metadata_pdf_presented=true old_png_presented=true stable_page_identity=true reading_copies_verified=true source_unchanged=true',
        );
      } finally {
        debugPrint = previousDebugPrint;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => workspace.flushPositions());
        workspace.dispose();
        library.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathChannel,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('51212-entry v2 metadata is bounded, atomic across page faults, peer-bound and compatible before one selected transfer', () async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = RealLoopback();
    final dir = await Directory.systemTemp.createTemp('large-catalog-084-');
    SyncServer? server;
    CatalogRelay? relay;
    try {
      final old = await seedCatalog(
        Directory('${dir.path}/old'),
        '${dir.path}/old.json',
        62,
        folderCount: 3,
      );
      final large = await seedCatalog(
        Directory('${dir.path}/new'),
        '${dir.path}/new.json',
        51150,
      );
      var includeLarge = false;
      final source = CatalogCollectionSource(
        id: 'synthetic-collection',
        bindings: () => [
          CatalogSourceBinding(
            '11111111111111111111111111111111',
            'Earlier source',
            old,
          ),
          if (includeLarge)
            CatalogSourceBinding(
              '22222222222222222222222222222222',
              'New large source',
              large,
            ),
        ],
      );
      server = await SyncServer.start(
        source: CatalogLibrarySource(catalog: old, libraryId: 'unused-legacy'),
        collectionSource: source,
        readerStore: await ReaderStateStore.open(
          statePath: '${dir.path}/reader.json',
        ),
        stateDirectory: '${dir.path}/server',
        catalogSnapshotTtl: const Duration(seconds: 1),
      );
      relay = CatalogRelay(server.uri);
      await relay.start();
      final client = await SyncClient.pair(
        baseUri: relay.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final objects = await ReplicaLibraryView.open(
        rootDirectory: '${dir.path}/replica',
      );
      final replica = await ReplicaCollectionView.open(objects);
      relay.oldServer = true;
      expect(
        (await client.syncCollection(replica)).status,
        LibrarySyncStatus.complete,
      );
      expect(
        relay.legacyCatalogRequests,
        1,
        reason: '404 from an older computer uses the original v2 endpoint',
      );
      relay.oldServer = false;
      final oldItem = replica.index!.entries.first;
      await replica.select(
        OfflineRule(
          sourceId: oldItem.sourceId,
          entryId: oldItem.entryId,
          selected: true,
        ),
      );
      expect((await client.syncCollection(replica)).downloaded, 1);
      final oldPath = replica.presentationPathFor(oldItem.entryId);
      final originalBytes = await File(oldPath).readAsBytes();
      final downloadedBefore = objects.verificationStats.downloadBytesReceived;
      includeLarge = true;
      final index = await source.index();
      final wire = utf8.encode(jsonEncode(index.toJson())).length;
      expect(wire, greaterThan(16 * 1024 * 1024));
      for (final fault in PageFault.values.skip(1)) {
        relay.fault = fault;
        final rejected = await client.syncCollection(replica);
        expect(rejected.status, LibrarySyncStatus.partial, reason: fault.name);
        expect(
          replica.index!.entries,
          hasLength(62),
          reason: 'no half catalogue on ${fault.name}',
        );
        expect(replica.index!.sources, hasLength(1));
        expect(await File(oldPath).readAsBytes(), originalBytes);
        expect(
          objects.verificationStats.downloadBytesReceived,
          downloadedBefore,
        );
      }
      final reopenedOld = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: objects.rootDirectory),
      );
      expect(reopenedOld.index!.entries, hasLength(62));
      expect(reopenedOld.readableItemFor(oldItem.entryId), isNotNull);
      relay.fault = PageFault.none;
      relay.pages = 0;
      expect(
        (await client.syncCollection(replica)).status,
        LibrarySyncStatus.complete,
      );
      expect(replica.index!.entries, hasLength(51212));
      expect(replica.index!.sources, hasLength(2));
      expect(replica.index!.folders[index.sources.last.id], hasLength(2314));
      expect(relay.pages, greaterThan(1));
      expect(relay.maxPageBytes, lessThanOrEqualTo(512 * 1024));
      expect(server.activeCatalogSnapshots, 0);
      expect(large.contentHashBytesRead, 0);
      expect(objects.verificationStats.downloadBytesReceived, downloadedBefore);
      final catalogPages = relay.pages;
      final newItem = replica.index!.entries.firstWhere(
        (e) => e.sourceId == index.sources.last.id,
      );
      await replica.select(
        OfflineRule(
          sourceId: newItem.sourceId,
          entryId: newItem.entryId,
          selected: true,
        ),
      );
      final selected = await client.syncCollection(
        replica,
        onlyEntryIds: {newItem.entryId},
      );
      expect(selected.status, LibrarySyncStatus.complete);
      expect(selected.downloaded, 1);
      expect(large.contentHashBytesRead, newItem.length);
      expect(replica.selection.rules, hasLength(2));
      expect(replica.currentItems.where(replica.isReady), hasLength(2));
      final reopened = await ReplicaCollectionView.open(
        await ReplicaLibraryView.open(rootDirectory: objects.rootDirectory),
      );
      expect(reopened.index!.entries, hasLength(51212));
      expect(reopened.currentItems.where(reopened.isReady), hasLength(2));
      expect(await File(oldPath).readAsBytes(), originalBytes);
      final peerToken =
          (jsonDecode(
                await File('${dir.path}/client/client.json').readAsString(),
              ) as Map)['token']
              as String;
      final other = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/other',
      );
      final otherToken =
          (jsonDecode(
                await File('${dir.path}/other/client.json').readAsString(),
              ) as Map)['token']
              as String;
      final third = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/third',
      );
      final thirdToken =
          (jsonDecode(
                await File('${dir.path}/third/client.json').readAsString(),
              ) as Map)['token']
              as String;
      expect(other.peerId, isNot(third.peerId));
      final first = (await rawCatalog(server.uri, peerToken)).page!;
      final nextQuery = {
        'snapshot': first['snapshot'] as String,
        'offset': '${first['nextOffset']}',
      };
      expect(
        (await rawCatalog(server.uri, otherToken, nextQuery)).status,
        409,
        reason: 'token belongs only to the authenticated peer',
      );
      expect(
        (await rawCatalog(server.uri, peerToken, {
          'snapshot': first['snapshot'] as String,
          'offset': '0',
        })).status,
        409,
        reason: 'server rejects repeated offsets',
      );
      final again = (await rawCatalog(server.uri, peerToken)).page!;
      await rawCatalog(server.uri, otherToken);
      expect(server.activeCatalogSnapshots, 2);
      await rawCatalog(server.uri, thirdToken);
      expect(server.activeCatalogSnapshots, 2, reason: 'hard cache bound');
      expect(
        (await rawCatalog(server.uri, peerToken, {
          'snapshot': again['snapshot'] as String,
          'offset': '${again['nextOffset']}',
        })).status,
        409,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        server.activeCatalogSnapshots,
        0,
        reason: 'idle snapshots expire without another request',
      );
      await rawCatalog(server.uri, peerToken);
      expect(server.activeCatalogSnapshots, 1);
      await server.close();
      expect(
        server.activeCatalogSnapshots,
        0,
        reason: 'close clears incomplete transfers',
      );
      server = null;
      debugPrint(
        'CATALOG_FIXED entries=51212 prior_wire_bytes=$wire pages=$catalogPages max_page_bytes=${relay.maxPageBytes} interrupted_mixed_repeated_expired_overbudget_keep_old=true old_fallback=true peer_bound=true snapshots_max=2 cleanup=0 metadata_hash_bytes=0 selected_downloads=1 ready_after_reopen=2',
      );
    } finally {
      await relay?.close();
      await server?.close();
      await dir.delete(recursive: true);
      HttpOverrides.global = previousHttp;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('restoring 51k additional metadata source eventually auto-starts the saved multi-root service', () async {
    final dir = await Directory.systemTemp.createTemp('restore-service-084-');
    final data = await Directory('${dir.path}/app/catalogs')
        .create(recursive: true);
    final smallRoot = await Directory('${dir.path}/old').create();
    final largeRoot = await Directory('${dir.path}/new').create();
    String catalogPath(String root) =>
        '${data.path}/${sha256.convert(utf8.encode(Platform.isWindows ? p.normalize(root).toLowerCase() : p.normalize(root)))}.json';
    await seedCatalog(
      smallRoot,
      catalogPath(smallRoot.path),
      62,
      folderCount: 3,
    );
    await seedCatalog(largeRoot, catalogPath(largeRoot.path), 51150);
    await File('${data.parent.path}/sources-settings.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'primaryRoot': smallRoot.path,
        'primaryId': 'legacy',
        'primaryMetadataOnly': false,
        'sources': [
          {
            'id': '22222222222222222222222222222222',
            'name': 'Large source',
            'root': largeRoot.path,
          },
        ],
      }),
    );
    await Directory('${data.parent.path}/sync').create();
    await File('${data.parent.path}/sync/settings.json').writeAsString(
      jsonEncode({'version': 1, 'autoStartServer': true, 'roots': {}}),
    );
    final library = LibraryController(
      dataDirectory: data.parent,
      watchSource: false,
    );
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(statePath: '${data.parent.path}/reader.json'),
    );
    final sync = SyncController(
      library: library,
      workspace: workspace,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    try {
      await library.initialize();
      expect(
        library.scanning,
        isTrue,
        reason: 'restored added source refresh is in flight',
      );
      await sync.initialize();
      for (var i = 0; i < 2000 && (library.scanning || !sync.serving); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(library.scanning, isFalse);
      expect(sync.serving, isTrue, reason: sync.serverMessage);
      expect(library.snapshot!.entries, hasLength(51212));
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        sync.port!,
      );
      socket.destroy();
      expect(sync.autoStartServer, isTrue);
      expect(library.sources, hasLength(2));
      debugPrint(
        'RESTORE_SERVICE_FIXED metadata_entries=51212 roots=2 saved_auto_start=true scanning_completed=true live_listener=true settings_preserved=true',
      );
    } finally {
      await sync.stopServer();
      sync.dispose();
      workspace.dispose();
      library.dispose();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
