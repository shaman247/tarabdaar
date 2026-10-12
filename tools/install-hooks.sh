#!/bin/bash
# Install the tracked pre-commit guard. Skip once with git commit --no-verify.
set -euo pipefail
cd "$(dirname "$0")/.."
# Resolve Git's active hook directory, including worktrees and core.hooksPath.
hooks_dir=$(git rev-parse --git-path hooks)
mkdir -p "$hooks_dir"
cat > "$hooks_dir/pre-commit" <<'HOOK'
#!/bin/bash
set -euo pipefail
exec "$(git rev-parse --show-toplevel)/tools/pre-commit.sh" "$@"
HOOK
chmod +x "$hooks_dir/pre-commit"
echo "installed $hooks_dir/pre-commit"
