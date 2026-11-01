import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/reader/annotation_canvas.dart';

void main() {
  test('swept eraser clips sparse paths locally, preserves styles, one commit and atomic undo/redo survive schema2 roundtrip and bidirectional merge', () async {
    final dir = await Directory.systemTemp.createTemp('path-erase-');
    try {
      final store = await ReaderStateStore.open(
        statePath: '${dir.path}/state.json',
      );
      final page = PageKey(entryId: 'a', revisionId: 'r', pageNumber: 1);
      final style = StrokeStyle(
        tool: AnnotationTool.highlighter,
        argb: 0x55225588,
        widthFraction: .004,
      );
      final original = await store.addStroke(
        page,
        style: style,
        points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
      );
      final second = await store.addStroke(
        page,
        style: style,
        points: [NormalizedPoint(.1, .6), NormalizedPoint(.9, .6)],
      );
      final untouched = await store.addStroke(
        page,
        style: style,
        points: [NormalizedPoint(.1, .9), NormalizedPoint(.9, .9)],
      );
      final base = store.snapshot;
      final replacements = <String, List<List<NormalizedPoint>>>{};
      for (final s in [original, second]) {
        // One fast pointer move crosses both two-point strokes: no sampling holes.
        replacements[s.id] = eraseStrokePath(
          s.points,
          const Size(1000, 1000),
          const Offset(500, 100),
          const Offset(500, 800),
          20,
        );
      }
      expect(replacements[original.id], hasLength(2));
      expect(replacements[original.id]!.first.last.x, closeTo(.48, 1e-9));
      expect(replacements[original.id]!.last.first.x, closeTo(.52, 1e-9));
      expect(
        eraseStrokePath(
          untouched.points,
          const Size(1000, 1000),
          const Offset(500, 100),
          const Offset(500, 800),
          20,
        ).single,
        same(untouched.points),
      );
      final generation = store.snapshot.generation;
      await store.replaceStrokePaths(page, replacements);
      expect(store.snapshot.generation, generation + 1);
      expect(store.snapshot.strokesFor(page), hasLength(5));
      expect(
        store.snapshot
            .strokesFor(page)
            .every(
              (s) => s.style.toJson().toString() == style.toJson().toString(),
            ),
        isTrue,
      );
      await store.undo(page);
      expect(store.snapshot.strokesFor(page).map((s) => s.id).toSet(), {
        original.id,
        second.id,
        untouched.id,
      });
      await store.redo(page);
      expect(store.snapshot.strokesFor(page), hasLength(5));
      final reopened = await ReaderStateStore.open(statePath: store.statePath);
      expect(reopened.snapshot.toJson()['schemaVersion'], 2);
      expect(reopened.snapshot.strokesFor(page), hasLength(5));
      final merged = mergeReaderSnapshots(
        base: base,
        local: base,
        remote: reopened.snapshot,
        peerId: 'ipad',
      ).snapshot;
      final reverse = mergeReaderSnapshots(
        base: base,
        local: reopened.snapshot,
        remote: base,
        peerId: 'desktop',
      ).snapshot;
      expect(
        merged.strokesFor(page).map((s) => s.id).toSet(),
        reopened.snapshot.strokesFor(page).map((s) => s.id).toSet(),
      );
      expect(
        reverse.strokesFor(page).map((s) => s.id).toSet(),
        merged.strokesFor(page).map((s) => s.id).toSet(),
      );
      expect(merged.strokesFor(page).any((s) => s.id == original.id), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('queued eraser gestures rebase on committed fragments and each undo restores one gesture', () async {
    final dir = await Directory.systemTemp.createTemp('queued-eraser-');
    try {
      final store = await ReaderStateStore.open(
        statePath: '${dir.path}/state.json',
      );
      final page = PageKey(entryId: 'e', revisionId: 'r', pageNumber: 1);
      await store.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff123456,
          widthFraction: .004,
        ),
        points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
      );
      StrokePathRebuilder erase(double x) =>
          (strokes) => {
            for (final stroke in strokes)
              stroke.id: eraseStrokePath(
                stroke.points,
                const Size(1000, 1000),
                Offset(x, 0),
                Offset(x, 1000),
                20,
              ),
          };
      final first = store.replaceStrokePaths(page, {}, rebuild: erase(300));
      final second = store.replaceStrokePaths(page, {}, rebuild: erase(700));
      await Future.wait([first, second]);
      expect(store.snapshot.strokesFor(page), hasLength(3));
      await store.undo(page);
      expect(store.snapshot.strokesFor(page), hasLength(2));
      await store.undo(page);
      expect(store.snapshot.strokesFor(page), hasLength(1));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
