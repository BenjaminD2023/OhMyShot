#!/bin/sh
# Packages a signed Release build; never builds, changes signing, creates keys, or publishes.
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$task_repo_dir" "$@" <<'PY'
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

repo = Path(sys.argv.pop(1))
parser = argparse.ArgumentParser(prog="Scripts/package-release.sh", description="Create OhMyShot DMG, app-only update ZIP, signed appcast, source archive and checksums. Does not publish or notarize.")
parser.add_argument("--app", required=True, type=Path, help="Already-built, signed Release OhMyShot.app")
parser.add_argument("--output", required=True, type=Path, help="New or empty artifact directory")
parser.add_argument("--version", required=True, help="Expected CFBundleShortVersionString")
parser.add_argument("--build", required=True, help="Expected CFBundleVersion; increase for every update")
parser.add_argument("--tag", required=True, help="Immutable GitHub release tag, e.g. v0.2.0-fork.1")
parser.add_argument("--source-ref", default="HEAD", help="Committed source ref; must match the clean checkout's HEAD")
parser.add_argument("--repository", default="BenjaminD2023/OhMyShot", help="Public GitHub owner/repository")
parser.add_argument("--sparkle-tools", type=Path, default=Path(os.environ.get("SPARKLE_TOOLS", repo / "build/tools/Sparkle-2.10.0/bin")), help="Sparkle 2.10.0 bin directory (or parent); default SPARKLE_TOOLS")
parser.add_argument("--key-account", default=os.environ.get("SPARKLE_KEY_ACCOUNT", "BenjaminD2023.OhMyShot.updates"), help="Existing dedicated Sparkle Keychain account; default SPARKLE_KEY_ACCOUNT")
args = parser.parse_args()

def fail(message):
    raise SystemExit("package-release: " + message)

def command(values, capture=False, cwd=None):
    result = subprocess.run([str(value) for value in values], check=True, cwd=cwd,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode().strip() if capture else None

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

def signature(path):
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], check=True, capture_output=True, text=True)
    text = result.stdout + result.stderr
    team = re.search(r"^TeamIdentifier=(.+)$", text, re.M)
    return {"team": team.group(1) if team else None,
            "authorities": re.findall(r"^Authority=(.+)$", text, re.M),
            "runtime": bool(re.search(r"flags=.*\bruntime\b", text))}

def verify_app(path):
    command(["codesign", "--verify", "--deep", "--strict", path])
    top = signature(path)
    if not top["team"] or top["team"] == "not set" or not top["authorities"]:
        fail("a certificate-signed app with a TeamIdentifier is required; ad-hoc signing is not a distribution identity")
    if not top["runtime"]:
        fail("Hardened Runtime is required")
    entitlements = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)], check=True, capture_output=True).stdout
    if entitlements and plistlib.loads(entitlements).get("com.apple.security.cs.disable-library-validation", False):
        fail("library validation must stay enabled")
    binaries = []
    seen = set()
    magic = {bytes.fromhex(x) for x in ["feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]}
    for candidate in sorted(path.rglob("*")):
        if not candidate.is_file() or candidate.resolve() in seen:
            continue
        seen.add(candidate.resolve())
        with candidate.open("rb") as handle:
            if handle.read(4) not in magic:
                continue
        arches = command(["xcrun", "lipo", "-archs", candidate], capture=True).split()
        if "arm64" not in arches:
            fail("embedded executable lacks arm64: " + str(candidate.relative_to(path)))
        command(["codesign", "--verify", "--strict", candidate])
        signed = signature(candidate)
        if signed["team"] != top["team"]:
            fail("embedded code must use the app's signing team: " + str(candidate.relative_to(path)))
        binaries.append({"path": str(candidate.relative_to(path)), "architectures": arches,
                         "team": signed["team"], "sha256": digest(candidate)})
    return {"team": top["team"], "authorities": top["authorities"], "hardenedRuntime": True,
            "libraryValidationEnabled": True, "machOFiles": binaries}

if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
    fail("repository must be a GitHub owner/repository")
if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.tag) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", args.build):
    fail("invalid release tag or numeric build version")
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.version):
    fail("version must be a numeric marketing version")
