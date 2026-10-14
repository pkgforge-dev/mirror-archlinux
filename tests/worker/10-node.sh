#!/usr/bin/env bash
#
# The Worker's own tests: node --test over worker/test/*.test.js.
#
# They run worker/src/index.js against a mock fetch (a GHCR stand-in) and a
# Cache API stub with a clock. No network. One test runs client/pacman-oci
# --tags under sh and compares every tag with the Worker's tagOf.
#
#   REPO_ROOT=$PWD bash tests/worker/10-node.sh
#
# Needs node 22 or newer and sh on PATH. Each node test is one TAP line here.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

IMAGE_HINT="the pinned image in .github/workflows/worker.yml"
REPRODUCE="node --test 'worker/test/*.test.js'"

if ! command -v node > /dev/null 2>&1; then
  fail "node is on PATH" "the worker suite needs node 22 or newer" "reproduce: run $REPRODUCE in $IMAGE_HINT"
  summary
  exit 1
fi
major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$major" -lt 22 ]; then
  fail "node is 22 or newer" "node on PATH is $(node --version)" "reproduce: run $REPRODUCE in $IMAGE_HINT"
  summary
  exit 1
fi
ok "node $(node --version) is 22 or newer"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

cd "$REPO_ROOT"
rc=0
node --test --test-reporter=tap 'worker/test/*.test.js' > "$work/node.tap" 2>&1 || rc=$?

# Each top-level test point becomes one line of this plan. Subtests and the
# YAML diagnostics are indented and stay in the log below on a failure.
points=0
while IFS= read -r line; do
  case "$line" in
    'ok '*)
      points=$((points + 1))
      ok "node: ${line#ok * - }"
      ;;
    'not ok '*)
      points=$((points + 1))
      fail "node: ${line#not ok * - }" "reproduce: $REPRODUCE"
      ;;
  esac
done < "$work/node.tap"

if [ "$points" -lt 40 ]; then
  fail "node ran the worker tests" "only $points top-level tests reported" "$(sed -n 1,40p "$work/node.tap")" "reproduce: $REPRODUCE"
fi
if [ "$rc" -eq 0 ]; then
  ok "node --test exits 0"
else
  fail "node --test exits 0" "exit $rc; the TAP log follows" "reproduce: $REPRODUCE"
  sed -e 's/^/#   /' "$work/node.tap"
fi

summary
