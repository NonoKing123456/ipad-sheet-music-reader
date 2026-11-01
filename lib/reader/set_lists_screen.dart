import '../library/score_path_label.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

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
  });
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final List<ScoreTarget> Function() targets;
  final Listenable? sourceChanges;
  final ScoreLoader? loader;
  final ScoreCatalogProvider? catalog;
  final ScorePreparation? prepare;
  final String preparationLabel, preparationNotice;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: workspace,
    builder: (context, _) {
      final lists = workspace.store.snapshot.activeSetLists;
      return Scaffold(
        appBar: AppBar(title: const Text('曲单')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final name = await _nameDialog(context);
            if (name != null) {
              await workspace.edit((store) => store.createSetList(name));
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('创建曲单'),
        ),
        body: Column(
          children: [
            if (workspace.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  workspace.error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (workspace.store.storageWarnings.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('已从备份恢复，请检查最近修改。'),
              ),
            Expanded(
              child: lists.isEmpty
                  ? const Center(child: Text('创建曲单，把演出曲目按顺序放在一起。'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                      itemCount: lists.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final list = lists[index];
                        return ListTile(
                          leading: const Icon(Icons.queue_music),
                          title: Text(list.name),
                          subtitle: Text('${list.activeItems.length} 首曲谱'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
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
                              ),
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
      final list = workspace.store.snapshot.setListById(listId)!;
      final items = list.activeItems;
      final metadata = {
        for (final entry in _catalogEntries()) entry.entryId: entry,
      };
      final unique = items.map((item) => item.entryId).toSet();
      final unready = unique
          .where((id) => metadata[id]?.readable != true)
          .length;
      final old = unique
          .where((id) => metadata[id]?.state == ScoreContentState.readableOld)
          .length;
      final needed = unique
          .where((id) => metadata[id]?.needsPreparation == true)
          .toSet();
      return Scaffold(
        appBar: AppBar(
          title: Text(list.name),
          actions: [
            IconButton(
              tooltip: '重命名曲单',
              icon: const Icon(Icons.drive_file_rename_outline),
              onPressed: () async {
                final name = await _nameDialog(context, initial: list.name);
                if (name != null) {
                  await workspace.edit(
                    (store) => store.renameSetList(listId, name),
                  );
                }
              },
            ),
            const SizedBox(width: 12),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _AddScores(
              workspace: workspace,
              listId: listId,
              targets: _catalogEntries(),
            ),
          ),
          icon: const Icon(Icons.playlist_add),
          label: const Text('添加曲谱'),
        ),
        body: Column(
          children: [
            if (workspace.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  workspace.error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${items.length} 首 · $unready 份未准备${old > 0 ? ' · $old 份旧版可读' : ''}',
                    style: const TextStyle(color: Color(0xff65736b)),
                  ),
                  if (prepare != null && needed.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => unawaited(_prepare(context, needed)),
                      icon: const Icon(Icons.download_outlined),
                      label: Text(preparationLabel),
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
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('顺序阅读'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('从谱库添加曲谱；同一份曲谱可以重复加入。'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                      buildDefaultDragHandles: false,
                      itemCount: items.length,
                      onReorderItem: (oldIndex, newIndex) {
                        unawaited(
                          workspace.edit(
                            (store) => store.reorderItem(
                              listId,
                              items[oldIndex].id,
                              newIndex,
                            ),
                          ),
                        );
                      },
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final target = metadata[item.entryId];
                        return Card(
                          key: ValueKey(item.id),
                          child: ListTile(
                            leading: CircleAvatar(child: Text('${index + 1}')),
                            title: Text(
                              target == null
                                  ? '目录尚未更新的曲谱'
                                  : p.posix.basename(
                                      target.displayPath.replaceAll('\\', '/'),
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              target == null
                                  ? '请更新目录。'
                                  : '${target.parentFolderLabel ?? scoreParentFolder(target.displayPath)} · ${target.statusLabel}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () =>
                                unawaited(_open(context, item, target)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (target != null)
                                  Tooltip(
                                    message: target.statusLabel,
                                    child: Icon(
                                      target.state == ScoreContentState.ready
                                          ? Icons.check_circle_outline
                                          : target.state ==
                                                ScoreContentState.readableOld
                                          ? Icons.update
                                          : target.state ==
                                                    ScoreContentState.missing ||
                                                target.state ==
                                                    ScoreContentState
                                                        .sourceOffline
                                          ? Icons.error_outline
                                          : Icons.cloud_download_outlined,
                                      size: 18,
                                    ),
                                  ),
                                if (prepare != null &&
                                    target?.needsPreparation == true)
                                  IconButton(
                                    tooltip: '准备这份曲谱',
                                    icon: const Icon(Icons.download_outlined),
                                    onPressed: () => unawaited(
                                      _prepare(context, {item.entryId}),
                                    ),
                                  ),
                                IconButton(
                                  tooltip: '从曲单移除',
                                  onPressed: () => unawaited(
                                    workspace.edit(
                                      (store) =>
                                          store.removeItem(listId, item.id),
                                    ),
                                  ),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Icon(Icons.drag_handle),
                                  ),
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
        height: MediaQuery.sizeOf(context).height * .8,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '从谱库添加曲谱',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索曲名或路径',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(_message!),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final target = matches[index];
                    return ListTile(
                      leading: const Icon(Icons.add_circle_outline),
                      title: Text(
                        p.posix.basename(
                          target.displayPath.replaceAll('\\', '/'),
                        ),
                      ),
                      subtitle: Text(
                        '${target.parentFolderLabel ?? scoreParentFolder(target.displayPath)} · ${target.statusLabel}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        final item = await widget.workspace.edit(
                          (store) =>
                              store.addItem(widget.listId, target.entryId),
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
