import 'package:flutter/material.dart';

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

class DirectoryParentButton extends StatelessWidget {
  const DirectoryParentButton({
    super.key,
    required this.currentPath,
    required this.parentLabel,
    required this.rootLabel,
    this.onPressed,
  });
  final String currentPath, parentLabel, rootLabel;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: currentPath.isEmpty ? rootLabel : currentPath,
    child: Semantics(
      button: onPressed != null,
      label: currentPath.isEmpty ? rootLabel : '返回上一级：$parentLabel',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('directory-parent-button'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  currentPath.isEmpty
                      ? Icons.folder_outlined
                      : Icons.arrow_upward,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    currentPath.isEmpty
                        ? '$rootLabel · 根目录'
                        : '上一级 · $parentLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
