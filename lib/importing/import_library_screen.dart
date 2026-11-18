import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../library/library_widgets.dart';
import '../library/directory_navigation.dart';
import '../library/score_file_icon.dart';
import '../sync/sync_controller.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'external_import_store.dart';
import 'import_computer_dialog.dart';

class ImportLibraryScreen extends StatefulWidget {
  const ImportLibraryScreen({
    super.key,
    required this.store,
    required this.openScore,
    required this.openFiles,
    this.computer,
    this.initialDrafts = false,
  });
  final ExternalImportStore store;
  final SyncController? computer;
  final Future<void> Function(String id) openScore;
  final VoidCallback openFiles;
  final bool initialDrafts;
  @override
  State<ImportLibraryScreen> createState() => _ImportLibraryScreenState();
}

class _ImportLibraryScreenState extends State<ImportLibraryScreen> {
  late String _root = widget.store.localLibrary.path;
  late String _folder = _root;
  late bool _drafts = widget.initialDrafts;
  List<Directory> _folders = [];
  int _folderRequest = 0;
  @override
  void initState() {
    super.initState();
    _loadFolder(_folder);
  }

  Future<void> _loadFolder(String path) async {
    final request = ++_folderRequest;
    var candidate = path;
    var unavailable = false;
    while (true) {
      try {
        final root = await widget.store.localLibrary.resolveSymbolicLinks();
        final actual = await Directory(candidate).resolveSymbolicLinks();
        if (!p.equals(root, actual) && !p.isWithin(root, actual)) {
          throw const FileSystemException('不在本机导入目录范围内');
        }
        final folders = await Directory(actual)
            .list(followLinks: false)
            .where((entry) => entry is Directory)
            .cast<Directory>()
            .toList();
        folders.sort((a, b) => a.path.compareTo(b.path));
        if (!mounted || request != _folderRequest) return;
        setState(() {
          _root = root;
          _folder = actual;
          _folders = folders;
        });
        break;
      } on FileSystemException {
        if (!mounted || request != _folderRequest) return;
        unavailable = true;
        if (p.isWithin(_root, candidate)) {
          candidate = p.dirname(candidate);
          continue;
        }
        setState(() {
          _folder = _root;
          _folders = [];
        });
        break;
      }
    }
    if (unavailable && !_drafts) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('文件夹已移动或不可访问。')));
    }
  }

  Future<void> _delete(ImportedScore score) async {
    final pending =
        score.remoteTransaction != null && !score.remoteTransaction!.conflict;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除临时曲谱？'),
        content: Text(
          pending
              ? '电脑可能已收到“${score.name}”。只删除本机暂存，不删除电脑文件。'
              : '删除“${score.name}”的本机临时副本。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(pending ? '删除本机暂存' : '删除'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await widget.store.remove(score.id, allowPendingRemote: pending);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('删除失败，临时稿已保留。')));
      }
    }
  }

  Future<void> _renameForComputer(ImportedScore score) async {
    final computer = widget.computer!;
    try {
      final confirmed = await computer.confirmImportDirectory();
      if (!mounted) return;
      if (!confirmed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请连接电脑确认目标谱库后重试，曲谱仍在本机暂存。')),
        );
        return;
      }
      final selection = await showDialog<ImportComputerSelection>(
        context: context,
        builder: (_) => ImportComputerFolderDialog(
          sources: ImportComputerDestination.forComputer(computer),
          fileName: score.name,
          previous: score.remoteTransaction,
        ),
      );
      if (selection == null || !mounted) return;
      await computer.retryImportWithName(
        id: score.id,
        sourceId: selection.source.id,
        sourceName: selection.source.name,
        folder: selection.folder,
        basename: selection.basename,
        computerKey: selection.source.computerKey,
        collectionId: selection.source.collectionId,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('改名重试未完成，请确认目标谱库后重试。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final root = _root;
    final atRoot = p.equals(_folder, root);
    final screen = Scaffold(
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
                  _ImportTab(
                    label: '本机文件夹',
                    selected: !_drafts,
                    onPressed: () {
                      setState(() => _drafts = false);
                      _loadFolder(_folder);
                    },
                  ),
                  Flexible(
                    child: AnimatedBuilder(
                      animation: widget.store,
                      builder: (context, _) {
                        final pending = widget.store.records
                            .where((score) => score.pendingComputer)
                            .length;
                        final conflicts = widget.store.importNameConflicts;
                        return _ImportTab(
                          label: '暂存',
                          selected: _drafts,
                          onPressed: () => setState(() => _drafts = true),
                          status: [
                            if (pending > 0) '$pending 待传',
                            if (conflicts > 0) '$conflicts 需改名',
                          ].join(' · '),
                        );
                      },
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
                    if (score.remoteTransaction != null) return false;
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
                            : score.needsComputerRename
                            ? '电脑已有同名曲谱 · 需改名'
                            : score.pendingComputer
                            ? '本机可读 · 待传电脑 · ${score.remoteTransaction!.sourceName}'
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
                            : score.needsComputerRename &&
                                  widget.computer != null
                            ? PopupMenuButton<String>(
                                tooltip: '${score.name} 待传选项',
                                icon: const ReaderIcon(ReaderGlyph.more),
                                onSelected: (action) => action == 'rename'
                                    ? _renameForComputer(score)
                                    : _delete(score),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('改名重试'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除本机暂存'),
                                  ),
                                ],
                              )
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
    return DirectoryMetadataScope(enabled: !_drafts, child: screen);
  }
}

class _ImportTab extends StatelessWidget {
  const _ImportTab({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.status = '',
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final String status;

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: ScoreSpace.sm),
                  child: Text(
                    label,
                    style: ScoreText.caption.copyWith(
                      color: selected ? t.pine : t.ink500,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      key: ValueKey('import-tab-indicator-$label'),
                      height: ScoreLayout.importTabUnderline,
                      decoration: BoxDecoration(
                        color: t.pine,
                        borderRadius: BorderRadius.circular(
                          ScoreLayout.importTabUnderline / 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (status.isNotEmpty)
              Flexible(
                child: Text(
                  ' · $status',
                  style: ScoreText.caption.copyWith(color: t.ink500),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
