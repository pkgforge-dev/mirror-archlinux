#!/usr/bin/env bash
#
# scripts/dispatch-sync starts one sync.yml run on main for the targets it is
# given, only when sync.yml is active and no run of it waits.
#
# A stub gh answers the state and the runs list from files and records every
# call, one argument in each <>, so the test needs no network and no token.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

need_tool jq "dispatch-sync reads the runs list with jq" || { summary; exit; }

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
{
  printf 'gh'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$STUB_DIR/calls.log"
case "$1 $2" in
  "api repos/"*/runs\?*)
    [ "${STUB_RUNS_FAIL:-0}" = 1 ] && exit 4
    cat "$STUB_DIR/runs.json"
    ;;
  "api repos/"*)
    [ "${STUB_STATE_FAIL:-0}" = 1 ] && exit 4
    printf '{"state":"%s"}\n' "${STUB_STATE:-active}"
    ;;
  "workflow run")
    [ "${STUB_RUN_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *)
    echo "stub gh: no answer for: gh $*" >&2
    exit 9
    ;;
esac
EOF
chmod 0755 "$work/bin/gh"
export STUB_DIR="$work" GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux
export PATH="$work/bin:$PATH"

# case_run DESC RUNS_JSON EXPECT_RC EXPECT_START(yes|no) [TARGET...]
# EXPECT_START: whether gh workflow run is called
case_run() {
  local desc="$1" runs="$2" want_rc="$3" want_start="$4" rc=0 got
  shift 4
  printf '%s\n' "$runs" > "$work/runs.json"
  : > "$work/calls.log"
  bash "$REPO_ROOT/scripts/dispatch-sync" "$@" > "$work/out.log" 2>&1 || rc=$?
  check "$desc: exit status" "$want_rc" "$rc" "scripts/dispatch-sync $*; $(tr '\n' ' ' < "$work/out.log")"
  if grep -q '^gh <workflow> <run> ' "$work/calls.log"; then got=yes; else got=no; fi
  check "$desc: gh workflow run is called: $want_start" "$want_start" "$got" "cat calls.log after scripts/dispatch-sync $*"
}

# a_run STATUS -> one run of the runs list, as JSON
a_run() {
  printf '{"status":"%s","event":"workflow_dispatch","display_title":"Sync x86_64-core"}' "$1"
}

case_run "no run of sync.yml" '{"workflow_runs":[]}' 0 yes x86_64-core x86_64-extra
check "two targets: one run, with both in its targets input, on main" \
  "gh <workflow> <run> <sync.yml> <--ref> <main> <--repo> <pkgforge-dev/mirror-archlinux> <-f> <targets=x86_64-core x86_64-extra>" \
  "$(grep '^gh <workflow> <run> ' "$work/calls.log")" "scripts/dispatch-sync x86_64-core x86_64-extra; cat calls.log"
check "the runs list is every run of sync.yml, 50 to a page, of any branch" \
  "gh <api> <repos/pkgforge-dev/mirror-archlinux/actions/workflows/sync.yml/runs?per_page=50>" \
  "$(grep 'runs?' "$work/calls.log")" "scripts/dispatch-sync x86_64-core x86_64-extra; cat calls.log"

case_run "only completed runs" "{\"workflow_runs\":[$(a_run completed),$(a_run completed)]}" 0 yes x86_64-core
case_run "a run in progress, which may have planned before the change" \
  "{\"workflow_runs\":[$(a_run in_progress)]}" 0 yes x86_64-core
for s in queued waiting requested pending; do
  case_run "a run that is $s" "{\"workflow_runs\":[$(a_run completed),$(a_run "$s")]}" 2 no x86_64-core
done
if grep -q 'run(s) of sync.yml wait' "$work/out.log"; then
  ok "a run that waits: the notice says so"
else
  fail "a run that waits: the notice says so" "$(cat "$work/out.log")" "reproduce: scripts/dispatch-sync x86_64-core with a pending run"
fi

STUB_STATE=disabled_manually case_run "a sync.yml a person disabled" '{"workflow_runs":[]}' 2 no x86_64-core
if grep -q 'sync.yml is disabled_manually' "$work/out.log"; then
  ok "a disabled sync.yml: the notice names its state"
else
  fail "a disabled sync.yml: the notice names its state" "$(cat "$work/out.log")" "reproduce: scripts/dispatch-sync x86_64-core with sync.yml disabled"
fi
STUB_STATE_FAIL=1 case_run "the state of sync.yml does not read" '{"workflow_runs":[]}' 1 no x86_64-core
STUB_RUNS_FAIL=1 case_run "the runs list does not read" '{"workflow_runs":[]}' 1 no x86_64-core
STUB_RUN_FAIL=1 case_run "GitHub refuses the start" '{"workflow_runs":[]}' 1 yes x86_64-core

case_run "a target name with a ;" '{"workflow_runs":[]}' 1 no 'x86_64-core;true'
check "a target name with a ;: gh is not called at all" "" "$(cat "$work/calls.log")" "scripts/dispatch-sync 'x86_64-core;true'"
case_run "a target name with a space" '{"workflow_runs":[]}' 1 no 'x86_64-core x86_64-extra'
case_run "no target" '{"workflow_runs":[]}' 1 no

summary
