# iPad Sheet Music Reader

Source-only application repository for **0.7.1+12**. It contains no scores, annotations, set lists, credentials, private fixtures or build outputs.

The reader fits paper to the display, pairs each page with its annotations and retains the readable old page until its successor is ready. Directional transitions take 90 ms; repeated pedal key-downs are counted in order and held-key repeats are ignored. Only the next set-list score is prewarmed. Normal page boundaries remain silent.

System stylus events write and locally erase. Touch never draws ink. Expanding annotation tools enables bounded vertical paper movement at fit size; closing tools immediately restores centered fit and invalidates old touch/sample events. Reading at fit remains centered, with normal bounded pan after zoom. Horizontal fit swipes and PageUp/PageDown still turn pages.

Compact tool icons support press-and-horizontal-drag sizing. The eyedropper shows its independent last successful paper-color sample inside the same button. Its explicit menu offers reuse or resampling. Sampling excludes existing ink and UI; opaque covering strokes remain ordinary undoable annotations. Recoverable errors and unsaved work remain available through a compact status entry. Bitmap image information copies only display measurements and a short existing content fingerprint.

On Windows choose a score folder and use **连接我的 iPad**. On iPad scan the pairing QR once, then sync on the same network while the Windows reader is open. Existing authenticated pairing is retained. Do not uninstall or clear data when updating; keep the same bundle ID and local signing identity.

The workflow uses Flutter **3.47.8**, standard public **macos-26** and Xcode **26.6**. It verifies native **IOS / arm64** outputs and publishes an unsigned IPA, checksum and build information as a prerelease. The unsigned IPA needs local signing before installation. No Apple credentials or personal scores are uploaded. Only the approved public repository and standard free runner are allowed; no paid/private/larger runner fallback or Actions artifact storage.

Pushes trigger the workflow only when its workflow path changes. Owner-only manual dispatch requires `public_source_confirmed`. Reviewed source archive SHA256 is recorded in the workflow. Keep all source changes within the exact `.gitignore` allowlist.

Focused Windows-hosted tests and independent review passed. These checks cover synthetic touch/stylus, menu, readiness and mobile geometry behavior; they are not physical iPad or pedal measurements. Version 0.7.1 still needs installation and real-device verification.
