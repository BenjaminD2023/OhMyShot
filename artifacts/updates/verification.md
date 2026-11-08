Automatic update validation (2026-11-07)

- Debug: Scripts/build.sh PASS; Apple Development designated requirement retained.
- Related tests: OhMyShotKit ReleaseNotesTests, BundleDeclarationTests, OMSUITests: 177 PASS.
- Full Scripts/test.sh: model-pack async tests stalled; stopped. Focused invocation completed related tests,
  then unrelated OhMyShotVLM build failed at CompileMetalFile. Direct Xcode metal shim reports missing Metal
  Toolchain while xcrun resolves installed cryptex toolchain. No VLM source changed.
- Website: installed tsc -p src/worker and tsc -p src/client PASS; 4 node transport tests PASS.
  pnpm wrapper's version bootstrap was unable to reach registry; used installed tsc, without disabling signature checks.
- Local wrangler Worker at localhost:8790 returned production signed feed; cmp with direct GitHub bytes PASS.
- Downloaded full 15,692,643-byte production 0.1.0 zip through local Worker; CryptoKit Ed25519 verification
  against Config/Info.plist public key and appcast signature PASS.
- Real Dev UI: localized changelog, close/continue, update reminder and later action checked. The menu screenshot uses
  a Debug-only NSPopUpButton with the same native menu contents; its first row is Update to 0.2.0.
  Screenshot 0.2.0 is debug-only preview; no release published and no update installed.
- Website production deployment and mainland no-VPN testing are not done.
- Sol-loop gpt-6.1-sol: 5 rounds total (3 production + 2 Debug preview), APPROVE; fixed reminder wake/completion retries, Markdown reference links,
  feed assertion, signed-feed recovery policy, and isolation of the preview menu target. Acknowledged Sparkle fallback documented.

Review ledger: S1 accepted/documented acknowledged fallback; S2 reminder retries fixed; S3 reference links fixed;
S4 configuration assertion fixed; S5 signed-feed expiration disabled; D1 debug menu registrations isolated.
No declined findings. Reviewer token usage was not returned. Tracked diff grew from 494 insertions/45 deletions to
551 insertions/48 deletions during review and visual verification, excluding new files in both counts.
No branch pushed, no PR opened, and no production deployment performed.

Screenshots: `changelog.png`, `reminder.png`, `menu.png`. The 0.2.0 version is preview data, not a published version.
