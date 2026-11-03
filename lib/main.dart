import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'dart:io';
import 'dart:async';

import 'package:path/path.dart' as p;

import 'reader/reader_stage.dart';
import 'library/library_controller.dart';
import 'library/library_screen.dart';
import 'library/desktop_navigation_history.dart';
import 'theme/app_theme.dart';
import 'theme/device_layout.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final options = LaunchOptions.parse(arguments);
  runApp(
    ScoreReaderApp(
      initialPath: options.initialPath,
      dataDirectory: options.dataDirectory,
      simulateIpad: options.simulateIpad,
    ),
  );
}

class LaunchOptions {
  const LaunchOptions({
    this.initialPath,
    this.dataDirectory,
    this.simulateIpad = false,
  });
  final String? initialPath;
  final Directory? dataDirectory;
  final bool simulateIpad;

  factory LaunchOptions.parse(List<String> arguments) {
    String? file;
    Directory? data;
    var simulateIpad = false;
    for (var i = 0; i < arguments.length; i++) {
      if (arguments[i] == '--data-dir') {
        if (++i >= arguments.length || !p.isAbsolute(arguments[i])) {
          throw const FormatException(
            '--data-dir requires an absolute directory',
          );
        }
        data = Directory(p.normalize(arguments[i]));
      } else if (arguments[i] == '--simulate-ipad') {
        simulateIpad = true;
      } else if (!arguments[i].startsWith('--') && file == null) {
        file = arguments[i];
      } else {
        throw FormatException('Unsupported argument: ${arguments[i]}');
      }
    }
    return LaunchOptions(
      initialPath: file,
      dataDirectory: data,
      simulateIpad: simulateIpad,
    );
  }
}

class ScoreReaderApp extends StatefulWidget {
  const ScoreReaderApp({
    super.key,
    this.initialPath,
    this.libraryController,
    this.dataDirectory,
    this.simulateIpad = false,
  });

  final String? initialPath;
  final LibraryController? libraryController;
  final Directory? dataDirectory;
  final bool simulateIpad;

  @override
  State<ScoreReaderApp> createState() => _ScoreReaderAppState();
}

class _ScoreReaderAppState extends State<ScoreReaderApp> {
  final _history = DesktopNavigationHistory();
  late final ThemeController _theme;
  late final DeviceLayoutController _deviceLayout;
  @override
  void initState() {
    super.initState();
    _theme = ThemeController(
      directory:
          widget.dataDirectory ?? widget.libraryController?.dataDirectory,
    );
    _deviceLayout = DeviceLayoutController(simulateIpad: widget.simulateIpad);
    unawaited(_theme.load());
    _history.attach();
  }

  @override
  void dispose() {
    _history.detach();
    _theme.dispose();
    _deviceLayout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DeviceLayoutScope(
      controller: _deviceLayout,
      child: ThemeScope(
        controller: _theme,
        child: AnimatedBuilder(
          animation: _theme,
          builder: (context, _) => DesktopHistoryScope(
            history: _history,
            child: MaterialApp(
              title: '曲谱阅读器',
              navigatorObservers: [readerRouteVisibility, _history],
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (context, child) => DeviceLayoutCanvas(
                controller: _deviceLayout,
                child: child ?? const SizedBox.shrink(),
              ),
              theme: scoreReaderTheme(Brightness.light),
              darkTheme: scoreReaderTheme(Brightness.dark),
              themeMode: _theme.mode,
              home: LibraryScreen(
                controller: widget.libraryController,
                dataDirectory: widget.dataDirectory,
                initialPath: widget.initialPath,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
