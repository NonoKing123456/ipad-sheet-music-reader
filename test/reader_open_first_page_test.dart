import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';

import 'reader_fixture.dart';

ScoreTarget _target(String id, {String? filePath}) => ScoreTarget(
  entryId: id,
  revisionId: 'synthetic-r1',
  filePath: filePath ?? '/synthetic/$id.png',
  displayPath: 'synthetic-folder/$id.png',
);

void main() {
  group('fresh reading sessions', () {
    late Directory temporary;
    late ReaderWorkspace workspace;
    ReaderSession? session;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('reader-first-page-');
      workspace = ReaderWorkspace(
        await ReaderStateStore.open(
          statePath: p.join(temporary.path, 'reader.json'),
        ),
      );
    });

    tearDown(() async {
      session?.dispose();
      session = null;
      await workspace.flushPositions();
      workspace.dispose();
      await temporary.delete(recursive: true);
    });

    test(
      'default open ignores page 3 bookmark and reopening starts at page 1',
      () async {
        final target = _target('a');
        final bookmark = await workspace.store.saveReadingPosition(
          document: target.key,
          pageNumber: 3,
          pageCount: 4,
        );
        final list = await workspace.store.createSetList('Synthetic set list');
        final item = await workspace.store.addItem(list.id, target.entryId);
        final annotatedPage = PageKey(
          entryId: target.entryId,
          revisionId: target.revisionId,
          pageNumber: 3,
        );
        final stroke = await workspace.store.addStroke(
          annotatedPage,
          style: StrokeStyle(
            tool: AnnotationTool.pen,
            argb: 0xff000000,
            widthFraction: .003,
          ),
          points: [NormalizedPoint(.1, .2), NormalizedPoint(.2, .3)],
        );
        session = ReaderSession(
          workspace: workspace,
          locate: (_) => target,
          deferPositionPersistence: true,
          loader: (target) async => LoadedScore(target: target, pageCount: 4),
        );

        await session!.open(target);
        expect(session!.page, 1);
        await session!.seek(4, gesture: Object());
        expect(session!.page, 4);
        await session!.open(target);
        expect(session!.page, 1);
        expect(workspace.store.readingPosition(target.key), same(bookmark));
        expect(
          workspace.store.snapshot.strokesFor(annotatedPage).single.id,
          stroke.id,
        );
        expect(
          workspace.store.snapshot.setListById(list.id)!.activeItems.single.id,
          item.id,
        );
      },
    );

    test(
      'explicit page number still overrides a saved reading position',
      () async {
        final target = _target('a');
        await workspace.store.saveReadingPosition(
          document: target.key,
          pageNumber: 3,
          pageCount: 4,
        );
        session = ReaderSession(
          workspace: workspace,
          locate: (_) => target,
          deferPositionPersistence: true,
          loader: (target) async => LoadedScore(target: target, pageCount: 4),
        );

        await session!.open(target, pageNumber: 2);
        expect(session!.page, 2);
        await session!.open(target, pageNumber: 99);
        expect(session!.page, 4);
      },
    );

    test(
      'set-list transitions and in-document seek retain explicit pages',
      () async {
        final targets = {'a': _target('a'), 'b': _target('b')};
        final list = await workspace.store.createSetList('Synthetic set list');
        final first = await workspace.store.addItem(list.id, 'a');
        final second = await workspace.store.addItem(list.id, 'b');
        for (final target in targets.values) {
          await workspace.store.saveReadingPosition(
            document: target.key,
            pageNumber: 3,
            pageCount: 4,
          );
        }
        session = ReaderSession(
          workspace: workspace,
          locate: (id) => targets[id],
          setListId: list.id,
          deferPositionPersistence: true,
          loader: (target) async => LoadedScore(target: target, pageCount: 4),
        );

        await session!.open(targets['a']!, itemId: first.id, pageNumber: 4);
        await session!.turn(NavigationDirection.forward);
        expect(session!.position!.entryId, 'b');
        expect(session!.position!.setListItemId, second.id);
        expect(session!.page, 1);
        await session!.turn(NavigationDirection.backward);
        expect(session!.position!.entryId, 'a');
        expect(session!.position!.setListItemId, first.id);
        expect(session!.page, 4);
        await session!.seek(2, gesture: Object());
        expect(session!.page, 2);
        expect(session!.position!.setListItemId, first.id);
      },
    );
  });

  for (final initialPage in <int?>[null, 2]) {
    testWidgets(
      'actual reader opens ${initialPage == null ? 'at page 1' : 'at explicit page $initialPage'} with saved page 3',
      (tester) async {
        final temporary = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('reader-first-page-screen-'),
        ))!;
        final workspace = (await tester.runAsync(() async {
          return ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: p.join(temporary.path, 'reader.json'),
            ),
          );
        }))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          for (var i = 0; workspace.saving && i < 200; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            await tester.pump();
          }
          expect(workspace.saving, isFalse);
          await tester.runAsync(() async {
            workspace.dispose();
            await temporary.delete(recursive: true);
          });
        });
        await tester.binding.setSurfaceSize(const Size(810, 1080));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final imagePath = p.join(temporary.path, 'synthetic.png');
        await writeSyntheticPaper(tester, imagePath);
        final target = _target('a', filePath: imagePath);
        await tester.runAsync(
          () => workspace.store.saveReadingPosition(
            document: target.key,
            pageNumber: 3,
            pageCount: 4,
          ),
        );
        final presented = <PageKey>[];

        await tester.pumpWidget(
          MaterialApp(
            home: LibraryReaderScreen(
              workspace: workspace,
              locate: (_) => target,
              initialTarget: target,
              initialPageNumber: initialPage,
              loader: (target) async =>
                  LoadedScore(target: target, pageCount: 4, imageAspect: .75),
              onPresented: presented.add,
            ),
          ),
        );
        await settleReader(tester);

        final expectedPage = initialPage ?? 1;
        expect(find.byType(RawImage), findsWidgets);
        expect(presented, isNotEmpty);
        expect(
          presented.first,
          PageKey(
            entryId: target.entryId,
            revisionId: target.revisionId,
            pageNumber: expectedPage,
          ),
        );
        expect(
          presented.every((page) => page.pageNumber == expectedPage),
          isTrue,
          reason: 'opening never presents the old bookmark before the target',
        );
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.iOS,
      }),
    );
  }
}
