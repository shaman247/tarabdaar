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
# Compiler diagnostics remain visible, and actionable warnings fail the build.
# Xcode emits this exact metadata warning for apps without App Intents support.
run_checked() {
    local output rc=0 diagnostics
    output=$("$@" 2>&1) || rc=$?
    diagnostics=$(printf '%s\n' "$output" | grep -E 'error:|warning:' |
        grep -vF 'warning: Metadata extraction skipped. No AppIntents.framework dependency found.' || true)
    if [ -n "$diagnostics" ]; then
        printf '%s\n' "$diagnostics"
    fi
    if [ "$rc" -ne 0 ]; then
        # Preserve non-compiler failures as well (signing, tool startup, etc.).
        printf '%s\n' "$output"
        return "$rc"
    fi
    if [ -n "$diagnostics" ]; then
        echo "❌ Build has actionable warnings or errors" >&2
        return 1
    fi
}

echo "→ regenerating docs/parameters.md"
run_checked swift run -c release --package-path Packages/TarabdaarCore paramdoc \
    docs/parameters.md

# Render the whole docs/ tree to the HTML site (docs/html/, sidebar TOC).
# Runs AFTER parameters.md so the generated parameter page is included.
echo "→ regenerating docs/html"
python3 tools/gen_docs_html.py

run_checked xcodebuild \
    -project Tarabdaar/Tarabdaar.xcodeproj \
    -scheme TarabdaarMac \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/mac-ci \
    -quiet build

echo "✅ TarabdaarMac build succeeded"
