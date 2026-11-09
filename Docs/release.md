# Releases and updates

OhMyShot is released on GitHub: each release carries a zip of the app and the Sparkle appcast that lists it. New
Release builds fetch that appcast through the website; the published 0.1.0 still fetches GitHub directly.
The first, 0.1.0, was released on 2026-11-03 from the
maintainer's Mac (its notarization waited 16 hours in Apple's queue). Releases are signed with the
maintainer's Developer ID (team DT6YQU64FF, since 2026-11-02) and notarized; `Scripts/release.sh` stops before it builds
anything on a Mac without the certificate or notarytool's credentials, and `Scripts/release.sh --dry-run` runs the rest
of it with the Mac's own development identity. The release workflow runs the same script on GitHub Actions for a pushed
tag, and CI builds every push to main the way it does (Releasing from CI, below).

## How the app updates

- Release builds check `https://www.ohmyshot.org/updates/appcast`. The website Worker streams the original signed
  GitHub appcast unchanged. Its `/updates/download/v<version>/OhMyShot-<version>.zip` endpoint streams the archive,
  including byte-range requests, so neither request redirects the user's Mac to GitHub. The app retries transport
  failures once through GitHub directly. For a manual check or download, dismiss Sparkle’s error alert to start
  that retry; a retried download asks for installation confirmation again. Signature failures are not retried through a different source.
- Deploy the companion website change **before shipping this app**. The update routes have no new secrets or storage
  dependencies. This removes the user's direct GitHub dependency; Cloudflare's international network is not a mainland
  CDN SLA. Check the feed and a complete archive download on mainland networks without VPN before release. A dedicated
  mainland/Hong Kong mirror can replace this transport later without weakening Sparkle verification.
