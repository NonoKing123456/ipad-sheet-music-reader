# Flutter semantics patch: PR #193372

This carries the upstream `packages/flutter/lib/src/semantics/semantics.dart` changes for [Flutter PR #193372](https://github.com/flutter/flutter/pull/193372), specifically [commit `c0c4d54`](https://github.com/flutter/flutter/commit/c0c4d54) (merged to master as `7d952a3`). The PR addresses orphaned OverlayPortal traversal semantics by excluding nodes whose traversal parent is absent or itself excluded. The upstream Flutter SDK source is BSD-3-Clause licensed; see [FLUTTER-LICENSE](FLUTTER-LICENSE). This patch file contains only the upstream framework source diff; Flutter's upstream test changes are not applied to the SDK.

The semantics apply script is deliberately pinned to the local SDK revision `737ba8f885dc774b53b442759999a312c9461e4e`, pre-patch `semantics.dart` Git blob `5cc2d64d6d0e1f13a26a2ece44232feef452c72e`, and post-patch blob `5c2ff4c3562ef1844a660f96d81733172d998705`. It resolves `flutter.bat` from `PATH` by default or accepts `-FlutterRoot`, checks the source and patch applicability before writing, backs up the original file under `backups/`, changes only `packages/flutter/lib/src/semantics/semantics.dart`, verifies the post-patch hash and reverse applicability, and treats only that exact post-patch source as an idempotent no-op. Once the profiler patch below is applied, it also verifies that `packages/flutter_tools/lib/src/commands/test.dart` is either the pinned original hash or the exact pinned profiler-patch hash; any other SDK changes are rejected.

Apply from the product repository with:

```powershell
powershell -ExecutionPolicy Bypass -File tools/flutter-patches/apply-193372.ps1
```

To undo the patch, use the same patch in reverse from the SDK root:

```powershell
git -C D:\WorkSpace\.tools\flutter apply --reverse D:\WorkSpace\iPad-Sheet-Music-Reader\tools\flutter-patches\193372-semantics.patch
```

The script does not run Flutter or tests.

## Windows test-host profiler workaround

Dart SDK issue [#64627](https://github.com/dart-lang/sdk/issues/64627) links the Windows `flutter_tester` crash to Flutter issue [#191069](https://github.com/flutter/flutter/issues/191069): the Dart sampling profiler's native stack walker can dereference an invalid frame pointer. This SDK's `flutter test` starts `flutter_tester` with Dart profiling enabled and did not expose a switch. The local tools-only patch adds `--[no-]enable-dart-profiling` to `flutter test` (default remains `true`) and passes that value to `DebuggingOptions.enabled`.

`apply-test-profiler.ps1` is pinned to the same SDK revision, `test.dart` pre-patch blob `78f4cd5a4c3c2fe6339c7b80e2b970de697ff4f6`, and post-patch blob `b6515e9c3335bb65d56e3edaa20dcd4ed81ec783`. It requires the semantics patch above, backs up only `packages/flutter_tools/lib/src/commands/test.dart`, and validates the resulting SDK worktree contains exactly those two pinned modified files. When it first applies the source patch it also backs up and removes only `bin/cache/flutter_tools.stamp`, so Flutter rebuilds its cached tool snapshot on next invocation. If the source patch already exists, `-InvalidateToolSnapshot` explicitly requests the same narrowly scoped backup/removal.

The helper [Test-Reader.ps1](../windows/Test-Reader.ps1) applies/verifies both local patches, checks `flutter test --help` for the profiler option, invalidates the tool stamp once if an old snapshot does not expose it, then runs `flutter test --no-enable-dart-profiling`. If the option is absent after the rebuild, it stops before running tests.

Disabling this flag removes CPU sampling from the `flutter_tester` command line; it does not skip tests, assertions, coverage, or the test runner. Other Flutter commands keep their existing profiling defaults.
