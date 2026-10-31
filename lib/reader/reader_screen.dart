import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';

import 'reader_input.dart';
import 'reader_page_seek_bar.dart';
import 'reader_stage.dart';
import 'reader_preview_frame.dart';
import 'reader_page_window.dart';
import 'sharp_pdf_page.dart';
import 'sharp_file_image.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.initialPath,
    this.entryId,
    this.revisionId,
  });

  final String? initialPath;
  final String? entryId;
  final String? revisionId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final TransformationController _transform = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _seekRegionKey = GlobalKey();
  final List<String> _recent = [];
  PdfDocument? _document;
  String? _filePath;
  String? _error;
  bool _loading = false;
  bool _toolsVisible = !isMobileReader;
  bool _tablet = false;
  bool _landscape = false;
  int _page = 1;
  Duration? _requestedAt;
  int _visiblePage = 1;
  int _openGeneration = 0;
  double _scale = 1;
  ImageDisplayInfo? _imageInfo;
  int _inputGeneration = 0;

  void _resetViewport() {
    setState(() {
      _inputGeneration++;
      _transform.value = Matrix4.identity();
    });
  }

  final Stopwatch _openWatch = Stopwatch();
  final Map<int, Stopwatch> _pageWatches = {};
  final Set<int> _renderedPages = {};

  int get _pageCount => _document?.pages.length ?? (_filePath == null ? 0 : 1);
  bool get _ready => _filePath != null && !_loading && _error == null;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    if (widget.initialPath != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _open(widget.initialPath!),
      );
    }
  }

  void _onTransform() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if ((_scale - scale).abs() > 0.01 && mounted) {
      setState(() => _scale = scale);
    }
  }

  @override
  void dispose() {
    _openGeneration++;
    _document?.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '曲谱（PDF、JPG、PNG、WebP）',
            extensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
            uniformTypeIdentifiers: ['com.adobe.pdf', 'public.image'],
          ),
        ],
      );
      if (file != null && mounted) await _open(file.path);
    } catch (error) {
      if (mounted) _showMessage('无法打开文件选择器：$error');
    }
  }

  Future<void> _open(String filePath) async {
    final generation = ++_openGeneration;
    final old = _document;
    setState(() {
      _filePath = filePath;
      _document = null;
      _error = null;
      _loading = true;
      _page = 1;
      _visiblePage = 1;
      _imageInfo = null;
      _inputGeneration++;
      _renderedPages.clear();
      _pageWatches.clear();
      _transform.value = Matrix4.identity();
    });
    _openWatch
      ..reset()
      ..start();
    await old?.dispose();
    PdfDocument? opened;
    try {
      final extension = path.extension(filePath).toLowerCase();
      if (!const [
        '.pdf',
        '.jpg',
        '.jpeg',
        '.png',
        '.webp',
      ].contains(extension)) {
        throw const FormatException('支持的格式：PDF、JPG、PNG、WebP');
      }
      if (!await File(filePath).exists()) {
        throw const FileSystemException('文件不存在或暂时无法读取');
      }
      if (extension == '.pdf') {
        await pdfrxFlutterInitialize();
        opened = await PdfDocument.openFile(filePath);
        if (opened.pages.isEmpty) {
          throw const FormatException('这份 PDF 没有可显示的页面');
        }
      }
      if (!mounted || generation != _openGeneration) {
        await opened?.dispose();
        return;
      }
      setState(() {
        _document = opened;
        _loading = false;
        _recent.remove(filePath);
        _recent.insert(0, filePath);
        if (_recent.length > 8) _recent.removeLast();
      });
      debugPrint(
        'READER opened type=$extension pages=$_pageCount metadata_ms=${_openWatch.elapsedMilliseconds}',
      );
    } catch (error, stack) {
      await opened?.dispose();
      debugPrint('READER open_failed: $error\n$stack');
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _loading = false;
        _error = '无法读取这份曲谱。请检查文件是否完整、是否受密码保护，或先在云盘中下载到本机，再重新打开。';
      });
    }
  }

  void _turn(int direction) {
    if (!_ready) return;
    _seek(_page + direction);
  }

  void _seek(int next) {
    if (!_ready) return;
    if (next < 1 || next > _pageCount) {
      return;
    }
    _requestedAt = readerPresentationNow();
    _pageWatches[next] = Stopwatch()..start();
    setState(() {
      _page = next;
      _inputGeneration++;
      _transform.value = Matrix4.identity();
    });
    debugPrint(
      'READER page_request page=$_page previously_rendered=${_renderedPages.contains(_page)}',
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  void _zoom(double factor) {
    final next = (_scale * factor).clamp(1.0, 4.0);
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final centre = viewport?.size.center(Offset.zero) ?? Offset.zero;
    final scene = _transform.toScene(centre);
    _transform.value = Matrix4.diagonal3Values(next, next, 1)
      ..setTranslationRaw(
        centre.dx - scene.dx * next,
        centre.dy - scene.dy * next,
        0,
      );
  }

  void _onRendered(int number) {
    if (_renderedPages.add(number)) {
      debugPrint(
        'READER page_rendered page=$number open_elapsed_ms=${_openWatch.elapsedMilliseconds}',
      );
    }
    final watch = _pageWatches.remove(number);
    if (watch != null) {
      debugPrint(
        'READER page_presented page=$number elapsed_ms=${watch.elapsedMilliseconds}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ReaderStage(
        hasReadablePage: _ready,
        onToolsVisibilityChanged: (visible) {
          setState(() => _toolsVisible = visible);
          if (!visible) _resetViewport();
        },
        onPrevious: () => _turn(-1),
        onNext: () => _turn(1),
        onViewportChanged: _resetViewport,
        top: _header(),
        bottom: _footer(),
        contentBuilder: (toggleTools) => _tabletFrame(toggleTools),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xfffaf9f5),
        border: Border(bottom: BorderSide(color: Color(0xffdedfd7))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop())
                IconButton(
                  tooltip: '返回谱库',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
              const Icon(
                Icons.library_music_outlined,
                color: Color(0xff236459),
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _filePath == null ? '曲谱阅读器' : path.basename(_filePath!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _filePath == null
                          ? '打开曲谱，专注演奏'
                          : path.dirname(_filePath!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff65736b),
                      ),
                    ),
                  ],
                ),
              ),
              if (_ready && _document == null)
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (_) => showImageDisplayInfo(context, _imageInfo),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'info', child: Text('图片信息')),
                  ],
                ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canPreviewReader)
                IconButton(
                  tooltip: _tablet ? '退出开发预览' : '开发预览（模拟平板）',
                  isSelected: _tablet,
                  icon: const Icon(Icons.tablet_mac_outlined),
                  onPressed: () => setState(() => _tablet = !_tablet),
                ),
              if (canPreviewReader && _tablet)
                IconButton(
                  tooltip: '开发预览：切换横竖屏',
                  icon: const Icon(Icons.screen_rotation_outlined),
                  onPressed: () => setState(() => _landscape = !_landscape),
                ),
              if (_ready) ...[
                IconButton(
                  tooltip: '缩小',
                  onPressed: () => _zoom(1 / 1.25),
                  icon: const Icon(Icons.remove, size: 20),
                ),
                IconButton(
                  tooltip: '恢复整页',
                  onPressed: () => _transform.value = Matrix4.identity(),
                  icon: const Icon(Icons.fit_screen, size: 20),
                ),
                IconButton(
                  tooltip: '放大',
                  onPressed: () => _zoom(1.25),
                  icon: const Icon(Icons.add, size: 20),
                ),
              ],
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _chooseFile,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('打开曲谱'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabletFrame(VoidCallback toggleTools) => ReaderPreviewFrame(
    enabled: canPreviewReader && _tablet,
    landscape: _landscape,
    child: _body(toggleTools),
  );

  Widget _body(VoidCallback toggleTools) {
    if (_filePath == null) return _welcome();
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 18),
            Text('正在打开曲谱…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 52,
                  color: Color(0xff8a5446),
                ),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _chooseFile,
                  child: const Text('打开其他曲谱'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ReaderInput(
      onPrevious: () => _turn(-1),
      onNext: () => _turn(1),
      onCenterTap: toggleTools,
      allowPointerPageTurns: _scale <= 1.01,
      transform: _transform,
      viewportKey: _viewportKey,
      touchControlKey: _seekRegionKey,
      gestureGeneration: _inputGeneration,
      pageAspect: _document == null
          ? null
          : _document!.pages[_visiblePage - 1].width /
                _document!.pages[_visiblePage - 1].height,
      child: _document == null ? _image() : _pdf(),
    );
  }

  Widget _pdf() {
    final document = _document!;
    final generation = _openGeneration;
    return ReaderPageWindow(
      key: ValueKey(generation),
      pageNumber: _page,
      requestedAt: _requestedAt,
      pageCount: _pageCount,
      aspectFor: (number) =>
          document.pages[number - 1].width / document.pages[number - 1].height,
      onPresented: (_, number) => setState(() => _visiblePage = number),
      readyPageBuilder: (number, active, ready, failed) => SharpPdfPage(
        key: ValueKey(number),
        page: document.pages[number - 1],
        active: active,
        transform: _transform,
        viewportKey: _viewportKey,
        onRendered: () {
          ready();
          if (mounted && generation == _openGeneration) _onRendered(number);
        },
        onError: failed,
      ),
    );
  }

  Widget _image() {
    final generation = _openGeneration;
    return SharpFileImage(
      path: _filePath!,
      transform: _transform,
      onRendered: () {
        if (mounted && generation == _openGeneration) _onRendered(1);
      },
      onImageInfo: (info) {
        if (mounted && generation == _openGeneration) _imageInfo = info;
      },
    );
  }

  Widget _welcome() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(36),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: const Color(0xffdfe8df),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.music_note_outlined,
                  size: 52,
                  color: Color(0xff236459),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '让曲谱回到演奏中',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '打开一份本地曲谱，开始阅读。\n点击两侧、左右滑动，或使用脚踏翻页。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xff65736b), height: 1.8),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _chooseFile,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text('选择曲谱文件'),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'PDF  ·  JPG  ·  PNG  ·  WebP',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1,
                  color: Color(0xff65736b),
                ),
              ),
              if (_recent.isNotEmpty) ...[
                const SizedBox(height: 28),
                for (final file in _recent)
                  ListTile(
                    title: Text(path.basename(file)),
                    subtitle: Text(
                      path.dirname(file),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: const Icon(Icons.history),
                    onTap: () => _open(file),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer() => !_ready || !_toolsVisible
      ? const SizedBox.shrink()
      : ReaderPageSeekBar(
          hitRegionKey: _seekRegionKey,
          key: ValueKey(_openGeneration),
          currentPage: _visiblePage,
          pageCount: _pageCount,
          onSeek: (page, _) => _seek(page),
        );
}
