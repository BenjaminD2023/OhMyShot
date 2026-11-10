#!/bin/sh
# Makes the installer disk image of a built app: a window with the app beside the Applications folder, over the
# picture Tools/dmg/installer.swift draws (DESIGN.md, Installer Disk Image), and the app's icon as the volume's.
# Finder is never scripted: the same script writes the window's layout, so this runs without anyone logged in, as in CI.
# Docs/release.md (The installer disk image) says where it stands in a release.
#
# Usage: Scripts/make-dmg.sh                 the app a release left in build/release/<version>/, to
#                                            OhMyShot-<version>.dmg beside it
#        Scripts/make-dmg.sh <app> [<dmg>]   another app (a dry run's, a Release build's), to <dmg> or beside it
#
# The image is signed when there is a "Developer ID Application" certificate (in SIGNING_KEYCHAIN when it's set, as
# for Scripts/release.sh), and left unsigned otherwise. It is not notarized here.
set -eu
cd "$(dirname "$0")/.."

fail() {
  echo "make-dmg: $*" >&2
  exit 1
}

[ $# -le 2 ] || fail "usage: Scripts/make-dmg.sh [<app> [<dmg>]]"
APP=${1:-build/release/$(sed -n 's/^MARKETING_VERSION = //p' Config/Base.xcconfig)/OhMyShot.app}
[ -d "$APP" ] || fail "no app at $APP"
NAME=$(basename "$APP" .app)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") \
  || fail "$APP has no version"
DMG=${2:-$(dirname "$APP")/$NAME-$VERSION.dmg}
ICON="$APP/Contents/Resources/AppIcon.icns"
[ -f "$ICON" ] || fail "$APP has no AppIcon.icns for the volume's icon"
# An image is as good as the app in it: one whose signature is broken would be refused where it lands.
codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"

WORK=$(mktemp -d)
VOLUME="$WORK/volume"
detach() {
  hdiutil detach "$VOLUME" >/dev/null 2>&1 || { sleep 2; hdiutil detach -force "$VOLUME" >/dev/null 2>&1; }
}
trap 'detach || true; rm -rf "$WORK"' EXIT
# hdiutil, which says nothing worth reading unless it fails (and on macOS 27 warns that diskutil will replace it).
image() {
  hdiutil "$@" > "$WORK/hdiutil.log" 2>&1 || { cat "$WORK/hdiutil.log" >&2; fail "hdiutil $1 failed"; }
}

echo "Making $DMG..."
STAGE="$WORK/stage"
mkdir -p "$STAGE" "$VOLUME"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ICON" "$STAGE/.VolumeIcon.icns"
xcrun swift Tools/dmg/installer.swift "$STAGE" "$NAME" "$NAME.app" || fail "couldn't draw the window"

# Read-write first: a volume shows its .VolumeIcon.icns only with the custom-icon flag on its root folder, which an
# image made from a folder doesn't take from the folder. (hdiutil makehybrid does, and puts empty Finder information
# on every file besides, which breaks the app's signature.) Mounted where Finder doesn't look, so nothing else is
# written to it.
image create -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -ov "$WORK/read-write.dmg"
image attach "$WORK/read-write.dmg" -nobrowse -noautoopen -mountpoint "$VOLUME"
# kHasCustomIcon, in the Finder flags at byte 8 of the root folder's Finder information.
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$VOLUME"
rm -rf "$VOLUME/.fseventsd"
detach || fail "couldn't unmount the image"

# Compressed with LZMA: a quarter smaller than zlib for this app, and read by every macOS the app runs on.
mkdir -p "$(dirname "$DMG")"
image convert "$WORK/read-write.dmg" -format ULMO -ov -o "$DMG"

IDENTITY=$(security find-identity -v -p codesigning ${SIGNING_KEYCHAIN:+"$SIGNING_KEYCHAIN"} \
  | awk '/"Developer ID Application: /{ print $2; exit }')
if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" ${SIGNING_KEYCHAIN:+--keychain "$SIGNING_KEYCHAIN"} --timestamp "$DMG"
fi

# What was made, read back: the image's checksums, then the app in it and the window's files.
image verify "$DMG"
image attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$VOLUME"
codesign --verify --deep --strict "$VOLUME/$NAME.app" || fail "the app in the image doesn't verify"
[ "$(readlink "$VOLUME/Applications")" = /Applications ] || fail "the image has no link to Applications"
for file in .DS_Store .background/background.tiff .VolumeIcon.icns; do
  [ -s "$VOLUME/$file" ] || fail "the image has no $file"
done
detach || fail "couldn't unmount the image"

echo "Made $(du -h "$DMG" | cut -f1 | tr -d ' ') $DMG."
if [ -z "$IDENTITY" ]; then
  echo "Not signed: no Developer ID Application certificate in ${SIGNING_KEYCHAIN:-the keychain}."
fi