app = args.app.resolve()
if app.name != "OhMyShot.app" or not (app / "Contents/Info.plist").is_file():
    fail("--app must point to OhMyShot.app")
output = args.output.resolve()
if output.exists() and not output.is_dir():
    fail("output must be a directory")
if output.exists() and any(output.iterdir()):
    fail("output directory must be empty; published version artifacts must not be overwritten")
if output == repo or repo.is_relative_to(output):
    fail("output must not be the checkout or one of its parents")
if output == app or output.is_relative_to(app) or app.is_relative_to(output):
    fail("output must not be inside or contain the input app")
tools = args.sparkle_tools.resolve()
if not (tools / "generate_appcast").is_file():
    tools = tools / "bin"
for tool in ["generate_appcast", "sign_update", "generate_keys"]:
    if not os.access(tools / tool, os.X_OK):
        fail("missing executable Sparkle tool: " + str(tools / tool))
key_arguments = ["--account", args.key_account]

source_commit = command(["git", "rev-parse", args.source_ref + "^{commit}"], capture=True, cwd=repo)
if source_commit != command(["git", "rev-parse", "HEAD"], capture=True, cwd=repo):
    fail("source-ref must match the checkout used for the build")
if command(["git", "status", "--porcelain", "--untracked-files=normal"], capture=True, cwd=repo):
    fail("commit the complete fork and release settings before packaging; source checkout must be clean")
existing_tag = subprocess.run(["git", "rev-parse", "--verify", "refs/tags/" + args.tag + "^{commit}"], cwd=repo, capture_output=True, text=True)
if existing_tag.returncode == 0 and existing_tag.stdout.strip() != source_commit:
    fail("the release tag already identifies a different source commit")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (args.version, args.build):
    fail("app version/build do not match the requested release")
feed_url = f"https://github.com/{args.repository}/releases/latest/download/appcast.xml"
if info.get("SUFeedURL") != feed_url or info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True or info.get("SUSignedFeedFailureExpirationInterval") != 0:
    fail("app must use the fork's stable feed and require feed/pre-extraction signature verification")
try:
    if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
        fail("SUPublicEDKey must contain a 32-byte Ed25519 public key")
except ValueError:
    fail("SUPublicEDKey is not valid base64")
main_binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
if command(["xcrun", "lipo", "-archs", main_binary], capture=True).split() != ["arm64"]:
    fail("the release app must be arm64")
if not (app / "Contents/Frameworks/Sparkle.framework").is_dir():
    fail("Sparkle.framework is missing from the app")
identity = verify_app(app)
# -p only reads an existing public key; it never creates or exports a private key.
public_key = command([tools / "generate_keys", "--account", args.key_account, "-p"], capture=True)
if public_key != info["SUPublicEDKey"]:
    fail("signing account public key does not match the app SUPublicEDKey")
for name in ["LICENSE", "README.md", "Docs/ThirdPartyNotices.txt"]:
    if not (repo / name).is_file():
        fail("missing fork distribution file: " + name)
for name in ["LICENSE", "ThirdPartyNotices.txt"]:
    if not (app / "Contents/Resources" / name).is_file():
        fail("app must embed its distribution license/notice before signing: " + name)

