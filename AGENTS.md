# Fork maintenance

This checkout maintains BenjaminD2023/OhMyShot. `origin` is the maintained fork; `upstream` is fzlzjerry/OhMyShot.

Keep upstream changes integrated while preserving the user features and saved preferences in [Docs/FORK_FEATURES.md](Docs/FORK_FEATURES.md). Resolve conflicts by combining behavior; do not reset the fork to upstream or remove a feature to get a clean merge.

Perform code review and relevant checks before making direct Conventional Commits to the fork's main branch. The user does not want PRs within this fork. Preserve unrelated work.

Use [Docs/releasing.md](Docs/releasing.md) for versioned app, update ZIP, signed appcast and DMG releases. Keep signing keys and local signing configuration private, preserve Hardened Runtime and library validation, and publish matching source and checksums. Do not claim Apple notarization unless actually verified.
