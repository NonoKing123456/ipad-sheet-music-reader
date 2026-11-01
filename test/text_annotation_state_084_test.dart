import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/library_controller.dart';
import 'package:score_reader/reader/reader_workspace.dart';
import 'package:score_reader/sync/sync_controller.dart';

final page = PageKey(entryId: 'synthetic', revisionId: 'r', pageNumber: 1);
final now = DateTime.utc(2026, 1, 1);
final style = StrokeStyle(
  tool: AnnotationTool.pen,
  argb: 0xff222222,
  widthFraction: .004,
);
AnnotationStroke ink(String id, {bool deleted = false}) => AnnotationStroke(
  id: id,
  style: style,
  points: [NormalizedPoint(.1, .2), NormalizedPoint(.3, .4)],
  createdUtc: now,
  updatedUtc: now,
  version: 7,
  deletedUtc: deleted ? now : null,
);
TextAnnotation text(String id, String content, {double x = .1}) =>
    TextAnnotation(
      id: id,
      text: content,
      anchor: NormalizedPoint(x, .25),
      argb: 0xffc12b32,
      fontSizeFraction: 20 / 1024,
      widthFraction: .45,
      createdUtc: now,
      updatedUtc: now,
      version: 1,
    );
ReaderSnapshot snapshot(
  List<PageAnnotation> items, {
  List<MergeConflict> conflicts = const [],
  int generation = 1,
}) => ReaderSnapshot(
  generation: generation,
  annotations: {page: items},
  setLists: [],
  bookmarks: {},
  conflicts: conflicts,
);
TextAnnotation onlyText(ReaderStateStore store) =>
    store.snapshot.annotationsFor(page).whereType<TextAnnotation>().single;

Set<String> retainedText(ReaderSnapshot state, String id) {
  final found = <String>{};
  void visit(Object? value) {
    if (value is Map) {
      if (value['kind'] == 'text' && value['id'] == id) {
        found.add((value['text'] as Map)['text'] as String);
      }
      for (final child in value.values) {
        visit(child);
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child);
      }
    }
  }

  visit(state.toJson());
  return found;
}

class _RealLoopback extends HttpOverrides {}

class _EmptySource implements LibrarySource {
  @override
  Future<SyncManifest> manifest() async =>
      SyncManifest(libraryId: 'synthetic', folders: [''], entries: []);
  @override
  Future<Stream<List<int>>> openObject(String id, String revision) =>
      throw StateError('No content transfer');
}

