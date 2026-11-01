import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/annotation_canvas.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';
import 'package:score_reader/sync/sync_screen.dart';

final _page = PageKey(entryId: 'synthetic', revisionId: 'r', pageNumber: 1);
final _white = StrokeStyle(
  tool: AnnotationTool.pen,
  argb: 0xffffffff,
  widthFraction: .1,
);
final _black = StrokeStyle(
  tool: AnnotationTool.pen,
  argb: 0xff000000,
  widthFraction: .02,
);
AnnotationStroke _stroke(
  String id,
  StrokeStyle style, {
  List<NormalizedPoint>? points,
  int version = 1,
}) => AnnotationStroke(
  id: id,
  style: style,
  points: points ?? [NormalizedPoint(.5, .5)],
  createdUtc: DateTime.utc(1990),
  updatedUtc: DateTime.utc(1990),
  version: version,
);
ReaderSnapshot _snapshot(List<AnnotationStroke> strokes) => ReaderSnapshot(
  generation: 0,
  pages: {_page: strokes},
  setLists: [],
  bookmarks: {},
);
List<String> _order(ReaderSnapshot state) =>
    state.pages[_page]!.map((s) => s.id).toList();
String _geometry(Map<String, Object?> json) => sha256
    .convert(utf8.encode(canonicalReaderJson([json['style'], json['points']])))
    .toString();

class _HeldLayerWorkspace extends ReaderWorkspace {
  _HeldLayerWorkspace(super.store);
  final held = <(PendingPathEdit, Completer<void>)>[];
  @override
  Future<void> replacePaths(
    PageKey page,
    Map<String, List<List<NormalizedPoint>>> paths, {
    StrokePathRebuilder? rebuild,
  }) {
    final edit = PendingPathEdit(page, paths, rebuild)..saving = true,
        done = Completer<void>();
    pendingPaths.add(edit);
    held.add((edit, done));
    notifyListeners();
    return done.future;
  }

  Future<void> commit() async {
    final edit = held.first.$1;
    await store.replaceStrokePaths(
      edit.page,
      edit.paths,
      rebuild: edit.rebuild,
    );
    notifyListeners();
  }

  void retire() {
    final first = held.removeAt(0);
    pendingPaths.remove(first.$1);
    first.$2.complete();
    notifyListeners();
  }
}

Future<int> _pixel(
  WidgetTester tester,
  AnnotationPainter painter,
  int x,
  int y,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xffcccccc), BlendMode.src);
  painter.paint(canvas, const Size(1000, 1000));
  final picture = recorder.endRecording();
  final image = (await tester.runAsync(() => picture.toImage(1000, 1000)))!;
  picture.dispose();
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  image.dispose();
  final offset = (y * 1000 + x) * 4;
  return (bytes.getUint8(offset + 3) << 24) |
      (bytes.getUint8(offset) << 16) |
      (bytes.getUint8(offset + 1) << 8) |
      bytes.getUint8(offset + 2);
}

AnnotationPainter _painter(List<AnnotationStroke> strokes) => AnnotationPainter(
  strokes: strokes,
  pending: const [],
  draft: const [],
  draftStyle: _black,
);

