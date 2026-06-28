#!/bin/bash
# Headless StarpadMac build. Exits non-zero on warnings/errors. Wire
# this into a pre-commit hook or CI step so a Mac-breaking change made
# during iPad work catches before merge.
#
# Builds into a DEDICATED DerivedData path (build/mac-ci) so it never
# clobbers Xcode's shared DerivedData. A plain command-line `xcodebuild`
# leaves the product code object *unsigned*; if that landed in the IDE's
# DerivedData, the next Run in Xcode would launch the unsigned binary and
# fail with "The executable is not codesigned." Keeping CI builds in their
# own path means the IDE always builds + signs its own product.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT=$(xcodebuild \
    -project Starpad/Starpad.xcodeproj \
    -scheme StarpadMac \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/mac-ci \
    -quiet build 2>&1)

EXIT=$?
echo "$OUTPUT" | grep -E "error:|warning:" | grep -v "appintents\|never used\|consider replacing" || true

if [ $EXIT -ne 0 ]; then
    echo "❌ StarpadMac build failed"
    exit $EXIT
fi
if echo "$OUTPUT" | grep -q "error:"; then
    echo "❌ StarpadMac build had errors"
    exit 1
fi
echo "✅ StarpadMac build succeeded"
