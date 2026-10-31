import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'raster_plan.dart';
import 'paper_color_sampler.dart';

Future<ui.Image?> renderSharpPdfPage(
  PdfPage page,
  PageRasterPlan plan,
  PdfPageRenderCancellationToken cancellation,
  bool neighbour,
) async {
  final raw = await page.render(
    x: plan.x,
    y: plan.y,
    width: plan.width,
    height: plan.height,
    fullWidth: plan.fullWidth,
    fullHeight: plan.fullHeight,
    cancellationToken: cancellation,
    priority: neighbour
        ? PdfPageRenderPriority.low
        : PdfPageRenderPriority.high,
  );
  if (raw == null) return null;
  try {
    return cancellation.isCanceled ? null : await raw.createImage();
  } finally {
    raw.dispose();
  }
}

typedef PageRasterizer = Future<ui.Image?> Function(
  PdfPage,
  PageRasterPlan,
  PdfPageRenderCancellationToken,
  bool,
);

/// Full paper fallback plus one screen-sized sharp visible patch. Neither the
/// annotation space nor InteractiveViewer's geometry is changed by rendering.
class SharpPdfPage extends StatefulWidget {
  const SharpPdfPage({
    super.key,
    required this.page,
    required this.active,
    required this.transform,
    required this.viewportKey,
    this.onRendered,
    this.onError,
    this.colorSampler,
    this.colorKey,
    this.rasterizer = renderSharpPdfPage,
  });
  final PdfPage page;
  final bool active;
  final TransformationController transform;
  final GlobalKey viewportKey;
  final VoidCallback? onRendered;
  final ValueChanged<String?>? onError;
  final PaperColorSampler? colorSampler;
  final Object? colorKey;
  final PageRasterizer rasterizer;
  @override
  State<SharpPdfPage> createState() => _SharpPdfPageState();
}

