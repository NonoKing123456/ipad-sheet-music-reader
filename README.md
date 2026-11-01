# iPad Sheet Music Reader

Source-only application repository for **0.8.4+17**. Personal scores, annotations, set lists, credentials, private probes, preview fonts and build outputs are excluded.

Update **both Windows and iPad together**, preserving the bundle ID and local signing identity. Do not uninstall or clear data. ReaderState schema 3 reads existing schema 1/2 ink without changing its geometry, identity, tombstones or drawing order, and adds typed vector text. Capability checks reject incompatible annotation exchanges before either peer changes state; existing schema 2 pending exchanges can resume. Older apps cannot safely write schema 3.

The explicit T tool supports Unicode text, including Chinese, English and punctuation, using touch, pen or Windows mouse. Text can be selected, edited, moved and deleted with session undo/redo; movement previews locally and commits once on release. Ordinary touch remains page input outside T. Two-finger zoom is retained, and cancelled or stale gestures cannot write to another page. Concurrent text edits and required order geometry remain durably recorded.

Windows local score opening now sends only file data to its reading-copy worker. Large multi-source catalogs transfer in authenticated snapshot pages of at most 512 KiB, publishing only a complete index; interruption keeps the prior directory and downloaded objects. Sources, pairing, selected-download rules and set-list links are preserved. No whole-library hashing or download is required to browse metadata.

Directory search expands from the top magnifier; refresh updates directly and parent navigation has a full touch target. Floating page dots are larger and higher, with bounded point counts and live seeking. Editing permits only the extra downward movement needed to uncover paper behind the actual top tools; the bottom dots add no pan margin. The full-page fit, ink smoothing, ordered pedals, presented-page bookmarks and layer-preserving eraser are retained.

Large iOS images continue to use serialized ImageIO downsampling with foreground priority and resource leases. Visible foreground readers request wakefulness and release it when covered or backgrounded. Original scores are never rewritten. Synthetic macOS ImageIO smoke passed in the prior release; it is not an iPad memory-limit or Jetsam diagnosis. This release's final iOS build and physical iPad input, keyboard and wake checks remain pending at source preparation time.

The unsigned workflow fixes Flutter **3.47.8**, public standard **macos-26** and Xcode **26.6**, runs the shared production-core synthetic ImageIO and storage smoke checks, then verifies **IOS / arm64**. Only the unsigned IPA, checksum and build information are published as a prerelease. Local signing is required. No Apple credentials or private scores are uploaded. Keep the reviewed allowlist and free runner; workflow-path pushes trigger builds, and owner manual dispatch requires `public_source_confirmed`.
