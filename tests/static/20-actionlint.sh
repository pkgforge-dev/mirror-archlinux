#!/usr/bin/env bash
#
# Every workflow passes actionlint, which also runs shellcheck over each run:
# block. An `if: !cancelled()` left unquoted is a YAML tag, not an expression,
# and this is where that is caught.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

if ! command -v actionlint > /dev/null 2>&1; then
  fail "actionlint is on PATH" "the static suite needs it" "reproduce: scripts/install-test-tools ./bin && PATH=\$PWD/bin:\$PATH tests/run.sh static"
  summary
  exit 1
fi

cd "$REPO_ROOT"
found=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$f" ] || continue
  found=$((found + 1))
  out="$(actionlint -no-color "$f" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "actionlint $f"
  else
    fail "actionlint $f" "$(printf '%s\n' "$out" | sed -n 1,30p)" "reproduce: actionlint $f"
  fi
done
if [ "$found" -eq 0 ]; then
  fail "there are workflows to lint" "no .github/workflows/*.yml or *.yaml" "reproduce: ls .github/workflows"
fi

summary
