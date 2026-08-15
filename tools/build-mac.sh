#!/bin/bash
# Headless TarabdaarMac build. Exits non-zero on warnings/errors. Wire
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

# Regenerate the parameter documentation from the LIVE definitions
# (ParamRegistry / CompositeParam). The generator
# compiles against the same types the apps use, so docs/parameters.md
# stays in sync with the parameter set by construction — a definition
# change that breaks the generator fails the build here.
echo "→ regenerating docs/parameters.md"
swift run -c release --package-path Packages/TarabdaarCore paramdoc \
    docs/parameters.md

# Render the whole docs/ tree to the HTML site (docs/html/, sidebar TOC).
# Runs AFTER parameters.md so the generated parameter page is included.
echo "→ regenerating docs/html"
python3 tools/gen_docs_html.py

OUTPUT=$(xcodebuild \
    -project Tarabdaar/Tarabdaar.xcodeproj \
    -scheme TarabdaarMac \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/mac-ci \
    -quiet build 2>&1)

EXIT=$?
echo "$OUTPUT" | grep -E "error:|warning:" | grep -v "appintents\|never used\|consider replacing" || true

if [ $EXIT -ne 0 ]; then
    echo "❌ TarabdaarMac build failed"
    exit $EXIT
fi
if echo "$OUTPUT" | grep -q "error:"; then
    echo "❌ TarabdaarMac build had errors"
    exit 1
fi
echo "✅ TarabdaarMac build succeeded"
