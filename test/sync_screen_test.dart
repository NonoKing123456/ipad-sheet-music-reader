import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/library/library_screen.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';
import 'package:score_reader/sync/qr_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets(
    'iPad home exposes connection and offline entry without directory picker',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('sync-screen-'),
      ))!;
      final library = LibraryController(
        dataDirectory: directory,
        watchSource: false,
      );
      await tester.runAsync(library.initialize);
      final workspace = (await tester.runAsync(() async {
        final store = await ReaderStateStore.open(
          statePath: p.join(directory.path, 'reader-state.json'),
        );
        return ReaderWorkspace(store);
      }))!;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryScreen(
              controller: library,
              readerWorkspace: workspace,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('把整个谱库带在身边'), findsNothing);
      expect(find.text('搜索离线曲名或文件夹'), findsOneWidget);
      expect(find.byTooltip('选择谱库文件夹'), findsNothing);
      expect(find.text('打开离线谱库'), findsNothing);
      var scans = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        QrScanner.channel,
        (call) async {
          expect(call.method, 'scan');
          scans++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          QrScanner.channel,
          null,
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('扫描电脑二维码'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(find.byType(SyncScreen), findsOneWidget);
      expect(find.text('开启局域网服务'), findsNothing);
      expect(scans, 1);
      expect(find.text('电脑地址与端口'), findsNothing);
      expect(find.text('8位临时配对码'), findsNothing);
      await tester.tap(find.text('高级诊断（通常不需要）'));
      await tester.pumpAndSettle();
      expect(find.text('电脑地址与端口'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      library.dispose();
      workspace.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );

  testWidgets(
    'computer connection button starts listener and hides technical details',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('computer-connect-'),
      ))!;
      final controller = (await tester.runAsync(() async {
        final root = Directory(p.join(directory.path, 'source'));
        await root.create();
        await File(p.join(root.path, 'piece.png')).writeAsString('synthetic');
        final library = LibraryController(
          dataDirectory: Directory(p.join(directory.path, 'data')),
          watchSource: false,
        );
        await library.initialize();
        await library.selectRoot(root.path);
        final workspace = ReaderWorkspace(
          await ReaderStateStore.open(
            statePath: p.join(directory.path, 'reader.json'),
          ),
        );
        final sync = SyncController(
          library: library,
          workspace: workspace,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await sync.initialize();
        return sync;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncScreen(controller: controller, openOffline: () {}),
        ),
      );
      expect(find.text('显示连接二维码'), findsOneWidget);
      expect(find.text('电脑地址与端口'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('显示连接二维码'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(controller.serving, isTrue);
      expect(controller.autoStartServer, isTrue);
      expect(find.text('更新二维码'), findsOneWidget);
      if (controller.pairingQr != null) {
        expect(find.byType(QrImageView), findsOneWidget);
      }
      expect(find.text('8位临时配对码'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      await tester.runAsync(controller.stopServer);
      controller.dispose();
      controller.library.dispose();
      controller.workspace.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );

  testWidgets(
    'conflicts show both readable names and complete optional variants at narrow width',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('conflict-screen-'),
      ))!;
      final library = LibraryController(
        dataDirectory: directory,
        watchSource: false,
      );
      final controller = (await tester.runAsync(() async {
        await library.initialize();
        final store = await ReaderStateStore.open(
          statePath: p.join(directory.path, 'reader-state.json'),
        );
        final list = await store.createSetList('Original');
        final base = store.snapshot;
        final remoteJson =
            jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>;
        final setLists = remoteJson['setLists'] as List;
        (setLists.single as Map)['name'] = 'iPad version';
        await store.renameSetList(list.id, 'Windows version');
        await store.mergeFromPeer(
          base: base,
          remote: ReaderSnapshot.fromJson(remoteJson),
          peerId: 'test-peer',
        );
        final sync = SyncController(
          library: library,
          workspace: ReaderWorkspace(store),
        );
        await sync.initialize();
        return sync;
      }))!;
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: SyncConflictsScreen(controller: controller)),
      );
      expect(find.textContaining('版本一：'), findsOneWidget);
      expect(find.textContaining('版本二：'), findsOneWidget);
      expect(find.textContaining('Windows version'), findsWidgets);
      expect(find.textContaining('iPad version'), findsWidgets);
      await tester.tap(find.text('原始版本详情'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      controller.workspace.dispose();
      library.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}
