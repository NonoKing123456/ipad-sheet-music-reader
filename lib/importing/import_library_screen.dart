import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../library/library_widgets.dart';
import '../library/directory_navigation.dart';
import '../library/score_file_icon.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'external_import_store.dart';

class ImportLibraryScreen extends StatefulWidget {
  const ImportLibraryScreen({
    super.key,
    required this.store,
    required this.openScore,
    required this.openFiles,
  });
  final ExternalImportStore store;
  final Future<void> Function(String id) openScore;
  final VoidCallback openFiles;
  @override
  State<ImportLibraryScreen> createState() => _ImportLibraryScreenState();
}

class _ImportLibraryScreenState extends State<ImportLibraryScreen> {
  late String _folder = widget.store.localLibrary.path;
  bool _drafts = false;
  List<Directory> _folders = [];
  @override
  void initState() {
    super.initState();
    _loadFolder(_folder);
  }

  Future<void> _loadFolder(String path) async {
    try {
      final root = await widget.store.localLibrary.resolveSymbolicLinks();
      final actual = await Directory(path).resolveSymbolicLinks();
      if (!p.equals(root, actual) && !p.isWithin(root, actual)) return;
      final folders = await Directory(actual)
          .list(followLinks: false)
          .where((entry) => entry is Directory)
          .cast<Directory>()
          .toList();
      folders.sort((a, b) => a.path.compareTo(b.path));
      if (mounted) {
        setState(() {
          _folder = actual;
          _folders = folders;
        });
      }
    } catch (_) {
      /* The saved records remain available even if a folder is offline. */
    }
  }

  Future<void> _delete(ImportedScore score) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除临时曲谱？'),
        content: Text('删除“${score.name}”的本机临时副本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await widget.store.remove(score.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('删除失败，临时稿已保留。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final root = widget.store.localLibrary.path;
    final atRoot = p.equals(_folder, root);
    return Scaffold(
      backgroundColor: t.paper1,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: ScoreLayout.headerHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
                child: Row(
                  children: [
                    LibraryIconButton(
                      glyph: ReaderGlyph.back,
                      label: '返回曲库',
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        '本机导入',
                        style: ScoreText.title.copyWith(color: t.ink900),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.openFiles,
                      child: const Text('导入文件'),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: ScoreLayout.rowDividerThickness, color: t.hair),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() => _drafts = false);
                      _loadFolder(_folder);
                    },
                    child: Text(
                      '本机文件夹',
                      style: ScoreText.caption.copyWith(
                        color: _drafts ? t.ink500 : t.pine,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _drafts = true),
                    child: Text(
                      '暂存',
                      style: ScoreText.caption.copyWith(
                        color: _drafts ? t.pine : t.ink500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!_drafts)
              DirectoryBreadcrumbs(
                rootLabel: '本机导入',
                currentPath: atRoot
                    ? ''
                    : p
                          .relative(_folder, from: root)
                          .split(p.separator)
                          .join('/'),
                onNavigate: (path) => _loadFolder(p.join(root, path)),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: ScoreLayout.listMargin),
              child: LibraryColumnHeader(),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.store,
                builder: (context, _) {
                  final records = widget.store.records.where((score) {
                    if (_drafts) return !score.saved;
                    if (!score.saved) return false;
                    final directory = p.dirname(score.savedPath!);
                    return p.equals(directory, _folder) ||
                        (atRoot && !p.isWithin(root, score.savedPath!));
                  }).toList();
                  final folders = _drafts ? <Directory>[] : _folders;
                  if (records.isEmpty && folders.isEmpty) {
                    return Center(
                      child: Text(
                        _drafts ? '暂无暂存曲谱' : '文件夹中暂无曲谱',
                        style: ScoreText.body.copyWith(color: t.ink500),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: folders.length + records.length,
                    padding: const EdgeInsets.symmetric(
                      horizontal: ScoreLayout.listMargin,
                    ),
                    itemBuilder: (context, index) {
                      if (index < folders.length) {
                        final folder = folders[index];
                        return LibraryFileRow(
                          leading: const ScoreFileIcon.folder(showBadge: false),
                          name: p.basename(folder.path),
                          onTap: () => _loadFolder(folder.path),
                        );
                      }
                      final score = records[index - folders.length];
                      return LibraryFileRow(
                        leading: ScoreFileIcon(
                          path: score.name,
                          showBadge: false,
                        ),
                        name: score.name,
                        subtitle: score.saved
                            ? (atRoot && !p.isWithin(root, score.savedPath!)
                                  ? p.dirname(score.savedPath!)
                                  : null)
                            : '暂存 · 尚未保存到曲库',
                        metadata: LibraryFileMetadata(
                          entryId: 'import-${score.id}',
                          revisionId: score.hash,
                          path: score.name,
                        ),
                        onTap: () async {
                          await widget.openScore(score.id);
                          if (mounted) _loadFolder(_folder);
                        },
                        action: score.saved
                            ? null
                            : LibraryIconButton(
                                glyph: ReaderGlyph.trash,
                                label: '删除暂存 ${score.name}',
                                onPressed: () => _delete(score),
                              ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
