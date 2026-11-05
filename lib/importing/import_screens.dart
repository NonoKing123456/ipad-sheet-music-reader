import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import '../library/library_widgets.dart';
import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/reader_workspace.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'external_import_store.dart';
export 'import_library_screen.dart';
import 'import_annotation_mirror.dart';

class ImportDestination {
  const ImportDestination(this.label, this.directory);
  final String label;
  final Directory directory;
}

typedef ImportCatalogIdentity = Future<(String, String)?> Function(String path);

class ImportReaderScreen extends StatefulWidget {
  const ImportReaderScreen({
    super.key,
    required this.store,
    required this.scoreId,
    required this.workspace,
    this.destinations = const [],
    this.allowOtherDirectories = false,
    this.catalogIdentity,
    this.initialPageNumber,
    this.loader,
  });
  final ExternalImportStore store;
  final String scoreId;
  final ReaderWorkspace workspace;
  final List<ImportDestination> destinations;
  final bool allowOtherDirectories;
  final ImportCatalogIdentity? catalogIdentity;
  final int? initialPageNumber;
  final ScoreLoader? loader;
  @override
  State<ImportReaderScreen> createState() => _ImportReaderScreenState();
}

class _ImportReaderScreenState extends State<ImportReaderScreen> {
  late final ScoreTarget _target = widget.store.target(
    widget.store.byId(widget.scoreId)!,
  );
  bool _saving = false, _loaded = false, _confirming = false;
  ImportedScore? get _score => widget.store.byId(widget.scoreId);
  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _mirror(ImportedScore score) async {
    if (score.catalogEntryId == null) return;
    await mirrorImportAnnotations(
      widget.workspace,
      _target.key,
      DocumentKey(
        entryId: score.catalogEntryId!,
        revisionId: score.catalogRevisionId!,
      ),
    );
  }

