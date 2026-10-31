# iPad Sheet Music Reader

Source-only iPad build repository for version **0.4.1+6**. No scores, user state, credentials, or local build outputs are included.

The workflow builds a native iPad/iPhone device application with Flutter **3.47.8** (revision `737ba8f885dc774b53b442759999a312c9461e4e`), standard **macos-26 arm64**, and **Xcode 26.6**. It creates an **unsigned** `Payload/Runner.app` IPA container, SHA-256 checksum, and build information. Every nested Mach-O must report **IOS / arm64** before packaging.

## Build and download

1. This repository contains only the reviewed application source, which the owner has authorized for public release. Never add scores, user state, credentials, or unreviewed working files.
2. Only this public repository, its owner, and the standard runner are allowed. GitHub provides standard hosted runners free for public repositories; private and larger runners are excluded. No Actions artifact storage is used. Outputs are published as public prerelease assets, each strictly smaller than 2 GiB. See [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [standard runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), and [release limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
3. The initial `main` push containing `.github/workflows/ios-unsigned.yml` triggers the build. Later pushes trigger it only when that workflow path changes. For a manual run, as the owner open **Actions → iOS unsigned device build → Run workflow**, and enable `public_source_confirmed` (default false). Pull requests do not trigger it. Do not switch to a private repository or paid runner to resolve a failure.
4. Download the three assets from prerelease `unsigned-ipad-<run number>-<attempt>`, inspect build information, and verify the IPA checksum. The job has a 25-minute limit; a failure produces no successful delivery claim. Prereleases are not marked latest. The job has repository contents write permission solely to publish these assets; `GH_TOKEN` is passed only to the final publishing step, and checkout credentials are not persisted.

**Status:** this workflow has only been prepared and statically checked on Windows. No macOS/iOS build, signing, installation, or iPad validation has passed yet. The unsigned IPA cannot be installed directly; later local signing and real-device checks remain necessary. Apple account credentials and signing material are never required by this workflow.
