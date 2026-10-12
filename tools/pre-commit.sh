#!/bin/bash
# Kept in the checkout so installed hooks pick up guard changes immediately.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# NUL-delimited names cover deletions, renames, spaces and embedded newlines.
# Broad package coverage makes new DSP files/resources guarded by default.
staged_paths=$(mktemp)
trap 'rm -f "$staged_paths"' EXIT
git diff --cached --name-only --no-renames -z > "$staged_paths"
full_guard=false
while IFS= read -r -d '' path; do
    case "$path" in
        Packages/SarangiKit/*|Packages/TarabdaarCore/Package.swift|\
        Packages/TarabdaarCore/Sources/*|Packages/TarabdaarCore/Tests/*|\
        TarabdaarMac/AppController*.swift|TarabdaarMac/*Store.swift|\
        TarabdaarMac/Default.json|*.tarabdaar|\
        tools/test-full.sh|tools/pre-commit.sh|tools/install-hooks.sh)
            full_guard=true
            ;;
    esac
done < "$staged_paths"

# Run both packages even after a failure, and preserve either exit status.
core_rc=0
sarangi_rc=0
if "$full_guard"; then
    echo "pre-commit: sound/parameter change staged — running the full guard"
    tools/test-full.sh || core_rc=$?
else
    echo "pre-commit: fast loop"
    swift test --package-path Packages/TarabdaarCore || core_rc=$?
fi
swift test --package-path Packages/SarangiKit || sarangi_rc=$?
if [ "$core_rc" -ne 0 ] || [ "$sarangi_rc" -ne 0 ]; then
    echo "pre-commit: FAILED (TarabdaarCore rc=$core_rc, SarangiKit rc=$sarangi_rc)" >&2
    exit 1
fi
