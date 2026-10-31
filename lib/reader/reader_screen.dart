import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';

import 'reader_input.dart';
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
  final List<String> _recent = [];
  PdfDocument? _document;
  String? _filePath;
  String? _error;
  bool _loading = false;
  bool _tablet = false;
  bool _landscape = false;
  int _page = 1;
  int _openGeneration = 0;
  double _scale = 1;
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
    final next = _page + direction;
    if (next < 1 || next > _pageCount) {
      _showMessage(direction < 0 ? '已经是第一页' : '已经是最后一页');
      return;
    }
    _pageWatches[next] = Stopwatch()..start();
    setState(() {
      _page = next;
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
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(child: _tabletFrame()),
            _footer(),
          ],
        ),
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
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: _tablet ? '退出平板预览' : '平板布局预览',
                isSelected: _tablet,
                icon: const Icon(Icons.tablet_mac_outlined),
                onPressed: () => setState(() => _tablet = !_tablet),
              ),
              if (_tablet)
                IconButton(
                  tooltip: '切换横竖屏',
                  icon: const Icon(Icons.screen_rotation_outlined),
                  onPressed: () => setState(() => _landscape = !_landscape),
                ),
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

  Widget _tabletFrame() => ReaderPreviewFrame(
    enabled: _tablet,
    landscape: _landscape,
    child: _body(),
  );

  Widget _body() {
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
      allowPointerPageTurns: _scale <= 1.01,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: InteractiveViewer(
          key: _viewportKey,
          transformationController: _transform,
          minScale: 1,
          maxScale: 4,
          child: _document == null ? _image() : _pdf(),
        ),
      ),
    );
  }

  Widget _pdf() {
    final document = _document!;
    final generation = _openGeneration;
    return ReaderPageWindow(
      key: ValueKey(generation),
      pageNumber: _page,
      pageCount: _pageCount,
      aspectFor: (number) =>
          document.pages[number - 1].width / document.pages[number - 1].height,
      pageBuilder: (number) => SharpPdfPage(
        key: ValueKey(number),
        page: document.pages[number - 1],
        active: number == _page,
        transform: _transform,
        viewportKey: _viewportKey,
        onRendered: () {
          if (mounted && generation == _openGeneration) _onRendered(number);
        },
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

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xfffaf9f5),
        border: Border(top: BorderSide(color: Color(0xffdedfd7))),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: '上一页 · Page Up',
            onPressed: _ready ? () => _turn(-1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            _ready ? '$_page / $_pageCount' : '本地阅读',
            key: const ValueKey('page-indicator'),
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            tooltip: '下一页 · Page Down',
            onPressed: _ready ? () => _turn(1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          if (_ready) ...[
            IconButton(
              tooltip: '缩小',
              onPressed: () => _zoom(1 / 1.25),
              icon: const Icon(Icons.remove, size: 20),
            ),
            Tooltip(
              message: '恢复整页',
              child: TextButton(
                onPressed: () => _transform.value = Matrix4.identity(),
                child: Text('${(_scale * 100).round()}%'),
              ),
            ),
            IconButton(
              tooltip: '放大',
              onPressed: () => _zoom(1.25),
              icon: const Icon(Icons.add, size: 20),
            ),
          ],
        ],
      ),
    );
  }
}
