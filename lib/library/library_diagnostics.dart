import 'package:flutter/foundation.dart';
import 'package:library_core/library_core.dart' as core;
import 'package:library_sync/library_sync.dart' as sync;
import 'package:reader_state/reader_state.dart' as reader;

bool _initialized = false;

/// Package globals are isolate-local, so worker bootstraps also call this.
void initializeLibraryDiagnostics() {
  if (_initialized) return;
  _initialized = true;
  core.swallowedErrorLogger = logLibraryFailure;
  sync.swallowedErrorLogger = logLibraryFailure;
  reader.swallowedErrorLogger = logLibraryFailure;
}

/// Log source locations only: exception text and stack URIs may contain secrets.
void logLibraryFailure(String event, Object error, StackTrace stack) {
  // Require a basename boundary; discard file/package URI prefixes entirely.
  final location = RegExp(
    r'(?:^|[/\\(\s:])([A-Za-z_][A-Za-z0-9_]*\.dart:\d+(?::\d+)?)\)?$',
  );
  final frames = stack
      .toString()
      .split('\n')
      .map((line) {
        return location.firstMatch(line.trim())?.group(1);
      })
      .whereType<String>()
      .take(8);
  debugPrint(
    'LIBRARY $event kind=${error.runtimeType} stack=${frames.join(' <- ')}',
  );
}
