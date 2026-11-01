import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/page_count_service.dart';
import 'package:score_reader/library/windows_file_identity.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/offline_library_screen.dart';

import 'desktop_reader_fixture.dart' show desktopPdf, desktopUntil;

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'visible PDF counts parse single flight, survive cache reopen, invalidate revisions and skip offline placeholders; images never read',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('count-087-'),
      ))!;
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => dir.path,
      );
      final file = File('${dir.path}/synthetic.pdf');
      var revision = 'r1';
      late PageCountFile input;
      await tester.runAsync(() async {
        await file.writeAsBytes(desktopPdf(12));
        final stat = await file.stat();
        input = PageCountFile(
          file.path,
          dir.path,
          size: stat.size,
          modifiedUtc: stat.modified.toUtc(),
        );
      });
      PageCountService create() => PageCountService(
        cacheDirectory: '${dir.path}/cache',
        resolve: (key) => key.revisionId == revision ? input : null,
      );
      var service = create();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ListView.builder(
              itemCount: 51212,
              itemExtent: 72,
              itemBuilder: (_, i) => ScoreFileMetadata(
                entryId: 'entry-$i',
                revisionId: revision,
                path: i == 0 ? 'Synthetic.pdf' : 'not-read.png',
                service: service,
              ),
            ),
          ),
        );
        await desktopUntil(
          tester,
          () => find.text('12页').evaluate().isNotEmpty,
        );
        expect(service.parses, 1);
        expect(attributesAllowLocalMetadata(0x400 | 0x20), true);
        expect(attributesAllowLocalMetadata(0x400 | 0x400000), false);
        expect(service.maxConcurrent, 1);
        expect(find.text('PNG'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        service = create();
        final cached = await tester.runAsync(
          () => service.lookup(const PageMetadataKey('entry-0', 'r1')),
        );
        expect(cached, 12);
        expect(service.parses, 0);
        await tester.runAsync(() async {
          await file.writeAsBytes(desktopPdf(3));
          revision = 'r2';
          final stat = await file.stat();
          input = PageCountFile(
            file.path,
            dir.path,
            size: stat.size,
            modifiedUtc: stat.modified.toUtc(),
          );
        });
        expect(
          await tester.runAsync(
            () => service.lookup(const PageMetadataKey('entry-0', 'r2')),
          ),
          3,
        );
        expect(service.parses, 1);
        await tester.runAsync(() async {
          final result = await Process.run('attrib', ['+o', file.path]);
          expect(result.exitCode, 0);
        });
        expect(
          await tester.runAsync(
            () => service.lookup(const PageMetadataKey('entry-0', 'r2')),
          ),
          3,
        );
        expect(
          await tester.runAsync(
            () => service.lookup(const PageMetadataKey('placeholder', 'r2')),
          ),
          isNull,
        );
        expect(service.parses, 1);
        final other = Directory('${dir.path}/other');
        await tester.runAsync(() async {
          await other.create();
          await File('${other.path}/other.pdf').writeAsBytes(desktopPdf(1));
          final made = await Process.run('cmd.exe', [
            '/c',
            'mklink',
            '/J',
            p.normalize('${dir.path}/alias'),
            p.normalize(other.path),
          ]);
          expect(made.exitCode, 0, reason: '${made.stdout} ${made.stderr}');
        });
        expect(
          await tester.runAsync(
            () => isLocallyReadableFile('${dir.path}/alias/other.pdf'),
          ),
          false,
        );
        debugPrint(
          'PAGE_COUNT_087 virtual_rows=51212 parses=1 max_concurrent=1 cache_reopen_no_parse=true revision_count=3 placeholder_skipped=true images_no_io=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        service.dispose();
        await tester.runAsync(() async {
          await Process.run('attrib', ['-o', file.path]);
          await dir.delete(recursive: true);
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'actual authenticated small metadata batch does not prepare or mutate source catalogue, rejects unknown revisions and falls back on old peers',
    (tester) async {
      final oldHttp = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('count-http-087-'),
      ))!;
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => dir.path,
      );
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      SyncController? sync;
      try {
        await tester.runAsync(() async {
          await File('${dir.path}/root/Synthetic.pdf').create(recursive: true);
          await File('${dir.path}/root/Synthetic.pdf')
              .writeAsBytes(desktopPdf(7));
          await library.initialize();
          await library.selectRoot('${dir.path}/root', metadataOnly: true);
          sync = SyncController(
            library: library,
            workspace: workspace,
            bindAddress: InternetAddress.loopbackIPv4,
          );
          await sync!.initialize();
          await sync!.startServer();
        });
        expect(sync!.serving, true);
        final entry = library.snapshot!.availableEntries.single;
        expect(entry.currentRevision.contentHash, isNull);
        final generation = library.snapshot!.generation;
        final before = await tester.runAsync(
          () => File(library.catalogForSync!.statePath).readAsBytes(),
        );
        final client = (await tester.runAsync(
          () => SyncClient.pair(
            baseUri: Uri.parse('http://127.0.0.1:${sync!.port}'),
            code: sync!.pairingCode!,
            stateDirectory: '${dir.path}/client',
          ),
        ))!;
        final key = PageMetadataKey(entry.id, entry.currentRevisionId);
        final counts = (await tester.runAsync(
          () => client.pageMetadata([
            key,
            const PageMetadataKey('missing', 'r'),
            PageMetadataKey(entry.id, 'stale'),
          ]),
        ))!;
        expect(counts, {key: 7});
        expect(library.snapshot!.generation, generation);
        expect(
          await tester.runAsync(
            () => File(library.catalogForSync!.statePath).readAsBytes(),
          ),
          before,
        );
        expect(entry.currentRevision.contentHash, isNull);
        final credentials = jsonDecode(
          (await tester.runAsync(
            () => File('${dir.path}/client/client.json').readAsString(),
          ))!,
        ) as Map;
        Future<int> raw(Object body, bool authorized) async {
          final http = HttpClient();
          try {
            final req = await http.postUrl(
              Uri.parse(
                'http://127.0.0.1:${sync!.port}/collection/page-metadata',
              ),
            );
            req.headers.set(
              'Authorization',
              'Bearer ${authorized ? credentials['token'] : 'invalid'}',
            );
            req.write(jsonEncode(body));
            final response = await req.close();
            await response.drain<void>();
            return response.statusCode;
          } finally {
            http.close(force: true);
          }
        }

        expect(
          await tester.runAsync(
            () => raw({
              'items': [key.toJson()],
            }, false),
          ),
          401,
        );
        expect(
          await tester.runAsync(
            () => raw({'items': List.filled(17, key.toJson())}, true),
          ),
          400,
        );
        expect(
          await tester.runAsync(
            () => raw({
              'items': [
                {'path': 'C:/private.pdf'},
              ],
            }, true),
          ),
          400,
        );
        final legacy = (await tester.runAsync(
          () => SyncServer.start(
            source: _NoScores(),
            readerStore: workspace.store,
            stateDirectory: '${dir.path}/old-server',
          ),
        ))!;
        try {
          final old = (await tester.runAsync(
            () => SyncClient.pair(
              baseUri: legacy.uri,
              code: legacy.createPairingCode(),
              stateDirectory: '${dir.path}/old-client',
            ),
          ))!;
          expect(await tester.runAsync(() => old.pageMetadata([key])), isEmpty);
        } finally {
          await tester.runAsync(legacy.close);
        }
        debugPrint(
          'PAGE_METADATA_087 real_native_pdf=7 auth_first=true max_batch16=true no_paths=true unknown_stale_omitted=true catalog_bytes_unchanged=true legacy404_unknown=true',
        );
      } finally {
        sync?.dispose();
        library.dispose();
        workspace.dispose();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        HttpOverrides.global = oldHttp;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'iPad actual offline file rows show format and unknown PDF page count, reconnect refresh is row-local and images stay one page',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ipad-count-087-'),
      ))!;
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
        ))!,
      );
      final sync = SyncController(library: library, workspace: workspace);
      try {
        await tester.runAsync(() async {
          await library.initialize();
          await sync.initialize();
          await sync.collection!.updateIndex(
            CollectionIndex(
              id: 'demo',
              sources: const [LibrarySourceInfo('one', '合成谱库')],
              folders: const {
                'one': [''],
              },
              entries: [
                CatalogItem(
                  sourceId: 'one',
                  entryId: 'pdf',
                  revisionId: 'r',
                  relativePath: 'Synthetic.pdf',
                  length: 1234,
                  format: 'pdf',
                ),
                CatalogItem(
                  sourceId: 'one',
                  entryId: 'png',
                  revisionId: 'r',
                  relativePath: 'Synthetic.png',
                  length: 1234,
                  format: 'png',
                ),
              ],
            ),
          );
        });
        await tester.pumpWidget(
          MaterialApp(home: OfflineLibraryScreen(controller: sync)),
        );
        await desktopUntil(tester, () => find.text('待获取').evaluate().isNotEmpty);
        expect(find.text('PNG'), findsOneWidget);
        expect(find.byIcon(Icons.picture_as_pdf_outlined),findsOneWidget);
        expect(find.byIcon(Icons.image_outlined),findsOneWidget);
        final appearances = [for(final ext in ['pdf','jpg','png','webp']) scoreFileAppearance('synthetic.$ext')];
        expect(appearances.map((a)=>a.background).toSet().length,4);
        expect(appearances.every((a)=>ThemeData.estimateBrightnessForColor(a.background) == Brightness.light),true);
        final view = sync.activeCollection!.directory;
        // A successful later metadata reply updates only the mounted row.
        final pdfRow = tester
            .widgetList<ScoreFileMetadata>(find.byType(ScoreFileMetadata))
            .firstWhere((row) => row.path.endsWith('.pdf'));
        sync.pageCounts.remember(
          PageMetadataKey(pdfRow.entryId, pdfRow.revisionId),
          12,
        );
        await tester.pump();
        expect(find.text('12页'), findsOneWidget);
        expect(sync.pageCounts.parses, 0);
        expect(sync.activeCollection!.directory, same(view));
        expect(tester.takeException(), isNull);
        debugPrint(
          'IPAD_PAGE_COUNT_087 pdf_unknown=true image_one_no_io=true late_count_row_update=true structure_unchanged=true parses=0',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync.dispose();
        library.dispose();
        workspace.dispose();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.binding.setSurfaceSize(null);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'remote visible counts batch and persist offline, retry only connection changes, cancel queued interest and keep identical local failures quiet',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('remote-count-087-');
        final batches = <List<PageMetadataKey>>[];
        var connected = false;
        final service = PageCountService(
          resolve: (_) => null,
          cacheDirectory: '${dir.path}/remote',
          remote: (keys) async {
            batches.add(List.of(keys));
            return connected ? {for (final key in keys) key: 12} : {};
          },
        );
        final keys = List.generate(20, (i) => PageMetadataKey('pdf-$i', 'r1'));
        PageCountService? reopened, broken;
        const provider = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          (_) async => dir.path,
        );
        try {
          final rows = [for (final key in keys) service.watch(key)];
          service.unwatch(keys.last);
          await Future.wait(keys.take(19).map(service.lookup));
          expect(batches.map((e) => e.length), [16, 3]);
          expect(batches.expand((e) => e), isNot(contains(keys.last)));
          for (var i = 0; i < 20; i++) {
            service.refreshVisible();
          }
          expect(batches.length, 2);
          connected = true;
          service.connectionChanged();
          await Future.wait(keys.take(19).map(service.lookup));
          expect(rows.take(19).every((row) => row.value == 12), true);
          expect(batches.length, 4);
          var unexpectedNetwork = 0;
          reopened = PageCountService(
            resolve: (_) => null,
            cacheDirectory: '${dir.path}/remote',
            remote: (_) async {
              unexpectedNetwork++;
              throw const SocketException('offline');
            },
          );
          expect(await reopened.lookup(keys.first), 12);
          expect(
            await reopened.lookup(PageMetadataKey(keys.first.entryId, 'r2')),
            isNull,
          );
          expect(unexpectedNetwork, 1);
          final file = File('${dir.path}/broken.pdf');
          await file.writeAsString('synthetic broken PDF');
          final stat = await file.stat();
          broken = PageCountService(
            resolve: (_) => PageCountFile(
              file.path,
              dir.path,
              size: stat.size,
              modifiedUtc: stat.modified.toUtc(),
            ),
          );
          final bad = broken.watch(const PageMetadataKey('bad', 'r'));
          await broken.lookup(const PageMetadataKey('bad', 'r'));
          expect(broken.parses, 1);
          expect(bad.value, isNull);
          for (var i = 0; i < 40; i++) {
            broken.refreshVisible();
          }
          expect(broken.parses, 1);
          final elsewhere = Directory('${dir.path}/elsewhere');
          await elsewhere.create();
          final made = await Process.run('cmd.exe', [
            '/c',
            'mklink',
            '/J',
            p.normalize('${dir.path}/linked'),
            p.normalize(elsewhere.path),
          ]);
          expect(made.exitCode, 0, reason: '${made.stdout} ${made.stderr}');
          final linked = PageCountService(
            resolve: (_) => null,
            cacheDirectory: '${dir.path}/linked',
            remote: (keys) async => {for (final key in keys) key: 5},
          );
          expect(await linked.lookup(keys.first), 5);
          expect(await elsewhere.list().toList(), isEmpty);
          linked.dispose();
          debugPrint(
            'REMOTE_PAGE_COUNT_087 batches=16+3 canceled_interest=true same_failure_no_reparse=true connection_retry=true offline_cached=12 new_revision_unknown=true linked_cache_rejected=true',
          );
        } finally {
          service.dispose();
          reopened?.dispose();
          broken?.dispose();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            provider,
            null,
          );
        }
      });
    },
  );
}

class _NoScores implements LibrarySource {
  @override
  Future<SyncManifest> manifest() =>
      throw StateError('No catalogue request allowed');
  @override
  Future<Stream<List<int>>> openObject(String a, String b) =>
      throw StateError('No content transfer allowed');
}
