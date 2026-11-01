import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:reader_state/reader_state.dart';
import 'package:score_reader/library/windows_file_identity.dart';

void main() {
  test('real Windows metadata-only source retains identity ink and set-list references through rename and folder move with zero content hash bytes', () async {
    final dir = await Directory.systemTemp.createTemp('windows-source-id-');
    try {
      final root = await Directory('${dir.path}/scores').create();
      final folder = await Directory('${root.path}/foo').create();
      final file = await File('${folder.path}/a.png')
          .writeAsBytes([1, 2, 3, 4]);
      var contentProbes = 0;
      Future<LibraryCatalog> open() => LibraryCatalog.open(
        rootPath: root.path,
        statePath: '${dir.path}/catalog.json',
        fileIdentityResolver: windowsFileIdentity,
        fileAccessProbe: (_, _) async {
          contentProbes++;
          return FileAccess.ordinary;
        },
      );
      final catalog = await open();
      await catalog.rescan(metadataOnly: true);
      final original = catalog.snapshot.entries.single;
      expect(original.platformFileId, isNotNull);
      expect(
        original.platformFileId,
        await windowsFileIdentity(file.path, await file.stat()),
      );
      final globalId = collectionEntryId('new-source', original.id);
      final page = PageKey(
        entryId: globalId,
        revisionId: original.currentRevisionId,
        pageNumber: 1,
      );
      final ink = await ReaderStateStore.open(
        statePath: '${dir.path}/ink.json',
      );
      await ink.addStroke(
        page,
        style: StrokeStyle(
          tool: AnnotationTool.pen,
          argb: 0xff123456,
          widthFraction: .004,
        ),
        points: [NormalizedPoint(.2, .3)],
      );
      final list = await ink.createSetList('keep');
      await ink.addItem(list.id, globalId);
      await file.rename('${folder.path}/renamed.png');
      await catalog.rescan(metadataOnly: true);
      expect(catalog.snapshot.entries.single.id, original.id);
      expect(catalog.snapshot.entries.single.relativePath, 'foo/renamed.png');
      await folder.rename('${root.path}/bar');
      await catalog.rescan(metadataOnly: true);
      final moved = catalog.snapshot.entries.single;
      expect(moved.id, original.id);
      expect(moved.currentRevisionId, original.currentRevisionId);
      expect(moved.platformFileId, original.platformFileId);
      expect(moved.relativePath, 'bar/renamed.png');
      expect(moved.currentRevision.contentHash, isNull);
      expect(catalog.contentHashBytesRead, 0);
      expect(catalog.contentHashOperations, 0);
      expect(contentProbes, 0);
      final reopened = await open();
      expect(reopened.snapshot.entries.single.id, original.id);
      final restored = await ReaderStateStore.open(statePath: ink.statePath);
      expect(
        restored.snapshot.strokesFor(
          PageKey(
            entryId: collectionEntryId('new-source', moved.id),
            revisionId: moved.currentRevisionId,
            pageNumber: 1,
          ),
        ),
        hasLength(1),
      );
      expect(
        restored.snapshot.setListById(list.id)!.activeItems.single.entryId,
        globalId,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
