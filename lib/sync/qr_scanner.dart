import 'package:flutter/services.dart';

class QrScanner {
  static const channel = MethodChannel('score_reader/pairing_scanner');

  /// iOS presents an AVFoundation camera sheet. Cancellation returns null.
  static Future<String?> scan() => channel.invokeMethod<String>('scan');
}
