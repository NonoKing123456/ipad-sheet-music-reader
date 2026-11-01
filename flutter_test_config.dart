import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

/// Explicit, process-local workaround candidate for the Windows Dart 3.13
/// native sampling crash. No SDK, product code or test assertion is changed.
/// Default runs use the normal sampling configuration.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  const enabled = bool.fromEnvironment(
    'SCORE_READER_WINDOWS_TEST_SAMPLING_WORKAROUND',
  );
  if (!enabled) {
    await testMain();
    return;
  }
  if (!Platform.isWindows || !Platform.version.startsWith('3.13.')) {
    throw StateError(
      'The opt-in sampling workaround is restricted to Windows / Dart 3.13. '
      'Run normal tests or review the workaround for this SDK.',
    );
  }
  final uri = (await Service.getInfo()).serverUri;
  if (uri == null) {
    throw StateError('Opt-in tests require --enable-vmservice --no-dds.');
  }
  final socket = await WebSocket.connect(
    uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
  ).timeout(const Duration(seconds: 10));
  final pending = <int, Completer<Map<String, dynamic>>>{};
  var nextId = 0;
  void failPending(Object failure) {
    for (final response in pending.values) {
      if (!response.isCompleted) response.completeError(failure);
    }
  }

  final subscription = socket.listen(
    (event) {
      final response = Map<String, dynamic>.from(
        jsonDecode(event is String ? event : utf8.decode(event as List<int>))
            as Map,
      );
      final completer = pending[response['id']];
      if (completer == null || completer.isCompleted) return;
      if (response['error'] != null) {
        completer.completeError(StateError('VM service rejected a flag RPC.'));
      } else {
        completer.complete(
          Map<String, dynamic>.from(response['result'] as Map),
        );
      }
    },
    onError: (Object failure) => failPending(failure),
    onDone: () =>
        failPending(StateError('VM service closed before verification.')),
  );
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final id = ++nextId;
    final response = Completer<Map<String, dynamic>>();
    pending[id] = response;
    try {
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': parameters,
        }),
      );
      return await response.future.timeout(const Duration(seconds: 10));
    } finally {
      pending.remove(id);
    }
  }

  String profilePeriod(Map<String, dynamic> result) =>
      (result['flags'] as List).cast<Map>().singleWhere(
            (flag) => flag['name'] == 'profile_period',
          )['valueAsString']
          as String;
  try {
    final before = profilePeriod(await rpc('getFlagList'));
    const value = '2000000000';
    final result = await rpc('setFlag', {
      'name': 'profile_period',
      'value': value,
    });
    if (result['type'] != 'Success') {
      throw StateError('VM service did not accept the sampling flag.');
    }
    final after = profilePeriod(await rpc('getFlagList'));
    if (after != value) {
      throw StateError('Sampling flag readback did not match.');
    }
    // No VM URI/auth token is printed. This only describes this test process.
    // ignore: avoid_print
    print(
      'SCORE_TEST_SAMPLING opt_in=true windows=true dart=3.13 '
      'profile_period_before=$before profile_period_after=$after',
    );
  } finally {
    await subscription.cancel();
    await socket.close();
  }
  await testMain();
}
