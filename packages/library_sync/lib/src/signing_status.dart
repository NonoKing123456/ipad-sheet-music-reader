import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'storage.dart';

class SigningDeviceStatus {
  const SigningDeviceStatus(this.expiration);
  final DateTime? expiration;
  Map<String, Object?> toJson() => {
        'status': expiration == null ? 'unknown' : 'known',
        if (expiration != null)
          'expirationMilliseconds': expiration!.toUtc().millisecondsSinceEpoch,
      };
  factory SigningDeviceStatus.fromJson(Map<String, dynamic> json) {
    if (json.keys
        .any((key) => key != 'status' && key != 'expirationMilliseconds')) {
      throw const FormatException('Unknown signing status fields.');
    }
    if (json['status'] == 'unknown' &&
        !json.containsKey('expirationMilliseconds')) {
      return const SigningDeviceStatus(null);
    }
    if (json['status'] != 'known') {
      throw const FormatException('Invalid signing status.');
    }
    return SigningDeviceStatus(_date(json['expirationMilliseconds']));
  }
}

DateTime _date(Object? value) {
  if (value is! int || value < 0 || value > 253402300799000) {
    throw const FormatException('Invalid signing date.');
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

bool _id(String id) => RegExp(r'^[a-f0-9]{32}$').hasMatch(id);
// Existing peer IDs are opaque URL-safe values, not source/catalog hex IDs.
bool _peerId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id);

class SigningStatusReceipt {
  const SigningStatusReceipt({
    required this.serverId,
    required this.peerId,
    required this.status,
    required this.receivedAt,
    this.lastKnownExpiration,
    this.lastKnownReceivedAt,
  });
  final String serverId, peerId;
  final SigningDeviceStatus status;
  final DateTime receivedAt;
  final DateTime? lastKnownExpiration, lastKnownReceivedAt;
  Map<String, Object?> toJson() => {
        'server': serverId,
        'peer': peerId,
        'report': status.toJson(),
        'receivedAt': receivedAt.millisecondsSinceEpoch,
        if (lastKnownExpiration != null)
          'lastKnownExpiration': lastKnownExpiration!.millisecondsSinceEpoch,
        if (lastKnownReceivedAt != null)
          'lastKnownReceivedAt': lastKnownReceivedAt!.millisecondsSinceEpoch,
      };
  factory SigningStatusReceipt.fromJson(Map<String, dynamic> json) {
    final server = json['server'], peer = json['peer'];
    if (server is! String ||
        peer is! String ||
        !_id(server) ||
        !_peerId(peer)) {
      throw const FormatException('Invalid signing receipt owner.');
    }
    return SigningStatusReceipt(
      serverId: server,
      peerId: peer,
      status: SigningDeviceStatus.fromJson(
          Map<String, dynamic>.from(json['report'] as Map)),
      receivedAt: _date(json['receivedAt']),
      lastKnownExpiration: json['lastKnownExpiration'] == null
          ? null
          : _date(json['lastKnownExpiration']),
      lastKnownReceivedAt: json['lastKnownReceivedAt'] == null
          ? null
          : _date(json['lastKnownReceivedAt']),
    );
  }
}

/// Small, separately leased/serialized/atomic status data; never reader state.
/// Cached reports are invisible until their existing authentication is checked.
class SigningStatusStore {
  SigningStatusStore._(this.root, this._lease);
  final String root;
  final DirectoryLease _lease;
  final _records = <String, SigningStatusReceipt>{};
  final _active = <String, Set<String>>{};
  Future<void> _tail = Future.value();
  void Function()? onChanged;
  bool _closed = false, _closing = false, _scopeSelected = false;
  String? _selectedServer;

  /// A second app instance can project the owner's committed receipt without
  /// taking or modifying its lease. Authentication is supplied by the current
  /// server's peer projection; unrelated cached receipts are never returned.
  static Future<SigningStatusReceipt?> readAuthorized(
      String directory, String serverId, Set<String> authenticatedPeers) async {
    if (!_id(serverId) || authenticatedPeers.isEmpty) return null;
    final root = p.normalize(p.absolute(directory));
    final path = p.join(root, 'status.json');
    for (final candidate in [path, '$path.backup']) {
      assertSafePath(root, candidate);
      final file = File(candidate);
      if (await file.exists() && await file.length() > 65536) {
        throw const FormatException('Signing status file too large.');
      }
    }
    final json = await readJson(path);
    if (json == null) return null;
    if (json['schema'] != 1 ||
        json['receipts'] is! List ||
        (json['receipts'] as List).length > 64) {
      throw const FormatException('Invalid signing status file.');
    }
    SigningStatusReceipt? latest;
    for (final value in json['receipts'] as List) {
      final item = SigningStatusReceipt.fromJson(
          Map<String, dynamic>.from(value as Map));
      if (item.serverId != serverId ||
          !authenticatedPeers.contains(item.peerId)) continue;
      if (latest == null ||
          item.receivedAt.isAfter(latest.receivedAt) ||
          (item.receivedAt == latest.receivedAt &&
              item.peerId.compareTo(latest.peerId) > 0)) {
        latest = item;
      }
    }
    return latest;
  }

  void selectServer(String? serverId) {
    _scopeSelected = true;
    _selectedServer = serverId;
    onChanged?.call();
  }

  String get _path => p.join(root, 'status.json');
  Set<String> get serverIds => _records.values.map((x) => x.serverId).toSet();
  SigningStatusReceipt? get latest {
    SigningStatusReceipt? result;
    for (final item in _records.values) {
      if (_scopeSelected && item.serverId != _selectedServer) continue;
      if (!(_active[item.serverId]?.contains(item.peerId) ?? false)) continue;
      if (result == null ||
          item.receivedAt.isAfter(result.receivedAt) ||
          (item.receivedAt == result.receivedAt &&
              '${item.serverId}/${item.peerId}'
                      .compareTo('${result.serverId}/${result.peerId}') >
                  0)) {
        result = item;
      }
    }
    return result;
  }

  static Future<SigningStatusStore> open(String directory) async {
    final root = p.normalize(p.absolute(directory));
    final lease = await DirectoryLease.acquire(root);
    try {
      final store = SigningStatusStore._(root, lease);
      for (final suffix in ['', '.backup']) {
        final file = File('${store._path}$suffix');
        assertSafePath(root, file.path);
        if (await file.exists() && await file.length() > 65536) {
          throw const FormatException('Signing status file too large.');
        }
      }
      final json = await readJson(store._path);
      if (json != null) {
        if (json['schema'] != 1 ||
            json['receipts'] is! List ||
            (json['receipts'] as List).length > 64) {
          throw const FormatException('Invalid signing status file.');
        }
        for (final value in json['receipts'] as List) {
          final item = SigningStatusReceipt.fromJson(
              Map<String, dynamic>.from(value as Map));
          store._records['${item.serverId}/${item.peerId}'] = item;
        }
      }
      return store;
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  void setAuthenticatedPeers(String serverId, Set<String> peers) {
    if (_closed || !_id(serverId)) return;
    _active[serverId] = peers.where(_peerId).toSet();
    onChanged?.call();
  }

  Future<void> receive(String serverId, String authenticatedPeer,
      SigningDeviceStatus status, DateTime receivedAt) {
    if (_closing || _closed)
      return Future.error(StateError('Signing status store closed.'));
    final next = _tail.then((_) async {
      if (_closed ||
          !(_active[serverId]?.contains(authenticatedPeer) ?? false)) {
        return;
      }
      final key = '$serverId/$authenticatedPeer', previous = _records[key];
      final item = SigningStatusReceipt(
        serverId: serverId,
        peerId: authenticatedPeer,
        status: status,
        receivedAt: receivedAt.toUtc(),
        lastKnownExpiration: status.expiration ?? previous?.lastKnownExpiration,
        lastKnownReceivedAt: status.expiration == null
            ? previous?.lastKnownReceivedAt
            : receivedAt.toUtc(),
      );
      final records = Map<String, SigningStatusReceipt>.of(_records)
        ..[key] = item;
      final ordered = records.values.toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      final retained = ordered.take(64).toList();
      await writeJson(_path, {
        'schema': 1,
        'receipts': [for (final x in retained) x.toJson()]
      });
      _records
        ..clear()
        ..addEntries(
            retained.map((x) => MapEntry('${x.serverId}/${x.peerId}', x)));
      onChanged?.call();
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> close() async {
    _closing = true;
    await _tail;
    _closed = true;
    onChanged = null;
    await _lease.close();
  }
}
