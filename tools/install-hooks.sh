#!/bin/bash
# Install the repo's git hooks: a pre-commit that runs the full guard
# (tools/test-full.sh) whenever a kernel, table-builder, parameter,
# artifact or DSP-test file is staged — the change classes CLAUDE.md
# says must not be committed without it. Other commits run the fast
# loop only. Skip once with `git commit --no-verify`.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
staged=$(git diff --cached --name-only)
if echo "$staged" | grep -qE '^Packages/SarangiKit/Sources/CBowKernel/|Bow/Bow(Tables|Engine|Controls|Config)\.swift|ParamRegistry\.swift|bowed_string\.json|Tests/.*(Parity|Realtime|Rebuild|Zipper|LiveParamPush|ByteNull)'; then
    echo "pre-commit: DSP/parameter change staged — running the full guard"
    tools/test-full.sh
    (cd Packages/SarangiKit && swift test 2>&1 | tail -3)
else
    echo "pre-commit: fast loop"
    (cd Packages/TarabdaarCore && swift test 2>&1 | tail -3)
fi
HOOK
chmod +x .git/hooks/pre-commit
echo "installed .git/hooks/pre-commit"
