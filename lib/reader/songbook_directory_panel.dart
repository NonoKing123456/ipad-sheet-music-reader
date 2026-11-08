import 'dart:async';

import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart';
import 'package:library_sync/library_sync.dart';

import '../songbook/songbook_service.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';

/// The index is loaded independently of the reader's page rendering pipeline.
class SongbookDirectoryPanel extends StatefulWidget {
  const SongbookDirectoryPanel({
    super.key,
    required this.service,
    required this.documentKey,
    required this.title,
    required this.pageCount,
    required this.currentPage,
    required this.compact,
    required this.onJump,
    required this.onClose,
  });
  final SongbookService service;
  final PageMetadataKey documentKey;
  final String title;
  final int pageCount, currentPage;
  final bool compact;
  final ValueChanged<int> onJump;
  final VoidCallback onClose;

  @override
  State<SongbookDirectoryPanel> createState() => _SongbookDirectoryPanelState();
}

class _SongbookDirectoryPanelState extends State<SongbookDirectoryPanel> {
  SongbookIndex? _index;
  SearchQuery _searchQuery = SearchQuery('');
  SongbookIndex? _preparedIndex;
  Map<String, PreparedSearchText> _preparedItems = {};
  bool _loading = true, _editing = false, _saving = false;
  String? _selectedId, _error;
  bool _adding = false;
  int _epoch = 0;
  final _name = TextEditingController();
  final _page = TextEditingController();
  final _scroll = ScrollController();
  final _editorKey = GlobalKey();

