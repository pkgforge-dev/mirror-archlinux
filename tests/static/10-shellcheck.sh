#!/usr/bin/env bash
#
# Every shell file passes shellcheck, in the dialect its first line names: the
# wrapper as POSIX sh, the rest as bash.
#
# The wrapper runs under whatever /bin/sh a consumer has (bash on Arch, dash
# and busybox elsewhere), so a bashism in it is a bug that only shows on
# someone else's machine.
#
# The files are found, not listed: every shell script under client/ and
# scripts/, and every one in the test suites (run.sh, the harness and each
# suite's files). tests/lib/harness.sh script_kind decides what is shell.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

if ! command -v shellcheck > /dev/null 2>&1; then
  fail "shellcheck is on PATH" "the static suite needs it" "reproduce: scripts/install-test-tools ./bin && PATH=\$PWD/bin:\$PATH tests/run.sh static"
  summary
  exit 1
fi

cd "$REPO_ROOT"
files="$(
  shipped_scripts
  test_scripts
)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  shell="$(script_kind "$f")"
  out="$(shellcheck -x --source-path=SCRIPTDIR -s "$shell" "$f" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "shellcheck -s $shell $f"
  else
    fail "shellcheck -s $shell $f" "$(printf '%s\n' "$out" | sed -n 1,20p)" "reproduce: shellcheck -x --source-path=SCRIPTDIR -s $shell $f"
  fi
done <<< "$files"

# The wrapper and the files every suite depends on are found by the walk
# above. A walk that misses them misses others too.
for f in client/pacman-oci tests/run.sh tests/lib/harness.sh; do
  if [[ $'\n'"$files"$'\n' == *$'\n'"$f"$'\n'* ]]; then
    ok "the walk finds $f"
  else
    fail "the walk finds $f" "script_kind says $(script_kind "$f")" "reproduce: . tests/lib/harness.sh; shipped_scripts; test_scripts"
  fi
done

summary
