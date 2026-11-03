import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import '../theme/reader_icons.dart';
import 'reader_workspace.dart';

/// The stable entry ID also allows adding scores that have not been downloaded.
Future<void> showAddToSetList(
  BuildContext context, {
  required ReaderWorkspace workspace,
  required String entryId,
  required String displayPath,
}) async {
  final names = await showDialog<List<String>>(
    context: context,
    builder: (_) => _AddToSetListDialog(
      workspace: workspace,
      entryId: entryId,
      displayPath: displayPath,
    ),
  );
  if (names == null || names.isEmpty || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('已加入${names.map((name) => '「$name」').join('、')}')),
  );
}

class _AddToSetListDialog extends StatefulWidget {
  const _AddToSetListDialog({
    required this.workspace,
    required this.entryId,
    required this.displayPath,
  });
  final ReaderWorkspace workspace;
  final String entryId, displayPath;

  @override
  State<_AddToSetListDialog> createState() => _AddToSetListDialogState();
}

class _AddToSetListDialogState extends State<_AddToSetListDialog> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _selected = <String>{};
  bool _creating = false;
  bool _busy = false;
  String? _error;

  bool _contains(ScoreSetList list) =>
      list.activeItems.any((item) => item.entryId == widget.entryId);

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || _name.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final list = await widget.workspace.edit(
      (store) => store.createSetList(_name.text.trim()),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (list == null) {
        _error = '新建曲单失败，请重试。';
      } else {
        _selected.add(list.id);
        _creating = false;
        _name.clear();
        _search.clear();
      }
    });
  }

  Future<void> _submit() async {
    if (_busy || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final names = <String>[];
    // Each append uses the current store snapshot and its serialized write queue.
    // A partial failure keeps the dialog open; a retry skips saved entries.
    for (final id in _selected.toList()) {
      final list = widget.workspace.store.snapshot.setListById(id);
      if (list == null || list.isDeleted) continue;
      final item = await widget.workspace.edit((store) async {
        final current = store.snapshot.setListById(id);
        if (current == null || current.isDeleted) return null;
        // The queue checks again when this append actually executes.
        return store.addItem(id, widget.entryId, ifAbsent: true);
      });
      if (!mounted) return;
      if (item == null) {
        setState(() {
          _busy = false;
          _error = '加入失败，选择已保留，请重试。';
        });
        return;
      }
      names.add(list.name);
    }
    if (mounted) Navigator.pop(context, names);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.workspace,
    builder: (context, _) {
      final all = widget.workspace.store.snapshot.activeSetLists;
      final query = _search.text.trim().toLowerCase();
      final lists = all
          .where((list) => list.name.toLowerCase().contains(query))
          .toList();
      final media = MediaQuery.of(context);
      final availableHeight =
          media.size.height -
          media.viewInsets.bottom -
          media.padding.vertical -
          48;
      return PopScope(
        canPop: !_busy,
        child: AlertDialog(
          scrollable: true,
          title: Row(
            children: [
              const Expanded(child: Text('加入曲单')),
              IconButton(
                tooltip: '关闭',
                onPressed: _busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  p.posix.basenameWithoutExtension(
                    widget.displayPath.replaceAll('\\', '/'),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _search,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    hintText: '搜索曲单',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: (availableHeight * .36).clamp(72.0, 260.0),
                  child: lists.isEmpty
                      ? Center(
                          child: Text(all.isEmpty ? '还没有曲单，先新建一个。' : '没有找到曲单'),
                        )
                      : ListView.builder(
                          itemCount: lists.length,
                          itemBuilder: (context, index) {
                            final list = lists[index];
                            final added = _contains(list);
                            return CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                list.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              secondary: added ? const Text('已加入') : null,
                              value: added || _selected.contains(list.id),
                              onChanged: added || _busy
                                  ? null
                                  : (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(list.id);
                                      } else {
                                        _selected.remove(list.id);
                                      }
                                    }),
                            );
                          },
                        ),
                ),
                if (_creating)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _name,
                          autofocus: true,
                          enabled: !_busy,
                          decoration: const InputDecoration(labelText: '曲单名称'),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _create(),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy || _name.text.trim().isEmpty
                            ? null
                            : _create,
                        child: const Text('创建'),
                      ),
                    ],
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => setState(() => _creating = !_creating),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建曲单'),
            ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: _busy || _selected.isEmpty ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const ReaderIcon(ReaderGlyph.playlistAdd),
              label: const Text('加入所选曲单'),
            ),
          ],
        ),
      );
    },
  );
}
