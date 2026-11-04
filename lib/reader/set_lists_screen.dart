import '../library/score_path_label.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';
import 'package:library_sync/library_sync.dart' show PageMetadataKey;

import '../theme/tokens.dart';
import '../theme/reader_icons.dart';
import '../theme/device_layout.dart';
import '../theme/app_theme.dart';
import '../library/score_file_icon.dart';
import '../library/page_count_service.dart';

import 'library_reader_screen.dart';
import 'reader_session.dart';
import 'reader_workspace.dart';

Future<String?> _nameDialog(BuildContext context, {String initial = ''}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: initial),
    );

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});
  final String initial;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial.isEmpty ? '创建曲单' : '曲单名称'),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: '曲单名称'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}

class SetListsScreen extends StatelessWidget {
  const SetListsScreen({
    super.key,
    required this.workspace,
    required this.locate,
    required this.targets,
    this.sourceChanges,
    this.loader,
    this.catalog,
    this.prepare,
    this.preparationLabel = '准备本曲单',
    this.preparationNotice = '需要来源可用。',
    this.initialListId,
    this.initialCreate = false,
    this.embedded = false,
    this.onSelectionChanged,
    this.onBack,
    this.pageCounts,
  });
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final List<ScoreTarget> Function() targets;
  final Listenable? sourceChanges;
  final ScoreLoader? loader;
  final ScoreCatalogProvider? catalog;
  final ScorePreparation? prepare;
  final String preparationLabel, preparationNotice;
  final String? initialListId;
  final bool initialCreate;
  final bool embedded;
  final ValueChanged<String?>? onSelectionChanged;
  final VoidCallback? onBack;
  final PageCountService? pageCounts;

  Future<void> _create(BuildContext context) async {
    final name = await _nameDialog(context);
    if (name != null) {
      await workspace.edit((store) => store.createSetList(name));
    }
  }

  @override
  Widget build(BuildContext context) => _SetListsEntry(screen: this);

