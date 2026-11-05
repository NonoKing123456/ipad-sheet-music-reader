import 'package:flutter/services.dart';

import 'external_import_store.dart';

class FileImportBridge {
  static const channel = MethodChannel('score_reader/file_import');
  Future<void> Function()? onChanged;
  void start() => channel.setMethodCallHandler((call) async {
    if (call.method == 'pendingChanged') await onChanged?.call();
  });
  void dispose() => channel.setMethodCallHandler(null);
  Future<List<Map<String, dynamic>>> listPending() async {
    try {
      final result = await channel.invokeListMethod<dynamic>('listPending');
      return [
        for (final value in result ?? [])
          Map<String, dynamic>.from(value as Map),
      ];
    } on MissingPluginException {
      return [];
    }
  }

  Future<void> acknowledge(String id) async {
    await channel.invokeMethod<bool>('ack', {'id': id});
    await channel.invokeMethod<bool>('release', {'id': id});
  }

  static Future<void> copyToNewFile(
    String source,
    String destination, {
    String? trustedRootPath,
  }) async {
    try {
      await channel.invokeMethod<bool>('copyToNewFile', {
        'sourcePath': source,
        'destinationPath': destination,
        'trustedRootPath': ?trustedRootPath,
      });
    } on PlatformException catch (error) {
      if (error.code == 'already_exists') throw const ImportDestinationExists();
      rethrow;
    }
  }
}
