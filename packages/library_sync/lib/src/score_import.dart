import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'collection.dart';
import 'manifest.dart';
import 'storage.dart';

/// The peer names a registered logical source, never a host filesystem path.
class ScoreImportRequest {
  ScoreImportRequest(
      {required this.operationId,
      required this.sourceId,
      required this.relativeFolder,
      required this.fileName,
      required this.length,
      required this.hash}) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(operationId) ||
        sourceId.isEmpty ||
        sourceId.length > 128 ||
        length <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        relativeFolder.length > 4096) {
      throw const FormatException('Invalid score import.');
    }
    validatePortablePath(relativeFolder, folder: true);
    for (final segment in [
      ...relativeFolder.split('/').where((s) => s.isNotEmpty),
      fileName
    ]) {
      if (segment.isEmpty ||
          segment.length > 255 ||
          RegExp(r'[\x00-\x1f<>:"/\\|?*]').hasMatch(segment) ||
          segment.endsWith('.') ||
          segment.endsWith(' ') ||
          RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])(?:\.|$)',
                  caseSensitive: false)
              .hasMatch(segment)) {
        throw const FormatException('Invalid destination name.');
      }
    }
    validatePortablePath(fileName);
    final extension = p.posix.extension(fileName).toLowerCase();
    if (extension.length < 2 ||
        !supportedFormats.contains(extension.substring(1))) {
      throw const FormatException('Unsupported score format.');
    }
  }
  final String operationId, sourceId, relativeFolder, fileName, hash;
  final int length;
  String get relativePath =>
      relativeFolder.isEmpty ? fileName : '$relativeFolder/$fileName';
  Map<String, Object?> toJson() => {
        'operationId': operationId,
        'sourceId': sourceId,
        'relativeFolder': relativeFolder,
        'fileName': fileName,
        'length': length,
        'hash': hash
      };
  factory ScoreImportRequest.fromJson(Map<String, dynamic> j) =>
      ScoreImportRequest(
          operationId: j['operationId'] as String,
          sourceId: j['sourceId'] as String,
          relativeFolder: j['relativeFolder'] as String,
          fileName: j['fileName'] as String,
          length: j['length'] as int,
          hash: j['hash'] as String);
}

class ScoreImportReceipt {
  const ScoreImportReceipt(
      {required this.operationId,
      required this.collectionId,
      required this.source,
      required this.item});
  final String operationId, collectionId;
  final LibrarySourceInfo source;
  final CatalogItem item;
  Map<String, Object?> toJson() => {
        'protocol': 1,
        'operationId': operationId,
        'collectionId': collectionId,
        'source': source.toJson(),
        'item': item.toJson()
      };
  factory ScoreImportReceipt.fromJson(Map<String, dynamic> j) {
    if (j['protocol'] != 1)
      throw const FormatException('Invalid import receipt.');
    final receipt = ScoreImportReceipt(
        operationId: j['operationId'] as String,
        collectionId: j['collectionId'] as String,
        source: LibrarySourceInfo.fromJson(asMap(j['source'])),
        item: CatalogItem.fromJson(asMap(j['item'])));
    if (receipt.source.id != receipt.item.sourceId ||
        receipt.item.missing ||
        receipt.item.hash == null ||
        receipt.collectionId.isEmpty) {
      throw const FormatException('Invalid imported identity.');
    }
    return receipt;
  }
}

class ScoreImportFailure implements Exception {
  const ScoreImportFailure(this.code, this.status);
  final String code;
  final int status;
}

typedef ScoreImportCopy = Future<void> Function(
    String source, String destination, String trustedRoot);

/// Receipts and staged bytes live in application state, outside every source.
/// The server serializes calls. An uncertain interrupted create fails closed:
/// only a durable `created` record may resume indexing an already-created file.
class HostScoreImportStore {
  HostScoreImportStore(
      {required this.directory,
      required this.collectionId,
      required this.bindings,
      required this.copyNewFile,
      required this.register});
  final String directory, collectionId;
  final List<CatalogSourceBinding> Function() bindings;
  final ScoreImportCopy copyNewFile;
  final Future<CatalogItem> Function(String sourceId, String relativePath)
      register;

  CatalogSourceBinding _source(String id) {
    for (final source in bindings()) {
      if (source.id == id && source.online) return source;
    }
    throw const ScoreImportFailure('import_source_unavailable', 503);
  }

