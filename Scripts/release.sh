#!/bin/sh
# Makes a release of the version in Config/Base.xcconfig, and publishes nothing: build/release/<version>/ ends up with
# OhMyShot-<version>.zip (signed with Developer ID, notarized, stapled) and the appcast.xml that lists it, signed with
# the Sparkle key in the login keychain. The last lines print the `gh release create` that would publish them.
# Docs/release.md has the whole procedure.
#
# Usage: Scripts/release.sh            a release
#        Scripts/release.sh --dry-run  everything that needs no Developer ID: the archive, the zip, the notes and an
#                                      appcast, signed with this Mac's own identity and not notarized, into
#                                      build/release/<version>-dry-run/. Never publish what it makes.
#
# A release needs, on this Mac:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarytool's credentials saved as the keychain profile "OhMyShot" (NOTARY_PROFILE to use another):
#       xcrun notarytool store-credentials OhMyShot --apple-id <id> --team-id <team>
#   - the Sparkle key in the login keychain, account "ohmyshot" (generate_keys -f <backup> --account ohmyshot)
#   - a "## [<version>]" section in CHANGELOG.md, which becomes the release notes
#   - a working tree with nothing uncommitted
set -eu
cd "$(dirname "$0")/.."

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

REPO=fzlzjerry/OhMyShot
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE_ACCOUNT=ohmyshot
NOTARY_PROFILE=${NOTARY_PROFILE:-OhMyShot}
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin

fail() {
  echo "release: $*" >&2
  exit 1
}

VERSION=$(sed -n 's/^MARKETING_VERSION = //p' Config/Base.xcconfig)
BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Config/Base.xcconfig)
TAG="v$VERSION"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail "no MARKETING_VERSION or CURRENT_PROJECT_VERSION in Config/Base.xcconfig"

if [ $DRY_RUN = 1 ]; then
  OUT="build/release/$VERSION-dry-run"
else
  OUT="build/release/$VERSION"
fi

