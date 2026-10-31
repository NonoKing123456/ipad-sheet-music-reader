import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'raster_plan.dart';
import 'paper_color_sampler.dart';

class ImageDisplayInfo {
  const ImageDisplayInfo({
    required this.source,
    required this.decoded,
    required this.logicalDisplay,
    required this.dpr,
    required this.zoom,
    this.fileVersion,
  });
  final Size source, decoded, logicalDisplay;
  final double dpr, zoom;
  final String? fileVersion;
  String get summary =>
      '源图：${source.width.round()}×${source.height.round()} px\n'
      '实际载入：${decoded.width.round()}×${decoded.height.round()} px\n'
      '整幅显示：${(logicalDisplay.width * dpr * zoom).round()}×${(logicalDisplay.height * dpr * zoom).round()} px\n'
      'DPR：${dpr.toStringAsFixed(2)}\n缩放：${(zoom * 100).round()}%\n文件版本标识：${fileVersion ?? '未提供'}';
  @override
  bool operator ==(Object other) =>
      other is ImageDisplayInfo &&
      source == other.source &&
      decoded == other.decoded &&
      logicalDisplay == other.logicalDisplay &&
      dpr == other.dpr &&
      zoom == other.zoom &&
      fileVersion == other.fileVersion;
  @override
  int get hashCode =>
      Object.hash(source, decoded, logicalDisplay, dpr, zoom, fileVersion);
}

Future<void> showImageDisplayInfo(
  BuildContext context,
  ImageDisplayInfo? info,
) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '图片信息',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        SelectableText(info?.summary ?? '图片正在准备，请稍后重试。'),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: info == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: info.summary)),
          icon: const Icon(Icons.copy),
          label: const Text('复制显示数据'),
        ),
      ],
    ),
  ),
);

/// Keeps one decoded frame and requests source pixels appropriate to zoom.
/// No global cache of every zoom level and no unconditional 2200px downgrade.
class SharpFileImage extends StatefulWidget {
  const SharpFileImage({
    super.key,
    required this.path,
    required this.transform,
    this.onRendered,
    this.onError,
    this.colorSampler,
    this.colorKey,
    this.active = true,
    this.onImageInfo,
    this.fileVersion,
    this.errorText = '图片暂时无法显示，请返回后重试。',
  });
  final String path;
  final TransformationController transform;
  final VoidCallback? onRendered;
  final ValueChanged<String?>? onError;
  final PaperColorSampler? colorSampler;
  final Object? colorKey;
  final bool active;
  final ValueChanged<ImageDisplayInfo>? onImageInfo;
  final String? fileVersion;
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
  bool _infoScheduled = false;
  ImageDisplayInfo? _reportedInfo;
  @override
  void initState() {
    super.initState();
    _bindSampler();
    widget.transform.addListener(_changed);
    unawaited(_open());
  }

  void _bindSampler() {
    if (widget.colorKey != null) {
      widget.colorSampler?.attach(widget.colorKey!, this, _sampleColor);
    }
  }

  Future<Color?> _sampleColor(Offset normalized) async {
    final image = _image, space = _space;
    if (image == null || space == null || space.isEmpty) return null;
    final painted = applyBoxFit(
      BoxFit.contain,
      Size(image.width.toDouble(), image.height.toDouble()),
      space,
    ).destination;
    final rect = Alignment.center.inscribe(painted, Offset.zero & space);
    final point = Offset(
      normalized.dx * space.width,
      normalized.dy * space.height,
    );
    if (!rect.contains(point)) return null;
    return samplePaperImage(
      image,
      Offset(
        (point.dx - rect.left) / rect.width,
        (point.dy - rect.top) / rect.height,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant SharpFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.colorSampler != widget.colorSampler ||
        oldWidget.colorKey != widget.colorKey) {
      if (oldWidget.colorKey != null) {
        oldWidget.colorSampler?.detach(oldWidget.colorKey!, this);
      }
      _bindSampler();
    }
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
    _reportedInfo = null;
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
      if (mounted && epoch == _epoch) {
        setState(() => _failed = true);
        widget.onError?.call(widget.errorText);
      }
    }
  }

  void _changed() {
    _reportImageInfo();
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
      zoom: widget.active ? widget.transform.value.getMaxScaleOnAxis() : 1,
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
      debugPrint(
        'READER image_decode source=${descriptor.width}x${descriptor.height} pixels=${image.width}x${image.height} dpr=$_dpr zoom=${widget.transform.value.getMaxScaleOnAxis().toStringAsFixed(2)} active=${widget.active}',
      );
      widget.onRendered?.call();
      widget.onError?.call(null);
    } catch (_) {
      if (mounted && epoch == _epoch) {
        _target = null;
        setState(() => _failed = true);
        widget.onError?.call(widget.errorText);
      }
    } finally {
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    if (widget.colorKey != null) {
      widget.colorSampler?.detach(widget.colorKey!, this);
    }
    widget.transform.removeListener(_changed);
    _timer?.cancel();
    _release();
    super.dispose();
  }

  void _reportImageInfo() {
    if (_infoScheduled || widget.onImageInfo == null) return;
    _infoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _infoScheduled = false;
      if (!mounted || _image == null || _descriptor == null || _space == null) {
        return;
      }
      final image = _image!, descriptor = _descriptor!;
      final painted = applyBoxFit(
        BoxFit.contain,
        Size(image.width.toDouble(), image.height.toDouble()),
        _space!,
      ).destination;
      final info = ImageDisplayInfo(
        source: Size(descriptor.width.toDouble(), descriptor.height.toDouble()),
        decoded: Size(image.width.toDouble(), image.height.toDouble()),
        logicalDisplay: painted,
        dpr: _dpr,
        zoom: widget.transform.value.getMaxScaleOnAxis(),
        fileVersion:
            widget.fileVersion != null &&
                RegExp(r'^[a-fA-F0-9]{12,64}$').hasMatch(widget.fileVersion!)
            ? widget.fileVersion!.substring(0, 12)
            : null,
      );
      if (info != _reportedInfo) {
        _reportedInfo = info;
        widget.onImageInfo?.call(info);
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _space = constraints.biggest;
      _dpr = MediaQuery.devicePixelRatioOf(context);
      _schedule();
      _reportImageInfo();
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