  Future<(CatalogSourceBinding, String, String)> _destination(
      ScoreImportRequest request) async {
    final source = _source(request.sourceId);
    final root = p.normalize(p.absolute(source.catalog.rootPath));
    final folder = p.joinAll([
      root,
      ...request.relativeFolder.split('/').where((s) => s.isNotEmpty)
    ]);
    final target = p.join(folder, request.fileName);
    assertSafePath(root, target);
    if (!p.equals(root, await Directory(root).resolveSymbolicLinks()) ||
        !p.equals(folder, await Directory(folder).resolveSymbolicLinks()) ||
        await FileSystemEntity.type(folder, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const ScoreImportFailure('import_source_unavailable', 503);
    }
    if (p.equals(root, directory) || p.isWithin(root, directory)) {
      throw const FormatException('Import state must be outside source.');
    }
    return (source, root, target);
  }

  Future<ScoreImportReceipt> receive(String peerId, ScoreImportRequest request,
      Stream<List<int>> bytes) async {
    final (source, root, target) = await _destination(request);
    final key = sha256
        .convert(utf8.encode('$peerId/${request.operationId}'))
        .toString();
    final recordPath = p.join(directory, '$key.json');
    final record = await readJson(recordPath);
    final fingerprint =
        sha256.convert(utf8.encode(jsonEncode(request.toJson()))).toString();
    final rootKey = Platform.isWindows ? root.toLowerCase() : root;
    if (record != null &&
        (record['fingerprint'] != fingerprint ||
            record['root'] != rootKey ||
            record['collectionId'] != collectionId)) {
      throw const ScoreImportFailure('import_operation_conflict', 409);
    }
    assertSafePath(directory, directory);
    await Directory(directory).create(recursive: true);
    final staged = File(p.join(directory, '$key.upload'));
    assertSafePath(directory, staged.path);
    final sink = staged.openWrite();
    var length = 0;
    try {
      await for (final chunk in bytes) {
        length += chunk.length;
        if (length > request.length)
          throw const ScoreImportFailure('import_integrity', 422);
        sink.add(chunk);
        await sink.flush();
      }
      await sink.close();
      if (length != request.length ||
          (await sha256.bind(staged.openRead()).first).toString() !=
              request.hash) {
        throw const ScoreImportFailure('import_integrity', 422);
      }
      if (record?['receipt'] != null) {
        return ScoreImportReceipt.fromJson(asMap(record!['receipt']));
      }
      final (_, currentRoot, currentTarget) = await _destination(request);
      if (!p.equals(root, currentRoot) || !p.equals(target, currentTarget)) {
        throw const ScoreImportFailure('import_operation_conflict', 409);
      }
      final next = <String, Object?>{
        'schema': 1,
        'collectionId': collectionId,
        'fingerprint': fingerprint,
        'root': rootKey,
        'state': 'creating'
      };
      if (record?['state'] != 'created') {
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const ScoreImportFailure('import_destination_exists', 409);
        }
        await writeJson(recordPath, next);
        await copyNewFile(staged.path, target, root);
        next['state'] = 'created';
        await writeJson(recordPath, next);
      } else {
        next['state'] = 'created';
      }
      await _destination(request);
      if (await File(target).length() != request.length ||
          (await sha256.bind(File(target).openRead()).first).toString() !=
              request.hash) {
        throw const ScoreImportFailure('import_integrity', 422);
      }
      final item = await register(request.sourceId, request.relativePath);
      final (_, registeredRoot, registeredTarget) = await _destination(request);
      if (!p.equals(root, registeredRoot) ||
          !p.equals(target, registeredTarget)) {
        throw const ScoreImportFailure('import_operation_conflict', 409);
      }
      if (item.sourceId != request.sourceId ||
          item.relativePath != request.relativePath ||
          item.hash != request.hash ||
          item.length != request.length ||
          item.missing) {
        throw const ScoreImportFailure('import_integrity', 422);
      }
      final receipt = ScoreImportReceipt(
          operationId: request.operationId,
          collectionId: collectionId,
          source: LibrarySourceInfo(source.id, source.name),
          item: item);
      await writeJson(recordPath,
          {...next, 'state': 'complete', 'receipt': receipt.toJson()});
      return receipt;
    } finally {
      await sink.close().catchError((Object _) {});
      if (await staged.exists()) await staged.delete();
    }
  }
}
