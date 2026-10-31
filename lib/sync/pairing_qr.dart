import 'dart:convert';
import 'dart:io';

/// Only app-owned pairing data is accepted. A scan never opens a web page.
class PairingQr {
  PairingQr({required this.origins, required this.code, required this.expires});

  final List<Uri> origins;
  final String code;
  final DateTime expires;

  static bool isLanOrigin(Uri uri) {
    final ip = InternetAddress.tryParse(uri.host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final bytes = ip.rawAddress;
    final private =
        bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
    return private &&
        uri.scheme == 'http' &&
        uri.hasPort &&
        uri.port > 0 &&
        uri.port <= 65535 &&
        uri.userInfo.isEmpty &&
        uri.path.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  static bool isPhysicalInterface(String name) => !RegExp(
    r'loopback|virtual|vethernet|vmware|vbox|hyper-v|docker|wsl|tailscale|zerotier|wireguard|tunnel|tap-|tun\d|vpn',
    caseSensitive: false,
  ).hasMatch(name);

  String encode() => jsonEncode({
    'app': 'score-reader-pair',
    'v': 1,
    'origins': origins.map((uri) => uri.toString()).toList(),
    'code': code,
    'expires': expires.toUtc().toIso8601String(),
  });

  static PairingQr decode(String text, {DateTime? now}) {
    if (text.length > 1800) throw const FormatException('二维码内容过长。');
    final data = jsonDecode(text);
    if (data is! Map ||
        data['app'] != 'score-reader-pair' ||
        data['v'] != 1 ||
        data['origins'] is! List ||
        data['code'] is! String ||
        !RegExp(r'^\d{8}$').hasMatch(data['code'] as String) ||
        data['expires'] is! String) {
      throw const FormatException('请扫描曲谱阅读器电脑端显示的二维码。');
    }
    final values = data['origins'] as List;
    if (values.isEmpty || values.length > 3) {
      throw const FormatException('二维码中的电脑连接无效，请重新生成。');
    }
    final origins = <Uri>[];
    for (final value in values) {
      if (value is! String) throw const FormatException('无效的电脑连接。');
      final uri = Uri.parse(value);
      if (!isLanOrigin(uri)) throw const FormatException('二维码中的电脑连接无效。');
      if (!origins.contains(uri)) origins.add(uri);
    }
    final expires = DateTime.parse(data['expires'] as String).toUtc();
    final current = (now ?? DateTime.now()).toUtc();
    if (!expires.isAfter(current)) {
      throw const FormatException('二维码已过期，请在电脑点击“更新二维码”后重扫。');
    }
    if (expires.difference(current) > const Duration(minutes: 3)) {
      throw const FormatException('二维码时间无效，请校准电脑与iPad时间后重扫。');
    }
    return PairingQr(
      origins: origins,
      code: data['code'] as String,
      expires: expires,
    );
  }
}
