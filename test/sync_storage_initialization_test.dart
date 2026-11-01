import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

Future<SyncController> open(Directory data) async {
  final library = LibraryController(dataDirectory: data, watchSource: false);
  await library.initialize();
  final workspace = ReaderWorkspace(
    await ReaderStateStore.open(
      statePath: p.join(data.path, 'reader-state.json'),
    ),
  );
  final sync = SyncController(library: library, workspace: workspace);
  await sync.initialize();
  return sync;
}

void close(SyncController sync) {
  sync.dispose();
  sync.workspace.dispose();
  sync.library.dispose();
}

void main() {
  test('trusted app root initializes and reopens without replacing saved settings or reader state', () async {
    final temp = await Directory.systemTemp.createTemp('storage-init-');
    try {
      final first = await open(temp);
      expect(first.initializationError, isNull);
      expect(
        first.directory.path,
        p.join(await temp.resolveSymbolicLinks(), 'sync'),
      );
      await first.workspace.store.createSetList('preserved');
      final settings = File(p.join(first.directory.path, 'settings.json'));
      final original = jsonEncode({
        'version': 1,
        'roots': {
          'unchanged-root': {'id': 'a' * 32, 'port': 50001},
        },
        'autoStartServer': false,
      });
      await settings.writeAsString(original);
      close(first);
      final reopened = await open(temp);
      expect(reopened.initializationError, isNull);
      expect(reopened.replica, isNotNull);
      expect(
        reopened.workspace.store.snapshot.setLists.single.name,
        'preserved',
      );
      expect(await settings.readAsString(), original);
      close(reopened);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('controller accepts a trusted ancestor alias and continues using the same files', () async {
    final configured = Platform.environment['SCORE_STORAGE_ALIAS_FIXTURE'];
    if (configured == null) {
      markTestSkipped(
        'Provide a synthetic directory alias fixture; Windows link permissions are not assumed. CI requires native alias smoke.',
      );
      return;
    }
    final base = Directory(configured);
    final alias = await base.createTemp('controller-alias-');
    try {
      final sync = await open(alias);
      expect(sync.initializationError, isNull);
      expect(sync.replica, isNotNull);
      expect(
        sync.directory.path,
        p.join(await alias.resolveSymbolicLinks(), 'sync'),
      );
      final sentinel = File(p.join(alias.path, 'sync', 'same-location'));
      await sentinel.writeAsString('preserved');
      expect(
        await File(p.join(sync.directory.path, 'same-location')).readAsString(),
        'preserved',
      );
      close(sync);
      final reopened = await open(alias);
      expect(reopened.initializationError, isNull);
      expect(await sentinel.readAsString(), 'preserved');
      close(reopened);
    } finally {
      final target = await alias.resolveSymbolicLinks();
      expect(p.dirname(target), await base.resolveSymbolicLinks());
      await Directory(target).delete(recursive: true);
    }
  });

  test('malformed offline metadata stays in place and reports a path-free diagnostic', () async {
    final temp = await Directory.systemTemp.createTemp('storage-diagnostic-');
    try {
      final replica = Directory(p.join(temp.path, 'sync', 'replica'));
      await replica.create(recursive: true);
      final manifest = File(p.join(replica.path, 'manifest.json'));
      await manifest.writeAsString('{"schema":999}');
      final sync = await open(temp);
      expect(sync.initializationError, contains('SYNC-REPLICA-FORMAT'));
      expect(sync.initializationError, isNot(contains(temp.path)));
      expect(await manifest.readAsString(), '{"schema":999}');
      close(sync);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
