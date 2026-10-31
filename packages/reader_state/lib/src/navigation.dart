import 'models.dart';

enum NavigationDirection { forward, backward }

enum NavigationStatus {
  moved,
  boundary,
  missingTarget,
  metadataRequired,
  staleRevision,
  invalidPosition,
}

enum DocumentMetadataStatus { ready, missing, unknown }

class DocumentMetadata {
  DocumentMetadata.ready(
      {required this.entryId,
      required String revisionId,
      required int pageCount})
      : status = DocumentMetadataStatus.ready,
        revisionId = revisionId,
        pageCount = pageCount {
    requireNonEmptyId(entryId, 'entryId');
    requireNonEmptyId(revisionId, 'revisionId');
    if (pageCount < 1) throw ArgumentError.value(pageCount, 'pageCount');
  }
  DocumentMetadata.image({required String entryId, required String revisionId})
      : this.ready(entryId: entryId, revisionId: revisionId, pageCount: 1);
  DocumentMetadata.missing(this.entryId)
      : status = DocumentMetadataStatus.missing,
        revisionId = null,
        pageCount = null {
    requireNonEmptyId(entryId, 'entryId');
  }
  DocumentMetadata.unknown(this.entryId)
      : status = DocumentMetadataStatus.unknown,
        revisionId = null,
        pageCount = null {
    requireNonEmptyId(entryId, 'entryId');
  }
  final String entryId;
  final DocumentMetadataStatus status;
  final String? revisionId;
  final int? pageCount;
}

class ReadingPosition {
  ReadingPosition(
      {required this.entryId,
      required this.revisionId,
      required this.pageNumber,
      this.setListItemId}) {
    requireNonEmptyId(entryId, 'entryId');
    requireNonEmptyId(revisionId, 'revisionId');
    if (pageNumber < 1) throw ArgumentError.value(pageNumber, 'pageNumber');
    if (setListItemId != null)
      requireNonEmptyId(setListItemId!, 'setListItemId');
  }
  final String entryId;
  final String revisionId;
  final int pageNumber;
  final String? setListItemId;
  PageKey get pageKey =>
      PageKey(entryId: entryId, revisionId: revisionId, pageNumber: pageNumber);

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.entryId == entryId &&
      other.revisionId == revisionId &&
      other.pageNumber == pageNumber &&
      other.setListItemId == setListItemId;
  @override
  int get hashCode =>
      Object.hash(entryId, revisionId, pageNumber, setListItemId);
}

/// Preserve this request while loading metadata, then resolve it again once.
/// Do not replace [current] with an intermediate/optimistic position.
class NavigationRequest {
  const NavigationRequest({required this.current, required this.direction});
  final ReadingPosition current;
  final NavigationDirection direction;
}

class NavigationResult {
  const NavigationResult(
      {required this.request,
      required this.status,
      required this.position,
      this.requiredEntryId,
      this.targetItemId,
      this.reason});
  final NavigationRequest request;
  final NavigationStatus status;

  /// Changed only for [NavigationStatus.moved]; otherwise the original position.
  final ReadingPosition position;
  final String? requiredEntryId;
  final String? targetItemId;
  final String? reason;
  bool get didMove => status == NavigationStatus.moved;
}

class ReaderNavigator {
  const ReaderNavigator._();

  /// Empty [queue] means standalone reading. A non-empty queue requires an
  /// explicit item ID in the current position, including repeated entries.
  static NavigationResult resolve(
    NavigationRequest request, {
    List<SetListItem> queue = const [],
    required Map<String, DocumentMetadata> documents,
  }) {
    final current = request.current;
    final visible = queue.where((item) => !item.isRemoved).toList();

    NavigationResult hold(NavigationStatus status,
            {String? entryId, String? itemId, String? reason}) =>
        NavigationResult(
            request: request,
            status: status,
            position: current,
            requiredEntryId: entryId,
            targetItemId: itemId,
            reason: reason);

    int? queueIndex;
    if (visible.isNotEmpty) {
      final index =
          visible.indexWhere((item) => item.id == current.setListItemId);
      if (index < 0 || visible[index].entryId != current.entryId) {
        return hold(NavigationStatus.invalidPosition,
            reason: 'Current item is not in this queue.');
      }
      queueIndex = index;
    } else if (current.setListItemId != null) {
      return hold(NavigationStatus.invalidPosition,
          reason: 'Current set list item is no longer active.');
    }

    final metadata = documents[current.entryId];
    if (metadata == null || metadata.status == DocumentMetadataStatus.unknown) {
      return hold(NavigationStatus.metadataRequired,
          entryId: current.entryId,
          itemId: current.setListItemId,
          reason: 'Current document metadata is needed.');
    }
    if (metadata.entryId != current.entryId) {
      return hold(NavigationStatus.invalidPosition,
          reason: 'Metadata key does not match entry ID.');
    }
    if (metadata.status == DocumentMetadataStatus.missing) {
      return hold(NavigationStatus.missingTarget,
          entryId: current.entryId,
          itemId: current.setListItemId,
          reason: 'Current document is missing.');
    }
    if (metadata.revisionId != current.revisionId) {
      return hold(NavigationStatus.staleRevision,
          entryId: current.entryId,
          itemId: current.setListItemId,
          reason: 'Current content revision changed.');
    }
    final pageCount = metadata.pageCount!;
    if (current.pageNumber > pageCount) {
      return hold(NavigationStatus.invalidPosition,
          reason: 'Current page is outside document.');
    }
    final forward = request.direction == NavigationDirection.forward;
    if ((forward && current.pageNumber < pageCount) ||
        (!forward && current.pageNumber > 1)) {
      return NavigationResult(
          request: request,
          status: NavigationStatus.moved,
          position: ReadingPosition(
              entryId: current.entryId,
              revisionId: current.revisionId,
              pageNumber: current.pageNumber + (forward ? 1 : -1),
              setListItemId: current.setListItemId));
    }
    final targetIndex =
        queueIndex == null ? null : queueIndex + (forward ? 1 : -1);
    if (targetIndex == null ||
        targetIndex < 0 ||
        targetIndex >= visible.length) {
      return hold(NavigationStatus.boundary,
          reason:
              forward ? 'End of reading queue.' : 'Start of reading queue.');
    }
    final targetItem = visible[targetIndex];
    final target = documents[targetItem.entryId];
    if (target == null || target.status == DocumentMetadataStatus.unknown) {
      return hold(NavigationStatus.metadataRequired,
          entryId: targetItem.entryId,
          itemId: targetItem.id,
          reason: 'Target document metadata is needed.');
    }
    if (target.entryId != targetItem.entryId) {
      return hold(NavigationStatus.invalidPosition,
          reason: 'Target metadata key does not match entry ID.');
    }
    if (target.status == DocumentMetadataStatus.missing) {
      return hold(NavigationStatus.missingTarget,
          entryId: targetItem.entryId,
          itemId: targetItem.id,
          reason: 'Target document is missing.');
    }
    return NavigationResult(
        request: request,
        status: NavigationStatus.moved,
        position: ReadingPosition(
            entryId: targetItem.entryId,
            revisionId: target.revisionId!,
            pageNumber: forward ? 1 : target.pageCount!,
            setListItemId: targetItem.id));
  }
}
