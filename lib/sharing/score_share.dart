import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'annotated_pdf_export.dart';

export 'annotated_pdf_export.dart' show ExportAnnotations;

typedef NativeFileShare = Future<ShareResult> Function(ShareParams params);

/// Shares an immutable byte-for-byte copy, never a rasterized reading cache.
/// Copies outlive the share sheet: receiving apps can read them asynchronously.
class ScoreShareService {
  ScoreShareService({this.temporaryDirectory, NativeFileShare? share})
    : _share = share ?? SharePlus.instance.share;

  static final instance = ScoreShareService();
  final Directory? temporaryDirectory;
  final NativeFileShare _share;
  static const retention = Duration(days: 7);

  Future<File> prepareOriginal({
    required String filePath,
    String? fileName,
    Future<void> Function()? validate,
    void Function()? checkCancelled,
  }) async {
    await validate?.call();
    final source = File(filePath);
    final before = await source.stat();
    if (before.type != FileSystemEntityType.file || before.size == 0) {
      throw const FileSystemException('Original score is unavailable.');
    }
    final name = p.posix.basename(
      (fileName ?? p.basename(filePath)).replaceAll('\\', '/'),
    );
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Invalid score file name.');
    }
    final root = Directory(
      p.join(
        (temporaryDirectory ?? await getTemporaryDirectory()).path,
        'score-reader-shares',
      ),
    );
    await root.create(recursive: true);
    await _removeExpired(root);
    final directory = await root.createTemp('original-');
    try {
      final copy = File(p.join(directory.path, name));
      if (checkCancelled == null) {
        await source.copy(copy.path);
      } else {
        final sink = copy.openWrite();
        try {
          await for (final chunk in source.openRead()) {
            checkCancelled();
            sink.add(chunk);
            await sink.flush();
          }
          checkCancelled();
        } finally {
          await sink.close();
        }
      }
      final after = await source.stat();
      if (after.type != FileSystemEntityType.file ||
          before.size != after.size ||
          before.modified != after.modified ||
          await copy.length() != before.size) {
        throw const FileSystemException(
          'Score changed while preparing a copy.',
        );
      }
      return copy;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _removeExpired(Directory root) async {
    final cutoff = DateTime.now().subtract(retention);
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory ||
          !p.basename(item.path).startsWith('original-')) {
        continue;
      }
      try {
        if ((await item.stat()).modified.isBefore(cutoff)) {
          await item.delete(recursive: true);
        }
      } catch (_) {
        // Cleanup cannot block sharing; never touch files outside this cache.
      }
    }
  }

  Future<ShareResult> share({
    required String filePath,
    required Rect origin,
    String? fileName,
    Future<void> Function()? validate,
  }) async {
    if (!origin.isFinite || origin.isEmpty) {
      throw const FormatException('Share sheet requires a visible anchor.');
    }
    final copy = await prepareOriginal(
      filePath: filePath,
      fileName: fileName,
      validate: validate,
    );
    return sharePrepared(copy, origin);
  }

  Future<ShareResult> sharePrepared(File copy, Rect origin) {
    if (!origin.isFinite || origin.isEmpty) {
      throw const FormatException('Share sheet requires a visible anchor.');
    }
    return _share(
      ShareParams(files: [XFile(copy.path)], sharePositionOrigin: origin),
    );
  }

  Future<void> discardPrepared(File file) async {
    final directory = file.parent;
    if (!p.basename(directory.path).startsWith('original-') ||
        p.basename(directory.parent.path) != 'score-reader-shares') {
      throw StateError(
        'Refusing to remove a directory outside the share cache.',
      );
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Rect _shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  final screen = Offset.zero & MediaQuery.sizeOf(context);
  if (box is RenderBox && box.hasSize && box.attached) {
    final rect = (box.localToGlobal(Offset.zero) & box.size).intersect(screen);
    if (rect.isFinite && !rect.isEmpty) return rect;
  }
  return Rect.fromCenter(center: screen.center, width: 1, height: 1);
}

enum _ScoreShareKind { original, annotated }

Future<void> shareScore(
  BuildContext context, {
  required String filePath,
  String? fileName,
  Future<void> Function()? validate,
  Future<bool> Function()? beforeShare,
  ExportAnnotations? annotationsFor,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  File? prepared;
  var exporting = false;
  var exportComplete = false;
  try {
    if (beforeShare != null && !await beforeShare()) return;
    if (!context.mounted) return;
    final kind = await showModalBottomSheet<_ScoreShareKind>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('分享原文件'),
              subtitle: const Text('保留原格式与清晰度'),
              onTap: () => Navigator.pop(context, _ScoreShareKind.original),
            ),
            ListTile(
              leading: const Icon(Icons.edit_document),
              title: const Text('分享带批注的 PDF 副本'),
              subtitle: const Text('全部页面与批注 · 图像化 PDF'),
              onTap: () => Navigator.pop(context, _ScoreShareKind.annotated),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    final service = ScoreShareService.instance;
    late ShareResult result;
    if (kind == _ScoreShareKind.original) {
      final original = await service.prepareOriginal(
        filePath: filePath,
        fileName: fileName,
        validate: validate,
      );
      if (!context.mounted) {
        await service.discardPrepared(original);
        return;
      }
      result = await service.sharePrepared(original, _shareOrigin(context));
    } else {
      exporting = true;
      final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
      final output = await _exportWithProgress(context, (
        cancellation,
        progress,
      ) async {
        prepared = await service.prepareOriginal(
          filePath: filePath,
          fileName: fileName,
          validate: validate,
          checkCancelled: cancellation.check,
        );
        cancellation.check();
        return AnnotatedPdfExporter().export(
          original: prepared!,
          annotationsFor: annotationsFor ?? (_) => const [],
          cancellation: cancellation,
          onProgress: progress,
          textFontFamily: fontFamily,
        );
      });
      exportComplete = true;
      if (!context.mounted) {
        await service.discardPrepared(prepared!);
        return;
      }
      result = await service.sharePrepared(output, _shareOrigin(context));
    }
    if (context.mounted && result.status == ShareResultStatus.dismissed) {
      messenger?.showSnackBar(const SnackBar(content: Text('已取消分享')));
    }
  } catch (failure) {
    if (prepared != null && !exportComplete) {
      await ScoreShareService.instance.discardPrepared(prepared!);
    }
    if (context.mounted) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            failure is ExportCancelled
                ? '已取消导出'
                : exporting
                ? '无法导出批注副本，请检查文件和可用空间。'
                : '无法分享原文件，请确认文件已下载且仍可读取。',
          ),
        ),
      );
    }
  }
}

