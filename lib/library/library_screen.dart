import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:library_core/library_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reader_state/reader_state.dart';

import '../reader/reader_screen.dart';
import '../reader/library_reader_screen.dart';
import '../reader/reader_session.dart';
import '../reader/reader_workspace.dart';
import '../reader/set_lists_screen.dart';
import 'library_controller.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_screen.dart';
import '../sync/offline_library_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.controller,
    this.dataDirectory,
    this.readerWorkspace,
  });
  final LibraryController? controller;
  final Directory? dataDirectory;
  final ReaderWorkspace? readerWorkspace;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  LibraryController? _library;
  final TextEditingController _search = TextEditingController();
  final Set<String> _collapsedFolders = {};
  String? _initializationError;
  ReaderWorkspace? _workspace;
  Future<ReaderWorkspace>? _workspaceFuture;
  bool _openingReader = false;
  SyncController? _sync;
  Future<SyncController>? _syncFuture;
  bool get _canProvideLibrary =>
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final controller =
          widget.controller ??
          LibraryController(
            dataDirectory:
                widget.dataDirectory ??
                Directory(
                  p.join(
                    (await getApplicationSupportDirectory()).path,
                    'library',
                  ),
                ),
          );
      if (!mounted) {
        if (widget.controller == null) controller.dispose();
        return;
      }
      _library = controller;
      controller.addListener(_changed);
      setState(() {});
      if (!controller.initialized) await controller.initialize();
    } catch (failure) {
      debugPrint('LIBRARY data_directory_failed: $failure');
      if (mounted) {
        setState(
          () => _initializationError = '无法准备应用数据目录。请检查磁盘空间和写入权限，重新启动应用。',
        );
      }
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _library?.scheduleRescan();
    if (state == AppLifecycleState.paused) _sync?.cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _library?.removeListener(_changed);
    if (widget.controller == null) _library?.dispose();
    _workspace?.removeListener(_changed);
    if (widget.readerWorkspace == null) _workspace?.dispose();
    _sync?.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _selectRoot() async {
    try {
      final root = await getDirectoryPath(confirmButtonText: '使用这个谱库');
      if (root != null && mounted) {
        _search.clear();
        _collapsedFolders.clear();
        await _sync?.stopServer();
        await _library?.selectRoot(root);
      }
    } catch (failure) {
      debugPrint('LIBRARY picker_failed: $failure');
      if (mounted) _message('无法选择谱库，请关闭其他文件选择窗口后重试。');
    }
  }

  Future<void> _openSingle() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '曲谱',
          extensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
          uniformTypeIdentifiers: ['com.adobe.pdf', 'public.image'],
        ),
      ],
    );
    if (file != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(initialPath: file.path),
        ),
      );
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _folder(String folder) {
    _search.clear();
    _library!.setQuery('');
    _library!.setFolder(folder);
  }

  Future<void> _openEntry(LibraryEntry entry) async {
    if (_openingReader) return;
    _openingReader = true;
    try {
      final library = _library!;
      final workspace = await _prepareReader();
      final target = _locate(entry.id);
      if (!mounted) return;
      if (target == null) {
        _message('曲谱暂时无法读取，请先下载到本机或刷新谱库后重试。');
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LibraryReaderScreen(
            workspace: workspace,
            locate: _locate,
            initialTarget: target,
            sourceChanges: library,
          ),
        ),
      );
      if (mounted) library.scheduleRescan();
    } catch (failure, stack) {
      debugPrint('READER workspace_failed: $failure\n$stack');
      if (mounted) _message('批注和曲单数据暂时无法打开。请检查应用数据目录；已有记录未被清空。');
    } finally {
      _openingReader = false;
    }
  }

  ScoreTarget? _locate(String id) {
    final library = _library;
    if (library?.snapshot == null) return null;
    for (final entry in library!.snapshot!.availableEntries) {
      if (entry.id == id &&
          entry.availability == ContentAvailability.ready &&
          entry.currentRevision.contentHash != null) {
        return ScoreTarget(
          entryId: entry.id,
          revisionId: entry.currentRevisionId,
          filePath: library.absolutePathFor(entry),
          displayPath: library.absolutePathFor(entry),
          contentHash: entry.currentRevision.contentHash,
        );
      }
    }
    return null;
  }

  List<ScoreTarget> _targets() => [
    for (final entry
        in _library?.snapshot?.availableEntries ?? <LibraryEntry>[])
      if (_locate(entry.id) case final ScoreTarget target) target,
  ];

  Future<ReaderWorkspace> _prepareReader() => _workspaceFuture ??= (() async {
    try {
      final workspace =
          widget.readerWorkspace ??
          ReaderWorkspace(
            await ReaderStateStore.open(
              statePath: p.join(
                _library!.dataDirectory.path,
                'reader-state.json',
              ),
            ),
          );
      if (!mounted) {
        if (widget.readerWorkspace == null) workspace.dispose();
        throw StateError('Library disposed');
      }
      _workspace = workspace;
      workspace.addListener(_changed);
      setState(() {});
      return workspace;
    } catch (_) {
      _workspaceFuture = null;
      rethrow;
    }
  })();

  Future<void> _openSetLists() async {
    if (_openingReader) return;
    _openingReader = true;
    try {
      final workspace = await _prepareReader();
      final offline = !_canProvideLibrary || _library?.rootPath == null;
      final sync = offline ? await _prepareSync() : null;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SetListsScreen(
            workspace: workspace,
            locate: sync?.locateOffline ?? _locate,
            targets: sync == null
                ? _targets
                : () => [
                    for (final entry
                        in sync.replica?.snapshot.availableEntries ??
                            <LibraryEntry>[])
                      if (sync.locateOffline(entry.id)
                          case final ScoreTarget target)
                        target,
                  ],
            sourceChanges: sync ?? _library,
          ),
        ),
      );
    } catch (failure, stack) {
      debugPrint('READER workspace_failed: $failure\n$stack');
      if (mounted) _message('批注和曲单数据暂时无法打开。请检查应用数据目录后重试。');
    } finally {
      _openingReader = false;
    }
  }

  Future<SyncController> _prepareSync() => _syncFuture ??= (() async {
    try {
      final workspace = await _prepareReader();
      final sync = SyncController(library: _library!, workspace: workspace);
      await sync.initialize();
      if (!mounted) {
        sync.dispose();
        throw StateError('Library disposed');
      }
      _sync = sync;
      return sync;
    } catch (_) {
      _syncFuture = null;
      rethrow;
    }
  })();

  Future<void> _openSync() async {
    try {
      final sync = await _prepareSync();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SyncScreen(
            controller: sync,
            openOffline: () => unawaited(_openOffline()),
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message('同步资料暂时无法打开，请检查应用数据目录。');
    }
  }

  Future<void> _openOffline() async {
    try {
      final sync = await _prepareSync();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => OfflineLibraryScreen(controller: sync),
        ),
      );
    } catch (_) {
      if (mounted) _message('离线谱库暂时无法打开，请检查应用数据目录。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              '曲谱库',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: const Color(0xfffaf9f5),
            actions: [
              IconButton(
                tooltip: '无线同步 / 连接电脑',
                onPressed: library?.initialized == true
                    ? () => unawaited(_openSync())
                    : null,
                icon: const Icon(Icons.wifi),
              ),
              IconButton(
                tooltip: '离线谱库',
                onPressed: library?.initialized == true
                    ? () => unawaited(_openOffline())
                    : null,
                icon: const Icon(Icons.offline_pin_outlined),
              ),
              IconButton(
                tooltip: '曲单',
                onPressed: library?.initialized == true ? _openSetLists : null,
                icon: const Icon(Icons.queue_music),
              ),
              IconButton(
                tooltip: '打开单份曲谱',
                onPressed: _openSingle,
                icon: const Icon(Icons.description_outlined),
              ),
              if (_canProvideLibrary)
                IconButton(
                  tooltip: '选择谱库文件夹',
                  onPressed: library == null ? null : _selectRoot,
                  icon: const Icon(Icons.folder_open_outlined),
                ),
              const SizedBox(width: 8),
            ],
          ),
          drawer: !wide && library?.rootPath != null
              ? Drawer(child: SafeArea(child: _sidebar(library!)))
              : null,
          body: library == null
              ? Center(
                  child: _initializationError == null
                      ? const CircularProgressIndicator()
                      : Text(_initializationError!),
                )
              : !library.initialized
              ? const Center(child: CircularProgressIndicator())
              : library.rootPath == null
              ? _welcome(library)
              : Row(
                  children: [
                    if (wide) SizedBox(width: 260, child: _sidebar(library)),
                    if (wide) const VerticalDivider(width: 1),
                    Expanded(child: _content(library)),
                  ],
                ),
        );
      },
    );
  }

  Widget _welcome(LibraryController library) => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.library_music_outlined,
                size: 64,
                color: Color(0xff236459),
              ),
              const SizedBox(height: 24),
              Text(
                _canProvideLibrary ? '你的文件夹，就是你的谱库' : '把整个谱库带在身边',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                _canProvideLibrary
                    ? '保留原来的整理方式，按文件夹浏览，按曲名和路径搜索。\n支持 PDF、JPG、PNG 和 WebP。'
                    : '连接同一Wi-Fi下的电脑，同步完整谱库。\n已同步的曲谱、批注和曲单可在断网后使用。',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.8, color: Color(0xff65736b)),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (_canProvideLibrary)
                    FilledButton.icon(
                      onPressed: _selectRoot,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('选择谱库文件夹'),
                    ),
                  FilledButton.icon(
                    onPressed: () => unawaited(_openSync()),
                    icon: const Icon(Icons.wifi),
                    label: const Text('连接电脑 / 无线同步'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openOffline()),
                    icon: const Icon(Icons.offline_pin_outlined),
                    label: const Text('打开离线谱库'),
                  ),
                ],
              ),
              if (library.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    library.error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _sidebar(LibraryController library) => ColoredBox(
    color: const Color(0xfff6f5ef),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '文件夹',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                '${library.totalCount} 份曲谱 · ${library.folders.length - 1} 个文件夹',
                style: const TextStyle(color: Color(0xff65736b), fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(children: [_folderNode(library, '', 0)])),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Tooltip(
            message: library.rootPath!,
            child: Text(
              library.rootPath!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xff65736b)),
            ),
          ),
        ),
      ],
    ),
  );

  String _parent(String folder) {
    final index = folder.lastIndexOf('/');
    return index < 0 ? '' : folder.substring(0, index);
  }

  Widget _folderNode(LibraryController library, String folder, int depth) {
    final children =
        library.folders
            .where(
              (candidate) =>
                  candidate.isNotEmpty && _parent(candidate) == folder,
            )
            .toList()
          ..sort();
    final expanded = !_collapsedFolders.contains(folder);
    final selected = library.currentFolder == folder;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.only(left: mathIndent(depth)),
          child: ListTile(
            dense: true,
            selected: selected,
            selectedTileColor: const Color(0xffdfe8df),
            leading: Icon(
              folder.isEmpty
                  ? Icons.library_music_outlined
                  : Icons.folder_outlined,
              size: 20,
            ),
            title: Tooltip(
              message: folder.isEmpty ? library.rootPath! : folder,
              child: Text(
                folder.isEmpty
                    ? p.basename(library.rootPath!)
                    : p.posix.basename(folder),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: children.isEmpty
                ? null
                : IconButton(
                    tooltip: expanded ? '收起文件夹' : '展开文件夹',
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    onPressed: () => setState(() {
                      expanded
                          ? _collapsedFolders.add(folder)
                          : _collapsedFolders.remove(folder);
                    }),
                  ),
            onTap: () => _folder(folder),
          ),
        ),
        if (expanded)
          for (final child in children) _folderNode(library, child, depth + 1),
      ],
    );
  }

  double mathIndent(int depth) => (depth * 12.0).clamp(0, 132);

  Widget _content(LibraryController library) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: library.setQuery,
                decoration: InputDecoration(
                  hintText: '搜索曲名或文件夹名称',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            library.setQuery('');
                          },
                        ),
                  filled: true,
                  fillColor: const Color(0xfffaf9f5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xffdedfd7)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: '刷新谱库',
              onPressed: () => unawaited(library.rescan()),
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<String>(
              tooltip: '更多刷新选项',
              onSelected: (_) => unawaited(library.rescan(verifyAll: true)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'verify', child: Text('完整校验文件内容')),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            IconButton(
              tooltip: '上一级文件夹',
              onPressed: library.currentFolder.isEmpty
                  ? null
                  : () => _folder(_parent(library.currentFolder)),
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
            Expanded(
              child: Tooltip(
                message: library.currentFolder.isEmpty
                    ? library.rootPath!
                    : library.currentFolder,
                child: Text(
                  library.currentFolder.isEmpty
                      ? '谱库根目录'
                      : library.currentFolder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (library.searching) ...[
              const Text('当前文件夹及子文件夹', style: TextStyle(fontSize: 12)),
              Checkbox(
                value: library.searchCurrentFolder,
                onChanged: (value) => library.setSearchScope(value ?? false),
              ),
            ],
          ],
        ),
      ),
      if (library.scanning) const LinearProgressIndicator(minHeight: 2),
      if (_workspace?.pending.isNotEmpty ?? false)
        _notice(
          '还有 ${_workspace!.pending.length} 笔批注未保存，点击重试。退出应用将丢失未保存笔迹。',
          Icons.edit_outlined,
          () => unawaited(_workspace!.retryStrokes()),
        ),
      if (library.error != null)
        _notice(library.error!, Icons.error_outline, () => _details(library)),
      if (library.watchWarning != null)
        _notice(
          library.watchWarning!,
          Icons.info_outline,
          () => _details(library),
        ),
      if (library.storageWarnings.isNotEmpty ||
          (library.lastScan?.issues.isNotEmpty ?? false) ||
          (library.lastScan?.ambiguities.isNotEmpty ?? false))
        _notice(
          '${library.lastScan?.issues.length ?? 0} 项读取提示 · ${library.lastScan?.ambiguities.length ?? 0} 项关联待确认${library.storageWarnings.isEmpty ? '' : ' · 索引恢复提示'}',
          Icons.info_outline,
          () => _details(library),
        ),
      Expanded(child: _entries(library)),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        color: const Color(0xfffaf9f5),
        child: Text(
          library.scanning
              ? '正在更新谱库，可继续搜索和浏览已有结果…'
              : '${library.visibleEntries.length} 份曲谱${library.lastScanDuration == null ? '' : ' · 上次更新 ${(library.lastScanDuration!.inMilliseconds / 1000).toStringAsFixed(2)} 秒'}',
          style: const TextStyle(fontSize: 12, color: Color(0xff65736b)),
        ),
      ),
    ],
  );

  Widget _notice(String text, IconData icon, VoidCallback action) => Material(
    color: const Color(0xffffedcf),
    child: InkWell(
      onTap: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    ),
  );

  Widget _entries(LibraryController library) {
    final entries = library.visibleEntries;
    final subfolders = library.searching ? <String>[] : library.listing.folders;
    if (entries.isEmpty && subfolders.isEmpty) {
      return Center(
        child: Text(
          library.scanning
              ? '正在扫描文件夹…'
              : library.searching
              ? '没有找到匹配的曲谱'
              : '这个文件夹里还没有曲谱',
          style: const TextStyle(color: Color(0xff65736b)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: subfolders.length + entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        if (index < subfolders.length) {
          final folder = subfolders[index];
          return ListTile(
            leading: const Icon(
              Icons.folder_outlined,
              color: Color(0xff8b784a),
            ),
            title: Text(p.posix.basename(folder)),
            subtitle: Text(folder, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _folder(folder),
          );
        }
        final entry = entries[index - subfolders.length];
        final image =
            p.posix.extension(entry.relativePath).toLowerCase() != '.pdf';
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          leading: Container(
            width: 38,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0xffe1e9e0),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              image ? Icons.image_outlined : Icons.description_outlined,
              color: const Color(0xff236459),
            ),
          ),
          title: Text(
            p.posix.basenameWithoutExtension(entry.relativePath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Tooltip(
            message: library.absolutePathFor(entry),
            child: Text(
              library.absolutePathFor(entry),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xff65736b)),
            ),
          ),
          trailing: IconButton(
            tooltip: '查看完整路径',
            icon: const Icon(Icons.info_outline, size: 19),
            onPressed: () => _pathDetails(entry),
          ),
          onTap: () => unawaited(_openEntry(entry)),
        );
      },
    );
  }

  void _pathDetails(LibraryEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(p.posix.basename(entry.relativePath)),
      content: SelectableText(_library!.absolutePathFor(entry)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  void _details(LibraryController library) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('谱库更新提示'),
      content: SizedBox(
        width: 650,
        height: 380,
        child: SingleChildScrollView(
          child: SelectableText(
            [
              if (library.error != null) library.error!,
              if (library.watchWarning != null) library.watchWarning!,
              if (library.storageWarnings.isNotEmpty)
                '上次索引文件无法完整读取，已从备份恢复。最近一次索引变化可能需要重新扫描确认；原谱未被更改。',
              for (final issue in library.lastScan?.issues ?? <ScanIssue>[])
                '${issue.relativePath.isEmpty ? '谱库根目录' : issue.relativePath}：${_issueMessage(issue.stage)}',
              for (final ambiguity
                  in library.lastScan?.ambiguities ?? <MoveAmbiguity>[])
                '存在相同内容的多个位置，已保留独立条目，未自动转移批注。缺失关联 ${ambiguity.missingEntryIds.length} 项，新增 ${ambiguity.newEntryIds.length} 项。',
            ].join('\n\n'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  String _issueMessage(ScanIssueStage stage) => switch (stage) {
    ScanIssueStage.deferred => '文件尚未下载，请先从云盘下载到本机后刷新。',
    ScanIssueStage.link => '此位置是文件夹链接，已跳过，以免读取谱库之外的资料。',
    ScanIssueStage.enumeration => '暂时无法浏览此文件夹，已保留上次索引。请检查连接或权限后刷新。',
    ScanIssueStage.metadata ||
    ScanIssueStage.content => '文件暂时无法读取，请检查是否完整、是否已下载，再刷新。',
    ScanIssueStage.identity => '无法确认文件关联，已保守保留条目。',
  };
}
