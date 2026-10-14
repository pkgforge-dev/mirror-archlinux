#!/usr/bin/env bash
#
# Every script is committed executable. A workflow step that runs
# scripts/plan from a checkout whose index lost the bit fails with 126, and a
# consumer who downloads the wrapper from a raw URL gets whatever mode git had.
#
# The rule, for every file under client/ and scripts/: a file with a #! line
# is 100755, a file without one is a library that is sourced or imported
# (scripts/lib.sh) and is 100644. tests/run.sh is 100755.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  ok "skipped: not a git checkout, the index holds the modes"
  summary
  exit 0
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if script_has_shebang "$f"; then
    want=100755
  else
    want=100644
  fi
  mode="$(git ls-files -s -- "$f" | awk '{ print $1 }')"
  if [ -z "$mode" ]; then
    fail "$f is in the git index" "git ls-files does not list it" "reproduce: git ls-files -s -- $f"
  else
    check "$f is mode $want in the index" "$want" "$mode" "git ls-files -s -- $f"
  fi
done <<< "$(shipped_files; printf '%s\n' tests/run.sh)"

# The library rule above must still give the one sourced library its mode.
check "scripts/lib.sh has no #! line, so it stays 100644" 1 \
  "$(script_has_shebang scripts/lib.sh && echo 0 || echo 1)" "sed -n 1p scripts/lib.sh"

summary
