import 'dart:async';

import 'package:reader_state/reader_state.dart';

import '../reader/reader_session.dart';
import 'recent_reading_store.dart';

/// One observer per reader route. Pages in a book do not rewrite its history;
/// moving A → B → A in a set list records all three successful openings.
class RecentPresentationObserver {
  RecentPresentationObserver(this.store, {this.onLoaded, this.clock});
  final RecentReadingStore store;
  final void Function(LoadedScore)? onLoaded;
  final DateTime Function()? clock;
  LoadedScore? _loaded;
  DocumentKey? _presented;
  void loaded(LoadedScore score) {
    _loaded = score;
    onLoaded?.call(score);
  }

  void presented(PageKey page) {
    final score = _loaded;
    if (score == null ||
        score.target.key != page.document ||
        _presented == page.document) {
      return;
    }
    _presented = page.document;
    final target = score.target;
    unawaited(
      store.record(
        RecentReading(
          entryId: page.entryId,
          revisionId: page.revisionId,
          path: target.displayPath,
          contextLabel: target.parentFolderLabel ?? '',
          openedAt: clock?.call() ?? DateTime.now(),
          pageCount: score.pageCount,
        ),
      ),
    );
  }
}