output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".ohmyshot-release-", dir=output.parent) as temporary:
    work = Path(temporary)
    artifacts = work / "artifacts"
    artifacts.mkdir()
    updates = work / "updates"
    updates.mkdir()
    disk = work / "disk"
    disk.mkdir()
    staged_app = disk / "OhMyShot.app"
    command(["ditto", app, staged_app])
    command(["codesign", "--verify", "--deep", "--strict", staged_app])
    stem = f"OhMyShot-{args.version}-build{args.build}-arm64"
    archive = updates / (stem + ".zip")
    command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", staged_app, archive])
    with zipfile.ZipFile(archive) as zipped:
        if not all(name.split("/")[0] in {"OhMyShot.app", "__MACOSX"} for name in zipped.namelist()):
            fail("update ZIP contains files outside the app")
    feed = artifacts / "appcast.xml"
    command([tools / "generate_appcast", *key_arguments, "--download-url-prefix",
             f"https://github.com/{args.repository}/releases/download/{args.tag}/", "--maximum-deltas", "0", "-o", feed, updates])
    # Verification does not rewrite signed XML. Never reformat it after generation.
    command([tools / "sign_update", *key_arguments, "--verify", feed])
    tree = ET.parse(feed)
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = tree.findall("./channel/item")
    if len(items) != 1:
        fail("expected a single latest release in the generated feed")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("generated feed has no update archive")
    version = item.findtext(ns + "version") or enclosure.get(ns + "version")
    short_version = item.findtext(ns + "shortVersionString") or enclosure.get(ns + "shortVersionString")
    expected_url = f"https://github.com/{args.repository}/releases/download/{args.tag}/{archive.name}"
    ed_signature = enclosure.get(ns + "edSignature", "")
    if version != args.build or short_version != args.version or enclosure.get("url") != expected_url or int(enclosure.get("length", "0")) != archive.stat().st_size:
        fail("generated feed metadata does not match the release archive")
    if len(base64.b64decode(ed_signature, validate=True)) != 64:
        fail("archive EdDSA signature is missing or invalid; signing key must match SUPublicEDKey")
    command([tools / "sign_update", *key_arguments, "--verify", archive, ed_signature])
    shutil.move(archive, artifacts / archive.name)

    source = artifacts / f"OhMyShot-{args.tag}-source.tar.gz"
    command(["git", "archive", "--format=tar.gz", "--prefix=OhMyShot-source/", "-o", source, source_commit], cwd=repo)
    shutil.copy2(source, disk / source.name)
    for name in ["LICENSE", "README.md"]:
        shutil.copy2(repo / name, disk / name)
    shutil.copy2(repo / "Docs/ThirdPartyNotices.txt", disk / "ThirdPartyNotices.txt")
    source_url = f"https://github.com/{args.repository}/archive/refs/tags/{args.tag}.tar.gz"
    (disk / "SOURCE.txt").write_text(f"OhMyShot fork: https://github.com/{args.repository}\nRelease tag: {args.tag}\nSource commit: {source_commit}\nComplete tracked source is included in {source.name}.\nGitHub tag source archive: {source_url}\nLicense: GNU GPL version 3 (see LICENSE).\n", encoding="utf-8")
    (disk / "Source Code.webloc").write_bytes(plistlib.dumps({"URL": source_url}))
    (disk / "Applications").symlink_to("/Applications")
    dmg = artifacts / (stem + ".dmg")
    command(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO", "-volname", "OhMyShot " + args.version, "-srcfolder", disk, dmg])
    command(["hdiutil", "verify", "-quiet", dmg])
    distributed = sorted(artifacts.iterdir())
    manifest = {"product": "OhMyShot", "version": args.version, "build": args.build,
                "repository": args.repository, "tag": args.tag, "sourceCommit": source_commit,
                "sourceArchiveURL": source_url, "bundleIdentifier": info.get("CFBundleIdentifier"),
                "architecture": "arm64", "minimumMacOS": info.get("LSMinimumSystemVersion"),
                "feedURL": feed_url, "publicEdKey": info["SUPublicEDKey"],
                "signedFeedVerified": True, "updateSignatureVerified": True,
                "codeSigning": identity, "notarizationVerified": False,
                "notarizationNote": "This script does not notarize or claim Developer ID notarization.",
                "packagingScriptSHA256": digest(repo / "Scripts/package-release.sh"),
                "sparkleTools": {name: digest(tools / name) for name in ["generate_appcast", "sign_update"]},
                "files": {path.name: {"sha256": digest(path), "bytes": path.stat().st_size} for path in distributed}}
    (artifacts / "RELEASE-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (artifacts / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in sorted(artifacts.iterdir())))
    output.mkdir(exist_ok=True)
    if any(output.iterdir()):
        fail("output became nonempty during packaging")
    for path in artifacts.iterdir():
        shutil.move(path, output / path.name)
print("Verified release artifacts: " + str(output))
PY
