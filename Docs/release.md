# Releases and updates

OhMyShot is released on GitHub: each release carries a zip of the app and the Sparkle appcast that lists it, and the
app looks for updates in the latest release's appcast. Nothing has been released yet. Releases are signed with the
maintainer's Developer ID (team DT6YQU64FF, since 2026-11-02) and notarized; `Scripts/release.sh` stops before it builds
anything on a Mac without the certificate or notarytool's credentials, and `Scripts/release.sh --dry-run` runs the rest
of it with the Mac's own development identity. The release workflow runs the same script on GitHub Actions for a pushed
tag (Releasing from CI, below).

## How the app updates

- **Only release builds look.** `SUFeedURL` is set in `Config/Release.xcconfig`:
  `https://github.com/MMFoundation/OhMyShot/releases/latest/download/appcast.xml`. Debug builds ("OhMyShot Dev") have no
  feed, so they never look and show neither Settings › General › Updates nor Check for Updates… in the menu.
- **Everything is signed.** The appcast and every archive are signed with the project's EdDSA key; the public half is
  `SUPublicEDKey` in `Config/Info.plist`. The app refuses an appcast or an archive that doesn't match it
  (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`).
- **No timer of its own.** Sparkle's schedule is off (`SUEnableAutomaticChecks` is NO), since it would keep a timer in
  the app. While Settings › General › Check for updates automatically is on (the default), `UpdateController` asks the
  system's background activity scheduler for a look about once a day (24 h, ± 4 h, utility), and skips a look less than
  18 h after the last one. The app holds nothing while idle.
- **Gently.** A version found by the app's own look waits in the menu bar menu ("Update to Version 0.2.0…") and in
  Settings ("Version 0.2.0 is available."), rather than putting a window in front of what the person is doing. Sparkle
  shows its own window at once only when it would anyway: the app has just launched, or the Mac was left idle. Check for
  Updates… and Check Now always show Sparkle's windows. Nothing is downloaded before the person says so:
  `SUAllowsAutomaticUpdates` is NO, so Sparkle never offers to download and install by itself.

## The signing key

The EdDSA key was made on 2026-10-20 with Sparkle's `generate_keys --account ohmyshot` and lives in the login keychain
of the maintainer's Mac, account `ohmyshot`. Keep a backup of it somewhere safe and offline: without it, no copy of the
app already installed can ever be updated again (a new key needs a new app, or a release signed with both).

- Back it up: `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ohmyshot -x <file>`
- Put it on another Mac: `generate_keys --account ohmyshot -f <file>`
- See the public key: `generate_keys --account ohmyshot -p` (it must match `SUPublicEDKey`)

The tools are Sparkle's, in the package's artifacts once the project has resolved its packages (any build does).

## One-time setup for releases

1. A Developer ID Application certificate in the login keychain (Apple Developer Program, Certificates, Developer ID
   Application). `security find-identity -v -p codesigning` lists it. The app is built with the development team in
   `Config/Signing.local.xcconfig` and signed again with Developer ID, so that file stays as it is (changing its team
   would cost the Dev app its Screen Recording permission).
2. notarytool's credentials in the keychain, under the profile name the script uses:
   `xcrun notarytool store-credentials OhMyShot --apple-id <apple id> --team-id DT6YQU64FF`. It asks for an
   app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords, in the form
   `abcd-efgh-ijkl-mnop`); the account's own password gets "HTTP status code: 401. Invalid credentials".
3. The Sparkle key (above).
4. `gh` signed in to an account that can make releases on MMFoundation/OhMyShot.

## The package versions

The generated project isn't committed, so the package versions it resolves are kept in `Config/Package.resolved`, a copy
of the project's own `OhMyShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
`Scripts/bootstrap.sh` puts it into a project that has none (a new checkout), and `Scripts/release.sh` builds with it
and nothing else (`-onlyUsePackageVersionsFromResolvedFile`), on a Mac and in CI alike. It has to agree with the
packages' own `Package.resolved` files and with `project.yml`. `Scripts/acknowledgments.py` and AcknowledgmentsTests
stop at a package it leaves out (Xcode resolves that one as it likes, even when told to keep to the file) or pins at
another version. A release also stops after its build when a checkout isn't at its committed version or the notices
don't match (`acknowledgments.py --check`).

To change a package's version, change it (in a package's `Package.swift`, in `project.yml`, or with Xcode's File ›
Packages › Update to Latest Package Versions). Bring the packages' own files along with `swift package resolve` (or
`update`) with `--package-path Packages/OhMyShotKit` and `Packages/OhMyShotVLM` (which pins OhMyShotKit's packages too),
build, copy the project's file back, and make the notices again (step 3 below):

```sh
cp OhMyShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Config/Package.resolved
```

Its `originHash` differs from one checkout to another, and Xcode doesn't hold that against it. On 2026-11-02 a fresh
resolve with another checkout's hash checked out exactly the versions in the file, an older one than the newest
allowed included, and a version outside a package's requirements stopped the build.

## Making a release

1. Raise `MARKETING_VERSION` (what people see, such as 0.2.0) and `CURRENT_PROJECT_VERSION` (a whole number that Sparkle
   compares: it has to be higher than every build in the feed) in `Config/Base.xcconfig`.
2. Move CHANGELOG.md's Unreleased entries under `## [<version>] - <date>`. That section becomes the release notes in
   Sparkle's window and on the release page.
3. Make the notices again after a build (`Scripts/build.sh Release`): `python3 -I Scripts/acknowledgments.py` writes
   `App/Acknowledgments.md` (Settings › About › Acknowledgments…) from the licenses of the packages the app is built
   with, which ask for their notices to go with every copy. It stops at a package it doesn't know (add it to `PACKAGES`
   in the script) and at a checkout of another version than the one resolved; the unit tests fail while a resolved
   package has no notice of its version.
