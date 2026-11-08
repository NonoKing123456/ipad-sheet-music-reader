/// Display only: pass a physical file basename, never a folder or content title.
/// The actual filesystem name and path remain unchanged.
String physicalFileDisplayName(String basename) =>
    _withoutPhysicalSuffix(basename);

/// Display/search path retaining every directory segment and its punctuation.
/// Only the supported format suffix on the final physical filename is hidden.
String physicalFileDisplayPath(String path) => _withoutPhysicalSuffix(path);

final _physicalSuffix =
    RegExp(r'\.(?:pdf|jpe?g|png|webp)$', caseSensitive: false);
String _withoutPhysicalSuffix(String value) =>
    value.replaceFirst(_physicalSuffix, '');
final _words = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", unicode: true);

bool _isHan(int rune) =>
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x323af);

class _SearchWord {
  const _SearchWord(this.text, this.chinese);
  final String text;
  final bool chinese;
}

List<_SearchWord> _tokenize(String text) {
  final result = <_SearchWord>[];
  for (final match in _words.allMatches(text)) {
    var buffer = StringBuffer();
    bool? chinese;
    for (final rune in match.group(0)!.runes) {
      // Internal contractions stay one word: Don't -> dont, never don / t.
      if (rune == 0x27 || rune == 0x2019) continue;
      final nextChinese = _isHan(rune);
      if (chinese != null && chinese != nextChinese) {
        result.add(_SearchWord(buffer.toString(), chinese));
        buffer = StringBuffer();
      }
      chinese = nextChinese;
      buffer.writeCharCode(rune);
    }
    if (chinese != null) result.add(_SearchWord(buffer.toString(), chinese));
  }
  return List.unmodifiable(result);
}

/// Start of the first literal complete-query highlight at a legal search
/// boundary, or -1. This retains the existing single-span presentation; query
/// abbreviations never create additional or disjoint highlight spans.
int searchHighlightStart(String text, String query) {
  final needle = query.trim();
  final firstWord = _words.firstMatch(needle);
  if (firstWord == null) return -1;
  final starts = <int>{};
  for (final word in _words.allMatches(text)) {
    starts.add(word.start);
    var offset = word.start;
    bool? wasChinese;
    for (final rune in word.group(0)!.runes) {
      final width = rune > 0xffff ? 2 : 1;
      if (rune != 0x27 && rune != 0x2019) {
        final chinese = _isHan(rune);
        if (chinese || wasChinese == true) starts.add(offset);
        wasChinese = chinese;
      }
      offset += width;
    }
  }
  // Match against the original text so case conversion cannot shift offsets.
  final literal = RegExp(RegExp.escape(needle),
      caseSensitive: false, unicode: true);
  for (final wordStart in starts) {
    final start = wordStart - firstWord.start;
    if (start >= 0 && literal.matchAsPrefix(text, start) != null) return start;
  }
  return -1;
}

/// Immutable, pure-Dart search material. Prepare once while building metadata
/// indexes; matching subsequent keystrokes never splits the target text again.
/// Punctuation is a word boundary. Han/Latin transitions are boundaries too;
/// no dictionary, CamelCase splitting, transliteration or fuzzy matching occurs.
class PreparedSearchText {
  PreparedSearchText(String text) : this._(text.toLowerCase());
  PreparedSearchText._(this.normalized) : _tokens = _tokenize(normalized);
  factory PreparedSearchText.physicalPath(String path) =>
      PreparedSearchText(physicalFileDisplayPath(path));

  /// Join metadata already prepared in a worker, without splitting it again.
  factory PreparedSearchText.withPrefix(
          PreparedSearchText prefix, PreparedSearchText path) =>
      PreparedSearchText._prepared('${prefix.normalized}/${path.normalized}',
          List.unmodifiable([...prefix._tokens, ...path._tokens]));
  PreparedSearchText._prepared(this.normalized, this._tokens);
  final String normalized;
  final List<_SearchWord> _tokens;
}

/// Compile once per query, then reuse against every prepared target.
class SearchQuery {
  SearchQuery(String query)
      : _tokens = _tokenize(query.toLowerCase()),
        _hasInput = query.trim().isNotEmpty;

  /// Accept a pasted physical filename/path while keeping a bare format word
  /// searchable. Content/outline searches must use the plain constructor.
  factory SearchQuery.physicalPath(String query) {
    query = query.trim();
    final stripped = physicalFileDisplayPath(query);
    final lastSegment = stripped.split(RegExp(r'[/\\]')).last;
    return SearchQuery(_words.hasMatch(lastSegment) ? stripped : query);
  }
  final List<_SearchWord> _tokens;
  final bool _hasInput;

  bool matches(PreparedSearchText target) {
    if (_tokens.isEmpty) return !_hasInput;
    // Preserve Chinese substring search, including the existing independently
    // entered Chinese fragments. Mixed queries use the ordered sequence below.
    if (_tokens.every((word) => word.chinese)) {
      return _tokens.every((word) => target.normalized.contains(word.text));
    }
    final words = target._tokens;
    for (var start = 0; start <= words.length - _tokens.length; start++) {
      var matches = true;
      for (var offset = 0; offset < _tokens.length; offset++) {
        final queryWord = _tokens[offset], word = words[start + offset];
        if (queryWord.chinese != word.chinese ||
            !(queryWord.chinese
                ? word.text.contains(queryWord.text)
                : word.text.startsWith(queryWord.text))) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }
}
