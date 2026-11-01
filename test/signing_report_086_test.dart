import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/signing/signing_expiry_chip.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';

class _RealLoopback extends HttpOverrides {}

const hostId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class NoScoreWork implements LibrarySource {
  int calls = 0;
  @override
  Future<SyncManifest> manifest() async {
    calls++;
    throw StateError('status must not request scores');
  }

  @override
  Future<Stream<List<int>>> openObject(String id, String revision) async {
    calls++;
    throw StateError('no scores');
  }
}

Future<void> reportUntil(WidgetTester tester, bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready() && watch.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue);
  await tester.pump();
}

void main() {
  test('authenticated signing receipts are bounded, durable, peer-scoped, serial and optional without score/state exchange', () async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = _RealLoopback();
    final dir = await Directory.systemTemp.createTemp('signing-wire-086-');
    final source = NoScoreWork();
    final reader = await ReaderStateStore.open(
      statePath: '${dir.path}/reader.json',
    );
    var server = await SyncServer.start(
      source: source,
      readerStore: reader,
      stateDirectory: '${dir.path}/server',
    );
    var store = await SigningStatusStore.open('${dir.path}/status');
    final first = await SyncClient.pair(
      baseUri: server.uri,
      code: server.createPairingCode(),
      stateDirectory: '${dir.path}/client-one',
    );
    final second = await SyncClient.pair(
      baseUri: server.uri,
      code: server.createPairingCode(),
      stateDirectory: '${dir.path}/client-two',
    );
    var accepted = 0;
    server.onSigningStatus = (peer, status, receivedAt) async {
      store.setAuthenticatedPeers(hostId, server.authenticatedPeerIds);
      await store.receive(hostId, peer, status, receivedAt);
      accepted++;
    };
    final expires = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    ).add(const Duration(days: 6));
    final generation = reader.snapshot.generation;
    try {
      expect(
        await first.reportSigningStatus(SigningDeviceStatus(expires)),
        isTrue,
      );
      final receipt = store.latest!;
      expect(receipt.peerId, first.peerId);
      expect(
        receipt.receivedAt.difference(DateTime.now().toUtc()).inSeconds.abs(),
        lessThan(3),
      );
      final fixtureCredentials = jsonDecode(
        await File('${dir.path}/client-one/client.json').readAsString(),
      ) as Map;
      final http = HttpClient();
      Future<int> raw(Object body, {bool authenticated = true}) async {
        final request = await http.postUrl(
          server.uri.resolve('/device-status/signing'),
        );
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${authenticated ? fixtureCredentials['token'] : 'synthetic-invalid'}',
        );
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        expect(
          await raw({
            'status': 'known',
            'expirationMilliseconds': expires.millisecondsSinceEpoch,
          }, authenticated: false),
          401,
        );
        expect(await raw({'status': 'unknown', 'peerId': second.peerId}), 400);
        expect(await raw({'status': 'unknown', 'padding': 'x' * 1100}), 413);
        expect(
          await raw({'status': 'known', 'expirationMilliseconds': -1}),
          400,
        );
      } finally {
        http.close(force: true);
      }
      expect(accepted, 1);
      await second.reportSigningStatus(
        SigningDeviceStatus(expires.add(const Duration(days: 1))),
      );
      expect(store.latest!.peerId, second.peerId);
      store.setAuthenticatedPeers(hostId, {first.peerId});
      expect(
        store.latest!.peerId,
        first.peerId,
        reason: 'a revoked/newer receipt cannot become current',
      );
      store.selectServer('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      expect(
        store.latest,
        isNull,
        reason: 'other former source/server receipts are outside current scope',
      );
      store.selectServer(hostId);
      await store.close();
      store = await SigningStatusStore.open('${dir.path}/status');
      expect(
        store.latest,
        isNull,
        reason:
            'reopened cache is hidden until current authentication is checked',
      );
      store.setAuthenticatedPeers(hostId, {first.peerId});
      expect(store.latest!.status.expiration, expires);
      await Future.wait([
        store.receive(
          hostId,
          first.peerId,
          SigningDeviceStatus(expires.add(const Duration(days: 2))),
          DateTime.now().toUtc(),
        ),
        store.receive(
          hostId,
          first.peerId,
          const SigningDeviceStatus(null),
          DateTime.now().toUtc(),
        ),
      ]);
      expect(store.latest!.status.expiration, isNull);
      expect(
        store.latest!.lastKnownExpiration,
        expires.add(const Duration(days: 2)),
      );
      await store.close();
      store = await SigningStatusStore.open('${dir.path}/status');
      store.setAuthenticatedPeers(hostId, {first.peerId});
      expect(store.latest!.status.expiration, isNull);
      expect(
        store.latest!.lastKnownExpiration,
        expires.add(const Duration(days: 2)),
      );
      server.onSigningStatus = null;
      expect(
        await first.reportSigningStatus(SigningDeviceStatus(expires)),
        isFalse,
        reason: 'old/optional server 404 is silent compatibility',
      );
      expect(source.calls, 0);
      expect(reader.snapshot.generation, generation);
      debugPrint(
        'SIGNING_REPORT_086 auth401=true size413=true strict_body=true server_clock=true peer_filter=true serial_unknown_retains_known=true reopen=true optional404=true score_calls=0 reader_state_unchanged=true',
      );
    } finally {
      await server.close();
      await store.close();
      HttpOverrides.global = previousHttp;
    }
  });

  testWidgets(
    'native home report survives late server startup, coalesces latest pending and mirrors historical receipt without online claims',
    (tester) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _RealLoopback();
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('signing-latest-086-'),
      ))!;
      final source = NoScoreWork();
      final hostReader = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/host-reader.json'),
      ))!;
      var server = (await tester.runAsync(
        () => SyncServer.start(
          source: source,
          readerStore: hostReader,
          stateDirectory: '${dir.path}/server',
        ),
      ))!;
      final port = server.port;
      final store = (await tester.runAsync(
        () => SigningStatusStore.open('${dir.path}/status'),
      ))!;
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/client-app'),
        watchSource: false,
      );
      final workspace = ReaderWorkspace(
        (await tester.runAsync(
          () => ReaderStateStore.open(
            statePath: '${dir.path}/client-reader.json',
          ),
        ))!,
      );
      final client = SyncController(library: library, workspace: workspace);
      final display = ValueNotifier<SigningStatusReceipt?>(null);
      const native = MethodChannel('score_reader/signing_expiry');
      var nativeReads = 0, reportCount = 0;
      var expires = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      ).add(const Duration(days: 2, minutes: 10));
      final finalDate = expires.add(const Duration(days: 2));
      final gate = Completer<void>();
      store.onChanged = () => display.value = store.latest;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        _,
      ) async {
        nativeReads++;
        return {
          'status': 'known',
          'expirationMilliseconds': expires.millisecondsSinceEpoch,
        };
      });
      try {
        await tester.runAsync(() async {
          await library.initialize();
          await client.initialize();
          await client.pair(server.uri.toString(), server.createPairingCode());
          await client.collection!.updateIndex(
            CollectionIndex(
              id: 'synthetic',
              sources: const [LibrarySourceInfo('demo', '示例谱库')],
              folders: const {
                'demo': [''],
              },
              entries: [],
            ),
          );
          await server.close();
        });
        final recoveryWatch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineLibraryScreen(controller: client, isHome: true),
          ),
        );
        await reportUntil(tester, () => nativeReads == 1);
        // Keep the port closed while pumping IO so the first attempt really fails.
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
        }
        // Advance the request deadline while still closed, then process its failure.
        await tester.pump(const Duration(seconds: 4));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        server = (await tester.runAsync(
          () => SyncServer.start(
            source: source,
            readerStore: hostReader,
            stateDirectory: '${dir.path}/server',
            port: port,
          ),
        ))!;
        server.onSigningStatus = (peer, status, receivedAt) async {
          reportCount++;
          if (reportCount == 1) await gate.future;
          store.setAuthenticatedPeers(hostId, server.authenticatedPeerIds);
          await store.receive(hostId, peer, status, receivedAt);
        };
        await reportUntil(tester, () => reportCount == 1);
        expect(
          recoveryWatch.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: 2)),
          reason: 'a failed initial connection recovered through the bounded pending retry',
        );
        expires = expires.add(const Duration(days: 1));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await reportUntil(tester, () => nativeReads == 2);
        expires = finalDate;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await reportUntil(tester, () => nativeReads == 3);
        gate.complete();
        await reportUntil(
          tester,
          () => store.latest?.status.expiration == finalDate,
        );
        expect(
          reportCount,
          2,
          reason:
              'only the in-flight report and latest pending report are sent',
        );
        expect(source.calls, 0);
        await tester.runAsync(server.close);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                title: SigningExpiryChip(
                  pairedDevice: true,
                  pairedStatus: display,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('iPad签名剩余4天'), findsOneWidget);
        expect(
          nativeReads,
          3,
          reason: 'desktop mirror never reads its local unsigned bundle',
        );
        await tester.tap(find.text('iPad签名剩余4天'));
        await tester.pumpAndSettle();
        expect(find.textContaining('电脑收到：'), findsOneWidget);
        expect(find.textContaining('功能更新需安装新版'), findsOneWidget);
        final currentPeer = store.latest!.peerId;
        await tester.runAsync(
          () => store.receive(
            hostId,
            currentPeer,
            const SigningDeviceStatus(null),
            DateTime.now().toUtc(),
          ),
        );
        await tester.pump();
        expect(find.text('到期时间待确认'), findsOneWidget);
        expect(find.textContaining('上次读到的到期时间：'), findsOneWidget);
        expect(find.textContaining('该次确认：'), findsOneWidget);
        store.setAuthenticatedPeers(hostId, {});
        await tester.pump();
        expect(
          find.text('到期时间待确认'),
          findsOneWidget,
          reason: 'revocation also clears an already open details view',
        );
        expect(find.textContaining('电脑收到：'), findsNothing);
        expect(find.textContaining('上次读到的到期时间：'), findsNothing);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        final legacy = (await tester.runAsync(
          () => HttpServer.bind(InternetAddress.loopbackIPv4, port),
        ))!;
        var legacyRequests = 0;
        legacy.listen((request) async {
          legacyRequests++;
          await request.drain<void>();
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"error":"old server"}');
          await request.response.close();
        });
        client.reportLocalSigningExpiry(finalDate);
        await reportUntil(tester, () => legacyRequests == 1);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2200)),
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        expect(legacyRequests, 1, reason: '404 does not schedule a retry loop');
        await tester.runAsync(() => legacy.close(force: true));
        expect(source.calls, 0);
        debugPrint(
          'SIGNING_REPORT_086 late_startup_retry_without_sync=true native_reads=3 latest_reports=2 score_calls=0 offline_historical_chip=true live_revocation_hides_cache=true',
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await tester.pumpWidget(const SizedBox());
        client.dispose();
        workspace.dispose();
        library.dispose();
        await tester.runAsync(store.close);
        display.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        );
        await tester.binding.setSurfaceSize(null);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        HttpOverrides.global = previousHttp;
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Windows actual home restores only a still-authenticated cached iPad receipt without native IO',
    (tester) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _RealLoopback();
      await tester.binding.setSurfaceSize(const Size(810, 900));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('signing-desktop-home-086-'),
      ))!;
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/app'),
        watchSource: false,
      );
      final source = NoScoreWork();
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      ).add(const Duration(days: 5, minutes: 10));
      const native = MethodChannel('score_reader/signing_expiry');
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        _,
      ) async {
        reads++;
        throw StateError('desktop must not read its own profile');
      });
      try {
        await tester.runAsync(() async {
          await library.initialize();
          final scores = await Directory('${dir.path}/synthetic-scores')
              .create();
          await File('${scores.path}/Example.pdf')
              .writeAsString('%PDF synthetic metadata only');
          await library.selectRoot(scores.path, metadataOnly: true);
          final normalized = p.normalize(p.absolute(library.rootPath!));
          final rootKey = sha256
              .convert(
                utf8.encode(
                  Platform.isWindows ? normalized.toLowerCase() : normalized,
                ),
              )
              .toString();

          final root = '${library.dataDirectory.path}/sync';
          final reader = await ReaderStateStore.open(
            statePath: '${dir.path}/wire-reader.json',
          );
          final server = await SyncServer.start(
            source: source,
            readerStore: reader,
            stateDirectory: '$root/servers/$hostId',
          );
          final client = await SyncClient.pair(
            baseUri: server.uri,
            code: server.createPairingCode(),
            stateDirectory: '${dir.path}/fixture-client',
          );
          final store = await SigningStatusStore.open('$root/signing-status');
          store.setAuthenticatedPeers(hostId, server.authenticatedPeerIds);
          await store.receive(
            hostId,
            client.peerId,
            SigningDeviceStatus(expiry),
            DateTime.now().toUtc().subtract(const Duration(days: 1)),
          );
          await store.close();
          await server.close();
          await File('$root/settings.json').writeAsString(
            jsonEncode({
              'version': 1,
              'roots': {
                rootKey: {'id': hostId, 'port': 0},
              },
            }),
          );
        });
        await tester.pumpWidget(
          MaterialApp(home: LibraryScreen(controller: library)),
        );
        await reportUntil(
          tester,
          () => find.text('iPad签名剩余5天').evaluate().isNotEmpty,
        );
        expect(reads, 0);
        expect(source.calls, 0);
        await tester.tap(find.text('iPad签名剩余5天'));
        await tester.pumpAndSettle();
        expect(find.textContaining('电脑收到：'), findsOneWidget);
        expect(find.textContaining('上次回报'), findsNWidgets(2));
        expect(find.textContaining('功能更新需安装新版'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final other = await Directory('${dir.path}/other-root').create();
          await library.selectRoot(other.path, metadataOnly: true);
        });
        await reportUntil(
          tester,
          () => find.text('iPad签名未回报').evaluate().isNotEmpty,
        );
        expect(
          find.text('iPad签名剩余5天'),
          findsNothing,
          reason: 'switching the active server/root immediately hides the former pair cache',
        );
        debugPrint(
          'SIGNING_REPORT_086 actual_windows_home=true cached_auth_checked=true old_receipt_kept_offline=true native_reads=0 score_calls=0',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        library.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        );
        await tester.binding.setSurfaceSize(null);
        HttpOverrides.global = previousHttp;
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
