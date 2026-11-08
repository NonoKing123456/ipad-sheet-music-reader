import 'dart:async';

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
  });
  final SongbookService? service;
  final String query;
  final Widget Function(List<SongbookSearchHit>) builder;
  @override
  State<SongbookSearchBuilder> createState() => _SongbookSearchBuilderState();
}

class _SongbookSearchBuilderState extends State<SongbookSearchBuilder> {
  List<SongbookSearchHit> _hits = const [];
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.service?.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SongbookSearchBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service?.removeListener(_refresh);
      widget.service?.addListener(_refresh);
    }
    if (oldWidget.query != widget.query ||
        oldWidget.service != widget.service) {
      _hits = const [];
      _refresh();
    }
  }

  void _refresh() {
    final epoch = ++_epoch;
    final service = widget.service;
    if (service == null || widget.query.trim().isEmpty) {
      if (mounted && _hits.isNotEmpty) setState(() => _hits = const []);
      return;
    }
    unawaited(
      service
          .search(widget.query)
          .then((hits) {
            if (mounted && epoch == _epoch) setState(() => _hits = hits);
          })
          .catchError((Object _) {
            if (mounted && epoch == _epoch) setState(() => _hits = const []);
          }),
    );
  }

  @override
  void dispose() {
    _epoch++;
    widget.service?.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_hits);
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
  Widget build(BuildContext context) => LibraryFileRow(
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
    onTap: onOpen,
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
