import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import 'annotation_text_layer.dart';
import 'reader_input.dart';
import 'reader_page_seek_bar.dart';
import 'reader_stage.dart';
import 'reader_preview_frame.dart';
import 'reader_page_window.dart';
import 'reader_session.dart';
import 'reader_workspace.dart';
import 'sharp_pdf_page.dart';
import 'sharp_file_image.dart';
import 'paper_color_sampler.dart';
import 'reader_tool_button.dart';

class LibraryReaderScreen extends StatefulWidget {
  const LibraryReaderScreen({
    super.key,
    required this.workspace,
    required this.locate,
    required this.initialTarget,
    this.setListId,
    this.itemId,
    this.sourceChanges,
    this.loader,
    this.colorSampler,
    this.presentationClock,
  });
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final ScoreTarget initialTarget;
  final String? setListId;
  final String? itemId;
  final Listenable? sourceChanges;
  final ScoreLoader? loader;
  final PaperColorSampler? colorSampler;
  final Duration Function()? presentationClock;
  @override
  State<LibraryReaderScreen> createState() => _LibraryReaderScreenState();
}

class _LibraryReaderScreenState extends State<LibraryReaderScreen> {
  late final ReaderSession _session;
  final TransformationController _transform = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _seekRegionKey = GlobalKey();
  final GlobalKey _textSelectionKey = GlobalKey();
  bool _tablet = false;
  bool _landscape = false;
  bool _writing = false;
  late final PaperColorSampler _colorSampler =
      widget.colorSampler ?? PaperColorSampler();
  bool _picking = false, _sampling = false;
  bool _editing = !isMobileReader;
  int _inputGeneration = 0;
  int? _lastSample;
  bool _usingSample = false, _sampleMenuOpen = false;
  final _sampleButtonKey = GlobalKey();
  int _pickEpoch = 0;
  String? _pickMessage;
  EdgeInsets _panInsets = EdgeInsets.zero;
  ReaderTool _tool = ReaderTool.pen;
  bool _textTool = false;
  final _sizes = <ReaderTool, double>{
    ReaderTool.pen: 3.2,
    ReaderTool.highlighter: 16,
    ReaderTool.eraser: 14.6,
  };
  bool _touchTransforming = false;
  final _deferredTurns = ReaderNavigationQueue();
  String? _navigationWarning;
  int _direction = 1;
  Duration? _requestedAt;
  PageKey? _visiblePage;
  LoadedScore? _visibleDocument;
  final _imageInfos = <PageKey, ImageDisplayInfo>{};
  LoadedScore? _prewarmScore;
  int _prewarmEpoch = 0;
  (PageKey, DocumentKey)? _prewarmAnchor;
  int _color = 0xffc12b32;
  double _scale = 1;
  PageKey? _shownPage;
  final Set<PageKey> _renderedPages = {};
  Stopwatch? _pageWatch;
  bool _presented = false;

  @override
  void initState() {
    super.initState();
    _session = ReaderSession(
      workspace: widget.workspace,
      locate: widget.locate,
      setListId: widget.setListId,
      loader: widget.loader,
      deferPositionPersistence: true,
    )..addListener(_changed);
    widget.workspace.addListener(_changed);
    widget.sourceChanges?.addListener(_session.refreshSource);
    _transform.addListener(_transformChanged);
    unawaited(
      _session.open(
        widget.initialTarget,
        itemId: widget.itemId,
        restore: widget.setListId == null,
      ),
    );
  }

