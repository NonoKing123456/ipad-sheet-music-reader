import 'reader_fixture.dart';

import 'package:flutter/gestures.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/library_reader_screen.dart';
import 'package:score_reader/reader/reader_session.dart';
import 'package:score_reader/reader/reader_workspace.dart';

void main() {
  for (final inSetList in [false, true]) {
    testWidgets(
      'library reader preview, rotation and scaled ink, setList=$inSetList',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('preview-test-'),
        ))!;
        final workspace = (await tester.runAsync(() async {
          return ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: p.join(directory.path, 'state.json'),
            ),
          );
        }))!;
        String? listId;
        String? itemId;
        if (inSetList) {
          await tester.runAsync(() async {
            final list = await workspace.store.createSetList('演出');
            listId = list.id;
            itemId = (await workspace.store.addItem(list.id, 'e')).id;
          });
        }
        await writeSyntheticPaper(tester, p.join(directory.path, 'page.png'));
        final target = ScoreTarget(
          entryId: 'e',
          revisionId: 'r',
          filePath: p.join(directory.path, 'page.png'),
          displayPath: 'folder/page.png',
        );
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: LibraryReaderScreen(
                workspace: workspace,
                locate: (_) => target,
                initialTarget: target,
                setListId: listId,
                itemId: itemId,
                loader: (target) async =>
                    LoadedScore(target: target, pageCount: 1, imageAspect: .75),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await settleReader(tester);
        await tester.tap(find.byTooltip('开发预览（模拟平板）'));
        await tester.pump();
        var viewport = tester.getSize(
          find.byKey(const ValueKey('tablet-preview-viewport')),
        );
        expect(viewport.width / viewport.height, closeTo(.75, .001));
        expect(find.text('批注'), findsNothing);
        expect(
          tester.takeException(),
          isNull,
          reason: 'narrow toolbar and footer must fit',
        );
        await tester.tap(find.byTooltip('开发预览：切换横竖屏'));
        await tester.pump();
        viewport = tester.getSize(
          find.byKey(const ValueKey('tablet-preview-viewport')),
        );
        expect(viewport.width / viewport.height, closeTo(4 / 3, .001));
        await tester.tap(find.byTooltip('放大'));
        await tester.pump();
        await tester.tap(find.byTooltip('收起阅读工具'));
        await settleReader(tester);
        final box = tester.renderObject<RenderBox>(
          find.byType(AnnotationCanvas),
        );
        final first = box.localToGlobal(
          Offset(box.size.width * .25, box.size.height * .3),
        );
        final last = box.localToGlobal(
          Offset(box.size.width * .75, box.size.height * .7),
        );
        await tester.runAsync(() async {
          final pointer = await tester.startGesture(
            first,
            kind: PointerDeviceKind.stylus,
          );
          await pointer.moveTo(last);
          await pointer.up();
        });
        await settleReader(tester);
        expect(workspace.saving, isFalse);
        final page = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1);
        final stroke = workspace.store.snapshot.strokesFor(page).single;
        expect(stroke.points.first.x, closeTo(.25, .001));
        expect(stroke.points.first.y, closeTo(.3, .001));
        expect(stroke.points.last.x, closeTo(.75, .001));
        expect(stroke.points.last.y, closeTo(.7, .001));
        await tester.tapAt(box.localToGlobal(box.size.center(Offset.zero)));
        await settleReader(tester);
        await tester.tap(find.byTooltip('开发预览：切换横竖屏'));
        await tester.pump();
        expect(find.text('100%'), findsOneWidget);
        expect(workspace.store.snapshot.strokesFor(page).single.id, stroke.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
        await tester.runAsync(() async {
          for (var retry = 0; workspace.saving && retry < 200; retry++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          workspace.dispose();
          await directory.delete(recursive: true);
        });
      },
    );
  }
}
