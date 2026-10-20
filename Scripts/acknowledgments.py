#!/usr/bin/env python3
"""Writes App/Acknowledgments.md: OhMyShot's own license and the notices of the software the app is built with, which
their licenses (MIT, BSD, Apache-2.0, zlib) ask to go with every copy. The app shows it in Settings › About ›
Acknowledgments…; model packs show their own licenses when they're downloaded, so they're not in it.

  python3 -I Scripts/acknowledgments.py            Writes the file from the packages' checkouts.
  python3 -I Scripts/acknowledgments.py --check    Exits 1 if the file isn't what it would write, and writes nothing.

The licenses come from the checkouts Xcode resolved for the app (build/SourcePackages, made by any build of the app;
--source-packages <dir> names another). Run it after a build whenever a dependency changes, and before every release
(Docs/release.md). AcknowledgmentsTests (OMSCoreTests) fails while a resolved package has no entry here, or one of
another version.

What each package brings into the app is listed in PACKAGES below, by hand: a package's own license, and for MLX the
code it vendors, whose notices are in license files or in the comments at the top of a source file. A package that
isn't listed stops the script, and so does a listed file that isn't there. Copyright lines and license files in a
package's compiled sources that nothing below covers are printed as warnings, to look at when MLX is updated.
"""
import argparse
import json
import re
import sys
import textwrap
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App/Acknowledgments.md"
# What the app is built with: the packages' own resolved versions, and the packages project.yml adds for the app.
RESOLVED = [ROOT / "Packages/OhMyShotKit/Package.resolved", ROOT / "Packages/OhMyShotVLM/Package.resolved"]
PROJECT = ROOT / "project.yml"


@dataclass
class Notice:
    """One notice: a license file, or the comment around `marker` in a source file (`header`)."""

    path: str
    title: str = ""
    # Where it is, said under the title: the folder or file in the package, and where it comes from.
    origin: str = ""
    header: str = ""
    # Copies of the same code elsewhere in the package, which the notice covers too.
    also: tuple = ()


@dataclass
class Package:
    name: str
    notices: list
    # Folders of the package whose files are compiled into the app, looked through for notices nothing here covers.
    compiled: list = field(default_factory=list)
    # Holders whose copyright lines need no notice of their own: the package's own license covers them.
    holders: tuple = ()
    # Folders whose own license file is among the notices, so that their files' copyright lines are covered.
    vendored: tuple = ()


CMLX = "Source/Cmlx"
PACKAGES = {
    # A binary (the release's Sparkle.framework); its LICENSE carries the notices of the code it includes.
    "sparkle": Package("Sparkle", [Notice("LICENSE")]),
    "keyboardshortcuts": Package("KeyboardShortcuts", [Notice("license")], compiled=["Sources"]),
    "mlx-swift": Package(
        "MLX Swift",
        [
            Notice("LICENSE"),
            Notice(f"{CMLX}/mlx/LICENSE", "MLX", f"{CMLX}/mlx, from https://github.com/ml-explore/mlx"),
            Notice(f"{CMLX}/mlx-c/LICENSE", "MLX C", f"{CMLX}/mlx-c, from https://github.com/ml-explore/mlx-c"),
            Notice(f"{CMLX}/fmt/LICENSE", "{fmt}", f"{CMLX}/fmt, from https://github.com/fmtlib/fmt"),
            Notice(f"{CMLX}/json/LICENSE.MIT", "JSON for Modern C++", f"{CMLX}/json, from https://github.com/nlohmann/json"),
            Notice(f"{CMLX}/metal-cpp/LICENSE.txt", "metal-cpp", f"{CMLX}/metal-cpp, from https://developer.apple.com/metal/cpp/"),
            Notice(f"{CMLX}/mlx/mlx/3rdparty/pocketfft.h", "PocketFFT", f"{CMLX}/mlx/mlx/3rdparty/pocketfft.h", header="Max-Planck-Society"),
            Notice(
                f"{CMLX}/mlx/mlx/threadpool.h", "ThreadPool", f"{CMLX}/mlx/mlx/threadpool.h", header="Jakob Progsch",
                also=(f"{CMLX}/include-framework/mlx-threadpool.h",),
            ),
            Notice(
                f"{CMLX}/mlx/mlx/small_vector.h", "V8", f"{CMLX}/mlx/mlx/small_vector.h", header="the V8 project authors",
                also=(f"{CMLX}/include-framework/mlx-small_vector.h",),
            ),
            # Two Metal kernels: in default.metallib, in the app's Resources, and in the kernels MLX compiles when used.
            Notice(
                f"{CMLX}/mlx/mlx/backend/metal/kernels/cexpf.h", "Thrust", f"{CMLX}/mlx/mlx/backend/metal/kernels/cexpf.h",
                header="NVIDIA Corporation", also=(f"{CMLX}/mlx-generated/metal/cexpf.h", f"{CMLX}/mlx-generated/unary_ops.cpp"),
            ),
            Notice(
                f"{CMLX}/mlx/mlx/backend/metal/kernels/expm1f.h", "expm1f", f"{CMLX}/mlx/mlx/backend/metal/kernels/expm1f.h",
                header="Norbert Juffa", also=(f"{CMLX}/mlx-generated/metal/expm1f.h", f"{CMLX}/mlx-generated/unary_ops.cpp"),
            ),
        ],
        compiled=["Source"],
        holders=("Apple Inc.", "ml-explore"),
        vendored=(f"{CMLX}/fmt", f"{CMLX}/json", f"{CMLX}/metal-cpp"),
    ),
    "swift-numerics": Package(
        "Swift Numerics", [Notice("LICENSE.txt")], compiled=["Sources"], holders=("Apple Inc. and the Swift Numerics project authors",)
    ),
}

