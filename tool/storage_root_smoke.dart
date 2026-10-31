// Pure Dart, synthetic data only. CI requires actual links; never a silent skip.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';
import 'package:library_sync/src/storage.dart'
    show assertSafePath, DirectoryLease;
import 'package:path/path.dart' as p;

void check(bool value, String label) {
  if (!value) throw StateError('Storage smoke failed: $label');
  stdout.writeln('PASS $label');
}

Future<void> rejected(Future<void> Function() action, String label) async {
  try {
    await action();
  } on FileSystemException catch (failure) {
    check(failure.message == 'Linked sync/source paths are forbidden.', label);
    return;
  }
  throw StateError('Storage smoke unexpectedly accepted: $label');
}

Future<void> main(List<String> arguments) async {
  final requireLinks = arguments.contains('--require-links');
  final parent = await Directory.systemTemp.resolveSymbolicLinks();
  final scratch = await Directory(parent).createTemp('score-storage-smoke-');
  final createdLinks = <Link>[];
  try {
    final realApp = Directory(p.join(scratch.path, 'real-app'));
    await realApp.create();
    final alias = Link(p.join(scratch.path, 'app-alias'));
    var linksAvailable = false;
    try {
      await alias.create(realApp.path);
      createdLinks.add(alias);
      linksAvailable = true;
    } on FileSystemException {
      if (requireLinks) rethrow;
      stdout.writeln('SKIP symbolic-link cases: host permission unavailable');
    }
    final supplied = linksAvailable ? Directory(alias.path) : realApp;
    if (linksAvailable) {
      await rejected(() async {
        await ReplicaLibraryView.open(
          rootDirectory: p.join(supplied.path, 'sync', 'replica'),
        );
      }, 'legacy alias replica open rejects link');
    }
    final root = await prepareTrustedStateRoot(supplied);
    check(
      p.equals(root.path, await realApp.resolveSymbolicLinks()),
      'trusted alias resolves to same location',
    );
    final sentinel = File(p.join(supplied.path, 'existing-identity.json'));
    await sentinel.writeAsString('{"libraryId":"unchanged","paired":true}');
    final replicaPath = p.join(root.path, 'sync', 'replica');
    final replica = await ReplicaLibraryView.open(rootDirectory: replicaPath);
    check(replica.manifest == null, 'canonical root initializes empty replica');
    final bytes = utf8.encode('synthetic offline score');
    final entry = ManifestEntry(
      entryId: 'synthetic',
      revisionId: 'r1',
      relativePath: 'score.png',
      hash: sha256.convert(bytes).toString(),
      length: bytes.length,
      format: 'png',
      missing: false,
    );
    await replica.receiveObject(entry, Stream.value(bytes));
    await replica.commitManifest(
      SyncManifest(
        libraryId: 'unchanged-library',
        entries: [entry],
        folders: [''],
      ),
    );
    final reopenedRoot = await prepareTrustedStateRoot(supplied);
    final reopened = await ReplicaLibraryView.open(
      rootDirectory: p.join(reopenedRoot.path, 'sync', 'replica'),
    );
    check(
      reopened.manifest?.libraryId == 'unchanged-library' &&
          await File(reopened.objectPath(entry)).readAsString() ==
              utf8.decode(bytes),
      'reopen preserves identity and cached object',
    );
    check(
      await File(p.join(root.path, 'existing-identity.json')).readAsString() ==
          '{"libraryId":"unchanged","paired":true}',
      'alias state remains in place',
    );
    final lease = await DirectoryLease.acquire(replicaPath);
    try {
      var duplicateBlocked = false;
      try {
        final duplicate = await DirectoryLease.acquire(
          p.join(reopenedRoot.path, 'sync', 'replica'),
        );
        await duplicate.close();
      } on StateError {
        duplicateBlocked = true;
      }
      check(duplicateBlocked, 'canonical roots share one lock identity');
    } finally {
      await lease.close();
    }
    var escapeBlocked = false;
    try {
      assertSafePath(root.path, p.join(root.path, '..', 'escape'));
    } on FormatException {
      escapeBlocked = true;
    }
    check(escapeBlocked, 'lexical root escape remains rejected');
    if (linksAvailable) {
      final outside = Directory(p.join(scratch.path, 'outside'));
      await outside.create();
      final unsafeReplica = Directory(p.join(root.path, 'unsafe-replica'));
      await unsafeReplica.create();
      final objects = Link(p.join(unsafeReplica.path, 'objects'));
      await objects.create(outside.path);
      createdLinks.add(objects);
      final unsafe = await ReplicaLibraryView.open(
        rootDirectory: unsafeReplica.path,
      );
      await rejected(
        () => unsafe.receiveObject(entry, Stream.value(bytes)),
        'linked object directory remains rejected',
      );
      check(
        await outside.list().isEmpty,
        'no object escaped into linked directory',
      );
      await rejected(() async {
        assertSafePath(scratch.path, p.join(alias.path, 'source.png'));
      }, 'source link guard remains unchanged');
    }
    await File(reopened.objectPath(entry)).writeAsString('damaged');
    final damaged = await ReplicaLibraryView.open(
      rootDirectory: replicaPath,
      verifyAll: true,
    );
    check(
      damaged.snapshot.entries.single.availability ==
          ContentAvailability.unreadable,
      'corrupt cached bytes remain unavailable',
    );
    if (Platform.isMacOS) {
      var systemAliasChecked = false;
      for (final prefix in ['/tmp', '/var/tmp']) {
        if (!await Directory(prefix).exists()) continue;
        if (p.equals(await Directory(prefix).resolveSymbolicLinks(), prefix)) {
          continue;
        }
        final systemRoot = await Directory(prefix)
            .createTemp('score-system-alias-');
        try {
          await rejected(() async {
            await ReplicaLibraryView.open(
              rootDirectory: p.join(systemRoot.path, 'sync', 'replica'),
            );
          }, 'legacy Apple system alias rejects link');
          final canonicalSystem = await prepareTrustedStateRoot(systemRoot);
          await ReplicaLibraryView.open(
            rootDirectory: p.join(canonicalSystem.path, 'sync', 'replica'),
          );
          await ReplicaLibraryView.open(
            rootDirectory: p.join(canonicalSystem.path, 'sync', 'replica'),
          );
          check(true, 'Apple system alias initializes and reopens replica');
          systemAliasChecked = true;
        } finally {
          await systemRoot.delete(recursive: true);
        }
        break;
      }
      check(systemAliasChecked, 'actual Apple system alias was exercised');
    }
    stdout.writeln(
      'PASS storage root smoke complete; links=${linksAvailable ? 'exercised' : 'skipped'}',
    );
  } finally {
    for (final link in createdLinks.reversed) {
      if (await link.exists()) await link.delete();
    }
    final verifiedScratch = await scratch.resolveSymbolicLinks();
    if (!p.equals(p.dirname(verifiedScratch), parent) ||
        !p.basename(verifiedScratch).startsWith('score-storage-smoke-')) {
      throw StateError('Refusing cleanup outside generated smoke directory');
    }
    await scratch.delete(recursive: true);
  }
}
