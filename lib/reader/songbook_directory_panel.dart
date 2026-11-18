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
  final _search = TextEditingController();
  SearchQuery _searchQuery = SearchQuery('');
  SongbookIndex? _preparedIndex;
  Map<String, PreparedSearchText> _preparedItems = {};
  bool _loading = true, _editing = false, _saving = false;
  String? _selectedId, _error;
  bool _adding = false;
  (String, String) _initialDraft = ('', '');
  int _epoch = 0;
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _page = TextEditingController();
  final _scroll = ScrollController();
  final _editorKey = GlobalKey();

  void _revealEditor({bool focusTitle = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final editor = _editorKey.currentContext;
      if (mounted && editor != null) {
        if (focusTitle && _adding) _nameFocus.requestFocus();
        unawaited(
          Scrollable.ensureVisible(
            editor,
            duration: ScoreMotion.panel,
            alignment: _adding ? 0 : 1,
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
      _saving = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _search.dispose();
    _name.dispose();
    _nameFocus.dispose();
    _page.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setQuery(String value) =>
      setState(() => _searchQuery = SearchQuery(value));

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

  bool get _draftChanged =>
      (_adding || _selectedId != null) &&
      (_name.text, _page.text) != _initialDraft;

  Future<void> _select(SongbookItem? item) async {
    if (_saving || item != null && item.id == _selectedId) return;
    if (_draftChanged) {
      if (!await _save() || !mounted) return;
      if (item != null) {
        final id = item.id;
        item = _index?.items.where((entry) => entry.id == id).firstOrNull;
        if (item == null) return;
      }
    }
    if (item == null && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.minScrollExtent);
    }
    _revealEditor(focusTitle: item == null);
    setState(() {
      _adding = item == null;
      _selectedId = item?.id;
      _name.text = item?.title ?? '';
      _page.text = item == null
          ? '${widget.currentPage}'
          : item.pageNumber?.toString() ?? '';
      _initialDraft = (_name.text, _page.text);
      _error = item?.needsReview == true ? '文件已更新，请核对 PDF 页码后保存。' : null;
    });
  }

  void _toggleEditing() {
    if (_saving) return;
    if (_editing && _draftChanged) {
      unawaited(_save(finishEditing: true));
      return;
    }
    setState(() {
      _editing = !_editing;
      _adding = false;
      _selectedId = null;
    });
  }

  Future<bool> _save({bool finishEditing = false}) async {
    if (_saving) return false;
    final epoch = _epoch;
    final selected = _index?.items
        .where((item) => item.id == _selectedId)
        .firstOrNull;
    final keepHeading =
        selected != null &&
        selected.pageNumber == null &&
        _page.text.trim().isEmpty;
    final page = int.tryParse(_page.text.trim());
    if (_name.text.trim().isEmpty ||
        !keepHeading && (page == null || page < 1 || page > widget.pageCount)) {
      setState(() => _error = '填写名称和 1–${widget.pageCount} 的 PDF 实际页码。');
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final index = await widget.service.saveItem(
        widget.documentKey,
        itemId: _selectedId,
        title: _name.text.trim(),
        pageNumber: page,
        ancestors: selected?.ancestors ?? const [],
      );
      if (mounted && epoch == _epoch) {
        setState(() {
          _index = index;
          _adding = false;
          _selectedId = null;
          if (finishEditing) _editing = false;
        });
        return true;
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '目录保存失败，请重试。');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _saving = false);
    }
    return false;
  }

  Widget _editor() => ConstrainedBox(
    key: _editorKey,
    constraints: const BoxConstraints(
      minHeight: ReaderNavigationTokens.directoryEditorHeight,
    ),
    child: ColoredBox(
      color: ScoreTokens.of(context).pineWash,
      child: Padding(
        padding: const EdgeInsets.all(ScoreSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('名称', style: ScoreText.note),
                TextField(
                  key: const ValueKey('songbook-edit-title'),
                  controller: _name,
                  focusNode: _nameFocus,
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
              ],
            ),
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
          item.id: PreparedSearchText(
            '${item.ancestors.join(' ')} ${item.title}',
          ),
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
                    onPressed: _saving ? null : _toggleEditing,
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
                  controller: _search,
                  onChanged: _setQuery,
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
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            icon: const ReaderIcon(ReaderGlyph.close),
                            onPressed: () {
                              _search.clear();
                              _setQuery('');
                            },
                          ),
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
                        _search.text.trim().isEmpty
                            ? '${all.length} 条索引'
                            : '匹配 ${items.length} 条，共 ${all.length} 条索引',
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
                  : items.isEmpty && all.isNotEmpty && !_adding && !_loading
                  ? Center(child: Text('未找到匹配的目录项', style: ScoreText.body))
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
                          if (_adding && index == 0) return _editor();
                          final item = items[_adding ? index - 1 : index];
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
