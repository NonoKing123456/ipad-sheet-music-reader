# iPad Sheet Music Reader

Source-only application repository for **0.8.0+13**. No scores, annotations, set lists, credentials, private fixtures or build outputs are included.

Windows can add independent score folders with **添加谱库文件夹**. Each keeps its original hierarchy. Search results identify the source and parent folder. New sources index metadata first; content is hashed only when opened or selected, or when the user explicitly requests full verification of the current source. Windows attribute-only file IDs preserve identity across renames and folder moves within one source.

iPad updates the directory and selected offline content. New sources default to zero downloads; choose a whole source, folder or individual score after reviewing its count and size. Existing whole-library preferences and pairing remain. Older clients remain confined to the migrated original source and cannot receive new roots automatically. Removing a download keeps ink and set-list references.

Metadata, selection intent and verified readable content are separate. Interrupted updates keep the last readable revision and its matching ink until a replacement is completely verified. A small checksummed resolution journal preserves completed objects if the full directory snapshot cannot be saved. Storage failures stop later requests; source-file failures do not prevent other safe downloads or exchange of saved reader state.

Reading tools hidden means vertical movement is locked, including while zoomed; pinching keeps the viewport Y center fixed. Showing annotation tools allows bounded vertical paper movement. Closing tools resets centered fit and cancels stale gestures/sampling. Touch never draws ink. The 90 ms ready-gated page transition, ordered pedals, compact sizing tools and independent eyedropper sample are retained.

Connect Windows and iPad on the same network. Pair once using the computer QR, then use **更新目录与所选内容**. Keep the same bundle ID and local signing identity when updating; do not uninstall or clear existing data.

The workflow uses Flutter **3.47.8**, standard public **macos-26** and Xcode **26.6**. It verifies **IOS / arm64** outputs and publishes an unsigned IPA, checksum and build information as a prerelease. Local signing is required before installation. No Apple credentials or personal scores are uploaded. Use only the approved public repository and standard free runner; no paid/private/larger runner fallback or Actions artifact storage.

Workflow-path pushes trigger the build. Owner manual dispatch requires `public_source_confirmed`. The reviewed source archive SHA256 is recorded in the workflow. Keep the exact source allowlist.

Focused deterministic tests and independent review passed. The large-data fixture represents over 100 GB logically with a few synthetic bytes; it is not a real 100 GB throughput benchmark. Physical iPad installation and hardware behavior still require verification.
