import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tokens.dart';
import 'reader_icons.dart';
import 'device_layout.dart';

/// App chrome only. Score pixels and annotation colours retain their originals.
///
/// 所有颜色都来自 [ScoreTokens]（见 DESIGN.md）。这里不再出现十六进制字面量。
ThemeData scoreReaderTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final tokens = dark ? ScoreTokens.dark : ScoreTokens.light;
  final primary = tokens.pineDeep;
  final onEmphasis = tokens.onBrand;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: tokens.pine,
        brightness: brightness,
        surface: tokens.paper0,
      ).copyWith(
        primary: primary,
        onPrimary: onEmphasis,
        primaryContainer: tokens.pineWash,
        onPrimaryContainer: tokens.ink900,
        secondary: tokens.pineDeep,
        onSecondary: onEmphasis,
        secondaryContainer: tokens.pineWash,
        onSecondaryContainer: dark ? tokens.ink900 : tokens.pineDeep,
        tertiary: tokens.pineDeep,
        onTertiary: tokens.paper0,
        tertiaryContainer: tokens.pineWash,
        onTertiaryContainer: tokens.ink900,
        error: tokens.dangerInk,
        onError: tokens.paper0,
        errorContainer: tokens.dangerBg,
        onErrorContainer: tokens.dangerInk,
        surface: tokens.paper0,
        onSurface: tokens.ink900,
        surfaceContainerLowest: tokens.paper0,
        surfaceContainerLow: tokens.paper1,
        surfaceContainer: tokens.paper2,
        surfaceContainerHigh: tokens.paper2,
        surfaceContainerHighest: tokens.paper2,
        onSurfaceVariant: tokens.ink500,
        outline: tokens.ink500,
        outlineVariant: tokens.paper2,
        surfaceTint: tokens.pine,
      );
  final uiFont = defaultTargetPlatform == TargetPlatform.windows
      ? 'Segoe UI'
      : null;
  return ThemeData(
    useMaterial3: true,
    fontFamily: uiFont,
    fontFamilyFallback: defaultTargetPlatform == TargetPlatform.windows
        ? const ['Microsoft YaHei']
        : null,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.paper1,
    extensions: [tokens],
    textTheme: TextTheme(
      displayLarge: ScoreText.display.copyWith(
        color: tokens.ink900,
        fontFamily: uiFont,
      ),
      titleLarge: ScoreText.title.copyWith(
        color: tokens.ink900,
        fontFamily: uiFont,
      ),
      titleMedium: ScoreText.headline.copyWith(
        color: tokens.ink900,
        fontFamily: uiFont,
      ),
      bodyLarge: ScoreText.body.copyWith(
        color: tokens.ink700,
        fontFamily: uiFont,
      ),
      bodyMedium: ScoreText.body.copyWith(
        color: tokens.ink700,
        fontFamily: uiFont,
      ),
      bodySmall: ScoreText.caption.copyWith(
        color: tokens.ink500,
        fontFamily: uiFont,
      ),
      labelLarge: ScoreText.caption.copyWith(
        color: tokens.ink900,
        fontFamily: uiFont,
      ),
      labelMedium: ScoreText.note.copyWith(
        color: tokens.ink700,
        fontFamily: uiFont,
      ),
      labelSmall: ScoreText.micro.copyWith(
        color: tokens.ink500,
        fontFamily: uiFont,
      ),
    ),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.paper0,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.overlayAll),
      titleTextStyle: ScoreText.title.copyWith(color: tokens.ink900),
      contentTextStyle: ScoreText.body.copyWith(color: tokens.ink700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(color: tokens.hair),
    listTileTheme: ListTileThemeData(
      tileColor: Colors.transparent,
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.onSecondaryContainer,
      selectedTileColor: scheme.secondaryContainer,
      minTileHeight: 48,
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.paper0,
      surfaceTintColor: Colors.transparent,
      textStyle: ScoreText.caption.copyWith(color: tokens.ink900),
      menuPadding: const EdgeInsets.all(ScoreSpace.sm),
      shape: const RoundedRectangleBorder(borderRadius: ScoreRadius.overlayAll),
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
    bool currentDark() => switch (controller.mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => Theme.of(context).brightness == Brightness.dark,
    };
    final dark = currentDark();
    return IconButton(
      key: const ValueKey('theme-action'),
      tooltip: dark ? '切换到浅色' : '切换到深色',
      style: IconButton.styleFrom(
        fixedSize: Size.square(
          DeviceLayoutScope.isCompact(context)
              ? ScoreLayout.touchTarget
              : ScoreLayout.desktopTarget,
        ),
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(
          borderRadius: ScoreRadius.controlAll,
        ),
      ),
      icon: ReaderIcon(dark ? ReaderGlyph.sun : ReaderGlyph.moon),
      onPressed: () async {
        try {
          await controller.setMode(
            currentDark() ? ThemeMode.light : ThemeMode.dark,
          );
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('外观已切换，偏好暂未保存。')));
          }
        }
      },
    );
  }
}
