# iPad Sheet Music Reader

Source-only application repository for **0.8.1+14**. Scores, annotations, set lists, credentials and build outputs are excluded.

Windows keeps independent score folders in their original hierarchy. iPad updates the directory and downloads selected scores or folders. Existing pairing, cached readable revisions, ink and set-list references remain supported.

Reading at fit stays centered. Zoomed paper supports bounded one- and two-finger panning; closing annotation tools resets fit and cancels stale gestures. Compact directory badges show offline or pending-update status. Newly captured ink uses incremental smoothing with one shared polyline for preview, persistence and local erasure; existing ink is unchanged. Touch never draws ink. The 90 ms page transition and ordered pedals are retained.

Pair once on the same network using the Windows QR, then use **更新目录与所选内容**. Preserve the bundle ID and local signing identity when updating; do not uninstall or clear data.

The unsigned iPad workflow uses fixed Flutter **3.47.8**, public standard **macos-26** and Xcode **26.6**. It verifies **IOS / arm64** and publishes the unsigned IPA, checksum and build information as a prerelease. Local signing is required for installation. No Apple credentials or personal scores are uploaded. Keep the exact reviewed source allowlist and standard free runner.

Workflow-path pushes trigger the build. Owner manual dispatch requires `public_source_confirmed`. The workflow records the reviewed source archive SHA256. Focused automated checks and independent review passed; physical iPad writing and pedal feel still require device feedback.
