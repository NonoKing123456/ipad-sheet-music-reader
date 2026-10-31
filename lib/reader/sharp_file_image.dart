import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
    this.decodeForTesting,
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
  @visibleForTesting
  final Future<ui.Image> Function(ui.ImageDescriptor, Size)? decodeForTesting;
  final String errorText;
  @override
  State<SharpFileImage> createState() => _SharpFileImageState();
}

class _SharpFileImageState extends State<SharpFileImage> {
  _ImageSource? _source;
  ui.ImageDescriptor? get _descriptor => _source?.descriptor;
  Size? _wanted;
  bool _decoding = false;
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
    _source?.release();
    _source = null;
    _wanted = null;
    _discardRetiredImageDecodes();
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
      _source = _ImageSource(buffer, descriptor);
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
        _failed ||
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
    _wanted = next;
    if (_decoding) return;
    _decoding = true;
    try {
      while (mounted && _source != null && _wanted != null) {
        final source = _source!;
        var target = _wanted!;
        _wanted = null;
        if (_target != null &&
            _target!.width >= target.width &&
            _target!.height >= target.height) {
          continue;
        }
        final epoch = _epoch, path = widget.path;
        final testingDecoder = widget.decodeForTesting;
        source.retain();
        try {
          final image = await _serialImageDecode(
            valid: () =>
                mounted && epoch == _epoch && identical(source, _source),
            foreground: () => widget.active,
            operation: () async {
              if (_wanted != null) {
                target = _wanted!;
                _wanted = null;
              }
              if (_target != null &&
                  _target!.width >= target.width &&
                  _target!.height >= target.height) {
                return null;
              }
              return testingDecoder != null
                  ? testingDecoder(source.descriptor, target)
                  : _decodeImage(source.descriptor, path, target);
            },
          );
          if (image == null) continue;
          if (!mounted || epoch != _epoch || !identical(source, _source)) {
            image.dispose();
            continue;
          }
          _target = target;
          setState(() {
            _image?.dispose();
            _image = image;
            _failed = false;
          });
          debugPrint(
            'READER image_decode source=${source.descriptor.width}x${source.descriptor.height} pixels=${image.width}x${image.height} dpr=$_dpr zoom=${widget.transform.value.getMaxScaleOnAxis().toStringAsFixed(2)} active=${widget.active}',
          );
          widget.onRendered?.call();
          widget.onError?.call(null);
        } catch (_) {
          if (mounted && epoch == _epoch && identical(source, _source)) {
            _target = null;
            setState(() => _failed = true);
            widget.onError?.call(widget.errorText);
            _wanted = null;
          }
        } finally {
          source.release();
        }
      }
    } finally {
      _decoding = false;
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

/// Encoded source ownership survives path changes/disposal until its last job
/// finishes. Generation checks alone cannot protect native resources in flight.
class _ImageSource {
  _ImageSource(this.buffer, this.descriptor);
  final ui.ImmutableBuffer buffer;
  final ui.ImageDescriptor descriptor;
  int _owners = 1;
  void retain() => _owners++;
  void release() {
    if (--_owners == 0) {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}

class _ImageDecodeJob {
  _ImageDecodeJob(this.valid, this.foreground, this.operation);
  final bool Function() valid, foreground;
  final Future<ui.Image?> Function() operation;
  final result = Completer<ui.Image?>();
}

final _imageDecodeJobs = <_ImageDecodeJob>[];
bool _imageDecodeRunning = false;
Future<ui.Image?> _serialImageDecode({
  required bool Function() valid,
  required bool Function() foreground,
  required Future<ui.Image?> Function() operation,
}) {
  final job = _ImageDecodeJob(valid, foreground, operation);
  _imageDecodeJobs.add(job);
  if (!_imageDecodeRunning) unawaited(_drainImageDecodes());
  return job.result.future;
}

Future<void> _drainImageDecodes() async {
  _imageDecodeRunning = true;
  try {
    while (_imageDecodeJobs.isNotEmpty) {
      _discardRetiredImageDecodes();
      if (_imageDecodeJobs.isEmpty) break;
      final active = _imageDecodeJobs.indexWhere((job) => job.foreground());
      final job = _imageDecodeJobs.removeAt(active < 0 ? 0 : active);
      try {
        job.result.complete(await job.operation());
      } catch (error, stack) {
        job.result.completeError(error, stack);
      }
    }
  } finally {
    _imageDecodeRunning = false;
  }
}

void _discardRetiredImageDecodes() {
  for (var index = _imageDecodeJobs.length - 1; index >= 0; index--) {
    if (!_imageDecodeJobs[index].valid()) {
      _imageDecodeJobs.removeAt(index).result.complete(null);
    }
  }
}

const _rasterChannel = MethodChannel('score_reader/raster_decode');
Future<ui.Image> _decodeImage(
  ui.ImageDescriptor source,
  String path,
  Size target,
) async {
  String? prepared;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? thumbnail;
  ui.Codec? codec;
  try {
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        source.width * source.height > 12000000) {
      prepared = await _rasterChannel.invokeMethod<String>('prepareRaster', {
        'path': path,
        'width': target.width.toInt(),
        'height': target.height.toInt(),
      });
      if (prepared == null) throw StateError('No prepared raster');
      buffer = await ui.ImmutableBuffer.fromFilePath(prepared);
      thumbnail = await ui.ImageDescriptor.encoded(buffer);
      if (thumbnail.width * thumbnail.height > 12000000 ||
          math.max(thumbnail.width, thumbnail.height) > 8192) {
        throw StateError('Prepared raster exceeds the image budget');
      }
    }
    final descriptor = thumbnail ?? source;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.min(descriptor.width, target.width.toInt()),
      targetHeight: math.min(descriptor.height, target.height.toInt()),
    );
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    thumbnail?.dispose();
    buffer?.dispose();
    if (prepared != null) {
      await _rasterChannel.invokeMethod<bool>('releaseRaster', {
        'path': prepared,
      });
    }
  }
}
