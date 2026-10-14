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

# ⚠ actionlint 1.7.12, the newest release, does not know the concurrency key
# queue. GitHub documents it for github.com ("Control the concurrency of
# workflows and jobs"; changelog 2026-05-07), and sync.yml uses queue: max.
# Only that one message is ignored. tests/static/50-workflow-policy.sh checks
# the key's value instead. Remove the ignore when actionlint knows the key.
IGNORE_QUEUE='unexpected key "queue" for "concurrency" section'

cd "$REPO_ROOT"
found=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$f" ] || continue
  found=$((found + 1))
  out="$(actionlint -no-color -ignore "$IGNORE_QUEUE" "$f" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "actionlint $f"
  else
    fail "actionlint $f" "$(printf '%s\n' "$out" | sed -n 1,30p)" "reproduce: actionlint -ignore '$IGNORE_QUEUE' $f"
  fi
done
if [ "$found" -eq 0 ]; then
  fail "there are workflows to lint" "no .github/workflows/*.yml or *.yaml" "reproduce: ls .github/workflows"
fi

summary
