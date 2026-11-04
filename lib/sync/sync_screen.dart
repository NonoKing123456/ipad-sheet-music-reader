import 'dart:async';
import 'dart:convert';

import '../theme/tokens.dart';
import '../theme/device_layout.dart';
import '../theme/reader_icons.dart';
import '../signing/signing_expiry_chip.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:reader_state/reader_state.dart';
import 'package:library_sync/library_sync.dart' show OfflineRule;

import '../reader/annotation_canvas.dart';
import 'sync_controller.dart';
import 'qr_scanner.dart';

String _contentSize(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
    : bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '$bytes B';

Future<void> showDeviceSyncPanel(
  BuildContext context, {
  required SyncController controller,
  required VoidCallback openOffline,
  bool scanOnOpen = false,
  bool syncOnOpen = false,
}) {
  final compact = DeviceLayoutScope.isCompact(context);
  Widget content() => SyncScreen(
    controller: controller,
    openOffline: openOffline,
    scanOnOpen: scanOnOpen,
    syncOnOpen: syncOnOpen,
    panel: true,
  );
  if (compact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(
        maxWidth: double.infinity,
        maxHeight: ScoreLayout.sheetMaxHeight,
      ),
      backgroundColor: ScoreTokens.of(context).paper0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ScoreRadius.overlay),
        ),
      ),
      builder: (_) => content(),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: ScoreTokens.of(context).paper0,
      insetPadding: const EdgeInsets.all(ScoreSpace.lg),
      shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.overlayAll),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ScoreLayout.sheetWidth,
          maxHeight: ScoreLayout.sheetMaxHeight,
        ),
        child: content(),
      ),
    ),
  );
}

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.controller,
    required this.openOffline,
    this.scanOnOpen = false,
    this.syncOnOpen = false,
    this.panel = false,
  });
  final SyncController controller;
  final VoidCallback openOffline;
  final bool scanOnOpen;
  final bool syncOnOpen;
  final bool panel;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final TextEditingController _address = TextEditingController(
    text: widget.controller.computerAddress?.toString() ?? '',
  );
  final TextEditingController _code = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _scanning = false;
  bool _catalogUpdating = false;
  bool _diagnosticsOpen = false;
  Object? _rangeSelection;
  List<OfflineRule> _rangeRules = const [];
  String? _scanMessage;
  bool get _desktop =>
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.scanOnOpen) unawaited(_scan());
      if (widget.syncOnOpen) unawaited(widget.controller.synchronize());
    });
  }

  Future<void> _scan() async {
    if (_scanning || widget.controller.busy) return;
    setState(() {
      _scanning = true;
      _scanMessage = null;
    });
    try {
      final value = await QrScanner.scan();
      if (!mounted || value == null) return;
      final paired = await widget.controller.pairFromQr(value);
      if (paired && mounted) await widget.controller.synchronize();
    } on PlatformException catch (failure) {
      if (mounted) {
        setState(
          () => _scanMessage = failure.message ?? '无法打开相机，请在设置中允许相机访问后重试。',
        );
      }
    } on MissingPluginException {
      if (mounted) setState(() => _scanMessage = '请使用支持扫码的新版本iPad阅读器。');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _refreshCatalog() async {
    if (_catalogUpdating) return;
    setState(() => _catalogUpdating = true);
    try {
      await widget.controller.refreshCatalog();
    } finally {
      if (mounted) setState(() => _catalogUpdating = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final sync = widget.controller, tokens = ScoreTokens.of(context);
      final compact = DeviceLayoutScope.isCompact(context);
      final rangeRules = _downloadRangeRules(sync);
      final content = Column(
        children: [
          SizedBox(
            height: ScoreLayout.headerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.xl),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '设备与同步',
                      style: ScoreText.title.copyWith(color: tokens.ink900),
                    ),
                  ),
                  SizedBox.square(
                    dimension: compact
                        ? ScoreLayout.touchTarget
                        : ScoreLayout.desktopTarget,
                    child: IconButton(
                      tooltip: '关闭设备与同步',
                      onPressed: () => Navigator.pop(context),
                      icon: const ReaderIcon(ReaderGlyph.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 0, thickness: 1, color: tokens.hair2),
          Expanded(
            child: CustomScrollView(
              key: const PageStorageKey('device-sync-scroll'),
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    ScoreSpace.xl,
                    ScoreSpace.lg,
                    ScoreSpace.xl,
                    ScoreSpace.xl,
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      if (sync.initializationError != null)
                        SliverToBoxAdapter(
                          child: _status(
                            sync.initializationError!,
                            error: true,
                          ),
                        ),
                      SliverToBoxAdapter(child: _connection(sync)),
                      SliverToBoxAdapter(
                        child: _section(
                          SigningExpiryChip(
                            section: true,
                            pairedDevice: _desktop,
                            pairedStatus: _desktop ? sync.signingStatus : null,
                            unavailable: _desktop
                                ? sync.signingUnavailable
                                : null,
                            onRefresh: _desktop
                                ? sync.refreshSigningStatus
                                : null,
                            onRead: _desktop
                                ? null
                                : (expiry) => sync.reportLocalSigningExpiry(
                                    expiry.expiration,
                                  ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _section(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: _title('曲库目录')),
                                  TextButton.icon(
                                    onPressed: sync.busy || !sync.paired
                                        ? null
                                        : () => unawaited(_refreshCatalog()),
                                    icon: _activityIcon(_catalogUpdating),
                                    label: const Text('更新目录'),
                                  ),
                                ],
                              ),
                              _caption(
                                sync.hasOfflineLibrary
                                    ? '${sync.offlineCount} 份曲谱可离线阅读'
                                    : '更新目录后选择需要下载的曲谱',
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(child: _section(_downloads(sync))),
                      SliverList.builder(
                        itemCount: rangeRules.length,
                        itemBuilder: (_, index) =>
                            _downloadRange(sync, rangeRules[index]),
                      ),
                      if (sync.message != null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(top: ScoreSpace.sm),
                            child: _status(
                              sync.message!,
                              error:
                                  sync.phase == SyncPhase.failed ||
                                  sync.phase == SyncPhase.partial,
                            ),
                          ),
                        ),
                      if (sync.workspace.store.snapshot.conflicts.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _section(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _title('有待处理的批注或曲单版本'),
                                _caption(
                                  '共 ${sync.workspace.store.snapshot.conflicts.length} 项待查看',
                                ),
                                TextButton(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          SyncConflictsScreen(controller: sync),
                                    ),
                                  ),
                                  child: const Text('查看保留的版本'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(child: _section(_diagnostics(sync))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
      final target = compact
          ? ScoreLayout.touchTarget
          : ScoreLayout.desktopTarget;
      return Theme(
        data: Theme.of(context).copyWith(
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              minimumSize: Size(0, target),
              foregroundColor: tokens.ink900,
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.merge(ScoreText.caption),
              shape: const RoundedRectangleBorder(
                borderRadius: ScoreRadius.controlAll,
              ),
            ),
          ),
        ),
        child: Material(
          color: tokens.paper0,
          child: widget.panel
              ? content
              : Scaffold(body: SafeArea(child: content)),
        ),
      );
    },
  );

  Widget _title(String text) => Text(
    text,
    style: ScoreText.body.copyWith(
      color: ScoreTokens.of(context).ink900,
      fontWeight: FontWeight.w500,
    ),
  );
  Widget _caption(String text) => Text(
    text,
    style: ScoreText.caption.copyWith(color: ScoreTokens.of(context).ink500),
  );
  Widget _section(Widget child) => Container(
    padding: const EdgeInsets.symmetric(vertical: ScoreSpace.lg),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: ScoreTokens.of(context).hair2)),
    ),
    child: child,
  );
  Widget _activityIcon(bool active) => active
      ? SizedBox.square(
          dimension: ScoreLayout.iconVisual,
          child: CircularProgressIndicator(
            strokeWidth: ScoreLayout.iconStroke,
            color: ScoreTokens.of(context).pine,
          ),
        )
      : const ReaderIcon(ReaderGlyph.sync);

  Widget _connection(SyncController sync) => Padding(
    padding: const EdgeInsets.only(bottom: ScoreSpace.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ReaderIcon(
              ReaderGlyph.ipad,
              size: ScoreSpace.xxl,
              color: ScoreTokens.of(context).pine,
            ),
            const SizedBox(width: ScoreSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _desktop
                        ? 'iPad · ${sync.signingStatus.value == null ? '等待连接' : '已配对'}'
                        : 'Windows 电脑 · ${sync.paired ? '已配对' : '尚未配对'}',
                    style: ScoreText.headline.copyWith(
                      color: ScoreTokens.of(context).ink900,
                    ),
                  ),
                  _caption(
                    _desktop
                        ? (sync.serving ? '同一局域网内可连接' : '显示二维码后由 iPad 扫码连接')
                        : (sync.computerAddress?.toString() ?? '扫描电脑上的连接二维码'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: ScoreSpace.sm),
        if (_desktop) ...[
          if (sync.serving && sync.pairingQr != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: ScoreSpace.md),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: QrImageView(
                      data: sync.pairingQr!,
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.all(ScoreSpace.md),
                    ),
                  ),
                ),
              ),
            ),
          if (sync.serving && sync.pairingQr == null)
            _caption('暂未找到可用的局域网连接。连接同一网络后更新二维码。'),
          TextButton.icon(
            onPressed: sync.serverBusy || sync.initializationError != null
                ? null
                : () => unawaited(sync.connectMyIpad()),
            icon: _activityIcon(sync.serverBusy),
            label: Text(
              sync.serverBusy
                  ? '正在准备连接…'
                  : sync.serving
                  ? '更新二维码'
                  : '显示连接二维码',
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text('下次自动连接我的 iPad', style: ScoreText.caption),
            value: sync.autoStartServer,
            onChanged: sync.serverBusy
                ? null
                : (value) => unawaited(sync.setAutoStartServer(value)),
          ),
          if (sync.serving)
            TextButton(
              onPressed: sync.serverBusy
                  ? null
                  : () => unawaited(sync.stopServer()),
              child: const Text('暂时停止连接'),
            ),
          if (sync.serverMessage != null) _caption(sync.serverMessage!),
        ] else ...[
          TextButton.icon(
            onPressed:
                sync.busy || _scanning || sync.initializationError != null
                ? null
                : () => unawaited(_scan()),
            icon: _activityIcon(_scanning),
            label: Text(
              _scanning
                  ? '正在连接…'
                  : sync.paired
                  ? '重新扫描电脑二维码'
                  : '扫描电脑二维码',
            ),
          ),
          if (_scanMessage != null) _status(_scanMessage!, error: true),
        ],
      ],
    ),
  );

  Widget _downloads(SyncController sync) {
    final total = sync.totalObjects;
    final label = sync.backgroundImporting
        ? '正在保存下载内容'
        : sync.backgroundPendingObjects > 0
        ? '下载中 · 余 ${sync.backgroundPendingObjects} 份'
        : sync.backgroundPausedObjects > 0
        ? '已暂停 · ${sync.backgroundPausedObjects} 份'
        : sync.phase == SyncPhase.transferring && !_catalogUpdating
        ? (total == null ? '准备下载' : '下载中 · ${sync.processedObjects} / $total 份')
        : '下载内容';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _title(label)),
            if (sync.backgroundPendingObjects > 0)
              TextButton.icon(
                onPressed: () => unawaited(sync.pauseBackgroundDownloads()),
                icon: const ReaderIcon(ReaderGlyph.pause),
                label: const Text('暂停'),
              )
            else if (sync.backgroundPausedObjects > 0)
              TextButton.icon(
                onPressed: sync.busy
                    ? null
                    : () => unawaited(sync.resumeBackgroundDownloads()),
                icon: const ReaderIcon(ReaderGlyph.play),
                label: const Text('继续'),
              )
            else if (sync.busy &&
                !sync.committingLibrary &&
                (sync.phase == SyncPhase.transferring ||
                    sync.phase == SyncPhase.merging))
              TextButton(onPressed: sync.cancel, child: const Text('取消'))
            else if (sync.paired)
              TextButton.icon(
                onPressed: sync.hasSyncActivity
                    ? null
                    : () => unawaited(sync.synchronize()),
                icon: const ReaderIcon(ReaderGlyph.downloadList),
                label: const Text('下载所选'),
              ),
          ],
        ),
        _caption(
          '已选择 ${sync.selectedDownloadTotals.$1} 份 · ${_contentSize(sync.selectedDownloadTotals.$2)}',
        ),
        if (sync.backgroundPendingObjects > 0 ||
            (sync.busy && !_catalogUpdating)) ...[
          const SizedBox(height: ScoreSpace.sm),
          LinearProgressIndicator(
            value: total != null && total > 0
                ? (sync.processedObjects / total).clamp(0.0, 1.0)
                : null,
            minHeight: ScoreSpace.xs,
          ),
          const SizedBox(height: ScoreSpace.sm),
        ],
        _caption('已完成内容可离线阅读'),
        if (sync.backgroundFailedObjects > 0)
          _status(
            sync.backgroundStorageBlocked
                ? '存储空间或写入问题暂停了下载，请释放空间后继续。'
                : '${sync.backgroundFailedObjects} 份下载未完成，请检查连接后重试。',
            error: true,
          ),
        Wrap(
          spacing: ScoreSpace.sm,
          children: [
            TextButton(
              onPressed: sync.hasOfflineLibrary ? widget.openOffline : null,
              child: const Text('打开离线曲库'),
            ),
            TextButton(
              onPressed: sync.busy || !sync.hasOfflineLibrary
                  ? null
                  : () => unawaited(sync.verifyOfflineLibrary()),
              child: const Text('完整校验'),
            ),
          ],
        ),
      ],
    );
  }

  List<OfflineRule> _downloadRangeRules(SyncController sync) {
    final selection = sync.collection?.selection;
    if (!identical(selection, _rangeSelection)) {
      _rangeSelection = selection;
      _rangeRules =
          selection?.rules
              .where((rule) => rule.selected && rule.folder != null)
              .toList(growable: false) ??
          const [];
    }
    return _rangeRules;
  }

  Widget _downloadRange(SyncController sync, OfflineRule rule) => _section(
    Builder(
      builder: (context) {
        final status = sync.folderOfflineStatus(
          sourceId: rule.sourceId,
          folder: rule.folder!,
        );
        final source = sync.offlineSources
            .where((source) => source.id == rule.sourceId)
            .firstOrNull;
        final folder = rule.folder!.isEmpty
            ? source?.name ?? '来源目录'
            : rule.folder!.split('/').last;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const ReaderIcon(ReaderGlyph.folder),
                const SizedBox(width: ScoreSpace.sm),
                Expanded(child: _title(folder)),
                _caption('${status.readable} / ${status.total}'),
              ],
            ),
            const SizedBox(height: ScoreSpace.sm),
            if (status.total > 0)
              LinearProgressIndicator(
                value: status.readable / status.total,
                minHeight: ScoreSpace.xs,
              ),
            const SizedBox(height: ScoreSpace.sm),
            _caption(
              status.total > 0 && status.readable == status.total
                  ? '已完成'
                  : '已选择的下载范围',
            ),
          ],
        );
      },
    ),
  );

  Widget _diagnostics(SyncController sync) => ExpansionTile(
    onExpansionChanged: (value) => setState(() => _diagnosticsOpen = value),
    trailing: ReaderIcon(
      _diagnosticsOpen ? ReaderGlyph.chevronUp : ReaderGlyph.chevronDown,
    ),
    tilePadding: EdgeInsets.zero,
    title: Text('连接与诊断', style: ScoreText.caption),
    children: [
      if (_desktop) ...[
        for (final address in sync.addresses)
          SelectableText(address.toString(), style: ScoreText.caption),
        if (sync.serving)
          SelectableText(
            '临时配对码：${sync.pairingCode ?? ''}',
            style: ScoreText.caption,
          ),
      ],
      TextField(
        controller: _address,
        enabled: !sync.busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '电脑地址与端口',
          hintText: 'http://192.168.1.8:50000',
        ),
      ),
      const SizedBox(height: ScoreSpace.sm),
      TextField(
        controller: _code,
        enabled: !sync.busy,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: const InputDecoration(labelText: '8位临时配对码'),
      ),
      TextButton(
        onPressed: sync.busy || sync.initializationError != null
            ? null
            : () => unawaited(sync.pair(_address.text, _code.text)),
        child: Text(sync.paired ? '重新配对' : '配对电脑'),
      ),
      if (defaultTargetPlatform == TargetPlatform.iOS)
        _caption('首次连接请允许本地网络访问。后台下载由系统调度；强制关闭后需重新打开继续。'),
    ],
  );

  Widget _status(String message, {bool error = false}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(ScoreSpace.sm),
    color: error
        ? ScoreTokens.of(context).dangerBg
        : ScoreTokens.of(context).paper1,
    child: Text(
      message,
      style: ScoreText.caption.copyWith(
        color: error
            ? ScoreTokens.of(context).dangerInk
            : ScoreTokens.of(context).ink700,
      ),
    ),
  );
}