  void _transformChanged() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (mounted && (_scale - scale).abs() > .01) setState(() => _scale = scale);
  }

  void _changed() {
    if (!mounted) return;
    if (_shownPage != _session.pageKey) {
      _inputGeneration++;
      _cancelPick();
      _prewarmEpoch++;
      _prewarmScore = null;
      _prewarmAnchor = null;
      _session.cancelPrewarm();
      _shownPage = _session.pageKey;
      final page = _shownPage;
      if (page != null) {
        debugPrint(
          'READER page_request page=${page.pageNumber} previously_rendered=${_renderedPages.contains(page)}',
        );
        _renderedPages.removeWhere(
          (candidate) =>
              candidate.document != page.document ||
              (candidate.pageNumber - page.pageNumber).abs() > 1,
        );
        _pageWatch = Stopwatch()..start();
        _presented = false;
      }
      _transform.value = Matrix4.identity();
    }
    setState(() {});
    if (_session.pageKey == _visiblePage &&
        _session.page == _session.current?.pageCount) {
      unawaited(_prewarmNext());
    }
  }

  @override
  void dispose() {
    _pickEpoch++;
    _colorSampler.dispose();
    widget.workspace.removeListener(_changed);
    widget.sourceChanges?.removeListener(_session.refreshSource);
    _session.removeListener(_changed);
    _session.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<bool> _confirmLeaving() async {
    if (widget.workspace.pending.isEmpty &&
        widget.workspace.pendingPaths.isEmpty &&
        widget.workspace.pendingText.isEmpty) {
      return true;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('批注尚未保存'),
            content: const Text('退出应用会丢失未保存内容。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续保存'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('返回谱库'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _back() async {
    if (!await _confirmLeaving()) return;
    await widget.workspace.flushPositions();
    if (mounted) Navigator.pop(context);
  }

  StrokeStyle get _style => StrokeStyle(
    tool: _tool == ReaderTool.highlighter
        ? AnnotationTool.highlighter
        : AnnotationTool.pen,
    argb: _tool == ReaderTool.highlighter
        ? ((_color & 0xffffff) | 0x55000000)
        : _color,
    widthFraction:
        _sizes[_tool == ReaderTool.highlighter
            ? ReaderTool.highlighter
            : ReaderTool.pen]! /
        810,
  );

  void _cancelPick() {
    _pickEpoch++;
    _picking = false;
    _pickMessage = null;
  }

  void _selectTool(ReaderTool tool) => setState(() {
    _cancelPick();
    _textTool = false;
    _tool = tool;
  });

  Future<void> _sampleAction() async {
    if (_writing) return;
    if (_picking || _lastSample == null) {
      _togglePicking();
      return;
    }
    final anchor =
        _sampleButtonKey.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final page = _visiblePage, generation = _inputGeneration;
    final sample = _lastSample!;
    setState(() => _sampleMenuOpen = true);
    final choice = await showMenu<String>(
      context: context,
      requestFocus: false,
      position: RelativeRect.fromRect(
        anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'use',
          height: 48,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Color(sample),
                  border: Border.all(color: const Color(0xff52615c)),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              const Text('使用此颜色'),
            ],
          ),
        ),
        const PopupMenuItem(value: 'pick', height: 48, child: Text('重新吸色')),
      ],
    );
    if (!mounted) return;
    setState(() => _sampleMenuOpen = false);
    if (!_editing || generation != _inputGeneration || page != _visiblePage) {
      return;
    }
    if (choice == 'pick') {
      _togglePicking();
    } else if (choice == 'use') {
      setState(() {
        _cancelPick();
        _color = sample;
        _tool = ReaderTool.pen;
        _usingSample = true;
      });
    }
  }

  void _setEditing(bool editing) {
    setState(() {
      _editing = editing;
      if (!editing) {
        _textTool = false;
        _inputGeneration++;
        _cancelPick();
        _touchTransforming = false;
        _transform.value = Matrix4.identity();
      }
    });
  }

  void _resetViewport() {
    setState(() {
      _inputGeneration++;
      _cancelPick();
      _touchTransforming = false;
      _transform.value = Matrix4.identity();
    });
  }

  void _togglePicking() {
    if (_writing) return;
    setState(() {
      if (_picking) {
        _cancelPick();
      } else {
        _pickEpoch++;
        _picking = true;
        _pickMessage = null;
      }
    });
  }

  Future<void> _pickColor(PageKey page, Offset normalized) async {
    if (!_picking || _sampling || page != _visiblePage) return;
    final epoch = ++_pickEpoch;
    setState(() {
      _sampling = true;
      _pickMessage = null;
    });
    try {
      final color = await _colorSampler.sample(page, normalized);
      if (!mounted ||
          epoch != _pickEpoch ||
          !_picking ||
          page != _visiblePage) {
        return;
      }
      if (color == null) {
        setState(() => _pickMessage = '未能读取该处底色，请点在纸张内或重试。');
      } else {
        setState(() {
          _color = color.toARGB32() | 0xff000000;
          _lastSample = _color;
          _usingSample = true;
          _tool = ReaderTool.pen;
          _picking = false;
        });
      }
    } catch (_) {
      if (mounted && epoch == _pickEpoch) {
        setState(() => _pickMessage = '底色读取失败，请重试。');
      }
    } finally {
      if (mounted) setState(() => _sampling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _session.current;
    final page = _session.pageKey;
    final workspace = widget.workspace;
    final title =
        _visibleDocument?.target.displayPath ??
        current?.target.displayPath ??
        widget.initialTarget.displayPath;
    return Scaffold(
      body: ReaderStage(
        hasReadablePage: _visiblePage != null,
        statusLabel: workspace.unsavedCount > 0
            ? '${workspace.unsavedCount} 项未保存'
            : '阅读状态',
        onToolsVisibilityChanged: _setEditing,
        allowOverlayPageKeys: _sampleMenuOpen,
        onObstructionChanged: (insets) => setState(() => _panInsets = insets),
        onPrevious: () => _navigate(NavigationDirection.backward),
        onNext: () => _navigate(NavigationDirection.forward),
        onViewportChanged: _resetViewport,
        top: Material(
          color: const Color(0xfffaf9f5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppBar(
                leading: IconButton(
                  tooltip: '返回谱库',
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back),
                ),
                title: Text(
                  p.posix.basename(title.replaceAll('\\', '/')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
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
                  if (_visibleDocument != null && _visibleDocument!.pdf == null)
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      onSelected: (_) => unawaited(
                        showImageDisplayInfo(
                          context,
                          _imageInfos[_visiblePage],
                        ),
                      ),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'info', child: Text('图片信息')),
                      ],
                    ),
                  if (canPreviewReader)
                    IconButton(
                      tooltip: _tablet ? '退出开发预览' : '开发预览（模拟平板）',
                      isSelected: _tablet,
                      icon: const Icon(Icons.tablet_mac_outlined),
                      onPressed: () => setState(() {
                        _tablet = !_tablet;
                        _inputGeneration++;
                        _cancelPick();
                        _transform.value = Matrix4.identity();
                      }),
                    ),
                  if (canPreviewReader && _tablet)
                    IconButton(
                      tooltip: '开发预览：切换横竖屏',
                      icon: const Icon(Icons.screen_rotation_outlined),
                      onPressed: () => setState(() {
                        _landscape = !_landscape;
                        _inputGeneration++;
                        _cancelPick();
                        _transform.value = Matrix4.identity();
                      }),
                    ),
                ],
              ),
              if (page != null) _tools(_visiblePage ?? page),
            ],
          ),
        ),
        bottom: _footer(),
        notices: [
          if (workspace.store.storageWarnings.isNotEmpty)
            _notice('已从备份恢复，请检查最近修改。'),
          if (workspace.error != null) _notice(workspace.error!),
          if (workspace.textConflictNotice != null)
            _notice(workspace.textConflictNotice!),
          if (workspace.unsavedCount > 0)
            Material(
              color: const Color(0xffffedcf),
              child: ListTile(
                dense: true,
                title: Text('${workspace.unsavedCount} 项批注未保存'),
                trailing: TextButton(
                  onPressed: () => unawaited(workspace.retryStrokes()),
                  child: const Text('重试保存'),
                ),
              ),
            ),
          if (_session.message != null)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _notice(_session.message!),
                if (_visiblePage != null)
                  TextButton(
                    onPressed: () => _navigate(
                      _direction > 0
                          ? NavigationDirection.forward
                          : NavigationDirection.backward,
                    ),
                    child: const Text('重试翻页'),
                  ),
              ],
            ),
          if (_navigationWarning != null) _notice(_navigationWarning!),
          if (_pickMessage != null) _notice(_pickMessage!),
          if (_session.sourceChanged) _notice('源曲谱已变更，当前为旧版。'),
        ],
        loading: _session.loading && _visiblePage != null,
        contentBuilder: (toggleTools) => ReaderPreviewFrame(
          enabled: canPreviewReader && _tablet,
          landscape: _landscape,
          child: current == null || page == null
              ? Center(
                  child: _session.loading
                      ? const CircularProgressIndicator()
                      : FilledButton(
                          onPressed: () => unawaited(
                            _session.open(
                              widget.initialTarget,
                              itemId: widget.itemId,
                            ),
                          ),
                          child: const Text('重新打开'),
                        ),
                )
              : ReaderInput(
                  onPrevious: () => _navigate(NavigationDirection.backward),
                  onNext: () => _navigate(NavigationDirection.forward),
                  onCenterTap: _picking ? null : toggleTools,
                  allowPointerPageTurns: !_picking && _scale <= 1.01,
                  panInsets: _panInsets,
                  pageAspect:
                      _visibleDocument?.aspectFor(
                        _visiblePage?.pageNumber ?? 1,
                      ) ??
                      current.aspectFor(_session.page),
                  mouseInk: true,
                  editing: _editing,
                  gestureGeneration: _inputGeneration,
                  onTransformGestureChanged: (active) =>
                      setState(() => _touchTransforming = active),
                  transform: _transform,
                  viewportKey: _viewportKey,
                  touchControlKey: _seekRegionKey,
                  textTool: _textTool,
                  textSelectionKey: _textSelectionKey,
                  child: ReaderPageWindow(
                    documentKey: current.target.key,
                    pageNumber: _session.page,
                    pageCount: current.pageCount,
                    aspectFor: current.aspectFor,
                    direction: _direction,
                    requestedAt: _requestedAt,
                    presentationClock: widget.presentationClock,
                    retainDocument: current.retain,
                    releaseDocument: current.release,
                    holdPresentation: _writing,
                    onPresented: (document, number) {
                      final visible = PageKey(
                        entryId: current.target.entryId,
                        revisionId: current.target.revisionId,
                        pageNumber: number,
                      );
                      if (document != current.target.key) return;
                      setState(() {
                        if (_visiblePage != visible) _cancelPick();
                        _visiblePage = visible;
                        _visibleDocument = current;
                      });
                      _session.rememberPresented(visible, current.pageCount);
                      if (number == current.pageCount) {
                        unawaited(_prewarmNext());
                      }
                    },
                    prewarm: _prewarmScore == null
                        ? null
                        : ReaderPrewarmPage(
                            documentKey: _prewarmScore!.target.key,
                            aspect: _prewarmScore!.aspectFor(1),
                            retainDocument: _prewarmScore!.retain,
                            releaseDocument: _prewarmScore!.release,
                            pageBuilder: _prewarmBuilder(_prewarmScore!),
                          ),
                    readyPageBuilder: (number, active, ready, failed) =>
                        _surface(current, number, active, ready, failed),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _surface(
    LoadedScore document,
    int number,
    bool active,
    VoidCallback ready,
    ValueChanged<String?> failed,
  ) {
    final surfacePage = PageKey(
      entryId: document.target.entryId,
      revisionId: document.target.revisionId,
      pageNumber: number,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (document.pdf != null)
          SharpPdfPage(
            page: document.pdf!.pages[number - 1],
            active: active,
            transform: _transform,
            viewportKey: _viewportKey,
            onRendered: () {
              ready();
              _onRendered(document, number);
            },
            onError: failed,
            colorSampler: _colorSampler,
            colorKey: surfacePage,
          )
        else
          SharpFileImage(
            active: active,
            fileVersion: document.target.contentHash,
            path: document.renderPath ?? document.target.filePath,
            transform: _transform,
            onRendered: ready,
            onError: failed,
            colorSampler: _colorSampler,
            colorKey: surfacePage,
            onImageInfo: (info) {
              if (!mounted) return;
              _imageInfos[surfacePage] = info;
              while (_imageInfos.length > 6) {
                _imageInfos.remove(
                  _imageInfos.keys.firstWhere(
                    (key) => key != _visiblePage && key != surfacePage,
                  ),
                );
              }
            },
          ),
        AnnotationTextLayer(
          selectionKey: surfacePage == _visiblePage ? _textSelectionKey : null,
          mouseControlKey: _seekRegionKey,
          workspace: widget.workspace,
          page: surfacePage,
          enabled:
              active &&
              !_session.sourceChanged &&
              !_picking &&
              (!_textTool || (_editing && surfacePage == _visiblePage)),
          textTool: _textTool,
          style: _textTool
              ? StrokeStyle(
                  tool: AnnotationTool.pen,
                  argb: _color,
                  widthFraction: _style.widthFraction,
                )
              : _style,
          eraser: _tool == ReaderTool.eraser,
          eraserRadiusFraction: _sizes[ReaderTool.eraser]! / 810,
          suspended: _touchTransforming,
          onWritingChanged: _writingChanged,
        ),
        if (_picking && surfacePage == _visiblePage)
          PaperColorPickLayer(
            onPick: (point) => unawaited(_pickColor(surfacePage, point)),
          ),
      ],
    );
  }

  ReadyPageBuilder _prewarmBuilder(LoadedScore document) =>
      (number, active, ready, failed) =>
          _surface(document, number, active, ready, failed);

  Future<void> _prewarmNext() async {
    if (_session.pageKey != _visiblePage ||
        _session.page != _visibleDocument?.pageCount) {
      return;
    }
    final next = _session.nextPrewarmTarget;
    final anchor = next == null ? null : (_visiblePage!, next.key);
    if (_prewarmAnchor == anchor) return;
    _prewarmAnchor = anchor;
    _prewarmScore = null;
    _session.cancelPrewarm();
    final epoch = ++_prewarmEpoch;
    if (anchor == null) return;
    final loaded = await _session.prewarmNext();
    if (mounted && epoch == _prewarmEpoch && loaded != null) {
      setState(() => _prewarmScore = loaded);
    }
  }

  void _onRendered(LoadedScore document, int number) {
    if (!mounted ||
        !identical(document, _session.current) ||
        (number - _session.page).abs() > 1) {
      return;
    }
    final page = PageKey(
      entryId: document.target.entryId,
      revisionId: document.target.revisionId,
      pageNumber: number,
    );
    if (_renderedPages.add(page)) {
      debugPrint(
        'READER page_rendered page=$number window_size=${_renderedPages.length}',
      );
    }
    if (page == _shownPage && !_presented) {
      _presented = true;
      debugPrint(
        'READER page_presented page=$number elapsed_ms=${_pageWatch?.elapsedMilliseconds ?? 0}',
      );
    }
  }

  Widget _notice(String message) => Container(
    width: double.infinity,
    color: const Color(0xffffedcf),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
    child: Text(message, style: const TextStyle(fontSize: 12)),
  );

  Widget _tools(PageKey page) => Align(
    alignment: Alignment.center,
    child: Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      color: const Color(0xfffaf9f5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.center,
          children: [
            for (final tool in ReaderTool.values)
              ReaderToolButton(
                key: ValueKey(tool),
                tool: tool,
                selected: !_picking && !_textTool && _tool == tool,
                value: _sizes[tool]!,
                onSelect: () => _selectTool(tool),
                onChanged: (value) => setState(() => _sizes[tool] = value),
              ),
            IconButton(
              tooltip: '文字批注',
              isSelected: _textTool,
              icon: const Icon(Icons.text_fields),
              onPressed: () => setState(() {
                _cancelPick();
                _textTool = !_textTool;
              }),
            ),
            ReaderSampleColorButton(
              key: _sampleButtonKey,
              sample: _lastSample == null ? null : Color(_lastSample!),
              picking: _picking,
              busy: _sampling,
              usingSample: _usingSample && _tool == ReaderTool.pen,
              onPressed:
                  _visiblePage == null ||
                      _visiblePage != _session.pageKey ||
                      _writing
                  ? null
                  : _sampleAction,
            ),
            for (final (name, color) in [
              ('红色', 0xffc12b32),
              ('黑色', 0xff222222),
              ('蓝色', 0xff1c57ac),
              ('黄色', 0xffffc107),
            ])
              Tooltip(
                message: name,
                child: InkWell(
                  onTap: () => setState(() {
                    _cancelPick();
                    _usingSample = false;
                    _color = color;
                  }),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(color),
                          border: Border.all(
                            color: !_usingSample && _color == color
                                ? Colors.white
                                : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: !_usingSample && _color == color
                              ? const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: '撤销',
              onPressed: widget.workspace.store.canUndo(page)
                  ? () => unawaited(
                      widget.workspace.edit((store) => store.undo(page)),
                    )
                  : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: '重做',
              onPressed: widget.workspace.store.canRedo(page)
                  ? () => unawaited(
                      widget.workspace.edit((store) => store.redo(page)),
                    )
                  : null,
              icon: const Icon(Icons.redo),
            ),
          ],
        ),
      ),
    ),
  );

  void _navigate(NavigationDirection direction) {
    if (_sampleMenuOpen) {
      _sampleMenuOpen = false;
      Navigator.of(context).pop();
    }
    if (_picking) setState(_cancelPick);
    final step = direction == NavigationDirection.forward ? 1 : -1;
    _direction = step;
    if (_writing) {
      if (!_deferredTurns.add(direction)) {
        setState(() => _navigationWarning = '翻页处理中，请稍候。');
      }
      return;
    }
    _requestedAt = widget.presentationClock?.call() ?? readerPresentationNow();
    unawaited(_session.turn(direction));
  }

  void _writingChanged(bool writing) {
    if (!mounted) return;
    // Pointer-up commits its captured page before releasing deferred navigation.
    setState(() => _writing = writing);
    if (!writing) {
      while (!_deferredTurns.isEmpty) {
        _navigate(_deferredTurns.take()!);
      }
    }
  }

  Widget _footer() {
    if (!_editing || _writing || _visiblePage == null) {
      return const SizedBox.shrink();
    }
    return ReaderPageSeekBar(
      hitRegionKey: _seekRegionKey,
      key: ValueKey(_visibleDocument?.target.key),
      currentPage: _visiblePage!.pageNumber,
      pageCount: _visibleDocument?.pageCount ?? 1,
      enabled: _session.current?.target.key == _visibleDocument?.target.key,
      onCancel: _session.cancelSeek,
      onSeek: (number, gesture) {
        if (_writing ||
            !_editing ||
            _session.current?.target.key != _visibleDocument?.target.key) {
          return;
        }
        if (_picking) setState(_cancelPick);
        _direction = number >= _visiblePage!.pageNumber ? 1 : -1;
        _requestedAt =
            widget.presentationClock?.call() ?? readerPresentationNow();
        unawaited(_session.seek(number, gesture: gesture));
      },
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
}
