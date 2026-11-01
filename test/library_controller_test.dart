import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'package:score_reader/library/library_controller.dart';

Future<LibraryScanPacket> scan(String root, String state, bool verify) async {
  final watch = Stopwatch()..start();
  final catalog = await LibraryCatalog.open(rootPath: root, statePath: state);
  final result = await catalog.rescan(verifyAll: verify);
  return LibraryScanPacket(result, catalog.storageWarnings, watch.elapsed);
}

void main() {
  late Directory temporary;
  late Directory source;
  late Directory data;
  final controllers = <LibraryController>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'score-reader-controller-',
    );
    source = await Directory(p.join(temporary.path, '原始 曲谱')).create();
    data = Directory(p.join(temporary.path, 'application-data'));
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    final checked = p.normalize(p.absolute(temporary.path));
    if (!p.isWithin(
      p.normalize(p.absolute(Directory.systemTemp.path)),
      checked,
    )) {
      throw StateError('Refusing cleanup outside system temp.');
    }
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  LibraryController make({LibraryScanRunner? runner, bool watch = false}) {
    final controller = LibraryController(
      dataDirectory: data,
      scanRunner: runner,
      watchSource: watch,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> file(String relative, [String content = 'test content']) async {
    final target = File(p.join(source.path, relative));
    await target.parent.create(recursive: true);
    await target.writeAsString(content);
  }

  test(
    'worker scan, folders and path search use the shared catalogue',
    () async {
      await file('老师整理/巴赫/练习.pdf');
      await file('爵士/Autumn.PNG');
      await file('爵士/Leaf.webp');
      await file('爵士/notes.md');
      await Directory(p.join(source.path, '空文件夹')).create();
      final controller = make();
      await controller.initialize();
      await controller.selectRoot(source.path);
      expect(controller.error, isNull);
      expect(controller.totalCount, 3);
      expect(controller.folders, contains('空文件夹'));
      controller.setQuery('老师整理 练习');
      expect(controller.visibleEntries.single.relativePath, '老师整理/巴赫/练习.pdf');
      controller.setFolder('爵士');
      controller.setSearchScope(true);
      expect(controller.visibleEntries, isEmpty);
      controller.setQuery('');
      expect(controller.visibleEntries.length, 2);
      expect(p.isWithin(source.path, controller.statePath), isFalse);
      expect(
        await File(p.join(source.path, '爵士', 'notes.md')).readAsString(),
        'test content',
      );
    },
  );

  test(
    'selected folder is restored from application data on reopening',
    () async {
      await file('谱.pdf');
      final first = make(runner: scan);
      await first.initialize();
      await first.selectRoot(source.path);
      final id = first.snapshot!.availableEntries.single.id;
      final next = make(runner: scan);
      await next.initialize();
      expect(next.rootPath, source.path);
      expect(next.totalCount, 1);
      expect(next.snapshot!.availableEntries.single.id, id);
    },
  );

  test(
    'a late scan from an old folder cannot replace the new folder',
    () async {
      await file('旧谱.pdf');
      final other = await Directory(p.join(temporary.path, 'new-root'))
          .create();
      await File(p.join(other.path, 'new.pdf')).writeAsString('new');
      final gate = Completer<void>();
      final started = Completer<void>();
      final controller = make(
        runner: (root, state, verify) async {
          if (root == source.path) {
            started.complete();
            await gate.future;
          }
          return scan(root, state, verify);
        },
      );
      await controller.initialize();
      final oldRequest = controller.selectRoot(source.path);
      await started.future;
      await controller.selectRoot(other.path);
      gate.complete();
      await oldRequest;
      expect(controller.rootPath, other.path);
      expect(
        controller.snapshot!.availableEntries.single.relativePath,
        'new.pdf',
      );
      final settings = await File(p.join(data.path, 'library-settings.json'))
          .readAsString();
      expect(settings, contains('new-root'));
    },
  );

  test('typing during a scan keeps the latest query and scope', () async {
    await file('第一首.pdf');
    await file('第二首.pdf');
    Completer<void>? gate;
    final controller = make(
      runner: (root, state, verify) async {
        if (gate != null) await gate.future;
        return scan(root, state, verify);
      },
    );
    await controller.initialize();
    await controller.selectRoot(source.path);
    gate = Completer<void>();
    final pending = controller.rescan();
    controller.setQuery('第一');
    controller.setQuery('第二');
    gate.complete();
    await pending;
    expect(controller.query, '第二');
    expect(controller.visibleEntries.single.relativePath, '第二首.pdf');
  });

  test('scan failure preserves last results and reports the error', () async {
    await file('保留.pdf');
    var fail = false;
    final controller = make(
      runner: (root, state, verify) {
        if (fail) throw const FileSystemException('temporary test failure');
        return scan(root, state, verify);
      },
    );
    await controller.initialize();
    await controller.selectRoot(source.path);
    fail = true;
    await controller.rescan();
    expect(controller.totalCount, 1);
    expect(controller.error, contains('已保留上次谱库结果'));
    expect(controller.scanning, isFalse);
  });

  test('actual filesystem event schedules a rescan', () async {
    await file('one.pdf');
    final controller = make(runner: scan, watch: true);
    await controller.initialize();
    await controller.selectRoot(source.path);
    expect(controller.watchWarning, isNull);
    await file('two.PNG');
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (controller.totalCount != 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(controller.totalCount, 2);
  });
}
