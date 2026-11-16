/// Optional host diagnostics; errors and stacks may contain private data.
typedef SwallowedErrorLogger = void Function(
    String event, Object error, StackTrace stack);

/// Hosts must sanitize before logging. Unset by default in each isolate.
SwallowedErrorLogger? swallowedErrorLogger;

/// Diagnostics must never change a fallback, retry, or observer's behavior.
void reportSwallowedError(String event, Object error, StackTrace stack) {
  try {
    swallowedErrorLogger?.call(event, error, stack);
  } catch (_) {
    // A failing diagnostic sink is control flow, not another reportable error.
  }
}
