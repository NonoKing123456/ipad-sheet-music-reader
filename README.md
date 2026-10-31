# iPad Sheet Music Reader

Source-only application repository for **0.8.2+15**. Personal scores, ink, set lists, credentials, private probes and build outputs are excluded.

Windows keeps independent score folders in their original hierarchy. iPad downloads selected sources, folders or scores. Folder badges distinguish none, partial and all current versions downloaded; completed folders hide redundant download actions. Existing pairing, readable old revisions, annotations and set-list references remain supported.

Reading fit stays centered; zoomed paper supports bounded panning. Image decoding is serialized with foreground priority, latest-target coalescing and resource leases. Image metadata no longer decodes a redundant frame. Large iOS images use ImageIO target-size downsampling; small images keep the existing pixel path. Original files are never rewritten.

The transparent page dots seek while dragging, use bounded visual points and preserve ordered pedals, actual presented-page bookmarks and annotation page identity. Actual pen-down hides the dots and reaches the canvas, including the bottom control area. Hidden tools hide the dots. Zoom buttons and fit remain in the top controls; percentages and the solid bottom bar are removed. New-ink smoothing and the 90 ms page transition are retained.

Pair once on the same network using the Windows QR, then use **更新目录与所选内容**. Preserve the bundle ID and local signing identity when updating; do not uninstall or clear data.

The unsigned workflow uses fixed Flutter **3.47.8**, standard public **macos-26** and Xcode **26.6**. It runs the shared ImageIO production core on a synthetic large PNG in a separate decode process, records RSS and cleanup evidence, then builds and verifies **IOS / arm64**. The new native smoke and iOS path still require a successful cloud run; local Windows mechanisms and focused tests have been independently reviewed. macOS RSS does not establish an iPad memory limit or explain a device Jetsam report.

The workflow publishes only an unsigned IPA, checksum and build information as a prerelease. Local signing is required. No Apple credentials or private scores are uploaded. Keep the exact reviewed source allowlist and standard free runner. Workflow-path pushes trigger builds; owner manual dispatch requires `public_source_confirmed`.
