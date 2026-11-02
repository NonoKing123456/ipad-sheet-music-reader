import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:library_sync/library_sync.dart';
import 'package:score_reader/library/library_controller.dart';

void main() {
  test('host groups selected sources, publishes each once and keeps ready requests read-only', () async {
    final temporary = await Directory.systemTemp.createTemp('host-bulk32-');
    final first = await Directory('${temporary.path}/first').create();
    final second = await Directory('${temporary.path}/second').create();
    for (var i = 0; i < 4; i++) {
      await File('${first.path}/$i.pdf').writeAsString('first synthetic $i');
    }
    await File('${second.path}/other.pdf').writeAsString('second synthetic');
    final library = LibraryController(
      dataDirectory: Directory('${temporary.path}/state'),
      watchSource: false,
    );
    try {
      await library.initialize();
      await library.selectRoot(first.path, metadataOnly: true);
      await library.addSource(second.path);
      for (
        var i = 0;
        i < 200 && library.snapshot!.availableEntries.length != 5;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(library.snapshot!.availableEntries, hasLength(5));
      final before = library.snapshot!;
      final chosen = before.availableEntries
          .where((entry) => !entry.relativePath.endsWith('3.pdf'))
          .toList();
      final revisions = {
        for (final entry in chosen) entry.id: entry.currentRevisionId,
      };
      final generations = {
        for (final source in library.sources)
          source.id: source.catalog.snapshot.generation,
      };
      var notifications = 0;
      library.addListener(() => notifications++);
      final source = CatalogCollectionSource(
        id: 'host-bulk32',
        bindings: () => library.sources,
        prepareEntry: library.prepareForRead,
        prepareEntries: library.prepareManyForRead,
      );
      final ready = await source.prepareMany(revisions);
      expect(ready.keys.toSet(), revisions.keys.toSet());
      expect(notifications, 2);
      for (final source in library.sources) {
        expect(source.catalog.snapshot.generation, generations[source.id]! + 1);
      }
      expect(
        before.availableEntries.every(
          (entry) => entry.currentRevision.contentHash == null,
        ),
        isTrue,
      );
      final sibling = before.availableEntries.singleWhere(
        (entry) => entry.relativePath.endsWith('3.pdf'),
      );
      expect(
        identical(library.snapshot!.entryById(sibling.id), sibling),
        isTrue,
      );
      final bytes = {
        for (final source in library.sources)
          source.id: await File(source.catalog.statePath).readAsBytes(),
      };
      notifications = 0;
      expect(
        (await source.prepareMany(revisions)).keys.toSet(),
        revisions.keys.toSet(),
      );
      expect(notifications, 0);
      for (final source in library.sources) {
        expect(
          await File(source.catalog.statePath).readAsBytes(),
          bytes[source.id],
        );
      }
      expect(await source.prepareMany({chosen.first.id: 'stale'}), isEmpty);
    } finally {
      library.dispose();
      await temporary.delete(recursive: true);
    }
  });
}
