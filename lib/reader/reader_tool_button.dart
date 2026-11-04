import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

/// The same press feedback and target geometry are shared by reader controls.
class ReaderActionButton extends StatefulWidget {
  const ReaderActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.tool = false,
    this.caption,
    this.width,
    this.target = ScoreLayout.touchTarget,
  });
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool selected, tool;
  final String? caption;
  final double? width;
  final double target;
  @override
  State<ReaderActionButton> createState() => _ReaderActionButtonState();
}

class _ReaderActionButtonState extends State<ReaderActionButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final foreground = widget.selected
        ? widget.tool
              ? t.onBrand
              : t.pineDeep
        : t.ink700;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      enabled: widget.onPressed != null,
      child: Tooltip(
        message: widget.label,
        child: Listener(
          onPointerDown: widget.onPressed == null
              ? null
              : (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? ScoreMotion.pressScale : 1,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : ScoreMotion.micro,
            child: SizedBox(
              width: widget.width ?? widget.target,
              height: widget.target,
              child: TextButton(
                onPressed: widget.onPressed,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: foreground,
                  disabledForegroundColor: t.ink300,
                  backgroundColor: widget.selected
                      ? widget.tool
                            ? t.pine
                            : t.pineWash
                      : Colors.transparent,
                  overlayColor: t.pineWash,
                  splashFactory: NoSplash.splashFactory,
                  shape: const RoundedRectangleBorder(
                    borderRadius: ScoreRadius.controlAll,
                  ),
                  textStyle: Theme.of(context).textTheme.labelLarge,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      widget.icon,
                      if (widget.caption != null) ...[
                        const SizedBox(width: ScoreSpace.sm),
                        Text(widget.caption!),
                      ],
                    ],
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

class ReaderToolButton extends StatelessWidget {
  const ReaderToolButton({
    super.key,
    required this.tool,
    required this.selected,
    required this.value,
    required this.onSelect,
    this.buttonWidth = ScoreLayout.touchTarget,
    this.buttonHeight = ScoreLayout.touchTarget,
    this.iconOnly = true,
  });
  final ReaderTool tool;
  final bool selected;
  final double value;
  final VoidCallback onSelect;
  final double buttonWidth, buttonHeight;
  final bool iconOnly;
  @override
  Widget build(BuildContext context) => ReaderActionButton(
    label: tool.label,
    icon: ReaderIcon(tool.glyph, size: ScoreLayout.iconVisual),
    onPressed: onSelect,
    selected: selected,
    tool: true,
    target: buttonHeight,
    width: buttonWidth,
    caption: iconOnly ? null : tool.label,
  );
}

/// Direct horizontal adjustment: 20dp changes one displayed size unit.
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
  double get _step => widget.textMode ? 1 / 1024 : .1;
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
    final foreground = tokens.ink900;
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
              dragStartBehavior: DragStartBehavior.down,
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
                                  details.delta.dx /
                                      ScoreLayout.readerSizePixelsPerUnit *
                                      (widget.textMode ? 1 / 1024 : 1))
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
                duration: ScoreMotion.micro,
                width: ScoreLayout.readerSizeWidth,
                height: ScoreLayout.touchTarget,
                decoration: BoxDecoration(
                  color: _start != null ? tokens.pineWash : Colors.transparent,
                  borderRadius: ScoreRadius.controlAll,
                  border: _focused
                      ? Border.all(color: scheme.primary, width: 1)
                      : null,
                ),
                child: Opacity(
                  opacity: _enabled ? 1 : .38,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ScoreLayout.readerSizePadding,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: ScoreSpace.lg,
                          height: ScoreSpace.lg,
                          child: CustomPaint(
                            painter: ReaderToolSizePreview(
                              widget.tool,
                              widget.textMode ? 3 : _value,
                              foreground,
                            ),
                          ),
                        ),
                        const SizedBox(width: ScoreSpace.xs),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatted,
                              style: ScoreText.caption.copyWith(
                                color: tokens.ink500,
                              ),
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

/// The only sampled-color slot sits directly on the eyedropper icon.
class ReaderSampleColorButton extends StatelessWidget {
  const ReaderSampleColorButton({
    super.key,
    required this.sample,
    required this.picking,
    required this.busy,
    required this.usingSample,
    required this.onPressed,
  });
  final bool picking, busy, usingSample;
  final Color? sample;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => ReaderActionButton(
    label: picking ? '取消吸色' : '吸取谱面底色',
    selected: picking,
    tool: true,
    onPressed: onPressed,
    icon: SizedBox.square(
      dimension: ScoreLayout.readerSampleStack,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(
            top: 2,
            left: 0,
            child: ReaderIcon(
              ReaderGlyph.eyedropper,
              size: ScoreLayout.iconVisual,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              key: const ValueKey('reader-sample-swatch'),
              width: ScoreLayout.readerSampleVisual,
              height: ScoreLayout.readerSampleVisual,
              decoration: BoxDecoration(
                color: sample ?? Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: ScoreTokens.of(context).ink500,
                  width: .75,
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
  );
}

/// Kept for callers outside the reader; the v2 bar exposes no second sample slot.
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
  Widget build(BuildContext context) => ReaderActionButton(
    label: '使用最近吸取的底色',
    selected: selected,
    onPressed: onPressed,
    icon: Container(
      width: ScoreSpace.xl,
      height: ScoreSpace.xl,
      decoration: BoxDecoration(color: sample, shape: BoxShape.circle),
    ),
  );
}

class ReaderPaletteButton extends StatefulWidget {
  const ReaderPaletteButton({
    super.key,
    required this.argb,
    required this.onChanged,
    this.onMenuChanged,
  });
  final int argb;
  final ValueChanged<int>? onChanged;
  final ValueChanged<bool>? onMenuChanged;
  @override
  State<ReaderPaletteButton> createState() => _ReaderPaletteButtonState();
}

class _ReaderPaletteButtonState extends State<ReaderPaletteButton> {
  final _menu = MenuController();
  int get argb => widget.argb;
  ValueChanged<int>? get onChanged => widget.onChanged;
  // Content colors stay independent from the app's light/dark shell.
  static const colors = [
    0xff17201c,
    0xffc9432d,
    0xff236459,
    0xff1c57ac,
    0xffe5b33c,
    0xffa26f91,
    0xfffbfaf6,
    0xff805c3b,
  ];
  Widget _dot(BuildContext context, int color, {bool selected = false}) =>
      Container(
        width: ScoreLayout.readerColorVisual,
        height: ScoreLayout.readerColorVisual,
        padding: const EdgeInsets.all(ScoreLayout.readerColorInset),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? ScoreTokens.of(context).pine
                : ScoreTokens.of(context).hair,
            width: 1,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
          ),
        ),
      );
  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _menu,
    onOpen: () => widget.onMenuChanged?.call(true),
    onClose: () => widget.onMenuChanged?.call(false),
    style: const MenuStyle(padding: WidgetStatePropertyAll(EdgeInsets.zero)),
    menuChildren: [
      SizedBox(
        width: ScoreLayout.paletteWidth,
        child: Padding(
          padding: const EdgeInsets.all(ScoreSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var row = 0; row < 2; row++)
                Row(
                  children: [
                    for (var col = 0; col < ScoreLayout.paletteColumns; col++)
                      ReaderActionButton(
                        label:
                            '颜色 ${row * ScoreLayout.paletteColumns + col + 1}',
                        icon: _dot(
                          context,
                          colors[row * ScoreLayout.paletteColumns + col],
                          selected:
                              argb ==
                              colors[row * ScoreLayout.paletteColumns + col],
                        ),
                        onPressed: onChanged == null
                            ? null
                            : () {
                                _menu.close();
                                onChanged!(
                                  colors[row * ScoreLayout.paletteColumns +
                                      col],
                                );
                              },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ],
    builder: (context, controller, _) => ReaderActionButton(
      label: '颜色',
      icon: _dot(context, argb),
      onPressed: onChanged == null
          ? null
          : () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}
