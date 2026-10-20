# Releasing the BenjaminD2023 fork

This fork ships its complete local feature set, including changes that upstream did not accept. Releases and automatic updates come from [BenjaminD2023/OhMyShot](https://github.com/BenjaminD2023/OhMyShot). Upstream releases do not replace this fork's update feed.

## Requirements

- A clean, committed checkout containing the exact release source. Increase `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig` before building. Every update needs a higher build number.
- Xcode 27 with the macOS 27 SDK, Swift 6, XcodeGen, and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`). The embedded VLM reader links MLX and requires this toolchain to compile its Metal kernels. The app's deployment target is macOS 26 and its executable is arm64.
- A working local signing configuration. The app, Sparkle framework, and embedded helpers must have valid signatures from the same team, with Hardened Runtime and library validation enabled. Keep credentials and `Config/Signing.local.xcconfig` out of Git.
- The official Sparkle **2.10.0** distribution tools. Set `SPARKLE_TOOLS` to its `bin` directory, or pass `--sparkle-tools`. Verify the downloaded distribution against its published checksum.
- The existing dedicated Sparkle Keychain account `BenjaminD2023.OhMyShot.updates`. `SUPublicEDKey` in the app must match this account. Keep the same key for future releases; packaging never generates or exports it. `--key-account` / `SPARKLE_KEY_ACCOUNT` can select another existing account. Packaging verifies that the existing account’s public key matches the app before creating artifacts.

Apple Development signing is not Developer ID notarization. The packaging script verifies signatures but does not notarize, weaken library validation, or claim that Gatekeeper will accept a public download without additional user action.

## Build and package

For the initial fork release, use version `0.2.0`, build `2`, and tag `v0.2.0-fork.1`. The tag must identify the source commit recorded in the release manifest.

```sh
DEVELOPER_DIR=/Users/benjamin/Downloads/Xcode.app/Contents/Developer \
  Scripts/build.sh Release

SPARKLE_TOOLS="$PWD/build/tools/Sparkle-2.10.0/bin" \
  Scripts/package-release.sh \
    --app build/Build/Products/Release/OhMyShot.app \
    --output build/releases/v0.2.0-fork.1 \
    --version 0.2.0 --build 2 --tag v0.2.0-fork.1
```

`Scripts/package-release.sh --help` lists all options. Packaging requires a new or empty output directory. It does not modify the built app, create a tag, or publish anything. It fails if the checkout is dirty, a requested version differs from the app, the architecture/signing checks fail, or Sparkle cannot verify the feed and update signatures.

The output contains:

- A DMG with `OhMyShot.app`, an Applications shortcut, GPL `LICENSE`, `ThirdPartyNotices.txt`, the fork's `README.md`, the complete tracked source archive, and a link to the GitHub tag's source archive.
- An app-only ZIP for Sparkle. The app itself must contain `Contents/Resources/LICENSE` and `ThirdPartyNotices.txt` before signing, so both installation methods retain the required notices. Extra disk-image notes and source archives are kept out of this ZIP.
- `appcast.xml`, signed by Sparkle's tool. Do not reformat or edit its bytes after signing.
- The source archive, `RELEASE-MANIFEST.json`, and `SHA256SUMS`. The manifest records the source commit, app version, signing team, architectures, tool fingerprints, archive hashes, and verification results. It makes no notarization claim.

## Publish and keep updates working

Publish the artifacts to the matching immutable tag in this fork. Include the signed `appcast.xml` asset in **every** normal release and mark the completed release as the latest release only after all assets are uploaded. Do not mark an incomplete draft or test release as latest.

The stable feed is:

```text
https://github.com/BenjaminD2023/OhMyShot/releases/latest/download/appcast.xml
```

The feed's enclosure points to the versioned release ZIP, such as `/releases/download/v0.2.0-fork.1/OhMyShot-0.2.0-build2-arm64.zip`. The app requires a signed feed and verifies the update before extraction. Keep this feed URL and its signing key stable; publishing a new signed feed enables the app's updater without requiring an automated CI job.

After publishing, download the public assets, check `SHA256SUMS`, and verify the downloaded feed with the same Sparkle `sign_update --account BenjaminD2023.OhMyShot.updates --verify appcast.xml` tool. Confirm that the latest-feed URL resolves to the new release and its enclosure uses the expected tag. Retain prior releases and their source tags.

See [Sparkle's publishing guide](https://sparkle-project.org/documentation/publishing/) for archive and appcast behavior. Signing/notarization credentials and release publication are separate from this local packaging script.
