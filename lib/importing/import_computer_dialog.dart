import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;

import '../library/directory_navigation.dart';
import '../library/library_widgets.dart';
import '../library/score_file_icon.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'external_import_store.dart';

class ImportComputerDestination {
  const ImportComputerDestination({
    required this.id,
    required this.name,
    required this.folders,
  });
  final String id, name;
  final List<String> folders;
}

class ImportComputerSelection {
  const ImportComputerSelection(this.source, this.folder, this.basename);
  final ImportComputerDestination source;
  final String folder, basename;
}

/// Uses the normal collection's logical directory, never computer disk paths.
class ImportComputerFolderDialog extends StatefulWidget {
  const ImportComputerFolderDialog({
    super.key,
    required this.sources,
    required this.fileName,
    this.previous,
  });
  final List<ImportComputerDestination> sources;
  final String fileName;
  final ImportRemoteTransaction? previous;
  @override
  State<ImportComputerFolderDialog> createState() =>
      _ImportComputerFolderDialogState();
}

class _ImportComputerFolderDialogState
    extends State<ImportComputerFolderDialog> {
  late final _name = TextEditingController(
    text: p.basenameWithoutExtension(
      widget.previous?.fileName ?? widget.fileName,
    ),
  );
  ImportComputerDestination? _source;
  String _folder = '';
  String? _error;
  (String, List<String>)? _hierarchyKey;
  FolderHierarchy? _hierarchy;
  String get _extension => p.extension(widget.fileName).toLowerCase();
  @override
  void initState() {
    super.initState();
    final previous = widget.previous;
    if (previous != null) {
      _source = widget.sources
          .where((source) => source.id == previous.sourceId)
          .firstOrNull;
      if (_source?.folders.contains(previous.relativeFolder) == true) {
        _folder = previous.relativeFolder;
      }
      if (previous.conflict) _error = '已有同名曲谱，请修改文件名。';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final error = importNameError(_name.text, _extension);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      ImportComputerSelection(_source!, _folder, _name.text),
    );
  }

  @override
  void didUpdateWidget(ImportComputerFolderDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_source != null) {
      _source = widget.sources
          .where((source) => source.id == _source!.id)
          .firstOrNull;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final source = _source;
    if (source != null && _hierarchyKey != (source.id, source.folders)) {
      _hierarchyKey = (source.id, source.folders);
      _hierarchy = FolderHierarchy(source.folders);
    }
    final folders = source == null
        ? const <String>[]
        : _hierarchy!.childrenOf(_folder);
    return AlertDialog(
      title: const Text('保存到电脑谱库'),
      content: SizedBox(
        width: ScoreLayout.sheetWidth,
        height:
            (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).vertical -
                    ScoreLayout.headerHeight * 2 -
                    ScoreLayout.touchTarget -
                    ScoreSpace.xl * 2)
                .clamp(ScoreLayout.touchTarget, ScoreLayout.sheetWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (source != null)
              Row(
                children: [
                  if (_folder.isEmpty)
                    LibraryIconButton(
                      glyph: ReaderGlyph.back,
                      label: '选择其他谱库',
                      onPressed: () => setState(() => _source = null),
                    ),
                  Expanded(
                    child: DefaultTextStyle(
                      // Match the nested Material's text metrics when the
                      // breadcrumb measures its logical directory labels.
                      style: Theme.of(context).textTheme.bodyMedium!,
                      child: DirectoryBreadcrumbs(
                        rootLabel: source.name,
                        currentPath: _folder,
                        onNavigate: (path) => setState(() => _folder = path),
                      ),
                    ),
                  ),
                ],
              ),
            const LibraryColumnHeader(),
            Expanded(
              child: widget.sources.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(ScoreSpace.lg),
                      child: Text(
                        '配对电脑并更新目录后，可选择保存位置。',
                        style: ScoreText.body.copyWith(color: t.ink500),
                      ),
                    )
                  : ListView.builder(
                      itemCount: source == null
                          ? widget.sources.length
                          : folders.length,
                      itemBuilder: (context, index) {
                        if (source == null) {
                          final item = widget.sources[index];
                          return LibraryFileRow(
                            leading: const ScoreFileIcon.folder(
                              showBadge: false,
                            ),
                            name: item.name,
                            onTap: () => setState(() {
                              _source = item;
                              _folder = '';
                            }),
                          );
                        }
                        final path = folders[index];
                        return LibraryFileRow(
                          leading: const ScoreFileIcon.folder(showBadge: false),
                          name: p.posix.basename(path),
                          onTap: () => setState(() => _folder = path),
                        );
                      },
                    ),
            ),
            const SizedBox(height: ScoreSpace.md),
            TextField(
              key: const ValueKey('import-computer-basename'),
              controller: _name,
              style: ScoreText.body.copyWith(color: t.ink900),
              decoration: InputDecoration(
                labelText: '文件名',
                suffixText: _extension,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) {
                if (source != null) _save();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: ScoreSpace.sm),
              Text(
                _error!,
                style: ScoreText.caption.copyWith(color: t.dangerInk),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: source == null ? null : _save,
          child: const Text('保存到这里'),
        ),
      ],
    );
  }
}
