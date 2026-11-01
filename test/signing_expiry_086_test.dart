import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/signing/signing_expiry_chip.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';

class SigningTestSync extends SyncController {
  SigningTestSync({required super.library, required super.workspace});
  int fullSnapshots = 0, fullCatalogs = 0;
  @override
  LibrarySnapshot? get offlineSnapshot {
    fullSnapshots++;
    return super.offlineSnapshot;
  }

  @override
  List<ScoreCatalogEntry> get offlineScoreCatalog {
    fullCatalogs++;
    return super.offlineScoreCatalog;
  }
}

Future<void> signingFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
}

void main() {
  test('signature countdown uses exact profile date across day/hour/minute/expiry and unknown boundaries', () {
    final now = DateTime.utc(2026, 11, 1, 12);
    SigningExpiry after(Duration duration) => SigningExpiry(now.add(duration));
    expect(after(const Duration(days: 7)).label(now), '签名剩余7天');
    expect(after(const Duration(days: 1)).label(now), '签名剩余1天');
    expect(
      after(const Duration(hours: 23, minutes: 59)).label(now),
      '签名剩余23小时',
    );
    expect(after(const Duration(hours: 1)).label(now), '签名剩余1小时');
    expect(after(const Duration(minutes: 59)).label(now), '签名剩余59分钟');
    expect(after(const Duration(minutes: 1)).label(now), '签名剩余1分钟');
    expect(after(const Duration(seconds: 1)).label(now), '签名不足1分钟');
    expect(after(Duration.zero).label(now), '签名已到期');
    expect(after(const Duration(seconds: -1)).label(now), '签名已到期');
    expect(after(const Duration(days: 1)).nearExpiry(now), isFalse);
    expect(after(const Duration(hours: 23)).nearExpiry(now), isTrue);
    final known = SigningExpiry.fromNative({
      'status': 'known',
      'expirationMilliseconds': now.millisecondsSinceEpoch,
    });
    expect(known.expiration, now);
    expect(known.exactLocalTime, contains('(UTC'));
    expect(known.exactLocalTime, contains(':00'));
    for (final payload in [
      null,
      {},
      {'status': 'unknown'},
      {'status': 'known', 'expirationMilliseconds': 'not a date'},
      {'status': 'known', 'expirationMilliseconds': -1},
      {'status': 'known', 'expirationMilliseconds': 8640000000000001},
    ]) {
      expect(SigningExpiry.fromNative(payload).label(now), '签名待确认');
      expect(SigningExpiry.fromNative(payload).expiration, isNull);
    }
  });

  testWidgets(
    'home signature leaf refreshes on resume, keeps search controls and no full-library work; Windows never reads or shows it',
    (tester) async {
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(const Size(810, 1080));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('signing-expiry-086-'),
      ))!;
      final library = LibraryController(
        dataDirectory: Directory('${dir.path}/library'),
        watchSource: false,
      );
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/reader.json'),
      ))!;
      final workspace = ReaderWorkspace(store);
      final sync = SigningTestSync(library: library, workspace: workspace);
      var notifications = 0, nativeCalls = 0;
      final expiration = DateTime.now().toUtc().add(
        const Duration(days: 3, minutes: 10),
      );
      Object? response = {
        'status': 'known',
        'expirationMilliseconds': expiration.millisecondsSinceEpoch,
      };
      Completer<Object?>? gate;
      const native = MethodChannel('score_reader/signing_expiry');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        expect(call.method, 'expiration');
        expect(call.arguments, isNull);
        nativeCalls++;
        return gate == null ? response : await gate.future;
      });
      try {
        await tester.runAsync(() async {
          await library.initialize();
          await sync.initialize();
          await sync.collection!.updateIndex(
            CollectionIndex(
              id: 'synthetic-signing-home',
              sources: const [LibrarySourceInfo('demo', '练习谱库')],
              folders: const {
                'demo': ['', '练习'],
              },
              entries: [
                CatalogItem(
                  sourceId: 'demo',
                  entryId: 'song',
                  revisionId: 'r1',
                  relativePath: '练习/练习曲.pdf',
                  length: 100,
                  format: 'pdf',
                ),
              ],
            ),
          );
        });
        final directory = sync.collection!.directory;
        sync.addListener(() => notifications++);
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineLibraryScreen(controller: sync, isHome: true),
          ),
        );
        await signingFrames(tester);
        if (!ios) {
          expect(find.byType(SigningExpiryChip), findsNothing);
          expect(nativeCalls, 0);
          debugPrint(
            'SIGNING_EXPIRY_086 non_iOS_native_calls=0 chip_visible=false',
          );
          return;
        }
        expect(nativeCalls, 1);
        expect(find.text('签名剩余3天'), findsOneWidget);
        expect(
          tester.getSize(find.widgetWithText(TextButton, '签名剩余3天')).height,
          greaterThanOrEqualTo(44),
        );
        final baselineNotifications = notifications;
        final baselineFullSnapshots = sync.fullSnapshots,
            baselineCatalogs = sync.fullCatalogs;
        expect(baselineFullSnapshots, 0);
        expect(baselineCatalogs, 0);
        await tester.tap(find.text('签名剩余3天'));
        await signingFrames(tester);
        expect(
          find.text(SigningExpiry(expiration).exactLocalTime),
          findsOneWidget,
        );
        expect(find.textContaining('自动续签由电脑Sideloadly处理'), findsOneWidget);
        expect(find.textContaining('已开启'), findsNothing);
        await tester.tap(find.text('知道了'));
        await signingFrames(tester);
        await tester.tap(find.byTooltip('搜索'));
        await tester.pump();
        expect(find.text('签名剩余3天').hitTestable(), findsNothing);
        await tester.tap(find.byTooltip('关闭搜索'));
        await tester.pump();
        expect(
          nativeCalls,
          1,
          reason: 'hiding search preserves the leaf without reading the profile again',
        );
        await tester.pump(const Duration(minutes: 2));
        expect(nativeCalls, 1, reason: 'countdown ticks use memory only');
        expect(notifications, baselineNotifications);
        expect(sync.fullSnapshots, baselineFullSnapshots);
        expect(sync.fullCatalogs, baselineCatalogs);
        expect(identical(sync.collection!.directory, directory), isTrue);

        gate = Completer<Object?>();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(nativeCalls, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(nativeCalls, 2, reason: 'in-flight native reads coalesce');
        gate.complete({'status': 'unknown'});
        gate = null;
        await signingFrames(tester);
        expect(find.text('签名期限未读取'), findsOneWidget);
        await tester.tap(find.text('签名期限未读取'));
        await signingFrames(tester);
        expect(find.text('暂未读取到到期时间。'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await signingFrames(tester);

        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          _,
        ) async {
          nativeCalls++;
          throw PlatformException(code: 'synthetic_unavailable');
        });
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await signingFrames(tester);
        expect(nativeCalls, 3);
        expect(find.text('签名期限未读取'), findsOneWidget);
        expect(notifications, baselineNotifications);
        expect(sync.fullSnapshots, baselineFullSnapshots);
        expect(sync.fullCatalogs, baselineCatalogs);
        expect(identical(sync.collection!.directory, directory), isTrue);
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'the small chip does not overflow a narrow title',
        );
        expect(tester.getTopLeft(find.byTooltip('搜索')).dy, lessThan(60));
        debugPrint(
          'SIGNING_EXPIRY_086 startup_resume_singleflight=true unknown_and_error=true search_preserves_leaf=true full_snapshot_delta=0 full_catalog_delta=0 controller_notifications_delta=0 tap_target_at_least44=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync.dispose();
        workspace.dispose();
        library.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        );
        await tester.binding.setSurfaceSize(null);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.windows,
    }),
  );
}
