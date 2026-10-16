# Packaging & Distribution

Quick reference for shipping Tarabdaar (iOS) and TarabdaarMac outside of Xcode's run-on-device flow. TarabdaarMac has **Hardened Runtime** enabled; the iOS app uses Automatic provisioning. What's documented here is the workflow specific to each distribution channel.

## Local build and commit checks

`tools/build-mac.sh` regenerates the parameter documentation and HTML reference,
then explicitly builds TarabdaarMac with the Release configuration in
`build/mac-ci`, separate from Xcode’s signed products. The local app is
`build/mac-ci/Build/Products/Release/TarabdaarMac.app`.
Compiler warnings and errors from both the parameter generator and app build are
printed and fail the command. The only ignored diagnostic is Xcode’s
“Metadata extraction skipped. No AppIntents.framework dependency found.” warning.
A tool failure also prints its output and preserves its exit status.

`tools/install-hooks.sh` installs a launcher for the tracked
`tools/pre-commit.sh` in Git’s active hooks directory, respecting worktrees and
`core.hooksPath`. The full TarabdaarCore DSP guard runs for staged changes in:

- Any SarangiKit file, including all engines, DSP effects, fitted resources and tests.
- TarabdaarCore sources, tests or package manifest.
- Mac app-controller and store files, the default preset, or any `.tarabdaar` preset.
- The hook installer, hook implementation or full-guard script.

Other changes run TarabdaarCore’s fast tests. Both routes run SarangiKit’s tests,
even when TarabdaarCore fails; either package failure blocks the commit. Deleted
files and both sides of renames are classified, including names containing spaces
or newlines. `git commit --no-verify` skips the hook once.

`tools/test-full.sh` runs the non-timing suites in parallel in Debug, then runs
`RealtimePerformanceTests` and `RebuildCostTests` serially in Release. Timing
measures the optimized production host and DSP against the audio callback budget;
SarangiKit's forced Debug optimization does not optimize the host render path.
Both phases run even if one fails, and either failure fails the guard.

Run `python3 -m unittest discover -s tools/tests` to check guard routing, package
failure propagation, timing configuration, build-warning handling and generated documentation links
without compiling either package.

## macOS — Developer ID + Notarization

For distribution outside the Mac App Store (e.g. direct download, internal builds), notarize a Hardened-Runtime-enabled `.app` against Apple's notarization service.

**No external dependencies**: TarabdaarMac renders its own String voice (`SarangiKit.BowEngine` + the `CBowKernel` C target, both in-repo) — there is no hosted-AU or plugin dependency to install on the target Mac. The whole instrument ships inside the bundle.

### One-time setup

1. Enroll in the Apple Developer Program (paid). You'll get a **Team ID** (10-char) and access to **Developer ID Application** code-signing certificates.
2. Generate an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Save it; you'll pass it to `notarytool`.
3. Store the credentials in your keychain so the script doesn't need them inline:
   ```bash
   xcrun notarytool store-credentials tarabdaar-notary \
       --apple-id "you@example.com" \
       --team-id "YOURTEAMID" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```
   `tarabdaar-notary` is the keychain profile name; the release script reads it.

### Per-release build

Use [`tools/release-mac.sh`](../tools/release-mac.sh). It does:

1. `xcodebuild archive` of the `TarabdaarMac` scheme.
2. Export to a signed `.app` using its generated `ExportOptions.plist` and Developer ID Application certificate.
3. Zip the app and submit it with `xcrun notarytool submit … --wait`.
4. Staple the notarization ticket with `xcrun stapler staple`, then validate it.

Configure `TEAM_ID` and the `NOTARY_PROFILE` keychain entry before running. Signing uses the Developer ID Application certificate selected by the export options. Output is `build/Release/TarabdaarMac.app`. The release script removes the existing `build/` directory before archiving.

## macOS — Mac App Store

Generally you'd use Xcode's "Archive → Distribute App → App Store Connect" flow. Hardened Runtime stays enabled.

## iOS — App Store / TestFlight

Standard Xcode archive + upload. The iPad is a silent controller using TLP over USB or BLE-MIDI — it does not require any Local Network usage description, Bonjour service declaration, or multicast entitlement.
