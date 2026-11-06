import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
import 'reader_view_capabilities.dart';
import '../library/desktop_navigation_history.dart';
import '../theme/app_theme.dart';
import '../theme/device_layout.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'add_to_set_list_dialog.dart';
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
    this.headerAction,
    this.beforeLeave,
    this.restoreScreen,
    this.initiallyShowToolbar = false,
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
  final Widget? headerAction;
  final Future<bool> Function()? beforeLeave;
  final Widget? Function(int pageNumber)? restoreScreen;
  final bool initiallyShowToolbar;
  @override
  State<LibraryReaderScreen> createState() => _LibraryReaderScreenState();
}

class _LibraryReaderScreenState extends State<LibraryReaderScreen> {
  bool get _isCompact => DeviceLayoutScope.isCompact(context);
  ReaderViewCapabilities get _capabilities =>
      ReaderViewCapabilities.of(context);
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
  bool _sharing = false;
  bool _dotsSuppressed = false;
  final _penPointers = <int>{};
  Timer? _dotRestore;
  Size? _paperViewportSize;
  PageKey? _paperViewportPage;
  Offset? _preferredViewportAnchor;
  PageKey? _preferredAnchorPage;
  double? _preferredAnchorScale;
  bool _projectingViewport = false;
  late final PaperColorSampler _colorSampler =
      widget.colorSampler ?? PaperColorSampler();
  bool _picking = false, _sampling = false;
  bool _editing = false;
  bool _initialLoading = true;
  final _stageControls = ReaderStageController();
  DesktopReaderPreferences? _viewPreferences;
  ReaderViewMode _viewMode = ReaderViewMode.single;
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
  bool _leaving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_capabilities.supports(_viewMode)) {
      // Rotation changes this reading session only. Keep the user's stored
      // layout/grouping preferences intact and never rewind to the first page.
      _viewMode = ReaderViewMode.single;
      _direction = 0;
      _inputGeneration++;
      _cancelPick();
      _transform.value = Matrix4.identity();
      final focus = _annotationPage ?? _visiblePage;
      if (focus != null && focus != _session.pageKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _effectiveViewMode == ReaderViewMode.single &&
              _session.current?.target.key == focus.document) {
            unawaited(_session.seek(focus.pageNumber, gesture: Object()));
          }
        });
      }
    }
    final route = ModalRoute.of(context);
    if (route == null) return;
    DesktopHistoryScope.of(context)?.reader(route, _leaveSafely, () {
      final position = _historyPosition;
      final restored = widget.restoreScreen?.call(
        position?.pageNumber ?? widget.initialPageNumber ?? 1,
      );
      if (restored != null) return restored;
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
        headerAction: widget.headerAction,
        beforeLeave: widget.beforeLeave,
        restoreScreen: widget.restoreScreen,
        initiallyShowToolbar: widget.initiallyShowToolbar,
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
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        widget.beforeLeave != null &&
        !readerTextEditorActive &&
        !_desktopMenuOpen &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      unawaited(_back());
      return KeyEventResult.handled;
    }
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
      // Layout capabilities are inherited; initState starts this operation
      // before those dependencies can be read.
      await Future<void>.value();
      if (mounted) {
        final preferences = await DesktopReaderPreferences.open(
          p.join(
            p.dirname(widget.workspace.store.statePath),
            _isCompact ? 'tablet-reader-view.json' : 'desktop-reader-view.json',
          ),
        );
        if (!mounted) return;
        setState(() {
          _viewPreferences = preferences;
          _viewMode = _capabilities.resolve(preferences.mode);
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
    if (!_projectingViewport) {
      _preferredViewportAnchor = null;
      _preferredAnchorPage = null;
      _preferredAnchorScale = null;
    }
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
      if (!_followingContinuous) _continuousNavigation++;
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
      if ((_isCompact && _effectiveViewMode == ReaderViewMode.single) ||
          _effectiveViewMode == ReaderViewMode.continuous) {
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
    _dotRestore?.cancel();
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
    if (_leaving) return false;
    _leaving = true;
    try {
      return await _finishLeaving();
    } finally {
      _leaving = false;
    }
  }

  Future<bool> _finishLeaving() async {
    if (!mounted || _blockLeavingWhileWriting()) return false;
    if (!await _textControls.finish() ||
        !mounted ||
        _blockLeavingWhileWriting()) {
      return false;
    }
    if (widget.allowAnnotations && !await _confirmLeaving()) return false;
    if (!mounted || _blockLeavingWhileWriting()) return false;
    await widget.workspace.flushPositions();
    if (!mounted || _blockLeavingWhileWriting()) return false;
    if (widget.beforeLeave != null && !await widget.beforeLeave!()) {
      return false;
    }
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

  Future<bool> _setEditing(bool editing) async {
    if (!editing && !_editing) return true;
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
        // Chrome changes preserve the current zoom/view. The viewport adapter
        // below maps that same content anchor into the new available area.
        if (_transform.value.getMaxScaleOnAxis() <= 1.000001) {
          _transform.value = Matrix4.identity();
        }
      }
    });
    return true;
  }

  void _resetViewport() {
    setState(() {
      _inputGeneration++;
      _cancelPick();
      _touchTransforming = false;
      if (_transform.value.getMaxScaleOnAxis() <= 1.000001) {
        _transform.value = Matrix4.identity();
      }
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
    final child = _buildReader(context);
    if (widget.beforeLeave == null) return child;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Explicit toolbar/history pops already completed _leaveSafely. A
        // system maybePop arrives here first and takes that same guarded path.
        if (!didPop) unawaited(_back());
      },
      child: child,
    );
  }

  Widget _buildReader(BuildContext context) {
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
      body: _trackPen(
        ReaderStage(
          controller: _stageControls,
          initiallyShowTools: widget.initiallyShowToolbar ? true : null,
          fitAspectFor: _effectiveViewMode == ReaderViewMode.continuous
              ? null
              : _readerFitAspect,
          hasReadablePage: _visiblePage != null,
          statusLabel: workspace.unsavedCount > 0
              ? '${workspace.unsavedCount} 项未保存'
              : '阅读状态',
          onToolsLayoutSettled: _refreshReaderLayout,
          beforeHideTools: () async =>
              !_writing && (!_editing || await _setEditing(false)),
          blockArrowKeys: _desktopMenuOpen,
          onObstructionChanged: (insets) => setState(() => _panInsets = insets),
          onPrevious: () => _navigate(NavigationDirection.backward),
          onNext: () => _navigate(NavigationDirection.forward),
          onViewportChanged: _resetViewport,
          top: Column(
            key: const ValueKey('reader-top-chrome'),
            mainAxisSize: MainAxisSize.min,
            children: [
              _compactHeader(current, title),
              if (page != null && widget.allowAnnotations && _editing)
                _tools(_visiblePage ?? page),
            ],
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
              : _effectiveViewMode != ReaderViewMode.single
              ? _modeContent(current, page, toggleTools)
              : _paperViewport(
                  ReaderInput(
                    onPrevious: () => _navigate(NavigationDirection.backward),
                    onNext: () => _navigate(NavigationDirection.forward),
                    onCenterTap: _picking ? null : toggleTools,
                    allowPointerPageTurns:
                        !_picking &&
                        !_textTool &&
                        _tool == null &&
                        _scale <= 1.01,
                    panInsets: _panInsets,
                    pageAspect:
                        _visibleDocument?.aspectFor(
                          _visiblePage?.pageNumber ?? 1,
                        ) ??
                        current.aspectFor(_session.page),
                    mouseInk: _editing && _tool != null,
                    touchInk: _editing && _tool != null,
                    editing: _editing,
                    ignorePointerGestures: _desktopMenuOpen,
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
        ),
      ),
    );
  }

  ReaderViewMode get _effectiveViewMode =>
      _editing && _viewMode == ReaderViewMode.continuous
      ? ReaderViewMode.single
      : _viewMode;
  FirstPageArrangement _arrangementFor(String entryId) =>
      widget.allowAnnotations
      ? _viewPreferences?.arrangementFor(entryId) ?? FirstPageArrangement.paired
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
    if (_writing ||
        _editing ||
        mode == _viewMode ||
        !_capabilities.supports(mode)) {
      return;
    }
    if (_viewMode == ReaderViewMode.continuous) {
      _continuousRestore = _continuous.anchor;
      _continuousAnchorFocus = _visiblePage;
    } else if (mode == ReaderViewMode.continuous &&
        _session.pageKey != _continuousAnchorFocus) {
      _continuousRestore = null;
    }
    setState(() {
      _viewMode = mode;
      _direction = 0;
      _inputGeneration++;
      _cancelPick();
      _transform.value = Matrix4.identity();
    });
    _savePreference(_viewPreferences?.setMode(mode));
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
      _savePreference(_viewPreferences?.setArrangement(id, value));
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
    if (_viewMode == ReaderViewMode.continuous) {
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
    if (_viewMode == ReaderViewMode.continuous &&
        _session.pageKey != _continuousEditStart) {
      _continuousRestore = null;
    }
    _setEditing(false);
  }

  Future<void> _addToSetList() async {
    if (_writing || !await _textControls.finish() || !mounted) return;
    final target = _visibleDocument?.target ?? _session.current?.target;
    if (target == null) return;
    setState(() => _desktopMenuOpen = true);
    try {
      await showAddToSetList(
        context,
        workspace: widget.workspace,
        entryId: target.entryId,
        displayPath: target.displayPath,
      );
    } finally {
      if (mounted) setState(() => _desktopMenuOpen = false);
    }
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
      doublePage: _effectiveViewMode == ReaderViewMode.spread,
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
      body: _trackPen(
        ReaderStage(
          top: const SizedBox.shrink(),
          bottom: const SizedBox.shrink(),
          hasReadablePage: _visiblePage != null,
          onViewportChanged: _resetViewport,
          onPrevious: () => _navigate(NavigationDirection.backward),
          onNext: () => _navigate(NavigationDirection.forward),
          blockArrowKeys: _desktopMenuOpen || _quickPageMenu.isOpen,
          contentBuilder: (_) => DesktopReaderShell(
            fitAspectFor: _effectiveViewMode == ReaderViewMode.continuous
                ? null
                : _readerFitAspect,
            documentMenu: [
              if (document != null && Platform.isWindows)
                MenuItemButton(
                  onPressed: () =>
                      unawaited(_revealCurrentFile(document.target)),
                  child: const Text('打开文件所在目录'),
                ),
              if (document != null && document.pdf == null)
                MenuItemButton(
                  onPressed: () => unawaited(
                    showImageDisplayInfo(context, _imageInfos[_visiblePage]),
                  ),
                  child: const Text('图片信息'),
                ),
            ],
            primaryActions: [
              if (widget.headerAction != null) widget.headerAction!,
              if (widget.allowAnnotations)
                ReaderActionButton(
                  label: '加入曲单',
                  icon: const ReaderIcon(
                    ReaderGlyph.playlistAdd,
                    size: ScoreLayout.iconVisual,
                  ),
                  target: ScoreLayout.desktopTarget,
                  onPressed: _writing ? null : _addToSetList,
                ),
            ],
            actions: [
              if (document != null)
                _shareButton(document, title, ScoreLayout.desktopTarget),
              const SizedBox(
                width: ScoreLayout.desktopTarget,
                height: ScoreLayout.desktopTarget,
                child: ThemeAction(),
              ),
            ],
            onObstructionChanged: (insets) {
              if (mounted && _panInsets != insets) {
                setState(() => _panInsets = insets);
              }
            },
            title: p.basename(title),
            pageLabel: pageLabel,
            mode: _effectiveViewMode,
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
              if (_effectiveViewMode == ReaderViewMode.continuous) {
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
            contentBuilder: (toggleBar) =>
                _modeContent(current, page, toggleBar),
          ),
        ),
      ),
    );
  }

  Widget _modeContent(
    LoadedScore? current,
    PageKey? page,
    VoidCallback toggleBar,
  ) {
    if (current == null || page == null) {
      return Center(
        child: _initialLoading || _session.loading
            ? const CircularProgressIndicator()
            : FilledButton(onPressed: _retryOpen, child: const Text('重新打开')),
      );
    }
    if (_effectiveViewMode == ReaderViewMode.continuous) {
      return ReaderContinuousView(
        key: ValueKey(current.target.key),
        documentKey: current.target.key,
        pageCount: current.pageCount,
        aspectFor: current.aspectFor,
        controller: _continuous,
        rasterPageLimit: _isCompact ? 2 : 4,
        touchPanHorizontal: _isCompact,
        edgeToEdge: _isCompact,
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
          if (_effectiveViewMode != ReaderViewMode.continuous ||
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
    return LayoutBuilder(
      builder: (context, paperConstraints) {
        final paperSize = Size(
          paperConstraints.maxWidth - readerPagePadding(context).horizontal,
          paperConstraints.maxHeight - readerPagePadding(context).vertical,
        );
        final groups = ReaderSpreads(
          pageCount: current.pageCount,
          doublePage: _effectiveViewMode == ReaderViewMode.spread,
          arrangement: _arrangementFor(current.target.entryId),
        );
        final mode = _effectiveViewMode;
        final viewKey = (current.target.key, mode, groups.arrangement);
        double aspect(int index) {
          final group = groups.at(index);
          if (!groups.doublePage) {
            return current.aspectFor(group.first);
          }
          return readerSpreadAspect(paperSize, group, current.aspectFor);
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
                : readerSpreadAspect(paperSize, first, next.aspectFor),
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

        return _paperViewport(
          ReaderInput(
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
            mouseWheel: !_isCompact,
            panInsets: _panInsets,
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
                    _effectiveViewMode != mode ||
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
                    _effectiveViewMode != mode ||
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
          ),
        );
      },
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
        (_effectiveViewMode != ReaderViewMode.continuous)) {
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
        _effectiveViewMode == ReaderViewMode.spread &&
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
                (_isCompact && _effectiveViewMode == ReaderViewMode.single) ||
                _effectiveViewMode == ReaderViewMode.continuous ||
                (identical(document, _visibleDocument) &&
                    (_effectiveViewMode == ReaderViewMode.spread
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
                ((_isCompact && _effectiveViewMode == ReaderViewMode.single) ||
                    editableSpread ||
                    (_editing &&
                        surfacePage == _visiblePage &&
                        surfacePage == _session.pageKey)) &&
                !_session.sourceChanged &&
                (!_textTool || editableSpread || surfacePage == _visiblePage),
            textTool: _textTool,
            onTextToolRequested: _tool == null && !_textTool && !_picking
                ? () => setState(() => _textTool = true)
                : null,
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
    final last = _effectiveViewMode == ReaderViewMode.spread
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
    final currentSize = _textTool
        ? _textControls.fontSizeFraction
        : _sizes[activeTool]!;
    final minSize = _textTool ? 8 / 1024 : activeTool.minSize;
    final maxSize = _textTool ? 96 / 1024 : activeTool.maxSize;
    Widget history(bool undo) => ReaderActionButton(
      label: undo ? '撤销' : '重做',
      icon: ReaderIcon(
        undo ? ReaderGlyph.undo : ReaderGlyph.redo,
        size: ScoreLayout.iconVisual,
      ),
      onPressed:
          (undo
                  ? widget.workspace.store.canUndo(page)
                  : widget.workspace.store.canRedo(page)) ||
              widget.workspace.savingAnnotations
          ? () => _queueAnnotationHistory(page, undo: undo)
          : null,
    );
    return Container(
      key: _textToolsKey,
      height: ScoreLayout.annotationBarHeight,
      decoration: BoxDecoration(
        color: ScoreTokens.of(context).paper0,
        border: Border(
          bottom: BorderSide(color: ScoreTokens.of(context).hair2),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey(
                _isCompact
                    ? 'reader-ipad-annotation-scroll'
                    : 'reader-desktop-annotation-scroll',
              ),
              controller: _toolsScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tool in ReaderTool.values) ...[
                    if (tool != ReaderTool.values.first)
                      const SizedBox(width: ScoreSpace.xs),
                    ReaderToolButton(
                      key: ValueKey(tool),
                      tool: tool,
                      selected: !_picking && !_textTool && _tool == tool,
                      value: _sizes[tool]!,
                      onSelect: () => _selectTool(tool),
                    ),
                  ],
                  const SizedBox(width: ScoreSpace.xs),
                  ReaderActionButton(
                    label: '文字批注',
                    icon: const ReaderIcon(
                      ReaderGlyph.text,
                      size: ScoreLayout.iconVisual,
                    ),
                    selected: _textTool && !_picking,
                    tool: true,
                    onPressed: _toggleTextTool,
                  ),
                  const SizedBox(width: ScoreSpace.lg),
                  ReaderPaletteButton(
                    argb: _color,
                    onMenuChanged: (open) =>
                        setState(() => _desktopMenuOpen = open),
                    onChanged: _textControls.saving
                        ? null
                        : (color) {
                            setState(() {
                              _cancelPick();
                              _usingSample = false;
                              _color = color;
                            });
                            if (_textTool) _textControls.changeColor(color);
                          },
                  ),
                  const SizedBox(width: ScoreSpace.xs),
                  ReaderSampleColorButton(
                    sample: _lastSample == null ? null : Color(_lastSample!),
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
                  const SizedBox(width: ScoreSpace.lg),
                  ReaderSizeButton(
                    key: const ValueKey('annotation-size-button'),
                    value: currentSize.clamp(minSize, maxSize),
                    min: minSize,
                    max: maxSize,
                    label: _textTool ? '字号' : '粗细',
                    tool: activeTool,
                    textMode: _textTool,
                    onChanged: _textTool && _textControls.saving
                        ? null
                        : (value) => setState(() {
                            if (_textTool) {
                              _textControls.changeFontSizeFraction(value);
                            } else {
                              _sizes[activeTool] = value;
                            }
                          }),
                    onChangeEnd: _textTool
                        ? (_) => unawaited(_textControls.commitFontSize())
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: ScoreSpace.lg),
          history(true),
          const SizedBox(width: ScoreSpace.xs),
          history(false),
        ],
      ),
    );
  }

  double _readerFitAspect(Size viewport) {
    final document = _visibleDocument ?? _session.current;
    if (document == null) return 1;
    final number = _visiblePage?.pageNumber ?? _session.page;
    if (_effectiveViewMode == ReaderViewMode.spread) {
      final spread = ReaderSpreads(
        pageCount: document.pageCount,
        doublePage: true,
        arrangement: _arrangementFor(document.target.entryId),
      ).forPage(number);
      return readerSpreadAspect(viewport, spread, document.aspectFor);
    }
    return document.aspectFor(number);
  }

  Widget _paperViewport(Widget child) => Padding(
    padding: readerPagePadding(context),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final next = constraints.biggest, before = _paperViewportSize;
        final samePage = _paperViewportPage == _visiblePage;
        _paperViewportSize = next;
        _paperViewportPage = _visiblePage;
        final matrix = Matrix4.copy(_transform.value);
        final scale = matrix.getMaxScaleOnAxis();
        if (before != null &&
            before != next &&
            samePage &&
            scale > 1.000001 &&
            !readerTextEditorActive) {
          Rect fitted(Size size) => Alignment.center.inscribe(
            applyBoxFit(
              BoxFit.contain,
              Size(_readerFitAspect(size), 1),
              size,
            ).destination,
            Offset.zero & size,
          );
          final oldPaper = fitted(before), newPaper = fitted(next);
          final scene =
              (before.center(Offset.zero) -
                  Offset(matrix.storage[12], matrix.storage[13])) /
              scale;
          // Preserve the user's preferred content anchor through temporary
          // chrome clamping. Opening a bar can make an edge view unreachable;
          // closing it restores that original view instead of accumulating drift.
          final fraction =
              _preferredAnchorPage == _visiblePage &&
                  _preferredAnchorScale == scale &&
                  _preferredViewportAnchor != null
              ? _preferredViewportAnchor!
              : Offset(
                  (scene.dx - oldPaper.left) / oldPaper.width,
                  (scene.dy - oldPaper.top) / oldPaper.height,
                );
          _preferredViewportAnchor = fraction;
          _preferredAnchorPage = _visiblePage;
          _preferredAnchorScale = scale;
          final anchor =
              newPaper.topLeft +
              Offset(
                fraction.dx * newPaper.width,
                fraction.dy * newPaper.height,
              );
          final translation = clampReaderPan(
            viewport: next,
            scale: scale,
            translation: next.center(Offset.zero) - anchor * scale,
            pageAspect: _readerFitAspect(next),
          );
          // This LayoutBuilder owns the transformed reader below it. Publish
          // the reprojected anchor before those descendants build/paint, so
          // the compositor never shows one frame with the old viewport matrix.
          _projectingViewport = true;
          try {
            _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
              ..setTranslationRaw(translation.dx, translation.dy, 0);
          } finally {
            _projectingViewport = false;
          }
        }
        return child;
      },
    ),
  );

  Widget _trackPen(Widget child) => Listener(
    onPointerDown: (event) {
      if (event.kind != PointerDeviceKind.stylus &&
          event.kind != PointerDeviceKind.invertedStylus) {
        return;
      }
      _dotRestore?.cancel();
      _penPointers.add(event.pointer);
      if (!_dotsSuppressed) setState(() => _dotsSuppressed = true);
    },
    onPointerUp: _releasePen,
    onPointerCancel: _releasePen,
    child: child,
  );
  void _releasePen(PointerEvent event) {
    if (!_penPointers.remove(event.pointer) || _penPointers.isNotEmpty) return;
    _dotRestore?.cancel();
    _dotRestore = Timer(ScoreMotion.micro, () {
      if (mounted) setState(() => _dotsSuppressed = false);
    });
  }

  Future<void> _revealCurrentFile(ScoreTarget target) async {
    try {
      if (!await File(target.filePath).exists()) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('文件已移动或不存在，请刷新谱库后重试。')));
        }
        return;
      }
      await Process.start(
        'explorer.exe',
        ['/select,', target.filePath],
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('无法打开文件所在目录，请重试。')));
      }
    }
  }

  Future<void> _share(LoadedScore document, String title) async {
    if (_sharing || _writing) return;
    setState(() => _sharing = true);
    try {
      await shareScore(
        context,
        filePath: document.target.filePath,
        fileName: p.basename(title),
        validate: document.target.validateBeforeRead,
        beforeShare: _prepareShare,
        annotationsFor: (number) => _shareAnnotations(document.target, number),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _shareButton(LoadedScore document, String title, double target) =>
      ReaderActionButton(
        label: _sharing ? '正在分享' : '分享',
        target: target,
        icon: _sharing
            ? const SizedBox.square(
                dimension: ScoreLayout.iconVisual,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const ReaderIcon(ReaderGlyph.share, size: ScoreLayout.iconVisual),
        onPressed: _writing || _sharing
            ? null
            : () => unawaited(_share(document, title)),
      );

  Widget _compactHeader(LoadedScore? current, String title) {
    final t = ScoreTokens.of(context);
    final document = _visibleDocument ?? current;
    return Container(
      height: ScoreLayout.readerHeaderHeight,
      decoration: BoxDecoration(
        color: t.paper0,
        border: Border(bottom: BorderSide(color: t.hair2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.lg),
      child: Row(
        children: [
          ReaderActionButton(
            label: '返回曲库',
            onPressed: _back,
            icon: const ReaderIcon(
              ReaderGlyph.back,
              size: ScoreLayout.iconVisual,
            ),
          ),
          const SizedBox(width: ScoreSpace.sm),
          Expanded(
            child: MenuAnchor(
              style: const MenuStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size(ScoreLayout.menuWidth, 0),
                ),
              ),
              onOpen: () => setState(() => _desktopMenuOpen = true),
              onClose: () => setState(() => _desktopMenuOpen = false),
              menuChildren: [
                if (widget.allowAnnotations)
                  MenuItemButton(
                    onPressed: _addToSetList,
                    child: const Text('加入曲单'),
                  ),
                if (document != null && document.pdf == null)
                  MenuItemButton(
                    onPressed: () => unawaited(
                      showImageDisplayInfo(context, _imageInfos[_visiblePage]),
                    ),
                    child: const Text('图片信息'),
                  ),
              ],
              builder: (context, controller, _) => Semantics(
                button: true,
                label: '曲谱操作',
                child: Tooltip(
                  message: '曲谱操作',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    child: SizedBox(
                      key: const ValueKey('reader-title-menu'),
                      height: ScoreLayout.readerTitleMenuHitHeight,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              p.posix.basename(title.replaceAll('\\', '/')),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ScoreText.body.copyWith(
                                color: t.ink900,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: ScoreSpace.xs),
                          const ReaderIcon(
                            ReaderGlyph.chevronDown,
                            size: ScoreLayout.readerTitleChevron,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: ScoreSpace.sm),
          if (widget.headerAction != null) ...[
            widget.headerAction!,
            const SizedBox(width: ScoreSpace.xs),
          ],
          if (_capabilities.multipleModes) _compactModeMenu(),
          if (document != null)
            TextButton(
              onPressed: _writing ? null : _jumpDialog,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, ScoreLayout.touchTarget),
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
                foregroundColor: t.ink500,
                textStyle: Theme.of(context).textTheme.labelLarge,
                splashFactory: NoSplash.splashFactory,
              ),
              child: Text(
                '${_visiblePage?.pageNumber ?? _session.page} / ${document.pageCount}',
              ),
            ),
          if (widget.allowAnnotations) ...[
            const SizedBox(width: ScoreSpace.xs),
            ReaderActionButton(
              key: const ValueKey('ipad-annotation-toggle'),
              label: _editing ? '完成批注' : '批注',
              caption: _editing ? '完成批注' : '批注',
              width: _editing
                  ? ScoreLayout.readerAnnotationDoneButtonWidth
                  : ScoreLayout.readerAnnotationButtonWidth,
              selected: _editing,
              onPressed: _writing ? null : _annotationAction,
              icon: const ReaderIcon(
                ReaderGlyph.pen,
                size: ScoreLayout.iconVisual,
              ),
            ),
          ],
          if (document != null) ...[
            const SizedBox(width: ScoreSpace.xs),
            _shareButton(document, title, ScoreLayout.touchTarget),
          ],
          const SizedBox(width: ScoreSpace.xs),
          const SizedBox(
            width: ScoreLayout.touchTarget,
            height: ScoreLayout.touchTarget,
            child: ThemeAction(),
          ),
        ],
      ),
    );
  }

  Widget _compactModeMenu() {
    final arrangement = _arrangementFor(
      _session.current?.target.entryId ?? widget.initialTarget.entryId,
    );
    return MenuAnchor(
      onOpen: () => setState(() => _desktopMenuOpen = true),
      onClose: () => setState(() => _desktopMenuOpen = false),
      style: const MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(ScoreLayout.menuWidth, 0)),
      ),
      menuChildren: [
        for (final mode in ReaderViewMode.values)
          MenuItemButton(
            key: ValueKey(('ipad-reader-mode', mode)),
            onPressed: _writing || _editing || !_capabilities.supports(mode)
                ? null
                : () => _changeView(mode),
            trailingIcon: _effectiveViewMode == mode
                ? const ReaderIcon(ReaderGlyph.check)
                : null,
            child: Text(switch (mode) {
              ReaderViewMode.single => '单页',
              ReaderViewMode.spread => '双页',
              ReaderViewMode.continuous => '连续',
            }),
          ),
        if (_effectiveViewMode == ReaderViewMode.spread)
          for (final value in FirstPageArrangement.values)
            MenuItemButton(
              key: ValueKey(('ipad-reader-arrangement', value)),
              onPressed: _writing || _editing
                  ? null
                  : () => _changeArrangement(value),
              trailingIcon: arrangement == value
                  ? const ReaderIcon(ReaderGlyph.check)
                  : null,
              child: Text(
                value == FirstPageArrangement.alone ? '首页单独' : '1、2页并排',
              ),
            ),
      ],
      builder: (context, controller, _) => ReaderActionButton(
        key: const ValueKey('ipad-reader-mode-button'),
        label: '阅读模式',
        icon: const ReaderIcon(ReaderGlyph.book),
        onPressed: _writing
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

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
    if (_effectiveViewMode == ReaderViewMode.spread) {
      final arrangements =
          _viewPreferences?.arrangements ??
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
    if ((_effectiveViewMode == ReaderViewMode.continuous) ||
        _dotsSuppressed ||
        _writing ||
        _textDraftActive ||
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        _visiblePage == null) {
      return const SizedBox.shrink();
    }
    return ReaderPageSeekBar(
      hitRegionKey: _seekRegionKey,
      key: ValueKey(_visibleDocument?.target.key),
      currentPage: _visiblePage!.pageNumber,
      pageCount: _visibleDocument?.pageCount ?? 1,
      enabled:
          !_picking &&
          _session.current?.target.key == _visibleDocument?.target.key,
      onCancel: _session.cancelSeek,
      onSeek: (number, gesture) async {
        if (_writing ||
            _picking ||
            _session.current?.target.key != _visibleDocument?.target.key) {
          return;
        }
        final document = _visibleDocument;
        if (!await _textControls.finish() ||
            !mounted ||
            _visibleDocument != document ||
            _writing) {
          return;
        }
        _direction = number >= _visiblePage!.pageNumber ? 1 : -1;
        _requestedAt =
            widget.presentationClock?.call() ?? readerPresentationNow();
        unawaited(_session.seek(number, gesture: gesture));
      },
    );
  }

  void _zoom(double factor) {
    if (_effectiveViewMode == ReaderViewMode.continuous) {
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