Future<({int status, Map<String, dynamic> json})> rawState(
  Uri uri,
  String token,
  String path,
  Map<String, Object?> body, {
  bool capable = false,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (capable) request.headers.set('x-reader-state-max-schema', 3);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final json = jsonDecode(
      await utf8.decoder.bind(response).join(),
    ) as Map<String, dynamic>;
    return (status: response.statusCode, json: json);
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('stale text draft after peer edit or deletion preserves both durable semantic branches, including failed pending retry', () async {
    final dir = await Directory.systemTemp.createTemp('text-interleaved-084-');
    try {
      for (var scenario = 0; scenario < 5; scenario++) {
        final folder = await Directory('${dir.path}/case-$scenario').create();
        final store = await ReaderStateStore.open(
          statePath: '${folder.path}/state.json',
        );
        final workspace = ReaderWorkspace(store);
        final a = store.newText(
          text: '原文 A',
          anchor: NormalizedPoint(.2, .3),
          argb: 0xff222222,
        );
        await store.saveText(page, a);
        final ancestor = store.snapshot;
        final remote = scenario == 1
            ? a.withDeletion(true, now)
            : scenario == 3
            ? a.revise(now: now, version: 18)
            : a.revise(
                text: '远端 R',
                anchor: NormalizedPoint(.4, .45),
                now: now,
              );
        final desired = scenario == 4
            ? a.revise(now: now)
            : scenario == 2
            ? a.withDeletion(true, now)
            : a.revise(text: '本地 L，English!', now: now);
        if (scenario == 0) {
          final held = await folder.rename('${folder.path}.held');
          await File(folder.path).writeAsString('synthetic failure');
          expect(
            await workspace.saveText(page, desired, expected: TextEditBase(a)),
            isFalse,
          );
          await File(folder.path).delete();
          await held.rename(folder.path);
        }
        await store.mergeFromPeer(
          base: ancestor,
          remote: ancestor.next(
            annotations: {
              page: [remote],
            },
          ),
          peerId: 'remote',
        );
        expect(store.snapshot.conflicts, isEmpty);
        if (scenario == 0) {
          expect(workspace.pendingText.single.expected.value!.text, a.text);
          await workspace.retryStrokes();
          expect(workspace.pendingText, isEmpty);
          expect(workspace.textConflictNotice, isNotNull);
        } else {
          await store.saveText(page, desired, expected: TextEditBase(a));
        }
        final reopened = await ReaderStateStore.open(
          statePath: store.statePath,
        );
        if (scenario == 4) {
          expect(reopened.snapshot.conflicts, isEmpty);
          expect(onlyText(reopened).geometry, remote.geometry);
          expect(await store.undo(page), isFalse);
          expect(await store.redo(page), isFalse);
          expect(
            onlyText(await ReaderStateStore.open(statePath: store.statePath))
                .geometry,
            remote.geometry,
          );
        } else if (scenario == 3) {
          expect(
            reopened.snapshot.conflicts,
            isEmpty,
            reason: 'counter/time-only changes are not semantic divergence',
          );
          expect(onlyText(reopened).text, desired.text);
        } else {
          final conflict = reopened.snapshot.conflicts.single;
          expect(conflict.kind, 'stroke');
          final branches = [
            TextAnnotation.fromJson(Map<String, dynamic>.from(conflict.first)),
            TextAnnotation.fromJson(Map<String, dynamic>.from(conflict.second)),
          ];
          expect(
            branches.map((t) => t.geometry),
            containsAll([remote.geometry, desired.geometry]),
          );
          expect(
            branches.map((t) => t.isDeleted),
            containsAll([remote.isDeleted, desired.isDeleted]),
          );
          final winner = (store.snapshot.annotations[page]!.singleWhere(
            (item) => item.id == a.id,
          )) as TextAnnotation;
          final changed =
              canonicalReaderJson(winner.geometry) !=
                  canonicalReaderJson(remote.geometry) ||
              winner.isDeleted != remote.isDeleted;
          expect(await store.undo(page), changed);
          if (changed) {
            final undone = store.snapshot.annotations[page]!.singleWhere(
              (item) => item.id == a.id,
            ) as TextAnnotation;
            expect(undone.geometry, remote.geometry);
            expect(undone.isDeleted, remote.isDeleted);
          }
          expect(await store.redo(page), changed);
          final redone = store.snapshot.annotations[page]!.singleWhere(
            (item) => item.id == a.id,
          ) as TextAnnotation;
          expect(redone.geometry, winner.geometry);
          expect(redone.isDeleted, winner.isDeleted);
          expect(
            (await ReaderStateStore.open(statePath: store.statePath))
                .snapshot
                .conflicts
                .single
                .toJson(),
            conflict.toJson(),
          );
        }
        workspace.dispose();
      }
      debugPrint(
        'TEXT_INTERLEAVE_084 captured_semantic_base=true merge_then_stale_edit_or_delete_preserves_both=true failed_pending_keeps_base=true durable_conflict_not_undo_only=true counter_only_no_conflict=true',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('schema2 ink is unchanged while confirmed Unicode text edits move delete undo redo reopen and failed saves retry', () async {
    final dir = await Directory.systemTemp.createTemp('text-state-084-');
    final data = await Directory('${dir.path}/state').create();
    final file = File('${data.path}/reader.json');
    final legacy = snapshot([
      ink('a'),
      ink('deleted', deleted: true),
      ink('b'),
    ]);
    final old = legacy.toJson()..['schemaVersion'] = 2;
    await file.writeAsString(jsonEncode(old));
    final store = await ReaderStateStore.open(statePath: file.path);
    final workspace = ReaderWorkspace(store);
    final library = LibraryController(
      dataDirectory: Directory('${dir.path}/library'),
      watchSource: false,
    );
    final sync = SyncController(library: library, workspace: workspace);
    try {
      expect(
        store.snapshot.pages[page]!.map((s) => s.toJson()),
        legacy.pages[page]!.map((s) => s.toJson()),
      );
      expect(
        jsonDecode(await file.readAsString())['schemaVersion'],
        2,
        reason: 'read does not rewrite old state',
      );
      final created = store.newText(
        text: '中文，English! “标点”；\n第二行。',
        anchor: NormalizedPoint(.2, .3),
        argb: 0xff123456,
      );
      expect(await workspace.saveText(page, created), isTrue);
      await store.addStroke(
        page,
        style: style,
        points: [NormalizedPoint(.6, .7)],
      );
      final order = store.snapshot.annotations[page]!.map((a) => a.id).toList();
      final serialized = onlyText(store).toJson();
      expect(serialized['kind'], 'text');
      expect(serialized.containsKey('points'), isFalse);
      expect(serialized.containsKey('style'), isFalse);
      final moved = onlyText(store).revise(
        text: '修改后的中文 / English，？！',
        anchor: NormalizedPoint(.4, .45),
        now: now,
      );
      expect(await workspace.saveText(page, moved), isTrue);
      expect(store.snapshot.annotations[page]!.map((a) => a.id), order);
      expect(await store.undo(page), isTrue);
      expect(onlyText(store).text, created.text);
      expect(onlyText(store).anchor, created.anchor);
      expect(await store.redo(page), isTrue);
      expect(onlyText(store).text, moved.text);
      expect(onlyText(store).anchor, moved.anchor);
      expect(
        await workspace.saveText(page, onlyText(store).withDeletion(true, now)),
        isTrue,
      );
      expect(
        store.snapshot.annotationsFor(page).whereType<TextAnnotation>(),
        isEmpty,
      );
      expect(await store.undo(page), isTrue);
      expect(onlyText(store).text, moved.text);
      expect(await store.redo(page), isTrue);
      expect(
        store.snapshot.annotationsFor(page).whereType<TextAnnotation>(),
        isEmpty,
      );
      expect(await store.undo(page), isTrue);
      final parked = await data.rename('${data.path}.held');
      await File(data.path).writeAsString('synthetic storage failure');
      expect(
        await workspace.saveText(
          page,
          onlyText(store).revise(text: '待重试：完整中文 + English。', now: now),
        ),
        isFalse,
      );
      expect(workspace.pendingText, hasLength(1));
      expect(workspace.unsavedCount, 1);
      expect(sync.hasUnsavedEdits, isTrue);
      expect(
        workspace.annotationsFor(page).whereType<TextAnnotation>().single.text,
        '待重试：完整中文 + English。',
      );
      await File(data.path).delete();
      await parked.rename(data.path);
      await workspace.retryStrokes();
      expect(workspace.pendingText, isEmpty);
      expect(sync.hasUnsavedEdits, isFalse);
      expect(onlyText(store).text, '待重试：完整中文 + English。');
      expect(await store.undo(page), isTrue);
      expect(onlyText(store).text, moved.text);
      expect(await store.redo(page), isTrue);
      final reopened = await ReaderStateStore.open(statePath: file.path);
      expect(onlyText(reopened).text, '待重试：完整中文 + English。');
      expect(reopened.snapshot.annotations[page]!.map((a) => a.id), order);
      for (var i = 0; i < 3; i++) {
        expect(
          reopened.snapshot.pages[page]![i].toJson(),
          legacy.pages[page]![i].toJson(),
        );
      }
      expect(jsonDecode(await file.readAsString())['schemaVersion'], 3);
      debugPrint(
        'TEXT_STATE_084 schema2_ink_identity_geometry_versions_tombstones_preserved=true typed_unicode_no_points=true edit_move_delete_undo_redo=true failed_pending_retry=true reopen=true',
      );
    } finally {
      sync.dispose();
      workspace.dispose();
      library.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('text content conflicts and order fingerprints retain complete Unicode geometry across continuous merges and stale replay', () {
    final a = text('a', '旧字，old.'), b = ink('b');
    final localText = a.revise(
      text: '本地新字，English!',
      anchor: NormalizedPoint(.35, .45),
      now: now,
    );
    final base = snapshot([a, b]);
    final left = snapshot([localText, b]), right = snapshot([b, a]);
    final first = mergeReaderSnapshots(
      base: base,
      local: left,
      remote: right,
      peerId: 'peer',
    ).snapshot;
    final swapped = mergeReaderSnapshots(
      base: base,
      local: right,
      remote: left,
      peerId: 'peer',
    ).snapshot;
    expect(first.conflicts.single.kind, 'strokeOrder');
    expect(
      first.annotations[page]!.map((a) => a.toJson()),
      swapped.annotations[page]!.map((a) => a.toJson()),
    );
    expect(retainedText(first, 'a'), containsAll([a.text, localText.text]));
    final oldInkHash = sha256
        .convert(
          utf8.encode(
            canonicalReaderJson([b.toJson()['style'], b.toJson()['points']]),
          ),
        )
        .toString();
    for (final branch in [
      first.conflicts.single.first,
      first.conflicts.single.second,
    ]) {
      expect((branch['geometryRefs'] as Map)['b'], oldInkHash);
      expect((branch['geometryRefs'] as Map)['a'], isA<String>());
    }
    final rollback = snapshot([a, b], conflicts: first.conflicts);
    final second = mergeReaderSnapshots(
      base: first,
      local: first,
      remote: rollback,
      peerId: 'peer',
    ).snapshot;
    expect(retainedText(second, 'a'), containsAll([a.text, localText.text]));
    final stale = snapshot(
      second.annotations[page]!,
      conflicts: first.conflicts,
      generation: second.generation,
    );
    final replay = mergeReaderSnapshots(
      base: second,
      local: stale,
      remote: second,
      peerId: 'peer',
    ).snapshot;
    final reverse = mergeReaderSnapshots(
      base: second,
      local: second,
      remote: stale,
      peerId: 'peer',
    ).snapshot;
    expect(retainedText(replay, 'a'), containsAll([a.text, localText.text]));
    expect(
      canonicalReaderJson(replay.toJson()),
      canonicalReaderJson(reverse.toJson()),
    );
    final concurrent = mergeReaderSnapshots(
      base: base,
      local: left,
      remote: snapshot([a.revise(text: '另一端：修改。', now: now), b]),
      peerId: 'peer',
    ).snapshot;
    expect(concurrent.conflicts.single.kind, 'stroke');
    expect(
      concurrent.annotationsFor(page).whereType<TextAnnotation>(),
      hasLength(1),
    );
    expect(
      retainedText(concurrent, 'a'),
      containsAll([localText.text, '另一端：修改。']),
    );
    expect(
      ReaderSnapshot.fromJson(Map<String, dynamic>.from(replay.toJson()))
          .toJson(),
      replay.toJson(),
    );
    debugPrint(
      'TEXT_MERGE_084 typed_live_record=true concurrent_content_both_retained=true order_refs_cover_text=true old_ink_hash_unchanged=true last_text_geometry_pinned=true stale_peer_union_swap_converges=true',
    );
  });

  test('state capability gates old peers before mutation and resumes exact schema2 pending before offline text exchange', () async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = _RealLoopback();
    final dir = await Directory.systemTemp.createTemp('text-capability-084-');
    SyncServer? server;
    HttpServer? oldServer;
    try {
      final computer = await ReaderStateStore.open(
        statePath: '${dir.path}/computer.json',
      );
      final reader = await ReaderStateStore.open(
        statePath: '${dir.path}/reader.json',
      );
      await reader.addStroke(
        page,
        style: style,
        points: [NormalizedPoint(.2, .3)],
      );
      server = await SyncServer.start(
        source: _EmptySource(),
        readerStore: computer,
        stateDirectory: '${dir.path}/server',
      );
      final port = server.port;
      final client = await SyncClient.pair(
        baseUri: server.uri,
        code: server.createPairingCode(),
        stateDirectory: '${dir.path}/client',
      );
      final clientFile = File('${dir.path}/client/client.json'),
          peersFile = File('${dir.path}/server/peers.json');
      final clientJson =
          jsonDecode(await clientFile.readAsString()) as Map<String, dynamic>;
      final token = clientJson['token'] as String;
      final body = <String, Object?>{
        'requestId': 'existing-schema2-request',
        'baselineId': 'initial',
        'snapshot': reader.snapshot.toJson()..['schemaVersion'] = 2,
      };
      final peersBefore = await peersFile.readAsBytes();
      expect((await rawState(server.uri, token, '/state', body)).status, 426);
      expect(
        (await rawState(server.uri, token, '/ack', {
          'requestId': 'existing-schema2-request',
          'baselineId': 'initial',
        })).status,
        426,
      );
      expect(await peersFile.readAsBytes(), peersBefore);
      expect(computer.snapshot.generation, 0);
      expect(computer.snapshot.mergeReceipts, isEmpty);
      final sent = await rawState(
        server.uri,
        token,
        '/state',
        body,
        capable: true,
      );
      expect(sent.status, 200);
      final generationAfterResponse = computer.snapshot.generation;
      final receipts = computer.snapshot.mergeReceipts.toSet();
      await server.close();
      server = null;
      // Simulate an existing 0.8.3 on-disk pending response without changing
      // request ID/body/fingerprint. It contains ink only, so schema2 is valid.
      final peers =
          jsonDecode(await peersFile.readAsString()) as Map<String, dynamic>;
      final peer = (peers['peers'] as Map)[client.peerId] as Map;
      ((peer['pending'] as Map)['response']
              as Map)['snapshot']['schemaVersion'] =
          2;
      (peer['baseline'] as Map)['schemaVersion'] = 2;
      await peersFile.writeAsString(jsonEncode(peers));
      clientJson['pending'] = {...body, 'response': null};
      await clientFile.writeAsString(jsonEncode(clientJson));
      server = await SyncServer.start(
        source: _EmptySource(),
        readerStore: computer,
        stateDirectory: '${dir.path}/server',
        port: port,
      );
      await client.syncReaderState(reader);
      expect(
        computer.snapshot.generation,
        generationAfterResponse,
        reason: 'server replays the old response, not another merge',
      );
      expect(computer.snapshot.mergeReceipts, receipts);
      expect(
        (jsonDecode(await clientFile.readAsString()) as Map)['pending'],
        isNull,
      );
      final savedPeers = jsonDecode(await peersFile.readAsString()) as Map;
      expect(
        ((savedPeers['peers'] as Map)[client.peerId] as Map)['pending'],
        isNull,
      );
      final annotation = reader.newText(
        text: '离线中文：Hello，世界！',
        anchor: NormalizedPoint(.3, .4),
        argb: 0xff123456,
      );
      await reader.saveText(page, annotation);
      await client.syncReaderState(reader);
      expect(onlyText(computer).text, annotation.text);
      expect(onlyText(reader).id, annotation.id);
      expect(
        (await ReaderStateStore.open(statePath: computer.statePath)).snapshot
            .annotationsFor(page)
            .whereType<TextAnnotation>()
            .single
            .text,
        annotation.text,
      );
      oldServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var stateRequests = 0;
      oldServer.listen((request) async {
        if (request.uri.path == '/state' || request.uri.path == '/ack') {
          stateRequests++;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
      final incompatible = Map<String, dynamic>.from(
        jsonDecode(await clientFile.readAsString()) as Map,
      )..['baseUri'] = 'http://127.0.0.1:${oldServer.port}';
      await clientFile.writeAsString(jsonEncode(incompatible));
      final before = await clientFile.readAsBytes(),
          beforeState = await File(reader.statePath).readAsBytes();
      final oldClient = await SyncClient.open(
        stateDirectory: '${dir.path}/client',
      );
      await expectLater(
        oldClient.syncReaderState(reader),
        throwsA(
          isA<SyncProtocolException>()
              .having((e) => e.status, 'status', 426)
              .having((e) => e.code, 'code', 'reader_upgrade_required'),
        ),
      );
      expect(stateRequests, 0);
      expect(await clientFile.readAsBytes(), before);
      expect(await File(reader.statePath).readAsBytes(), beforeState);
      debugPrint(
        'TEXT_PROTOCOL_084 missing_old_capability_rejected_before_merge_receipt_peer_change=true exact_schema2_pending_replay_ack=true no_duplicate_merge=true unicode_offline_exchange_reopen=true old_server_preflight_no_pending_mutation=true',
      );
    } finally {
      await oldServer?.close(force: true);
      await server?.close();
      await dir.delete(recursive: true);
      HttpOverrides.global = previousHttp;
    }
  });
}
