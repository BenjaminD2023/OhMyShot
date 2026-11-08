#!/usr/bin/env python3
"""Reject a release app/archive whose embedded updater cannot use the fork feed.

Checks the built artifact, not the source xcconfig. Runs on macOS and Linux and
never modifies the app, archive, signatures, or Keychain.
"""
import argparse
import plistlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEBSITE_FEED = 'https://github.com/BenjaminD2023/OhMyShot/releases/latest/download/appcast.xml'


def check_artifact(path, version, build):
    if path.is_dir():
        info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    else:
        with zipfile.ZipFile(path) as archive:
            name = 'OhMyShot.app/Contents/Info.plist'
            if archive.namelist().count(name) != 1:
                raise ValueError('Archive must contain exactly one OhMyShot.app/Contents/Info.plist')
            info = plistlib.loads(archive.read(name))
    expected_key = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())['SUPublicEDKey']
    expected = {
        'CFBundleIdentifier': 'io.github.fzlzjerry.ohmyshot',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': build,
        'SUFeedURL': WEBSITE_FEED,
        'SUPublicEDKey': expected_key,
        'SURequireSignedFeed': True,
        'SUVerifyUpdateBeforeExtraction': True,
        'SUSignedFeedFailureExpirationInterval': 0,
    }
    errors = []
    for key, value in expected.items():
        actual = info.get(key)
        if type(actual) is not type(value) or actual != value:
            errors.append(f'{key}: expected {value!r}, found {actual!r}')
    if errors:
        raise ValueError('Release updater validation failed:\n' + '\n'.join(errors))
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path, help='Built .app directory or final release .zip')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    try:
        check_artifact(args.artifact, args.version, args.build)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(error, file=sys.stderr)
        return 1
    print(f'Verified fork updater in {args.artifact} ({args.version}, build {args.build}).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
