import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Fixture {
  _Fixture(this.root, this.view, this.manifest, this.bytes);
  final String root;
  final ReplicaLibraryView view;
  final SyncManifest manifest;
  final Map<String, List<int>> bytes;
  int get totalBytes => bytes.values.fold(0, (sum, data) => sum + data.length);
  String get indexPath => p.join(root, 'manifest.json');
  Future<Map<String, dynamic>> index() async => Map<String, dynamic>.from(
      jsonDecode(await File(indexPath).readAsString()) as Map);
  Future<void> writeIndex(Map<String, dynamic> value) =>
      File(indexPath).writeAsString(jsonEncode(value)).then((_) {});
  static Future<_Fixture> create() async {
    final dir = await Directory.systemTemp.createTemp('replica-warm-');
    addTearDown(() => dir.delete(recursive: true));
    final bytes = {
      'a': utf8.encode('first score'),
      'b': utf8.encode('second larger score')
    };
    final manifest = SyncManifest(libraryId: 'library', folders: [
      ''
    ], entries: [
      for (final e in bytes.entries)
        ManifestEntry(
            entryId: e.key,
            revisionId: 'r1',
            relativePath: '${e.key}.pdf',
            hash: sha256.convert(e.value).toString(),
            length: e.value.length,
            format: 'pdf',
            missing: false)
    ]);
    final view = await ReplicaLibraryView.open(rootDirectory: dir.path);
    for (final e in manifest.entries) {
      await view.receiveObject(e, Stream.value(bytes[e.entryId]!));
    }
    await view.commitManifest(manifest);
    return _Fixture(dir.path, view, manifest, bytes);
  }
}

