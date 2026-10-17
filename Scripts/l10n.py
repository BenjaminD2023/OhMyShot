#!/usr/bin/env python3
"""Works with OhMyShot's translations, the string catalogs (*.xcstrings) beside the code. See Docs/localization.md.

  Scripts/l10n.py status                  How far each language is translated.
  Scripts/l10n.py check                   Checks every translation keeps the English's placeholders (exit 1 if not).
  Scripts/l10n.py export <lang> [file]    Writes the strings <lang> still lacks to a JSON file to translate
                                          (<lang>.json by default; --all for every string, to review).
  Scripts/l10n.py import <file>           Puts a translated export back into the catalogs.

A language is a code as Apple names it: fr, es, ja, de, pt-BR, zh-Hans, zh-Hant… Export and import need nothing but
Python 3, so a language can be translated without Xcode; Xcode's String Catalog editor works on the same files.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_DIRS = ["App", "Extensions", "Packages/OhMyShotKit/Sources"]
SOURCE = "en"
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")


def catalogs():
    """Every string catalog of the app, by its path from the repository's root."""
    found = []
    for directory in CATALOG_DIRS:
        found += sorted((ROOT / directory).rglob("*.xcstrings"))
    return [path for path in found if ".build" not in path.parts]


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, catalog):
    """Writes a catalog the way Xcode does, so saving it in Xcode later changes nothing."""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf-8")


def translatable(entry):
    return entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"


def english(key, entry):
    """The English of an entry: a string, or a dictionary of plural forms."""
    unit = entry.get("localizations", {}).get(SOURCE)
    if not unit:
        return key
    if "stringUnit" in unit:
        return unit["stringUnit"]["value"]
    plural = unit.get("variations", {}).get("plural")
    if plural:
        return {category: form["stringUnit"]["value"] for category, form in plural.items()}
    return key


def translation(entry, language):
    """A language's translation of an entry, as english() gives the English, or None when it has none."""
    unit = entry.get("localizations", {}).get(language)
    if not unit:
        return None
    if "stringUnit" in unit:
        return unit["stringUnit"]["value"] if unit["stringUnit"].get("state") != "new" else None
    plural = unit.get("variations", {}).get("plural")
    if plural:
        return {category: form["stringUnit"]["value"] for category, form in plural.items()}
    return None


def languages():
    found = set()
    for path in catalogs():
        for entry in load(path)["strings"].values():
            found |= set(entry.get("localizations", {}))
    return sorted(found - {SOURCE})


SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:lld|llu|ld|lu|lf|hhd|d|u|f|@|s|x|X|c|g|e))|%%")
PARAMETER = re.compile(r"\$\{[A-Za-z_]+\}")


def specifiers(text):
    """The format specifiers of a string, as (argument position, type) pairs."""
    found, count = [], 0
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        count += 1
        position = int(match.group(1)) if match.group(1) else count
        found.append((position, re.sub(r"^[-+ 0#]*\d*(\.\d+)?", "", match.group(2))))
    return sorted(found)


def problems(source, target):
    """What a translation gets wrong about the English's placeholders."""
    if isinstance(source, dict):
        source = source.get("other", next(iter(source.values())))
    forms = target.items() if isinstance(target, dict) else [(None, target)]
    found = []
    for category, text in forms:
        where = f" [{category}]" if category else ""
        if category and category not in PLURAL_CATEGORIES:
            found.append(f"unknown plural category “{category}”")
        elif not isinstance(text, str) or not text.strip():
            found.append(f"empty translation{where}")
        elif specifiers(source) != specifiers(text):
            found.append(f"placeholders{where} {specifiers(text)} should be {specifiers(source)}")
        elif Counter(PARAMETER.findall(source)) != Counter(PARAMETER.findall(text)):
            found.append(f"${{…}} parameters{where} differ from the English")
    return found


def status():
    total, done = 0, Counter()
    langs = languages()
    for path in catalogs():
        for entry in load(path)["strings"].values():
            if not translatable(entry):
                continue
            total += 1
            for language in langs:
                if translation(entry, language) is not None:
                    done[language] += 1
    print(f"{total} strings to translate")
    for language in langs:
        print(f"  {language:8} {done[language]:5} translated  {100 * done[language] // max(total, 1):3}%")


def check():
    count = 0
    for path in catalogs():
        for key, entry in load(path)["strings"].items():
            for language in sorted(entry.get("localizations", {})):
                if language == SOURCE:
                    continue
                target = translation(entry, language)
                if target is None:
                    continue
                for problem in problems(english(key, entry), target):
                    count += 1
                    print(f"{path.relative_to(ROOT)}: {language}: “{key}”: {problem}")
    print(f"{count} problems" if count else "All translations keep their placeholders.")
    return 1 if count else 0


def export(language, output, everything):
    items = []
    for path in catalogs():
        for key, entry in load(path)["strings"].items():
            if not translatable(entry):
                continue
            existing = translation(entry, language)
            if existing is not None and not everything:
                continue
            item = {"catalog": str(path.relative_to(ROOT)), "key": key}
            if entry.get("comment"):
                item["comment"] = entry["comment"]
            item["english"] = english(key, entry)
            item["translation"] = existing if existing is not None else ""
            items.append(item)
    output = Path(output or f"{language}.json")
    output.write_text(json.dumps({"language": language, "strings": items}, ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    print(f"Wrote {len(items)} strings to {output}. Fill in each “translation”, then: Scripts/l10n.py import {output}")


def import_(file):
    data = json.loads(Path(file).read_text(encoding="utf-8"))
    language = data["language"]
    by_catalog, rejected = {}, 0
    for item in data["strings"]:
        target = item.get("translation")
        if not target:
            continue
        if isinstance(target, str) and isinstance(item["english"], dict):
            target = {"other": target}
        found = problems(item["english"], target)
        if found:
            rejected += 1
            print(f"Skipped “{item['key']}”: {'; '.join(found)}")
            continue
        by_catalog.setdefault(item["catalog"], []).append((item["key"], target))
    imported = 0
    for name, entries in by_catalog.items():
        path = ROOT / name
        catalog = load(path)
        for key, target in entries:
            entry = catalog["strings"].get(key)
            if entry is None:
                print(f"Skipped “{key}”: no longer in {name}")
                continue
            if isinstance(target, dict):
                unit = {"variations": {"plural": {
                    category: {"stringUnit": {"state": "translated", "value": text}}
                    for category, text in target.items()
                }}}
            else:
                unit = {"stringUnit": {"state": "translated", "value": target}}
            entry.setdefault("localizations", {})[language] = unit
            imported += 1
        save(path, catalog)
    print(f"Imported {imported} {language} translations" + (f"; skipped {rejected} with problems" if rejected else ""))
    return 1 if rejected else 0


def main(arguments):
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    command, rest = arguments[0], arguments[1:]
    if command == "status":
        status()
        return 0
    if command == "check":
        return check()
    if command == "export" and rest:
        everything = "--all" in rest
        rest = [argument for argument in rest if argument != "--all"]
        export(rest[0], rest[1] if len(rest) > 1 else None, everything)
        return 0
    if command == "import" and rest:
        return import_(rest[0])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