void main() {
  test('causal stroke order survives clock-skew IDs, independent append, missing base records and swapped merges without false conflicts', () {
    final cover = _stroke(
      'z-cover',
      _white,
      points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
    );
    final first = _stroke('00-clock-skew-ink', _black);
    final second = _stroke(
      '01-independent-ink',
      _black,
      points: [NormalizedPoint(.6, .5)],
    );
    final base = _snapshot([cover]);
    final left = _snapshot([cover, first]), right = _snapshot([cover, second]);
    final merged = mergeReaderSnapshots(
      base: base,
      local: left,
      remote: right,
      peerId: 'r',
    );
    final swapped = mergeReaderSnapshots(
      base: base,
      local: right,
      remote: left,
      peerId: 'l',
    );
    expect(_order(merged.snapshot), [
      'z-cover',
      '00-clock-skew-ink',
      '01-independent-ink',
    ]);
    expect(_order(swapped.snapshot), _order(merged.snapshot));
    expect(merged.conflicts, isEmpty);
    final absent = mergeReaderSnapshots(
      base: base,
      local: base,
      remote: _snapshot([first]),
      peerId: 'r',
    );
    expect(_order(absent.snapshot), ['z-cover', '00-clock-skew-ink']);
    expect(absent.conflicts, isEmpty);
    final newer = _stroke(
      '000-even-earlier-clock',
      _black,
      points: [NormalizedPoint(.7, .5)],
    );
    final causal = mergeReaderSnapshots(
      base: base,
      local: merged.snapshot,
      remote: _snapshot([cover, first, newer]),
      peerId: 'r',
    );
    expect(
      _order(causal.snapshot).indexOf(newer.id),
      greaterThan(_order(causal.snapshot).indexOf(first.id)),
    );
    expect(causal.conflicts, isEmpty);
    debugPrint(
      'LAYER_DAG_083 base_before_clock_skew_ink=true independent_append_converges=true absent_is_not_delete=true clocks_not_authority=true',
    );
  });

  testWidgets(
    'actual eraser preview pending commit undo redo and reopen preserve opaque cover below later ink, including concurrent sync',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('layers-083-'),
      ))!;
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final workspace = _HeldLayerWorkspace(store);
      final cover = (await tester.runAsync(
        () => store.addStroke(
          _page,
          style: _white,
          points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
        ),
      ))!;
      final ink = (await tester.runAsync(
        () => store.addStroke(
          _page,
          style: _black,
          points: [NormalizedPoint(.5, .5)],
        ),
      ))!;
      final base = store.snapshot;
      AnnotationPainter current() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<AnnotationPainter>()
          .single;
      Future<void> black(String phase) async {
        expect(
          await _pixel(tester, current(), 500, 500),
          0xff000000,
          reason: phase,
        );
        debugPrint(
          'LAYER_PHASE_083 $phase center=black order=${current().strokes.map((s) => s.style.argb.toRadixString(16)).join(",")}',
        );
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AnnotationCanvas(
              workspace: workspace,
              page: _page,
              enabled: true,
              eraser: true,
              eraserRadiusFraction: .02,
              style: _black,
            ),
          ),
        );
        await black('before');
        final eraser = await tester.startGesture(
          const Offset(200, 300),
          pointer: 91,
          kind: PointerDeviceKind.stylus,
        );
        await eraser.moveTo(const Offset(200, 700));
        await tester.pump();
        await black('live-preview');
        expect(await _pixel(tester, current(), 200, 500), 0xffcccccc);
        await eraser.up();
        await tester.pump();
        await black('pending');
        await tester.runAsync(workspace.commit);
        await tester.pump();
        await black('commit-before-retire');
        workspace.retire();
        await tester.pump();
        await black('durable');
        final erased = store.snapshot;
        expect(erased.pages[_page]!.first.id, cover.id);
        expect(erased.pages[_page]!.first.isDeleted, isTrue);
        expect(erased.strokesFor(_page).last.id, ink.id);
        await tester.runAsync(() => store.undo(_page));
        workspace.refreshFromStore();
        await tester.pump();
        await black('undo');
        expect(await _pixel(tester, current(), 200, 500), 0xffffffff);
        await tester.runAsync(() => store.redo(_page));
        workspace.refreshFromStore();
        await tester.pump();
        await black('redo');
        final reopened = (await tester.runAsync(
          () => ReaderStateStore.open(statePath: store.statePath),
        ))!;
        expect(
          await _pixel(
            tester,
            _painter(reopened.snapshot.strokesFor(_page)),
            500,
            500,
          ),
          0xff000000,
        );
        expect(reopened.snapshot.toJson()['schemaVersion'], ReaderSnapshot.schemaVersion);
        final fresh = _stroke(
          '000-clock-skew-new-ink',
          _black,
          points: [NormalizedPoint(.65, .5)],
        );
        final remote = _snapshot([...base.pages[_page]!, fresh]);
        final merged = mergeReaderSnapshots(
          base: base,
          local: erased,
          remote: remote,
          peerId: 'r',
        );
        final reverse = mergeReaderSnapshots(
          base: base,
          local: remote,
          remote: erased,
          peerId: 'l',
        );
        expect(merged.conflicts, isEmpty);
        expect(reverse.conflicts, isEmpty);
        expect(_order(merged.snapshot), _order(reverse.snapshot));
        expect(merged.snapshot.strokesFor(_page).last.id, fresh.id);
        for (final state in [merged.snapshot, reverse.snapshot]) {
          expect(
            await _pixel(tester, _painter(state.strokesFor(_page)), 500, 500),
            0xff000000,
          );
          expect(
            await _pixel(tester, _painter(state.strokesFor(_page)), 650, 500),
            0xff000000,
          );
          expect(
            await _pixel(tester, _painter(state.strokesFor(_page)), 200, 500),
            0xffcccccc,
          );
        }
        expect(cover.points, [
          NormalizedPoint(.1, .5),
          NormalizedPoint(.9, .5),
        ]);
        debugPrint(
          'LAYER_ERASE_SYNC_083 fragments_in_original_layer=true undo_redo_reopen_black=true fresh_clock_skew_ink_above_cover=true bidirectional=true legacy_ink_payload_unchanged=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        while (workspace.held.isNotEmpty) {
          workspace.retire();
        }
        workspace.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'explicit order cycle preserves base and both restorable branch orders with minimal geometry and friendly UI',
    (tester) async {
      final cover = _stroke(
        'white',
        _white,
        points: [NormalizedPoint(.1, .5), NormalizedPoint(.9, .5)],
      );
      final changed = _stroke(
        'white',
        _white,
        points: [NormalizedPoint(.12, .5), NormalizedPoint(.88, .5)],
        version: 2,
      );
      final ink = _stroke('black', _black),
          added = _stroke('new', _black, points: [NormalizedPoint(.7, .5)]);
      final base = _snapshot([cover, ink]),
          left = _snapshot([changed, ink, added]),
          right = _snapshot([ink, cover, added]);
      final merged = mergeReaderSnapshots(
        base: base,
        local: left,
        remote: right,
        peerId: 'r',
      );
      final swapped = mergeReaderSnapshots(
        base: base,
        local: right,
        remote: left,
        peerId: 'l',
      );
      expect(_order(merged.snapshot), ['white', 'black', 'new']);
      expect(_order(swapped.snapshot), _order(merged.snapshot));
      final conflict = merged.conflicts.single;
      expect(conflict.kind, 'strokeOrder');
      expect(swapped.conflicts.single.id, conflict.id);
      final variants = [conflict.first, conflict.second];
      expect(
        variants.map((v) => (v['order'] as List).join(',')),
        unorderedEquals(['white,black,new', 'black,white,new']),
      );
      expect(variants.every((v) => !v.containsKey('strokes')), isTrue);
      final extra = [
        for (final v in variants) ...v['strokeVariants'] as List? ?? const [],
      ];
      expect(extra, hasLength(1));
      expect((extra.single as Map)['id'], 'white');
      final geometries = <String, Map<String, Object?>>{};
      for (final stroke in merged.snapshot.pages[_page]!) {
        final json = stroke.toJson();
        geometries[_geometry(json)] = json;
      }
      for (final raw in extra) {
        final json = Map<String, Object?>.from(raw as Map);
        geometries[_geometry(json)] = json;
      }
      for (final variant in variants) {
        final refs = Map<String, Object?>.from(
          variant['geometryRefs'] as Map? ?? const {},
        );
        final expected = (variant['order'] as List).first == 'white'
            ? left
            : right;
        for (final id in variant['order'] as List) {
          final json = refs[id] == null
              ? merged.snapshot.pages[_page]!
                    .singleWhere((s) => s.id == id)
                    .toJson()
              : geometries[refs[id]]!;
          expect(
            _geometry(json),
            _geometry(
              expected.pages[_page]!.singleWhere((s) => s.id == id).toJson(),
            ),
          );
        }
      }
      final roundtrip = ReaderSnapshot.fromJson(
        Map<String, dynamic>.from(merged.snapshot.toJson()),
      );
      expect(roundtrip.toJson()['schemaVersion'], ReaderSnapshot.schemaVersion);
      expect(roundtrip.conflicts.single.kind, 'strokeOrder');
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('layer-conflict-083-'),
      ))!;
      await tester.runAsync(
        () =>
            File('${dir.path}/state.json')
                .writeAsString(jsonEncode(roundtrip.toJson())),
      );
      final store = (await tester.runAsync(
        () => ReaderStateStore.open(statePath: '${dir.path}/state.json'),
      ))!;
      final workspace = ReaderWorkspace(store),
          library = LibraryController(dataDirectory: dir, watchSource: false);
      final sync = SyncController(library: library, workspace: workspace);
      try {
        await tester.pumpWidget(
          MaterialApp(home: SyncConflictsScreen(controller: sync)),
        );
        expect(find.text('笔迹叠放顺序有差异，双方记录已保留'), findsNWidgets(2));
        expect(find.textContaining('第1页'), findsOneWidget);
        expect(find.textContaining('3 笔记录'), findsNWidgets(2));
        expect(find.text('原始版本详情'), findsNothing);
        expect(tester.takeException(), isNull);
        debugPrint(
          'LAYER_CYCLE_083 base_hard_order=true swapped_converges=true orders_saved=true extra_geometry_records=1 branch_geometry_restorable=true schema2=true friendly_ui=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        sync.dispose();
        workspace.dispose();
        library.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );

  test('order conflict fingerprints retain geometry across later merges and stale same-id replay', () async {
    final a1 = _stroke('a', _black, points: [NormalizedPoint(.1, .5)]);
    final a2 = _stroke('a', _black, points: [NormalizedPoint(.2, .5)]);
    final b = _stroke('b', _black);
    final first = mergeReaderSnapshots(
      base: _snapshot([a1, b]),
      local: _snapshot([a2, b]),
      remote: _snapshot([b, a1]),
      peerId: 'peer',
    ).snapshot;
    final original = first.conflicts.single;
    expect(
      [
        original.first,
        original.second,
      ].every((v) => (v['geometryRefs'] as Map).length == 2),
      isTrue,
    );
    final rollback = _snapshot([a1, b]).next(conflicts: first.conflicts);
    final second = mergeReaderSnapshots(
      base: first,
      local: first,
      remote: rollback,
      peerId: 'peer',
    ).snapshot;
    expect(
      second.pages[_page]!.singleWhere((s) => s.id == 'a').points.single.x,
      .1,
    );
    bool retained(ReaderSnapshot state, double x) =>
        state.pages[_page]!.any((s) => s.id == 'a' && s.points.single.x == x) ||
        state.conflicts.any(
          (c) => [c.first, c.second].any(
            (v) => (v['strokeVariants'] as List? ?? const []).any(
              (raw) =>
                  (raw as Map)['id'] == 'a' &&
                  (((raw['points'] as List).single as Map)['x'] as num)
                          .toDouble() ==
                      x,
            ),
          ),
        );
    expect(retained(second, .2), isTrue);
    final stale = _snapshot([a1, b]).next(conflicts: first.conflicts);
    final forward = mergeReaderSnapshots(
      base: second,
      local: second,
      remote: stale,
      peerId: 'peer',
    ).snapshot;
    final reverse = mergeReaderSnapshots(
      base: second,
      local: stale,
      remote: second,
      peerId: 'peer',
    ).snapshot;
    expect(retained(forward, .2), isTrue);
    expect(retained(reverse, .2), isTrue);
    expect(
      canonicalReaderJson(forward.conflicts.single.toJson()),
      canonicalReaderJson(reverse.conflicts.single.toJson()),
    );
    expect(forward.conflicts.single.id, original.id);
    final again = mergeReaderSnapshots(
      base: forward,
      local: forward,
      remote: stale,
      peerId: 'peer',
    ).snapshot;
    List<Map<String, Object?>> archives(ReaderSnapshot state) => [
      for (final variant in [
        state.conflicts.single.first,
        state.conflicts.single.second,
      ])
        for (final raw in variant['strokeVariants'] as List? ?? const [])
          Map<String, Object?>.from(raw as Map),
    ];
    expect(archives(again).length, archives(forward).length);
    expect(
      archives(again).map(_geometry).toSet().length,
      archives(again).length,
    );
    final dir = await Directory.systemTemp.createTemp('layer-retention-083-');
    try {
      final path = '${dir.path}/state.json';
      await File(path).writeAsString(jsonEncode(again.toJson()));
      final reopened = await ReaderStateStore.open(statePath: path);
      expect(retained(reopened.snapshot, .2), isTrue);
      expect(reopened.snapshot.toJson()['schemaVersion'], ReaderSnapshot.schemaVersion);
      debugPrint(
        'LAYER_RETENTION_083 all_branch_refs=true rollback_pins_only_missing_geometry=true stale_same_id_union=true swapped_same_payload=true repeated_merge_no_archive_growth=true reopen_preserves=true',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
