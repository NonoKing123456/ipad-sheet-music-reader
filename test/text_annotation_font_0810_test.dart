import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';

final _page = PageKey(
  entryId: 'font-synthetic',
  revisionId: 'r',
  pageNumber: 1,
);
final _now = DateTime.utc(2026, 11, 2);
TextAnnotation _only(ReaderStateStore store) =>
    store.snapshot.annotationsFor(_page).whereType<TextAnnotation>().single;
ReaderSnapshot _snapshot(TextAnnotation text) => ReaderSnapshot(
  generation: 1,
  annotations: {
    _page: [text],
  },
  setLists: [],
  bookmarks: {},
  conflicts: [],
);
void main() {
  test('font optional JSON keeps legacy geometry and unknown values fall back safely', () {
    final text = TextAnnotation(
      id: 'a',
      text: '中文，Hello!\n第二行。',
      anchor: NormalizedPoint(.2, .3),
      argb: 0xff222222,
      fontSizeFraction: 20 / 1024,
      widthFraction: .45,
      createdUtc: _now,
      updatedUtc: _now,
      version: 1,
    );
    final legacy = text.toJson();
    expect((legacy['text'] as Map).containsKey('font'), isFalse);
    expect((legacy['text'] as Map).containsKey('rotation'), isFalse);
    expect(
      TextAnnotation.fromJson(jsonDecode(jsonEncode(legacy))).toJson(),
      legacy,
    );
    final future = jsonDecode(jsonEncode(legacy)) as Map<String, dynamic>;
    (future['text'] as Map)['font'] = 'unknown-future-font';
    expect(TextAnnotation.fromJson(future).font, AnnotationTextFont.system);
    (future['text'] as Map)['rotation'] = 'unknown';
    expect(TextAnnotation.fromJson(future).rotation, 0);
    for (final font in AnnotationTextFont.values) {
      final styled = text.revise(
        font: font,
        rotation: .37,
        widthFraction: .28,
        now: _now,
      );
      final roundTrip = ReaderSnapshot.fromJson(
        jsonDecode(jsonEncode(_snapshot(styled).toJson())),
      );
      expect(
        roundTrip.annotationsFor(_page).whereType<TextAnnotation>().single.font,
        font,
      );
      expect(
        styled.revise(anchor: NormalizedPoint(.4, .5), now: _now).font,
        font,
      );
      expect(styled.withDeletion(true, _now).font, font);
      expect(styled.withDeletion(true, _now).rotation, .37);
      expect(
        roundTrip
            .annotationsFor(_page)
            .whereType<TextAnnotation>()
            .single
            .geometry,
        styled.geometry,
      );
    }
  });
  test('font and normalized size survive save edit move delete undo redo and disk reopen', () async {
    final dir = await Directory.systemTemp.createTemp('reader-font-state-');
    try {
      final path = '${dir.path}/state.json';
      final store = await ReaderStateStore.open(statePath: path);
      final original = store.newText(
        text: '原文',
        anchor: NormalizedPoint(.2, .3),
        argb: 0xff222222,
      );
      await store.saveText(_page, original);
      final styled = _only(store).revise(
        font: AnnotationTextFont.monospace,
        fontSizeFraction: 32 / 1024,
        rotation: -.42,
        widthFraction: .27,
        now: _now,
      );
      await store.saveText(_page, styled, expected: TextEditBase(_only(store)));
      expect(_only(store).font, AnnotationTextFont.monospace);
      expect(await store.undo(_page), isTrue);
      expect(_only(store).font, AnnotationTextFont.system);
      expect(_only(store).fontSizeFraction, 20 / 1024);
      expect(_only(store).rotation, 0);
      expect(_only(store).widthFraction, .45);
      expect(await store.redo(_page), isTrue);
      expect(_only(store).fontSizeFraction, 32 / 1024);
      expect(_only(store).rotation, -.42);
      expect(_only(store).widthFraction, .27);
      final moved = _only(store)
          .revise(anchor: NormalizedPoint(.4, .5), now: _now);
      await store.saveText(_page, moved);
      await store.saveText(_page, _only(store).withDeletion(true, _now));
      expect(store.snapshot.annotationsFor(_page), isEmpty);
      expect(await store.undo(_page), isTrue);
      expect(_only(store).font, AnnotationTextFont.monospace);
      expect(await store.undo(_page), isTrue);
      expect(_only(store).anchor, original.anchor);
      expect(_only(store).fontSizeFraction, 32 / 1024);
      expect(_only(store).rotation, -.42);
      expect(_only(store).widthFraction, .27);
      await store.redo(_page);
      final reopened = await ReaderStateStore.open(statePath: path);
      expect(_only(reopened).geometry, _only(store).geometry);
      expect(_only(reopened).font, AnnotationTextFont.monospace);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
    'sync merge and conflict serialization retain both font/size branches',
    () async {
      final base = TextAnnotation(
        id: 'a',
        text: '同一段文字',
        anchor: NormalizedPoint(.2, .3),
        argb: 0xff222222,
        fontSizeFraction: 20 / 1024,
        widthFraction: .45,
        createdUtc: _now,
        updatedUtc: _now,
        version: 1,
      );
      final local = base.revise(
        font: AnnotationTextFont.serif,
        fontSizeFraction: 24 / 1024,
        rotation: .2,
        widthFraction: .22,
        now: _now,
      );
      final remote = base.revise(
        font: AnnotationTextFont.monospace,
        fontSizeFraction: 30 / 1024,
        rotation: -.3,
        widthFraction: .33,
        now: _now,
      );
      final result = mergeReaderSnapshots(
        base: _snapshot(base),
        local: _snapshot(local),
        remote: _snapshot(remote),
        peerId: 'synthetic-peer',
      );
      expect(result.conflicts, hasLength(1));
      final roundTrip = ReaderSnapshot.fromJson(
        jsonDecode(jsonEncode(result.snapshot.toJson())),
      );
      final conflict = roundTrip.conflicts.single;
      final variants = [
        TextAnnotation.fromJson(Map<String, dynamic>.from(conflict.first)),
        TextAnnotation.fromJson(Map<String, dynamic>.from(conflict.second)),
      ];
      expect(variants.map((t) => t.font).toSet(), {
        AnnotationTextFont.serif,
        AnnotationTextFont.monospace,
      });
      expect(variants.map((t) => t.fontSizeFraction).toSet(), {
        24 / 1024,
        30 / 1024,
      });
      expect(variants.map((t) => t.rotation).toSet(), {.2, -.3});
      expect(variants.map((t) => t.widthFraction).toSet(), {.22, .33});
    },
  );
}