# What has to be in place before anything is built.
if [ $DRY_RUN = 0 ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "commit or stash the changes first"
  IDENTITY=$(security find-identity -v -p codesigning | awk '/"Developer ID Application: /{print $2; exit}')
  [ -n "$IDENTITY" ] || fail "no Developer ID Application certificate in the keychain"
  TIMESTAMP=--timestamp
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool credentials under the keychain profile \"$NOTARY_PROFILE\" (xcrun notarytool store-credentials)"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    fail "the tag $TAG is on another commit: raise MARKETING_VERSION"
  fi
fi
if [ $DRY_RUN = 1 ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2; exit}')
  [ -n "$IDENTITY" ] || fail "no Apple Development identity for the dry run"
  TIMESTAMP=--timestamp=none
fi
SECTION=$VERSION
if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
  [ $DRY_RUN = 1 ] || fail "CHANGELOG.md has no \"## [$VERSION]\" section for the release notes"
  SECTION=Unreleased
  echo "CHANGELOG.md has no \"## [$VERSION]\" section yet: the dry run's notes are Unreleased's."
fi
if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed"; then
  fail "Xcode's Metal Toolchain isn't installed: xcodebuild -downloadComponent MetalToolchain"
fi
if [ ! -d OhMyShot.xcodeproj ] || [ project.yml -nt OhMyShot.xcodeproj/project.pbxproj ]; then
  Scripts/bootstrap.sh
fi

rm -rf "$OUT"
mkdir -p "$OUT/archives"

# The feed so far, so the new appcast keeps the versions before it; the first release has none. Its build number has
# to be below this one, or Sparkle would offer nothing.
if curl -fsSL "$FEED" -o "$OUT/archives/appcast.xml" 2>/dev/null; then
  LAST_BUILD=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$OUT/archives/appcast.xml" | sort -n | tail -1)
  if [ -n "$LAST_BUILD" ] && [ "$BUILD" -le "$LAST_BUILD" ]; then
    fail "CURRENT_PROJECT_VERSION is $BUILD, but the feed already has build $LAST_BUILD: raise it"
  fi
else
  rm -f "$OUT/archives/appcast.xml"
  echo "No feed at $FEED yet: the appcast starts with this version."
fi

echo "Building OhMyShot $VERSION ($BUILD)..."
for app in build/Build/Products/Release/*.app build/Build/Products/Release/*.appex; do
  if [ -d "$app" ]; then xattr -cr "$app"; fi
done
# Stripped, as an archive would be, and without the debugging entitlement a development identity adds, which
# notarization refuses. Not an archive: the MLX library's copy script can't read an archive's intermediate paths, and
# a generic destination builds the packages for Intel too.
xcodebuild \
  -project OhMyShot.xcodeproj \
  -scheme OhMyShot \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet \
  build > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; fail "the build failed: $OUT/build.log"; }
# Xcode 27 beta prints "error: the following command failed with exit code 0" for some compiles that only warned, in
# plain Release builds too, and the build still succeeds; anything else that says error is worth a look.
if grep "^error:" "$OUT/build.log" | grep -qv "failed with exit code 0 but produced no further output"; then
  grep "^error:" "$OUT/build.log" >&2
  fail "the build reported errors: $OUT/build.log"
fi
APP="$OUT/OhMyShot.app"
ditto build/Build/Products/Release/OhMyShot.app "$APP"

# Signed again from the inside out, as Sparkle's documentation does it: Sparkle's helpers come signed ad hoc, and
# every piece needs the identity, the hardened runtime, and (for a release) a secure timestamp. Each keeps its own
# entitlements, less those of development signing.
echo "Signing..."
mkdir -p "$OUT/entitlements"
sign() {
  piece=$1
  plist="$OUT/entitlements/$(printf '%s' "$piece" | shasum | cut -c1-12).plist"
  codesign -d --entitlements - --xml "$piece" > "$plist" 2>/dev/null || true
  for key in com.apple.security.get-task-allow com.apple.application-identifier com.apple.developer.team-identifier; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  done
  if [ -s "$plist" ] && /usr/libexec/PlistBuddy -c "Print" "$plist" 2>/dev/null | grep -q " = "; then
    codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$plist" "$piece"
  else
    codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$piece"
  fi
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for piece in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  if [ -e "$piece" ]; then sign "$piece"; fi
done
for piece in "$APP"/Contents/Frameworks/*; do
  if [ -e "$piece" ] && [ "$piece" != "$SPARKLE" ]; then sign "$piece"; fi
done
sign "$APP/Contents/MacOS/OhMyShot Text Reader"
for piece in "$APP"/Contents/PlugIns/*.appex; do
  if [ -e "$piece" ]; then sign "$piece"; fi
done
sign "$APP"

# Every piece of code in the app: its signer, its hardened runtime, and no debugging entitlement. A release stops at
# any piece that isn't Developer ID with the runtime; a dry run only lists them.
echo "Checking signatures..."
codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"
BAD=0
find "$APP" \( -name "*.app" -o -name "*.appex" -o -name "*.xpc" -o -name "*.framework" -o -type f -perm +111 \) -print \
  | while read -r piece; do
    if [ -f "$piece" ] && ! file "$piece" | grep -q "Mach-O"; then continue; fi
    info=$(codesign -dvv "$piece" 2>&1 || true)
    signer=$(printf '%s\n' "$info" | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)
    [ -n "$signer" ] || signer=$(printf '%s\n' "$info" | sed -n 's/^Signature=\(.*\)/\1/p' | head -1)
    runtime=$(printf '%s\n' "$info" | grep -q 'flags=.*runtime' && echo runtime || echo "no runtime")
    case "$signer" in "Developer ID Application:"*) ok=1 ;; *) ok=0 ;; esac
    name=${piece#"$APP"/}
    [ "$piece" != "$APP" ] || name=OhMyShot.app
    printf '  %-12s %s  %s\n' "$runtime" "$name" "$(printf '%s' "$signer" | sed 's/: .*//')"
    if codesign -d --entitlements - --xml "$piece" 2>/dev/null | grep -q "get-task-allow"; then
      echo "release: $name can still be debugged (get-task-allow), which notarization refuses" >&2
      exit 1
    fi
    if [ $DRY_RUN = 0 ] && { [ $ok = 0 ] || [ "$runtime" != runtime ]; }; then
      echo "release: $name isn't signed with Developer ID and the hardened runtime" >&2
      exit 1
    fi
  done || BAD=1
[ $BAD = 0 ] || exit 1

ZIP="$OUT/archives/OhMyShot-$VERSION.zip"
if [ $DRY_RUN = 0 ]; then
  echo "Notarizing..."
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notarization.txt"
  grep -q "status: Accepted" "$OUT/notarization.txt" \
    || fail "notarization didn't accept it: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Asks for the notarization itself rather than Gatekeeper's verdict, which says nothing on a Mac where Gatekeeper
  # is turned off.
  codesign --verify --strict --check-notarization -R="notarized" "$APP" || fail "the app doesn't read as notarized"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The release notes: the version's section of CHANGELOG.md, with the link definitions its references use.
NOTES="$OUT/archives/OhMyShot-$VERSION.md"
awk -v head="## [$SECTION]" '
  index($0, head) == 1 { on = 1; next }
  on && /^## \[/ { on = 0 }
  on { print }
' CHANGELOG.md > "$NOTES"
grep '^\[[^]]*\]: http' CHANGELOG.md >> "$NOTES" || true
cp "$NOTES" "$OUT/release-notes.md"

echo "Writing the appcast..."
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --embed-release-notes \
  --maximum-deltas 0 \
  "$OUT/archives"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/archives/appcast.xml" || fail "the appcast doesn't list build $BUILD"
grep -q "sparkle-signatures:" "$OUT/archives/appcast.xml" || fail "the appcast isn't signed"

echo
echo "Made $(du -h "$ZIP" | cut -f1 | tr -d ' ') $ZIP ($(du -sh "$APP" | cut -f1 | tr -d ' ') unzipped) and $OUT/archives/appcast.xml."
if [ $DRY_RUN = 1 ]; then
  echo "A dry run: signed with this Mac's identity and not notarized. Don't publish it."
else
  echo "To publish it (the zip and the appcast go to the release; the feed is the latest release's appcast.xml):"
  echo "  gh release create $TAG '$ZIP' '$OUT/archives/appcast.xml' --repo $REPO --target $(git rev-parse HEAD) --title 'OhMyShot $VERSION' --notes-file '$OUT/release-notes.md'"
fi
