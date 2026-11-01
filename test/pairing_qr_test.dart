import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/sync/pairing_qr.dart';

void main() {
  final now = DateTime.utc(2026, 10, 31, 12);
  Map<String, Object> payload() => {
    'app': 'score-reader-pair',
    'v': 1,
    'origins': ['http://192.168.1.8:50000', 'http://10.0.0.8:50000'],
    'code': '12345678',
    'expires': now.add(const Duration(minutes: 2)).toIso8601String(),
  };

  test(
    'QR round trip contains only versioned LAN origins and a temporary code',
    () {
      final qr = PairingQr.decode(jsonEncode(payload()), now: now);
      expect(qr.origins.first.host, '192.168.1.8');
      expect(qr.origins, hasLength(2));
      expect(qr.code, '12345678');
      expect(PairingQr.decode(qr.encode(), now: now).origins, qr.origins);
    },
  );

  test('rejects arbitrary websites, loopback, credentials, routes and malformed payloads', () {
    for (final origin in [
      'https://192.168.1.8:50000',
      'http://example.com:80',
      'http://8.8.8.8:80',
      'http://127.0.0.1:80',
      'http://0.0.0.0:80',
      'http://192.168.1.8',
      'http://user:pass@192.168.1.8:80',
      'http://192.168.1.8:80/path',
      'http://192.168.1.8:80?q=x',
      'http://192.168.1.8:80#x',
      'http://[::1]:80',
    ]) {
      expect(
        () => PairingQr.decode(
          jsonEncode({
            ...payload(),
            'origins': [origin],
          }),
          now: now,
        ),
        throwsFormatException,
        reason: origin,
      );
    }
    for (final mutation in <Map<String, Object>>[
      {'v': 2},
      {'app': 'other'},
      {'origins': []},
      {'origins': List.filled(4, 'http://10.0.0.1:80')},
      {'code': '12'},
      {'expires': 'invalid'},
    ]) {
      expect(
        () =>
            PairingQr.decode(jsonEncode({...payload(), ...mutation}), now: now),
        throwsFormatException,
      );
    }
    expect(
      () => PairingQr.decode('https://example.com', now: now),
      throwsFormatException,
    );
  });

  test('expired and implausibly future QR is rejected before a connection', () {
    for (final expires in [
      now,
      now.subtract(const Duration(seconds: 1)),
      now.add(const Duration(minutes: 4)),
    ]) {
      expect(
        () => PairingQr.decode(
          jsonEncode({...payload(), 'expires': expires.toIso8601String()}),
          now: now,
        ),
        throwsFormatException,
      );
    }
  });

  test('virtual adapters are excluded while physical adapter names remain eligible', () {
    for (final name in [
      'vEthernet (WSL)',
      'VMware Network Adapter VMnet8',
      'WireGuard Tunnel',
      'Loopback Pseudo-Interface',
      'Tailscale',
      'VirtualBox Host-Only Ethernet',
    ]) {
      expect(PairingQr.isPhysicalInterface(name), isFalse, reason: name);
    }
    for (final name in ['Wi-Fi', '以太网', '无线网络连接', 'Ethernet 2']) {
      expect(PairingQr.isPhysicalInterface(name), isTrue, reason: name);
    }
  });
}
