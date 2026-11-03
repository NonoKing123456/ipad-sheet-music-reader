import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:reader_state/reader_state.dart';

import 'annotation_text_layer.dart';
import 'reader_text_editing.dart';
import 'reader_input.dart';
import 'reader_page_seek_bar.dart';
import 'reader_stage.dart';
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
import '../theme/app_theme.dart';
import '../theme/device_layout.dart';
import '../sharing/score_share.dart';

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
  bool get _isCompact => DeviceLayoutScope.isCompact(context);
  late final ReaderSession _session;
  final TransformationController _transform = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _seekRegionKey = GlobalKey();
  final GlobalKey _textSelectionKey = GlobalKey();
  final GlobalKey _textToolsKey = GlobalKey();
  final _textControls = ReaderTextEditorController();
  double _reportedFontSize = 20 / 1024;
  bool _textDraftActive = false;
  bool _writing = false;
  late final PaperColorSampler _colorSampler =
      widget.colorSampler ?? PaperColorSampler();
  bool _picking = false, _sampling = false;
  bool _editing = false;
  bool _initialLoading = true;
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
  bool _usingSample = false;
  final _quickPageController = TextEditingController();
  final _quickPageMenu = MenuController();
  final _toolsScrollController = ScrollController();
  Future<void> _annotationHistoryTail = Future<void>.value();
  int _pickEpoch = 0;
  String? _pickMessage;
  EdgeInsets _panInsets = EdgeInsets.zero;
  ReaderTool? _tool;
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
  // The spread remains one reading position; undo and text selection follow
  // the paper that actually accepted the most recent annotation interaction.
  PageKey? _annotationPage;
  PageKey? get _annotationTarget => _annotationPage ?? _visiblePage;
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
  ReaderSnapshot? _shareSnapshot;

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
    }, blockKeys: () => _desktopMenuOpen || _writing || readerTextEditorActive);
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_annotationHistoryKey);
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

  KeyEventResult _annotationHistoryKey(KeyEvent event) {
    if (event is! KeyDownEvent || !_annotationHistoryAllowed()) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final undo =
        event.logicalKey == LogicalKeyboardKey.keyZ && !keyboard.isShiftPressed;
    final redo =
        event.logicalKey == LogicalKeyboardKey.keyY ||
        (event.logicalKey == LogicalKeyboardKey.keyZ &&
            keyboard.isShiftPressed);
    if (!undo && !redo) return KeyEventResult.ignored;
    final page = _annotationTarget ?? _session.pageKey;
    if (page == null) return KeyEventResult.handled;
    _queueAnnotationHistory(page, undo: undo);
    return KeyEventResult.handled;
  }

  bool _annotationHistoryAllowed() {
    if (!mounted ||
        readerTextEditorActive ||
        _textControls.saving ||
        _writing ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        _desktopMenuOpen ||
        _quickPageMenu.isOpen) {
      return false;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    return focus?.widget is! EditableText &&
        focus?.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  void _queueAnnotationHistory(PageKey page, {required bool undo}) {
    final operation = _annotationHistoryTail.then((_) async {
      await widget.workspace.waitForAnnotationWrites();
      if (!mounted || !_annotationHistoryAllowed()) return;

      final workspace = widget.workspace;
      final hasUncommittedOnPage =
          workspace.pending.any(
            (stroke) => stroke.page == page && !stroke.saving,
          ) ||
          workspace.pendingPaths.any(
            (edit) => edit.page == page && !edit.saving,
          ) ||
          workspace.pendingText.any(
            (edit) => edit.page == page && !edit.saving,
          );
      if (hasUncommittedOnPage) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('批注尚未保存，请先重试保存。')));
        return;
      }

      final store = workspace.store;
      if (undo ? store.canUndo(page) : store.canRedo(page)) {
        await workspace.edit(
          (store) => undo ? store.undo(page) : store.redo(page),
        );
      }
    });
    _annotationHistoryTail = operation.catchError((
      Object error,
      StackTrace stack,
    ) {
      debugPrint('READER annotation_history_failed: $error\n$stack');
    });
  }

  Future<void> _openInitial() async {
    try {
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
    } finally {
      if (mounted) setState(() => _initialLoading = false);
    }
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
      if (!_followingContinuous && !_isCompact) _continuousNavigation++;
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
      if (_isCompact || _effectiveDesktopMode == ReaderViewMode.continuous) {
        _transform.value = Matrix4.identity();
      }
    }
    setState(() {});
    if (_terminalVisiblePage != null) {
      unawaited(_prewarmNext());
    }
  }

  void _textControlsChanged() {
    if (mounted &&
        (_textDraftActive != _textControls.editing ||
            (_textTool && _color != _textControls.argb) ||
            (_reportedFontSize - _textControls.fontSizeFraction).abs() >
                .00001)) {
      setState(() {
        _textDraftActive = _textControls.editing;
        _reportedFontSize = _textControls.fontSizeFraction;
        if (_textTool) {
          _color = _textControls.argb;
          _usingSample = false;
        }
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_annotationHistoryKey);
    _quickPageController.dispose();
    _toolsScrollController.dispose();
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

  bool _blockLeavingWhileWriting() {
    if (!_writing || !mounted) return false;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('笔迹正在输入，请抬笔后再离开。')));
    return true;
  }

  Future<bool> _leaveSafely() async {
    if (!mounted || _blockLeavingWhileWriting()) return false;
    if (!await _textControls.finish() ||
        !mounted ||
        _blockLeavingWhileWriting()) {
      return false;
    }
    if (widget.allowAnnotations && !await _confirmLeaving()) return false;
    if (!mounted || _blockLeavingWhileWriting()) return false;
    await widget.workspace.flushPositions();
    return mounted && !_blockLeavingWhileWriting();
  }

  Future<bool> _prepareShare() async {
    _shareSnapshot = null;
    if (_writing || !await _textControls.finish() || !mounted) return false;
    if (widget.workspace.savingAnnotations ||
        widget.workspace.unsavedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.workspace.savingAnnotations
                ? '批注正在保存，请稍后分享。'
                : '批注尚未保存，请先重试保存。',
          ),
        ),
      );
      return false;
    }
    _shareSnapshot = widget.workspace.store.snapshot;
    return true;
  }

  List<PageAnnotation> _shareAnnotations(ScoreTarget target, int pageNumber) =>
      List.unmodifiable(
        (_shareSnapshot ?? widget.workspace.store.snapshot).annotationsFor(
          PageKey(
            entryId: target.entryId,
            revisionId: target.revisionId,
            pageNumber: pageNumber,
          ),
        ),
      );

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
    setState(() {
      _cancelPick();
      _textTool = false;
      _tool = _tool == tool ? null : tool;
      if (tool == ReaderTool.eraser) {
        _usingSample = false;
      } else if (_lastSample != null && _color == _lastSample) {
        _usingSample = true;
      }
    });
  }

  Future<void> _toggleTextTool() async {
    if (!await _textControls.finish() || !mounted) return;
    setState(() {
      _cancelPick();
      if (!_textTool) _textControls.argb = _color;
      _textTool = !_textTool;
      _tool = null;
    });
  }

  Future<void> _sampleAction() async {
    if (_writing || _visiblePage == null || _visiblePage != _session.pageKey) {
      return;
    }
    _togglePicking();
  }

  void _useSampleColor() {
    final sample = _lastSample;
    if (_writing || sample == null || _visiblePage != _session.pageKey) return;
    setState(() {
      _cancelPick();
      _color = sample;
      _usingSample = true;
    });
    if (_textTool) _textControls.changeColor(sample);
  }

  Future<bool> _setEditing(bool editing) async {
    if (!editing && (!await _textControls.finish() || !mounted)) return false;
    editing = editing && widget.allowAnnotations;
    setState(() {
      _editing = editing;
      _annotationPage = editing ? _visiblePage : null;
      if (!editing) {
        _textTool = false;
        _tool = null;
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

  void _refreshReaderLayout() {
    if (mounted) setState(() {});
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
    if (!_picking || _sampling || page != _annotationTarget) return;
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
          page != _annotationTarget) {
        return;
      }
      if (color == null) {
        setState(() => _pickMessage = '未能读取该处底色，请点在纸张内或重试。');
      } else {
        setState(() {
          _color = color.toARGB32() | 0xff000000;
          _lastSample = _color;
          _usingSample = true;
          _picking = false;
        });
        if (_textTool) _textControls.changeColor(_color);
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
    if (!_isCompact) return _desktop(current, page, title);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: readerSurroundColor(context),
      body: ReaderStage(
        controller: _stageControls,
        hasReadablePage: _visiblePage != null,
        statusLabel: workspace.unsavedCount > 0
            ? '${workspace.unsavedCount} 项未保存'
            : '阅读状态',
        onToolsVisibilityChanged: _setEditing,
        onToolsLayoutSettled: _refreshReaderLayout,
        beforeHideTools: _textControls.finish,
        onObstructionChanged: (insets) => setState(() => _panInsets = insets),
        onPrevious: () => _navigate(NavigationDirection.backward),
        onNext: () => _navigate(NavigationDirection.forward),
        onViewportChanged: _resetViewport,
        top: Material(
          color: Theme.of(context).colorScheme.surface,
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
                  const ThemeAction(),
                  if (current != null)
                    ShareAction(
                      filePath: current.target.filePath,
                      fileName: p.basename(title),
                      validate: current.target.validateBeforeRead,
                      beforeShare: _prepareShare,
                      annotationsFor: (number) =>
                          _shareAnnotations(current.target, number),
                    ),
                  if (_editing && !_textDraftActive)
                    IconButton(
                      tooltip: '完成批注',
                      onPressed: _writing ? null : _stageControls.hideTools,
                      icon: const Icon(Icons.check),
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
              color: Theme.of(context).colorScheme.tertiaryContainer,
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
        contentBuilder: (toggleTools) => current == null || page == null
            ? Center(
                child: _initialLoading || _session.loading
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
                allowPointerPageTurns:
                    !_picking && !_textTool && _tool == null && _scale <= 1.01,
                panInsets: _panInsets,
                pageAspect:
                    _visibleDocument?.aspectFor(
                      _visiblePage?.pageNumber ?? 1,
                    ) ??
                    current.aspectFor(_session.page),
                mouseInk: _editing && _tool != null,
                touchInk: _editing && _tool != null,
                editing: _editing,
                gestureGeneration: _inputGeneration,
                onTransformGestureChanged: (active) =>
                    setState(() => _touchTransforming = active),
                transform: _transform,
                viewportKey: _viewportKey,
                touchControlKey: _seekRegionKey,
                textTool: _textTool,
                textSelectionKey: _textSelectionKey,
                textControls: _picking ? null : _textControls,
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
    );
  }

  ReaderViewMode get _effectiveDesktopMode =>
      _editing && _desktopMode == ReaderViewMode.continuous
      ? ReaderViewMode.single
      : _desktopMode;
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

  Future<void> _annotationAction() async {
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
    final selected = visible.pageNumber;
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
    if (_writing || !_editing || !await _textControls.finish() || !mounted) {
      return;
    }
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
        color: Theme.of(context).colorScheme.tertiaryContainer,
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
      backgroundColor: readerSurroundColor(context),
      body: ReaderStage(
        top: const SizedBox.shrink(),
        bottom: const SizedBox.shrink(),
        hasReadablePage: _visiblePage != null,
        onViewportChanged: _resetViewport,
        onPrevious: () => _navigate(NavigationDirection.backward),
        onNext: () => _navigate(NavigationDirection.forward),
        blockArrowKeys: _desktopMenuOpen || _quickPageMenu.isOpen,
        contentBuilder: (_) => DesktopReaderShell(
          actions: [
            const ThemeAction(),
            if (document != null)
              ShareAction(
                filePath: document.target.filePath,
                fileName: p.basename(title),
                validate: document.target.validateBeforeRead,
                beforeShare: _prepareShare,
                annotationsFor: (number) =>
                    _shareAnnotations(document.target, number),
              ),
          ],
          title: p.basename(title),
          pageLabel: pageLabel,
          mode: _effectiveDesktopMode,
          arrangement: grouping.arrangement,
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
          beforeHideTools: () => _setEditing(false),
          editing: _editing,
          writing: _writing,
          textEditing: _textDraftActive,
          annotationTools: page == null
              ? null
              : IgnorePointer(
                  ignoring: _visiblePage != page,
                  child: _tools(_annotationPage ?? _visiblePage ?? page),
                ),
          bottom: _footer(),
          notices: _desktopNotices(),
          statusLabel: widget.workspace.unsavedCount > 0
              ? '${widget.workspace.unsavedCount} 项未保存'
              : '阅读状态',
          loading:
              (_initialLoading || _session.loading) && _visiblePage != null,
          contentBuilder: (toggleBar) {
            if (current == null || page == null) {
              return Center(
                child: _initialLoading || _session.loading
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
              onCenterTap: _tool != null || _textTool || _picking
                  ? null
                  : toggleBar,
              allowPointerPageTurns:
                  _tool == null && !_textTool && !_picking && _scale <= 1.01,
              pageAspect: aspect(
                groups
                    .forPage(
                      _visiblePage?.document == current.target.key
                          ? _visiblePage!.pageNumber
                          : _session.page,
                    )
                    .index,
              ),
              mouseInk: _editing && _tool != null,
              touchInk: _editing && _tool != null,
              mouseWheel: true,
              editing: _editing,
              gestureGeneration: _inputGeneration,
              transform: _transform,
              viewportKey: _viewportKey,
              touchControlKey: _seekRegionKey,
              textTool: _textTool,
              textSelectionKey: _textSelectionKey,
              textControls: _picking ? null : _textControls,
              ignorePointerGestures: _desktopMenuOpen || _quickPageMenu.isOpen,
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
        _annotationPage = _editing ? visible : null;
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
        (_isCompact || _effectiveDesktopMode != ReaderViewMode.continuous)) {
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
    final editableSpread =
        !_isCompact &&
        _effectiveDesktopMode == ReaderViewMode.spread &&
        identical(document, _visibleDocument) &&
        _visiblePage != null &&
        _session.current == document &&
        ReaderSpreads(
          pageCount: document.pageCount,
          doublePage: true,
          arrangement: _arrangementFor(document.target.entryId),
        ).forPage(_visiblePage!.pageNumber).contains(number) &&
        ReaderSpreads(
          pageCount: document.pageCount,
          doublePage: true,
          arrangement: _arrangementFor(document.target.entryId),
        ).forPage(_session.page).contains(number);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (document.pdf != null)
          SharpPdfPage(
            page: document.pdf!.pages[number - 1],
            active: active,
            allowDetail:
                _isCompact ||
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
            selectionKey: surfacePage == (_annotationPage ?? _visiblePage)
                ? _textSelectionKey
                : null,
            mouseControlKey: _seekRegionKey,
            workspace: widget.workspace,
            page: surfacePage,
            enabled:
                active &&
                _editing &&
                (_tool != null || _textTool) &&
                (_isCompact ||
                    editableSpread ||
                    (_editing &&
                        surfacePage == _visiblePage &&
                        surfacePage == _session.pageKey)) &&
                !_session.sourceChanged &&
                (!_textTool || editableSpread || surfacePage == _visiblePage),
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
            suspended: _touchTransforming || _picking,
            clipToPage: editableSpread,
            transferTextOnTap: editableSpread,
            onInteractionStart: () {
              if (editableSpread && _annotationPage != surfacePage) {
                setState(() => _annotationPage = surfacePage);
              }
            },
            onWritingChanged: _writingChanged,
          ),
        if (_picking && surfacePage == _annotationTarget)
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
    final last = !_isCompact && _effectiveDesktopMode == ReaderViewMode.spread
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
    color: Theme.of(context).colorScheme.tertiaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
    child: Text(message, style: const TextStyle(fontSize: 12)),
  );

  Widget _tools(PageKey page) {
    final activeTool = _tool ?? ReaderTool.pen;
    final size = _sizes[activeTool]!;
    const minTextSize = 8 / 1024;
    const maxTextSize = 96 / 1024;
    final currentSize = _textTool ? _textControls.fontSizeFraction : size;
    final minSize = _textTool ? minTextSize : activeTool.minSize;
    final maxSize = _textTool ? maxTextSize : activeTool.maxSize;
    final sizeLabel = _textTool ? '字号' : '粗细';
    if (!DeviceLayoutScope.isCompact(context)) {
      return _desktopAnnotationTools(
        page: page,
        activeTool: activeTool,
        currentSize: currentSize,
        minSize: minSize,
        maxSize: maxSize,
        sizeLabel: sizeLabel,
        size: size,
      );
    }
    return Align(
      alignment: Alignment.center,
      child: Container(
        key: _textToolsKey,
        width: double.infinity,
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(
              height: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      children: [
                        for (final tool in ReaderTool.values)
                          ReaderToolButton(
                            key: ValueKey(tool),
                            tool: tool,
                            selected: !_picking && !_textTool && _tool == tool,
                            value: _sizes[tool]!,
                            onSelect: () => _selectTool(tool),
                          ),
                        SizedBox(
                          width: 72,
                          height: 44,
                          child: Tooltip(
                            message: '文字批注',
                            child: TextButton.icon(
                              onPressed: _toggleTextTool,
                              icon: const Icon(Icons.text_fields, size: 19),
                              label: const Text('文字'),
                              style: TextButton.styleFrom(
                                fixedSize: const Size(72, 44),
                                minimumSize: const Size(72, 44),
                                maximumSize: const Size(72, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: _textTool
                                    ? Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer
                                    : Colors.transparent,
                                foregroundColor: _textTool
                                    ? Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer
                                    : Theme.of(context).colorScheme.onSurface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '撤销',
                          onPressed:
                              widget.workspace.store.canUndo(page) ||
                                  widget.workspace.savingAnnotations
                              ? () => _queueAnnotationHistory(page, undo: true)
                              : null,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          tooltip: '重做',
                          onPressed:
                              widget.workspace.store.canRedo(page) ||
                                  widget.workspace.savingAnnotations
                              ? () => _queueAnnotationHistory(page, undo: false)
                              : null,
                          icon: const Icon(Icons.redo),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ReaderAnnotationColors(
                            argb: _color,
                            onChanged: _textControls.saving
                                ? null
                                : (color) {
                                    setState(() {
                                      _cancelPick();
                                      _usingSample = false;
                                      _color = color;
                                    });
                                    if (_textTool) {
                                      _textControls.changeColor(color);
                                    }
                                  },
                          ),
                          const SizedBox(width: 8),
                          ReaderSampleColorButton(
                            sample: _lastSample == null
                                ? null
                                : Color(_lastSample!),
                            picking: _picking,
                            busy: _sampling,
                            usingSample: _usingSample,
                            onPressed:
                                _visiblePage == null ||
                                    _visiblePage != _session.pageKey ||
                                    _writing
                                ? null
                                : _sampleAction,
                          ),
                          ReaderSampleReuseButton(
                            sample: _lastSample == null
                                ? null
                                : Color(_lastSample!),
                            selected: _usingSample,
                            onPressed: _lastSample == null || _writing
                                ? null
                                : _useSampleColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            sizeLabel,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          SizedBox(
                            width: DeviceLayoutScope.isCompact(context)
                                ? 116
                                : 164,
                            child: Slider(
                              key: const ValueKey('annotation-size-slider'),
                              min: minSize,
                              max: maxSize,
                              divisions: 100,
                              value: currentSize.clamp(minSize, maxSize),
                              label: _textTool
                                  ? (currentSize * 1024).toStringAsFixed(0)
                                  : currentSize.toStringAsFixed(1),
                              onChanged: _textTool && _textControls.saving
                                  ? null
                                  : (value) => setState(() {
                                      if (_textTool) {
                                        _textControls.changeFontSizeFraction(
                                          value,
                                        );
                                      } else {
                                        _sizes[activeTool] = value;
                                      }
                                    }),
                              onChangeEnd: _textTool
                                  ? (_) => unawaited(
                                      _textControls.commitFontSize(),
                                    )
                                  : null,
                            ),
                          ),
                          SizedBox(
                            width: 34,
                            child: Text(
                              _textTool
                                  ? (currentSize * 1024).toStringAsFixed(0)
                                  : currentSize.toStringAsFixed(1),
                              textAlign: TextAlign.end,
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            height: 28,
                            child: _textTool
                                ? Center(
                                    child: Text(
                                      'A',
                                      key: const ValueKey(
                                        'annotation-size-preview',
                                      ),
                                      style: TextStyle(
                                        color: Color(_color),
                                        fontSize: (currentSize * 1024).clamp(
                                          8,
                                          28,
                                        ),
                                      ),
                                    ),
                                  )
                                : CustomPaint(
                                    key: const ValueKey(
                                      'annotation-size-preview',
                                    ),
                                    painter: ReaderToolSizePreview(
                                      activeTool,
                                      size,
                                      Color(_color),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopAnnotationTools({
    required PageKey page,
    required ReaderTool activeTool,
    required double currentSize,
    required double minSize,
    required double maxSize,
    required String sizeLabel,
    required double size,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth > 16
            ? constraints.maxWidth - 16
            : constraints.maxWidth;
        final showLabels = availableWidth >= 1000;
        final toolButtonWidth = showLabels ? 84.0 : 36.0;
        final toolButtonHeight = showLabels ? 40.0 : 36.0;
        final paletteCellSize = showLabels ? 36.0 : 32.0;
        final sampleSize = showLabels ? 36.0 : 32.0;
        final iconSize = showLabels ? 38.0 : 34.0;
        final sliderWidth = showLabels ? 112.0 : 82.0;
        const textButtonWidthWide = 72.0;
        final textButtonWidth = showLabels ? textButtonWidthWide : 36.0;
        const gap = 6.0;
        final paletteWidth = paletteCellSize * 7;
        final toolWidth = toolButtonWidth * 3 + textButtonWidth;
        final sliderGroupWidth =
            (showLabels ? 44.0 : 30.0) +
            sliderWidth +
            (showLabels ? 30.0 : 26.0) +
            (showLabels ? 32.0 : 28.0);
        final fixedWidth =
            toolWidth +
            paletteWidth +
            sampleSize * 2 +
            sliderGroupWidth +
            iconSize * 2 +
            gap * 4;
        final contentWidth = fixedWidth < availableWidth
            ? availableWidth
            : fixedWidth;
        final showScrollbar = fixedWidth > availableWidth;

        Widget spacing() => const SizedBox(width: gap);
        Widget denseSwatch(Widget child) => SizedBox(
          width: sampleSize,
          height: sampleSize,
          child: FittedBox(fit: BoxFit.scaleDown, child: child),
        );
        Widget undoRedo({required bool undo}) {
          final enabled =
              (undo
                  ? widget.workspace.store.canUndo(page)
                  : widget.workspace.store.canRedo(page)) ||
              widget.workspace.savingAnnotations;
          void callback() => _queueAnnotationHistory(page, undo: undo);
          return SizedBox(
            width: iconSize,
            height: iconSize,
            child: IconButton(
              tooltip: undo ? '撤销' : '重做',
              onPressed: enabled ? callback : null,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tight(Size(iconSize, iconSize)),
              iconSize: 20,
              icon: Icon(undo ? Icons.undo : Icons.redo),
            ),
          );
        }

        return Align(
          alignment: Alignment.center,
          child: Container(
            key: _textToolsKey,
            width: double.infinity,
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Scrollbar(
                    controller: _toolsScrollController,
                    thumbVisibility: showScrollbar,
                    interactive: true,
                    thickness: 4,
                    radius: const Radius.circular(4),
                    scrollbarOrientation: ScrollbarOrientation.bottom,
                    child: SingleChildScrollView(
                      key: const ValueKey('reader-desktop-annotation-scroll'),
                      controller: _toolsScrollController,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        key: const ValueKey(
                          'reader-desktop-annotation-content',
                        ),
                        width: contentWidth,
                        height: 45,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (final tool in ReaderTool.values)
                              ReaderToolButton(
                                key: ValueKey(tool),
                                tool: tool,
                                selected:
                                    !_picking && !_textTool && _tool == tool,
                                value: _sizes[tool]!,
                                onSelect: () => _selectTool(tool),
                                buttonWidth: toolButtonWidth,
                                buttonHeight: toolButtonHeight,
                                iconOnly: !showLabels,
                              ),
                            SizedBox(
                              width: textButtonWidth,
                              height: toolButtonHeight,
                              child: Tooltip(
                                message: '文字批注',
                                child: showLabels
                                    ? TextButton.icon(
                                        onPressed: _toggleTextTool,
                                        icon: const Icon(
                                          Icons.text_fields,
                                          size: 18,
                                        ),
                                        label: const Text('文字'),
                                        style: _desktopToolButtonStyle(
                                          selected: _textTool,
                                          width: textButtonWidth,
                                          height: toolButtonHeight,
                                        ),
                                      )
                                    : IconButton(
                                        onPressed: _toggleTextTool,
                                        icon: const Icon(Icons.text_fields),
                                        style: IconButton.styleFrom(
                                          fixedSize: Size(
                                            textButtonWidth,
                                            toolButtonHeight,
                                          ),
                                          minimumSize: Size(
                                            textButtonWidth,
                                            toolButtonHeight,
                                          ),
                                          maximumSize: Size(
                                            textButtonWidth,
                                            toolButtonHeight,
                                          ),
                                          padding: EdgeInsets.zero,
                                          backgroundColor: _textTool
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondaryContainer
                                              : Colors.transparent,
                                        ),
                                      ),
                              ),
                            ),
                            spacing(),
                            SizedBox(
                              width: paletteWidth,
                              height: 40,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: ReaderAnnotationColors(
                                  argb: _color,
                                  onChanged: _textControls.saving
                                      ? null
                                      : (color) {
                                          setState(() {
                                            _cancelPick();
                                            _usingSample = false;
                                            _color = color;
                                          });
                                          if (_textTool) {
                                            _textControls.changeColor(color);
                                          }
                                        },
                                ),
                              ),
                            ),
                            denseSwatch(
                              ReaderSampleColorButton(
                                sample: _lastSample == null
                                    ? null
                                    : Color(_lastSample!),
                                picking: _picking,
                                busy: _sampling,
                                usingSample: _usingSample,
                                onPressed:
                                    _visiblePage == null ||
                                        _visiblePage != _session.pageKey ||
                                        _writing
                                    ? null
                                    : _sampleAction,
                              ),
                            ),
                            denseSwatch(
                              ReaderSampleReuseButton(
                                sample: _lastSample == null
                                    ? null
                                    : Color(_lastSample!),
                                selected: _usingSample,
                                onPressed: _lastSample == null || _writing
                                    ? null
                                    : _useSampleColor,
                              ),
                            ),
                            spacing(),
                            SizedBox(
                              width: showLabels ? 44 : 30,
                              child: Tooltip(
                                message: sizeLabel,
                                child: Text(
                                  sizeLabel,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: sliderWidth,
                              child: Slider(
                                key: const ValueKey('annotation-size-slider'),
                                min: minSize,
                                max: maxSize,
                                divisions: 100,
                                value: currentSize.clamp(minSize, maxSize),
                                label: _textTool
                                    ? (currentSize * 1024).toStringAsFixed(0)
                                    : currentSize.toStringAsFixed(1),
                                onChanged: _textTool && _textControls.saving
                                    ? null
                                    : (value) => setState(() {
                                        if (_textTool) {
                                          _textControls.changeFontSizeFraction(
                                            value,
                                          );
                                        } else {
                                          _sizes[activeTool] = value;
                                        }
                                      }),
                                onChangeEnd: _textTool
                                    ? (_) => unawaited(
                                        _textControls.commitFontSize(),
                                      )
                                    : null,
                              ),
                            ),
                            SizedBox(
                              width: showLabels ? 30 : 26,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  _textTool
                                      ? (currentSize * 1024).toStringAsFixed(0)
                                      : currentSize.toStringAsFixed(1),
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: showLabels ? 32 : 28,
                              height: 28,
                              child: _textTool
                                  ? Center(
                                      child: Text(
                                        'A',
                                        key: const ValueKey(
                                          'annotation-size-preview',
                                        ),
                                        style: TextStyle(
                                          color: Color(_color),
                                          fontSize: (currentSize * 1024).clamp(
                                            8,
                                            28,
                                          ),
                                        ),
                                      ),
                                    )
                                  : CustomPaint(
                                      key: const ValueKey(
                                        'annotation-size-preview',
                                      ),
                                      painter: ReaderToolSizePreview(
                                        activeTool,
                                        size,
                                        Color(_color),
                                      ),
                                    ),
                            ),
                            spacing(),
                            undoRedo(undo: true),
                            undoRedo(undo: false),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  ButtonStyle _desktopToolButtonStyle({
    required bool selected,
    required double width,
    required double height,
  }) => TextButton.styleFrom(
    fixedSize: Size(width, height),
    minimumSize: Size(width, height),
    maximumSize: Size(width, height),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    backgroundColor: selected
        ? Theme.of(context).colorScheme.secondaryContainer
        : Colors.transparent,
    foregroundColor: selected
        ? Theme.of(context).colorScheme.onSecondaryContainer
        : Theme.of(context).colorScheme.onSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );

  Future<void> _navigate(NavigationDirection direction) async {
    if (!await _textControls.finish() || !mounted) return;
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
    if (!_isCompact && _effectiveDesktopMode == ReaderViewMode.spread) {
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
    if (!_isCompact && _visiblePage != null) {
      final document = _visibleDocument;
      if (document == null) return const SizedBox.shrink();
      final focus = _visiblePage!.pageNumber;
      final grouping = ReaderSpreads(
        pageCount: document.pageCount,
        doublePage: _effectiveDesktopMode == ReaderViewMode.spread,
        arrangement: _arrangementFor(document.target.entryId),
      ).forPage(focus);
      final label = grouping.first == grouping.last
          ? '$focus / ${document.pageCount}'
          : '${grouping.first}–${grouping.last} / ${document.pageCount}';
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 18),
          child: MenuAnchor(
            controller: _quickPageMenu,
            alignmentOffset: const Offset(0, -8),
            consumeOutsideTap: true,
            onOpen: () {
              if (mounted) setState(() => _desktopMenuOpen = true);
            },
            onClose: () {
              if (mounted) setState(() => _desktopMenuOpen = false);
            },
            menuChildren: [
              SizedBox(
                width: 236,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _quickPageController,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: '跳到页',
                            suffixText: '/ ${document.pageCount}',
                          ),
                          onSubmitted: (_) =>
                              unawaited(_seekQuickPage(document)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '前往',
                        onPressed: () => unawaited(_seekQuickPage(document)),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            builder: (context, controller, child) => TextButton(
              key: const ValueKey('desktop-bottom-page-indicator'),
              onPressed: _writing
                  ? null
                  : () {
                      _quickPageController.text = '$focus';
                      controller.isOpen
                          ? controller.close()
                          : controller.open();
                    },
              child: Text(label),
            ),
          ),
        ),
      );
    }
    if (!_isCompact ||
        _tool != null ||
        _textTool ||
        _picking ||
        _writing ||
        _visiblePage == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(bottom: _pageBottomGap()),
      child: ReaderPageSeekBar(
        hitRegionKey: _seekRegionKey,
        key: ValueKey(_visibleDocument?.target.key),
        currentPage: _visiblePage!.pageNumber,
        pageCount: _visibleDocument?.pageCount ?? 1,
        enabled: _session.current?.target.key == _visibleDocument?.target.key,
        onCancel: _session.cancelSeek,
        onSeek: (number, gesture) async {
          if (_writing ||
              _tool != null ||
              _textTool ||
              _picking ||
              _session.current?.target.key != _visibleDocument?.target.key) {
            return;
          }
          final document = _visibleDocument;
          if (!await _textControls.finish() ||
              !mounted ||
              _visibleDocument != document ||
              _writing ||
              _tool != null ||
              _textTool ||
              _picking) {
            return;
          }
          if (_picking) setState(_cancelPick);
          _direction = number >= _visiblePage!.pageNumber ? 1 : -1;
          _requestedAt =
              widget.presentationClock?.call() ?? readerPresentationNow();
          unawaited(_session.seek(number, gesture: gesture));
        },
      ),
    );
  }

  double _pageBottomGap() {
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final document = _visibleDocument;
    if (viewport == null || !viewport.hasSize || document == null) return 0;
    final aspect = document.aspectFor(_visiblePage?.pageNumber ?? 1);
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(aspect, 1),
      viewport.size,
    ).destination;
    final paper = Alignment.center.inscribe(
      fitted,
      Offset.zero & viewport.size,
    );
    final scale = _transform.value.getMaxScaleOnAxis();
    final bottom = paper.bottom * scale + _transform.value.storage[13];
    return (viewport.size.height - bottom).clamp(0.0, viewport.size.height);
  }

  Future<void> _seekQuickPage(LoadedScore document) async {
    _quickPageMenu.close();
    final target = int.tryParse(_quickPageController.text.trim());
    if (target == null ||
        !await _textControls.finish() ||
        !mounted ||
        !identical(_visibleDocument, document) ||
        _writing) {
      return;
    }
    if (_picking) setState(_cancelPick);
    _direction = target >= (_visiblePage?.pageNumber ?? 1) ? 1 : -1;
    _requestedAt = widget.presentationClock?.call() ?? readerPresentationNow();
    unawaited(_session.seek(target, gesture: Object()));
  }

  void _zoom(double factor) {
    if (!_isCompact && _effectiveDesktopMode == ReaderViewMode.continuous) {
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
