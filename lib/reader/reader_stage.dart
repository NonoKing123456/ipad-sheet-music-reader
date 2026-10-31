import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get isMobileReader =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;
bool get canPreviewReader => defaultTargetPlatform == TargetPlatform.windows;

/// Controls float above the unchanged full viewport. They never resize paper.
class ReaderStage extends StatefulWidget {
  const ReaderStage({
    super.key,
    required this.contentBuilder,
    required this.top,
    required this.bottom,
    this.notices = const [],
    this.drawing = false,
    this.onViewportChanged,
  });
  final Widget Function(VoidCallback toggleTools) contentBuilder;
  final Widget top, bottom;
  final List<Widget> notices;
  final bool drawing;
  final VoidCallback? onViewportChanged;
  @override
  State<ReaderStage> createState() => _ReaderStageState();
}

class _ReaderStageState extends State<ReaderStage> with WidgetsBindingObserver {
  late bool _tools = !isMobileReader;
  Size? _viewport;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _immerse();
  }

  void _immerse() {
    if (isMobileReader) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          defaultTargetPlatform == TargetPlatform.iOS
              ? SystemUiMode.manual
              : SystemUiMode.immersiveSticky,
          overlays: const [],
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _immerse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (isMobileReader) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_viewport != null && _viewport != size) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onViewportChanged?.call();
        });
      }
      _viewport = size;
      return Stack(
        key: const ValueKey('reading-viewport'),
        fit: StackFit.expand,
        children: [
          widget.contentBuilder(() => setState(() => _tools = !_tools)),
          if (_tools || widget.notices.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [if (_tools) widget.top, ...widget.notices],
                ),
              ),
            ),
          if (_tools)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: widget.bottom),
            ),
          if (!_tools && widget.drawing)
            Positioned(
              right: 8,
              top: 8,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: '显示批注工具',
                  onPressed: () => setState(() => _tools = true),
                  icon: const Icon(Icons.edit_note),
                ),
              ),
            ),
          if (_tools)
            Positioned(
              right: 8,
              bottom: 78,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: '收起阅读工具',
                  onPressed: () => setState(() => _tools = false),
                  icon: const Icon(Icons.fullscreen),
                ),
              ),
            ),
        ],
      );
    },
  );
}
