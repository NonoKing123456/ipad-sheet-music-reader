import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/tokens.dart';

class DirectorySearchField extends StatelessWidget {
  const DirectorySearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('directory-search-input'),
    controller: controller,
    focusNode: focusNode,
    onChanged: onChanged,
    decoration: const InputDecoration(
      hintText: '搜索曲名、谱库或文件夹',
      border: InputBorder.none,
      isDense: true,
    ),
  );
}

/// 当前目录的唯一权威显示位置。
///
/// 旧实现把「我在哪」和「返回上一级」压进同一个按钮，并且只显示**父级**名字，
/// 于是当前目录只能靠每行副标题去拼。这里拆成两件事：
/// 左侧是动作（48×48 返回上级），右侧是身份（完整路径面包屑，当前段加粗）。
///
/// 分段规则见 DESIGN.md §5.1：空间足够时完整展示，仅按实际文字宽度折叠最少中段，
/// 优先保留根、最近父目录与当前段，窄宽文字省略时保留完整 Tooltip。
class DirectoryBreadcrumbs extends StatelessWidget {
  const DirectoryBreadcrumbs({
    super.key,
    required this.rootLabel,
    required this.currentPath,
    this.onNavigate,
    this.trailing,
  });

  /// 根的名字，通常是谱库来源名（"我的 iPad" / "本地文件夹"）。
  final String rootLabel;

  /// 相对来源根的 posix 路径，'' 表示根目录。
  final String currentPath;

  /// 跳转到某个祖先目录；传入的路径同样相对来源根，'' 表示根。
  final ValueChanged<String>? onNavigate;

  final Widget? trailing;

  static const double barHeight = ScoreSpace.huge;

  /// 每一段都是整条高度，命中区在 iPad 上也够大。
  static const double _crumbHeight = barHeight;

  List<_Crumb> _crumbs() {
    final crumbs = <_Crumb>[_Crumb(label: rootLabel, path: '')];
    var path = '';
    for (final segment in currentPath.split('/')) {
      if (segment.isEmpty) continue;
      path = path.isEmpty ? segment : '$path/$segment';
      crumbs.add(_Crumb(label: segment, path: path));
    }
    return crumbs;
  }

  String get _fullLabel =>
      currentPath.isEmpty ? '$rootLabel · 根目录' : '$rootLabel/$currentPath';

  String get _parentPath {
    final index = currentPath.lastIndexOf('/');
    return index < 0 ? '' : currentPath.substring(0, index);
  }

