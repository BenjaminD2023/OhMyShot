# Releases and updates

OhMyShot is released on GitHub: each release carries a zip of the app and the Sparkle appcast that lists it, and the
app looks for updates in the latest release's appcast. Nothing has been released yet. A release needs a Developer ID
certificate, which this project doesn't have yet, so `Scripts/release.sh` stops before it builds anything without one;
`Scripts/release.sh --dry-run` runs the rest of it.

## How the app updates

- **Only release builds look.** `SUFeedURL` is set in `Config/Release.xcconfig`:
  `https://github.com/fzlzjerry/OhMyShot/releases/latest/download/appcast.xml`. Debug builds ("OhMyShot Dev") have no
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
   Application). `security find-identity -v -p codesigning` lists it.
2. notarytool's credentials in the keychain, with an app-specific password for the Apple Account:
   `xcrun notarytool store-credentials OhMyShot --apple-id <apple id> --team-id <team id>`
3. The Sparkle key (above).
4. `gh` signed in to an account that can make releases on fzlzjerry/OhMyShot.

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
     development identity adds,
   - signs every piece again with Developer ID from the inside out, as Sparkle's documentation does: Sparkle's XPC
     services, Autoupdate, Updater.app, and framework (they come signed ad hoc), the text reader, the Share extension,
     then the app, each with the hardened runtime, a secure timestamp, and its own entitlements,
   - stops if any piece of code in the app isn't signed with Developer ID and the hardened runtime, or can still be
     debugged,
   - notarizes it, staples the ticket, and checks that Gatekeeper takes it as notarized,
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

  url "https://github.com/fzlzjerry/OhMyShot/releases/download/v#{version}/OhMyShot-#{version}.zip"
  name "OhMyShot"
  desc "Screenshots, recordings, annotation, and on-device OCR"
  homepage "https://github.com/fzlzjerry/OhMyShot"

  livecheck do
    url "https://github.com/fzlzjerry/OhMyShot/releases/latest/download/appcast.xml"
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
