import 'collection.dart';
import 'replica.dart';

/// Platform-owned transfers. A staged file is never a committed offline object:
/// callers must use the replica's length/SHA check and atomic import, then ack.
abstract interface class BackgroundTransfer {
  Future<void> enqueue(
      {required String namespace,
      required Uri origin,
      required String bearerToken,
      required List<CatalogItem> items,
      required bool prepare,
      bool smallFileBatches = false,
      OfflineSelection? selection,
      required SyncCancellation? cancellation});
  Future<BackgroundTransferFile> wait(
      String namespace, CatalogItem item, SyncCancellation? cancellation);
  Future<List<BackgroundTransferFile>> staged(String namespace);
  Future<void> acknowledge(String namespace, CatalogItem item);
  Future<void> pause(String namespace);
}

abstract interface class BackgroundTransferBatchAcknowledger {
  Future<void> acknowledgeMany(String namespace, List<CatalogItem> items);
}

class BackgroundTransferFile {
  const BackgroundTransferFile(this.item, this.path,
      {this.requestedRevisionId, this.companions = const []});
  final CatalogItem item;
  final String path;
  final String? requestedRevisionId;
  final List<CatalogItem> companions;
}