class _SharpPdfPageState extends State<SharpPdfPage> {
  final GlobalKey _paperKey = GlobalKey();
  ui.Image? _base, _detail;
  PageRasterPlan? _basePlan, _detailPlan, _requestedDetail;
  PdfPageRenderCancellationToken? _baseToken, _detailToken;
  int _baseEpoch = 0, _detailEpoch = 0;
  Timer? _timer;
  Size? _paper;
  double _dpr = 1;
  bool _scheduled = false;
  bool _baseFailed = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _bindSampler();
    widget.transform.addListener(_transformed);
  }

  void _bindSampler() {
    if (widget.colorKey != null) {
      widget.colorSampler?.attach(widget.colorKey!, this, _sampleColor);
    }
  }

  Future<Color?> _sampleColor(Offset normalized) async {
    final base = _base, paper = _paper;
    if (base == null || paper == null || paper.isEmpty) return null;
    final point = Offset(
      normalized.dx * paper.width,
      normalized.dy * paper.height,
    );
    final detail = _detail, plan = _detailPlan;
    if (detail != null && plan != null && plan.logicalRect.contains(point)) {
      final rect = plan.logicalRect;
      return samplePaperImage(
        detail,
        Offset(
          (point.dx - rect.left) / rect.width,
          (point.dy - rect.top) / rect.height,
        ),
      );
    }
    return samplePaperImage(base, normalized);
  }

  @override
  void didUpdateWidget(covariant SharpPdfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.colorSampler != widget.colorSampler ||
        oldWidget.colorKey != widget.colorKey) {
      if (oldWidget.colorKey != null) {
        oldWidget.colorSampler?.detach(oldWidget.colorKey!, this);
      }
      _bindSampler();
    }
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform.removeListener(_transformed);
      widget.transform.addListener(_transformed);
    }
    if (oldWidget.page != widget.page) {
      _baseEpoch++;
      _baseToken?.cancel();
      _basePlan = null;
      _clearDetail();
      _base?.dispose();
      _base = null;
    } else if (oldWidget.active && !widget.active) {
      _clearDetail();
    }
  }

  void _clearDetail() {
    _detailEpoch++;
    _detailToken?.cancel();
    _detailToken = null;
    _detail?.dispose();
    _detail = null;
    _detailPlan = null;
    _requestedDetail = null;
  }

  void _transformed() {
    // Stop a pending obsolete render immediately; request the next stable view
    // after a short quiet period rather than allocating for every pinch sample.
    _detailEpoch++;
    _detailToken?.cancel();
    _requestedDetail = null;
    if (_baseFailed) {
      _basePlan = null;
      _baseFailed = false;
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 65), _schedule);
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _refresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    if (widget.colorKey != null) {
      widget.colorSampler?.detach(widget.colorKey!, this);
    }
    widget.transform.removeListener(_transformed);
    _timer?.cancel();
    _baseEpoch++;
    _baseToken?.cancel();
    _base?.dispose();
    _clearDetail();
    super.dispose();
  }

  Future<void> _render(PageRasterPlan plan, {required bool detail}) async {
    final epoch = detail ? ++_detailEpoch : ++_baseEpoch;
    final token = widget.page.createCancellationToken();
    if (detail) {
      _detailToken?.cancel();
      _detailToken = token;
      _requestedDetail = plan;
    } else {
      _baseToken?.cancel();
      _baseToken = token;
      _basePlan = plan;
    }
    ui.Image? image;
    try {
      image = await widget.rasterizer(widget.page, plan, token, !widget.active);
      if (image == null) {
        if (token.isCanceled || epoch != (detail ? _detailEpoch : _baseEpoch)) {
          return;
        }
        throw StateError('Renderer returned no frame.');
      }
      if (!mounted ||
          token.isCanceled ||
          epoch != (detail ? _detailEpoch : _baseEpoch)) {
        image.dispose();
        return;
      }
      setState(() {
        if (detail) {
          _detail?.dispose();
          _detail = image;
          _detailPlan = plan;
        } else {
          _base?.dispose();
          _base = image;
          _baseFailed = false;
        }
        _error = null;
      });
      debugPrint(
        'READER raster ${detail
            ? 'visible'
            : widget.active
            ? 'base'
            : 'neighbour'} page=${widget.page.pageNumber} pixels=${plan.width}x${plan.height} zoom=${widget.transform.value.getMaxScaleOnAxis().toStringAsFixed(2)}',
      );
      widget.onRendered?.call();
      widget.onError?.call(null);
    } catch (failure) {
      if (mounted &&
          epoch == (detail ? _detailEpoch : _baseEpoch) &&
          !token.isCanceled) {
        if (detail) {
          // A sharp patch is optional. Keep the base/previous patch readable;
          // the next pan or zoom clears this request and retries it.
          _requestedDetail = plan;
        } else {
          _baseFailed = true;
          if (_base == null) {
            setState(() => _error = '此页暂时无法渲染，请重试。');
            widget.onError?.call(_error);
          }
        }
        debugPrint('READER raster_failed page=${widget.page.pageNumber}');
      }
    }
  }

  void _refresh() {
    final paper = _paper;
    if (!mounted || paper == null || paper.isEmpty) return;
    final base = planPageRaster(
      paper: paper,
      devicePixelRatio: _dpr,
      zoom: 1,
      neighbour: !widget.active,
    );
    if (_basePlan == null ||
        _basePlan!.width < base.width ||
        _basePlan!.height < base.height) {
      unawaited(_render(base, detail: false));
    }
    final zoom = widget.transform.value.getMaxScaleOnAxis();
    if (!widget.active || zoom <= 1.02) {
      if (_detail != null || _requestedDetail != null) setState(_clearDetail);
      return;
    }
    final box = _paperKey.currentContext?.findRenderObject() as RenderBox?;
    final viewport =
        widget.viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || viewport == null || !box.hasSize || !viewport.hasSize) {
      return;
    }
    final top = box.globalToLocal(viewport.localToGlobal(Offset.zero));
    final bottom = box.globalToLocal(
      viewport.localToGlobal(viewport.size.bottomRight(Offset.zero)),
    );
    final visible = Rect.fromPoints(top, bottom).intersect(Offset.zero & paper);
    if (visible.isEmpty) return;
    // A little overscan keeps small pans crisp without replacing a patch.
    final requestedRegion = visible
        .inflate(24 / zoom)
        .intersect(Offset.zero & paper);
    final plan = planPageRaster(
      paper: paper,
      devicePixelRatio: _dpr,
      zoom: zoom,
      visible: requestedRegion,
    );
    if (_requestedDetail?.samePixels(plan) ?? false) return;
    if (_detailPlan != null &&
        _detail != null &&
        _detailPlan!.fullWidth >= plan.fullWidth &&
        _detailPlan!.logicalRect.contains(visible.topLeft) &&
        _detailPlan!.logicalRect.contains(
          visible.bottomRight - const Offset(.01, .01),
        )) {
      return;
    }
    unawaited(_render(plan, detail: true));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_paper != size) {
        _clearDetail();
        _paper = size;
      }
      _dpr = MediaQuery.devicePixelRatioOf(context);
      _schedule();
      return SizedBox.expand(
        key: _paperKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_base != null)
              RawImage(
                image: _base,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              )
            else
              Center(
                child: _error == null
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Text(_error!),
              ),
            if (_detail != null && _detailPlan != null)
              Positioned.fromRect(
                rect: _detailPlan!.logicalRect,
                child: RawImage(
                  image: _detail,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              ),
          ],
        ),
      );
    },
  );
}
