import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:library_sync/library_sync.dart' show PageMetadataKey;
import 'package:path/path.dart' as p;

import '../theme/reader_icons.dart';
import '../theme/device_layout.dart';
import '../theme/tokens.dart';
import 'page_count_service.dart';

/// One column definition for the header, files, folders and search results.
class LibraryColumns extends StatelessWidget {
  const LibraryColumns({
    super.key,
    required this.leading,
    required this.name,
    this.metadata,
    this.action,
  });
  final Widget leading, name;
  final Widget? metadata, action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: ScoreLayout.rowInnerPadding,
    ),
    child: Row(
      children: [
        SizedBox(
          width: ScoreLayout.iconColumn,
          child: Align(alignment: Alignment.centerLeft, child: leading),
        ),
        Expanded(child: name),
        SizedBox(
          width: ScoreLayout.typeColumn + ScoreLayout.pagesColumn,
          child: metadata,
        ),
        SizedBox(
          width: ScoreLayout.actionColumn,
          child: Center(child: action),
        ),
      ],
    ),
  );
}

class LibraryColumnHeader extends StatelessWidget {
  const LibraryColumnHeader({super.key});
  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    final style = ScoreText.caption.copyWith(color: tokens.ink500);
    return Container(
      key: const ValueKey('library-column-header'),
      height: ScoreLayout.columnHeaderHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hair2)),
      ),
      child: LibraryColumns(
        leading: const SizedBox.shrink(),
        name: Row(
          children: [
            Text('名称', style: style),
            const SizedBox(width: ScoreSpace.sm),
            ReaderIcon(
              ReaderGlyph.chevronDown,
              size: ScoreLayout.iconSmallVisual,
              color: tokens.ink500,
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

class LibraryFileRow extends StatelessWidget {
  const LibraryFileRow({
    super.key,
    required this.leading,
    required this.name,
    required this.onTap,
    this.subtitle,
    this.metadata,
    this.action,
    this.query = '',
  });
  final Widget leading;
  final String name, query;
  final String? subtitle;
  final Widget? metadata, action;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final tokens = ScoreTokens.of(context);
    final scale =
        MediaQuery.textScalerOf(context).scale(ScoreText.headline.fontSize!) /
        ScoreText.headline.fontSize!;
    final height =
        (subtitle == null
            ? ScoreLayout.fileRowHeight
            : query.isEmpty
            ? ScoreLayout.folderRowHeight
            : ScoreLayout.searchRowHeight) *
        scale.clamp(1, double.infinity);
    final style = ScoreText.headline.copyWith(color: tokens.ink900);
    final match = query.trim().isEmpty
        ? -1
        : name.toLowerCase().indexOf(query.toLowerCase().trim());
    final title = match < 0
        ? Text(name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)
        : Text.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(text: name.substring(0, match)),
                TextSpan(
                  text: name.substring(match, match + query.trim().length),
                  style: TextStyle(backgroundColor: tokens.searchHit),
                ),
                TextSpan(text: name.substring(match + query.trim().length)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: ScoreRadius.controlAll,
        hoverColor: tokens.paper0,
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: LibraryColumns(
                  leading: leading,
                  name: Padding(
                    padding: const EdgeInsets.only(right: ScoreSpace.lg),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(message: name, child: title),
                        if (subtitle != null) ...[
                          const SizedBox(height: ScoreLayout.rowSubtitleGap),
                          Tooltip(
                            message: subtitle!,
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ScoreText.caption.copyWith(
                                color: tokens.ink500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  metadata: metadata,
                  action: action,
                ),
              ),
              Positioned(
                left: ScoreLayout.rowDividerInsetStart,
                right: ScoreLayout.rowDividerInsetEnd,
                bottom: 0,
                height: ScoreLayout.rowDividerThickness,
                child: ColoredBox(color: tokens.hair),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Watches only visible immutable-revision metadata; does not parse score files.
class LibraryFileMetadata extends StatefulWidget {
  const LibraryFileMetadata({
    super.key,
    required this.entryId,
    required this.revisionId,
    required this.path,
    this.service,
  });
  final String entryId, revisionId, path;
  final PageCountService? service;
  @override
  State<LibraryFileMetadata> createState() => _LibraryFileMetadataState();
}

class _LibraryFileMetadataState extends State<LibraryFileMetadata> {
  ValueNotifier<int?>? _count;
  bool get _pdf => p.extension(widget.path).toLowerCase() == '.pdf';
  PageMetadataKey get _key =>
      PageMetadataKey(widget.entryId, widget.revisionId);
  void _bind() {
    if (_pdf) _count = widget.service?.watch(_key);
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(LibraryFileMetadata oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((
          oldWidget.entryId,
          oldWidget.revisionId,
          oldWidget.path,
          oldWidget.service,
        ) !=
        (widget.entryId, widget.revisionId, widget.path, widget.service)) {
      if (p.extension(oldWidget.path).toLowerCase() == '.pdf') {
        oldWidget.service?.unwatch(
          PageMetadataKey(oldWidget.entryId, oldWidget.revisionId),
        );
      }
      _count = null;
      _bind();
    }
  }

  @override
  void dispose() {
    if (_pdf) widget.service?.unwatch(_key);
    super.dispose();
  }

  Widget _label(int? count) {
    final tokens = ScoreTokens.of(context);
    final ext = p.extension(widget.path).toLowerCase();
    final label = ext == '.webp'
        ? 'WebP'
        : ext == '.jpeg'
        ? 'JPG'
        : ext.substring(ext.isEmpty ? 0 : 1).toUpperCase();
    final color = ext == '.pdf' || ext == '.webp'
        ? tokens.pineDeep
        : ext == '.jpg' || ext == '.jpeg'
        ? tokens.ink700
        : tokens.ink500;
    return Row(
      children: [
        SizedBox(
          width: ScoreLayout.typeColumn,
          child: Text(label, style: ScoreText.caption.copyWith(color: color)),
        ),
        Expanded(
          child: Tooltip(
            message: count == null ? '尚未取得页数' : '$count 页',
            child: Text(
              count == null ? '—' : '$count 页',
              textAlign: TextAlign.right,
              style: ScoreText.caption.copyWith(
                color: tokens.ink500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => !_pdf
      ? _label(1)
      : _count == null
      ? _label(null)
      : ValueListenableBuilder<int?>(
          valueListenable: _count!,
          builder: (_, value, _) => _label(value),
        );
}

class LibraryIconButton extends StatelessWidget {
  const LibraryIconButton({
    super.key,
    required this.glyph,
    required this.label,
    this.onPressed,
    this.touch = false,
  });
  final ReaderGlyph glyph;
  final String label;
  final VoidCallback? onPressed;
  final bool touch;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    icon: ReaderIcon(glyph),
    style: IconButton.styleFrom(
      fixedSize: Size.square(
        touch || DeviceLayoutScope.isCompact(context)
            ? ScoreLayout.touchTarget
            : ScoreLayout.desktopTarget,
      ),
      minimumSize: Size.zero,
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.controlAll),
    ),
  );
}

class LibraryNavigationItem extends StatelessWidget {
  const LibraryNavigationItem({
    super.key,
    required this.label,
    required this.onTap,
    this.glyph = ReaderGlyph.folder,
    this.selected = false,
    this.indent = 0,
    this.trailing,
    this.count,
  });
  final String label;
  final VoidCallback onTap;
  final ReaderGlyph glyph;
  final bool selected;
  final double indent;
  final Widget? trailing;
  final String? count;
  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Material(
        color: selected ? t.pineWash : Colors.transparent,
        borderRadius: ScoreRadius.controlAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: ScoreRadius.controlAll,
          child: SizedBox(
            height: ScoreLayout.touchTarget,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.md),
              child: Row(
                children: [
                  ReaderIcon(glyph, color: selected ? t.pine : t.ink700),
                  const SizedBox(width: ScoreSpace.md),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (indent > 0 ? ScoreText.caption : ScoreText.body)
                          .copyWith(
                            color: selected ? t.pine : t.ink700,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                    ),
                  ),
                  if (count != null)
                    Text(
                      count!,
                      style: ScoreText.caption.copyWith(
                        color: t.ink500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibrarySidebar extends StatelessWidget {
  const LibrarySidebar({
    super.key,
    required this.entries,
    required this.itemBuilder,
    required this.device,
  });
  final List<LibraryNavEntry> entries;
  final Widget Function(BuildContext, LibraryNavEntry) itemBuilder;
  final Widget device;
  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return Material(
      color: t.paper2,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          ScoreSpace.md,
          ScoreSpace.lg,
          ScoreSpace.md,
          ScoreSpace.md,
        ),
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: t.hair2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ScoreSpace.md,
                ScoreSpace.xs,
                ScoreSpace.md,
                ScoreLayout.iconVisual,
              ),
              child: Row(
                children: [
                  Container(
                    width: ScoreLayout.brandIconVisual,
                    height: ScoreLayout.brandIconVisual,
                    decoration: BoxDecoration(
                      color: t.pine,
                      borderRadius: ScoreRadius.controlAll,
                    ),
                    child: Center(
                      child: ReaderIcon(ReaderGlyph.book, color: t.onBrand),
                    ),
                  ),
                  const SizedBox(width: ScoreSpace.md),
                  Text('曲谱库', style: ScoreText.title.copyWith(color: t.ink900)),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: entries.length,
                itemBuilder: (context, index) =>
                    itemBuilder(context, entries[index]),
              ),
            ),
            Container(
              height: ScoreLayout.deviceCardHeight,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.hair)),
              ),
              child: device,
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryGroupLabel extends StatelessWidget {
  const LibraryGroupLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ScoreSpace.md,
      ScoreSpace.md,
      ScoreSpace.md,
      ScoreSpace.sm,
    ),
    child: Text(
      text,
      style: ScoreText.caption.copyWith(color: ScoreTokens.of(context).ink500),
    ),
  );
}

/// The result text keeps the scope action available without another toolbar.
class LibrarySearchContext extends StatelessWidget {
  const LibrarySearchContext({
    super.key,
    required this.count,
    required this.withinFolder,
    required this.onScopeChanged,
  });
  final int count;
  final bool withinFolder;
  final ValueChanged<bool> onScopeChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: ScoreLayout.resultContextHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ScoreLayout.listMargin + ScoreSpace.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LibraryOutsideTapExclusion(
          child: PopupMenuButton<bool>(
            tooltip: '搜索范围',
            onSelected: onScopeChanged,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: !withinFolder,
                checked: withinFolder,
                child: const Text('当前文件夹及子文件夹'),
              ),
            ],
            child: Text(
              '$count 个结果 · 显示所属目录',
              style: ScoreText.caption.copyWith(
                color: ScoreTokens.of(context).ink500,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

ButtonStyle libraryIconButtonStyle(BuildContext context) =>
    IconButton.styleFrom(
      foregroundColor: ScoreTokens.of(context).ink700,
      fixedSize: Size.square(
        DeviceLayoutScope.isCompact(context)
            ? ScoreLayout.touchTarget
            : ScoreLayout.desktopTarget,
      ),
      minimumSize: Size.zero,
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.controlAll),
    );

class LibrarySyncActivityIcon extends StatefulWidget {
  const LibrarySyncActivityIcon({super.key});
  @override
  State<LibrarySyncActivityIcon> createState() =>
      _LibrarySyncActivityIconState();
}

class _LibrarySyncActivityIconState extends State<LibrarySyncActivityIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: ScoreMotion.syncCycle,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _turns.stop();
    } else {
      _turns.repeat();
    }
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    key: const ValueKey('offline-sync-rotation'),
    turns: _turns,
    child: ReaderIcon(ReaderGlyph.sync, color: ScoreTokens.of(context).pine),
  );
  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }
}

/// Cached navigation data; widgets are created only by the sliver's item builder.
enum LibraryNavKind {
  group,
  source,
  folder,
  addSource,
  setList,
  newSetList,
  operations,
  refresh,
  returnLibrary,
}

class LibraryNavEntry {
  const LibraryNavEntry(this.kind, {this.value, this.label = ''});
  final LibraryNavKind kind;
  final Object? value;
  final String label;
}

/// Observes real taps without joining the gesture arena or consuming child taps.
/// A scroll, cancelled pointer, or multi-pointer sequence can never dismiss search.
class LibraryOutsideTapListener extends StatefulWidget {
  const LibraryOutsideTapListener({
    super.key,
    required this.enabled,
    required this.onTap,
    required this.child,
  });
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;
  @override
  State<LibraryOutsideTapListener> createState() =>
      _LibraryOutsideTapListenerState();
}

class _LibraryOutsideTapListenerState extends State<LibraryOutsideTapListener> {
  final Set<int> _pointers = {};
  final Set<int> _excluded = {};
  int? _candidate;
  Offset _origin = Offset.zero;
  double _maximumTravelSquared = 0, _slopSquared = 0;
  bool _multiplePointers = false;

  void _exclude(int pointer) {
    _excluded.add(pointer);
    if (_candidate == pointer) _candidate = null;
  }

  void _down(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) _multiplePointers = true;
    if (!widget.enabled ||
        _multiplePointers ||
        _excluded.contains(event.pointer) ||
        event.buttons != kPrimaryButton) {
      _candidate = null;
      return;
    }
    _candidate = event.pointer;
    _origin = event.position;
    _maximumTravelSquared = 0;
    final slop = computeHitSlop(
      event.kind,
      MediaQuery.maybeGestureSettingsOf(context),
    );
    _slopSquared = slop * slop;
  }

  void _observe(PointerEvent event) {
    if (_candidate != event.pointer) return;
    final distance = (event.position - _origin).distanceSquared;
    if (distance > _maximumTravelSquared) _maximumTravelSquared = distance;
  }

  void _finish(int pointer) {
    _candidate = null;
    _pointers.remove(pointer);
    _excluded.remove(pointer);
    if (_pointers.isEmpty) {
      _multiplePointers = false;
      _excluded.clear();
    }
  }

  void _up(PointerUpEvent event) {
    _observe(event);
    final tap =
        widget.enabled &&
        _candidate == event.pointer &&
        _pointers.length == 1 &&
        !_multiplePointers &&
        !_excluded.contains(event.pointer) &&
        _maximumTravelSquared <= _slopSquared;
    _finish(event.pointer);
    if (tap) widget.onTap();
  }

  @override
  void didUpdateWidget(LibraryOutsideTapListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _candidate = null;
  }

  @override
  Widget build(BuildContext context) => _LibraryOutsideTapScope(
    state: this,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _observe,
      onPointerUp: _up,
      onPointerCancel: (event) => _finish(event.pointer),
      onPointerSignal: (_) => _candidate = null,
      onPointerPanZoomStart: (_) => _candidate = null,
      child: widget.child,
    ),
  );
}

class _LibraryOutsideTapScope extends InheritedWidget {
  const _LibraryOutsideTapScope({required this.state, required super.child});
  final _LibraryOutsideTapListenerState state;
  @override
  bool updateShouldNotify(_LibraryOutsideTapScope oldWidget) =>
      state != oldWidget.state;
}

/// Protect search controls located within the otherwise dismissible content.
/// Down only marks the pointer; it never closes search or consumes the gesture.
class LibraryOutsideTapExclusion extends StatelessWidget {
  const LibraryOutsideTapExclusion({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_LibraryOutsideTapScope>();
    return Listener(
      onPointerDown: (event) => scope?.state._exclude(event.pointer),
      child: child,
    );
  }
}
