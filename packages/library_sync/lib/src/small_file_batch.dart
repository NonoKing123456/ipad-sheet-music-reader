import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'collection.dart';
import 'replica.dart';

/// Protocol v1 framing; larger objects require advertised peer capability. Large objects retain the original streaming path.
abstract final class SmallFileBatchLimits {
  static const count = 64;
  static const legacyObjectBytes = 256 * 1024;
  static const objectBytes = 1024 * 1024;
  static const payloadBytes = 4 * 1024 * 1024;
  static const headerBytes = 16 * 1024;
  static const archiveBytes = payloadBytes + count * (headerBytes + 8) + 8;
  static const prepareBytes = 1024 * 1024;
}

Iterable<List<CatalogItem>> planSmallFileBatches(Iterable<CatalogItem> items,
    {int objectBytes = SmallFileBatchLimits.objectBytes}) sync* {
  var batch = <CatalogItem>[], bytes = 0;
  for (final item in items) {
    if (item.length > objectBytes) continue;
    if (batch.length == SmallFileBatchLimits.count ||
        bytes + item.length > SmallFileBatchLimits.payloadBytes) {
      yield batch;
      batch = [];
      bytes = 0;
    }
    batch.add(item);
    bytes += item.length;
  }
  if (batch.isNotEmpty) yield batch;
}

class SmallFileBatchFrame {
  const SmallFileBatchFrame(this.entryId, this.sourceId, this.revisionId,
      this.status, this.item, this.bytes);
  final String entryId, sourceId, revisionId;
  final int status;
  final CatalogItem? item;
  final Uint8List bytes;
}

Uint8List _integers(int first, [int? second]) {
  final data = ByteData(second == null ? 4 : 8)..setUint32(0, first);
  if (second != null) data.setUint32(4, second);
  return data.buffer.asUint8List();
}

/// One bounded object is buffered and checked before its frame is emitted.
/// A source read failure becomes an error frame, so following files still work.
Stream<List<int>> encodeSmallFileBatch(
    List<CatalogItem> items, CollectionLibrarySource source,
    {SyncCancellation? cancellation}) async* {
  if (items.length > SmallFileBatchLimits.count ||
      items.fold(0, (sum, item) => sum + item.length) >
          SmallFileBatchLimits.payloadBytes) {
    throw const FormatException('Batch exceeds limits.');
  }
  yield [83, 82, 66, 49]; // SRB1
  yield _integers(items.length);
  for (final item in items) {
    cancellation?.check();
    var bytes = Uint8List(0), status = 200;
    try {
      if (item.hash == null || item.length > SmallFileBatchLimits.objectBytes)
        throw const FormatException('Not a small resolved object.');
      final builder = BytesBuilder(copy: false);
      await for (final chunk
          in await source.openSelectedObject(item.entryId, item.revisionId)) {
        cancellation?.check();
        if (builder.length + chunk.length > item.length)
          throw const LibraryContentIntegrityException();
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
      if (bytes.length != item.length ||
          sha256.convert(bytes).toString() != item.hash) {
        throw const LibraryContentIntegrityException();
      }
    } catch (error) {
      if (error is SyncCancelled) rethrow;
      status = 409;
      bytes = Uint8List(0);
    }
    var header = utf8.encode(jsonEncode({
      'entryId': item.entryId,
      'sourceId': item.sourceId,
      'revisionId': item.revisionId,
      'status': status,
      if (status == 200) 'item': item.toJson()
    }));
    if (header.length > SmallFileBatchLimits.headerBytes) {
      status = 413;
      bytes = Uint8List(0);
      header = utf8.encode(jsonEncode({
        'entryId': item.entryId,
        'sourceId': item.sourceId,
        'revisionId': item.revisionId,
        'status': status
      }));
      if (header.length > SmallFileBatchLimits.headerBytes)
        throw const FormatException('Batch identity too large.');
    }
    yield _integers(header.length, bytes.length);
    yield header;
    if (bytes.isNotEmpty) yield bytes;
  }
}

class _BatchReader {
  _BatchReader(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  List<int> current = const [];
  int offset = 0, consumed = 0;
  Future<Uint8List> read(int length) async {
    if (length < 0 ||
        length > SmallFileBatchLimits.objectBytes ||
        consumed + length > SmallFileBatchLimits.archiveBytes)
      throw const FormatException('Invalid batch size.');
    final output = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (offset == current.length) {
        if (!await iterator.moveNext())
          throw const FormatException('Truncated batch.');
        current = iterator.current;
        offset = 0;
        continue;
      }
      final count = (length - written).clamp(0, current.length - offset);
      output.setRange(written, written + count, current, offset);
      offset += count;
      written += count;
    }
    consumed += length;
    return output;
  }

  Future<void> finish() async {
    if (offset < current.length)
      throw const FormatException('Trailing batch data.');
    while (await iterator.moveNext()) {
      if (iterator.current.isNotEmpty)
        throw const FormatException('Trailing batch data.');
    }
  }
}

/// Framing is bounded independently of untrusted JSON lengths. Only the
/// current <=256 KiB payload is held; consumers commit files one at a time.
Stream<SmallFileBatchFrame> decodeSmallFileBatch(Stream<List<int>> stream,
    {SyncCancellation? cancellation}) async* {
  final reader = _BatchReader(stream);
  try {
    if (utf8.decode(await reader.read(4)) != 'SRB1')
      throw const FormatException('Unknown batch format.');
    final count = ByteData.sublistView(await reader.read(4)).getUint32(0);
    if (count > SmallFileBatchLimits.count)
      throw const FormatException('Too many batch records.');
    var payloadBytes = 0;
    for (var index = 0; index < count; index++) {
      cancellation?.check();
      final prefix = ByteData.sublistView(await reader.read(8));
      final headerLength = prefix.getUint32(0), length = prefix.getUint32(4);
      if (headerLength == 0 ||
          headerLength > SmallFileBatchLimits.headerBytes ||
          length > SmallFileBatchLimits.objectBytes ||
          payloadBytes + length > SmallFileBatchLimits.payloadBytes) {
        throw const FormatException('Batch record exceeds limits.');
      }
      final header = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(await reader.read(headerLength))) as Map);
      final bytes = await reader.read(length);
      payloadBytes += length;
      final status = header['status'] as int;
      final item = status == 200
          ? CatalogItem.fromJson(
              Map<String, dynamic>.from(header['item'] as Map))
          : null;
      if (status != 200 && length != 0)
        throw const FormatException('Error frame contains content.');
      yield SmallFileBatchFrame(
          header['entryId'] as String,
          header['sourceId'] as String,
          header['revisionId'] as String,
          status,
          item,
          bytes);
    }
    await reader.finish();
  } finally {
    await reader.iterator.cancel();
  }
}
