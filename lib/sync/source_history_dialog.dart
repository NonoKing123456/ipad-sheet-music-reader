import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'sync_controller.dart';

Future<void> showSourceHistoryDialog(
  BuildContext context, {
  required SyncController controller,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: ScoreTokens.of(context).paper0,
    insetPadding: const EdgeInsets.all(ScoreSpace.lg),
    shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.overlayAll),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: ScoreLayout.sheetWidth,
        maxHeight: ScoreLayout.sheetMaxHeight,
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final tokens = ScoreTokens.of(context);
          final entries = controller.offlineMissingEntries;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.xl),
                child: Text(
                  '历史源记录',
                  style: ScoreText.title.copyWith(color: tokens.ink900),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.xl),
                child: Text(
                  '最近目录更新时未找到这些源路径，可能已移除、移动或改名，具体原因未确认。这些历史记录不代表下载失败。',
                  style: ScoreText.caption.copyWith(color: tokens.ink500),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.xl),
                child: Text(
                  '${entries.length} 项 · 已移出当前目录',
                  style: ScoreText.caption.copyWith(
                    color: tokens.ink500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(
                // Keep large historical catalogs lazy, including the source
                // lookup. Do not materialize a snapshot or join every path.
                child: ListView.builder(
                  key: const ValueKey('source-history-list'),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Container(
                      key: ValueKey('source-history-${entry.id}'),
                      margin: const EdgeInsets.symmetric(
                        horizontal: ScoreSpace.xl,
                      ),
                      padding: const EdgeInsets.symmetric(
                        vertical: ScoreSpace.md,
                      ),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: tokens.hair2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            controller.sourceNameFor(entry.id),
                            style: ScoreText.caption.copyWith(
                              color: tokens.ink500,
                            ),
                          ),
                          const SizedBox(height: ScoreSpace.xs),
                          SelectableText(
                            entry.relativePath,
                            style: ScoreText.body.copyWith(
                              color: tokens.ink900,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(ScoreSpace.lg),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);
