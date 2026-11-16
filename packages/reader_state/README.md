# reader_state

Pure Dart state for the shared Windows/iPad reader. It never opens or modifies a
PDF/image. Rendering, pointer input, file availability and metadata loading belong
to the Flutter application.

## Annotation store

```dart
final store = await ReaderStateStore.open(statePath: appStateJsonPath);
final page = PageKey(entryId: entry.id, revisionId: revision.id, pageNumber: 1);

// Collect pointer samples in the UI; save only after this stroke ends.
final stroke = await store.addStroke(
  page,
  style: StrokeStyle(
    tool: AnnotationTool.pen,
    argb: 0xff222222,
    widthFraction: 0.003,
  ),
  points: [NormalizedPoint(0.1, 0.2), NormalizedPoint(0.7, 0.2)],
);
await store.eraseStroke(page, stroke.id); // Whole-stroke erase after UI hit-test.
await store.undo(page);
await store.redo(page);
final visible = store.snapshot.strokesFor(page);
```

Points use the unrotated page coordinate space, excluding letterboxing and viewer
chrome. The UI applies crop/rotation/zoom transformations consistently to the
page and marks. Width is relative to the page's shorter dimension; style color
is ARGB32, including alpha. Pen/highlighter compositing is a renderer concern.
No pressure or stylus-only information is required.

Completed operations are serialized and persisted before their returned Future
succeeds. Rapid calls evaluate against the preceding committed state, not a
captured older snapshot. Await/catch every operation and display saving errors.
A failed save does not change in-memory marks or undo history and does not block
later queued operations. `canUndo`/`canRedo` reflect committed state.

Editing history is page-specific and session-only. Reopening/reloading retains
the current visible marks and tombstones, but clears undo/redo stacks. A new edit
clears that page's redo branch. Old revision marks remain separately addressable.

## Set lists

```dart
final list = await store.createSetList('周末演出');
final a = await store.addItem(list.id, entryA.id);
final b = await store.addItem(list.id, entryB.id);
await store.addItem(list.id, entryA.id); // Repeated song: different item ID.
await store.reorderItem(list.id, a.id, 2); // Final visible index.
await store.removeItem(list.id, b.id); // No score file is deleted.
await store.renameSetList(list.id, '正式演出');
```

`snapshot.activeSetLists` and `list.activeItems` exclude deleted records;
`snapshot.setLists`/`list.items` retain tombstones. Reorder uses the final visible
index: moving A to 2 in `[A,B,C]` yields `[B,C,A]`; moving C to 0 yields `[C,A,B]`.
Adapt Flutter's raw `onReorder(oldIndex,newIndex)` by subtracting 1 from newIndex
when it is greater than oldIndex. Stable item IDs disambiguate repeated entries.

## One-action navigation

```dart
final request = NavigationRequest(
  current: ReadingPosition(
    entryId: entryA.id,
    revisionId: revisionA.id,
    pageNumber: lastPage,
    setListItemId: currentItem.id,
  ),
  direction: NavigationDirection.forward,
);
final result = ReaderNavigator.resolve(
  request,
  queue: list.activeItems,
  documents: knownMetadata,
);
```

For `moved`, open `result.position`. A last-page forward action enters only the
next song's page 1, even if it is a one-page image. A first-page backward action
enters the previous song's last page. Overall boundaries do not wrap.

For `metadataRequired`, load `result.requiredEntryId`, then resolve the unchanged
`result.request` again. It retains the original position, so loading does not
consume one foot-pedal press or accidentally advance twice. The UI must manage
pending-request cancellation and changes of active song/list while loading.

For `missingTarget`, hold the original position and show the missing item; no
automatic skipping or same-name substitution occurs. For `staleRevision`, the UI
must explicitly reopen/resolve the new content version; blindly retrying the old
revision request continues to return stale. Old annotation coordinates are never
copied to the new revision. `invalidPosition` identifies mismatched queue or page
metadata. An empty queue means standalone document navigation.

Images use `DocumentMetadata.image`, fixed at one page. PDF metadata uses
`DocumentMetadata.ready` with a positive actual page count. The navigator does no
I/O or persistence. Keyboard repeat suppression remains an input-layer concern.

## Reading position and persistence

```dart
await store.saveReadingPosition(
  document: page.document,
  pageNumber: 2,
  pageCount: actualPageCount,
);
final bookmark = store.readingPosition(page.document);
```

Bookmark writes validate the page range and are separate from navigation; the
caller can throttle them. Entry/revision keys isolate old/new content positions.

State is versioned JSON with temporary commit, a previous valid backup and a
short-lived file lock. A stale second store must `reload()` before writing.
Damaged primary data may recover the previous generation with `storageWarnings`;
the most recent operation may be absent and must not be presented as fully
recovered. Unsupported newer schemas fail instead of silently restoring an older
backup. Keep this state path in the application's user-data directory.

## Public data and future sync boundary

`ReaderSnapshot.toJson()` / `ReaderSnapshot.fromJson()` are public, with public
JSON methods on keys, points, styles, strokes, set lists/items and bookmarks.
`ReaderSnapshot.schemaVersion` identifies the current format. Stable stroke/list/
item IDs, per-record versions, UTC timestamps and deletion records are exposed.
Snapshot generation is a **local write-concurrency token**, not a distributed
version. Set list order is an ordered item list, with list-level version updates.

`ReaderStateStore.mergeFromPeer(base: ..., remote: ..., peerId: ...,
operationId: ...)` performs a three-way merge inside the store's serial queue.
Missing records do not mean deletion. Independently added IDs are retained;
different changes to the same object keep both complete variants in public
`snapshot.conflicts` and the returned `ReaderMergeResult.conflicts`. Canonical
JSON determines a repeatable representative, never wall-clock last-writer wins.
Set-list conflict variants retain complete names/orders, and the representative
list includes every merged live item. UI can inspect/recover variants using the
public model `fromJson` methods. Conflicts are not automatically resolved.

Schema 2 reads schema 1 and persists conflicts plus durable local merge receipts
in the same atomic snapshot. Optional `operationId` protects retrying a protocol
transaction after a crash; use a unique ID for each transaction and never reuse
it for different contents. Import clears session undo/redo history, whose edits
may no longer match the merged records. Visible marks and old revisions remain.
The LAN protocol and per-peer common-baseline handshake live in `library_sync`;
callers must not overwrite private state JSON or treat generation as authority.

## Verification

From this package: `dart pub get`, `dart analyze`, `dart test --reporter expanded`.
Tests use dedicated temporary state directories, never the user's score files.
