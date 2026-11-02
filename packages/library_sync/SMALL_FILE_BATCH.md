# Bounded small-file transfer, protocol v1

Small files use negotiated microbatches. Large files and older computers keep
the existing `/v2/prepare` and `/v2/object` routes. No library ZIP is created.

- At most 64 selected objects, 4 MiB of object bytes per batch.
- An individual small object is at most 1 MiB after size negotiation; a record header is at most
  16 KiB. The complete framed download is bounded to 5,243,400 bytes.
- Server and foreground decoder retain one bounded object payload at a time.
  Native URLSession archives live on disk, with at most six active system tasks;
  the serial native extractor holds one <=1 MiB payload at a time.
- Prepared metadata replies are at most 1 MiB. The server retains at most 128
  expiring plans and at most 8 MiB of serialized plan metadata. The native Dart
  adapter caches metadata for at most 16 batches. Catalogue/VM overhead is
  separate from these transport buffer bounds.
- Existing disk preflight reserves staged content plus atomic import copies
  and a 64 MiB margin; six maximum batch archives fit inside that margin.

## Wire exchange

`GET /v2/transfer-capabilities` advertises
`{"smallFileBatch":1,"smallFileObjectBytes":1048576}`. A 31 peer without the
size field retains the 256 KiB grouping limit; only a validated advertised
limit is used by the foreground/native planner. HTTP 404 selects the original
protocol. The original routes remain available to old
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

## Selected catalogue preparation (+32)

`CollectionBatchPreparation` is optional. A real catalogue-backed host groups
at most 64 selected revisions by source, yields an in-progress scan through the
existing foreground queue, opens one worker catalogue and writer lease per
actual transfer batch, hashes only selected cold files, and makes one immutable
catalogue/combined-view publication. Bad files are isolated; IDs, revision
references, unavailable siblings and missing tombstones remain. Known-ready
files retain the stat-validated zero-hash, zero-catalogue-write fast path.
Providers without this interface and old peers retain individual preparation.

This does not eliminate the full catalogue commit: the 4 MiB payload limit
means 300–900 KiB files form roughly 4–10-item batches rather than 64-item
batches. There is no unbounded preparation cache or background whole-library
hashing. Source-path, publication-generation and atomic-import guards remain.

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


## +32 large-catalogue synthetic measurements

`tool/catalog_batch_prepare_benchmark.dart` runs actual catalogue, protocol and
replica storage code over Windows loopback with generated files and a warmed
replica snapshot. It does not time Flutter UI, iPad, Wi-Fi or background
scheduling. The catalogue contains 53,461 entries (31,165 active and 22,296
missing tombstones), initially 8,638 ready and 22,527 cold, and 32,113,693 bytes.
Selected files span 300–900 KiB. Old cold runs use only 32 selections to avoid
writing about16GB for a redundant512-item comparison.

| Case | Selected | Total seconds | Source prepare seconds | Worker catalogue reads/writes | Hashes | Prepare/object requests | Resolution checkpoints |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| old31 cold | 32 | 63.948 | 39.378 | 32/32 | 32 | 64 | 32 |
| bulk32 cold | 32 | 21.880 | 5.563 | 5/5 | 32 | 10 | 5 |
| old31 ready | 32 | 15.014 | 0.041 | 0/0 | 0 | 64 | 32 |
| bulk32 ready | 32 | 14.918 | 0.041 | 0/0 | 0 | 10 | 5 |
| bulk32 cold | 512 | 127.802 | 89.346 | 81/81 | 512 | 162 | 81 |

The common initial host load is excluded from worker I/O counters; catalogue
paging remains23 requests in each run. Cold32 catalogue reads/writes each
drop from approximately1,028MB to160.6MB. New512 still writes approximately
2,602.6MB across81 actual batches, hashes only the selected314,511,360 bytes,
and preserves all53,461 entries and22,296 missing records. These are measured
sample sizes and byte counts, not a64x claim or projected iPad throughput.
