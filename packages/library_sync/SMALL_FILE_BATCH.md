# Bounded small-file transfer, protocol v1

Small files use negotiated microbatches. Large files and older computers keep
the existing `/v2/prepare` and `/v2/object` routes. No library ZIP is created.

- At most 64 selected objects, 4 MiB of object bytes per batch.
- An individual small object is at most 256 KiB; a record header is at most
  16 KiB. The complete framed download is bounded to 5,243,400 bytes.
- Server and foreground decoder retain one bounded object payload at a time.
  Native URLSession archives live on disk, with at most six active system tasks;
  the serial native extractor holds one <=256 KiB payload at a time.
- Prepared metadata replies are at most 1 MiB. The server retains at most 128
  expiring plans and at most 8 MiB of serialized plan metadata. The native Dart
  adapter caches metadata for at most 16 batches. Catalogue/VM overhead is
  separate from these transport buffer bounds.
- Existing disk preflight reserves staged content plus atomic import copies
  and a 64 MiB margin; six maximum batch archives fit inside that margin.

## Wire exchange

`GET /v2/transfer-capabilities` advertises `{"smallFileBatch":1}`. HTTP 404
selects the original protocol. The original routes remain available to old
clients on the new Windows server.

`POST /v2/batch-prepare` takes `items` with explicit `sourceId`, `entryId` and
`revisionId`. Each response record includes its original index and either
resolved immutable metadata or an isolated failure status. Plans are bound to
the authenticated peer and expire after 30 minutes. They never grant access
without the existing Bearer credential.

`GET /v2/batch-object?batchId=...&mask=...` transfers only the accepted members.
`mask` is **lowercase hexadecimal text**, at most 16 digits: bit i selects the
original request's ith record. Dart uses BigInt and Swift uses UInt64; neither
serializes the mask as a JSON number. Scope rules are checked after prepare
and again before import. Native resume receives the latest selection and
reprepares a paused batch's mask.

The stream is `SRB1`, a big-endian uint32 record count, then for every record:

```
uint32 headerBytes | uint32 payloadBytes | UTF-8 JSON header | raw payload
```

Successful headers include source/entry/revision, status 200 and complete
immutable metadata. Error headers have no payload. Count, byte limits,
identity, revision, length and SHA-256 are checked independently per file.
Source read failures and bad payload hashes preserve other valid frames;
only failed files retry through the individual route. Malformed framing falls
back for uncommitted members. Expired plans are reprepared by native callbacks
(at most two plan retries), or fall back individually in the foreground client.

## Durability and background execution

The entire selected plan is persisted before starting the six-task native
window. A persisted leader/members mapping advances prepare, download and
extraction through URLSession callbacks while Dart is suspended. A group
checkpoint appends all member transitions with one journal synchronization.
The adapter fetches companion metadata once per microbatch; Dart writes one
resolution checkpoint before importing its members and acknowledges up to 32
completed files in one native journal operation.

Each file still passes the existing incoming SHA/length check, temporary-file
flush and atomic rename. A staged file is not a readable success. Cancellation,
storage failure, app relaunch and a damaged member retain independently
verified files. Existing v30 queue and individual journal records decode with
the same schema; all new grouping fields are optional.

Background execution remains subject to iPadOS scheduling. User force-quit
cancels OS transfers; reopening reconciles the durable plan. Current endpoints
do not advertise byte ranges, so a failed bounded archive may restart in full.

## Synthetic Windows measurements

Both server and client ran on Windows loopback with generated files, private
temporary directories and the same toolchain. This is not iPad, Wi-Fi or
lock-screen testing. `tool/small_file_transfer_benchmark.dart --legacy` selects
the original algorithm; without it, the client negotiates microbatches.

| Files | Bytes/file | Added wait/request | Old / new seconds | Old / new transfer requests | Old / new metadata fsync |
| --- | ---: | ---: | ---: | ---: | ---: |
| 512 | 1,024 | 0 ms | 8.984 / 5.756 | 1,024 / 16 | 512 / 8 |
| 512 | 32,768 | 0 ms | 8.352 / 4.970 | 1,024 / 16 | 512 / 8 |
| 128 | 1,024 | 20 ms | 10.561 / 1.318 | 256 / 4 | 128 / 2 |
| 128 | 32,768 | 20 ms | 9.787 / 1.355 | 256 / 4 | 128 / 2 |

The tool samples whole-process RSS every 5 ms. Across these runs, RSS growth
was 11.5–22.1 MB for the old path and 14.7–62.9 MB for microbatches, including
both server/client, Dart allocation and heap retention. This is a bounded
buffer design with higher observed transient process memory, not a claim of
lower memory use. The limits above and framing rejection tests constrain
transport payloads independently of file count.

The Foundation-only compatibility smoke uses the real Swift schema:

```sh
swiftc ios/Runner/BackgroundDownloadBridge.swift tool/background_queue_schema_smoke.swift -o "$RUNNER_TEMP/background-queue-schema-smoke"
"$RUNNER_TEMP/background-queue-schema-smoke"
```

Expected marker:
`BACKGROUND_QUEUE_SCHEMA_SMOKE_OK legacy_jobs=3 legacy_journal=1 batch_checkpoint=1`.
Windows cannot execute this Swift smoke or compile the iOS bridge; both remain
for the single merged Mac CI build. Actual iPad lock-screen performance is
not inferred from these tests.
