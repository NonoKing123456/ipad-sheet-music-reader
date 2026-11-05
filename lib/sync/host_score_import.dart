import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;

import '../importing/external_import_store.dart';
import '../importing/file_import_bridge.dart';
import '../library/library_controller.dart';

/// The Windows host is the sole authority for catalog and revision identities.
HostScoreImportStore createHostScoreImportStore({
  required LibraryController library,
  required String directory,
  required String collectionId,
}) => HostScoreImportStore(
  directory: directory,
  collectionId: collectionId,
  bindings: () => library.sources,
  copyNewFile: (source, destination, root) async {
    try {
      await FileImportBridge.copyToNewFile(
        source,
        destination,
        trustedRootPath: root,
      );
    } on ImportDestinationExists {
      throw const ScoreImportFailure('import_destination_exists', 409);
    }
  },
  register: (sourceId, relativePath) async {
    await library.refreshImportedSource(sourceId);
    final source = library.sources.where((s) => s.id == sourceId).first;
    final folder = p.posix.dirname(relativePath);
    final entry = source.catalog
        .listFolder(folder == '.' ? '' : folder)
        .entries
        .where(
          (e) =>
              e.relativePath == relativePath && e.status != EntryStatus.missing,
        )
        .first;
    final externalId = collectionEntryId(sourceId, entry.id);
    final ready = await library.prepareForRead(
      externalId,
      entry.currentRevisionId,
    );
    return CatalogItem(
      sourceId: sourceId,
      entryId: externalId,
      revisionId: ready.currentRevisionId,
      relativePath: ready.relativePath,
      length: ready.currentRevision.size,
      hash: ready.currentRevision.contentHash,
      format: p.posix.extension(relativePath).substring(1).toLowerCase(),
    );
  },
);
