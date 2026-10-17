# Localization

OhMyShot is in English, Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Japanese (`ja`), Spanish
(`es`), and French (`fr`). It follows the language set in System Settings › General › Language & Region. You can
also pick a language for OhMyShot alone in Settings › General › Language. Translations of more languages are
welcome.

## Where the strings are

Every piece of text the app shows is in a String Catalog (`Localizable.xcstrings`) beside the code that uses it,
with all its translations:

| Catalog | What it holds |
| --- | --- |
| `App/Localizable.xcstrings` | The app target: menus, notifications, Shortcuts actions |
| `App/InfoPlist.xcstrings` | What macOS shows when it asks for the camera, the microphone, or the local network |
| `Extensions/Share/Localizable.xcstrings` | The Share menu extension |
| `Packages/OhMyShotKit/Sources/<module>/Resources/Localizable.xcstrings` | Each package module: `OMSCore`, `OMSCapture`, `OMSUI`, `OMSAnnotate`, `OMSStudio` |

The languages offered in Settings › General › Language are the ones in `App/Localizable.xcstrings`. A new
language appears there once that catalog has it, so you don't need to change any code.

## Adding a language, or finishing one

You can translate in Xcode or without it.

**Without Xcode** (Python 3 is all you need):

```sh
Scripts/l10n.py export de          # writes de.json: every string German still lacks
# fill in each "translation" in de.json with any text editor or translation tool
Scripts/l10n.py import de.json     # puts the translations into the catalogs
Scripts/l10n.py check              # every translation keeps the English's placeholders
```

Use the codes Apple uses, such as `de`, `it`, `ko`, `pt-BR`, or `zh-HK`. `Scripts/l10n.py status` shows how far
each language has got. `export de --all` exports every string, translated ones included, so you can review them.

**In Xcode**, open a catalog. To add a language, click + under the language list. Then fill in the column. Do this
for each catalog in the table above.

Then build (`Scripts/build.sh`), choose your language in Settings › General › Language, relaunch, and look
around. Open a pull request with the changed `.xcstrings` files.

## How to translate

- **Placeholders stay.** `%@`, `%lld`, `%d`, and `%.1f` are where the app puts a name or a number. Keep every one,
  of the same kind. If your language needs them in another order, number them all: `%2$@ … %1$@`. Keep `${…}`
  (Shortcuts parameters) and template tokens such as `{date}`, `{app}`, `{json:…}` as they are.
  `Scripts/l10n.py check` catches what's missing.
- **Plurals.** A few strings have plural forms ("1 capture", "2 captures"). In a JSON export their "english" and
  "translation" are objects keyed by CLDR plural category (`one`, `few`, `many`, `other`…). Give the categories
  your language uses; `other` is always needed.
- **Use the words macOS uses** in your language: System Settings, Privacy & Security, Screen Recording, menu bar,
  clipboard, and key names such as Return, Escape, and Shift. A button or menu item should read like one of
  macOS's own.
- **Keep names consistent.** Translate each feature (Quick Access, Pin, Capture Text, Scrolling Capture, Studio…)
  the same way everywhere. `DESIGN.md` describes each one.
- **VoiceOver text** (labels and announcements) is read aloud, so write it as natural speech.
- Keep "…" where the English has it, and use your language's own punctuation and quotation marks.
- **Check that it fits.** Most of the app grows with its text, but some places are only so wide. If a Settings
  pane cuts off a row, raise `SETTINGS_PANE_WIDTH` in `OMSUI`'s catalog. It's a number of points, not words: 520 in
  English, 580 in French, 600 in Spanish. Anywhere else, shorten the translation or open an issue.
- To see where a string appears, search the code for its English text.

## For developers: adding strings

Write every user-facing string so that it can be localized:

- In a package module, pass `bundle: .module`: `String(localized: "Copy", bundle: .module)`,
  `Text("Copy", bundle: .module)`. Without it the string is looked up in the app's catalog, not the module's.
- In the app and the Share extension, `String(localized: "Copy")` is enough.
- Interpolate instead of concatenating: `String(localized: "Uploaded to \(name).")`. This gives translators the
  whole sentence and lets them move the name.
- Use the catalog's plural variations for counts, not `count == 1 ? … : …`.
- Text that people never see, such as logs, file-format keys, and identifiers, stays English and unlocalized.

Building in Xcode adds new strings to the catalogs. On the command line, run `Scripts/sync-strings.sh`, which
builds and then adds the strings the code uses to each catalog and marks the ones it no longer uses as stale.
Commit the catalogs with the code. A string with no translation shows in English until someone translates it.
