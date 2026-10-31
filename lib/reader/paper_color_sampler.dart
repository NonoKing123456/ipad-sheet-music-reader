import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

typedef PaperPixelSample = Future<Color?> Function(Offset normalized);

/// Holds callbacks only; renderers own native images and detach on disposal.
class PaperColorSampler {
  final _sources = <Object, (Object, PaperPixelSample)>{};
  void attach(Object page, Object owner, PaperPixelSample sample) =>
      _sources[page] = (owner, sample);
  void detach(Object page, Object owner) {
    if (identical(_sources[page]?.$1, owner)) _sources.remove(page);
  }

  int get sourceCount => _sources.length;
  Future<Color?> sample(Object page, Offset normalized) async {
    final source = _sources[page];
    if (source == null) return null;
    final color = await source.$2(normalized);
    return identical(_sources[page]?.$1, source.$1) ? color : null;
  }

  void dispose() => _sources.clear();
}

/// Reads a 3x3 source-pixel crop, never the annotated screen or a full RGBA page.
/// Clone before the first await so renderer replacement/disposal cannot race it.
Future<Color?> samplePaperImage(ui.Image source, Offset normalized) async {
  if (normalized.dx < 0 ||
      normalized.dx > 1 ||
      normalized.dy < 0 ||
      normalized.dy > 1) {
    return null;
  }
  final image = source.clone();
  ui.Image? crop;
  ui.Picture? picture;
  try {
    final x = (normalized.dx * image.width).floor().clamp(0, image.width - 1);
    final y = (normalized.dy * image.height).floor().clamp(0, image.height - 1);
    final left = (x - 1).clamp(0, image.width - 1),
        top = (y - 1).clamp(0, image.height - 1);
    final width = (image.width - left).clamp(1, 3),
        height = (image.height - top).clamp(1, 3);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        left.toDouble(),
        top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.none,
    );
    picture = recorder.endRecording();
    crop = await picture.toImage(width, height);
    final bytes = await crop.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return null;
    final channels = [<int>[], <int>[], <int>[]];
    for (var i = 0; i < width * height; i++) {
      for (var c = 0; c < 3; c++) {
        channels[c].add(bytes.getUint8(i * 4 + c));
      }
    }
    for (final values in channels) {
      values.sort();
    }
    return Color.fromARGB(
      255,
      channels[0][channels[0].length ~/ 2],
      channels[1][channels[1].length ~/ 2],
      channels[2][channels[2].length ~/ 2],
    );
  } finally {
    crop?.dispose();
    picture?.dispose();
    image.dispose();
  }
}

/// Single tap sampling. Multitouch/pans cancel the tap and remain available to
/// the outer ReaderInput transform; this layer never writes an annotation.
class PaperColorPickLayer extends StatefulWidget {
  const PaperColorPickLayer({super.key, required this.onPick});
  final ValueChanged<Offset> onPick;
  @override
  State<PaperColorPickLayer> createState() => _PaperColorPickLayerState();
}

class _PaperColorPickLayerState extends State<PaperColorPickLayer> {
  final _pointers = <int>{};
  Offset? _start;
  bool _cancelled = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _pointers.add(event.pointer);
          if (_pointers.length == 1) {
            _start = event.localPosition;
            _cancelled =
                event.kind == PointerDeviceKind.mouse &&
                event.buttons != kPrimaryButton;
          } else {
            _cancelled = true;
          }
        },
        onPointerMove: (event) {
          if (_start != null && (event.localPosition - _start!).distance > 12) {
            _cancelled = true;
          }
        },
        onPointerUp: (event) {
          _pointers.remove(event.pointer);
          if (_pointers.isEmpty &&
              !_cancelled &&
              _start != null &&
              !constraints.biggest.isEmpty) {
            widget.onPick(
              Offset(
                event.localPosition.dx / constraints.maxWidth,
                event.localPosition.dy / constraints.maxHeight,
              ),
            );
          }
          if (_pointers.isEmpty) _start = null;
        },
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _cancelled = true;
        },
        child: const SizedBox.expand(),
      ),
    ),
  );
}
