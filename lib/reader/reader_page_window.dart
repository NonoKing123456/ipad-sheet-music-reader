import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Only the current page and its two immediate neighbours stay mounted.
class ReaderPageWindow extends StatelessWidget {
  const ReaderPageWindow({
    super.key,
    required this.pageNumber,
    required this.pageCount,
    required this.aspectFor,
    required this.pageBuilder,
  });

  final int pageNumber;
  final int pageCount;
  final double Function(int) aspectFor;
  final Widget Function(int) pageBuilder;

  @override
  Widget build(BuildContext context) {
    final first = math.max(1, pageNumber - 1);
    final last = math.min(pageCount, pageNumber + 1);
    return IndexedStack(
      index: pageNumber - first,
      sizing: StackFit.expand,
      children: [
        for (var number = first; number <= last; number++)
          Center(
            key: ValueKey(number),
            child: AspectRatio(
              aspectRatio: aspectFor(number),
              child: pageBuilder(number),
            ),
          ),
      ],
    );
  }
}
