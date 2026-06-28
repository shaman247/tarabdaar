# Packaging & Distribution

Quick reference for shipping Starpad (iOS) and StarpadMac outside of Xcode's run-on-device flow. Both apps already have **Hardened Runtime** enabled in their build settings; the iOS app uses Automatic provisioning. What's documented here is the workflow specific to each distribution channel.

## macOS — Developer ID + Notarization

For distribution outside the Mac App Store (e.g. direct download, internal builds), notarize a Hardened-Runtime-enabled `.app` against Apple's notarization service.

**Hosted-AU dependency**: StarpadMac depends on SWAM Viola being installed as a system Audio Unit on the target Mac. The Starpad bundle does not ship the SWAM AU — users must install Audio Modeling's product separately. If SWAM isn't installed, `AudioEngine.loadHostedInstrument` reports "AU not found" via `hostedInstrumentStatus` and the sym pool runs on silence.

### One-time setup

1. Enroll in the Apple Developer Program (paid). You'll get a **Team ID** (10-char) and access to **Developer ID Application** code-signing certificates.
2. Generate an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Save it; you'll pass it to `notarytool`.
3. Store the credentials in your keychain so the script doesn't need them inline:
   ```bash
   xcrun notarytool store-credentials starpad-notary \
       --apple-id "you@example.com" \
       --team-id "YOURTEAMID" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```
   `starpad-notary` is the keychain profile name; the release script reads it.

### Per-release build

Use [`tools/release-mac.sh`](../tools/release-mac.sh). It does:

1. `xcodebuild archive` of the `StarpadMac` scheme.
2. Export to a `.app` using the embedded `ExportOptions.plist`.
3. `codesign --deep --force` with your **Developer ID Application** certificate.
4. `xcrun notarytool submit … --wait` blocks until Apple notarizes.
5. `xcrun stapler staple` writes the notarization ticket into the bundle.

Customize the script's `TEAM_ID` and `SIGN_IDENTITY` at the top. Output lands in `build/Release/Starpad.app`. Zip and distribute.

## macOS — Mac App Store

Generally you'd use Xcode's "Archive → Distribute App → App Store Connect" flow. Hardened Runtime stays enabled.

## iOS — App Store / TestFlight

Standard Xcode archive + upload. The iPad target is a USB-MIDI controller only — it does not require any Local Network usage description, Bonjour service declaration, or multicast entitlement.
