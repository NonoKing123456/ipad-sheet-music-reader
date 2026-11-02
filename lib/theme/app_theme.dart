import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App chrome only. Score pixels and annotation colours retain their originals.
ThemeData scoreReaderTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff236459),
    brightness: brightness,
    surface: dark ? const Color(0xff171c1a) : const Color(0xfffaf9f5),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff111613)
        : const Color(0xffeeede7),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.onSecondaryContainer,
      selectedTileColor: scheme.secondaryContainer,
      minTileHeight: 48,
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
}

class ThemeController extends ChangeNotifier {
  ThemeController({this.directory});

  final Directory? directory;
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;
  File? _file;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _writes = Future<void>.value();

  Future<File> _settingsFile() async => _file ??= File(
    p.join(
      (directory ?? await getApplicationSupportDirectory()).path,
      'appearance.json',
    ),
  );

  Future<void> load() async {
    final generation = _generation;
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      final name = json is Map ? json['theme'] : null;
      final mode = ThemeMode.values.where((value) => value.name == name);
      if (!_disposed && generation == _generation && mode.isNotEmpty) {
        _mode = mode.first;
        notifyListeners();
      }
    } catch (_) {
      // Appearance is optional; damaged preferences must never block the library.
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_disposed || mode == _mode) return;
    _mode = mode;
    _generation++;
    notifyListeners();
    final write = _writes.catchError((Object _) {}).then((_) async {
      final file = await _settingsFile();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'theme': mode.name}),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _writes = write;
    await write;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()?.notifier;
}

class ThemeAction extends StatelessWidget {
  const ThemeAction({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    return PopupMenuButton<ThemeMode>(
      key: const ValueKey('theme-action'),
      tooltip: controller.mode == ThemeMode.system ? '外观 · 跟随系统' : '外观',
      icon: Icon(
        Theme.of(context).brightness == Brightness.dark
            ? Icons.dark_mode_outlined
            : Icons.light_mode_outlined,
      ),
      initialValue: controller.mode,
      onSelected: (mode) async {
        try {
          await controller.setMode(mode);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('外观已切换，偏好暂未保存。')));
          }
        }
      },
      itemBuilder: (_) => [
        for (final entry in const [
          (ThemeMode.system, Icons.brightness_auto_outlined, '跟随系统'),
          (ThemeMode.light, Icons.light_mode_outlined, '浅色'),
          (ThemeMode.dark, Icons.dark_mode_outlined, '深色'),
        ])
          PopupMenuItem(
            value: entry.$1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  child: controller.mode == entry.$1
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                const SizedBox(width: 8),
                Icon(entry.$2, size: 20),
                const SizedBox(width: 12),
                Text(entry.$3),
              ],
            ),
          ),
      ],
    );
  }
}
