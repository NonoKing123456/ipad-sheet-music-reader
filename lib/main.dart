import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'dart:io';

import 'package:path/path.dart' as p;

import 'reader/reader_stage.dart';
import 'library/library_controller.dart';
import 'library/library_screen.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final options = LaunchOptions.parse(arguments);
  runApp(
    ScoreReaderApp(
      initialPath: options.initialPath,
      dataDirectory: options.dataDirectory,
    ),
  );
}

class LaunchOptions {
  const LaunchOptions({this.initialPath, this.dataDirectory});
  final String? initialPath;
  final Directory? dataDirectory;

  factory LaunchOptions.parse(List<String> arguments) {
    String? file;
    Directory? data;
    for (var i = 0; i < arguments.length; i++) {
      if (arguments[i] == '--data-dir') {
        if (++i >= arguments.length || !p.isAbsolute(arguments[i])) {
          throw const FormatException(
            '--data-dir requires an absolute directory',
          );
        }
        data = Directory(p.normalize(arguments[i]));
      } else if (!arguments[i].startsWith('--') && file == null) {
        file = arguments[i];
      } else {
        throw FormatException('Unsupported argument: ${arguments[i]}');
      }
    }
    return LaunchOptions(initialPath: file, dataDirectory: data);
  }
}

class ScoreReaderApp extends StatelessWidget {
  const ScoreReaderApp({
    super.key,
    this.initialPath,
    this.libraryController,
    this.dataDirectory,
  });

  final String? initialPath;
  final LibraryController? libraryController;
  final Directory? dataDirectory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '曲谱阅读器',
      navigatorObservers: [readerRouteVisibility],
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff236459),
          surface: const Color(0xfffaf9f5),
        ),
        scaffoldBackgroundColor: const Color(0xffeeede7),
        visualDensity: VisualDensity.standard,
      ),
      home: LibraryScreen(
        controller: libraryController,
        dataDirectory: dataDirectory,
        initialPath: initialPath,
      ),
    );
  }
}
