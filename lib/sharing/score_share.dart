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
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // A transient file lock can defer deletion to normal cache expiry.
    }
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
  ScoreShareService? shareService,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final service = shareService ?? ScoreShareService.instance;
  File? pendingShare;
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
    final annotated = kind == _ScoreShareKind.annotated;
    final file = annotated
        ? await _runShareStep(
            context,
            message: '无法导出批注副本，请检查文件和可用空间。',
            retryLabel: '重新导出',
            operation: () => _prepareAnnotatedCopy(
              context,
              service,
              filePath: filePath,
              fileName: fileName,
              validate: validate,
              annotationsFor: annotationsFor,
            ),
          )
        : await service.prepareOriginal(
            filePath: filePath,
            fileName: fileName,
            validate: validate,
          );
    pendingShare = file;
    if (file == null || !context.mounted) return;
    final result = await _runShareStep(
      context,
      message: annotated ? '批注 PDF 已生成，系统分享未成功。' : '系统分享未成功。',
      retryLabel: '重试分享',
      operation: () => service.sharePrepared(file, _shareOrigin(context)),
    );
    if (result == null) return;
    // Receivers can continue reading even after the share sheet closes.
    pendingShare = null;
    if (context.mounted && result.status == ShareResultStatus.dismissed) {
      messenger?.showSnackBar(const SnackBar(content: Text('已取消分享')));
    }
  } on ExportCancelled {
    if (context.mounted) {
      messenger?.showSnackBar(const SnackBar(content: Text('已取消导出')));
    }
  } catch (_) {
    if (context.mounted) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('无法分享原文件，请确认文件已下载且仍可读取。')),
      );
    }
  } finally {
    if (pendingShare != null) await service.discardPrepared(pendingShare);
  }
}

Future<T?> _runShareStep<T extends Object>(
  BuildContext context, {
  required String message,
  required String retryLabel,
  required Future<T> Function() operation,
}) async {
  while (context.mounted) {
    try {
      return await operation();
    } on ExportCancelled {
      rethrow;
    } catch (_) {
      if (!context.mounted) return null;
      final retry = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(retryLabel),
            ),
          ],
        ),
      );
      if (retry != true) return null;
    }
  }
  return null;
}

Future<File> _prepareAnnotatedCopy(
  BuildContext context,
  ScoreShareService service, {
  required String filePath,
  String? fileName,
  Future<void> Function()? validate,
  ExportAnnotations? annotationsFor,
}) {
  final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
  return _exportWithProgress(context, (cancellation, progress) async {
    final original = await service.prepareOriginal(
      filePath: filePath,
      fileName: fileName,
      validate: validate,
      checkCancelled: cancellation.check,
    );
    try {
      return await AnnotatedPdfExporter().export(
        original: original,
        annotationsFor: annotationsFor ?? (_) => const [],
        cancellation: cancellation,
        onProgress: progress,
        textFontFamily: fontFamily,
      );
    } catch (_) {
      await service.discardPrepared(original);
      rethrow;
    }
  });
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