4. Commit, then run `Scripts/release.sh`. With nothing uncommitted, it:
   - fetches the current appcast and stops if its build number isn't higher than the feed's,
   - builds the Release app for Apple silicon, stripped and without the debugging entitlement (`get-task-allow`) that a
     development identity adds, with the package versions in `Config/Package.resolved` alone, and stops if the
     notices don't match them,
   - signs every piece again with Developer ID from the inside out, as Sparkle's documentation does: Sparkle's XPC
     services, Autoupdate, Updater.app, and framework (they come signed ad hoc), the text reader, the Share extension,
     then the app, each with the hardened runtime, a secure timestamp, and its own entitlements,
   - stops if any piece of code in the app isn't signed with Developer ID and the hardened runtime, or can still be
     debugged,
   - notarizes it, staples the ticket, and checks that Gatekeeper takes it as notarized. It uploads again (up to three
     times) when an upload is cut off, and waits out Apple's queue however long it is, asking once a minute and again
     after a failed asking: notarytool's own `--wait` stops at the first network error. A new team's first
     notarization took 18 hours; later ones are minutes as a rule, but have taken hours,
   - zips it to `build/release/<version>/archives/OhMyShot-<version>.zip`, and writes the release notes and the signed
     appcast beside it, keeping the versions the feed had.
5. Try the zip on a Mac (or a user account) that has an older release: Check for Updates… should offer it, install it,
   and relaunch, with Screen Recording still allowed.