# Not compiled into the app (tests, documentation, other platforms' backends, build files), so not looked through.
SKIPPED_FOLDERS = {
    ".git", "test", "tests", "Tests", "doc", "docs", "Documentation", "examples", "Examples", "benchmarks", "python",
    "cmake", "support", "cuda", "Encuda", "CompileLockRepro", "jaccl", "mpi", "nccl",
}
SOURCE_SUFFIXES = {".h", ".hpp", ".c", ".cc", ".cpp", ".m", ".mm", ".metal", ".swift"}
COPYRIGHT = re.compile(r"Copyright\s*(?:\([cC]\)|©|@)?\s*\d{4}(?:\s*-\s*(?:\d{2,4}|present))?,?\s*(.*)")
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)", re.IGNORECASE)


def fail(message):
    sys.exit(f"acknowledgments: {message}")


def warn(message):
    print(f"acknowledgments: warning: {message}", file=sys.stderr)


def identity(url):
    """A package's identity as SwiftPM names it: the last part of its address, lowercased, without .git."""
    return re.sub(r"\.git$", "", url.rstrip("/").rsplit("/", 1)[-1]).lower()


def resolved():
    """{identity: (address, version)} for every package the app is built with, as the committed files resolve them."""
    packages = {}

    def add(location, version, source):
        key = identity(location)
        if key in packages and packages[key][1] != version:
            fail(f"{key} is {packages[key][1]} in one place and {version} in {source}")
        packages[key] = (location, version)

    for path in RESOLVED:
        for pin in json.loads(path.read_text(encoding="utf-8"))["pins"]:
            add(pin["location"], pin["state"].get("version") or pin["state"]["revision"], path.relative_to(ROOT))
    for location, version in project_packages():
        add(location, version, PROJECT.relative_to(ROOT))
    return packages


def project_packages():
    """(url, exactVersion) for each remote package in project.yml's `packages:`."""
    found, url, inside = [], None, False
    for line in PROJECT.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            inside = line.rstrip() == "packages:"
            continue
        if not inside:
            continue
        if re.match(r"^  \S", line):
            url = None
        key, _, value = line.strip().partition(":")
        if key == "url":
            url = value.strip()
        elif key in ("exactVersion", "version") and url:
            found.append((url, value.strip().strip("\"'")))
        elif key in ("from", "minorVersion", "majorVersion", "branch", "revision", "minVersion") and url:
            fail(f"{url} in project.yml isn't pinned to an exact version, so its notice can't name one")
    return found


def checked_out(source_packages):
    """{identity: version} of the checkouts in Xcode's resolved packages."""
    state = source_packages / "workspace-state.json"
    if not state.exists():
        fail(f"{state} isn't there: build the app first (Scripts/build.sh)")
    versions = {}
    for dependency in json.loads(state.read_text(encoding="utf-8"))["object"]["dependencies"]:
        checkout = dependency["state"].get("checkoutState") or {}
        versions[dependency["packageRef"]["identity"]] = (checkout.get("version") or checkout.get("revision"), dependency.get("subpath"))
    return versions


def header(text, marker, path):
    """The comment around `marker`: a /* */ block, or the run of // lines it's in, without the comment marks."""
    at = text.find(marker)
    if at < 0:
        fail(f"{path} no longer has “{marker}”; look at its notice again")
    opened, closed = text.rfind("/*", 0, at), text.rfind("*/", 0, at)
    if opened > closed:
        end = text.find("*/", at)
        lines = text[opened + 2 : end].splitlines()
        # A block whose every line starts with " * " has them as decoration; elsewhere a "*" is the text's own bullet.
        if all(re.match(r"^\s*\*( |$)", line) for line in lines if line.strip()):
            lines = [re.sub(r"^\s*\*( |$)", "", line) for line in lines]
    else:
        lines = text.splitlines()
        index = text.count("\n", 0, at)
        first = last = index
        while first > 0 and lines[first - 1].lstrip().startswith("//"):
            first -= 1
        while last + 1 < len(lines) and lines[last + 1].lstrip().startswith("//"):
            last += 1
        lines = [line.lstrip()[2:] for line in lines[first : last + 1]]
    return textwrap.dedent("\n".join(lines)).strip("\n")