Future<File> _exportWithProgress(
  BuildContext context,
  Future<File> Function(ExportCancellation, void Function(int, int)) operation,
) async {
  final cancellation = ExportCancellation();
  final progress = ValueNotifier<(int, int)>((0, 0));
  final presented = Completer<BuildContext>();
  final closed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      if (!presented.isCompleted) presented.complete(context);
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在生成批注 PDF'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: value.$2 <= 0 ? null : value.$1 / value.$2,
                ),
                const SizedBox(height: 16),
                Text(
                  cancellation.cancelled
                      ? '正在取消…'
                      : value.$2 == 0
                      ? '正在准备原文件…'
                      : '${value.$1} / ${value.$2} 页',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancellation.cancel();
                progress.value = (progress.value.$1, -1);
              },
              child: const Text('取消'),
            ),
          ],
        ),
      );
    },
  );
  final dialog = await presented.future;
  try {
    return await operation(
      cancellation,
      (complete, total) => progress.value = (complete, total),
    );
  } finally {
    if (dialog.mounted) Navigator.of(dialog).pop();
    await closed;
    progress.dispose();
  }
}

class ShareAction extends StatefulWidget {
  const ShareAction({
    super.key,
    required this.filePath,
    this.fileName,
    this.validate,
    this.beforeShare,
    this.annotationsFor,
    this.tooltip = '分享',
  });
  final String filePath;
  final String? fileName;
  final Future<void> Function()? validate;
  final Future<bool> Function()? beforeShare;
  final ExportAnnotations? annotationsFor;
  final String tooltip;

  @override
  State<ShareAction> createState() => _ShareActionState();
}

class _ShareActionState extends State<ShareAction> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _busy ? '正在分享' : widget.tooltip,
    onPressed: _busy
        ? null
        : () async {
            setState(() => _busy = true);
            await shareScore(
              context,
              filePath: widget.filePath,
              fileName: widget.fileName,
              validate: widget.validate,
              beforeShare: widget.beforeShare,
              annotationsFor: widget.annotationsFor,
            );
            if (mounted) setState(() => _busy = false);
          },
    icon: _busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.ios_share_outlined),
  );
}