6. Publish with the `gh release create …` line the script prints last. The release gets the zip and `appcast.xml`, so
   the feed URL (the latest release's `appcast.xml`) moves to it. A release marked as a pre-release isn't "latest", so
   its appcast isn't the feed.

`Scripts/release.sh --dry-run` does step 4 with this Mac's Apple Development identity and without a timestamp, and
doesn't notarize, into `build/release/<version>-dry-run/`; without a `## [<version>]` section its notes are Unreleased's.
Don't publish what it makes. (An archive and an export for Developer ID were tried first and dropped: `xcodebuild
archive` puts the MLX bundle where the script that copies its Metal library may not read, and a generic destination
builds the packages for Intel as well.)

## Releasing from CI

`.github/workflows/release.yml` does steps 4 and 6 on GitHub Actions, with credentials from the repository's secrets in
place of the login keychain. Steps 1–3 stay the same: commit them, push, then push the tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

A tag that isn't `v` + `MARKETING_VERSION` stops the run, and a version that's already released (`gh release create` by
hand pushes its tag too) is left alone. Actions › Release › Run workflow runs it by hand: on a branch, the release makes
the tag at that commit; with "Publish" off, it builds, signs, and notarizes, and keeps only the artifact, which is the
way to do step 5 before the feed moves (pushing the tag afterwards builds it again).

The job selects Xcode, installs the Metal Toolchain and XcodeGen where they're missing, imports the Developer ID
identity into a keychain of its own, and runs `Scripts/release.sh --publish` with these, which the script takes in place
of the login keychain whenever they're set (its header lists them):

| Variable | Instead of |
| --- | --- |
| `SIGNING_KEYCHAIN` | the keychain search list: the identity is taken from that keychain alone (`codesign --keychain`) |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | the keychain profile: notarytool's `--key`, `--key-id`, `--issuer` |
| `SPARKLE_KEY_FILE` | the keychain account `ohmyshot`: `generate_appcast --ed-key-file` |

A checkout in CI has no project of its own, so its package versions are the committed ones (The package versions,
above). The app comes out of a CI build signed ad hoc (it has no `Signing.local.xcconfig`), and the script signs every
piece again as on the Mac. This was checked on 2026-11-02 with a dry run in a checkout without that file: each piece's
entitlements came out as in 0.1.0 (the app: microphone and camera; the Share extension: the sandbox and its Share Inbox
exception, with the bundle identifier filled in; the rest: none), and nothing could be debugged. The script also stops
when the appcast leaves the zip unsigned, as `generate_appcast` does (with only a warning) when the Sparkle key isn't
the one `SUPublicEDKey` names.

The run keeps `build/release/<version>/` as the artifact `OhMyShot-<version>`, without the unzipped app (an artifact
loses its links and permissions; the zip has it): the zip, the appcast, the notes, `build.log`, `notarization.txt`, and
`notarization-log.json` when Apple refused it. Its keychain and key files are deleted when it ends, however it ends.
A hosted job stops after six hours (`timeout-minutes: 360`, the most GitHub allows). When Apple's queue is longer, the
submission still ends at Apple, but the app it was made of goes with the job: re-run it, which builds and submits again.

### The runner

The app needs the macOS 27 SDK, so the job stops on an Xcode without it. GitHub's `macos-26` and `macos-latest` images
only have Xcode 26.

- **GitHub's `xcode-27` image** (the default). A preview on 2026-11-02: macOS 27.0.1 with Xcode 27.0, 27.1 (its
  default), and the 27.2 release candidate (27B48), as the runner-images repository lists them. The job uses
  `/Applications/Xcode_27.2.app`, and stops when the image has none; the repository variable `RELEASE_XCODE` picks
  another version, or the path of an Xcode. (The maintainer's Mac builds with Xcode 27.2 beta 27B5019j.) Standard
  runners cost nothing for a public repository.
- **A Mac of our own.** Register a self-hosted runner for macOS ARM64 (the MMFoundation organization's or the
  repository's Settings › Actions › Runners › New self-hosted runner) with a label nothing else uses, such as
  `ohmyshot-release`, and set the repository variable `RELEASE_RUNNER` to it, or type it in Run workflow's runner field.
  Without `/Applications/Xcode_<RELEASE_XCODE>.app` the job uses the Xcode that `xcode-select -p` names (set
  `RELEASE_XCODE` to `/Applications/Xcode-beta.app` to say so). It never uses the login keychain's identity: its own
  keychain goes at the end of the keychain search list while it runs, and is deleted afterwards. The runner's `PATH`
  needs Homebrew's `bin` for XcodeGen. GitHub advises self-hosted runners only for private repositories: this one is
  public, and a pull request from a fork runs the workflows in that pull request, which can name the runner's label.
  So give the runner to this repository alone (an organization runner group lets only private repositories use it
  unless told otherwise), choose Settings › Actions › General › "Require approval for all external contributors" for
  fork pull requests, and keep the hosted image the default.

### The secrets

Repository secrets (Settings › Secrets and variables › Actions), by name:

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate with its private key, as a .p12, in base64 |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12's password |
| `KEYCHAIN_PASSWORD` | a random password for the job's keychain (without it, each run makes one) |
| `NOTARY_KEY_P8_BASE64` | the App Store Connect API key, the `AuthKey_<key ID>.p8` file, in base64 |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer ID shown above the team keys (an individual key has none: leave it unset) |
| `SPARKLE_PRIVATE_KEY` | the Sparkle EdDSA private key, as `generate_keys -x` exports it |

To add them with `gh` from the repository's folder (`gh secret set NAME` with nothing on its input asks for the value):

1. The Developer ID identity. In Keychain Access › login › My Certificates, select only "Developer ID Application: …
   (DT6YQU64FF)", File › Export Items…, as Personal Information Exchange (.p12), with a new password. (`security export
   -t identities` would export every identity in the keychain.) Then:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo MMFoundation/OhMyShot
   gh secret set DEVELOPER_ID_P12_PASSWORD --repo MMFoundation/OhMyShot
   openssl rand -base64 32 | gh secret set KEYCHAIN_PASSWORD --repo MMFoundation/OhMyShot
   rm DeveloperID.p12
   ```

2. The App Store Connect API key: App Store Connect › Users and Access › Integrations › App Store Connect API › Team
   Keys (the Developer role is enough to notarize). Its .p8 can be downloaded only once; keep it somewhere safe,
   outside the repository. It can be tried first: `xcrun notarytool history --key <file> --key-id <key ID> --issuer
   <issuer ID>`. Then:

   ```sh
   base64 -i AuthKey_<key ID>.p8 | gh secret set NOTARY_KEY_P8_BASE64 --repo MMFoundation/OhMyShot
   gh secret set NOTARY_KEY_ID --repo MMFoundation/OhMyShot --body <key ID>
   gh secret set NOTARY_ISSUER_ID --repo MMFoundation/OhMyShot --body <issuer ID>
   ```

3. The Sparkle key (it signs every update from then on, so it's the secret to guard most):

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ohmyshot -x sparkle-private-key
   gh secret set SPARKLE_PRIVATE_KEY --repo MMFoundation/OhMyShot < sparkle-private-key
   rm sparkle-private-key
   ```

Repository variables, both optional: `RELEASE_RUNNER` (the runner's label; GitHub's `xcode-27` without it) and
`RELEASE_XCODE` (`27.2` without it).

## Trying the updater without a release

A Debug build can be pointed at a feed served from this Mac. Make a feed with a made-up newer version:

```sh
mkdir -p /tmp/feed/work /tmp/feed/archives
ditto build/Build/Products/Release/OhMyShot.app /tmp/feed/work/OhMyShot.app
# a higher version, and the keys that make generate_appcast sign the feed
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" -c "Set :CFBundleShortVersionString 0.1.1" \
  /tmp/feed/work/OhMyShot.app/Contents/Info.plist
# by its hash: a Mac can have two identities of the same name
IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2; exit}')
codesign -f -s "$IDENTITY" --preserve-metadata=identifier,entitlements,flags,runtime /tmp/feed/work/OhMyShot.app
(cd /tmp/feed/work && ditto -c -k --sequesterRsrc --keepParent OhMyShot.app ../archives/OhMyShot-0.1.1.zip)
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account ohmyshot \
  --download-url-prefix http://127.0.0.1:19020/ --maximum-deltas 0 /tmp/feed/archives
python3 -m http.server 19020 --bind 127.0.0.1 --directory /tmp/feed/archives
```

(A Release build made since 2026-10-20 already has `SURequireSignedFeed` in its Info.plist, which is what makes
`generate_appcast` sign the appcast.) Then:

| Hook | What it does |
| --- | --- |
| `ohmyshot-dev://debug/updates-start?feed=<url>` | The updater against that feed (default `http://127.0.0.1:19020/appcast.xml`); a version found always waits in the menu |
| `debug/updates-check` | A look, as the daily one does, without skipping a recent one |
| `debug/updates-schedule?on=1` | The daily background activity on (`on=0` off) |
| `debug/updates-state` | Logs the waiting version, the last look, and the menu's title |
| `debug/updates-render` | Settings › General behind the wallpaper, as `updates-general.png` in the debug snapshots |
| `debug/updates-stop` | No updater, as before |

Never choose the waiting version in the Dev app's menu: installing it would replace the Dev app with the made-up one.
The logs are in the `updates` category: `/usr/bin/log show --last 2m --predicate 'subsystem == "io.github.fzlzjerry.ohmyshot.dev" AND category == "updates"'`.
A feed changed after it was signed is refused ("The update feed is improperly signed"); this was tried on 2026-10-20.

## Homebrew

Homebrew's own casks only take apps that pass Gatekeeper, so OhMyShot can go there once its releases are notarized.
Homebrew no longer has `--no-quarantine`, so a cask of an app that isn't notarized, in a tap of our own, would still
need Open Anyway in System Settings › Privacy & Security on first launch. A cask for when there is a notarized release:

```ruby
cask "ohmyshot" do
  version "0.1.0"
  sha256 "…" # shasum -a 256 OhMyShot-0.1.0.zip

  url "https://github.com/MMFoundation/OhMyShot/releases/download/v#{version}/OhMyShot-#{version}.zip"
  name "OhMyShot"
  desc "Screenshots, recordings, annotation, and on-device OCR"
  homepage "https://github.com/MMFoundation/OhMyShot"

  livecheck do
    url "https://github.com/MMFoundation/OhMyShot/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "OhMyShot.app"

  zap trash: [
    "~/Library/Application Support/io.github.fzlzjerry.ohmyshot",
    "~/Library/Caches/io.github.fzlzjerry.ohmyshot",
    "~/Library/Preferences/io.github.fzlzjerry.ohmyshot.plist",
  ]
end
```
