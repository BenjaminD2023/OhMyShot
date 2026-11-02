#!/bin/sh
# Makes a release of the version in Config/Base.xcconfig, and publishes nothing unless asked: build/release/<version>/
# ends up with OhMyShot-<version>.zip (signed with Developer ID, notarized, stapled) and the appcast.xml that lists it,
# signed with the Sparkle key in the login keychain. The last lines print the `gh release create` that would publish
# them. Docs/release.md has the whole procedure.
#
# Usage: Scripts/release.sh            a release
#        Scripts/release.sh --publish  a release, then that `gh release create` itself (as the release workflow does)
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
#
# In CI (.github/workflows/release.yml) these take the login keychain's place, each only when it's set:
#   SIGNING_KEYCHAIN   a keychain file to take the Developer ID identity from, instead of the keychain search list
#   NOTARY_KEY         an App Store Connect API key (the .p8 file) for notarytool, instead of the keychain profile,
#   NOTARY_KEY_ID      with its key ID,
#   NOTARY_ISSUER      and its issuer ID (none for an individual key)
#   SPARKLE_KEY_FILE   the Sparkle private key as generate_keys -x exports it, instead of the keychain account
set -eu
cd "$(dirname "$0")/.."

fail() {
  echo "release: $*" >&2
  exit 1
}

DRY_RUN=0
PUBLISH=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    *) fail "unknown option $arg" ;;
  esac
done
[ $DRY_RUN = 0 ] || [ $PUBLISH = 0 ] || fail "a dry run is never published"

REPO=MMFoundation/OhMyShot
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE_ACCOUNT=ohmyshot
NOTARY_PROFILE=${NOTARY_PROFILE:-OhMyShot}
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
SIGNING_KEYCHAIN=${SIGNING_KEYCHAIN:-}
NOTARY_KEY=${NOTARY_KEY:-}
NOTARY_KEY_ID=${NOTARY_KEY_ID:-}
NOTARY_ISSUER=${NOTARY_ISSUER:-}
SPARKLE_KEY_FILE=${SPARKLE_KEY_FILE:-}

# The signing identities, from SIGNING_KEYCHAIN alone when it's set: on a Mac that also has the certificate in the
# login keychain, codesign would otherwise find it twice.
identity() {
  security find-identity -v -p codesigning ${SIGNING_KEYCHAIN:+"$SIGNING_KEYCHAIN"} \
    | awk -v kind="\"$1: " 'index($0, kind) { print $2; exit }'
}

# notarytool with the App Store Connect API key when there is one, and with the keychain profile otherwise.
notarytool() {
  if [ -n "$NOTARY_KEY" ]; then
    set -- "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID"
    if [ -n "$NOTARY_ISSUER" ]; then set -- "$@" --issuer "$NOTARY_ISSUER"; fi
  else
    set -- "$@" --keychain-profile "$NOTARY_PROFILE"
  fi
  xcrun notarytool "$@"
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
  IDENTITY=$(identity "Developer ID Application")
  [ -n "$IDENTITY" ] || fail "no Developer ID Application certificate in ${SIGNING_KEYCHAIN:-the keychain}"
  TIMESTAMP=--timestamp
  if [ -n "$NOTARY_KEY" ]; then
    [ -f "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] || fail "NOTARY_KEY needs the .p8 file and NOTARY_KEY_ID"
    notarytool history >/dev/null 2>&1 || fail "notarytool doesn't take the App Store Connect API key $NOTARY_KEY_ID"
  else
    [ -z "$NOTARY_KEY_ID$NOTARY_ISSUER" ] || fail "NOTARY_KEY_ID and NOTARY_ISSUER need NOTARY_KEY, the .p8 file"
    notarytool history >/dev/null 2>&1 \
      || fail "no notarytool credentials under the keychain profile \"$NOTARY_PROFILE\" (xcrun notarytool store-credentials)"
  fi
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    fail "the tag $TAG is on another commit: raise MARKETING_VERSION"
  fi
fi
if [ $DRY_RUN = 1 ]; then
  IDENTITY=$(identity "Apple Development")
  [ -n "$IDENTITY" ] || fail "no Apple Development identity for the dry run"
  TIMESTAMP=--timestamp=none
fi
if [ $PUBLISH = 1 ]; then
  gh auth status >/dev/null 2>&1 || fail "--publish needs gh, signed in (or GH_TOKEN)"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "$TAG is released already"; fi
fi
[ -z "$SPARKLE_KEY_FILE" ] || [ -s "$SPARKLE_KEY_FILE" ] || fail "no Sparkle key in $SPARKLE_KEY_FILE"
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
    codesign --force --sign "$IDENTITY" ${SIGNING_KEYCHAIN:+--keychain "$SIGNING_KEYCHAIN"} --options runtime \
      $TIMESTAMP --entitlements "$plist" "$piece"
  else
    codesign --force --sign "$IDENTITY" ${SIGNING_KEYCHAIN:+--keychain "$SIGNING_KEYCHAIN"} --options runtime \
      $TIMESTAMP "$piece"
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
  notarytool submit "$OUT/notarize.zip" --wait | tee "$OUT/notarization.txt"
  if ! grep -q "status: Accepted" "$OUT/notarization.txt"; then
    # Apple's reasons, fetched while the credentials are at hand (in CI they aren't, afterwards).
    SUBMISSION=$(sed -n 's/^ *id: //p' "$OUT/notarization.txt" | head -1)
    [ -z "$SUBMISSION" ] || notarytool log "$SUBMISSION" "$OUT/notarization-log.json" || true
    fail "notarization didn't accept it: $OUT/notarization-log.json says why"
  fi
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
if [ -n "$SPARKLE_KEY_FILE" ]; then
  set -- --ed-key-file "$SPARKLE_KEY_FILE"
else
  set -- --account "$SPARKLE_ACCOUNT"
fi
"$SPARKLE_BIN/generate_appcast" \
  "$@" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --embed-release-notes \
  --maximum-deltas 0 \
  "$OUT/archives"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/archives/appcast.xml" || fail "the appcast doesn't list build $BUILD"
grep -q "sparkle-signatures:" "$OUT/archives/appcast.xml" || fail "the appcast isn't signed"
# generate_appcast signs the feed with any key, but leaves the zip unsigned (with only a warning) when the key isn't
# the one SUPublicEDKey names, and the app would refuse both.
grep -q "OhMyShot-$VERSION\.zip\"[^>]*sparkle:edSignature=" "$OUT/archives/appcast.xml" \
  || fail "the appcast doesn't sign the zip: the Sparkle key isn't the one SUPublicEDKey in Config/Info.plist names"

echo
echo "Made $(du -h "$ZIP" | cut -f1 | tr -d ' ') $ZIP ($(du -sh "$APP" | cut -f1 | tr -d ' ') unzipped) and $OUT/archives/appcast.xml."
if [ $DRY_RUN = 1 ]; then
  echo "A dry run: signed with this Mac's identity and not notarized. Don't publish it."
elif [ $PUBLISH = 1 ]; then
  echo "Publishing $TAG..."
  gh release create "$TAG" "$ZIP" "$OUT/archives/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "OhMyShot $VERSION" --notes-file "$OUT/release-notes.md"
else
  echo "To publish it (the zip and the appcast go to the release; the feed is the latest release's appcast.xml):"
  echo "  gh release create $TAG '$ZIP' '$OUT/archives/appcast.xml' --repo $REPO --target $(git rev-parse HEAD) --title 'OhMyShot $VERSION' --notes-file '$OUT/release-notes.md'"
fi