  Widget _overview(
    BuildContext context, {
    ValueChanged<String>? onSelect,
  }) => AnimatedBuilder(
    animation: workspace,
    builder: (context, _) {
      final lists = workspace.store.snapshot.activeSetLists,
          tokens = ScoreTokens.of(context);
      return _setListSurface(
        context,
        embedded: embedded,
        child: Column(
          children: [
            _SetListHeader(onBack: onBack ?? () => Navigator.maybePop(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ScoreSpace.xxl,
                ScoreSpace.lg,
                ScoreSpace.xxl,
                ScoreSpace.xl,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${lists.length} 个曲单',
                      style: ScoreText.caption.copyWith(color: tokens.ink500),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _create(context),
                    icon: const ReaderIcon(ReaderGlyph.plus),
                    label: const Text('新建曲单'),
                  ),
                ],
              ),
            ),
            if (workspace.error != null)
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.lg),
                child: Text(
                  workspace.error!,
                  style: ScoreText.caption.copyWith(color: tokens.dangerInk),
                ),
              ),
            if (workspace.store.storageWarnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.lg),
                child: Text(
                  '已从备份恢复，请检查最近修改。',
                  style: ScoreText.caption.copyWith(color: tokens.warnInk),
                ),
              ),
            Expanded(
              child: lists.isEmpty
                  ? const Center(child: Text('创建曲单，把演出曲目按顺序放在一起。'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ScoreLayout.listMargin,
                      ),
                      itemCount: lists.length,
                      itemBuilder: (context, index) {
                        final list = lists[index];
                        void open() {
                          if (onSelect != null) {
                            onSelect(list.id);
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => _SetListDetail(
                                workspace: workspace,
                                listId: list.id,
                                locate: locate,
                                targets: targets,
                                sourceChanges: sourceChanges,
                                loader: loader,
                                catalog: catalog,
                                prepare: prepare,
                                preparationLabel: preparationLabel,
                                preparationNotice: preparationNotice,
                                pageCounts: pageCounts,
                              ),
                            ),
                          );
                        }

                        return SizedBox(
                          height: _setListRowHeight(context),
                          child: InkWell(
                            onTap: open,
                            splashFactory: NoSplash.splashFactory,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: ScoreLayout.iconColumn,
                                  child: ReaderIcon(
                                    ReaderGlyph.list,
                                    color: tokens.pine,
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        list.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ScoreText.headline.copyWith(
                                          color: tokens.ink900,
                                        ),
                                      ),
                                      Text(
                                        '${list.activeItems.length} 首曲谱',
                                        style: ScoreText.caption.copyWith(
                                          color: tokens.ink500,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(
                                  width: ScoreLayout.actionColumn,
                                  child: ReaderIcon(ReaderGlyph.chevronRight),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _setListSurface(
  BuildContext context, {
  required bool embedded,
  required Widget child,
}) {
  final theme = Theme.of(context);
  final tokens = ScoreTokens.of(context);
  final height = DeviceLayoutScope.isCompact(context)
      ? ScoreLayout.touchTarget
      : ScoreLayout.desktopTarget;
  final surface = embedded
      ? ColoredBox(color: ScoreTokens.of(context).paper1, child: child)
      : Scaffold(
          backgroundColor: ScoreTokens.of(context).paper1,
          body: SafeArea(child: child),
        );
  return Theme(
    data: theme.copyWith(
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: Size(0, height),
          foregroundColor: tokens.ink900,
          textStyle: theme.textTheme.labelLarge?.merge(ScoreText.caption),
          padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
          shape: const RoundedRectangleBorder(
            borderRadius: ScoreRadius.controlAll,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          backgroundColor: tokens.pineDeep,
          foregroundColor: tokens.onBrand,
          textStyle: theme.textTheme.labelLarge?.merge(ScoreText.caption),
          padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
          shape: const RoundedRectangleBorder(
            borderRadius: ScoreRadius.controlAll,
          ),
        ),
      ),
    ),
    child: surface,
  );
}

ButtonStyle _setListIconStyle(BuildContext context) => IconButton.styleFrom(
  foregroundColor: ScoreTokens.of(context).ink700,
  fixedSize: Size.square(
    DeviceLayoutScope.isCompact(context)
        ? ScoreLayout.touchTarget
        : ScoreLayout.desktopTarget,
  ),
  minimumSize: Size.zero,
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

double _setListRowHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final headline = ScoreText.headline.fontSize!,
      caption = ScoreText.caption.fontSize!;
  return ScoreLayout.setlistRowHeight +
      (scaler.scale(headline) - headline).clamp(0.0, double.infinity) *
          ScoreText.headline.height! +
      (scaler.scale(caption) - caption).clamp(0.0, double.infinity) *
          ScoreText.caption.height!;
}

double _setListTextWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

class _SetListHeader extends StatelessWidget {
  const _SetListHeader({required this.onBack, this.more});
  final VoidCallback onBack;
  final Widget? more;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: ScoreLayout.headerHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: ScoreLayout.listMargin),
      child: Row(
        children: [
          IconButton(
            style: _setListIconStyle(context),
            tooltip: '返回',
            onPressed: onBack,
            icon: const ReaderIcon(ReaderGlyph.back),
          ),
          const SizedBox(width: ScoreSpace.sm),
          Expanded(
            child: Text(
              '曲单',
              style: ScoreText.title.copyWith(
                color: ScoreTokens.of(context).ink900,
              ),
            ),
          ),
          const ThemeAction(),
          if (more != null) const SizedBox(width: ScoreSpace.sm),
          ?more,
        ],
      ),
    ),
  );
}

class _SetListsEntry extends StatefulWidget {
  const _SetListsEntry({required this.screen});
  final SetListsScreen screen;
  @override
  State<_SetListsEntry> createState() => _SetListsEntryState();
}

class _SetListsEntryState extends State<_SetListsEntry> {
  late String? _listId = widget.screen.initialListId;

  void _select(String? id) {
    setState(() => _listId = id);
    widget.screen.onSelectionChanged?.call(id);
  }

  @override
  void didUpdateWidget(covariant _SetListsEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screen.initialListId != widget.screen.initialListId) {
      _listId = widget.screen.initialListId;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.screen.initialCreate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.screen._create(context));
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.screen.workspace,
    builder: (context, _) {
      final screen = widget.screen, id = _listId;
      if (id != null &&
          screen.workspace.store.snapshot.activeSetLists.any(
            (list) => list.id == id,
          )) {
        return _SetListDetail(
          workspace: screen.workspace,
          listId: id,
          locate: screen.locate,
          targets: screen.targets,
          sourceChanges: screen.sourceChanges,
          loader: screen.loader,
          catalog: screen.catalog,
          prepare: screen.prepare,
          preparationLabel: screen.preparationLabel,
          preparationNotice: screen.preparationNotice,
          embedded: screen.embedded,
          onBack: screen.embedded ? screen.onBack ?? () => _select(null) : null,
          pageCounts: screen.pageCounts,
        );
      }
      return screen._overview(
        context,
        onSelect: screen.embedded ? _select : null,
      );
    },
  );
}

class _SetListDetail extends StatelessWidget {
  const _SetListDetail({
    required this.workspace,
    required this.listId,
    required this.locate,
    required this.targets,
    this.sourceChanges,
    this.loader,
    this.catalog,
    this.prepare,
    this.preparationLabel = '准备本曲单',
    this.preparationNotice = '需要来源可用。',
    this.embedded = false,
    this.onBack,
    this.pageCounts,
  });
  final ReaderWorkspace workspace;
  final String listId;
  final ScoreLocator locate;
  final List<ScoreTarget> Function() targets;
  final Listenable? sourceChanges;
  final ScoreLoader? loader;
  final ScoreCatalogProvider? catalog;
  final ScorePreparation? prepare;
  final String preparationLabel, preparationNotice;
  final bool embedded;
  final VoidCallback? onBack;
  final PageCountService? pageCounts;
  List<ScoreCatalogEntry> _catalogEntries() =>
      catalog?.call() ?? targets().map(ScoreCatalogEntry.fromTarget).toList();

  Future<void> _prepare(BuildContext context, Set<String> ids) async {
    final callback = prepare;
    if (callback == null) return;
    final entries = {
      for (final entry in _catalogEntries()) entry.entryId: entry,
    };
    final needed = ids
        .map((id) => entries[id])
        .whereType<ScoreCatalogEntry>()
        .where((entry) => entry.needsPreparation)
        .toList();
    if (needed.isEmpty) return;
    final known = needed.every((entry) => entry.bytes != null);
    final bytes = needed.fold<int>(
      0,
      (total, entry) => total + (entry.bytes ?? 0),
    );
    final size = !known
        ? '体积未知'
        : bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).toStringAsFixed(1)} KB';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('准备曲单曲谱'),
        content: Text('${needed.length} 份曲谱 · $size\n$preparationNotice'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始准备'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    String message;
    try {
      message = await callback(needed.map((entry) => entry.entryId).toSet());
    } catch (_) {
      message = '准备未完成，请检查连接后重试。';
    }
    if (context.mounted) {
      final current = {
        for (final entry in _catalogEntries()) entry.entryId: entry,
      };
      final unready = workspace.store.snapshot
          .setListById(listId)!
          .activeItems
          .map((item) => item.entryId)
          .toSet()
          .where((id) => current[id]?.readable != true)
          .length;
      if (unready > 0) message = '$message 本曲单仍有$unready份未准备。';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _open(
    BuildContext context,
    SetListItem item,
    ScoreCatalogEntry? metadata,
  ) async {
    if (metadata?.state == ScoreContentState.missing ||
        metadata?.state == ScoreContentState.sourceOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${metadata!.statusLabel}，请先恢复来源。')),
      );
      return;
    }
    var target = locate(item.entryId);
    if (target == null &&
        metadata?.needsPreparation == true &&
        prepare != null) {
      await _prepare(context, {item.entryId});
      if (!context.mounted) return;
      target = locate(item.entryId);
    }
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这份曲谱尚未准备，请连接电脑更新目录并准备本曲单。')),
      );
      return;
    }
    final ready = target;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LibraryReaderScreen(
          workspace: workspace,
          locate: locate,
          initialTarget: ready,
          setListId: listId,
          itemId: item.id,
          sourceChanges: sourceChanges,
          loader: loader,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([workspace, ?sourceChanges]),
    builder: (context, _) {
      final list = workspace.store.snapshot.setListById(listId);
      if (list == null || list.isDeleted) {
        return const Center(child: Text('曲单已移除'));
      }
      final items = list.activeItems, tokens = ScoreTokens.of(context);
      final metadata = {
        for (final entry in _catalogEntries()) entry.entryId: entry,
      };
      final needed = items
          .map((item) => item.entryId)
          .toSet()
          .where((id) => metadata[id]?.needsPreparation == true)
          .toSet();
      Future<void> add() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _AddScores(
          workspace: workspace,
          listId: listId,
          targets: _catalogEntries(),
        ),
      );
      final more = PopupMenuButton<String>(
        style: _setListIconStyle(context),
        constraints: const BoxConstraints.tightFor(
          width: ScoreLayout.menuWidth,
        ),
        tooltip: '曲单更多操作',
        icon: const ReaderIcon(ReaderGlyph.more),
        onSelected: (action) async {
          if (action == 'rename') {
            final name = await _nameDialog(context, initial: list.name);
            if (name != null) {
              await workspace.edit(
                (store) => store.renameSetList(listId, name),
              );
            }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'rename',
            height: ScoreLayout.touchTarget,
            child: Text('重命名曲单'),
          ),
        ],
      );
      return _setListSurface(
        context,
        embedded: embedded,
        child: Column(
          children: [
            _SetListHeader(
              onBack: onBack ?? () => Navigator.maybePop(context),
              more: more,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ScoreSpace.xxl,
                ScoreSpace.lg,
                ScoreSpace.xxl,
                ScoreSpace.xl,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final heading = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        list.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScoreText.title.copyWith(color: tokens.ink900),
                      ),
                      const SizedBox(height: ScoreSpace.xs),
                      Text(
                        '${items.length} 首 · 按演出顺序排列',
                        style: ScoreText.caption.copyWith(color: tokens.ink500),
                      ),
                    ],
                  );
                  final actions = Wrap(
                    alignment: WrapAlignment.end,
                    spacing: ScoreSpace.md,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (prepare != null && needed.isNotEmpty)
                        TextButton(
                          onPressed: () => unawaited(_prepare(context, needed)),
                          child: Text(preparationLabel),
                        ),
                      FilledButton.icon(
                        onPressed: items.isEmpty
                            ? null
                            : () => unawaited(
                                _open(
                                  context,
                                  items.first,
                                  metadata[items.first.entryId],
                                ),
                              ),
                        icon: const ReaderIcon(ReaderGlyph.play),
                        label: const Text('开始阅读'),
                      ),
                      TextButton.icon(
                        onPressed: add,
                        icon: const ReaderIcon(ReaderGlyph.plus),
                        label: const Text('添加曲谱'),
                      ),
                    ],
                  );
                  final labelStyle =
                      Theme.of(context).textTheme.labelLarge
                          ?.merge(ScoreText.caption) ??
                      ScoreText.caption;
                  double buttonWidth(String label, {bool icon = false}) =>
                      _setListTextWidth(context, label, labelStyle) +
                      ScoreSpace.lg * 2 +
                      (icon ? ScoreLayout.iconVisual + ScoreSpace.sm : 0);
                  final actionWidths = [
                    if (prepare != null && needed.isNotEmpty)
                      buttonWidth(preparationLabel),
                    buttonWidth('开始阅读', icon: true),
                    buttonWidth('添加曲谱', icon: true),
                  ];
                  final actionWidth =
                      actionWidths.fold<double>(
                        0,
                        (total, width) => total + width,
                      ) +
                      ScoreSpace.md * (actionWidths.length - 1);
                  final titleWidth = _setListTextWidth(
                    context,
                    list.name,
                    ScoreText.title,
                  );
                  final countWidth = _setListTextWidth(
                    context,
                    '${items.length} 首 · 按演出顺序排列',
                    ScoreText.caption,
                  );
                  final headingWidth = titleWidth > countWidth
                      ? titleWidth
                      : countWidth;
                  return headingWidth + ScoreSpace.lg + actionWidth <=
                          constraints.maxWidth
                      ? Row(
                          children: [
                            Expanded(child: heading),
                            const SizedBox(width: ScoreSpace.lg),
                            actions,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: ScoreSpace.sm),
                            Align(
                              alignment: Alignment.centerRight,
                              child: actions,
                            ),
                          ],
                        );
                },
              ),
            ),
            if (workspace.error != null)
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.lg),
                child: Text(
                  workspace.error!,
                  style: ScoreText.caption.copyWith(color: tokens.dangerInk),
                ),
              ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('从曲库添加需要演出的曲谱。'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ScoreLayout.listMargin,
                      ),
                      buildDefaultDragHandles: false,
                      itemCount: items.length,
                      onReorderItem: (oldIndex, newIndex) => unawaited(
                        workspace.edit(
                          (store) => store.reorderItem(
                            listId,
                            items[oldIndex].id,
                            newIndex,
                          ),
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final item = items[index],
                            target = metadata[items[index].entryId];
                        final displayPath = target?.displayPath ?? '目录尚未更新的曲谱';
                        final filename = p.posix.basename(
                          displayPath.replaceAll('\\', '/'),
                        );
                        final path = target == null
                            ? '请更新目录'
                            : target.parentFolderLabel ??
                                  '${target.sourceName} / ${scoreParentFolder(target.displayPath)}';
                        final compact = DeviceLayoutScope.isCompact(context);
                        final rowHeight = _setListRowHeight(context);
                        final iconState = switch (target?.state) {
                          ScoreContentState.ready ||
                          ScoreContentState.readableOld =>
                            ScoreFileIconState.ready,
                          ScoreContentState.missing ||
                          ScoreContentState.sourceOffline =>
                            ScoreFileIconState.unreadable,
                          _ => ScoreFileIconState.cloud,
                        };
                        final row = Row(
                          children: [
                            SizedBox(
                              width: ScoreLayout.desktopTarget,
                              child: ReorderableDragStartListener(
                                index: index,
                                child: Semantics(
                                  label: '拖动调整第 ${index + 1} 首的顺序',
                                  button: true,
                                  child: SizedBox(
                                    height: rowHeight,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: ReaderIcon(
                                        ReaderGlyph.grip,
                                        color: tokens.ink500,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: ScoreSpace.xxl,
                              child: Text(
                                '${index + 1}',
                                style: ScoreText.caption.copyWith(
                                  color: tokens.ink500,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(
                              width: ScoreLayout.iconColumn,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ScoreFileIcon(
                                  path: displayPath,
                                  state: iconState,
                                  showBadge: compact,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Tooltip(
                                message: '$filename\n$path',
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      filename,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ScoreText.headline.copyWith(
                                        color: tokens.ink900,
                                      ),
                                    ),
                                    Text(
                                      path,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ScoreText.caption.copyWith(
                                        color: tokens.ink500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(
                              width: ScoreLayout.pagesColumn,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  right: ScoreSpace.sm,
                                ),
                                child: _SetListPages(
                                  path: displayPath,
                                  target: locate(item.entryId),
                                  service: pageCounts,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: ScoreLayout.actionColumn,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: PopupMenuButton<String>(
                                  style: _setListIconStyle(context),
                                  constraints: const BoxConstraints.tightFor(
                                    width: ScoreLayout.menuWidth,
                                  ),
                                  tooltip: '曲谱更多操作',
                                  icon: const ReaderIcon(ReaderGlyph.more),
                                  onSelected: (action) {
                                    if (action == 'remove') {
                                      unawaited(
                                        workspace.edit(
                                          (store) =>
                                              store.removeItem(listId, item.id),
                                        ),
                                      );
                                    }
                                    if (action == 'prepare') {
                                      unawaited(
                                        _prepare(context, {item.entryId}),
                                      );
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    if (prepare != null &&
                                        target?.needsPreparation == true)
                                      const PopupMenuItem(
                                        value: 'prepare',
                                        height: ScoreLayout.touchTarget,
                                        child: Text('准备这份曲谱'),
                                      ),
                                    PopupMenuItem(
                                      value: 'remove',
                                      height: ScoreLayout.touchTarget,
                                      child: Text(
                                        '从曲单移除',
                                        style: ScoreText.caption.copyWith(
                                          color: tokens.dangerInk,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                        return SizedBox(
                          key: ValueKey(item.id),
                          height: rowHeight,
                          child: InkWell(
                            onTap: () =>
                                unawaited(_open(context, item, target)),
                            splashFactory: NoSplash.splashFactory,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ScoreLayout.rowInnerPadding,
                              ),
                              child: row,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

class _SetListPages extends StatefulWidget {
  const _SetListPages({required this.path, required this.target, this.service});
  final String path;
  final ScoreTarget? target;
  final PageCountService? service;
  @override
  State<_SetListPages> createState() => _SetListPagesState();
}

class _SetListPagesState extends State<_SetListPages> {
  ValueNotifier<int?>? _pages;
  PageMetadataKey? _key;
  void _bind() {
    final target = widget.target;
    if (target != null && widget.path.toLowerCase().endsWith('.pdf')) {
      _key = PageMetadataKey(target.entryId, target.revisionId);
      _pages = widget.service?.watch(_key!);
    }
  }

  void _unbind(PageCountService? service) {
    if (_key != null) service?.unwatch(_key!);
    _key = null;
    _pages = null;
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant _SetListPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target?.key != widget.target?.key ||
        oldWidget.service != widget.service ||
        oldWidget.path != widget.path) {
      _unbind(oldWidget.service);
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind(widget.service);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = [
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
    ].any(widget.path.toLowerCase().endsWith);
    Widget label(int? pages) => Text(
      pages == null ? '—' : '$pages 页',
      textAlign: TextAlign.right,
      style: ScoreText.caption.copyWith(
        color: ScoreTokens.of(context).ink500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return _pages == null
        ? label(image ? 1 : null)
        : ValueListenableBuilder<int?>(
            valueListenable: _pages!,
            builder: (_, pages, _) => label(pages),
          );
  }
}

class _AddScores extends StatefulWidget {
  const _AddScores({
    required this.workspace,
    required this.listId,
    required this.targets,
  });
  final ReaderWorkspace workspace;
  final String listId;
  final List<ScoreCatalogEntry> targets;
  @override
  State<_AddScores> createState() => _AddScoresState();
}

class _AddScoresState extends State<_AddScores> {
  String _query = '';
  String? _message;
  @override
  Widget build(BuildContext context) {
    final terms = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    final matches = widget.targets
        .where(
          (target) => terms.every(
            (term) => '${target.displayPath} ${target.parentFolderLabel ?? ''}'
                .toLowerCase()
                .contains(term),
          ),
        )
        .toList();
    return SafeArea(
      child: SizedBox(
        height: (MediaQuery.sizeOf(context).height * .8).clamp(
          0.0,
          ScoreLayout.sheetMaxHeight,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            ScoreSpace.xl,
            ScoreSpace.lg,
            ScoreSpace.xl,
            MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(child: Text('添加曲谱', style: ScoreText.title)),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: ReaderIcon(ReaderGlyph.search),
                  hintText: '搜索曲名或路径',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(ScoreSpace.sm),
                  child: Text(_message!),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final target = matches[index];
                    final included =
                        widget.workspace.store.snapshot
                            .setListById(widget.listId)
                            ?.activeItems
                            .any((item) => item.entryId == target.entryId) ==
                        true;
                    return ListTile(
                      minTileHeight: ScoreLayout.setlistRowHeight,
                      leading: SizedBox(
                        width: ScoreLayout.iconColumn,
                        child: Checkbox(value: included, onChanged: null),
                      ),
                      title: Text(
                        p.posix.basename(
                          target.displayPath.replaceAll('\\', '/'),
                        ),
                        style: ScoreText.headline,
                      ),
                      subtitle: Text(
                        '${target.parentFolderLabel ?? scoreParentFolder(target.displayPath)} · ${target.statusLabel}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ScoreText.caption.copyWith(
                          color: ScoreTokens.of(context).ink500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      onTap: included
                          ? null
                          : () async {
                              final item = await widget.workspace.edit(
                                (store) => store.addItem(
                                  widget.listId,
                                  target.entryId,
                                  ifAbsent: true,
                                ),
                              );
                              if (mounted) {
                                setState(
                                  () => _message = item == null
                                      ? '添加失败，请检查应用数据目录后重试。'
                                      : '已添加，可继续选择',
                                );
                              }
                            },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
