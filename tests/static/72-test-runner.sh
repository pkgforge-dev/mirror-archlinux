#!/usr/bin/env bash
#
# tests/run.sh finds the files of a suite, runs one file when named, keeps a
# live test off unless its switch is on, and fails when a file fails or when
# no file ran.
#
# ci.yml makes one integration job per line of `tests/run.sh --list
# integration`. A file the list misses gets no job and is never run, and the
# run is still green. So the list is checked here, in a tree of its own with
# known files.
#
# ⚠ A run.sh that hides failures also hides this file's failure. So ci.yml
# runs this file once with bash directly, before tests/run.sh static.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

tree="$work/tree"
mkdir -p "$tree/tests/lib" "$tree/tests/integration" "$tree/tests/worker" "$tree/tests/unit"
cp "$REPO_ROOT/tests/run.sh" "$tree/tests/run.sh"
cp "$REPO_ROOT/tests/lib/harness.sh" "$tree/tests/lib/harness.sh"

# passing_test FILE: a test file of one passing assertion that logs its name.
passing_test() {
  cat > "$1" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$REPO_ROOT/tests/lib/harness.sh"
printf '%s\n' "$(basename "$0")" >> "$REPO_ROOT/ran.log"
ok "a test that passes"
summary
EOF
}
passing_test "$tree/tests/integration/10-first.sh"
passing_test "$tree/tests/integration/20-second.sh"
passing_test "$tree/tests/worker/10-unit.sh"
passing_test "$tree/tests/worker/live.sh"
: > "$tree/tests/integration/notes.txt"

# run ARGS...: run.sh in the tree; output in $out, exit code in $rc, the files
# that ran in $ran (space separated).
run() {
  rc=0
  : > "$tree/ran.log"
  out="$(env -u WORKER_LIVE -u INTEGRATION_LIVE bash "$tree/tests/run.sh" "$@" 2>&1)" || rc=$?
  ran="$(tr '\n' ' ' < "$tree/ran.log")"
}

run --list integration
check "--list integration names each tests/integration/*.sh, in order" "10-first.sh 20-second.sh" \
  "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')" "tests/run.sh --list integration"
check "--list integration exits 0" 0 "$rc" "tests/run.sh --list integration"

run --list worker
check "--list worker leaves out live.sh while WORKER_LIVE is not 1" "10-unit.sh" \
  "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')" "tests/run.sh --list worker"

rc=0
out="$(WORKER_LIVE=1 bash "$tree/tests/run.sh" --list worker 2>&1)" || rc=$?
check "--list worker names live.sh when WORKER_LIVE=1" "10-unit.sh live.sh" \
  "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')" "WORKER_LIVE=1 tests/run.sh --list worker"

run integration
check "integration runs every file of the suite" "10-first.sh 20-second.sh " "$ran" "tests/run.sh integration"
check "integration exits 0 when every file passes" 0 "$rc" "tests/run.sh integration"

run integration 20-second.sh
check "a named file runs alone" "20-second.sh " "$ran" "tests/run.sh integration 20-second.sh"
run integration 20-second
check "a named file runs alone, named without .sh" "20-second.sh " "$ran" "tests/run.sh integration 20-second"
run integration tests/integration/10-first.sh
check "a named file runs alone, named by path" "10-first.sh " "$ran" "tests/run.sh integration tests/integration/10-first.sh"

run integration 30-absent.sh
check "a file that is not in the suite is a usage error" 2 "$rc" "tests/run.sh integration 30-absent.sh"

run worker
check "worker does not run live.sh while WORKER_LIVE is not 1" "10-unit.sh " "$ran" "tests/run.sh worker"
run worker live.sh
check "a named live.sh does not run either" "" "$ran" "tests/run.sh worker live.sh"
check "and the run fails, since no file ran" 1 "$rc" "tests/run.sh worker live.sh"

run unit
check "a suite with no file fails" 1 "$rc" "tests/run.sh unit (in a tree with no unit test)"

cat > "$tree/tests/integration/30-fails.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$REPO_ROOT/tests/lib/harness.sh"
fail "a test that fails"
summary
EOF
run integration
check "a failing file fails the run" 1 "$rc" "tests/run.sh integration (with a failing file)"
check "and every other file still runs" "10-first.sh 20-second.sh " "$ran" "tests/run.sh integration"
case "$out" in
  *"failed: integration/30-fails.sh, reproduce: tests/run.sh integration 30-fails.sh"*)
    ok "the summary names the failed file and the command that runs it alone"
    ;;
  *)
    fail "the summary names the failed file and the command that runs it alone" "$(printf '%s\n' "$out" | tail -n 4)" \
      "reproduce: tests/run.sh integration"
    ;;
esac

run all 10-first.sh
check "all takes no FILE" 2 "$rc" "tests/run.sh all 10-first.sh"
run nosuch
check "an unknown suite is a usage error" 2 "$rc" "tests/run.sh nosuch"

summary
