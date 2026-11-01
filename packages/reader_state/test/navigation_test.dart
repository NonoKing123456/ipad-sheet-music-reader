import 'package:reader_state/reader_state.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 29);
  SetListItem item(String id, String entry, {bool removed = false}) =>
      SetListItem(
          id: id,
          entryId: entry,
          createdUtc: now,
          updatedUtc: now,
          version: 1,
          removedUtc: removed ? now : null);
  ReadingPosition position(String entry, int page,
          {String revision = 'r1', String? itemId}) =>
      ReadingPosition(
          entryId: entry,
          revisionId: revision,
          pageNumber: page,
          setListItemId: itemId);
  NavigationRequest request(ReadingPosition current, {bool backward = false}) =>
      NavigationRequest(
          current: current,
          direction: backward
              ? NavigationDirection.backward
              : NavigationDirection.forward);
  final documents = {
    'A': DocumentMetadata.ready(entryId: 'A', revisionId: 'r1', pageCount: 3),
    'B': DocumentMetadata.image(entryId: 'B', revisionId: 'r1'),
    'C': DocumentMetadata.ready(entryId: 'C', revisionId: 'r1', pageCount: 5),
  };
  final queue = [item('item-A', 'A'), item('item-B', 'B'), item('item-C', 'C')];

  test('standalone navigation moves exactly one page and does not loop', () {
    final next = ReaderNavigator.resolve(request(position('A', 1)),
        documents: documents);
    expect(next.position, position('A', 2));
    expect(next.status, NavigationStatus.moved);
    final previous = ReaderNavigator.resolve(
        request(position('A', 3), backward: true),
        documents: documents);
    expect(previous.position, position('A', 2));
    expect(
        ReaderNavigator.resolve(request(position('A', 3)), documents: documents)
            .status,
        NavigationStatus.boundary);
    expect(
        ReaderNavigator.resolve(request(position('A', 1), backward: true),
                documents: documents)
            .status,
        NavigationStatus.boundary);
  });

  test(
      'last page advances only to next first page, including single-page image',
      () {
    final first = ReaderNavigator.resolve(
        request(position('A', 3, itemId: 'item-A')),
        queue: queue,
        documents: documents);
    expect(first.position, position('B', 1, itemId: 'item-B'));
    // A second explicit action is required to leave the one-page image.
    final second = ReaderNavigator.resolve(request(first.position),
        queue: queue, documents: documents);
    expect(second.position, position('C', 1, itemId: 'item-C'));
  });

  test('previous on first page opens the previous score final page', () {
    final result = ReaderNavigator.resolve(
        request(position('B', 1, itemId: 'item-B'), backward: true),
        queue: queue,
        documents: documents);
    expect(result.position, position('A', 3, itemId: 'item-A'));
  });

  test('overall queue first and last edges remain at their current positions',
      () {
    final first = position('A', 1, itemId: 'item-A');
    final last = position('C', 5, itemId: 'item-C');
    final previous = ReaderNavigator.resolve(request(first, backward: true),
        queue: queue, documents: documents);
    final next = ReaderNavigator.resolve(request(last),
        queue: queue, documents: documents);
    expect(previous.status, NavigationStatus.boundary);
    expect(previous.position, first);
    expect(next.status, NavigationStatus.boundary);
    expect(next.position, last);
  });

  test('duplicate score references are distinguished by stable item ID', () {
    final repeated = [item('first-A', 'A'), item('second-A', 'A')];
    final next = ReaderNavigator.resolve(
        request(position('A', 3, itemId: 'first-A')),
        queue: repeated,
        documents: documents);
    expect(next.position, position('A', 1, itemId: 'second-A'));
    final back = ReaderNavigator.resolve(request(next.position, backward: true),
        queue: repeated, documents: documents);
    expect(back.position, position('A', 3, itemId: 'first-A'));
  });

  test('missing next entry stops and is not silently skipped or substituted',
      () {
    final current = position('A', 3, itemId: 'item-A');
    final missing = {...documents, 'B': DocumentMetadata.missing('B')};
    final result = ReaderNavigator.resolve(request(current),
        queue: queue, documents: missing);
    expect(result.status, NavigationStatus.missingTarget);
    expect(result.requiredEntryId, 'B');
    expect(result.targetItemId, 'item-B');
    expect(result.position, current);
  });

  test(
      'target metadata can load and resolve the exact same action without another press',
      () {
    final action = request(position('A', 3, itemId: 'item-A'));
    final incomplete = {...documents}..remove('B');
    final pending =
        ReaderNavigator.resolve(action, queue: queue, documents: incomplete);
    expect(pending.status, NavigationStatus.metadataRequired);
    expect(pending.requiredEntryId, 'B');
    expect(pending.request, same(action));
    incomplete['B'] = documents['B']!;
    final completed = ReaderNavigator.resolve(pending.request,
        queue: queue, documents: incomplete);
    expect(completed.position, position('B', 1, itemId: 'item-B'));
    // Retrying the unchanged request is idempotent, not a second navigation step.
    expect(
        ReaderNavigator.resolve(pending.request,
                queue: queue, documents: incomplete)
            .position,
        completed.position);
  });

  test('current metadata loading also resumes the original one-page request',
      () {
    final action = request(position('A', 1));
    final pending = ReaderNavigator.resolve(action,
        documents: {'A': DocumentMetadata.unknown('A')});
    expect(pending.status, NavigationStatus.metadataRequired);
    expect(pending.requiredEntryId, 'A');
    final result =
        ReaderNavigator.resolve(pending.request, documents: documents);
    expect(result.position, position('A', 2));
  });

  test(
      'new revision never silently carries old current position or annotations',
      () {
    final current = position('A', 2);
    final newer = {
      ...documents,
      'A': DocumentMetadata.ready(entryId: 'A', revisionId: 'r2', pageCount: 1)
    };
    final result = ReaderNavigator.resolve(request(current), documents: newer);
    expect(result.status, NavigationStatus.staleRevision);
    expect(result.position, current);
    expect(result.position.pageKey.revisionId, 'r1');
  });

  test('missing current document and invalid page are explicit failures', () {
    expect(
        ReaderNavigator.resolve(request(position('A', 2)),
            documents: {'A': DocumentMetadata.missing('A')}).status,
        NavigationStatus.missingTarget);
    expect(
        ReaderNavigator.resolve(request(position('A', 4)), documents: documents)
            .status,
        NavigationStatus.invalidPosition);
    expect(
        () =>
            DocumentMetadata.ready(entryId: 'A', revisionId: 'r', pageCount: 0),
        throwsArgumentError);
    expect(DocumentMetadata.image(entryId: 'A', revisionId: 'r').pageCount, 1);
  });

  test('removed queue item cannot serve as a valid current item', () {
    final removedQueue = [
      item('item-A', 'A'),
      item('item-B', 'B', removed: true),
      item('item-C', 'C')
    ];
    expect(
        ReaderNavigator.resolve(request(position('B', 1, itemId: 'item-B')),
                queue: removedQueue, documents: documents)
            .status,
        NavigationStatus.invalidPosition);
    // Explicitly removed items are no longer part of the queue.
    final next = ReaderNavigator.resolve(
        request(position('A', 3, itemId: 'item-A')),
        queue: removedQueue,
        documents: documents);
    expect(next.position, position('C', 1, itemId: 'item-C'));
  });

  test('metadata keyed to the wrong entry is not accepted', () {
    final wrong = {...documents, 'B': documents['C']!};
    final result = ReaderNavigator.resolve(
        request(position('A', 3, itemId: 'item-A')),
        queue: queue,
        documents: wrong);
    expect(result.status, NavigationStatus.invalidPosition);
  });
}
