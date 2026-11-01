import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/offline_library_screen.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';

class _HeaderController extends SyncController {
  _HeaderController({required super.library, required super.workspace});

  bool pairedForTest = false;
  int refreshCalls = 0, synchronizeCalls = 0, cancelCalls = 0;

  @override
  bool get paired => pairedForTest;

  @override
  Future<void> refreshCatalog() async {
    refreshCalls++;
    phase = SyncPhase.complete;
    notifyListeners();
  }

  @override
  Future<void> synchronize({Set<String>? onlyEntryIds}) async {
    synchronizeCalls++;
  }

  @override
  void cancel() => cancelCalls++;

  void changed() => notifyListeners();
}

void main() {
  void testHeader(String description, WidgetTesterCallback callback) {
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  Future<_HeaderController> fixture(WidgetTester tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('offline-header-'),
    ))!;
    final library = LibraryController(
      dataDirectory: directory,
      watchSource: false,
    );
    final sync = (await tester.runAsync(() async {
      await library.initialize();
      final store = await ReaderStateStore.open(
        statePath: '${directory.path}/reader.json',
      );
      final controller = _HeaderController(
        library: library,
        workspace: ReaderWorkspace(store),
      );
      await controller.initialize();
      return controller;
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      sync.workspace.dispose();
      library.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    });
    return sync;
  }

  Future<void> show(
    WidgetTester tester,
    _HeaderController sync, {
    double width = 1024,
    bool reduceMotion = false,
    bool isHome = true,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: OfflineLibraryScreen(controller: sync, isHome: isHome),
      ),
    );
    await tester.pump();
  }

  Finder header() => find.byType(AppBar);
  Finder refresh() => find.byKey(const ValueKey('offline-refresh-catalog'));
  Finder management() => find.byKey(const ValueKey('offline-sync-management'));
  Finder rotation() => find.byKey(const ValueKey('offline-sync-rotation'));

  testHeader(
    'compact signing expiry stays visible and opens its existing details',
    (tester) async {
      const channel = MethodChannel('score_reader/signing_expiry');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'status': 'known',
          'expirationMilliseconds': DateTime.now()
              .add(const Duration(days: 6, hours: 1))
              .millisecondsSinceEpoch,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final sync = await fixture(tester)
        ..pairedForTest = true;
      await show(tester, sync, width: 375);
      await tester.pump();
      expect(find.text('6天'), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      await tester.tap(find.byTooltip('查看签名到期时间与续签方式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('签名到期时间'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testHeader(
    'idle header refreshes only the catalog once and has one set list entry',
    (tester) async {
      final sync = await fixture(tester)
        ..pairedForTest = true;
      await show(tester, sync);
      expect(find.text('更新目录'), findsOneWidget);
      expect(find.text('同步管理'), findsOneWidget);
      expect(find.byTooltip('曲单'), findsOneWidget);
      expect(
        find.descendant(
          of: header(),
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );
      expect(find.byTooltip('更多'), findsNothing);
      expect(tester.widget<AppBar>(header()).bottom, isNull);
      await tester.tap(refresh());
      await tester.pump();
      expect(sync.refreshCalls, 1);
      expect(sync.synchronizeCalls, 0);
      expect(sync.cancelCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testHeader(
    'unpaired connection opens management without auto scanning or synchronizing',
    (tester) async {
      final sync = await fixture(tester);
      await show(tester, sync, width: 320);
      expect(find.text('连接电脑'), findsOneWidget);
      expect(refresh(), findsNothing);
      await tester.tap(management());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final screen = tester.widget<SyncScreen>(find.byType(SyncScreen));
      expect(screen.scanOnOpen, isFalse);
      expect(screen.syncOnOpen, isFalse);
      expect(sync.synchronizeCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testHeader(
    'active header rotates one status with real progress and tapping only opens management',
    (tester) async {
      final sync = await fixture(tester)
        ..pairedForTest = true
        ..busy = true
        ..phase = SyncPhase.transferring
        ..processedObjects = 4
        ..totalObjects = 10;
      await show(tester, sync, width: 375);
      expect(find.text('下载中 4/10'), findsOneWidget);
      expect(refresh(), findsNothing);
      expect(
        find.descendant(of: header(), matching: find.byIcon(Icons.refresh)),
        findsNothing,
      );
      expect(rotation(), findsOneWidget);
      final turns = tester.widget<RotationTransition>(rotation()).turns;
      final before = turns.value;
      await tester.pump(const Duration(milliseconds: 300));
      expect(turns.value, isNot(before));
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(management(), findsOneWidget);
      expect(find.text('下载中 4/10'), findsOneWidget);
      await tester.tap(management());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SyncScreen), findsOneWidget);
      expect(sync.refreshCalls, 0);
      expect(sync.synchronizeCalls, 0);
      expect(sync.cancelCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testHeader(
    'restored background queue shows pending count and reduced motion keeps status still',
    (tester) async {
      final sync = await fixture(tester)
        ..pairedForTest = true
        ..backgroundPendingObjects = 7;
      await show(tester, sync, reduceMotion: true);
      expect(find.text('后台下载中 · 余 7 份'), findsOneWidget);
      expect(refresh(), findsNothing);
      final turns = tester.widget<RotationTransition>(rotation()).turns;
      final before = turns.value;
      await tester.pump(const Duration(seconds: 1));
      expect(turns.value, before);
      sync.backgroundImporting = true;
      sync.changed();
      await tester.pump();
      expect(find.text('正在保存下载内容'), findsOneWidget);
      sync.backgroundImporting = false;
      sync.backgroundPendingObjects = 0;
      sync.changed();
      await tester.pump();
      expect(rotation(), findsNothing);
      expect(refresh(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testHeader(
    'header fits phone and iPad split widths without an extra toolbar row',
    (tester) async {
      final sync = await fixture(tester)
        ..pairedForTest = true;
      for (final width in [320.0, 375.0, 600.0, 744.0, 1024.0]) {
        for (final home in [true, false]) {
          await show(tester, sync, width: width, isHome: home);
          expect(
            tester.takeException(),
            isNull,
            reason: 'idle width=$width home=$home',
          );
          expect(tester.widget<AppBar>(header()).bottom, isNull);
          expect(find.byTooltip('曲单'), findsOneWidget);
          sync.busy = true;
          sync.phase = SyncPhase.transferring;
          sync.totalObjects = 100;
          sync.processedObjects = 24;
          sync.changed();
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: 'busy width=$width home=$home',
          );
          sync.busy = false;
          sync.changed();
          await tester.pump();
        }
      }
      await show(tester, sync, width: 320, textScale: 2);
      expect(tester.takeException(), isNull);
    },
  );
}
