import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/reader_icons.dart';
import '../theme/tokens.dart';

enum ReaderTool { pen, highlighter, eraser }

extension ReaderToolAppearance on ReaderTool {
  String get label => switch (this) {
    ReaderTool.pen => '画笔',
    ReaderTool.highlighter => '荧光笔',
    ReaderTool.eraser => '橡皮',
  };
  IconData get icon => switch (this) {
    ReaderTool.pen => Icons.edit,
    ReaderTool.highlighter => Icons.highlight,
    ReaderTool.eraser => Icons.auto_fix_normal,
  };
  ReaderGlyph get glyph => switch (this) {
    ReaderTool.pen => ReaderGlyph.pen,
    ReaderTool.highlighter => ReaderGlyph.highlighter,
    ReaderTool.eraser => ReaderGlyph.eraser,
  };
  double get minSize => this == ReaderTool.pen ? 1 : 4;
  double get maxSize => this == ReaderTool.highlighter ? 64 : 48;
}

class ReaderToolButton extends StatelessWidget {
  const ReaderToolButton({
    super.key,
    required this.tool,
    required this.selected,
    required this.value,
    required this.onSelect,
    this.buttonWidth = 92,
    this.buttonHeight = 44,
    this.iconOnly = false,
  });
  final ReaderTool tool;
  final bool selected;
  final double value;
  final VoidCallback onSelect;
  final double buttonWidth;
  final double buttonHeight;
  final bool iconOnly;
  @override
  Widget build(BuildContext context) {
    final compactButton = Size(buttonWidth, buttonHeight);
    final tokens = ScoreTokens.of(context);
    final foreground = selected
        ? tokens.pine
        : Theme.of(context).colorScheme.onSurface;
    final background = selected
        ? tokens.pineWash
        : iconOnly
        ? tokens.paper2.withValues(alpha: .4)
        : Colors.transparent;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return SizedBox(
      width: buttonWidth,
      height: buttonHeight,
      child: Semantics(
        button: true,
        label: tool.label,
        selected: selected,
        value: value.toStringAsFixed(1),
        onTap: onSelect,
        child: Tooltip(
          message: tool.label,
          child: iconOnly
              ? IconButton(
                  onPressed: onSelect,
                  icon: ReaderIcon(tool.glyph, size: 22),
                  style: IconButton.styleFrom(
                    fixedSize: compactButton,
                    minimumSize: compactButton,
                    maximumSize: compactButton,
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: background,
                    foregroundColor: foreground,
                    shape: shape,
                  ),
                )
              : TextButton.icon(
                  onPressed: onSelect,
                  icon: ReaderIcon(tool.glyph, size: 22),
                  label: Text(
                    tool.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: TextButton.styleFrom(
                    fixedSize: compactButton,
                    minimumSize: compactButton,
                    maximumSize: compactButton,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: background,
                    foregroundColor: foreground,
                    shape: shape,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A direct horizontal adjustment confined to its own 56 × 44 touch target.
/// Updates preview immediately; one release creates one committed change.
class ReaderSizeButton extends StatefulWidget {
  const ReaderSizeButton({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
    required this.label,
    this.tool = ReaderTool.pen,
    this.color,
    this.textMode = false,
  }) : assert(min < max);

  final double value, min, max;
  final ValueChanged<double>? onChanged, onChangeEnd;
  final String label;
  final ReaderTool tool;
  final Color? color;
  final bool textMode;

  @override
  State<ReaderSizeButton> createState() => _ReaderSizeButtonState();
}

class _ReaderSizeButtonState extends State<ReaderSizeButton> {
  final _focus = FocusNode();
  double? _preview, _start;
  double _dragValue = 0;
  bool _focused = false;
  bool get _enabled => widget.onChanged != null;
  double get _value => (_preview ?? widget.value).clamp(widget.min, widget.max);
  double get _step => widget.textMode ? 1 / 1024 : .5;
  String _format(double value) => widget.textMode
      ? (value * 1024).toStringAsFixed(0)
      : value.toStringAsFixed(1);
  String get _formatted => _format(_value);

  void _update(double value) {
    final next = ((value / _step).round() * _step).clamp(
      widget.min,
      widget.max,
    );
    if (next == _value) return;
    setState(() => _preview = next);
    widget.onChanged?.call(next);
  }

  void _nudge(double direction) {
    final before = _value;
    _update(before + direction * _step);
    if (_value != before) widget.onChangeEnd?.call(_value);
    setState(() => _preview = null);
  }

  void _finish() {
    final value = _value;
    final changed = _start != null && value != _start;
    _start = null;
    if (changed) widget.onChangeEnd?.call(value);
    setState(() => _preview = null);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = ScoreTokens.of(context);
    final foreground = widget.color ?? scheme.onSurface;
    return Semantics(
      label: widget.label,
      value: _formatted,
      enabled: _enabled,
      increasedValue: _format((_value + _step).clamp(widget.min, widget.max)),
      decreasedValue: _format((_value - _step).clamp(widget.min, widget.max)),
      onIncrease: _enabled ? () => _nudge(1) : null,
      onDecrease: _enabled ? () => _nudge(-1) : null,
      child: Focus(
        focusNode: _focus,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (_, event) {
          if (!_enabled ||
              (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.arrowUp) {
            _nudge(1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowDown) {
            _nudge(-1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Tooltip(
          message: '${widget.label}：按住左右拖动调整',
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _enabled ? _focus.requestFocus : null,
              onHorizontalDragStart: !_enabled
                  ? null
                  : (_) {
                      _focus.requestFocus();
                      _start = _value;
                      _dragValue = _value;
                      setState(() => _preview = _value);
                    },
              onHorizontalDragUpdate: !_enabled
                  ? null
                  : (details) {
                      _dragValue =
                          (_dragValue +
                                  details.delta.dx *
                                      (widget.max - widget.min) /
                                      160)
                              .clamp(widget.min, widget.max);
                      _update(_dragValue);
                    },
              onHorizontalDragEnd: !_enabled ? null : (_) => _finish(),
              onHorizontalDragCancel: !_enabled
                  ? null
                  : () {
                      final start = _start;
                      _start = null;
                      if (start != null) widget.onChanged?.call(start);
                      setState(() => _preview = null);
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: 56,
                height: 44,
                decoration: BoxDecoration(
                  color: _start != null
                      ? tokens.pineWash
                      : tokens.paper2.withValues(alpha: .4),
                  borderRadius: BorderRadius.circular(10),
                  border: _focused
                      ? Border.all(color: scheme.primary, width: 1)
                      : null,
                ),
                child: Opacity(
                  opacity: _enabled ? 1 : .38,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: widget.textMode
                              ? Center(
                                  child: Text(
                                    'A',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium,
                                  ),
                                )
                              : CustomPaint(
                                  painter: ReaderToolSizePreview(
                                    widget.tool,
                                    _value,
                                    foreground,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatted,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderToolSizePreview extends CustomPainter {
  ReaderToolSizePreview(this.tool, this.value, this.color);
  final ReaderTool tool;
  final double value;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round;
    if (tool == ReaderTool.eraser) {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 1.5;
      canvas.drawCircle(
        size.center(Offset.zero),
        (value / 2).clamp(2.0, (size.shortestSide / 2 - 1).clamp(2.0, 14.0)),
        paint,
      );
    } else {
      paint.strokeWidth = (value / 2).clamp(
        1.0,
        (size.height - 2).clamp(1.0, 24.0),
      );
      canvas.drawLine(
        Offset((size.width * .2).clamp(0.0, 10.0), size.height / 2),
        Offset(
          size.width - (size.width * .2).clamp(0.0, 10.0),
          size.height / 2,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(ReaderToolSizePreview old) =>
      old.tool != tool || old.value != value || old.color != color;
}

/// The last successful sample belongs to the eyedropper, independently of the
/// active palette color. Its fine underline shows the last sampled color.
class ReaderSampleColorButton extends StatelessWidget {
  const ReaderSampleColorButton({
    super.key,
    required this.sample,
    required this.picking,
    required this.busy,
    required this.usingSample,
    required this.onPressed,
  });
  final bool picking, busy;
  final Color? sample;
  final bool usingSample;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = picking ? '取消吸色' : '吸取谱面底色';
    return Semantics(
      button: true,
      selected: picking,
      label: label,
      value: sample == null
          ? '尚未吸色'
          : usingSample
          ? '正在使用最近吸取的颜色'
          : '最近吸取的颜色可复用',
      onTap: onPressed,
      child: ExcludeSemantics(
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          isSelected: picking,
          style: IconButton.styleFrom(
            fixedSize: const Size(44, 44),
            minimumSize: const Size(44, 44),
            maximumSize: const Size(44, 44),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: picking
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: SizedBox.square(
            dimension: 28,
            child: Stack(
              children: [
                const Positioned(
                  top: 0,
                  left: 2,
                  child: ReaderIcon(ReaderGlyph.eyedropper, size: 24),
                ),
                Positioned(
                  left: 5,
                  right: 5,
                  bottom: 0,
                  child: Container(
                    key: const ValueKey('reader-sample-underline'),
                    height: 3,
                    decoration: BoxDecoration(
                      color:
                          sample ??
                          Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline
                            .withValues(alpha: .45),
                        width: .5,
                      ),
                    ),
                  ),
                ),
                if (busy)
                  const Positioned.fill(
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderSampleReuseButton extends StatelessWidget {
  const ReaderSampleReuseButton({
    super.key,
    required this.sample,
    required this.selected,
    required this.onPressed,
  });
  final Color? sample;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = sample == null ? '等待吸取底色' : '使用最近吸取的底色';
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: IconButton(
            key: const ValueKey('reader-sampled-color'),
            onPressed: onPressed,
            isSelected: selected,
            style: IconButton.styleFrom(
              fixedSize: const Size(44, 44),
              minimumSize: const Size(44, 44),
              maximumSize: const Size(44, 44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: selected
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: SizedBox.square(
              dimension: 28,
              child: Container(
                key: const ValueKey('sample-color-swatch'),
                decoration: BoxDecoration(
                  color: sample ?? ScoreTokens.of(context).paper2,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                    width: 1,
                  ),
                ),
                child: sample == null
                    ? const Icon(
                        Icons.remove,
                        key: ValueKey('sample-color-empty'),
                        size: 14,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