class SyncConflictsScreen extends StatelessWidget {
  const SyncConflictsScreen({super.key, required this.controller});
  final SyncController controller;
  String _entryName(String id) {
    final entry =
        controller.replica?.snapshot.entryById(id) ??
        controller.library.snapshot?.entryById(id);
    return entry?.relativePath ?? '保留的曲谱';
  }

  String _title(MergeConflict conflict) {
    if (conflict.kind == 'setList') {
      return '曲单：${conflict.first['name'] ?? conflict.second['name'] ?? '保留的曲单'}';
    }
    try {
      final page = (jsonDecode(conflict.objectKey) as List).first as Map;
      return '${_entryName(page['entryId'] as String)} · 第${page['pageNumber']}页批注';
    } catch (_) {
      return '保留的批注版本';
    }
  }

  Widget _variant(Map<String, Object?> json, String label, String kind) {
    if (kind == 'strokeOrder') {
      final count = (json['order'] as List? ?? const []).length;
      final deleted = (json['deletedIds'] as List? ?? const []).length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('笔迹叠放顺序有差异，双方记录已保留'),
          Text('$label：$count 笔记录，${count - deleted} 笔可见'),
        ],
      );
    }
    if (kind == 'setList') {
      final items = (json['items'] as List? ?? []).cast<Map>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label：${json['name'] ?? '曲单'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (json['deletedUtc'] != null) const Text('此版本已移除曲单'),
          for (var i = 0; i < items.length; i++)
            Text(
              '${i + 1}. ${_entryName(items[i]['entryId'] as String)}${items[i]['removedUtc'] == null ? '' : '（已移除）'}',
            ),
        ],
      );
    }
    try {
      final stroke = PageAnnotation.fromJson(Map<String, dynamic>.from(json));
      if (stroke is TextAnnotation) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label：${stroke.isDeleted ? '已删除文字' : '文字批注'}'),
            Text(stroke.text, maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
        );
      }
      if (stroke is! AnnotationStroke) return Text('$label：批注');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label：${stroke.isDeleted ? '已擦除' : '保留笔迹'} · ${stroke.style.tool == AnnotationTool.pen ? '画笔' : '荧光笔'}',
          ),
          const SizedBox(height: 8),
          Container(
            width: 240,
            height: 160,
            color: Colors.white,
            child: CustomPaint(
              painter: AnnotationPainter(
                strokes: [stroke],
                pending: const [],
                draft: const [],
                draftStyle: stroke.style,
              ),
            ),
          ),
        ],
      );
    } catch (_) {
      return Text('$label：完整内容保留在详情中。');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.workspace,
    builder: (context, _) {
      final conflicts = controller.workspace.store.snapshot.conflicts;
      return Scaffold(
        appBar: AppBar(title: const Text('保留的冲突版本')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('双方版本可查看，暂不支持合并选择。'),
            for (final conflict in conflicts)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title(conflict),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 24,
                        runSpacing: 16,
                        children: [
                          for (final (label, variant) in [
                            ('版本一', conflict.first),
                            ('版本二', conflict.second),
                          ])
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: _variant(variant, label, conflict.kind),
                            ),
                        ],
                      ),
                      if (conflict.kind != 'strokeOrder')
                        ExpansionTile(
                          title: const Text('原始版本详情'),
                          children: [
                            SelectableText(
                              const JsonEncoder.withIndent('  ')
                                  .convert(conflict.toJson()),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            if (conflicts.isEmpty) const Text('当前没有待处理的版本。'),
          ],
        ),
      );
    },
  );
}