- Signed-feed recovery expiration is disabled, so a prolonged outage never allows unsigned metadata.
- The signed appcast and every archive retain EdDSA verification (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`).
  Never rewrite a signed feed at the proxy. Release publishing stays the same; no second upload is necessary.
- The system background activity scheduler checks every six hours (± one hour). Enabling checks also checks at launch
  unless the last check was less than 4.5 hours ago. Automatic checks remain on by default and can be disabled in Settings.
- A found version is persisted by build number and stays at the top of the status menu, with an arrow beside its icon,
  until the installed build catches up. Opening/dismissing Sparkle does not erase it. Settings also shows the version.
  A reminder offers Update Now and Remind Me Tomorrow, at most once per version per day, when no capture, recording,
  editor or modal is active. If busy, the menu remains available; finishing a capture, activation and scheduled wakes retry the reminder.
- Downloads and installation still require confirmation. The updater never forces a restart during a capture.
- Debug builds have no production feed. `ohmyshot-dev://debug/updates-preview` shows a **simulated** 0.2.0 menu reminder
  and the Unreleased notes for visual QA, without checking or downloading an update.

### Mainland distribution acceptance

Before signing, `Scripts/release.sh` validates the built Release app with `Scripts/check-release-updater.py`,
including CI's `--build-only` run. It checks the processed feed URL, release identity and version/build, public key,
signed-feed enforcement, archive verification and disabled unsigned-feed recovery. After packaging it checks the
actual ZIP again; the CI publish job repeats the ZIP check immediately before creating the GitHub release. A missing
or legacy GitHub updater stops publication. `python3 -B -m unittest discover -s Scripts/tests -p 'test_release_updater.py'`
exercises valid packages, the legacy feed, missing/weakened signature settings and mismatched artifacts.

The website's `/download` and both installation guides must use the website archive route, including when release
lookup fails. A GitHub redirect is a failure, even if it works on the maintainer's connection. The published 0.1.0
archive still has a GitHub `SUFeedURL`; changing the website cannot change that installed binary. Publish a higher
version/build containing the website updater before mainland promotion. Users of 0.1.0 who cannot reach GitHub need
one manual download from the website to migrate; do not overwrite the signed 0.1.0 asset in place.

Run `python3 Scripts/check-distribution.py` on a mainland Mac with VPN/TUN disabled. It checks both home pages,
refuses external download redirects, downloads the complete browser and updater archives, compares them, checks
range responses, verifies the signed feed and archive against `Config/Info.plist`'s public key, and inspects the
updater settings inside the actual downloaded app. It needs Xcode's Swift compiler and Python 3, no private key or
Keychain access. Results and files go to `build/distribution-check/` (or `--output <directory>`). A legacy app or
external redirect makes it exit nonzero. HTTP proxies are bypassed; a system VPN/TUN must be disabled separately.

Record ISP, city, date and the report for China Telecom, Unicom and Mobile. An overseas `loc` in the diagnostic is
not mainland evidence. A successful transport check is not proof of installation: on a disposable copy of an older
website-updater release, accept a signed newer update, restart and confirm the installed build and permissions.
Do not use the working Dev app for that replacement. If mainland site reachability fails, arrange a measured
mainland/Hong Kong origin or CDN with the site maintainer and repeat these checks before promotion.

### First signed release through Publish: remaining acceptance

The CI trials exercised build, signing, notarization, and artifact upload with publishing disabled. They did **not**
exercise Publish end to end. The pre-publication updater checks alone cannot establish that the public website
download and Sparkle transport serve the release just built. The older post-publish GitHub check also cannot detect
a stale website download, a mismatched website cache, or an incorrect updater inside a public archive.

After the first real publication, `release.yml` now calls `verify-release.yml` with the version, build, and SHA-256
of the exact ZIP validated before upload. This independent job has only `contents: read`, no signing secrets, and
never publishes, modifies a release, installs an app, or accesses the Keychain. It runs `check-distribution.py` with
all three expectations. Success requires:

- The website's signed latest feed names the expected version and build (a different newer release also fails).
- The feed and its complete archive pass Ed25519 verification against the repository's public key.
- `/download` and the website's Sparkle archive route return complete, byte-identical ZIPs whose SHA-256 matches the
  original signed build artifact. Every redirect stays on the HTTPS website hosts.
- Both downloaded ZIPs pass the shared release-updater policy, including identity, version/build, feed, public key,
  signature enforcement, and disabled unsigned-feed recovery. Byte-range responses also match the verified archive.

The workflow retries up to three times, 20 seconds apart, for publication/cache propagation, preserving each
attempt's JSON report, log, and signed feed as a run artifact. A verification failure happens **after** publication;
it does not roll back, replace, or republish anything. Investigate the failed check, then rerun **Verify release
distribution** from Actions with the same three expectations. Do not rerun the Release workflow to retry this check:
its already-released preflight skips the build/publish jobs. The verification-only workflow can also be run locally
on a Mac after downloading the original CI build artifact (or using the original locally signed release ZIP):

```sh
# Example values: set these to the real release, not the checkout's possibly older Base.xcconfig.
VERSION=0.2.0
BUILD=2
SIGNED_ZIP="build/release/$VERSION/archives/OhMyShot-$VERSION.zip"
DIGEST=$(shasum -a 256 "$SIGNED_ZIP" | cut -d' ' -f1)
python3 -I Scripts/check-distribution.py --version "$VERSION" --build "$BUILD" \
  --sha256 "$DIGEST" --output "build/distribution-check/$VERSION-attempt-1"
```

Use the original build artifact's digest, not one computed from the public website being tested. All three
expectations must be supplied together; omitting all three retains the mainland diagnostic mode. Keep the report
and original release run URL as acceptance evidence. A passing hosted run proves public artifact parity, not
mainland reachability, Developer ID/notarization validation, or successful installation: retain the signing job's
evidence and perform the mainland and disposable-install checks above. The first real Publish run and this public
verification remain unproven until that release actually happens; adding or testing this verifier does not close
that operational acceptance item.

`python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py' -v` exercises this offline. On macOS it creates a
throwaway key and uses the real CryptoKit verifier to test signed fixtures, stale versions/builds, archive/hash
mismatches, tampered signatures, weakened updater settings, partial responses, bad ranges, and failed reruns. It
never contacts production endpoints or uses a production private key. CI runs these before a real release is needed.

### The post-update window

`CHANGELOG.md` is bundled in the signed application. On the first launch with this feature, and once per higher build
number afterwards, What’s New opens with the exact installed version's section. The menu's What’s New… reopens it.
Translations live in `App/ReleaseNotes-<language>.md` (`zh-Hans`, `zh-Hant`, `ja`, `es`, `fr`), with the same
`## [<version>]` sections as CHANGELOG.md. When releasing, move each translated Unreleased section under the release
version too. The app reads its selected language's matching version, falling back to CHANGELOG.md when missing;
it never substitutes a different version's notes. English remains the source of truth.
Notes work offline and don't execute HTML or JavaScript. Headings, paragraphs, bullet lists, inline Markdown (bold,
italic, links, inline code), and fenced code blocks are supported. Other Markdown constructs stay readable as text.
The default banner is a blue/teal native illustration. To customize it, add a `ReleaseBanner` image set to
`App/Assets.xcassets` (recommended 1200 × 400 or larger); it is bundled and code-signed too. Keep its lower-left area
clear for the localized headline. Without an image, the default banner is always available.

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
   - builds the Release app for Apple silicon (every target, the packages' too), stripped and without the debugging
     entitlement (`get-task-allow`) that a development identity adds, with the package versions in
     `Config/Package.resolved` alone and through Xcode's compilation cache in `build/CompilationCache.noindex`
     (Releasing from CI › The caches), and stops if the notices don't match them,
   - signs every piece again with Developer ID from the inside out, as Sparkle's documentation does: Sparkle's XPC
     services, Autoupdate, Updater.app, and framework (they come signed ad hoc), the text reader, the Share extension,
     then the app, each with the hardened runtime, a secure timestamp, and its own entitlements,
   - stops if any piece of code in the app isn't signed with Developer ID and the hardened runtime, or can still be
     debugged,
   - notarizes it, staples the ticket, and checks that Gatekeeper takes it as notarized. It uploads again (up to three
     times) when an upload is cut off, and waits out Apple's queue however long it is, asking once a minute and again
     after a failed asking: notarytool's own `--wait` stops at the first network error. A new team's first
     notarization took 18 hours, and 0.1.0's, the day after, 16; later ones are minutes as a rule,
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
builds the packages for Intel as well.) So did the build for `arch=arm64` until 2026-11-05: `ARCHS = arm64` in
`Config/Base.xcconfig` is the app's targets' alone, and the packages' targets took Release's `arm64 x86_64`, so every
release compiled MLX and the rest for Intel too, half of all its compiling, for an app that links none of it. The script
now gives `ARCHS=arm64` to every target.

