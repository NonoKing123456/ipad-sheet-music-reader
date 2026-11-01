import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:reader_state/reader_state.dart';

int _activeEditors = 0;
bool get readerTextEditorActive => _activeEditors > 0;
VoidCallback beginReaderTextEditing() {
  _activeEditors++;
  var ended = false;
  return () {
    if (!ended) {
      ended = true;
      _activeEditors--;
    }
  };
}

/// One reader's top T controls. A draft owns the controls until explicit done,
/// cancel, or navigation; another mounted paper cannot steal an open draft.
class ReaderTextEditorController extends ChangeNotifier {
  AnnotationTextFont font = AnnotationTextFont.system;
  bool editing = false;
  Object? _owner;
  VoidCallback? _releaseSelection, onEdit, onDelete, onCancel, onDone;
  ValueChanged<AnnotationTextFont>? onFont;
  bool _disposed = false;
  bool availableTo(Object owner) => !editing || identical(_owner, owner);
  bool bind(
    Object owner, {
    required AnnotationTextFont font,
    required bool editing,
    required VoidCallback release,
    ValueChanged<AnnotationTextFont>? onFont,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
    VoidCallback? onCancel,
    VoidCallback? onDone,
  }) {
    if (!availableTo(owner)) return false;
    if (!identical(_owner, owner)) {
      final old = _releaseSelection;
      _owner = null;
      _releaseSelection = null;
      old?.call();
    }
    _owner = owner;
    _releaseSelection = release;
    this.font = font;
    this.editing = editing;
    this.onFont = onFont;
    this.onEdit = onEdit;
    this.onDelete = onDelete;
    this.onCancel = onCancel;
    this.onDone = onDone;
    _changed();
    return true;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _releaseSelection = null;
    editing = false;
    onFont = null;
    onEdit = onDelete = onCancel = onDone = null;
    _changed();
  }

  void changeFont(AnnotationTextFont value) {
    font = value;
    onFont?.call(value);
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Embedded in the existing reader annotation bar, never above the text frame.
class ReaderTextFormatControls extends StatelessWidget {
  const ReaderTextFormatControls({super.key, required this.controller});
  final ReaderTextEditorController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<AnnotationTextFont>(
          key: const ValueKey('annotation-font'),
          value: controller.font,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(
              value: AnnotationTextFont.system,
              child: Text('系统'),
            ),
            DropdownMenuItem(
              value: AnnotationTextFont.serif,
              child: Text('宋体'),
            ),
            DropdownMenuItem(
              value: AnnotationTextFont.monospace,
              child: Text('等宽'),
            ),
          ],
          onChanged: (font) {
            if (font != null) controller.changeFont(font);
          },
        ),
        if (!controller.editing && controller.onEdit != null)
          IconButton(
            tooltip: '编辑文字',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            onPressed: controller.onEdit,
            icon: const Icon(Icons.edit_outlined, size: 20),
          ),
        if (!controller.editing && controller.onDelete != null)
          IconButton(
            tooltip: '删除文字',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            onPressed: controller.onDelete,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        if (controller.editing) ...[
          IconButton(
            tooltip: '取消文字编辑',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            onPressed: controller.onCancel,
            icon: const Icon(Icons.close, size: 20),
          ),
          IconButton(
            tooltip: '完成文字编辑',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            onPressed: controller.onDone,
            icon: const Icon(Icons.check, size: 22),
          ),
        ],
      ],
    ),
  );
}
