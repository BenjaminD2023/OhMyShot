#!/bin/sh
# Re-sign embedded Sparkle code with the built app's existing Apple signing identity.
set -eu
exec python3 - "$@" <<'PY'
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser(description="Sign Sparkle helpers inside-out, preserving the app's identity and entitlements.")
parser.add_argument("app", type=Path, help="Built, certificate-signed OhMyShot.app")
app = parser.parse_args().app.resolve()

def fail(message):
    raise SystemExit("sign-sparkle: " + message)

def run(arguments):
    result = subprocess.run([str(item) for item in arguments], capture_output=True, text=True)
    if result.returncode:
        fail("command failed: " + str(arguments[0]) + "\n" + result.stdout + result.stderr)
    return result.stdout + result.stderr

def signature(path):
    value = run(["codesign", "--display", "--verbose=4", path])
    authorities = re.findall(r"^Authority=(.+)$", value, re.M)
    team = re.search(r"^TeamIdentifier=(.+)$", value, re.M)
    return authorities, team.group(1) if team else None, bool(re.search(r"flags=.*\bruntime\b", value))

if not (app / "Contents/Info.plist").is_file():
    fail("pass a built app bundle")
framework = app / "Contents/Frameworks/Sparkle.framework"
version = (framework / "Versions/Current").resolve()
helpers = [version / name for name in ["Autoupdate", "Updater.app", "XPCServices/Downloader.xpc", "XPCServices/Installer.xpc"]]
if not framework.is_dir() or not all(path.exists() for path in helpers):
    fail("Sparkle.framework or one of its four expected helpers is missing; rebuild the app")
authorities, team, runtime = signature(app)
if not authorities or not team or team == "not set" or not runtime:
    fail("the app must already be Apple certificate-signed with Hardened Runtime; configure Config/Signing.local.xcconfig and rebuild (ad-hoc signing is insufficient)")
certificate = authorities[0]
if not certificate.startswith(("Apple Development:", "Developer ID Application:", "Apple Distribution:")):
    fail("the app's signing certificate is not a supported Apple identity: " + certificate)
identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
matches = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "' + re.escape(certificate) + r'"$', identities, re.M)
if len(matches) != 1:
    fail("the app's signing certificate must have exactly one valid private-key identity in Keychain: " + certificate)
identity = matches[0]
paths = helpers + [framework, app]
original_entitlements = {}
for path in paths:
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(path)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout else {}
    if entitlements.get("com.apple.security.cs.disable-library-validation", False):
        fail("library validation must remain enabled: " + str(path))
    original_entitlements[path] = entitlements
timestamp = "--timestamp" if certificate.startswith("Developer ID Application:") else "--timestamp=none"
for path in paths:
    run(["codesign", "--force", "--sign", identity, "--options", "runtime", timestamp,
         "--preserve-metadata=identifier,entitlements", path])
for path in paths:
    run(["codesign", "--verify", "--strict", path])
    signed_authorities, signed_team, signed_runtime = signature(path)
    if not signed_authorities or signed_authorities[0] != certificate or signed_team != team or not signed_runtime:
        fail("signing identity, team, or Hardened Runtime verification failed: " + str(path))
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(path)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout) if result.stdout else {}
    if entitlements != original_entitlements[path]:
        fail("entitlements changed while signing: " + str(path))
run(["codesign", "--verify", "--deep", "--strict", app])
print("Signed Sparkle's four helpers, framework and app; same team " + team + ", Hardened Runtime and original entitlements verified.")
PY
