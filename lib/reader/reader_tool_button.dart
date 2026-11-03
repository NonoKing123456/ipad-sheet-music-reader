import 'package:flutter/material.dart';

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
    final foreground = selected
        ? Theme.of(context).colorScheme.onSecondaryContainer
        : Theme.of(context).colorScheme.onSurface;
    final background = selected
        ? Theme.of(context).colorScheme.secondaryContainer
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
                  icon: Icon(tool.icon, size: 18),
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
                  icon: Icon(tool.icon, size: 19),
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
        (value / 2).clamp(2.0, 14.0),
        paint,
      );
    } else {
      paint.strokeWidth = (value / 2).clamp(1.0, 24.0);
      canvas.drawLine(
        Offset(10, size.height / 2),
        Offset(size.width - 10, size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(ReaderToolSizePreview old) =>
      old.tool != tool || old.value != value || old.color != color;
}

/// The last successful sample belongs to the eyedropper, independently of the
/// active palette color. An empty swatch has a slash; white samples have a rim.
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
                const Center(child: Icon(Icons.colorize, size: 22)),
                if (picking)
                  const Positioned(
                    right: 0,
                    top: 0,
                    child: Icon(Icons.add_circle, size: 11),
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
