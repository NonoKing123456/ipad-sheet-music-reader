import 'dart:io';

import 'package:library_core/library_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root, source;
  late String state;
  late LibraryCatalog host;
  late Map<String, String> selected;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-bulk-test-');
    source = await Directory('${root.path}/source').create();
    state = '${root.path}/state/catalog.json';
    for (var i = 0; i < 4; i++) {
      await File('${source.path}/$i.pdf').writeAsString('synthetic-$i');
    }
    host = await LibraryCatalog.open(rootPath: source.path, statePath: state);
    await host.rescan(metadataOnly: true);
    selected = {
      for (final e in host.snapshot.availableEntries.take(3))
        e.id: e.currentRevisionId
    };
  });
  tearDown(() => root.delete(recursive: true));

  test(
      'one worker load/commit hashes only selections, preserves immutable siblings and ready needs no write',
      () async {
    final before = host.snapshot;
    final sibling = before.availableEntries.last;
    final worker =
        await LibraryCatalog.open(rootPath: source.path, statePath: state);
    final patch =
        await worker.materializeManyForPublication(selected, host.publication);
    expect(worker.catalogReads, 1);
    expect(worker.catalogWrites, 1);
    expect(worker.contentHashOperations, 3);
    expect(patch.failures, isEmpty);
    expect(await host.applyBatchMaterialization(patch), isTrue);
    expect(host.snapshot.generation, before.generation + 1);
    expect(identical(host.snapshot.entryById(sibling.id), sibling), isTrue);
    for (final id in selected.keys) {
      expect(before.entryById(id)!.currentRevision.contentHash, isNull);
      expect(host.snapshot.entryById(id)!.currentRevisionId, selected[id]);
      expect((await host.readyIfUnchanged(id))!.currentRevision.contentHash,
          isNotNull);
    }
    final bytes = await File(state).readAsBytes();
    final readyWorker =
        await LibraryCatalog.open(rootPath: source.path, statePath: state);
    final ready = await readyWorker.materializeManyForPublication(
        selected, host.publication);
    expect(readyWorker.contentHashOperations, 0);
    expect(readyWorker.catalogWrites, 0);
    expect(await host.applyBatchMaterialization(ready), isTrue);
    expect(await File(state).readAsBytes(), bytes);
  });

  test(
      'bad selected file is isolated; successful revisions persist and later external commits reject stale patches',
      () async {
    final entries = host.snapshot.availableEntries;
    await File('${source.path}/${entries.first.relativePath}').delete();
    final worker =
        await LibraryCatalog.open(rootPath: source.path, statePath: state);
    final patch =
        await worker.materializeManyForPublication(selected, host.publication);
    expect(patch.entries, hasLength(2));
    expect(patch.failures.keys, [entries.first.id]);
    final reread =
        await LibraryCatalog.open(rootPath: source.path, statePath: state);
    expect(
        reread.snapshot.entryById(entries[1].id)!.currentRevision.contentHash,
        isNotNull);
    expect(reread.snapshot.entryById(entries.first.id)!.currentRevisionId,
        selected[entries.first.id]);
    final oldPatch = await reread.materializeManyForPublication(
        {entries[1].id: entries[1].currentRevisionId}, reread.publication);
    final newer =
        await LibraryCatalog.open(rootPath: source.path, statePath: state);
    await newer.materialize(entries.last.id);
    expect(await reread.applyBatchMaterialization(oldPatch), isFalse);
    expect(await host.applyBatchMaterialization(patch), isFalse);
  });

  test(
      'wrong revision and >64 request are rejected without hashing unrelated files',
      () async {
    final patch = await host.materializeManyForPublication(
        {selected.keys.first: 'stale'}, host.publication);
    expect(patch.entries, isEmpty);
    expect(patch.failures, hasLength(1));
    expect(host.contentHashOperations, 0);
    expect(
        () => host.materializeManyForPublication(
            {for (var i = 0; i < 65; i++) '$i': 'r'}, host.publication),
        throwsArgumentError);
  });
}
