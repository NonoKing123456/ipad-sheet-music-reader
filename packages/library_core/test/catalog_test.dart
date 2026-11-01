import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late Directory source;
  late String statePath;

  Future<File> fixture(String relative, String content) async {
    final file = File(p.joinAll([source.path, ...relative.split('/')]));
    await file.parent.create(recursive: true);
    return file.writeAsString(content, flush: true);
  }

  Future<LibraryCatalog> catalog({
    FileAccessProbe? fileAccessProbe,
    FileIdentityResolver? fileIdentityResolver,
  }) =>
      LibraryCatalog.open(
        rootPath: source.path,
        statePath: statePath,
        fileAccessProbe: fileAccessProbe,
        fileIdentityResolver: fileIdentityResolver,
      );

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('library-core-test-');
    source = await Directory(p.join(workspace.path, '演出谱合集')).create();
    statePath = p.join(workspace.path, 'state', 'library.json');
  });

  tearDown(() async {
    // Only the freshly-created, dedicated test workspace is removed.
    await workspace.delete(recursive: true);
  });

  test('indexes supported formats, empty folders and ancestor-path search',
      () async {
    await fixture('小提琴/老师整理/巴赫.PDF', 'pdf-one');
    await fixture('钢琴/巴赫.pdf', 'pdf-two');
    await fixture('图片/封面.JPG', 'jpeg');
    await fixture('图片/手稿.png', 'png');
    await fixture('图片/演出.webp', 'webp');
    await fixture('图片/照片.jpeg', 'jpeg-two');
    await fixture('说明.txt', 'ignored');
    await Directory(p.join(source.path, '空文件夹')).create();
    final library = await catalog();
    final result = await library.rescan();

    expect(result.snapshot.availableEntries, hasLength(6));
    expect(result.issues, isEmpty);
    expect(library.search('老师 巴赫').single.relativePath, '小提琴/老师整理/巴赫.PDF');
    expect(library.search('巴赫'), hasLength(2));
    expect(library.search('巴赫', withinFolder: '钢琴').single.relativePath,
        '钢琴/巴赫.pdf');
    expect(library.search('演出谱合集'), hasLength(6));
    expect(library.listFolder().folders, contains('空文件夹'));
    expect(library.listFolder('小提琴').folders, ['小提琴/老师整理']);
    expect(library.listFolder('小提琴/老师整理').entries, hasLength(1));
  });

  test(
      'unique external rename and later cross-folder move keep entry and revision',
      () async {
    final file = await fixture('原名.pdf', 'unique-score');
    final library = await catalog();
    await library.rescan();
    final initial = library.snapshot.availableEntries.single;
    final renamed = await file.rename(p.join(source.path, '新名.pdf'));
    final renameResult = await library.rescan();

    expect(renameResult.inferredMoves.single.entryId, initial.id);
    expect(renameResult.inferredMoves.single.evidence, 'uniqueContentHash');
    expect(library.snapshot.availableEntries.single.currentRevisionId,
        initial.currentRevisionId);

    await Directory(p.join(source.path, '分类')).create();
    await renamed.rename(p.join(source.path, '分类', '新名.pdf'));
    // Reopen first to simulate movement while the application is closed.
    final reopened = await catalog();
    final moved = await reopened.rescan();
    expect(moved.inferredMoves.single.entryId, initial.id);
    expect(reopened.snapshot.availableEntries.single.relativePath, '分类/新名.pdf');
    expect(reopened.snapshot.entries, hasLength(1));
  });

  test('copying equal content creates independent entries', () async {
    final first = await fixture('来源A/同名.pdf', 'same-bytes');
    final library = await catalog();
    await library.rescan();
    final originalId = library.snapshot.availableEntries.single.id;
    final duplicate = File(p.join(source.path, '来源B', '同名.pdf'));
    await duplicate.parent.create();
    await first.copy(duplicate.path);
    final result = await library.rescan();

    expect(result.addedEntryIds, hasLength(1));
    expect(result.inferredMoves, isEmpty);
    expect(library.snapshot.availableEntries.map((entry) => entry.id).toSet(),
        hasLength(2));
    expect(library.snapshot.entryById(originalId)!.relativePath, '来源A/同名.pdf');
  });

  test(
      'duplicate-content move remains explicit ambiguity, never silently merged',
      () async {
    final first = await fixture('A.pdf', 'same-bytes');
    await fixture('B.pdf', 'same-bytes');
    final library = await catalog();
    await library.rescan();
    final old = library.search('A.pdf').single;
    await first.rename(p.join(source.path, 'C.pdf'));
    final result = await library.rescan();

    expect(result.inferredMoves, isEmpty);
    expect(result.ambiguities.single.missingEntryIds, [old.id]);
    expect(result.ambiguities.single.newEntryIds, hasLength(1));
    expect(library.snapshot.entryById(old.id)!.status, EntryStatus.missing);
    expect(library.search('C.pdf').single.id, isNot(old.id));
    expect(library.snapshot.entries, hasLength(3));
  });

  test('same-path replacement preserves prior revision metadata', () async {
    final file = await fixture('曲谱.pdf', 'original-score');
    final library = await catalog();
    await library.rescan();
    final old = library.snapshot.availableEntries.single;
    await file.writeAsString('a new score with different pages', flush: true);
    final result = await library.rescan();
    final current = library.snapshot.availableEntries.single;

    expect(current.id, old.id);
    expect(current.currentRevisionId, isNot(old.currentRevisionId));
    expect(current.revisions.map((revision) => revision.id),
        contains(old.currentRevisionId));
    expect(result.modifiedEntryIds, [old.id]);
    expect(await file.readAsString(), 'a new score with different pages');
  });

  test(
      'unchanged metadata uses cache; explicit verification detects hidden change',
      () async {
    final file = await fixture('曲谱.pdf', 'AAAA');
    final library = await catalog();
    await library.rescan();
    final old = library.snapshot.availableEntries.single;
    final oldTime = (await file.stat()).modified;
    await file.writeAsString('BBBB', flush: true);
    await file.setLastModified(oldTime);

    final cached = await library.rescan();
    expect(cached.modifiedEntryIds, isEmpty);
    expect(library.snapshot.availableEntries.single.currentRevisionId,
        old.currentRevisionId);
    final verified = await library.rescan(verifyAll: true);
    expect(verified.modifiedEntryIds, [old.id]);
    expect(library.snapshot.availableEntries.single.currentRevisionId,
        isNot(old.currentRevisionId));
  });

  test('deletion retains missing entry and identical reappearance restores it',
      () async {
    final file = await fixture('曲谱.pdf', 'retained');
    final library = await catalog();
    await library.rescan();
    final original = library.snapshot.availableEntries.single;
    await file.delete();
    final removed = await library.rescan();
    expect(removed.missingEntryIds, [original.id]);
    expect(library.snapshot.entries.single.status, EntryStatus.missing);
    expect(library.search('曲谱'), isEmpty);

    await fixture('曲谱.pdf', 'retained');
    final restored = await library.rescan();
    expect(restored.restoredEntryIds, [original.id]);
    expect(library.snapshot.availableEntries.single.currentRevisionId,
        original.currentRevisionId);
  });

  test('unavailable root preserves prior entries and folders', () async {
    await fixture('保留目录/曲谱.pdf', 'retained');
    final library = await catalog();
    await library.rescan();
    final id = library.snapshot.availableEntries.single.id;
    final movedRoot = await source.rename(p.join(workspace.path, '暂时断开的根目录'));
    final result = await library.rescan();

    expect(result.hasIncompleteAreas, isTrue);
    expect(result.issues.single.stage, ScanIssueStage.enumeration);
    expect(result.missingEntryIds, isEmpty);
    expect(library.snapshot.entryById(id)!.status, EntryStatus.available);
    expect(library.snapshot.folders, contains('保留目录'));
    await movedRoot.rename(source.path);
  });

  test(
      'deferred content is indexed without reading and later hash enrichment is stable',
      () async {
    await fixture('离线.webp', 'placeholder-test');
    var deferred = true;
    final library = await catalog(
      fileAccessProbe: (_, __) async =>
          deferred ? FileAccess.deferred : FileAccess.ordinary,
    );
    final first = await library.rescan(verifyAll: true);
    final entry = library.snapshot.availableEntries.single;
    expect(entry.availability, ContentAvailability.deferred);
    expect(entry.currentRevision.contentHash, isNull);
    expect(first.issues.single.stage, ScanIssueStage.deferred);

    deferred = false;
    await library.rescan();
    final current = library.snapshot.availableEntries.single;
    expect(current.id, entry.id);
    expect(current.currentRevisionId, entry.currentRevisionId);
    expect(current.currentRevision.contentHash, isNotNull);
    expect(current.availability, ContentAvailability.ready);
  });

  test(
      'content access failure is separate from disappearance and preserves revision',
      () async {
    await fixture('曲谱.pdf', 'content');
    var fail = false;
    final library = await catalog(fileAccessProbe: (_, __) async {
      if (fail) throw const FileSystemException('simulated content denial');
      return FileAccess.ordinary;
    });
    await library.rescan();
    final old = library.snapshot.availableEntries.single;
    fail = true;
    final result = await library.rescan(verifyAll: true);
    final current = library.snapshot.availableEntries.single;

    expect(result.missingEntryIds, isEmpty);
    expect(result.issues.single.stage, ScanIssueStage.content);
    expect(current.availability, ContentAvailability.unreadable);
    expect(current.id, old.id);
    expect(current.currentRevisionId, old.currentRevisionId);
  });

  test('injected OS identity can disambiguate equal-content moves', () async {
    final first = await fixture('A.pdf', 'equal');
    await fixture('B.pdf', 'equal');
    final library = await catalog(
        fileIdentityResolver: (path, _) async =>
            p.basename(path) == 'B.pdf' ? 'file-B' : 'file-A');
    await library.rescan();
    final original = library.search('A.pdf').single;
    await first.rename(p.join(source.path, 'C.pdf'));
    final result = await library.rescan();

    expect(result.inferredMoves.single.entryId, original.id);
    expect(result.inferredMoves.single.evidence, 'platformFileId');
    expect(result.ambiguities, isEmpty);
    expect(library.search('C.pdf').single.id, original.id);
  });

  test('state is persisted outside source and reopens with stable IDs',
      () async {
    await fixture('曲谱.pdf', 'score');
    final library = await catalog();
    await library.rescan();
    final before = library.snapshot.availableEntries.single;
    final reopened = await catalog();

    expect(reopened.snapshot.availableEntries.single.id, before.id);
    expect(reopened.snapshot.availableEntries.single.currentRevisionId,
        before.currentRevisionId);
    expect(await source.list(recursive: true).length, 1);
    expect(await File(statePath).exists(), isTrue);
  });

  test('rejects state in source before creating state directories', () async {
    final forbidden = p.join(source.path, 'internal', 'state.json');
    await expectLater(
      LibraryCatalog.open(rootPath: source.path, statePath: forbidden),
      throwsArgumentError,
    );
    expect(await Directory(p.join(source.path, 'internal')).exists(), isFalse);
  });

  test('rejects root path as the state path', () async {
    await expectLater(
      LibraryCatalog.open(rootPath: source.path, statePath: source.path),
      throwsArgumentError,
    );
  });

  test('corrupt primary restores valid backup with an explicit warning',
      () async {
    await fixture('原谱.pdf', 'score');
    final library = await catalog();
    await library.rescan();
    final original = library.snapshot.availableEntries.single;
    await fixture('新谱.png', 'png');
    await library.rescan();
    await File(statePath).writeAsString('{broken');

    final recovered = await catalog();
    expect(recovered.storageWarnings, isNotEmpty);
    expect(recovered.snapshot.entryById(original.id), isNotNull);
    await recovered.rescan();
    expect(recovered.snapshot.availableEntries, hasLength(2));
    expect((await catalog()).snapshot.availableEntries, hasLength(2));
  });

  test(
      'corrupt primary with no valid backup fails instead of clearing catalogue',
      () async {
    await fixture('曲谱.pdf', 'score');
    final library = await catalog();
    await library.rescan();
    await File(statePath).writeAsString('{broken');
    await expectLater(catalog(), throwsA(isA<CatalogStorageException>()));
  });

  test('stale writers must reload before saving a new generation', () async {
    await fixture('曲谱.pdf', 'score');
    final first = await catalog();
    final stale = await catalog();
    await first.rescan();
    await expectLater(
        stale.rescan(), throwsA(isA<ConcurrentCatalogWriteException>()));
    await stale.reload();
    await stale.rescan();
    expect(stale.snapshot.generation, 2);
  });

  test('same-process concurrent catalogue operations are rejected', () async {
    await fixture('曲谱.pdf', 'score');
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = await catalog(fileAccessProbe: (_, __) async {
      entered.complete();
      await release.future;
      return FileAccess.ordinary;
    });
    final second = await catalog();
    final running = first.rescan();
    await entered.future;
    try {
      await expectLater(
          second.rescan(), throwsA(isA<ConcurrentCatalogWriteException>()));
    } finally {
      release.complete();
      await running;
    }
  });

  test('another process holding the state lock blocks writes', () async {
    await fixture('曲谱.pdf', 'score');
    final library = await catalog();
    final worker = await Process.start(Platform.resolvedExecutable, [
      'run',
      p.join('test', 'support', 'hold_lock.dart'),
      '$statePath.lock',
    ]);
    final output =
        worker.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final errors = worker.stderr.transform(utf8.decoder).join();
    try {
      expect(await output.first.timeout(const Duration(seconds: 20)), 'locked');
      await expectLater(
          library.rescan(), throwsA(isA<ConcurrentCatalogWriteException>()));
    } finally {
      worker.stdin.writeln('release');
      await worker.stdin.close();
      final exit = await worker.exitCode.timeout(const Duration(seconds: 20),
          onTimeout: () {
        worker.kill();
        return -1;
      });
      expect(exit, 0, reason: await errors);
    }
  });

  test('scope traversal is rejected', () async {
    final library = await catalog();
    expect(() => library.search('x', withinFolder: '../elsewhere'),
        throwsArgumentError);
    expect(() => library.listFolder('/outside'), throwsArgumentError);
  });

  test(
      'portable paths preserve Chinese spaces and scopes respect path boundaries',
      () async {
    await fixture('a/中文 曲谱 (现场版) #1.pdf', 'one');
    await fixture('ab/中文 曲谱.pdf', 'two');
    await fixture('a/子目录/第二首.PNG', 'three');
    final library = await catalog();
    await library.rescan();

    final scoped = library.search('', withinFolder: 'a');
    expect(scoped, hasLength(2));
    expect(scoped.map((entry) => entry.relativePath),
        everyElement(startsWith('a/')));
    final named = library.search('现场版 #1').single;
    expect(named.relativePath, 'a/中文 曲谱 (现场版) #1.pdf');
    expect(named.relativePath, isNot(contains('\\')));
    expect(await File(library.absolutePathFor(named)).readAsString(), 'one');
    expect(library.search('', withinFolder: r'a\子目录').single.relativePath,
        'a/子目录/第二首.PNG');
    if (Platform.isWindows) {
      expect(library.listFolder('A').entries, hasLength(1));
      expect(library.search('', withinFolder: 'A'), hasLength(2));
    }
  });

  test('symbolic links are not traversed or mistaken for confirmed deletion',
      () async {
    await fixture('本地/曲谱.pdf', 'local');
    final library = await catalog();
    await library.rescan();
    final localFolder = Directory(p.join(source.path, '本地'));
    final relocated = await localFolder.rename(p.join(workspace.path, '链接目标'));
    try {
      await Link(localFolder.path).create(relocated.path);
    } on FileSystemException {
      await relocated.rename(localFolder.path);
      markTestSkipped('Creating symbolic links is unavailable on this host.');
      return;
    }
    final result = await library.rescan();
    expect(result.issues.any((issue) => issue.stage == ScanIssueStage.link),
        isTrue);
    expect(result.missingEntryIds, isEmpty);
    expect(library.snapshot.availableEntries, hasLength(1));
  });
}