  Future<void> _save() async {
    if (_saving || !_loaded) return;
    final destination = await showDialog<Directory>(
      context: context,
      builder: (_) => ImportFolderDialog(
        roots: [
          ImportDestination('本机导入', widget.store.localLibrary),
          ...widget.destinations,
        ],
        allowOtherDirectories: widget.allowOtherDirectories,
      ),
    );
    if (destination == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.workspace.waitForAnnotationWrites();
      if (widget.workspace.unsavedCount != 0) throw StateError('批注尚未保存');
      await widget.store.save(
        widget.scoreId,
        destination,
        catalogIdentity: widget.catalogIdentity,
        beforeCleanup: _mirror,
      );
      if (mounted) _message('已保存到 ${p.basename(destination.path)}');
    } catch (failure) {
      debugPrint('IMPORT save_failed: $failure');
      if (mounted) _message('保存失败，曲谱和批注已留在本机暂存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _beforeLeave() async {
    if (_saving || _confirming) return false;
    final score = _score;
    if (score == null) return true;
    if (score.saved) {
      try {
        await _mirror(score);
        await widget.store.completeMirror(score.id);
        await widget.store.cleanupSavedPayload(score.id);
        return true;
      } catch (_) {
        if (mounted) _message('批注整理失败，原稿已保留，请重试。');
        return false;
      }
    }
    _confirming = true;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尚未保存到曲库'),
        content: const Text('可保留在本机暂存，稍后从“本机导入”继续阅读和整理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'read'),
            child: const Text('保持阅读'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text(
              '删除临时曲谱',
              style: TextStyle(color: ScoreTokens.of(context).dangerInk),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'keep'),
            child: const Text('保留暂存'),
          ),
        ],
      ),
    );
    _confirming = false;
    if (action != 'keep' && action != 'delete') return false;
    try {
      if (action == 'keep') {
        await widget.store.retain(score.id);
      } else {
        await widget.store.remove(score.id);
      }
      return true;
    } catch (_) {
      if (mounted) _message('操作失败，临时稿已保留，请重试。');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => LibraryReaderScreen(
    workspace: widget.workspace,
    initialTarget: _target,
    locate: (id) => id == _target.entryId ? _target : null,
    loader: widget.loader,
    initialPageNumber: widget.initialPageNumber,
    initiallyShowToolbar: true,
    onLoaded: (_) {
      if (mounted && !_loaded) setState(() => _loaded = true);
    },
    headerAction: TextButton(
      key: const ValueKey('external-import-save'),
      onPressed: _saving || !_loaded || _score?.saved == true ? null : _save,
      child: Text(
        _saving
            ? '保存中…'
            : _score?.saved == true
            ? '已保存'
            : '保存到…',
      ),
    ),
    beforeLeave: _beforeLeave,
    restoreScreen: (page) => widget.store.byId(widget.scoreId) == null
        ? null
        : ImportReaderScreen(
            store: widget.store,
            scoreId: widget.scoreId,
            workspace: widget.workspace,
            destinations: widget.destinations,
            allowOtherDirectories: widget.allowOtherDirectories,
            catalogIdentity: widget.catalogIdentity,
            initialPageNumber: page,
            loader: widget.loader,
          ),
  );
}

class ImportFolderDialog extends StatefulWidget {
  const ImportFolderDialog({
    super.key,
    required this.roots,
    this.allowOtherDirectories = false,
  });
  final List<ImportDestination> roots;
  final bool allowOtherDirectories;
  @override
  State<ImportFolderDialog> createState() => _ImportFolderDialogState();
}

class _ImportFolderDialogState extends State<ImportFolderDialog> {
  ImportDestination? _root;
  Directory? _folder;
  List<Directory> _children = [];
  String? _error;
  Future<void> _navigate(ImportDestination root, Directory folder) async {
    try {
      final actualRoot = await root.directory.resolveSymbolicLinks();
      final actual = await folder.resolveSymbolicLinks();
      if (!p.equals(actualRoot, actual) && !p.isWithin(actualRoot, actual)) {
        throw const FileSystemException('不在本机谱库范围内');
      }
      final children = await Directory(actual)
          .list(followLinks: false)
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();
      children.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      if (mounted) {
        setState(() {
          _root = root;
          _folder = Directory(actual);
          _children = children;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '文件夹不可用，请选择可写的本机目录。');
    }
  }

  Future<void> _newFolder() async {
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('新建'),
          ),
        ],
      ),
    );
    // The route transition still reads the controller until its overlay leaves.
    if (name == null || name.isEmpty || !mounted) return;
    if (name == '.' ||
        name == '..' ||
        RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name)) {
      setState(() => _error = '请使用有效的文件夹名称。');
      return;
    }
    try {
      final folder = Directory(p.join(_folder!.path, name));
      if (await FileSystemEntity.type(folder.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        setState(() => _error = '已有同名项目，请换一个名称。');
        return;
      }
      await folder.create();
      await _navigate(_root!, folder);
    } catch (_) {
      if (mounted) setState(() => _error = '新建失败，请检查空间与权限。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final folder = _folder, root = _root;
    return AlertDialog(
      title: const Text('保存到本机曲库'),
      content: SizedBox(
        width: ScoreLayout.sheetWidth,
        height:
            (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).vertical -
                    ScoreLayout.headerHeight -
                    ScoreLayout.headerHeight -
                    ScoreLayout.touchTarget -
                    ScoreSpace.xl -
                    ScoreSpace.xl)
                .clamp(ScoreLayout.touchTarget, ScoreLayout.sheetWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (folder != null && root != null)
              Row(
                children: [
                  LibraryIconButton(
                    glyph: ReaderGlyph.back,
                    label: '上一级文件夹',
                    onPressed: () {
                      if (p.equals(folder.path, root.directory.path)) {
                        setState(() {
                          _root = null;
                          _folder = null;
                        });
                      } else {
                        _navigate(root, folder.parent);
                      }
                    },
                  ),
                  Expanded(
                    child: Text(
                      p.equals(folder.path, root.directory.path)
                          ? root.label
                          : '${root.label} / ${p.relative(folder.path, from: root.directory.path)}',
                      maxLines: 2,
                      style: ScoreText.caption.copyWith(color: t.ink900),
                    ),
                  ),
                  TextButton(onPressed: _newFolder, child: const Text('新建文件夹')),
                ],
              ),
            Expanded(
              child: ListView(
                children: folder == null
                    ? [
                        for (final destination in widget.roots)
                          ListTile(
                            leading: const ReaderIcon(ReaderGlyph.folder),
                            title: Text(destination.label),
                            onTap: () =>
                                _navigate(destination, destination.directory),
                          ),
                        if (widget.allowOtherDirectories)
                          ListTile(
                            title: const Text('选择其他本机文件夹…'),
                            onTap: () async {
                              try {
                                final path = await getDirectoryPath(
                                  confirmButtonText: '保存到这里',
                                );
                                if (path != null && context.mounted) {
                                  Navigator.pop(context, Directory(path));
                                }
                              } catch (_) {
                                if (mounted) {
                                  setState(() => _error = '无法选择文件夹，请重试。');
                                }
                              }
                            },
                          ),
                      ]
                    : [
                        for (final child in _children)
                          ListTile(
                            leading: const ReaderIcon(ReaderGlyph.folder),
                            title: Text(p.basename(child.path)),
                            onTap: () => _navigate(root!, child),
                          ),
                      ],
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: ScoreText.caption.copyWith(color: t.dangerInk),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: folder == null
              ? null
              : () => Navigator.pop(context, folder),
          child: const Text('保存到这里'),
        ),
      ],
    );
  }
}
