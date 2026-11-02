import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import 'annotation_text_layer.dart';
import 'reader_text_editing.dart';
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
import 'reader_spreads.dart';
import 'desktop_reader.dart';
import 'reader_continuous.dart';
import '../library/desktop_navigation_history.dart';

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
    this.allowAnnotations = true,
    this.onPresented,
    this.initialPageNumber,
    this.onLoaded,
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
  final bool allowAnnotations;
  final ValueChanged<PageKey>? onPresented;
  final int? initialPageNumber;
  final ValueChanged<LoadedScore>? onLoaded;
  @override
  State<LibraryReaderScreen> createState() => _LibraryReaderScreenState();
}

class _LibraryReaderScreenState extends State<LibraryReaderScreen> {
  late final ReaderSession _session;
  final TransformationController _transform = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _seekRegionKey = GlobalKey();
  final GlobalKey _textSelectionKey = GlobalKey();
  final GlobalKey _textToolsKey = GlobalKey();
  final _textControls = ReaderTextEditorController();
  bool _textDraftActive = false;
  bool _tablet = false;
  bool _landscape = false;
  bool _writing = false;
  late final PaperColorSampler _colorSampler =
      widget.colorSampler ?? PaperColorSampler();
  bool _picking = false, _sampling = false;
  bool _editing = false;
  final _stageControls = ReaderStageController();
  DesktopReaderPreferences? _desktopPreferences;
  ReaderViewMode _desktopMode = ReaderViewMode.single;
  FirstPageArrangement _externalArrangement = FirstPageArrangement.paired;
  final _continuous = ReaderContinuousController();
  ReaderScrollAnchor? _continuousRestore;
  PageKey? _continuousAnchorFocus;
  PageKey? _continuousEditStart;
  int _continuousNavigation = 0;
  bool _followingContinuous = false;
  String? _viewPreferenceError;
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
  bool _desktopMenuOpen = false;
  PageKey? _shownPage;
  final Set<PageKey> _renderedPages = {};
  Stopwatch? _pageWatch;
  bool _presented = false;
  PageKey? _historyPosition;
  String? _historyItemId;
  LoadedScore? _notifiedDocument;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null) return;
    DesktopHistoryScope.of(context)?.reader(route, _leaveSafely, () {
      final position = _historyPosition;
      final latest = widget.locate(
        position?.entryId ?? widget.initialTarget.entryId,
      );
      if (latest == null) return null;
      return LibraryReaderScreen(
        workspace: widget.workspace,
        locate: widget.locate,
        initialTarget: latest,
        initialPageNumber: latest.revisionId == position?.revisionId
            ? position!.pageNumber
            : 1,
        setListId: widget.setListId,
        itemId: _historyItemId ?? widget.itemId,
        sourceChanges: widget.sourceChanges,
        loader: widget.loader,
        allowAnnotations: widget.allowAnnotations,
        onPresented: widget.onPresented,
        onLoaded: widget.onLoaded,
      );
    }, blockKeys: () => _desktopMenuOpen || _sampleMenuOpen || _writing || readerTextEditorActive);
  }

  @override
  void initState() {
    super.initState();
    _textControls.addListener(_textControlsChanged);
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
    unawaited(_openInitial());
  }

  Future<void> _openInitial() async {
    if (!isMobileReader) {
      final preferences = await DesktopReaderPreferences.open(
        p.join(
          p.dirname(widget.workspace.store.statePath),
          'desktop-reader-view.json',
        ),
      );
      if (!mounted) return;
      setState(() {
        _desktopPreferences = preferences;
        _desktopMode = preferences.mode;
      });
    }
    if (!mounted) return;
    await _session.open(
      widget.initialTarget,
      itemId: widget.itemId,
      pageNumber: widget.initialPageNumber,
      restore: false,
    );
  }

  void _transformChanged() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (mounted && (_scale - scale).abs() > .01) setState(() => _scale = scale);
  }

  void _changed() {
    if (!mounted) return;
    final document = _session.current;
    if (document != null && !identical(document, _notifiedDocument)) {
      _notifiedDocument = document;
      widget.onLoaded?.call(document);
    }
    if (_shownPage != _session.pageKey) {
      if (!_followingContinuous && !isMobileReader) _continuousNavigation++;
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
      if (isMobileReader ||
          _effectiveDesktopMode == ReaderViewMode.continuous) {
        _transform.value = Matrix4.identity();
      }
    }
    setState(() {});
    if (_terminalVisiblePage != null) {
      unawaited(_prewarmNext());
    }
  }

  void _textControlsChanged() {
    if (mounted && (_textDraftActive != _textControls.editing || (_textTool && _color != _textControls.argb))) {
      setState(() { _textDraftActive = _textControls.editing;
        if (_textTool) { _color = _textControls.argb; _usingSample = false; }
      });
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
    _textControls.dispose();
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
    if (await _leaveSafely() && mounted) Navigator.pop(context);
  }

  Future<bool> _leaveSafely() async {
    if (!mounted || !await _textControls.finish() || (widget.allowAnnotations && !await _confirmLeaving())) {
      return false;
    }
    await widget.workspace.flushPositions();
    return mounted;
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

  Future<void> _selectTool(ReaderTool tool) async {
    if (!await _textControls.finish() || !mounted) return;
    setState(() { _cancelPick(); _textTool = false; _tool = tool; });
  }
  Future<void> _toggleTextTool() async {
    if (!await _textControls.finish() || !mounted) return;
    setState(() { _cancelPick();
      if (!_textTool) _textControls.argb = _color;
      _textTool = !_textTool;
    });
  }


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

  Future<bool> _setEditing(bool editing) async {
    if (!editing && (!await _textControls.finish() || !mounted)) return false;
    editing = editing && widget.allowAnnotations;
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
    return true;
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
    if (!isMobileReader) return _desktop(current, page, title);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: ReaderStage(
        controller: _stageControls,
        hasReadablePage: _visiblePage != null,
        statusLabel: workspace.unsavedCount > 0
            ? '${workspace.unsavedCount} 项未保存'
            : '阅读状态',
        onToolsVisibilityChanged: _setEditing,
        beforeHideTools: _textControls.finish,
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
                  if (_editing && !_textDraftActive)
                    IconButton(
                      tooltip: '完成批注',
                      onPressed: _writing ? null : _stageControls.hideTools,
                      icon: const Icon(Icons.check),
                    ),
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
              if (page != null && widget.allowAnnotations)
                _tools(_visiblePage ?? page),
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
                          onPressed: () {
                            final latest = widget.locate(
                              widget.initialTarget.entryId,
                            );
                            if (latest != null) {
                              unawaited(
                                _session.open(
                                  latest,
                                  itemId: widget.itemId,
                                  restore: false,
                                ),
                              );
                            }
                          },
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
                  textControls: _textControls,
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
                      if (document == current.target.key) {
                        _markPresented(current, number);
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

  ReaderViewMode get _effectiveDesktopMode =>
      _editing ? ReaderViewMode.single : _desktopMode;
  FirstPageArrangement _arrangementFor(String entryId) =>
      widget.allowAnnotations
      ? _desktopPreferences?.arrangementFor(entryId) ??
            FirstPageArrangement.paired
      : _externalArrangement;

  void _savePreference(Future<void>? operation) {
    if (operation == null) return;
    unawaited(
      operation.catchError((Object _) {
        if (mounted) setState(() => _viewPreferenceError = '阅读设置暂未保存。');
      }),
    );
  }

  void _changeView(ReaderViewMode mode) {
    if (_writing || _editing || mode == _desktopMode) return;
    if (_desktopMode == ReaderViewMode.continuous) {
      _continuousRestore = _continuous.anchor;
      _continuousAnchorFocus = _visiblePage;
    } else if (mode == ReaderViewMode.continuous &&
        _session.pageKey != _continuousAnchorFocus) {
      _continuousRestore = null;
    }
    setState(() {
      _desktopMode = mode;
      _direction = 0;
      _inputGeneration++;
      _cancelPick();
      _transform.value = Matrix4.identity();
    });
    _savePreference(_desktopPreferences?.setMode(mode));
  }

  void _changeArrangement(FirstPageArrangement value) {
    if (_writing || _editing) return;
    final id = _session.current?.target.entryId ?? widget.initialTarget.entryId;
    setState(() {
      _externalArrangement = value;
      _direction = 0;
      _inputGeneration++;
      _transform.value = Matrix4.identity();
    });
    if (widget.allowAnnotations) {
      _savePreference(_desktopPreferences?.setArrangement(id, value));
    }
  }

  Future<void> _annotationAction({
    int? pageNumber,
    DocumentKey? expectedDocument,
  }) async {
    if (_writing) return;
    if (_editing) {
      await _finishAnnotation();
      return;
    }
    final document = _visibleDocument, visible = _visiblePage;
    if (!widget.allowAnnotations ||
        document == null ||
        visible == null ||
        _session.sourceChanged) {
      return;
    }
    if (expectedDocument != null && expectedDocument != document.target.key) {
      return;
    }
    var selected = pageNumber ?? visible.pageNumber;
    if (_desktopMode == ReaderViewMode.spread) {
      final spread = ReaderSpreads(
        pageCount: document.pageCount,
        doublePage: true,
        arrangement: _arrangementFor(document.target.entryId),
      ).forPage(selected);
      if (!spread.contains(selected) ||
          (spread.first != spread.last && pageNumber == null)) {
        return;
      }
    }
    if (_desktopMode == ReaderViewMode.continuous) {
      _continuousRestore = _continuous.anchor;
      _continuousEditStart = visible;
      _continuousAnchorFocus = visible;
    }
    if (_session.page != selected) {
      await _session.seek(selected, gesture: Object());
    }
    if (!mounted || _session.current?.target.key != document.target.key) return;
    _inputGeneration++;
    _setEditing(true);
  }

  Future<void> _finishAnnotation() async {
    if (_writing || !_editing || !await _textControls.finish() || !mounted) return;
    if (_desktopMode == ReaderViewMode.continuous &&
        _session.pageKey != _continuousEditStart) {
      _continuousRestore = null;
    }
    _setEditing(false);
  }

  Future<void> _jumpDialog() async {
    if (!await _textControls.finish() || !mounted) return;
    final document = _session.current;
    if (document == null || _writing) return;
    final key = document.target.key;
    var input = '${_visiblePage?.pageNumber ?? _session.page}';
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到页'),
        content: SizedBox(
          width: 160,
          child: TextFormField(
            autofocus: true,
            initialValue: input,
            onChanged: (value) => input = value,
            keyboardType: TextInputType.number,
            onFieldSubmitted: (value) =>
                Navigator.pop(context, int.tryParse(value)),
            decoration: InputDecoration(suffixText: '/ ${document.pageCount}'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(input)),
            child: const Text('前往'),
          ),
        ],
      ),
    );
    if (!mounted || target == null || _session.current?.target.key != key) {
      return;
    }
    await _session.seek(target, gesture: Object());
  }

  void _retryOpen() {
    final latest = widget.locate(widget.initialTarget.entryId);
    if (latest != null) {
      unawaited(_session.open(latest, itemId: widget.itemId, restore: false));
    }
  }

  List<Widget> _desktopNotices() => [
    if (widget.allowAnnotations &&
        widget.workspace.store.storageWarnings.isNotEmpty)
      _notice('已从备份恢复，请检查最近修改。'),
    if (widget.allowAnnotations && widget.workspace.error != null)
      _notice(widget.workspace.error!),
    if (widget.allowAnnotations && widget.workspace.textConflictNotice != null)
      _notice(widget.workspace.textConflictNotice!),
    if (widget.allowAnnotations && widget.workspace.unsavedCount > 0)
      Material(
        color: const Color(0xffffedcf),
        child: ListTile(
          dense: true,
          title: Text('${widget.workspace.unsavedCount} 项批注未保存'),
          trailing: TextButton(
            onPressed: () => unawaited(widget.workspace.retryStrokes()),
            child: const Text('重试保存'),
          ),
        ),
      ),
    if (_session.message != null) _notice(_session.message!),
    if (_navigationWarning != null) _notice(_navigationWarning!),
    if (_pickMessage != null) _notice(_pickMessage!),
    if (_viewPreferenceError != null) _notice(_viewPreferenceError!),
    if (_session.sourceChanged) _notice('源曲谱已变更，当前为旧版。'),
  ];

  Widget _desktop(LoadedScore? current, PageKey? page, String title) {
    final document = _visibleDocument ?? current;
    final focus = _visiblePage?.pageNumber ?? _session.page;
    final grouping = ReaderSpreads(
      pageCount: document?.pageCount ?? 1,
      doublePage: _effectiveDesktopMode == ReaderViewMode.spread,
      arrangement: _arrangementFor(
        document?.target.entryId ?? widget.initialTarget.entryId,
      ),
    );
    final shown = grouping.forPage(focus);
    final pageLabel =
        '${shown.first == shown.last ? focus : '${shown.first}–${shown.last}'} / ${document?.pageCount ?? 1}';
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: ReaderStage(
        top: const SizedBox.shrink(),
        bottom: const SizedBox.shrink(),
        hasReadablePage: _visiblePage != null,
        onViewportChanged: _resetViewport,
        onPrevious: () => _navigate(NavigationDirection.backward),
        onNext: () => _navigate(NavigationDirection.forward),
        allowOverlayPageKeys: _sampleMenuOpen,
        blockArrowKeys: _desktopMenuOpen,
        contentBuilder: (_) => DesktopReaderShell(
          title: p.basename(title),
          pageLabel: pageLabel,
          mode: _effectiveDesktopMode,
          arrangement: grouping.arrangement,
          annotationPages:
              !_editing && _effectiveDesktopMode == ReaderViewMode.spread
              ? shown.pages.toList()
              : const [],
          onAnnotatePage: (number) => _annotationAction(
            pageNumber: number,
            expectedDocument: document?.target.key,
          ),
          onMenuChanged: (open) {
            if (mounted && _desktopMenuOpen != open) {
              setState(() => _desktopMenuOpen = open);
            }
          },
          onMode: _changeView,
          onArrangement: _changeArrangement,
          onPrevious: () => _navigate(NavigationDirection.backward),
          onNext: () => _navigate(NavigationDirection.forward),
          onBack: () => unawaited(_back()),
          onZoom: _zoom,
          onFit: () {
            if (_effectiveDesktopMode == ReaderViewMode.continuous) {
              _continuous.fit();
            } else {
              _transform.value = Matrix4.identity();
            }
          },
          onJump: () => unawaited(_jumpDialog()),
          onAnnotate: widget.allowAnnotations
              ? () => unawaited(_annotationAction())
              : null,
          onFinishEditing: _finishAnnotation,
          editing: _editing,
          writing: _writing,
          textEditing: _textDraftActive,
          annotationTools: page == null
              ? null
              : IgnorePointer(
                  ignoring: _visiblePage != page,
                  child: _tools(_visiblePage ?? page),
                ),
          bottom: _footer(),
          notices: _desktopNotices(),
          statusLabel: widget.workspace.unsavedCount > 0
              ? '${widget.workspace.unsavedCount} 项未保存'
              : '阅读状态',
          loading: _session.loading && _visiblePage != null,
          contentBuilder: (toggleBar) {
            if (current == null || page == null) {
              return Center(
                child: _session.loading
                    ? const CircularProgressIndicator()
                    : FilledButton(
                        onPressed: _retryOpen,
                        child: const Text('重新打开'),
                      ),
              );
            }
            if (_effectiveDesktopMode == ReaderViewMode.continuous) {
              return ReaderContinuousView(
                key: ValueKey(current.target.key),
                documentKey: current.target.key,
                pageCount: current.pageCount,
                aspectFor: current.aspectFor,
                controller: _continuous,
                requestedPage: _session.page,
                navigationToken: _continuousNavigation,
                initialAnchor: _continuousRestore,
                controlKey: _seekRegionKey,
                viewportKey: _viewportKey,
                retainDocument: current.retain,
                releaseDocument: current.release,
                onCenterTap: toggleBar,
                onPrevious: () => _navigate(NavigationDirection.backward),
                onNext: () => _navigate(NavigationDirection.forward),
                pageBuilder: (number, active, ready, failed) =>
                    _surface(current, number, active, ready, failed),
                previewPageBuilder: (number, pixels, ready, failed) => _surface(
                  current,
                  number,
                  false,
                  ready,
                  failed,
                  previewPixels: pixels,
                ),
                onPresented: (number) {
                  if (_effectiveDesktopMode != ReaderViewMode.continuous ||
                      _session.current?.target.key != current.target.key) {
                    return;
                  }
                  _followingContinuous = true;
                  try {
                    _session.followPresentedPage(
                      PageKey(
                        entryId: current.target.entryId,
                        revisionId: current.target.revisionId,
                        pageNumber: number,
                      ),
                    );
                  } finally {
                    _followingContinuous = false;
                  }
                  _markPresented(current, number);
                },
              );
            }
            final groups = ReaderSpreads(
              pageCount: current.pageCount,
              doublePage: _effectiveDesktopMode == ReaderViewMode.spread,
              arrangement: _arrangementFor(current.target.entryId),
            );
            final mode = _effectiveDesktopMode;
            final viewKey = (current.target.key, mode, groups.arrangement);
            double aspect(int index) {
              final group = groups.at(index);
              if (!groups.doublePage) return current.aspectFor(group.first);
              return current.aspectFor(group.first) +
                  current.aspectFor(
                    group.last == group.first ? group.first : group.last,
                  ) +
                  .025;
            }

            ReaderPrewarmPage? warm;
            final next = _terminalVisiblePage == null ? null : _prewarmScore;
            if (next != null) {
              final nextGroups = ReaderSpreads(
                pageCount: next.pageCount,
                doublePage: groups.doublePage,
                arrangement: _arrangementFor(next.target.entryId),
              );
              final first = nextGroups.at(1);
              warm = ReaderPrewarmPage(
                documentKey: (next.target.key, mode, nextGroups.arrangement),
                aspect: !nextGroups.doublePage
                    ? next.aspectFor(first.first)
                    : next.aspectFor(first.first) +
                          next.aspectFor(first.last) +
                          .025,
                retainDocument: next.retain,
                releaseDocument: next.release,
                pageBuilder: (_, active, ready, failed) => ReaderSpreadSurface(
                  spread: first,
                  aspectFor: next.aspectFor,
                  onReady: ready,
                  onError: failed,
                  pageBuilder: (number, pageReady, pageFailed) =>
                      _surface(next, number, active, pageReady, pageFailed),
                ),
              );
            }

            return ReaderInput(
              onPrevious: () => _navigate(NavigationDirection.backward),
              onNext: () => _navigate(NavigationDirection.forward),
              onCenterTap: _editing || _picking ? null : toggleBar,
              allowPointerPageTurns: !_editing && !_picking && _scale <= 1.01,
              pageAspect: aspect(
                groups
                    .forPage(
                      _visiblePage?.document == current.target.key
                          ? _visiblePage!.pageNumber
                          : _session.page,
                    )
                    .index,
              ),
              mouseInk: _editing,
              mouseWheel: true,
              editing: _editing,
              gestureGeneration: _inputGeneration,
              transform: _transform,
              viewportKey: _viewportKey,
              touchControlKey: _seekRegionKey,
              textTool: _textTool,
              textSelectionKey: _textSelectionKey,
              textControls: _textControls,
              onTransformGestureChanged: (active) =>
                  setState(() => _touchTransforming = active),
              child: ReaderPageWindow(
                documentKey: viewKey,
                pageNumber: groups.forPage(_session.page).index,
                pageCount: groups.count,
                aspectFor: aspect,
                direction: _direction,
                requestedAt: _requestedAt,
                presentationClock: widget.presentationClock,
                forwardWindowOnly: true,
                paperWidthTransition: true,
                shortPageTransition: true,
                onWillPresent: () => _transform.value = Matrix4.identity(),
                prewarm: warm,
                surfaceBackground: Colors.transparent,
                retainDocument: current.retain,
                releaseDocument: current.release,
                holdPresentation: _writing,
                onSelected: (key, index) {
                  if (key != viewKey ||
                      _effectiveDesktopMode != mode ||
                      _session.current?.target.key != current.target.key ||
                      _arrangementFor(current.target.entryId) !=
                          groups.arrangement) {
                    return;
                  }
                  final group = groups.at(index);
                  _selectVisible(
                    current,
                    group.contains(_session.page) ? _session.page : group.first,
                  );
                },
                onPresented: (key, index) {
                  if (key != viewKey ||
                      _effectiveDesktopMode != mode ||
                      _session.current?.target.key != current.target.key ||
                      _arrangementFor(current.target.entryId) !=
                          groups.arrangement) {
                    return;
                  }
                  final group = groups.at(index);
                  _markPresented(
                    current,
                    group.contains(_session.page) ? _session.page : group.first,
                  );
                },
                readyPageBuilder: (index, active, ready, failed) =>
                    ReaderSpreadSurface(
                      spread: groups.at(index),
                      aspectFor: current.aspectFor,
                      onReady: ready,
                      onError: failed,
                      pageBuilder: (number, pageReady, pageFailed) => _surface(
                        current,
                        number,
                        active,
                        pageReady,
                        pageFailed,
                      ),
                    ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _selectVisible(LoadedScore document, int number) {
    if (!mounted || _session.current?.target.key != document.target.key) return;
    final visible = PageKey(
      entryId: document.target.entryId,
      revisionId: document.target.revisionId,
      pageNumber: number,
    );
    final changed = _visiblePage != visible || _visibleDocument != document;
    if (changed) {
      setState(() {
        _cancelPick();
        _visiblePage = visible;
        _visibleDocument = document;
      });
    }
  }

  void _markPresented(LoadedScore document, int number) {
    if (!mounted || _session.current?.target.key != document.target.key) return;
    _selectVisible(document, number);
    final visible = _visiblePage!;
    final newlyPresented =
        _historyPosition != visible ||
        _historyItemId != _session.position?.setListItemId;
    if (newlyPresented && widget.allowAnnotations) {
      _session.rememberPresented(visible, document.pageCount);
    }
    widget.onPresented?.call(visible);
    _historyPosition = visible;
    _historyItemId = _session.position?.setListItemId;
    if (visible == _shownPage && !_presented) {
      _presented = true;
      debugPrint(
        'READER page_presented page=$number elapsed_ms=${_pageWatch?.elapsedMilliseconds ?? 0}',
      );
    }
    if (_terminalVisiblePage != null &&
        (isMobileReader ||
            _effectiveDesktopMode != ReaderViewMode.continuous)) {
      unawaited(_prewarmNext());
    }
  }

  Widget _surface(
    LoadedScore document,
    int number,
    bool active,
    VoidCallback ready,
    ValueChanged<String?> failed, {
    int? previewPixels,
  }) {
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
            allowDetail:
                isMobileReader ||
                _effectiveDesktopMode == ReaderViewMode.continuous ||
                (identical(document, _visibleDocument) &&
                    (_effectiveDesktopMode == ReaderViewMode.spread
                        ? ReaderSpreads(
                            pageCount: document.pageCount,
                            doublePage: true,
                            arrangement: _arrangementFor(
                              document.target.entryId,
                            ),
                          ).forPage(_visiblePage!.pageNumber).contains(number)
                        : number == _visiblePage?.pageNumber)),
            previewPixels: previewPixels,
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
        if (widget.allowAnnotations)
          AnnotationTextLayer(
            transform: _transform,
            textControls: _textControls,
            topControlsKey: _textToolsKey,
            viewportKey: _viewportKey,
            selectionKey: surfacePage == _visiblePage
                ? _textSelectionKey
                : null,
            mouseControlKey: _seekRegionKey,
            workspace: widget.workspace,
            page: surfacePage,
            enabled:
                active &&
                (isMobileReader ||
                    (_editing &&
                        surfacePage == _visiblePage &&
                        surfacePage == _session.pageKey)) &&
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

  int? get _terminalVisiblePage {
    final document = _visibleDocument, visible = _visiblePage;
    if (document == null ||
        visible == null ||
        _historyPosition != visible ||
        _historyItemId != _session.position?.setListItemId ||
        !identical(document, _session.current) ||
        _session.pageKey != visible) {
      return null;
    }
    final last =
        !isMobileReader && _effectiveDesktopMode == ReaderViewMode.spread
        ? ReaderSpreads(
            pageCount: document.pageCount,
            doublePage: true,
            arrangement: _arrangementFor(document.target.entryId),
          ).forPage(visible.pageNumber).last
        : visible.pageNumber;
    return last == document.pageCount ? last : null;
  }

  Future<void> _prewarmNext() async {
    final last = _terminalVisiblePage;
    if (last == null) return;
    final next = _session.nextPrewarmTargetFor(lastVisiblePage: last);
    final anchor = next == null ? null : (_visiblePage!, next.key);
    if (_prewarmAnchor == anchor) return;
    _prewarmAnchor = anchor;
    _prewarmScore = null;
    _session.cancelPrewarm();
    final epoch = ++_prewarmEpoch;
    if (anchor == null) return;
    final loaded = await _session.prewarmNext(lastVisiblePage: last);
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
      key: _textToolsKey,
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
              if (_textTool)
                IconButton(tooltip: tool.label, icon: Icon(tool.icon), onPressed: () => _selectTool(tool))
              else ReaderToolButton(
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
              onPressed: _toggleTextTool,
            ),
            if (_textTool) ReaderTextFormatControls(controller: _textControls),
            if (!_textTool) ReaderSampleColorButton(
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
            if (!_textTool) ReaderAnnotationColors(argb:_color,onChanged:(color) => setState(() {
              _cancelPick(); _usingSample = false; _color = color;
            })),
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

  Future<void> _navigate(NavigationDirection direction) async {
    if (!await _textControls.finish() || !mounted) return;
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
    if (!isMobileReader && !_editing && _desktopMode == ReaderViewMode.spread) {
      final arrangements =
          _desktopPreferences?.arrangements ??
          const <String, FirstPageArrangement>{};
      final external = _externalArrangement;
      unawaited(
        _session.turnSpread(
          direction,
          (id) => widget.allowAnnotations
              ? arrangements[id] ?? FirstPageArrangement.paired
              : external,
        ),
      );
    } else {
      unawaited(_session.turn(direction));
    }
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
    final continuous =
        !isMobileReader && _effectiveDesktopMode == ReaderViewMode.continuous;
    if ((!_editing && !continuous) || _writing || _visiblePage == null) {
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
            (!_editing && !continuous) ||
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
    if (!isMobileReader && _effectiveDesktopMode == ReaderViewMode.continuous) {
      _continuous.zoom(factor);
      return;
    }
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
