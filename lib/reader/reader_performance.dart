import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reader_state/reader_state.dart';

import '../theme/tokens.dart';

class ReaderProgramPanel extends StatefulWidget {
  const ReaderProgramPanel({
    super.key,
    required this.name,
    required this.items,
    required this.currentId,
    required this.titleFor,
    required this.onSelect,
    this.pendingId,
    this.errorId,
    this.error,
  });

  final String name;
  final List<SetListItem> items;
  final String? currentId, pendingId, errorId, error;
  final String Function(SetListItem) titleFor;
  final ValueChanged<SetListItem> onSelect;

  @override
  State<ReaderProgramPanel> createState() => _ReaderProgramPanelState();
}

class _ReaderProgramPanelState extends State<ReaderProgramPanel> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    final extent =
        ScoreLayout.programRowHeight *
        (MediaQuery.textScalerOf(context).scale(17) / 17).clamp(
          1.0,
          double.infinity,
        );
    final index = widget.items.indexWhere(
      (item) => item.id == widget.currentId,
    );
    _scroll ??= ScrollController(
      initialScrollOffset: (index > 1 ? index - 1 : 0) * extent,
    );
    return Material(
      color: t.paper0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: t.hair)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(ScoreSpace.xl),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ScoreText.display.copyWith(color: t.ink900),
                    ),
                  ),
                  const SizedBox(width: ScoreSpace.sm),
                  Text(
                    '${widget.items.length} 首',
                    style: ScoreText.caption.copyWith(color: t.ink500),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                controller: _scroll,
                itemExtent: extent,
                itemCount: widget.items.length,
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  final selected = item.id == widget.currentId;
                  final title = widget.titleFor(item);
                  final error = widget.errorId == item.id ? widget.error : null;
                  return Semantics(
                    selected: selected,
                    button: true,
                    child: Ink(
                      color: selected ? t.pineWash : null,
                      child: InkWell(
                        key: ValueKey(('reader-program-item', item.id)),
                        onTap: widget.pendingId == null
                            ? () => widget.onSelect(item)
                            : null,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 3,
                              height: 26,
                              child: selected
                                  ? ColoredBox(color: t.pine)
                                  : null,
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ScoreSpace.xl,
                              ),
                              child: Text(
                                (index + 1).toString().padLeft(2, '0'),
                                style: ScoreText.caption.copyWith(
                                  color: selected ? t.pineDeep : t.ink500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: t.hair2),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            maxLines: error == null ? 2 : 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ScoreText.headline.copyWith(
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              color: selected
                                                  ? t.pineDeep
                                                  : t.ink900,
                                            ),
                                          ),
                                          if (error != null)
                                            Text(
                                              error,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: ScoreText.caption.copyWith(
                                                color: t.dangerInk,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (selected ||
                                        error != null ||
                                        widget.pendingId == item.id)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: ScoreSpace.sm,
                                        ),
                                        child: Text(
                                          selected
                                              ? '在读'
                                              : error != null
                                              ? '重试'
                                              : '打开中',
                                          style: ScoreText.caption.copyWith(
                                            color: t.pineDeep,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: ScoreSpace.xl),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReaderTurnFolio extends StatefulWidget {
  const ReaderTurnFolio({super.key, required this.page, required this.count});
  final int page, count;
  @override
  State<ReaderTurnFolio> createState() => _ReaderTurnFolioState();
}

class _ReaderTurnFolioState extends State<ReaderTurnFolio>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: ScoreMotion.micro,
    value: 1,
  );
  late final Timer _hold;
  @override
  void initState() {
    super.initState();
    _hold = Timer(ScoreMotion.pageNumberHold, () {
      if (MediaQuery.disableAnimationsOf(context)) {
        _fade.value = 0;
      } else {
        _fade.reverse();
      }
    });
  }

  @override
  void dispose() {
    _hold.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Score paper keeps its own colours across app themes.
    const colors = ScoreTokens.light;
    const shadows = [Shadow(color: Colors.white, blurRadius: 2)];
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _fade,
          child: Text.rich(
            TextSpan(
              text: '${widget.page}',
              style: ScoreText.title.copyWith(
                color: colors.ink700,
                shadows: shadows,
              ),
              children: [
                TextSpan(
                  text: ' / ${widget.count}',
                  style: ScoreText.caption.copyWith(
                    color: colors.ink500,
                    shadows: shadows,
                  ),
                ),
              ],
            ),
          ),
          builder: (context, child) {
            if (_fade.isDismissed) return const SizedBox.shrink();
            return Opacity(opacity: _fade.value, child: child);
          },
        ),
      ),
    );
  }
}
