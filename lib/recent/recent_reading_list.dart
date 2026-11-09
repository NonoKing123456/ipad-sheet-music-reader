import 'package:flutter/material.dart';
import 'package:library_core/library_core.dart' show physicalFileDisplayName;
import 'package:path/path.dart' as p;

import '../library/library_widgets.dart';
import '../library/score_file_icon.dart';
import '../theme/reader_icons.dart';
import '../theme/tokens.dart';
import 'recent_reading_store.dart';

enum RecentAvailability { ready, cloud, missing }

class RecentDisplay {
  const RecentDisplay(
    this.path,
    this.contextLabel,
    this.availability, {
    this.revisionId,
  });
  final String path, contextLabel;
  final RecentAvailability availability;
  final String? revisionId;
}

class RecentNavigationItem extends StatelessWidget {
  const RecentNavigationItem({
    super.key,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });
  final bool selected, compact;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: ScoreRadius.controlAll,
          child: SizedBox(
            height: ScoreLayout.touchTarget,
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: compact ? ScoreSpace.xs : 0,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected
                      ? t.pineWash
                      : (compact ? t.paper0 : Colors.transparent),
                  borderRadius: ScoreRadius.controlAll,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? ScoreSpace.lg : ScoreSpace.md,
                  ),
                  child: Row(
                    mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                    children: [
                      CustomPaint(
                        size: const Size.square(ScoreLayout.iconVisual),
                        painter: _ClockPainter(selected ? t.pine : t.ink700),
                      ),
                      const SizedBox(width: ScoreSpace.md),
                      Text(
                        '最近阅读',
                        style: ScoreText.body.copyWith(
                          color: selected ? t.pine : t.ink700,
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
    );
  }
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = ScoreLayout.iconStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(10, 10), 7.5, paint);
    canvas.drawPath(
      Path()
        ..moveTo(10, 5.5)
        ..lineTo(10, 10)
        ..lineTo(13, 12),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.color != color;
}

class RecentReadingList extends StatelessWidget {
  const RecentReadingList({
    super.key,
    required this.store,
    required this.resolve,
    required this.onOpen,
    required this.host,
    this.now,
  });
  final RecentReadingStore store;
  final RecentDisplay Function(RecentReading) resolve;
  final void Function(RecentReading, RecentDisplay) onOpen;
  final bool host;
  final DateTime? now;
  String _group(DateTime time) {
    final local = time.toLocal(), current = (now ?? DateTime.now()).toLocal();
    final today = DateTime(current.year, current.month, current.day);
    final date = DateTime(local.year, local.month, local.day);
    if (date == today) return '今天';
    if (date == DateTime(today.year, today.month, today.day - 1)) return '昨天';
    return '更早';
  }

  String _time(RecentReading entry) {
    final time = entry.openedAt.toLocal();
    if (_group(time) == '更早') return '${time.month}月${time.day}日';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final t = ScoreTokens.of(context), rows = <Object>[];
      String? group;
      for (final entry in store.entries) {
        final next = _group(entry.openedAt);
        if (next != group) {
          rows.add(next);
          group = next;
        }
        rows.add(entry);
      }
      return Column(
        key: const ValueKey('recent-reading-list'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ScoreLayout.listMargin,
              vertical: ScoreSpace.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '本机记录 · ${store.entries.length}首',
                    style: ScoreText.caption.copyWith(color: t.ink500),
                  ),
                ),
                Text(
                  '最近打开优先',
                  style: ScoreText.caption.copyWith(color: t.ink500),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ScoreLayout.listMargin,
            ),
            child: _header(context),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '还没有最近阅读',
                          style: ScoreText.headline.copyWith(color: t.ink900),
                        ),
                        const SizedBox(height: ScoreSpace.sm),
                        Text(
                          '从谱库打开一首曲谱后，会在这里显示',
                          style: ScoreText.caption.copyWith(color: t.ink500),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ScoreLayout.listMargin,
                    ),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      if (row is String) {
                        return SizedBox(
                          height: ScoreLayout.columnHeaderHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              row,
                              style: ScoreText.caption.copyWith(
                                color: t.ink500,
                              ),
                            ),
                          ),
                        );
                      }
                      final entry = row as RecentReading,
                          display = resolve(entry);
                      final missing =
                          display.availability == RecentAvailability.missing;
                      final time = _time(entry);
                      final count =
                          display.revisionId == null ||
                              display.revisionId == entry.revisionId
                          ? entry.pageCount
                          : null;
                      return Opacity(
                        opacity: missing ? .5 : 1,
                        child: _RecentFileRow(
                          key: ValueKey('recent-${entry.entryId}'),
                          leading: ScoreFileIcon(
                            path: display.path,
                            showBadge: !host && !missing,
                            state:
                                display.availability == RecentAvailability.cloud
                                ? ScoreFileIconState.cloud
                                : ScoreFileIconState.ready,
                          ),
                          name: physicalFileDisplayName(
                            p.basename(display.path),
                          ),
                          time: host ? time : null,
                          subtitle:
                              '${display.contextLabel}${host ? '' : ' · $time'}${missing ? ' · 文件已不存在' : ''}',
                          metadata: Row(
                            children: [
                              SizedBox(
                                width: ScoreLayout.typeColumn,
                                child: Text(
                                  p
                                      .extension(display.path)
                                      .replaceFirst('.', '')
                                      .toUpperCase(),
                                  style: ScoreText.caption.copyWith(
                                    color: t.ink500,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  count == null ? '—' : '$count 页',
                                  textAlign: TextAlign.right,
                                  style: ScoreText.caption.copyWith(
                                    color: t.ink500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          action: PopupMenuButton<String>(
                            tooltip: '最近阅读选项',
                            icon: const ReaderIcon(ReaderGlyph.more),
                            onSelected: (_) => store.remove(entry.entryId),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('从最近阅读移除'),
                              ),
                            ],
                          ),
                          onTap: () => onOpen(entry, display),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    },
  );
  Widget _header(BuildContext context) {
    if (!host) return const LibraryColumnHeader();
    final style = ScoreText.caption.copyWith(
      color: ScoreTokens.of(context).ink500,
    );
    return SizedBox(
      height: ScoreLayout.columnHeaderHeight,
      child: LibraryColumns(
        leading: const SizedBox.shrink(),
        name: Row(
          children: [
            Expanded(child: Text('名称', style: style)),
            SizedBox(
              width: ScoreLayout.typeColumn + ScoreLayout.actionColumn,
              child: Text('最近打开', style: style),
            ),
          ],
        ),
        metadata: Row(
          children: [
            SizedBox(
              width: ScoreLayout.typeColumn,
              child: Text('类型', style: style),
            ),
            Expanded(
              child: Text('页数', textAlign: TextAlign.right, style: style),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reuses the library columns, tokens and divider geometry, with the desktop
/// time column and a fixed 56dp two-line history row.
class _RecentFileRow extends StatelessWidget {
  const _RecentFileRow({
    super.key,
    required this.leading,
    required this.name,
    required this.subtitle,
    required this.metadata,
    required this.action,
    required this.onTap,
    this.time,
  });
  final Widget leading, metadata, action;
  final String name, subtitle;
  final String? time;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: t.paper0,
        borderRadius: ScoreRadius.controlAll,
        child: SizedBox(
          height: ScoreLayout.fileRowHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: LibraryColumns(
                  leading: leading,
                  name: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: ScoreSpace.md),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                message: name,
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ScoreText.headline.copyWith(
                                    color: t.ink900,
                                  ),
                                ),
                              ),
                              const SizedBox(
                                height: ScoreLayout.rowSubtitleGap,
                              ),
                              Tooltip(
                                message: subtitle,
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ScoreText.caption.copyWith(
                                    color: t.ink500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (time != null)
                        SizedBox(
                          width:
                              ScoreLayout.typeColumn + ScoreLayout.actionColumn,
                          child: Text(
                            time!,
                            style: ScoreText.caption.copyWith(color: t.ink500),
                          ),
                        ),
                    ],
                  ),
                  metadata: metadata,
                  action: action,
                ),
              ),
              Positioned(
                left: ScoreLayout.rowDividerInsetStart,
                right: ScoreLayout.rowDividerInsetEnd,
                bottom: 0,
                child: Container(
                  height: ScoreLayout.rowDividerThickness,
                  color: t.hair2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