def unlisted(checkout, package, covered):
    """Copyright lines and license files in the compiled folders that no notice covers."""
    for folder in package.compiled:
        for path in sorted((checkout / folder).rglob("*")):
            relative = path.relative_to(checkout).as_posix()
            if any(part in SKIPPED_FOLDERS for part in path.relative_to(checkout).parts) or not path.is_file():
                continue
            if relative in covered or any(relative.startswith(f"{vendored}/") for vendored in package.vendored):
                continue
            if LICENSE_FILE.match(path.name):
                yield f"{relative} is a license file no notice lists"
            elif path.suffix in SOURCE_SUFFIXES:
                for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                    match = COPYRIGHT.search(line)
                    if match and not any(match.group(1).startswith(holder) for holder in package.holders):
                        yield f"{relative}: {line.strip()}"
                        break


def fenced(text):
    return "```text\n" + text.rstrip() + "\n```"


def document(source_packages):
    packages, versions = resolved(), checked_out(source_packages)
    copyright_line = next(
        (line.strip() for line in (ROOT / "README.md").read_text(encoding="utf-8").splitlines() if line.startswith("Copyright")),
        None,
    ) or fail("README.md has no Copyright line")
    parts = [
        "<!-- Made by Scripts/acknowledgments.py from the licenses in the packages' checkouts. Don't edit it by hand. -->",
        "# Acknowledgments",
        "OhMyShot is built with the software below. Their licenses ask that these notices go with every copy.",
        "## OhMyShot",
        "https://github.com/fzlzjerry/OhMyShot",
        f"{copyright_line}\n\n"
        "OhMyShot is free software: you can redistribute it and modify it under the terms of the GNU General Public "
        "License, version 3, as published by the Free Software Foundation. It comes with no warranty. Its source code "
        "is at the address above, and the license is at the end of this file.",
    ]
    for key in sorted(packages, key=lambda key: PACKAGES[key].name.lower() if key in PACKAGES else key):
        location, version = packages[key]
        if key not in PACKAGES:
            fail(f"{key} ({location}) has no entry in PACKAGES: add what it brings into the app")
        if key not in versions:
            fail(f"{key} isn't in {source_packages}: build the app first (Scripts/build.sh)")
        if versions[key][0] != version:
            fail(f"{key} is checked out at {versions[key][0]} but resolved at {version}: build the app first (Scripts/build.sh)")
        package, checkout = PACKAGES[key], source_packages / "checkouts" / (versions[key][1] or key)
        parts += [f"## {package.name} {version}", location]
        covered = set()
        notices = list(package.notices)
        # Apache-2.0 asks for a work's NOTICE file too.
        for folder in [""] + [str(Path(notice.path).parent) for notice in notices if not notice.header]:
            for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
                path = Path(folder) / name
                if (checkout / path).exists() and all(notice.path != path.as_posix() for notice in notices):
                    notices.append(Notice(path.as_posix(), f"{package.name} NOTICE", path.as_posix()))
        for notice in notices:
            path = checkout / notice.path
            if not path.exists():
                fail(f"{path} isn't there; look at what {package.name} {version} brings again")
            text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
            if notice.header:
                text = header(text, notice.header, path)
            covered.update((notice.path,) + notice.also)
            if notice.title:
                parts += [f"### {notice.title}", f"*In {package.name}: {notice.origin}*"]
            parts.append(fenced(text))
        for message in unlisted(checkout, package, covered):
            warn(f"{package.name}: {message}")
    parts += ["## GNU General Public License, version 3", "The license of OhMyShot.", fenced((ROOT / "LICENSE").read_text(encoding="utf-8"))]
    return "\n\n".join(parts) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--source-packages", type=Path, default=ROOT / "build/SourcePackages")
    parser.add_argument("--check", action="store_true", help="exit 1 if the file isn't up to date, writing nothing")
    arguments = parser.parse_args()
    text = document(arguments.source_packages.resolve())
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else None
    if arguments.check:
        if current != text:
            fail(f"{OUTPUT.relative_to(ROOT)} isn't up to date: run Scripts/acknowledgments.py")
        print(f"{OUTPUT.relative_to(ROOT)} is up to date")
    elif current != text:
        OUTPUT.write_text(text, encoding="utf-8")
        print(f"Wrote {OUTPUT.relative_to(ROOT)}")
    else:
        print(f"{OUTPUT.relative_to(ROOT)} is up to date")


if __name__ == "__main__":
    main()