void main() {
  test(
      'download verifies incoming bytes once; committed warm open reads zero local content bytes',
      () async {
    final f = await _Fixture.create();
    expect(f.view.verificationStats.downloadObjectsVerified, 2);
    expect(f.view.verificationStats.downloadBytesReceived, f.totalBytes);
    expect(f.view.verificationStats.localHashOperations, 0);
    expect(f.view.verificationStats.localHashBytesRead, 0);
    final warm = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(warm.verificationStats.localHashOperations, 0);
    expect(warm.verificationStats.localHashBytesRead, 0);
    expect(warm.verificationStats.downloadBytesReceived, 0);
    expect(warm.verificationStats.cachedObjectsReused, 2);
    expect(
        warm.snapshot.availableEntries
            .every((e) => e.availability == ContentAvailability.ready),
        isTrue);
    for (final e in f.manifest.entries) {
      expect(await warm.hasVerifiedObject(e), isTrue);
    }
    await warm.commitManifest(f.manifest);
    expect(warm.verificationStats.localHashBytesRead, 0);
  });
  test(
      'legacy or missing verification records hash actual bytes once and persist their replacement',
      () async {
    final f = await _Fixture.create();
    final json = await f.index();
    json.remove('verificationSchema');
    json.remove('verifiedObjects');
    await f.writeIndex(json);
    final legacy = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(legacy.verificationStats.localHashOperations, 2);
    expect(legacy.verificationStats.localHashBytesRead, f.totalBytes);
    expect((await f.index())['generation'], json['generation']);
    final warm = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(warm.verificationStats.localHashBytesRead, 0);
    final recordsLost = await f.index();
    (recordsLost['verifiedObjects'] as Map)
        .remove(p.basename(f.view.objectPath(f.manifest.entries.first)));
    await f.writeIndex(recordsLost);
    final missingOne = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(missingOne.verificationStats.localHashOperations, 1);
    expect(
        missingOne.verificationStats.localHashBytesRead, f.bytes['a']!.length);
    expect(missingOne.verificationStats.cachedObjectsReused, 1);
  });
  test(
      'changed fingerprint hashes only that object; corrupt bytes stay unreadable',
      () async {
    final f = await _Fixture.create();
    final a = f.manifest.entries.first;
    final file = File(f.view.objectPath(a));
    final stat = await file.stat();
    await file.writeAsBytes(List.filled(a.length, 120));
    await file.setLastModified(stat.modified.add(const Duration(seconds: 5)));
    final changed = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(changed.verificationStats.localHashOperations, 1);
    expect(changed.verificationStats.localHashBytesRead, a.length);
    expect(changed.snapshot.entryById('a')!.availability,
        ContentAvailability.unreadable);
    expect(changed.snapshot.entryById('b')!.availability,
        ContentAvailability.ready);
    await file.writeAsBytes(f.bytes['a']!);
    final repaired = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(repaired.verificationStats.localHashOperations, 1);
    expect(repaired.verificationStats.localHashBytesRead, a.length);
    expect(repaired.snapshot.entryById('a')!.availability,
        ContentAvailability.ready);
  });
  test(
      'explicit full verification reads every object even with unchanged fingerprints',
      () async {
    final f = await _Fixture.create();
    final forcedOpen =
        await ReplicaLibraryView.open(rootDirectory: f.root, verifyAll: true);
    expect(forcedOpen.verificationStats.localHashOperations, 2);
    expect(forcedOpen.verificationStats.localHashBytesRead, f.totalBytes);
    final warm = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(warm.verificationStats.localHashBytesRead, 0);
    final stats = await warm.verifyAll();
    expect(stats.localHashOperations, 2);
    expect(stats.localHashBytesRead, f.totalBytes);
    expect(stats.downloadBytesReceived, 0);
  });
  test(
      'same size and restored mtime limitation is explicit; verifyAll detects altered bytes',
      () async {
    final f = await _Fixture.create();
    final a = f.manifest.entries.first;
    final file = File(f.view.objectPath(a));
    await file.setLastModified(DateTime.utc(2026));
    await f.view.verifyAll();
    final before = await file.stat();
    await file.writeAsBytes(List.filled(a.length, 120));
    await file.setLastModified(before.modified);
    final after = await file.stat();
    expect(after.size, before.size);
    expect(after.modified, before.modified);
    expect(after.mode, before.mode);
    final warm = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(warm.verificationStats.localHashBytesRead, 0);
    expect(
        warm.snapshot.entryById('a')!.availability, ContentAvailability.ready);
    await warm.verifyAll();
    expect(warm.verificationStats.localHashBytesRead, f.totalBytes);
    expect(warm.snapshot.entryById('a')!.availability,
        ContentAvailability.unreadable);
    expect(
        warm.snapshot.entryById('b')!.availability, ContentAvailability.ready);
  });
  test(
      'malformed and unknown verification records cannot report unverified content as ready',
      () async {
    final f = await _Fixture.create();
    final json = await f.index();
    final a = f.manifest.entries.first;
    (json['verifiedObjects'] as Map)[p.basename(f.view.objectPath(a))] = {
      'hash': 'bad',
      'length': 'wrong'
    };
    await f.writeIndex(json);
    final repairedRecord = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(repairedRecord.verificationStats.localHashOperations, 1);
    expect(repairedRecord.verificationStats.localHashBytesRead, a.length);
    final unknown = await f.index();
    unknown['verificationSchema'] = 999;
    await f.writeIndex(unknown);
    final full = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(full.verificationStats.localHashOperations, 2);
    expect(full.verificationStats.localHashBytesRead, f.totalBytes);
    expect((await f.index())['verificationSchema'], 1);
  });
  test(
      'valid atomic backup recovers verification records; two corrupt manifests fail explicitly',
      () async {
    final f = await _Fixture.create();
    await File(f.indexPath).copy('${f.indexPath}.backup');
    await File(f.indexPath).writeAsString('{broken');
    final recovered = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(recovered.verificationStats.localHashBytesRead, 0);
    expect(recovered.snapshot.availableEntries, hasLength(2));
    await File('${f.indexPath}.backup').writeAsString('{also broken');
    await expectLater(
        ReplicaLibraryView.open(rootDirectory: f.root), throwsFormatException);
  });
  test(
      'missing object cannot reuse a verification record; full verification reloads newer manifest',
      () async {
    final f = await _Fixture.create();
    final a = f.manifest.entries.first;
    await File(f.view.objectPath(a)).delete();
    final missing = await ReplicaLibraryView.open(rootDirectory: f.root);
    expect(missing.verificationStats.localHashBytesRead, 0);
    expect(missing.snapshot.entryById('a')!.availability,
        ContentAvailability.unreadable);
    final next = SyncManifest(
        libraryId: 'library',
        folders: [''],
        entries: [f.manifest.entries.last]);
    await missing.commitManifest(next);
    await f.view.verifyAll();
    expect(f.view.snapshot.entries.map((e) => e.id), ['b']);
    expect((await f.index())['generation'], missing.snapshot.generation);
  });
}
