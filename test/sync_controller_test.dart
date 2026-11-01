import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

void main() {
  late Directory temporary;
  final controllers = <SyncController>[];
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('sync-ui-controller-');
  });
  tearDown(() async {
    for (final controller in controllers.reversed) {
      await controller.stopServer();
      controller.dispose();
      controller.library.dispose();
      controller.workspace.dispose();
    }
    controllers.clear();
    await temporary.delete(recursive: true);
  });
  Future<SyncController> make(String name, {String? root}) async {
    final directory = Directory(p.join(temporary.path, name));
    final library = LibraryController(
      dataDirectory: directory,
      watchSource: false,
    );
    await library.initialize();
    if (root != null) await library.selectRoot(root);
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(
        statePath: p.join(directory.path, 'reader-state.json'),
      ),
    );
    final sync = SyncController(
      library: library,
      workspace: workspace,
      bindAddress: InternetAddress.loopbackIPv4,
      ioTimeout: const Duration(seconds: 2),
    );
    controllers.add(sync);
    await sync.initialize();
    expect(sync.initializationError, isNull);
    return sync;
  }

  Future<String> source(String name, {String content = 'original'}) async {
    final file = File(
      p.join(temporary.path, 'scores', name, 'ancestor', 'piece.png'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return p.join(temporary.path, 'scores', name);
  }

  Future<void> connect(SyncController computer, SyncController reader) async {
    await computer.startServer();
    expect(computer.serving, isTrue);
    await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
    expect(reader.paired, isTrue);
    await reader.synchronize();
    expect(reader.phase, SyncPhase.complete, reason: reader.message);
    expect(reader.processedObjects, reader.totalObjects);
    expect(reader.totalObjects, isNotNull);
  }

  test('explicit service, stable root identity/port, latest scan and immutable offline reopen', () async {
    final root = await source('first');
    final computer = await make('computer', root: root);
    var reader = await make('reader');
    expect(computer.serving, isFalse);
    await connect(computer, reader);
    final identity = reader.replica!.manifest!.libraryId;
    final port = computer.port;
    final original = reader.replica!.snapshot.availableEntries.single;
    final target = reader.locateOffline(original.id)!;
    expect(target.verifiedImmutable, isTrue);
    expect(target.revisionId, original.currentRevisionId);
    expect(target.filePath, reader.replica!.absolutePathFor(original));
    final localHashReads = reader.replica!.verificationStats.localHashBytesRead;
    await reader.synchronize();
    expect(
      reader.replica!.verificationStats.localHashBytesRead,
      localHashReads,
    );
    final added = File(p.join(root, 'new.pdf'));
    await added.writeAsString('new PDF bytes');
    await computer.library.rescan();
    await reader.synchronize();
    expect(
      reader.replica!.snapshot.availableEntries,
      hasLength(2),
      reason:
          'running source must resolve the latest catalog after a worker scan',
    );
    await computer.stopServer();
    await computer.startServer();
    expect(computer.port, port);
    await reader.synchronize();
    expect(reader.replica!.manifest!.libraryId, identity);
    await computer.stopServer();
    reader.dispose();
    reader.library.dispose();
    reader.workspace.dispose();
    controllers.remove(reader);
    final reopened = await make('reader');
    reader = reopened;
    expect(reopened.paired, isTrue);
    expect(reopened.hasOfflineLibrary, isTrue);
    expect(reopened.replica!.search('ancestor'), hasLength(1));
    expect(reopened.replica!.verificationStats.localHashBytesRead, 0);
    expect(
      await File(reopened.locateOffline(original.id)!.filePath).readAsString(),
      'original',
    );
    final otherRoot = await source('second', content: 'other');
    await computer.library.selectRoot(otherRoot);
    await computer.startServer();
    await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
    await reader.synchronize();
    expect(reader.phase, SyncPhase.partial);
    expect(reader.message, contains('另一份谱库'));
    expect(
      reader.replica!.manifest!.libraryId,
      identity,
      reason:
          'different library must not replace the previous complete replica',
    );
    await computer.stopServer();
    await computer.library.selectRoot(root);
    await computer.startServer();
    expect(computer.port, port);
  });

  test('pending strokes block sync, two-way edits notify and conflicts retain full versions', () async {
    final computer = await make('computer', root: await source('first'));
    final reader = await make('reader');
    await connect(computer, reader);
    final entry = reader.replica!.snapshot.availableEntries.single;
    final page = PageKey(
      entryId: entry.id,
      revisionId: entry.currentRevisionId,
      pageNumber: 1,
    );
    final style = StrokeStyle(
      tool: AnnotationTool.pen,
      argb: 0xff112233,
      widthFraction: .004,
    );
    final original = await computer.workspace.store.addStroke(
      page,
      style: style,
      points: [NormalizedPoint(.2, .3)],
    );
    final list = await computer.workspace.store.createSetList('Original');
    await computer.workspace.store.addItem(list.id, entry.id);
    await reader.synchronize();
    expect(
      reader.workspace.store.snapshot.strokesFor(page).single.id,
      original.id,
    );
    var notifications = 0;
    reader.workspace.addListener(() => notifications++);
    await reader.workspace.store.addStroke(
      page,
      style: style,
      points: [NormalizedPoint(.4, .5)],
    );
    await computer.workspace.store.addStroke(
      page,
      style: style,
      points: [NormalizedPoint(.7, .8)],
    );
    await reader.workspace.store.renameSetList(list.id, 'iPad edit');
    await computer.workspace.store.renameSetList(list.id, 'Windows edit');
    await reader.synchronize();
    expect(reader.phase, SyncPhase.complete);
    expect(reader.workspace.store.snapshot.strokesFor(page), hasLength(3));
    expect(computer.workspace.store.snapshot.strokesFor(page), hasLength(3));
    expect(reader.workspace.store.snapshot.conflicts, isNotEmpty);
    expect(
      reader.workspace.store.snapshot.conflicts.any(
        (c) => {
          c.first['name'],
          c.second['name'],
        }.containsAll({'iPad edit', 'Windows edit'}),
      ),
      isTrue,
    );
    expect(notifications, greaterThan(0));
    final generation = reader.workspace.store.snapshot.generation;
    reader.workspace.pending.add(
      PendingStroke(page, style, [NormalizedPoint(.9, .1)]),
    );
    await reader.synchronize();
    expect(reader.message, contains('没有开始同步'));
    expect(reader.workspace.store.snapshot.generation, generation);
    await reader.workspace.retryStrokes();
    await reader.synchronize();
    expect(reader.workspace.store.snapshot.strokesFor(page), hasLength(4));
    expect(computer.workspace.store.snapshot.strokesFor(page), hasLength(4));
  });

  test('active cancel preserves last complete replica and retry reports real progress', () async {
    final root = await source('cancel');
    final computer = await make('computer', root: root);
    final reader = await make('reader');
    await connect(computer, reader);
    final original = reader.replica!.snapshot.availableEntries.single;
    await File(p.join(root, 'new.pdf')).writeAsString('new revision bytes');
    await computer.library.rescan();
    var didCancel = false;
    void cancelOnManifest() {
      if (!didCancel &&
          reader.phase == SyncPhase.transferring &&
          reader.totalObjects == 2) {
        didCancel = true;
        reader.cancel();
      }
    }

    reader.addListener(cancelOnManifest);
    await reader.synchronize();
    reader.removeListener(cancelOnManifest);
    expect(didCancel, isTrue);
    expect(reader.phase, SyncPhase.cancelled);
    expect(reader.replica!.snapshot.availableEntries.single.id, original.id);
    expect(reader.message, contains('上次完整离线库'));
    await reader.synchronize();
    expect(reader.phase, SyncPhase.complete);
    expect(reader.processedObjects, 2);
    expect(reader.totalObjects, 2);
    expect(reader.replica!.snapshot.availableEntries, hasLength(2));
  });

  test('damaged pairing credentials and settings do not block a complete offline library', () async {
    final computer = await make('computer', root: await source('first'));
    var reader = await make('reader');
    await connect(computer, reader);
    final entry = reader.replica!.snapshot.availableEntries.single;
    final settingsFile = File(p.join(reader.directory.path, 'settings.json'));
    final settings = jsonDecode(await settingsFile.readAsString()) as Map;
    final peerFile = File(
      p.join(
        reader.directory.path,
        'clients',
        settings['clientFolder'] as String,
        'client.json',
      ),
    );
    await peerFile.writeAsString('damaged');
    await File('${peerFile.path}.backup').writeAsString('damaged backup');
    final old = reader;
    old.dispose();
    old.library.dispose();
    old.workspace.dispose();
    controllers.remove(old);
    reader = await make('reader');
    expect(reader.paired, isFalse);
    expect(reader.hasOfflineLibrary, isTrue);
    expect(reader.message, contains('重新配对'));
    expect(
      await File(reader.locateOffline(entry.id)!.filePath).readAsString(),
      'original',
    );
    await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
    // Pairing code was single-use, so an explicit refreshed code is needed.
    computer.refreshCode();
    await reader.pair('127.0.0.1:${computer.port}', computer.pairingCode!);
    expect(reader.paired, isTrue);
    reader.dispose();
    reader.library.dispose();
    reader.workspace.dispose();
    controllers.remove(reader);
    await settingsFile.writeAsString('damaged settings');
    await File('${settingsFile.path}.bak').writeAsString('damaged backup');
    final library = LibraryController(
      dataDirectory: Directory(p.join(temporary.path, 'reader')),
      watchSource: false,
    );
    await library.initialize();
    final workspace = ReaderWorkspace(
      await ReaderStateStore.open(
        statePath: p.join(library.dataDirectory.path, 'reader-state.json'),
      ),
    );
    final recovered = SyncController(library: library, workspace: workspace);
    controllers.add(recovered);
    await recovered.initialize();
    expect(recovered.initializationError, isNotNull);
    expect(recovered.hasOfflineLibrary, isTrue);
    expect(recovered.locateOffline(entry.id), isNotNull);
  });

  test(
    'root switch closes old listener; invalid address and code are visible',
    () async {
      final first = await source('first');
      final second = await source('second');
      final computer = await make('computer', root: first);
      final reader = await make('reader');
      await computer.startServer();
      await computer.library.selectRoot(second);
      expect(computer.serving, isFalse);
      for (var i = 0; computer.serverBusy && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await computer.startServer();
      expect(computer.serving, isTrue);
      await reader.pair('0.0.0.0:5555', '12345678');
      expect(reader.phase, SyncPhase.failed);
      expect(reader.paired, isFalse);
      await reader.pair('127.0.0.1:${computer.port}', '1');
      expect(reader.message, contains('8位'));
      await reader.pair('127.0.0.1:${computer.port}', '00000000');
      expect(reader.message, contains('配对码'));
      expect(computer.addresses.every((uri) => uri.host != '0.0.0.0'), isTrue);
    },
  );

  test(
    'personal connection is remembered, restarts once, and can be disabled',
    () async {
      var computer = await make(
        'personal-computer',
        root: await source('personal'),
      );
      await computer.connectMyIpad();
      expect(computer.serving, isTrue);
      expect(computer.autoStartServer, isTrue);
      final port = computer.port;
      await computer.stopServer();
      computer.dispose();
      computer.library.dispose();
      computer.workspace.dispose();
      controllers.remove(computer);
      computer = await make('personal-computer');
      for (var i = 0; computer.serverBusy && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(computer.autoStartServer, isTrue);
      expect(computer.serving, isTrue);
      expect(computer.port, port);
      await computer.stopServer();
      await computer.library.rescan();
      expect(
        computer.serving,
        isFalse,
        reason: 'temporary stop must survive later library notifications',
      );
      await computer.setAutoStartServer(false);
      computer.dispose();
      computer.library.dispose();
      computer.workspace.dispose();
      controllers.remove(computer);
      computer = await make('personal-computer');
      expect(computer.autoStartServer, isFalse);
      expect(computer.serving, isFalse);
      final reader = await make('personal-reader');
      final accepted = await reader.pairFromQr(
        '{"app":"score-reader-pair","v":1}',
      );
      expect(accepted, isFalse);
      expect(reader.paired, isFalse);
    },
  );
}
