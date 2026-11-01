import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';

void main() {
  late Directory temporary;
  late ReaderWorkspace workspace;
  ReaderSession? session;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reader-session-');
    workspace = ReaderWorkspace(
      await ReaderStateStore.open(
        statePath: p.join(temporary.path, 'state.json'),
      ),
    );
  });
  tearDown(() async {
    session?.dispose();
    session = null;
    while (workspace.saving) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    workspace.dispose();
    await temporary.delete(recursive: true);
  });
  ScoreTarget target(String id, [String revision = 'r1']) => ScoreTarget(
    entryId: id,
    revisionId: revision,
    filePath: '/objects/$id/$revision',
    displayPath: 'logical/$id.pdf',
  );

  test(
    'lazy next-song metadata retries same press, rapid presses serialize',
    () async {
      final list = await workspace.store.createSetList('test');
      final a = await workspace.store.addItem(list.id, 'a');
      await workspace.store.addItem(list.id, 'b');
      final gate = Completer<void>();
      final started = Completer<void>();
      session = ReaderSession(
        workspace: workspace,
        locate: (id) => target(id),
        setListId: list.id,
        loader: (target) async {
          if (target.entryId == 'b') {
            started.complete();
            await gate.future;
          }
          return LoadedScore(
            target: target,
            pageCount: target.entryId == 'a' ? 1 : 3,
          );
        },
      );
      await session!.open(target('a'), itemId: a.id);
      final first = session!.turn(NavigationDirection.forward);
      await started.future;
      expect(session!.position!.entryId, 'a');
      final second = session!.turn(NavigationDirection.forward);
      gate.complete();
      await Future.wait([first, second]);
      expect(session!.position!.entryId, 'b');
      expect(session!.page, 2);
      await session!.turn(NavigationDirection.backward);
      await session!.turn(NavigationDirection.backward);
      expect(session!.position!.entryId, 'a');
      expect(session!.page, 1);
      await session!.turn(NavigationDirection.backward);
      expect(session!.page, 1);
      expect(session!.message, isNull, reason: 'page boundaries stay quiet');
    },
  );

  test(
    'manual selection cancels a late metadata load and queued turns',
    () async {
      final list = await workspace.store.createSetList('test');
      final a = await workspace.store.addItem(list.id, 'a');
      await workspace.store.addItem(list.id, 'b');
      final gate = Completer<void>();
      final started = Completer<void>();
      session = ReaderSession(
        workspace: workspace,
        locate: (id) => target(id),
        setListId: list.id,
        loader: (target) async {
          if (target.entryId == 'b') {
            started.complete();
            await gate.future;
          }
          return LoadedScore(target: target, pageCount: 1);
        },
      );
      await session!.open(target('a'), itemId: a.id);
      final pending = session!.turn(NavigationDirection.forward);
      await started.future;
      final queued = session!.turn(NavigationDirection.forward);
      await session!.open(target('c'));
      gate.complete();
      await pending;
      await queued;
      expect(session!.position!.entryId, 'c');
      expect(session!.loading, isFalse);
    },
  );

  test(
    'missing target and replacement revision hold original position',
    () async {
      final list = await workspace.store.createSetList('test');
      final a = await workspace.store.addItem(list.id, 'a');
      await workspace.store.addItem(list.id, 'b');
      var revision = 'r1';
      session = ReaderSession(
        workspace: workspace,
        locate: (id) => id == 'b' ? null : target(id, revision),
        setListId: list.id,
        loader: (target) async => LoadedScore(target: target, pageCount: 1),
      );
      await session!.open(target('a'), itemId: a.id);
      await session!.turn(NavigationDirection.forward);
      expect(session!.position!.entryId, 'a');
      expect(session!.message, contains('缺失'));
      revision = 'r2';
      await session!.turn(NavigationDirection.forward);
      expect(session!.position!.revisionId, 'r1');
      expect(session!.message, contains('旧批注'));
    },
  );

  test(
    'failed completed stroke remains visibly pending and can retry',
    () async {
      final stateDir = Directory(p.join(temporary.path, 'blocked'));
      final store = await ReaderStateStore.open(
        statePath: p.join(stateDir.path, 'state.json'),
      );
      final failing = ReaderWorkspace(store);
      await stateDir.delete(recursive: true);
      await File(stateDir.path).writeAsString('blocks directory');
      final page = PageKey(entryId: 'a', revisionId: 'r1', pageNumber: 1);
      await failing.addStroke(
        page,
        StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff000000,
          widthFraction: .003,
        ),
        [NormalizedPoint(.1, .2)],
      );
      expect(failing.unsavedCount, 1);
      expect(failing.store.snapshot.strokesFor(page), isEmpty);
      await File(stateDir.path).delete();
      await failing.retryStrokes();
      expect(failing.unsavedCount, 0);
      expect(failing.store.snapshot.strokesFor(page), hasLength(1));
      failing.dispose();
    },
  );

  test(
    'quiet bookmark failures stay visible and retry saves the final page',
    () async {
      final root = Directory(p.join(temporary.path, 'bookmark-error'));
      final store = await ReaderStateStore.open(
        statePath: p.join(root.path, 'reader.json'),
      );
      final saving = ReaderWorkspace(store);
      await root.delete(recursive: true);
      await File(root.path).writeAsString('blocks directory');
      await saving.rememberPosition(
        document: DocumentKey(entryId: 'e', revisionId: 'r'),
        pageNumber: 2,
        pageCount: 3,
      );
      await saving.flushPositions();
      expect(saving.error, contains('阅读位置保存失败'));
      await File(root.path).delete();
      await saving.rememberPosition(
        document: DocumentKey(entryId: 'e', revisionId: 'r'),
        pageNumber: 3,
        pageCount: 3,
      );
      await saving.flushPositions();
      expect(saving.error, isNull);
      final reopened = await ReaderStateStore.open(statePath: store.statePath);
      expect(
        reopened
            .readingPosition(DocumentKey(entryId: 'e', revisionId: 'r'))
            ?.pageNumber,
        3,
      );
      saving.dispose();
    },
  );

  test('private revision copy warms without source reread and rejects changed bytes', () async {
    final file = File(p.join(temporary.path, 'source.pdf'));
    await file.writeAsString('old revision');
    final hash = sha256.convert(utf8.encode('old revision')).toString();
    final target = ScoreTarget(
      entryId: 'copy',
      revisionId: 'old',
      filePath: file.path,
      displayPath: 'source.pdf',
      contentHash: hash,
    );
    final cache = p.join(temporary.path, 'copies');
    final path = await prepareReadingCopy(target, cache);
    await file.delete();
    expect(await prepareReadingCopy(target, cache), path);
    expect(await File(path).readAsString(), 'old revision');
    await File(path).writeAsString('corrupt cache');
    await file.writeAsString('new revision');
    await expectLater(prepareReadingCopy(target, cache), throwsFormatException);
  });
}
