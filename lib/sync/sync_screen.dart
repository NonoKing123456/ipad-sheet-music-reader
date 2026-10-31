import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:reader_state/reader_state.dart';

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

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.controller,
    required this.openOffline,
    this.scanOnOpen = false,
    this.syncOnOpen = false,
  });
  final SyncController controller;
  final VoidCallback openOffline;
  final bool scanOnOpen;
  final bool syncOnOpen;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final TextEditingController _address = TextEditingController(
    text: widget.controller.computerAddress?.toString() ?? '',
  );
  final TextEditingController _code = TextEditingController();
  bool _scanning = false;
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

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final sync = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('无线同步')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (sync.initializationError != null)
              _status(sync.initializationError!),
            if (_desktop)
              _card('连接我的 iPad', [
                Text(
                  sync.library.sources.isEmpty
                      ? '请先添加谱库文件夹。'
                      : '${sync.library.sources.length} 个谱库 · ${sync.library.sources.map((s) => s.name).join('、')}',
                ),
                const SizedBox(height: 12),
                const Text(
                  '电脑和iPad连接同一Wi-Fi。在iPad扫描下方二维码，以后保持电脑阅读器打开，点击“更新目录与所选内容”。',
                ),
                if (sync.serving && sync.pairingQr != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: QrImageView(
                            data: sync.pairingQr!,
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.all(20),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (sync.serving && sync.pairingQr == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      '暂未找到可用的Wi-Fi或有线网络。请将电脑连接到与iPad相同的网络，再点击“更新二维码”。',
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          sync.serverBusy || sync.initializationError != null
                          ? null
                          : () => unawaited(sync.connectMyIpad()),
                      icon: Icon(
                        sync.serverBusy ? Icons.hourglass_top : Icons.qr_code,
                      ),
                      label: Text(
                        sync.serverBusy
                            ? '正在准备连接…'
                            : sync.serving
                            ? '更新二维码'
                            : '显示连接二维码',
                      ),
                    ),
                  ],
                ),
                if (sync.serverMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(sync.serverMessage!),
                  ),
                const SizedBox(height: 8),
                const Text('二维码2分钟有效、使用一次失效；未使用时会自动更新。请只让自己的iPad扫描。'),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('下次打开阅读器，自动连接我的 iPad'),
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
              ]),
            if (!_desktop)
              _card(sync.paired ? '我的电脑已连接' : '扫描电脑二维码', [
                Text(
                  sync.paired
                      ? '已记住电脑，打开电脑阅读器后可更新目录与所选内容。电脑换网络后重新扫码，已有离线内容保留。'
                      : '先在电脑阅读器首页点击“连接我的 iPad”，再扫描电脑上出现的二维码。只需操作一次，资料通过同一Wi-Fi传输。',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed:
                      sync.busy || _scanning || sync.initializationError != null
                      ? null
                      : () => unawaited(_scan()),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(
                    _scanning
                        ? '正在连接…'
                        : sync.paired
                        ? '重新扫描电脑二维码'
                        : '扫描电脑二维码',
                  ),
                ),
                if (_scanMessage != null) _status(_scanMessage!),
              ]),
            ExpansionTile(
              title: const Text('高级诊断（通常不需要）'),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                if (_desktop) ...[
                  for (final address in sync.addresses)
                    SelectableText(address.toString()),
                  if (sync.serving)
                    SelectableText('临时配对码：${sync.pairingCode ?? ''}'),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _address,
                  enabled: !sync.busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '电脑地址与端口',
                    hintText: 'http://192.168.1.8:50000',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  enabled: !sync.busy,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    labelText: '8位临时配对码',
                    border: OutlineInputBorder(),
                  ),
                ),
                FilledButton(
                  onPressed: sync.busy || sync.initializationError != null
                      ? null
                      : () => unawaited(sync.pair(_address.text, _code.text)),
                  child: Text(sync.paired ? '重新配对' : '配对电脑'),
                ),
                if (sync.paired)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('已保存连接：${sync.computerAddress}；重开后可直接同步。'),
                  ),
              ],
            ),
            _card('目录与离线内容', [
              Text(
                sync.hasOfflineLibrary
                    ? '已保存 ${sync.offlineCount} 份可用曲谱，可断网阅读。'
                    : '先更新目录，再在谱库中选择文件夹或单曲。新谱库不会自动下载。',
              ),
              Text(
                '已选择 ${sync.selectedDownloadTotals.$1} 份曲谱 · ${_contentSize(sync.selectedDownloadTotals.$2)}',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: sync.busy || !sync.paired
                        ? null
                        : () => unawaited(sync.synchronize()),
                    icon: const Icon(Icons.sync),
                    label: const Text('更新目录与所选内容'),
                  ),
                  OutlinedButton(
                    onPressed: sync.hasOfflineLibrary
                        ? widget.openOffline
                        : null,
                    child: const Text('打开离线谱库'),
                  ),
                  if (sync.busy &&
                      (sync.phase == SyncPhase.transferring ||
                          sync.phase == SyncPhase.merging))
                    OutlinedButton(
                      onPressed: sync.cancel,
                      child: const Text('取消同步'),
                    ),
                ],
              ),
              if (sync.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (sync.phase == SyncPhase.transferring)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    sync.totalObjects == null
                        ? '正在取得电脑谱库清单…'
                        : '正在更新所选内容 · ${sync.processedObjects} / ${sync.totalObjects} 份',
                  ),
                ),
              if (sync.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _status(sync.message!),
                ),
              const SizedBox(height: 10),
              const Text('中断可重试，已有离线内容保留。取消选择不会删除下载或批注。'),
              TextButton(
                onPressed: sync.busy || !sync.hasOfflineLibrary
                    ? null
                    : () => unawaited(sync.verifyOfflineLibrary()),
                child: const Text('完整校验已下载文件'),
              ),
            ]),
            if (sync.workspace.store.snapshot.conflicts.isNotEmpty)
              _card('有待处理的批注或曲单版本', [
                Text(
                  '共 ${sync.workspace.store.snapshot.conflicts.length} 项。双方完整版本已保留，尚未自动解决。',
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SyncConflictsScreen(controller: sync),
                    ),
                  ),
                  child: const Text('查看保留的版本'),
                ),
              ]),
            if (defaultTargetPlatform == TargetPlatform.iOS)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '首次连接请允许“本地网络”。若连接失败，可在系统设置中允许本应用访问本地网络后重试。请保持应用在前台完成目录更新和所选下载。',
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  Widget _status(String message) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    color: const Color(0xffffedcf),
    child: Text(message),
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
      final stroke = AnnotationStroke.fromJson(Map<String, dynamic>.from(json));
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
            const Text('下面两份版本均已完整保存。此版本提供查看；选取、合并和清除冲突的操作尚未提供。'),
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
