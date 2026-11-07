# Release-notes layout and localization verification

2026-11-08; follow-up to the automatic-update feature.

- Removed the Ready to capture label and Thanks for using OhMyShot footer text.
- Reduced the gap from the version badge to the first Markdown heading to 14 pt.
- Completed update UI translations and bundled release-note translations for Simplified Chinese,
  Traditional Chinese, Japanese, Spanish and French; English uses CHANGELOG.md.
- Localized notes must match the exact release. Missing or empty translated sections fall back to
  English, including sections containing only reference-link definitions.
- `Scripts/build.sh`: PASS after the final code change.
- `Scripts/test.sh --filter 'ReleaseNotesTests|BundleDeclarationTests|OMSUITests'`: 178 related tests
  PASS (163 UI and 15 core). The script then fails in the unrelated OhMyShotVLM Metal build at
  `CompileMetalFile`. See `release-notes-test-output.log` for the actual output. No VLM source changed.
- `python3 Scripts/l10n.py check`: PASS. All five localized Markdown files exist in the built app.
- Chinese and French were checked in the real Dev window. Screenshots: `changelog-zh-Hans.png` and
  `changelog-fr.png`. Version 0.2.0 is Debug preview data, not a published release.
- No UI source changed after screenshot capture; the last fix only handles empty note sections.
- Temporary language and update-preview arguments were cleared by restarting the Dev app normally.

## Review ledger

Sol-loop: two rounds with gpt-6.1-sol, xhigh (verified in the saved CLI context).
The ultrafast service tier was explicitly configured in both launches; the saved context does not
report the effective tier. Final verdict: APPROVE.

- S1 [should]: reference definitions made an empty translation appear non-empty. Accepted and fixed
  by checking the section body separately. Two regression cases pass. Round 2 marked S1 resolved.
- No declined findings. Tracked diff before review: 634 insertions / 51 deletions; after the fix:
  640 insertions / 52 deletions. These counts exclude new translations and verification artifacts.
- Raw reported usage: round 1 input 435080, cached input 379264, output 6275, reasoning output 2501;
  round 2 input 577185, cached input 516864, output 6869, reasoning output 2784.

App changes committed locally; not pushed. No PR or new app release was created.
