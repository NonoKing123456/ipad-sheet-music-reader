import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'raster_plan.dart';

/// Keeps one decoded frame and requests source pixels appropriate to zoom.
/// No global cache of every zoom level and no unconditional 2200px downgrade.
class SharpFileImage extends StatefulWidget {
  const SharpFileImage({
    super.key,
    required this.path,
    required this.transform,
    this.onRendered,
    this.errorText = '图片暂时无法显示，请返回后重试。',
  });
  final String path;
  final TransformationController transform;
  final VoidCallback? onRendered;
  final String errorText;
  @override
  State<SharpFileImage> createState() => _SharpFileImageState();
}

class _SharpFileImageState extends State<SharpFileImage> {
  ui.ImmutableBuffer? _buffer;
  ui.ImageDescriptor? _descriptor;
  ui.Image? _image;
  Size? _target, _space;
  int _epoch = 0;
  Timer? _timer;
  bool _scheduled = false, _failed = false;
  double _dpr = 1;
  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_changed);
    unawaited(_open());
  }

  @override
  void didUpdateWidget(covariant SharpFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform.removeListener(_changed);
      widget.transform.addListener(_changed);
    }
    if (oldWidget.path != widget.path) {
      _release();
      unawaited(_open());
    }
  }

  void _release() {
    _epoch++;
    _image?.dispose();
    _image = null;
    _descriptor?.dispose();
    _descriptor = null;
    _buffer?.dispose();
    _buffer = null;
    _target = null;
    _failed = false;
  }

  Future<void> _open() async {
    final epoch = ++_epoch;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(widget.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (!mounted || epoch != _epoch) {
        descriptor.dispose();
        buffer.dispose();
        return;
      }
      _buffer = buffer;
      _descriptor = descriptor;
      setState(() {});
    } catch (_) {
      descriptor?.dispose();
      buffer?.dispose();
      if (mounted && epoch == _epoch) setState(() => _failed = true);
    }
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 65), _decode);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_decode());
    });
  }

  Future<void> _decode() async {
    final descriptor = _descriptor;
    final available = _space;
    if (!mounted ||
        descriptor == null ||
        available == null ||
        available.isEmpty) {
      return;
    }
    final aspect = descriptor.width / descriptor.height;
    final paper = applyBoxFit(
      BoxFit.contain,
      Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
      available,
    ).destination;
    final next = planImageDecode(
      source: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
      paper: Size(paper.width, paper.width / aspect),
      devicePixelRatio: _dpr,
      zoom: widget.transform.value.getMaxScaleOnAxis(),
    );
    if (_target != null &&
        _target!.width >= next.width &&
        _target!.height >= next.height) {
      return;
    }
    final epoch = ++_epoch;
    _target = next;
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec(
        targetWidth: next.width.toInt(),
        targetHeight: next.height.toInt(),
      );
      final image = (await codec.getNextFrame()).image;
      if (!mounted || epoch != _epoch) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
      debugPrint('READER image_decode pixels=${image.width}x${image.height}');
      widget.onRendered?.call();
    } catch (_) {
      if (mounted && epoch == _epoch) {
        _target = null;
        setState(() => _failed = true);
      }
    } finally {
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_changed);
    _timer?.cancel();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _space = constraints.biggest;
      _dpr = MediaQuery.devicePixelRatioOf(context);
      _schedule();
      if (_image != null) {
        return RawImage(
          image: _image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      }
      return Center(
        child: _failed
            ? Text(widget.errorText)
            : const CircularProgressIndicator(strokeWidth: 2),
      );
    },
  );
}
