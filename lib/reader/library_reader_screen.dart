import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import 'annotation_canvas.dart';
import 'reader_input.dart';
import 'reader_stage.dart';
import 'reader_preview_frame.dart';
import 'reader_page_window.dart';
import 'reader_session.dart';
import 'reader_workspace.dart';
import 'sharp_pdf_page.dart';
import 'sharp_file_image.dart';

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
  });
  final ReaderWorkspace workspace;
  final ScoreLocator locate;
  final ScoreTarget initialTarget;
  final String? setListId;
  final String? itemId;
  final Listenable? sourceChanges;
  final ScoreLoader? loader;
  @override
  State<LibraryReaderScreen> createState() => _LibraryReaderScreenState();
}

class _LibraryReaderScreenState extends State<LibraryReaderScreen> {
  late final ReaderSession _session;
  final TransformationController _transform = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  bool _tablet = false;
  bool _landscape = false;
  bool _writing = false;
  bool _widthMenuOpen = false;
  bool _touchTransforming = false;
  final _deferredTurns = ReaderNavigationQueue();
  String? _navigationWarning;
  int _direction = 1;
  PageKey? _visiblePage;
  LoadedScore? _visibleDocument;
  double _eraserRadius = .018;
  bool _eraser = false;
  bool _highlight = false;
  double _width = .004;
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
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_changed);
    widget.sourceChanges?.removeListener(_session.refreshSource);
    _session.removeListener(_changed);
    _session.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<bool> _confirmLeaving() async {
    if (widget.workspace.pending.isEmpty &&
        widget.workspace.pendingPaths.isEmpty) {
      return true;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('还有笔迹未保存'),
            content: const Text('可以先留在阅读器重试保存。返回谱库后，未保存笔迹会保留在本次应用会话中；退出应用将丢失。'),
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
    tool: _highlight ? AnnotationTool.highlighter : AnnotationTool.pen,
    argb: _highlight ? ((_color & 0xffffff) | 0x55000000) : _color,
    widthFraction: _highlight ? _width * 5 : _width,
  );

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
        allowOverlayPageKeys: _widthMenuOpen,
        onPrevious: () => _navigate(NavigationDirection.backward),
        onNext: () => _navigate(NavigationDirection.forward),
        onViewportChanged: () => _transform.value = Matrix4.identity(),
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
                  if (canPreviewReader)
                    IconButton(
                      tooltip: _tablet ? '退出开发预览' : '开发预览（模拟平板）',
                      isSelected: _tablet,
                      icon: const Icon(Icons.tablet_mac_outlined),
                      onPressed: () => setState(() {
                        _tablet = !_tablet;
                        _transform.value = Matrix4.identity();
                      }),
                    ),
                  if (canPreviewReader && _tablet)
                    IconButton(
                      tooltip: '开发预览：切换横竖屏',
                      icon: const Icon(Icons.screen_rotation_outlined),
                      onPressed: () => setState(() {
                        _landscape = !_landscape;
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
            _notice('批注和曲单已从备份恢复，请检查最近修改。'),
          if (workspace.error != null) _notice(workspace.error!),
          if (workspace.unsavedCount > 0)
            Material(
              color: const Color(0xffffedcf),
              child: ListTile(
                dense: true,
                title: Text('${workspace.unsavedCount} 笔未保存'),
                trailing: TextButton(
                  onPressed: () => unawaited(workspace.retryStrokes()),
                  child: const Text('重试保存'),
                ),
              ),
            ),
          if (_session.message != null) _notice(_session.message!),
          if (_navigationWarning != null) _notice(_navigationWarning!),
          if (_session.sourceChanged)
            _notice('源曲谱已更新或移除，当前为旧版本。请返回谱库打开新版；旧批注仍保留。'),
          if (_session.loading) const LinearProgressIndicator(minHeight: 2),
        ],
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
                  onCenterTap: toggleTools,
                  allowPointerPageTurns: _scale <= 1.01,
                  mouseInk: true,
                  onTransformGestureChanged: (active) =>
                      setState(() => _touchTransforming = active),
                  transform: _transform,
                  viewportKey: _viewportKey,
                  child: ReaderPageWindow(
                    documentKey: current.target.key,
                    pageNumber: _session.page,
                    pageCount: current.pageCount,
                    aspectFor: current.aspectFor,
                    direction: _direction,
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
                        _visiblePage = visible;
                        _visibleDocument = current;
                      });
                      _session.rememberPresented(visible, current.pageCount);
                    },
                    readyPageBuilder: (number, active, ready, failed) {
                      final surfacePage = PageKey(
                        entryId: current.target.entryId,
                        revisionId: current.target.revisionId,
                        pageNumber: number,
                      );
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (current.pdf != null)
                            SharpPdfPage(
                              page: current.pdf!.pages[number - 1],
                              active: active,
                              transform: _transform,
                              viewportKey: _viewportKey,
                              onRendered: () {
                                ready();
                                _onRendered(current, number);
                              },
                              onError: failed,
                            )
                          else
                            SharpFileImage(
                              path:
                                  current.renderPath ?? current.target.filePath,
                              transform: _transform,
                              onRendered: ready,
                              onError: failed,
                            ),
                          AnnotationCanvas(
                            workspace: workspace,
                            page: surfacePage,
                            enabled: active && !_session.sourceChanged,
                            style: _style,
                            eraser: _eraser,
                            eraserRadiusFraction: _eraserRadius,
                            suspended: _touchTransforming,
                            onWritingChanged: _writingChanged,
                          ),
                        ],
                      );
                    },
                  ),
                ),
        ),
      ),
    );
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
            ChoiceChip(
              label: const Text('画笔'),
              avatar: const Icon(Icons.edit, size: 17),
              selected: !_eraser && !_highlight,
              onSelected: (_) => setState(() {
                _eraser = false;
                _highlight = false;
              }),
            ),
            ChoiceChip(
              label: const Text('荧光笔'),
              avatar: const Icon(Icons.highlight, size: 17),
              selected: !_eraser && _highlight,
              onSelected: (_) => setState(() {
                _eraser = false;
                _highlight = true;
              }),
            ),
            ChoiceChip(
              label: const Text('橡皮'),
              avatar: const Icon(Icons.auto_fix_normal, size: 17),
              selected: _eraser,
              onSelected: (_) => setState(() => _eraser = true),
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
                  onTap: () => setState(() => _color = color),
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
                            color: _color == color
                                ? Colors.white
                                : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: _color == color
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
            _widthControl(),
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

  Widget _widthControl() => Builder(
    builder: (buttonContext) => IconButton(
      tooltip: _eraser ? '橡皮半径' : '笔宽',
      icon: SizedBox(
        width: 28,
        height: 28,
        child: Center(
          child: _eraser
              ? Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xff334f66),
                      width: 1.5,
                    ),
                  ),
                )
              : Container(
                  width: 26,
                  height: (_width * 810).clamp(1.0, 12.0),
                  decoration: BoxDecoration(
                    color: Color(_color),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
        ),
      ),
      onPressed: () {
        final box = buttonContext.findRenderObject()! as RenderBox;
        final overlay =
            Overlay.of(context).context.findRenderObject()! as RenderBox;
        final rect =
            box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
        setState(() => _widthMenuOpen = true);
        unawaited(
          showMenu<void>(
            context: context,
            color: const Color(0xfffaf9f5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
            items: [
              PopupMenuItem<void>(
                enabled: false,
                padding: const EdgeInsets.all(12),
                child: StatefulBuilder(
                  builder: (context, refresh) {
                    final value = _eraser ? _eraserRadius : _width;
                    return SizedBox(
                      width: 220,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _eraser
                                ? '橡皮半径 ${(value * 810).round()}'
                                : '笔宽 ${(value * 810).toStringAsFixed(1)}',
                            style: const TextStyle(color: Color(0xff222222)),
                          ),
                          Slider(
                            value: value,
                            min: _eraser ? .006 : .001,
                            max: _eraser ? .05 : .012,
                            onChanged: (v) {
                              setState(() {
                                if (_eraser) {
                                  _eraserRadius = v;
                                } else {
                                  _width = v;
                                }
                              });
                              refresh(() {});
                            },
                          ),
                          Container(
                            height: _eraser
                                ? value * 810 * 2
                                : (value * 810).clamp(1.0, 12.0),
                            width: _eraser ? value * 810 * 2 : 160,
                            decoration: BoxDecoration(
                              color: _eraser
                                  ? const Color(0x22334f66)
                                  : Color(_color),
                              borderRadius: BorderRadius.circular(40),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ).whenComplete(() {
            if (mounted) setState(() => _widthMenuOpen = false);
          }),
        );
      },
    ),
  );

  void _navigate(NavigationDirection direction) {
    if (_widthMenuOpen) {
      Navigator.of(context).pop();
      _widthMenuOpen = false;
    }
    final step = direction == NavigationDirection.forward ? 1 : -1;
    _direction = step;
    if (_writing) {
      if (!_deferredTurns.add(direction)) {
        setState(() => _navigationWarning = '翻页操作过密，已保留先前请求；请稍候再翻。');
      }
      return;
    }
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

  Widget _footer() => Material(
    color: const Color(0xfffaf9f5),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: '上一页 · Page Up',
            onPressed: _session.current == null
                ? null
                : () => _navigate(NavigationDirection.backward),
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            '${_visiblePage?.pageNumber ?? 1} / ${_visibleDocument?.pageCount ?? 0}',
            key: const ValueKey('page-indicator'),
          ),
          IconButton(
            tooltip: '下一页 · Page Down',
            onPressed: _session.current == null
                ? null
                : () => _navigate(NavigationDirection.forward),
            icon: const Icon(Icons.chevron_right),
          ),
          if (widget.workspace.unsavedCount > 0)
            const Text(
              '未保存',
              style: TextStyle(color: Colors.red, fontSize: 12),
            ),
          const SizedBox(width: 16),
          IconButton(
            tooltip: '缩小',
            onPressed: () => _zoom(1 / 1.25),
            icon: const Icon(Icons.remove, size: 20),
          ),
          TextButton(
            onPressed: () => _transform.value = Matrix4.identity(),
            child: Text('${(_scale * 100).round()}%'),
          ),
          IconButton(
            tooltip: '放大',
            onPressed: () => _zoom(1.25),
            icon: const Icon(Icons.add, size: 20),
          ),
        ],
      ),
    ),
  );

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
