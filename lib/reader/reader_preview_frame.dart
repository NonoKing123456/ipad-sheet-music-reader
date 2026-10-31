import 'package:flutter/material.dart';
import 'reader_stage.dart';

/// A desktop layout preview; orientation changes the viewport, not page data.
class ReaderPreviewFrame extends StatelessWidget {
  const ReaderPreviewFrame({
    super.key,
    required this.enabled,
    required this.landscape,
    required this.child,
  });

  final bool enabled;
  final bool landscape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !canPreviewReader) return child;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: AspectRatio(
          key: const ValueKey('tablet-preview-viewport'),
          aspectRatio: landscape ? 4 / 3 : 3 / 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xff263b35), width: 7),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
