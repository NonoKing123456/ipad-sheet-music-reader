import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum FirstPageArrangement { alone, paired }

enum ReaderViewMode { single, spread, continuous }

class ReaderSpread {
  const ReaderSpread(this.index, this.first, this.last);
  final int index, first, last;
  bool contains(int page) => first <= page && page <= last;
  Iterable<int> get pages sync* {
    yield first;
    if (last != first) yield last;
  }
}

/// Page grouping is independent of rendering, bookmarks and annotations.
class ReaderSpreads {
  const ReaderSpreads({
    required this.pageCount,
    required this.doublePage,
    this.arrangement = FirstPageArrangement.paired,
  });
  final int pageCount;
  final bool doublePage;
  final FirstPageArrangement arrangement;
  bool get _firstAlone =>
      doublePage && arrangement == FirstPageArrangement.alone;
  int get count => !doublePage
      ? pageCount
      : _firstAlone
      ? 1 + pageCount ~/ 2
      : (pageCount + 1) ~/ 2;
  ReaderSpread forPage(int page) {
    page = page.clamp(1, pageCount);
    if (!doublePage) return ReaderSpread(page, page, page);
    if (_firstAlone && page == 1) return const ReaderSpread(1, 1, 1);
    final offset = _firstAlone ? 2 : 1;
    final first = offset + ((page - offset) ~/ 2) * 2;
    return ReaderSpread(
      (page - offset) ~/ 2 + (_firstAlone ? 2 : 1),
      first,
      (first + 1).clamp(1, pageCount),
    );
  }

  ReaderSpread at(int index) {
    index = index.clamp(1, count);
    if (!doublePage) return ReaderSpread(index, index, index);
    if (_firstAlone && index == 1) return const ReaderSpread(1, 1, 1);
    final first = _firstAlone ? 2 + (index - 2) * 2 : 1 + (index - 1) * 2;
    return ReaderSpread(index, first, (first + 1).clamp(1, pageCount));
  }

  int? adjacent(int focusPage, int direction) {
    final index = forPage(focusPage).index + direction;
    return index < 1 || index > count ? null : at(index).first;
  }
}

/// Windows-only local viewing preferences. They never enter reader_state or
/// peer sync. External read-only files do not get persistent entry identities.
class DesktopReaderPreferences {
  DesktopReaderPreferences._(this.path);
  final String path;
  ReaderViewMode mode = ReaderViewMode.single;
  final _firstPages = <String, FirstPageArrangement>{};
  Future<void> _writes = Future.value();
  static final _opened = <String, Future<DesktopReaderPreferences>>{};
  static Future<DesktopReaderPreferences> open(String path) =>
      _opened.putIfAbsent(path, () async {
        final preferences = DesktopReaderPreferences._(path);
        for (final candidate in [File(path), File('$path.backup')]) {
          try {
            if (!await candidate.exists()) continue;
            final json = jsonDecode(await candidate.readAsString()) as Map;
            if (json['schema'] != 1) continue;
            preferences.mode = ReaderViewMode.values.firstWhere(
              (value) => value.name == json['mode'],
              orElse: () => json['doublePage'] == true
                  ? ReaderViewMode.spread
                  : ReaderViewMode.single,
            );
            for (final entry in (json['firstPages'] as Map? ?? {}).entries) {
              if (entry.key is String && entry.value == 'alone') {
                preferences._firstPages[entry.key as String] =
                    FirstPageArrangement.alone;
              }
            }
            break;
          } catch (_) {
            /* A view preference falls back without touching notes. */
          }
        }
        return preferences;
      });
  FirstPageArrangement arrangementFor(String entryId) =>
      _firstPages[entryId] ?? FirstPageArrangement.paired;
  Map<String, FirstPageArrangement> get arrangements =>
      Map.unmodifiable(_firstPages);
  Future<void> setMode(ReaderViewMode value) {
    mode = value;
    return _save();
  }

  Future<void> setArrangement(String entryId, FirstPageArrangement value) {
    if (value == FirstPageArrangement.paired) {
      _firstPages.remove(entryId);
    } else {
      _firstPages[entryId] = value;
    }
    return _save();
  }

  Future<void> _save() =>
      _writes = _writes.catchError((Object _) {}).then((_) async {
        final target = File(path),
            backup = File('$path.backup'),
            temp = File('$path.tmp');
        await target.parent.create(recursive: true);
        await temp.writeAsString(
          jsonEncode({
            'schema': 1,
            'mode': mode.name,
            'firstPages': {for (final id in _firstPages.keys) id: 'alone'},
          }),
          flush: true,
        );
        if (await target.exists()) {
          if (await backup.exists()) await backup.delete();
          await target.rename(backup.path);
        }
        await temp.rename(path);
      });
}
