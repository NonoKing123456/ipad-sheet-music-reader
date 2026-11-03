# Flutter semantics fix

The framework source patch is from Flutter PR #193372, commit c0c4d54 (merged as 7d952a3):
https://github.com/flutter/flutter/pull/193372

Copyright 2014 The Flutter Authors. All rights reserved. Distributed under the BSD-3-Clause license in [FLUTTER-LICENSE](FLUTTER-LICENSE).

The iOS build applies this patch to Flutter revision 737ba8f885dc774b53b442759999a312c9461e4e and verifies the semantics.dart Git blob before (5cc2d64d6d0e1f13a26a2ece44232feef452c72e) and after (5c2ff4c3562ef1844a660f96d81733172d998705). It prevents orphaned OverlayPortal nodes from entering accessibility traversal updates. No Dart CPU profiler changes are applied by the iOS workflow.
