import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';

import '../library/library_widgets.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'songbook_service.dart';

class SongbookSearchBuilder extends StatefulWidget {
  const SongbookSearchBuilder({
    super.key,
    required this.service,
    required this.query,
    required this.builder,
    this.scope,
    this.includeBook,
  });
  final SongbookService? service;
  final String query;

  /// Changes with the active catalog, source or folder selection.
  final Object? scope;
  final bool Function(PageMetadataKey)? includeBook;
  final Widget Function(List<SongbookSearchHit> hits, Widget? status) builder;
  @override
  State<SongbookSearchBuilder> createState() => _SongbookSearchBuilderState();
}

class _SongbookSearchBuilderState extends State<SongbookSearchBuilder> {
  List<SongbookSearchHit> _hits = const [];
  bool _loading = false;
  bool _failed = false;
  int _epoch = 0;
  Future<Set<PageMetadataKey>>? _books;
  @override
  void initState() {
    super.initState();
    widget.service?.addListener(_indexChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SongbookSearchBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service?.removeListener(_indexChanged);
      widget.service?.addListener(_indexChanged);
    }
    final scopeChanged =
        oldWidget.scope != widget.scope || oldWidget.service != widget.service;
    if (scopeChanged) _books = null;
    if (scopeChanged || oldWidget.query != widget.query) {
      _hits = const [];
      _refresh();
    }
  }

  void _indexChanged() {
    _books = null;
    _refresh();
  }

  Future<void> _refresh() async {
    final epoch = ++_epoch;
    final service = widget.service;
    _failed = false;
    if (service == null || widget.query.trim().isEmpty) {
      setState(() {
        _hits = const [];
        _loading = false;
      });
      return;
    }
    final query = widget.query, include = widget.includeBook;
    setState(() => _loading = true);
    try {
      final hits = include == null
          ? await service.search(query)
          : await service.searchBooks(
              query,
              await (_books ??= service.indexedBooksWhere(include)),
            );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      _books = null;
      setState(() {
        _hits = const [];
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _epoch++;
    widget.service?.removeListener(_indexChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget? status;
    if (_failed) {
      status = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('谱本内曲目暂时查不到'),
          LibraryOutsideTapExclusion(
            child: TextButton(onPressed: _refresh, child: const Text('重试')),
          ),
        ],
      );
    } else if (_loading && _hits.isEmpty) {
      status = const Text('正在查找谱本内曲目…');
    }
    return widget.builder(_hits, status);
  }
}

class SongbookSearchResultRow extends StatelessWidget {
  const SongbookSearchResultRow({
    super.key,
    required this.hit,
    required this.pathLabel,
    required this.onOpen,
  });
  final SongbookSearchHit hit;
  final String pathLabel;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => LibraryOutsideTapExclusion(
    child: LibraryFileRow(
      key: ValueKey(('songbook-result', hit.key, hit.item.id)),
      leading: const ReaderIcon(ReaderGlyph.book),
      name: hit.item.title,
      subtitle:
          '${physicalFileDisplayPath(pathLabel)}${hit.item.ancestors.isEmpty ? '' : ' / ${hit.item.ancestors.join(' / ')}'}',
      metadata: Row(
        children: [
          SizedBox(
            width: ScoreLayout.typeColumn,
            child: Text(
              '目录',
              style: ScoreText.caption.copyWith(
                color: ScoreTokens.of(context).pineDeep,
              ),
            ),
          ),
          Expanded(
            child: Text(
              hit.item.needsReview
                  ? '待核对'
                  : hit.item.pageNumber == null
                  ? '章节'
                  : '第${hit.item.pageNumber}页',
              textAlign: TextAlign.right,
              style: ScoreText.caption.copyWith(
                color: ScoreTokens.of(context).ink500,
              ),
            ),
          ),
        ],
      ),
      onTap: hit.item.needsReview
          ? () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('文件已更新，请打开目录核对 PDF 页码。')),
            )
          : hit.item.canNavigate
          ? onOpen
          : null,
    ),
  );
}

Widget songbookResultHeading(BuildContext context, String label) => Padding(
  padding: const EdgeInsets.symmetric(
    horizontal: ScoreSpace.sm,
    vertical: ScoreSpace.sm,
  ),
  child: Align(
    alignment: Alignment.centerLeft,
    child: Text(
      label,
      style: ScoreText.note.copyWith(color: ScoreTokens.of(context).ink500),
    ),
  ),
);