  void _revealEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final editor = _editorKey.currentContext;
      if (mounted && editor != null) {
        unawaited(
          Scrollable.ensureVisible(
            editor,
            duration: ScoreMotion.panel,
            alignment: 1,
          ),
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _revealEditor();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SongbookDirectoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentKey != widget.documentKey ||
        oldWidget.service != widget.service) {
      _index = null;
      _selectedId = null;
      _adding = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _name.dispose();
    _page.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reread = false}) async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final index = await widget.service.load(
        widget.documentKey,
        reread: reread,
      );
      if (mounted && epoch == _epoch) setState(() => _index = index);
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '目录读取失败，可重试；曲谱仍可正常阅读。');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  void _select(SongbookItem? item) {
    _revealEditor();
    setState(() {
      _adding = item == null;
      _selectedId = item?.id;
      _name.text = item?.title ?? '';
      _page.text = '${item?.pageNumber ?? widget.currentPage}';
      _error = item?.needsReview == true ? '文件已更新，请核对 PDF 页码后保存。' : null;
    });
  }

  Future<void> _save() async {
    final page = int.tryParse(_page.text.trim());
    if (_name.text.trim().isEmpty ||
        page == null ||
        page < 1 ||
        page > widget.pageCount) {
      setState(() => _error = '填写名称和 1–${widget.pageCount} 的 PDF 实际页码。');
      return;
    }
    SongbookItem? selected;
    for (final item in _index?.items ?? <SongbookItem>[]) {
      if (item.id == _selectedId) selected = item;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final index = await widget.service.saveItem(
        widget.documentKey,
        itemId: selected?.id,
        title: _name.text.trim(),
        pageNumber: page,
        ancestors: selected?.ancestors ?? const [],
      );
      if (mounted) {
        setState(() {
          _index = index;
          _adding = false;
          _selectedId = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '目录保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _editor() => SizedBox(
    key: _editorKey,
    height: ReaderNavigationTokens.directoryEditorHeight,
    child: ColoredBox(
      color: ScoreTokens.of(context).pineWash,
      child: Padding(
        padding: const EdgeInsets.all(ScoreSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('名称', style: ScoreText.note),
            TextField(
              key: const ValueKey('songbook-edit-title'),
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(isDense: true),
            ),
            const SizedBox(height: ScoreSpace.sm),
            Text('PDF 实际页码', style: ScoreText.note),
            Row(
              children: [
                SizedBox(
                  width: ReaderNavigationTokens.directoryPageInputWidth,
                  child: TextField(
                    key: const ValueKey('songbook-edit-page'),
                    controller: _page,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _saving ? null : _save(),
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                const SizedBox(width: ScoreSpace.sm),
                Text('/ ${widget.pageCount}', style: ScoreText.note),
              ],
            ),
            const Spacer(),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存条目'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final source = _index?.items ?? <SongbookItem>[];
    final originalOrder = {
      for (var i = 0; i < source.length; i++) source[i].id: i,
    };
    final descendantPages = <String, int>{};
    for (final item in source) {
      final page = item.pageNumber;
      if (page == null) continue;
      for (var depth = 1; depth <= item.ancestors.length; depth++) {
        final path = item.ancestors.take(depth).join('\u0000');
        final before = descendantPages[path];
        if (before == null || page < before) descendantPages[path] = page;
      }
    }
    int orderPage(SongbookItem item) =>
        item.pageNumber ??
        descendantPages[[...item.ancestors, item.title].join('\u0000')] ??
        widget.pageCount + 1;
    final all = [...source]
      ..sort((a, b) {
        final byPage = orderPage(a).compareTo(orderPage(b));
        if (byPage != 0) return byPage;
        final byDepth = a.ancestors.length.compareTo(b.ancestors.length);
        return byDepth != 0
            ? byDepth
            : originalOrder[a.id]!.compareTo(originalOrder[b.id]!);
      });
    if (!identical(_preparedIndex, _index)) {
      _preparedIndex = _index;
      _preparedItems = {
        for (final item in source)
          item.id: PreparedSearchText('${item.ancestors.join(' ')} ${item.title}'),
      };
    }
    final items = all
        .where((item) => _searchQuery.matches(_preparedItems[item.id]!))
        .toList();
    String? currentId;
    int nearest = 0;
    for (final item in all) {
      final page = item.pageNumber;
      if (!item.needsReview &&
          page != null &&
          page <= widget.currentPage &&
          page >= nearest) {
        nearest = page;
        currentId = item.id;
      }
    }
    return Material(
      key: const ValueKey('songbook-directory-panel'),
      color: t.paper0,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ScoreSpace.md,
                ScoreSpace.sm,
                ScoreSpace.xs,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing ? '编辑目录' : '目录',
                      style: ScoreText.title,
                    ),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            _editing = !_editing;
                            _adding = false;
                            _selectedId = null;
                          }),
                    child: Text(_editing ? '完成' : '编辑'),
                  ),
                  IconButton(
                    tooltip: '关闭目录',
                    onPressed: widget.onClose,
                    icon: const ReaderIcon(ReaderGlyph.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  physicalFileDisplayName(widget.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScoreText.caption.copyWith(color: t.ink500),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(ScoreSpace.md),
              child: SizedBox(
                height: ReaderNavigationTokens.directorySearchHeight,
                child: TextField(
                  style: ScoreText.body,
                  key: const ValueKey('songbook-directory-search'),
                  onChanged: (value) =>
                      setState(() => _searchQuery = SearchQuery(value)),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: t.paper2,
                    border: const OutlineInputBorder(
                      borderRadius: ScoreRadius.controlAll,
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: const OutlineInputBorder(
                      borderRadius: ScoreRadius.controlAll,
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: ScoreRadius.controlAll,
                      borderSide: BorderSide(color: t.pine),
                    ),
                    hintText: '搜索曲目或章节',
                    prefixIcon: const Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: ReaderIcon(ReaderGlyph.search),
                    ),
                  ),
                ),
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(
                minHeight: ReaderNavigationTokens.progressHeight,
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.md),
                child: Text(
                  _error!,
                  style: ScoreText.note.copyWith(color: t.warnInk),
                ),
              ),
            if (all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${all.length} 条索引',
                        style: ScoreText.caption.copyWith(color: t.ink500),
                      ),
                    ),
                    SizedBox(
                      width: ReaderNavigationTokens.directoryPageColumn,
                      child: Text(
                        '页码',
                        textAlign: TextAlign.right,
                        style: ScoreText.caption.copyWith(color: t.ink500),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: all.isEmpty && !_loading && !_adding
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const ReaderIcon(ReaderGlyph.book),
                          const SizedBox(height: ScoreSpace.md),
                          Text('还没有目录', style: ScoreText.body),
                          const SizedBox(height: ScoreSpace.md),
                          FilledButton(
                            onPressed: () {
                              _editing = true;
                              _select(null);
                            },
                            child: const Text('添加当前页'),
                          ),
                        ],
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: ScoreSpace.md,
                        ),
                        itemCount: items.length + (_adding ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == items.length) return _editor();
                          final item = items[index];
                          final selected = _editing
                              ? item.id == _selectedId
                              : item.id == currentId;
                          final valid =
                              !item.needsReview &&
                              item.pageNumber != null &&
                              item.pageNumber! >= 1 &&
                              item.pageNumber! <= widget.pageCount;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: [
                                  ...item.ancestors,
                                  item.title,
                                ].join(' / '),
                                child: Material(
                                  color: selected ? t.pineWash : t.paper0,
                                  child: InkWell(
                                    onTap: _saving
                                        ? null
                                        : () {
                                            if (_editing || item.needsReview) {
                                              if (item.needsReview) {
                                                _editing = true;
                                              }
                                              _select(item);
                                            } else if (valid) {
                                              widget.onJump(item.pageNumber!);
                                            }
                                          },
                                    child: Container(
                                      height: widget.compact
                                          ? ReaderNavigationTokens
                                                .directoryTouchRow
                                          : ReaderNavigationTokens
                                                .directoryMouseRow,
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(color: t.hair2),
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: ScoreSpace.xs,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width:
                                                item.ancestors.length.clamp(
                                                  0,
                                                  3,
                                                ) *
                                                ScoreSpace.sm,
                                          ),
                                          Expanded(
                                            child: Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: ScoreText.body.copyWith(
                                                color: selected
                                                    ? t.pine
                                                    : t.ink900,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: ReaderNavigationTokens
                                                .directoryPageColumn,
                                            child: Text(
                                              item.needsReview
                                                  ? '待核对'
                                                  : '${item.pageNumber ?? '—'}',
                                              textAlign: TextAlign.right,
                                              style: ScoreText.caption.copyWith(
                                                color: valid
                                                    ? t.ink500
                                                    : t.warnInk,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_editing && selected) _editor(),
                            ],
                          );
                        },
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () {
                            _editing = true;
                            _select(null);
                          },
                    child: const Text('添加当前页'),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    tooltip: '更多目录操作',
                    icon: const ReaderIcon(ReaderGlyph.more),
                    enabled: !_saving && !_loading,
                    onSelected: (_) => unawaited(_load(reread: true)),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'reread',
                        child: Text('重新读取 PDF 目录（保留人工修改）'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
