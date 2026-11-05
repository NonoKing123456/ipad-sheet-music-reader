import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:reader_state/reader_state.dart';

import '../reader/reader_workspace.dart';

/// Copy completed edits through the existing transaction/merge boundary. The
/// temporary document remains intact until both this write and the save succeed.
Future<void> mirrorImportAnnotations(
  ReaderWorkspace workspace,
  DocumentKey from,
  DocumentKey to,
) async {
  if (from == to) return;
  await workspace.waitForAnnotationWrites();
  await workspace.flushPositions();
  if (workspace.unsavedCount != 0) throw StateError('批注尚未保存，请重试');
  final base = workspace.store.snapshot;
  final pages = Map<PageKey, List<PageAnnotation>>.of(base.annotations);
  for (final entry in base.annotations.entries) {
    if (entry.key.document != from) continue;
    final destination = PageKey(
      entryId: to.entryId,
      revisionId: to.revisionId,
      pageNumber: entry.key.pageNumber,
    );
    final annotations = <String, PageAnnotation>{
      for (final existing in pages[destination] ?? <PageAnnotation>[])
        existing.id: existing,
    };
    for (final annotation in entry.value) {
      final mapped = PageAnnotation.fromJson({
        ...annotation.toJson(),
        'id': sha256
            .convert(
              utf8.encode(
                'local-file-import/${to.entryId}/${to.revisionId}/${annotation.id}',
              ),
            )
            .toString(),
      });
      annotations[mapped.id] = mapped;
    }
    pages[destination] = annotations.values.toList();
  }
  final bookmarks = Map<DocumentKey, ReadingBookmark>.of(base.bookmarks);
  if (base.bookmarks[from] case final ReadingBookmark position) {
    bookmarks[to] = ReadingBookmark(
      document: to,
      pageNumber: position.pageNumber,
      pageCount: position.pageCount,
      updatedUtc: position.updatedUtc,
    );
  }
  await workspace.store.mergeFromPeer(
    base: base,
    remote: base.next(annotations: pages, bookmarks: bookmarks),
    peerId: 'local-file-import',
  );
  workspace.refreshFromStore(force: true);
}
