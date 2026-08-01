---
name: add-xcode-file
description: Add a new source file to the Starpad Xcode project. Use whenever creating a .swift file that must compile into the iOS (Starpad) or macOS (StarpadMac) target — those require hand-editing Starpad.xcodeproj/project.pbxproj with the repo's ID conventions. Files under Packages/ are SPM-discovered and need none of this.
---

# Adding a file to the Starpad Xcode project

## Files under `Packages/` — nothing to do

Drop the `.swift` file into the package's `Sources/<Target>/` directory. SPM
auto-discovers it; no pbxproj edit is needed.

One catch: anything referenced from outside the package must be `public` —
including the type, its `init`, and every method or property used across the
module boundary. A missing `public` on `init` is the usual failure.

## Files in the iOS target (`Starpad/Starpad/`) or macOS target (`StarpadMac/`)

These are **not** auto-discovered. Add the file to
`Starpad.xcodeproj/project.pbxproj` in four places:

1. A `PBXBuildFile` entry — ID prefix `A1xxxxxx` for iOS, `C1xxxxxx` for macOS
2. A `PBXFileReference` entry — `A2xxxxxx` / `C2xxxxxx`
3. The `PBXGroup` children list — iOS group `A5000002`, macOS group `C5000001`
4. The `PBXSourcesBuildPhase` files list — iOS `A7000001`, macOS `C7000001`

Use sequential IDs following the existing pattern in the file. A file added to
the group but missing from the build phase will show up in Xcode's navigator
and still fail to link — check all four.

## Verify

```bash
./tools/build-mac.sh
```

The iOS target is not covered by that script; build it separately if the file
landed in `Starpad/Starpad/`:

```bash
cd Starpad && xcodebuild -project Starpad.xcodeproj -scheme Starpad \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' \
  build 2>&1 | grep -E "error:|warning:"
```
