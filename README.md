# iPad Sheet Music Reader

Source-only application repository for **0.8.3+16**. Personal scores, ink, set lists, credentials, private probes and build outputs are excluded.

Windows preserves independent score folders and their hierarchy. iPad downloads selected sources, folders or scores. Folder icons show none, partial and all current versions downloaded; completed folders hide redundant download actions. Set lists can include catalog entries before download, show readiness and prepare only their confirmed missing or outdated contents. Readable old versions remain available when the computer is offline; failed preparation preserves the list and other offline selections.

Partial erasing preserves stroke layers, including undo and reopening. Three-way synchronization preserves causal drawing order across clock differences. Contradictory order branches and their referenced geometry remain recorded without changing ReaderState schema 2. Failed pending erasures must save before synchronization.

Reading keeps bounded zoom and panning, live transparent page dots, ordered pedals, presented-page bookmarks and new-ink smoothing. Large iOS images use serialized, target-size ImageIO downsampling with foreground priority and resource leases; original files are never rewritten. Visible foreground iOS readers now request wakefulness and release it when covered, exited or backgrounded. The wake bridge still requires the final iOS build and device confirmation.

Pair once on the same network using the Windows QR, then use **更新目录与所选内容**. Preserve the bundle ID and local signing identity when updating; do not uninstall or clear data.

The unsigned workflow fixes Flutter **3.47.8**, standard public **macos-26** and Xcode **26.6**. Its shared ImageIO production-core smoke uses a synthetic large PNG in a separate decode process, then the workflow builds and verifies **IOS / arm64**. That smoke passed for 0.8.2 on macOS; its RSS is not an iPad memory limit or device Jetsam diagnosis. The 0.8.3 cloud build has not run at source preparation time.

Only the unsigned IPA, checksum and build information are published as a prerelease. Local signing is required. No Apple credentials or private scores are uploaded. Keep the reviewed source allowlist and standard free runner. Workflow-path pushes trigger builds; owner manual dispatch requires `public_source_confirmed`.
