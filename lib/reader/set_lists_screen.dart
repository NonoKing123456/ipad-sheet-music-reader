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
  });
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final List<ScoreTarget> Function() targets;
  final Listenable? sourceChanges;
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
                child: Text('曲单和批注从备份恢复，最近一次修改可能未恢复。请检查内容。'),
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
  });
  final ReaderWorkspace workspace;
  final String listId;
  final ScoreLocator locate;
  final List<ScoreTarget> Function() targets;
  final Listenable? sourceChanges;

  Future<void> _open(BuildContext context, SetListItem item) async {
    final target = locate(item.entryId);
    if (target == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这份曲谱暂时缺失，请返回谱库检查。')));
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LibraryReaderScreen(
          workspace: workspace,
          locate: locate,
          initialTarget: target,
          setListId: listId,
          itemId: item.id,
          sourceChanges: sourceChanges,
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
              targets: targets(),
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${items.length} 首 · 拖动右侧手柄排序',
                      style: const TextStyle(color: Color(0xff65736b)),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: items.isEmpty
                        ? null
                        : () => unawaited(_open(context, items.first)),
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
                        final target = locate(item.entryId);
                        return Card(
                          key: ValueKey(item.id),
                          child: ListTile(
                            leading: CircleAvatar(child: Text('${index + 1}')),
                            title: Text(
                              target == null
                                  ? '暂时缺失的曲谱'
                                  : p.posix.basename(
                                      target.displayPath.replaceAll('\\', '/'),
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              target == null
                                  ? '保留原曲谱关联，恢复文件后可以继续使用。'
                                  : target.parentFolderLabel ??
                                        scoreParentFolder(target.displayPath),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => unawaited(_open(context, item)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
  final List<ScoreTarget> targets;
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
            (term) => target.displayPath.toLowerCase().contains(term),
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
                        target.parentFolderLabel ??
                            scoreParentFolder(target.displayPath),
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
