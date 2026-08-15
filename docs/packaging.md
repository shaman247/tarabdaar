# Packaging & Distribution

Quick reference for shipping Tarabdaar (iOS) and TarabdaarMac outside of Xcode's run-on-device flow. Both apps already have **Hardened Runtime** enabled in their build settings; the iOS app uses Automatic provisioning. What's documented here is the workflow specific to each distribution channel.

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
2. Export to a `.app` using the embedded `ExportOptions.plist`.
3. `codesign --deep --force` with your **Developer ID Application** certificate.
4. `xcrun notarytool submit … --wait` blocks until Apple notarizes.
5. `xcrun stapler staple` writes the notarization ticket into the bundle.

Customize the script's `TEAM_ID` and `SIGN_IDENTITY` at the top. Output lands in `build/Release/Tarabdaar.app`. Zip and distribute.

## macOS — Mac App Store

Generally you'd use Xcode's "Archive → Distribute App → App Store Connect" flow. Hardened Runtime stays enabled.

## iOS — App Store / TestFlight

Standard Xcode archive + upload. The iPad target is a USB-MIDI controller only — it does not require any Local Network usage description, Bonjour service declaration, or multicast entitlement.
