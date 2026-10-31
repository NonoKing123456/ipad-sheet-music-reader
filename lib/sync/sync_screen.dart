import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:reader_state/reader_state.dart';

import '../reader/annotation_canvas.dart';
import 'sync_controller.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({
    super.key,
    required this.controller,
    required this.openOffline,
  });
  final SyncController controller;
  final VoidCallback openOffline;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final TextEditingController _address = TextEditingController(
    text: widget.controller.computerAddress?.toString() ?? '',
  );
  final TextEditingController _code = TextEditingController();
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
            if (defaultTargetPlatform != TargetPlatform.iOS &&
                defaultTargetPlatform != TargetPlatform.android)
              _card('这台电脑提供谱库', [
                Text(sync.library.rootPath ?? '请先返回谱库选择源文件夹。'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          sync.serverBusy || sync.initializationError != null
                          ? null
                          : () => unawaited(
                              sync.serving
                                  ? sync.stopServer()
                                  : sync.startServer(),
                            ),
                      icon: Icon(sync.serving ? Icons.stop : Icons.wifi),
                      label: Text(sync.serving ? '关闭服务' : '开启局域网服务'),
                    ),
                    if (sync.serving)
                      OutlinedButton(
                        onPressed: sync.refreshCode,
                        child: const Text('刷新配对码'),
                      ),
                    if (sync.serving)
                      TextButton(
                        onPressed: () => unawaited(sync.refreshAddresses()),
                        child: const Text('刷新本机地址'),
                      ),
                  ],
                ),
                if (sync.serverMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(sync.serverMessage!),
                  ),
                if (sync.serving) ...[
                  const SizedBox(height: 16),
                  const Text('在阅读设备上填写其中一个电脑地址：'),
                  for (final address in sync.addresses)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: SelectableText(address.toString()),
                      subtitle: Text(
                        address.host == '127.0.0.1'
                            ? '仅供这台电脑内的另一实例测试'
                            : '本机网络地址；阅读设备需处于可互通的局域网',
                      ),
                    ),
                  SelectableText(
                    '配对码：${sync.pairingCode ?? ''}',
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 3,
                    ),
                  ),
                  const Text('配对码2分钟有效，成功使用一次即失效；过期请刷新。'),
                ],
              ]),
            _card('连接电脑', [
              const Text('与电脑连接同一可信Wi-Fi，在电脑开启服务后填写地址和配对码。资料通过本地网络传输。'),
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
            ]),
            _card('全库离线副本', [
              Text(
                sync.hasOfflineLibrary
                    ? '已保存 ${sync.offlineCount} 份可用曲谱，可断网阅读。'
                    : '尚未建立完整离线谱库。首次同步需接收并校验整个指定谱库。',
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
                    label: const Text('同步全库、批注和曲单'),
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
                        : '${sync.committingLibrary ? '文件已核验，正在提交完整离线库' : '正在核对并下载文件'} · ${sync.processedObjects} / ${sync.totalObjects} 份',
                  ),
                ),
              if (sync.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _status(sync.message!),
                ),
              const SizedBox(height: 10),
              const Text('同步中断后可重试；上次完整副本继续保留。电脑删除的条目标为缺失，已有缓存不会自动永久删除。'),
              TextButton(
                onPressed: sync.busy || !sync.hasOfflineLibrary
                    ? null
                    : () => unawaited(sync.verifyOfflineLibrary()),
                child: const Text('完整校验离线文件（读取全部内容）'),
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
                  '首次连接时请允许“本地网络”。若未连接成功，在系统“设置 → 隐私与安全性 → 本地网络”允许本应用，然后返回重试。请保持应用在前台完成全库同步。',
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