`Scripts/release.sh --check` makes only the checks of step 4 that need no Mac (nothing uncommitted, the tag, the
section in CHANGELOG.md, the feed's build number, and with `--publish` gh), and `Scripts/release.sh --build-only` only
its build and the notices' check, signing nothing: the release workflow's preflight and CI run them.

## Releasing from CI

`.github/workflows/release.yml` does steps 4 and 6 on GitHub Actions, with credentials from the repository's secrets in
place of the login keychain. Steps 1–3 stay the same: commit them, push, then push the tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

A tag that isn't `v` + `MARKETING_VERSION` stops the run, and a version that's already released (`gh release create` by
hand pushes its tag too) is left alone. Actions › Release › Run workflow runs it by hand: on a branch, the release makes
the tag at that commit; with "Publish" off, it builds, signs, and notarizes, and keeps only the artifact, which is the
way to do step 5 before the feed moves (pushing the tag afterwards builds it again). Only a version not yet released can
be built: the script stops when the version's tag is on another commit. So the workflow was first tried on 2026-11-04,
after 0.1.0, on a throwaway branch that raised the version to 0.1.1 (build 2) with a section in CHANGELOG.md: the hosted
`xcode-27` runner built, signed, and notarized it (accepted within minutes) in 17 minutes, and its appcast kept 0.1.0.
The workflow as it is now was tried the same way on 2026-11-05 (The times, below).

It runs four jobs, each after the one before:

| Job | Runs on | What it does |
| --- | --- | --- |
| Preflight | Linux, seconds | `Scripts/release.sh --check` (nothing uncommitted, the tag, the section in CHANGELOG.md, the feed's build number, and gh when publishing), and that the secrets are set |
| Build, sign, and notarize | a Mac (The runner, below) | `Scripts/release.sh`, from CI's compilation cache, keeping `build/release/<version>/` as the run's artifact |
| Publish | Linux | `gh release create` with the artifact's zip, appcast, and notes, then checks that the feed lists the build and serves that very zip |
| Verify public distribution | macOS, public key only | Reusable `verify-release.yml`: pins both website downloads and the signed feed to the version, build, and original ZIP hash; retains reports and can be rerun independently |

So a release that can't be made stops before a Mac is involved: the two runs that failed on 2026-11-04 (the secrets not
yet set, then a tag on another commit) each took a minute on the Mac, and would stop in Preflight now. Only Publish can
write to the repository (`contents: write`); the Mac's job, which runs the packages' build and holds the signing keys,
can only read it.

The Mac's job selects Xcode and installs the Metal Toolchain and XcodeGen where they're missing
(`.github/actions/xcode`, which CI shares), restores the caches (below), imports the Developer ID identity into a
keychain of its own, and runs `Scripts/release.sh` with these, which the script takes in place of the login keychain
whenever they're set (its header lists them):

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

### CI and the caches

`.github/workflows/ci.yml` builds every push to main that changes more than Markdown and `Docs/` (and runs by hand from
Actions › CI): `Scripts/release.sh --build-only`, a release's build without the signing, so a commit that a release
couldn't build, or whose notices don't match its packages, shows at once. A push while a build runs waits for it. The
build keeps two caches, which the release workflow restores:

- `build/SourcePackages`, the packages' checkouts, under the hash of `Config/Package.resolved`.
- `build/CompilationCache.noindex`, Xcode's compilation cache (`COMPILATION_CACHE_ENABLE_CACHING`), saved under each
  commit, and restored from the latest one made with the same Xcode build. A compile whose inputs (its sources, the
  modules it imports, its flags, the compiler) are those of one in the cache is replayed instead of run, and comes out
  the same: on 2026-11-05 a build from scratch and one replayed from the cache made byte for byte the same executables,
  once unsigned (only the Share extension's `Assets.car` differed, as it does between any two builds). A changed
  comment in OMSCore compiles OMSCore again and nothing else; a change to what a module declares compiles the modules
  that import it as well. `COMPILATION_CACHE_LIMIT_SIZE=2G` bounds it on disk; GitHub keeps about 290 MB of it a build.

A tag's run can read main's caches (GitHub lets every branch and tag restore the default branch's) but not save to them,
and only a push or a run by hand can save to main's (a pull request can't), so the release workflow only restores.
GitHub drops a cache that nothing has read for 7 days: after a week without a build of main, the next build starts cold.
The cache key names the runner's kind, so a Mac of our own (The runner, below) doesn't take what a hosted one compiled.

### The times

On the hosted `xcode-27` runner, for 0.1.1 on a throwaway branch, as on 2026-11-04:

| | 2026-11-04 | 2026-11-05 |
| --- | --- | --- |
| The release, to the artifact | 17 min 55 s | 4 min 1 s, CI having built the same code; 4 min 38 s with OMSCore changed since |
| Its build (`xcodebuild`) | 15 min 31 s | 89 s, every compile from the cache; 124 s, OMSCore compiled again; 5 min 33 s with no cache |
| Notarization | 1 min | 1 min |
| A release that can't be made | a minute, on the Mac | about 10 s, in Preflight |

Half of the old build was the packages compiled for Intel too (Making a release, above). What's left of a build replayed
from the cache is what no cache skips: planning the explicit modules, scanning the C++ for its headers, the asset
catalogs, MLX's Metal kernels, and linking. Publish wasn't timed (the trials didn't publish); it's a download and an
upload of 15 MB. A release with no cache at all would take about 8 minutes.

### The tests

The workflows run the Python release-check tests, but not the Swift package tests: run `Scripts/test.sh` on a Mac
before a release. The package tests were tried on GitHub's
macOS runners, which are virtual machines, on 2026-11-05: the VLM package's passed (in 4½ minutes), but much of
OhMyShotKit's needs a Mac. Vision's text recognition failed in 9 OCR tests (`e5rtError("e5rt_e5_compiler_compile call
failed")`), as did Live Text in a pin (PinViewTests) and a studio export's colors (StudioExportTests), and the recording
tests (GIFMakerTests first) and those of the next target hung until stopped. A runner on a Mac of our own (below)
would run them all, and the release could wait for them there.

### The runner

The app needs the macOS 27 SDK, so the job stops on an Xcode without it. GitHub's `macos-26` and `macos-latest` images
only have Xcode 26.

- **GitHub's `xcode-27` image** (the default). A preview on 2026-11-02: macOS 27.0.1 with Xcode 27.0, 27.1 (its
  default), and the 27.2 release candidate (27B48), as the runner-images repository lists them. The job uses
  `/Applications/Xcode_27.2.app`, and stops when the image has none; the repository variable `RELEASE_XCODE` picks
  another version, or the path of an Xcode. CI builds with the same one, which its caches have to come from for a
  release to use them. (The maintainer's Mac builds with Xcode 27.2 beta 27B5019j.) Standard runners cost nothing for
  a public repository.
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
