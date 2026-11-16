# library_sync

Pure Dart native-app LAN data transfer. No website, discovery, QR, cloud service
or iPad permission/UI implementation is included. Source score files are read
only; tests use dedicated temporary fixtures.

```dart
final source = CatalogLibrarySource(catalog: catalog, libraryId: persistedId);
final server = await SyncServer.start(
  source: source,
  readerStore: windowsReaderStore,
  stateDirectory: serverPrivateDirectory,
  // Default is loopback. Supply InternetAddress.anyIPv4 explicitly for LAN.
);
final code = server.createPairingCode(); // Display locally; valid for 2 minutes.
// Enter the Windows LAN IP and server.port on the other native application.
final client = await SyncClient.pair(
  baseUri: windowsLanUri,
  code: enteredCode,
  stateDirectory: clientPrivateDirectory,
);
final replica = await ReplicaLibraryView.open(rootDirectory: replicaDirectory);
final result = await client.syncLibrary(replica);
if (result.status == LibrarySyncStatus.complete) {
  final entries = replica.search('巴赫');
  final path = replica.absolutePathFor(entries.first);
}
final merged = await client.syncReaderState(ipadReaderStore);
// Display merged.conflicts; variants are complete public JSON model records.
await server.close();
```

`syncLibrary` accepts optional `onProgress: (progress) { ... }`. Its immutable
`LibrarySyncProgress` has `phase` (`LibrarySyncPhase.transferring`, `committing`,
`complete`), `processed` and `total`. The first event follows successful manifest
validation, with zero processed and the number of non-missing targets. Each
reused verified object or successfully received/verified object advances the
count. These are object counts, not byte percentages. `committing` may already
show total/total; only `complete` means the manifest was committed. No complete
event is emitted on failed/cancelled operations. Before the manifest arrives,
the caller should show indeterminate loading rather than inventing a total.

Progress is observation only. Callback invocation order follows event order;
callbacks may return `FutureOr<void>`, but the transfer does not await their
completion. Synchronous and asynchronous errors are consumed and do not change
the sync result. A callback that never finishes cannot hold up transfer or
cancellation. Async callback continuations may outlive the operation; UI should
scope them to its current operation. Calling `cancellation.cancel()` from an
observer still requests cancellation normally. Progress adds no content reads.

`LibrarySyncResult.failure` adds a safe `LibrarySyncFailure?` category while
preserving `status`, `downloaded`, `error` and existing constructor calls. Results
produced by `syncLibrary` use null on success, otherwise `differentLibrary`,
`sourceNotReady`, `connection` (including timeout/HTTP stream interruption),
`authentication` (HTTP 401/403), `integrity` (received object hash/length),
`localStorage` (local filesystem failure), `cancelled` or `unknown`. Generic
manifest/protocol format errors remain unknown, not content-integrity failures.
Classification uses types/status/recognized codes, never exception-message
parsing. The error text is fixed and contains no raw path, token or peer message.

`CatalogLibrarySource` throws `LibrarySourceNotReady` for deferred/unreadable
available entries. Custom sources can throw the same type. The server returns
only HTTP 503 with the allowlisted `source_not_ready` code and a fixed safe
message. Unrecognized/malformed peer error codes remain unknown. Existing peers
without the code remain compatible but may only report unknown. Server errors
never echo source exceptions, including a source's `SyncProtocolException` text.

`libraryId` is an application-persisted stable ID, never a Windows path. The
server state, client state, replica and reader-state files belong in separate
app-private locations outside the source. Keep the server port stable between
launches (pass `port`) and use a reachable LAN origin, not `0.0.0.0`. Pairing
credentials persist locally; reopen with `SyncClient.open(stateDirectory: ...)`.
One owner at a time may use each sync state directory. Await each operation and
surface failures. A client directory represents one server peer; do not copy it
to create another device. Every new device must pair independently.

HTTP is private LAN transport without eavesdropping confidentiality. The
short-lived pairing code has five attempts and one successful use. Other routes
require a random 32-byte Bearer token, kept out of URLs and logs. Use trusted
Wi-Fi. Never expose this listener as a public internet service. No automatic
server startup or permission prompts are performed by this package.

The whitelist manifest excludes source roots and OS file IDs. Available deferred
or unreadable source entries prevent complete sync; hydrate/repair them and retry
rather than presenting incomplete content as a full offline library. Missing
source records propagate as missing, without deleting cached objects. Content
downloads use private temporary files, bounded declared length and SHA-256. A
failed transfer leaves the last committed manifest and old revisions intact;
retry reuses verified complete objects. Logical paths only affect browsing;
object storage uses a hash of entry/revision/content identity. Links and root
escapes are rejected. App-private directories must not be concurrently modified
by untrusted processes (filesystem path checks cannot eliminate external races).

`ReplicaLibraryView` exposes core-shaped `snapshot`, `search`, `listFolder` and
`absolutePathFor` methods. It never rescans or invents entry IDs. Detected corrupt
bytes are marked unreadable until retry repairs them. Old entry objects can still
address their retained revisions. The cache is not automatically garbage-collected.

Normal `open` and unchanged repeat/incremental sync reuse persisted verification
records when expected hash/length and the local file's size, modification time
and mode match. Downloads are hashed while receiving; committing their manifest
does not reread those bytes. New, changed, missing or invalid verification records
require verification; unknown records never grant ready status. Records share the
manifest's atomic file and backup. Legacy manifests without records read each
object once and persist records for subsequent warm opens. Completed objects
from an interrupted, uncommitted manifest may require one local verification
after a process restart. Ordinary opens inspect metadata without reading every
score's contents.

Use `ReplicaLibraryView.open(rootDirectory: ..., verifyAll: true)` or
`await replica.verifyAll()` for a full integrity check. A same-size edit which
preserves modification time and mode can evade the normal fingerprint check;
explicit full verification detects it. This is a startup performance tradeoff for
app-private immutable objects, not protection from local tampering.
`replica.verificationStats` reports cumulative actual `localHashOperations` and
`localHashBytesRead`, separately from `downloadObjectsVerified` and
`downloadBytesReceived` (incoming content chunks consumed, including failed
transfers). `cachedObjectsReused` counts metadata-only cache hits. Statistics are
per view, include its initial open and are not persisted. Full verification
reloads the current manifest under the directory lease before updating records.

Reader-state sync uses a durable per-peer common baseline and pending response,
then commits client merge and confirms the baseline. Atomic merge receipts make
replays safe after a process stops between those steps. Failed or cancelled runs
retain pending state; call the same operation again. Client edits while waiting
are merged against its sent snapshot. Same-object conflicts preserve both full
variants in reader schema 2. They are unresolved and exposed to UI; no timestamp
last-writer overwrite or automatic conflict resolution occurs. Reader merge
clears session undo/redo stacks because imported edits can invalidate history;
visible marks, tombstones and conflicts persist.

`ioTimeout` (30 seconds by default) bounds connection/header waits and idle reads;
`SyncCancellation` closes an active client connection and prevents manifest or
baseline promotion after cancellation. Whole objects retry from the beginning.
JSON messages default to 16 MiB; raise `maxJsonBytes` consistently on both ends if
needed. `afterResponse` and `afterMerge` are optional deterministic test/progress
hooks; throwing leaves a retryable pending transaction.

Run `dart pub get`, `dart analyze`, and `dart test --reporter expanded` in this
directory. Windows loopback protocol tests do not prove iPad permissions,
background behavior, storage capacity, Wi-Fi performance or real-device reading.
