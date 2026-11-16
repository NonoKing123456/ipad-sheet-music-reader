# library_core

Pure Dart, read-only source catalogue for the sheet music reader. The source tree
contains PDF/JPG/JPEG/PNG/WebP files; folders, duplicate paths and missing entries
remain distinct. This package does not render files or change source content.

```dart
final library = await LibraryCatalog.open(
  rootPath: scoreFolder,
  statePath: applicationStateFile, // Must be outside scoreFolder.
);
final report = await library.rescan();
final matches = library.search('巴赫 老师');
final children = library.listFolder('小提琴');
final filePath = library.absolutePathFor(matches.first);
```

## Integration contract

- `snapshot.entries` includes missing records. Use `availableEntries` or `search`
  for current library listings. `availability` separately identifies deferred or
  unreadable content; a present file is not necessarily readable.
- `entry.id` is stable for a known path and uniquely inferred rename/move.
  `entry.currentRevisionId` changes when content changes. Store annotations
  against **both** IDs, so replacement files do not inherit incompatible marks.
- `ScanResult.inferredMoves` describes evidence. `ambiguities` must be surfaced
  rather than silently merged. A hash does not uniquely identify a library entry.
- Source paths are never used as cross-device IDs. Logical `relativePath` and
  folder paths use `/` separators, including on Windows. `rootPath` and injected
  `platformFileId` are local configuration, not a portable sync manifest.
- Unchanged size/modification time reuses a hash. `rescan(verifyAll: true)` reads
  all ordinary files again and detects changes which preserved both metadata
  values. The first scan reads supported file bytes; it does not decode PDFs.
- An optional `fileAccessProbe` can return `FileAccess.deferred` for known cloud
  placeholders. Those contents are not read, including during `verifyAll`.
  Ordinary/unknown files use normal read semantics. Pure Dart does not detect
  every Windows Cloud Files attribute itself.
- An optional `fileIdentityResolver` can supply a stable OS identity. Without it,
  duplicate-content movements remain ambiguous. The resolver must not return a
  path or hash in place of an OS identity.
- Incomplete enumeration preserves existing records in affected areas, reports
  scan issues and disables content-only move inference. Re-scan to recover.
- Enumeration is authoritative, so filesystem watchers should merely schedule a
  rescan. Changes while the app was closed are found by the next full traversal.

## Persistence and concurrency

The versioned JSON state and `.lock`/`.backup`/temporary files stay outside the
source directory. Each successful scan increments a generation. Concurrent
operations on one state path fail explicitly; a stale instance must `reload()`
before saving. A damaged primary snapshot can recover the previous valid backup
with `storageWarnings`. If neither copy is valid, opening fails rather than
creating an empty library. Backup recovery may lose the most recent generation;
the warning must remain visible until acknowledged by the application.

Revision history stores **metadata, not original file bytes**. If another program
overwrites a PDF, this package cannot restore its old content. Source backup,
user-driven ambiguity resolution, deletion propagation and network sync belong
to later application layers.

## Development

Run `dart pub get`, `dart analyze` and `dart test` in this package. Tests create a
dedicated temporary source tree and never depend on the user's original scores.