  String get _parentLabel => currentPath.isEmpty
      ? rootLabel
      : (_parentPath.isEmpty ? rootLabel : p.posix.basename(_parentPath));

  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    final crumbs = _crumbs();
    final separator = Icon(Icons.chevron_right, size: 14, color: tokens.ink300);
    final rootIcon = Icon(
      Icons.folder_outlined,
      size: ScoreText.body.fontSize,
      color: onNavigate == null ? tokens.ink300 : tokens.ink500,
    );

    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble();
      painter.dispose();
      return width;
    }

    final padding = ScoreSpace.sm + ScoreSpace.sm;
    final natural = [
      for (var i = 0; i < crumbs.length; i++)
        math.max(
          ScoreSpace.huge,
          measure(
                crumbs[i].label,
                ScoreText.caption.copyWith(
                  fontWeight: i == crumbs.length - 1
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ) +
              padding +
              (i == 0 && crumbs.length > 1
                  ? rootIcon.size! + ScoreSpace.xs
                  : 0),
        ),
    ];
    final menuWidth = math.max(
      ScoreSpace.huge,
      measure('…', ScoreText.caption) + padding,
    );

    Widget trailFor(double available) {
      var hiddenCount = 0;
      List<int> visible() => [
        0,
        for (var i = hiddenCount + 1; i < crumbs.length; i++) i,
      ];
      double extent(List<int> indices) =>
          indices.fold(0.0, (n, i) => n + natural[i]) +
          (hiddenCount > 0 ? menuWidth : 0) +
          (indices.length - 1 + (hiddenCount > 0 ? 1 : 0)) * separator.size!;
      var indices = visible();
      // Preserve root, current and the nearest parent as long as their whole
      // controls fit. Hide only the earliest middle prefix needed by width.
      while (extent(indices) > available && hiddenCount < crumbs.length - 3) {
        hiddenCount++;
        indices = visible();
      }
      double minimumExtent() =>
          indices.length * ScoreSpace.huge +
          (hiddenCount > 0 ? menuWidth : 0) +
          (indices.length - 1 + (hiddenCount > 0 ? 1 : 0)) * separator.size!;
      while (minimumExtent() > available && hiddenCount < crumbs.length - 2) {
        hiddenCount++;
        indices = visible();
      }
      final hidden = crumbs.sublist(1, hiddenCount + 1);
      final widths = {for (final i in indices) i: natural[i]};
      var excess = math.max(0.0, extent(indices) - available);
      // Long outer labels get bounded text, never partially clipped controls.
      // The current directory is the last label reduced and has a full tooltip.
      final budget = math.max(
        0.0,
        available -
            (hidden.isEmpty ? 0 : menuWidth) -
            (indices.length - 1 + (hidden.isEmpty ? 0 : 1)) * separator.size!,
      );
      final minimumLabel = math.min(ScoreSpace.huge, budget / indices.length);
      for (final i in indices) {
        final reduction = math.min(
          excess,
          math.max(0.0, widths[i]! - minimumLabel),
        );
        widths[i] = widths[i]! - reduction;
        excess -= reduction;
      }
      final trail = <Widget>[];
      for (var slot = 0; slot < indices.length; slot++) {
        final i = indices[slot], crumb = crumbs[i];
        if (slot > 0) trail.add(separator);
        if (i == crumbs.length - 1) {
          trail.add(
            SizedBox(
              width: widths[i],
              child: Tooltip(
                message: currentPath.isEmpty
                    ? '$rootLabel · 根目录'
                    : '$rootLabel/$currentPath',
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ScoreSpace.sm,
                  ),
                  child: Text(
                    crumb.label,
                    key: const ValueKey('directory-breadcrumb-current'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScoreText.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: tokens.ink900,
                    ),
                  ),
                ),
              ),
            ),
          );
        } else {
          trail.add(
            _CrumbButton(
              crumb: crumb,
              tooltip: crumb.path.isEmpty ? '$rootLabel · 根目录' : crumb.path,
              leading: i == 0 ? rootIcon : null,
              width: widths[i]!,
              onTap: onNavigate == null ? null : () => onNavigate!(crumb.path),
            ),
          );
        }
        if (slot == 0) {
          if (hidden.isNotEmpty) trail.add(separator);
          // Retain the menu state across resize while removing all hit/visual
          // space when expanded. A pending selection carries its original path.
          trail.add(
            Offstage(
              key: const ValueKey('directory-overflow-slot'),
              offstage: hidden.isEmpty,
              child: _OverflowMenu(
                crumbs: hidden,
                onSelected: onNavigate,
                width: menuWidth,
              ),
            ),
          );
        }
      }
      return SingleChildScrollView(
        key: ValueKey((rootLabel, currentPath)),
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: available),
          child: Row(mainAxisSize: MainAxisSize.min, children: trail),
        ),
      );
    }

    return SizedBox(
      height: barHeight,
      child: Row(
        children: [
          Tooltip(
            message: currentPath.isEmpty ? '已在根目录' : '返回上一级：$_parentLabel',
            child: IconButton(
              key: const ValueKey('directory-parent-button'),
              style: IconButton.styleFrom(
                fixedSize: const Size.square(ScoreSpace.huge),
                minimumSize: const Size.square(ScoreSpace.huge),
                maximumSize: const Size.square(ScoreSpace.huge),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: currentPath.isEmpty || onNavigate == null
                  ? null
                  : () => onNavigate!(_parentPath),
              icon: Icon(
                currentPath.isEmpty
                    ? Icons.folder_outlined
                    : Icons.arrow_upward,
                size: 22,
                color: currentPath.isEmpty ? tokens.ink300 : tokens.ink700,
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              container: true,
              label: '当前目录：$_fullLabel',
              child: Material(
                type: MaterialType.transparency,
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      trailFor(constraints.maxWidth),
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Crumb {
  const _Crumb({required this.label, required this.path});
  final String label;
  final String path;
}

class _CrumbButton extends StatelessWidget {
  const _CrumbButton({
    required this.crumb,
    required this.tooltip,
    required this.leading,
    required this.width,
    required this.onTap,
  });

  final _Crumb crumb;
  final String tooltip;
  final Icon? leading;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    final text = ScoreText.caption.copyWith(color: tokens.ink500);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: onTap != null,
        label: '转到 ${crumb.label}',
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('directory-breadcrumb-${crumb.path}'),
          onTap: onTap,
          borderRadius: ScoreRadius.controlAll,
          child: Container(
            height: DirectoryBreadcrumbs._crumbHeight,
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: ScoreSpace.xs),
                ],
                Expanded(
                  child: Text(
                    crumb.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.crumbs,
    required this.onSelected,
    required this.width,
  });

  final List<_Crumb> crumbs;
  final double width;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    return PopupMenuButton<String>(
      key: const ValueKey('directory-breadcrumb-overflow'),
      tooltip: '展开中间目录',
      enabled: onSelected != null,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (var index = 0; index < crumbs.length; index++)
          PopupMenuItem<String>(
            value: crumbs[index].path,
            child: Text(
              crumbs[index].path,
              style: ScoreText.caption.copyWith(color: tokens.ink700),
            ),
          ),
      ],
      child: Container(
        height: DirectoryBreadcrumbs._crumbHeight,
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
        alignment: Alignment.center,
        child: Text(
          '…',
          style: ScoreText.caption.copyWith(color: tokens.ink500),
        ),
      ),
    );
  }
}
