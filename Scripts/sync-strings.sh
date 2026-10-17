#!/bin/sh
# Brings every string catalog up to date with the source: adds the strings the code uses that a catalog lacks,
# and marks the ones it no longer uses stale. Translations already there are kept.
#
# The compiler writes the strings each file uses (.stringsdata) as it builds, so this builds first; pass
# --no-build to sync from the last build. Xcode does the same when it builds in the IDE; this is for the
# command line and for checking that nothing is missing (Scripts/l10n.py check).
set -eu
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-build" ]; then
  Scripts/build.sh >/dev/null
fi

INTERMEDIATES=build/Build/Intermediates.noindex

# sync <catalog> <directory holding the target's build intermediates>
sync() {
  catalog=$1
  objects="$INTERMEDIATES/$2/Objects-normal"
  if [ ! -d "$objects" ]; then
    echo "No build intermediates in $objects; build first." >&2
    exit 1
  fi
  # One sync call with every file: a call marks stale whatever its files don't use.
  set --
  for file in $(find "$objects" -name '*.stringsdata' | sort); do
    set -- "$@" --stringsdata "$file"
  done
  xcrun xcstringstool sync "$catalog" "$@"
  echo "Synced $catalog"
}

sync App/Localizable.xcstrings OhMyShot.build/Debug/OhMyShot.build
sync Extensions/Share/Localizable.xcstrings OhMyShot.build/Debug/ShareExtension.build
for target in OMSCore OMSCapture OMSUI OMSAnnotate OMSStudio; do
  sync "Packages/OhMyShotKit/Sources/$target/Resources/Localizable.xcstrings" "OhMyShotKit.build/Debug/$target-t.build"
done
