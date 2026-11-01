import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:library_sync/library_sync.dart';

/// The OS owns the whole batch before any file is awaited. Polling only updates
/// the foreground UI; URLSession and its native delegates advance without Dart.
class IosBackgroundTransfer implements BackgroundTransfer {
  IosBackgroundTransfer({
    MethodChannel? channel,
    this.pollInterval = const Duration(milliseconds: 300),
  }) : channel =
           channel ?? const MethodChannel('score_reader/background_download') {
    this.channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged?.call();
    });
  }
  final MethodChannel channel;
  final Duration pollInterval;
  void Function()? onChanged;
  void dispose() {
    channel.setMethodCallHandler(null);
  }

  Future<Map<String, dynamic>> activity(String namespace) async =>
      _map(await _invoke<Object?>('activity', {'namespace': namespace}));
  Future<void> resume(String namespace) =>
      _invoke<void>('resume', {'namespace': namespace});
  Future<void> discard(String namespace) =>
      _invoke<void>('discard', {'namespace': namespace});

  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      throw const FileSystemException('Background queue storage unavailable.');
    }
  }

  @override
  Future<void> enqueue({
    required String namespace,
    required Uri origin,
    required String bearerToken,
    required List<CatalogItem> items,
    required bool prepare,
    OfflineSelection? selection,
    required SyncCancellation? cancellation,
  }) async {
    cancellation?.check();
    await _invoke<void>('enqueue', {
      'namespace': namespace,
      'origin': origin.toString(),
      'token': bearerToken,
      'prepare': prepare,
      'selection': selection?.toJson(),
      'items': items.map((item) => item.toJson()).toList(),
    });
    if (cancellation?.isCancelled == true) {
      await pause(namespace);
      cancellation!.check();
    }
  }

  Map<String, dynamic> _map(Object? value) =>
      Map<String, dynamic>.from(value as Map);
  BackgroundTransferFile _file(Map<String, dynamic> value) =>
      BackgroundTransferFile(
        CatalogItem.fromJson(_map(value['item'])),
        value['path'] as String,
        requestedRevisionId: value['requestedRevisionId'] as String?,
      );

  @override
  Future<BackgroundTransferFile> wait(
    String namespace,
    CatalogItem item,
    SyncCancellation? cancellation,
  ) async {
    void cancel() {
      unawaited(pause(namespace).catchError((Object _) {}));
    }

    cancellation?.addListener(cancel);
    try {
      while (true) {
        cancellation?.check();
        final value = _map(
          await _invoke<Object?>('status', {
            'namespace': namespace,
            'entryId': item.entryId,
          }),
        );
        cancellation?.check();
        if (value['state'] == 'staged') {
          final file = _file(value);
          if (file.item.entryId != item.entryId ||
              file.item.sourceId != item.sourceId) {
            throw const FormatException('Background object identity changed.');
          }
          return file;
        }
        if (value['state'] == 'error') {
          switch (value['failure']) {
            case 'integrity':
              throw const LibraryContentIntegrityException();
            case 'storage':
              throw const FileSystemException(
                'Background staging unavailable.',
              );
            case 'http':
              throw SyncProtocolException(
                'Peer rejected background request.',
                value['status'] as int?,
              );
            default:
              throw const SocketException(
                'Background transfer interrupted; retry.',
              );
          }
        }
        if (value['state'] == 'paused' || value['state'] == 'missing') {
          throw const SocketException('Background transfer paused; retry.');
        }
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      cancellation?.removeListener(cancel);
    }
  }

  @override
  Future<List<BackgroundTransferFile>> staged(String namespace) async {
    final values =
        await _invoke<List<Object?>>('staged', {'namespace': namespace}) ?? [];
    return values.map((value) => _file(_map(value))).toList();
  }

  @override
  Future<void> acknowledge(String namespace, CatalogItem item) => _invoke<void>(
    'acknowledge',
    {'namespace': namespace, 'entryId': item.entryId},
  );
  @override
  Future<void> pause(String namespace) =>
      _invoke<void>('pause', {'namespace': namespace});
}
