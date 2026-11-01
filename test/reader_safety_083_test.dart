import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_stage.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

class _RealLoopback extends HttpOverrides {}

void main() {
  test('failed path-only erasure blocks sync until retry saves it, then durable erase reaches peer', () async {
    final beforeHttp = HttpOverrides.current;
    HttpOverrides.global = _RealLoopback();
    final dir = await Directory.systemTemp.createTemp('pending-path-sync-083-');
    final controllers = <SyncController>[];
    Future<SyncController> make(String name) async {
      final data = Directory('${dir.path}/$name');
      final library = LibraryController(
        dataDirectory: data,
        watchSource: false,
      );
      await library.initialize();
      final store = await ReaderStateStore.open(
        statePath: '${data.path}/reader-store/state.json',
      );
      final sync = SyncController(
        library: library,
        workspace: ReaderWorkspace(store),
        bindAddress: InternetAddress.loopbackIPv4,
        ioTimeout: const Duration(seconds: 2),
      );
      controllers.add(sync);
      await sync.initialize();
      return sync;
    }

    try {
      final source = await Directory('${dir.path}/scores').create();
      await File('${source.path}/synthetic.PNG').writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
        ),
      );
      final computer = await make('computer'), reader = await make('reader');
      await computer.library.selectRoot(source.path);
      await computer.startServer();
      expect(computer.serving, isTrue);
      await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      final entry = reader.offlineSnapshot!.availableEntries.single;
      final page = PageKey(
        entryId: entry.id,
        revisionId: entry.currentRevisionId,
        pageNumber: 1,
      );
      final stroke = await reader.workspace.store.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff000000,
          widthFraction: .01,
        ),
        points: [NormalizedPoint(.2, .3)],
      );
      await reader.synchronize();
      expect(computer.workspace.store.snapshot.strokesFor(page), hasLength(1));
      final stateDirectory = Directory(
        p.dirname(reader.workspace.store.statePath),
      );
      expect(p.isWithin(dir.path, stateDirectory.path), isTrue);
      final parked = await stateDirectory.rename('${stateDirectory.path}.held');
      await File(stateDirectory.path).writeAsString('synthetic write failure');
      await reader.workspace.replacePaths(page, {stroke.id: []});
      expect(reader.workspace.pending, isEmpty);
      expect(reader.workspace.pendingPaths, hasLength(1));
      expect(reader.workspace.unsavedCount, 1);
      expect(reader.workspace.saving, isFalse);
      expect(reader.hasUnsavedEdits, isTrue);
      final remoteGeneration = computer.workspace.store.snapshot.generation;
      await reader.synchronize();
      expect(reader.message, contains('没有开始同步'));
      expect(computer.workspace.store.snapshot.generation, remoteGeneration);
      expect(computer.workspace.store.snapshot.strokesFor(page), hasLength(1));
      await File(stateDirectory.path).delete();
      await parked.rename(stateDirectory.path);
      await reader.workspace.retryStrokes();
      expect(reader.hasUnsavedEdits, isFalse);
      expect(reader.workspace.pendingPaths, isEmpty);
      await reader.synchronize();
      expect(reader.phase, SyncPhase.complete);
      expect(reader.workspace.store.snapshot.strokesFor(page), isEmpty);
      expect(computer.workspace.store.snapshot.strokesFor(page), isEmpty);
      debugPrint(
        'PENDING_ERASE_SYNC_083 pendingPaths_only_blocks=true no_peer_mutation_before_retry=true durable_retry_then_sync=true',
      );
    } finally {
      for (final sync in controllers.reversed) {
        await sync.stopServer();
        sync.dispose();
        sync.workspace.dispose();
        sync.library.dispose();
      }
      await dir.delete(recursive: true);
      HttpOverrides.global = beforeHttp;
    }
  });

  testWidgets(
    'reader wake tokens follow visible opaque routes and lifecycle; popups preserve ownership and old disposal cannot release new reader',
    (tester) async {
      const channel = MethodChannel('score_reader/reader_activity');
      final owners = <String>{};
      final calls = <Map<Object?, Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'setReaderActive');
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        calls.add(args);
        final token = args['token']! as String;
        if (args['active'] == true) {
          owners.add(token);
        } else {
          owners.remove(token);
        }
        return null;
      });
      final navigator = GlobalKey<NavigatorState>();
      Widget reader(String name) => ReaderStage(
        hasReadablePage: true,
        top: const SizedBox.shrink(),
        bottom: const SizedBox.shrink(),
        contentBuilder: (_) => Center(child: Text(name)),
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [readerRouteVisibility],
            home: const Scaffold(body: Text('library')),
          ),
        );
        expect(owners, isEmpty);
        final a = MaterialPageRoute<void>(builder: (_) => reader('reader A'));
        navigator.currentState!.push(a);
        await tester.pumpAndSettle();
        expect(owners, hasLength(1));
        final tokenA = owners.single;
        showDialog<void>(
          context: tester.element(find.text('reader A')),
          builder: (_) => const AlertDialog(content: Text('local color popup')),
        );
        await tester.pumpAndSettle();
        expect(owners, {tokenA});
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(owners, {tokenA});
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('other page')),
          ),
        );
        await tester.pumpAndSettle();
        expect(owners, isEmpty);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(owners, {tokenA});
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(owners, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(owners, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(owners, {tokenA});
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => reader('reader B')),
        );
        await tester.pumpAndSettle();
        expect(owners, hasLength(1));
        expect(owners.single, isNot(tokenA));
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(owners, {tokenA});
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => reader('reader C')),
        );
        await tester.pumpAndSettle();
        final tokenC = owners.single;
        navigator.currentState!.removeRoute(a);
        await tester.pumpAndSettle();
        expect(owners, {tokenC});
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(owners, isEmpty);
        expect(
          calls
              .where((args) => args['active'] == true)
              .map((args) => args['token'])
              .toSet(),
          hasLength(3),
        );
        expect(tester.takeException(), isNull);
        debugPrint(
          'READER_WAKE_083 opaque_cover_releases=true popup_keeps_awake=true background_releases=true resumed_visible_reacquires=true old_dispose_preserves_new_token=true back_to_library_empty=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
