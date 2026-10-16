#!/usr/bin/env bash
#
# scripts/dispatch-overdue starts a workflow only when its newest run on main
# is older than the limit and no run of it is still going. For sync.yml, only
# a run of every target counts for the age.
#
# A stub gh answers the runs list from a file and records every call, so the
# test needs no network and no token.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

need_tool jq "dispatch-overdue reads the runs list with jq" || { summary; exit; }

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_DIR/calls.log"
case "$1 $2" in
  "api repos/"*/runs\?*)
    [ "${STUB_FAIL:-0}" = 1 ] && exit 4
    cat "$STUB_DIR/runs.json"
    ;;
  "api repos/"*)
    printf '{"state":"%s"}\n' "${STUB_STATE:-active}"
    ;;
  "workflow run") exit 0 ;;
  *)
    echo "stub gh: no answer for: gh $*" >&2
    exit 9
    ;;
esac
EOF
chmod 0755 "$work/bin/gh"
export STUB_DIR="$work" GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux
export PATH="$work/bin:$PATH"

# iso MINUTES_AGO -> an ISO 8601 UTC time that many minutes ago
iso() {
  jq -nr --argjson m "$1" 'now - ($m * 60) | floor | todate'
}

# a_run STATUS MINUTES_AGO [EVENT [TITLE]] -> one run of the runs list, as
# JSON; a scheduled run of every target by default
a_run() {
  jq -nc --arg s "$1" --arg t "$(iso "$2")" --arg e "${3:-schedule}" --arg d "${4:-Sync all targets}" \
    '{status: $s, created_at: $t, event: $e, display_title: $d}'
}

# case_run DESC RUNS_JSON EXPECT_RC EXPECT_DISPATCH(yes|no) [ARGS...]
case_run() {
  local desc="$1" runs="$2" want_rc="$3" want_dispatch="$4" rc=0 got
  shift 4
  printf '%s\n' "$runs" > "$work/runs.json"
  : > "$work/calls.log"
  bash "$REPO_ROOT/scripts/dispatch-overdue" "$@" > "$work/out.log" 2>&1 || rc=$?
  check "$desc: exit status" "$want_rc" "$rc" "scripts/dispatch-overdue $*"
  if grep -q '^gh workflow run ' "$work/calls.log"; then got=yes; else got=no; fi
  check "$desc: workflow started" "$want_dispatch" "$got" "cat calls.log after scripts/dispatch-overdue $*"
}

case_run "a run 30 min old, limit 240" \
  "{\"workflow_runs\":[$(a_run completed 30)]}" 0 no sync.yml 240
case_run "a newest run 300 min old, limit 240" \
  "{\"workflow_runs\":[$(a_run completed 300),$(a_run completed 500)]}" 0 yes sync.yml 240
case_run "an old run and a newer one 10 min old" \
  "{\"workflow_runs\":[$(a_run completed 900),$(a_run completed 10)]}" 0 no sync.yml 240
case_run "an old run that is still in progress" \
  "{\"workflow_runs\":[$(a_run in_progress 600)]}" 0 no sync.yml 240
case_run "an old run and a queued one" \
  "{\"workflow_runs\":[$(a_run completed 600),$(a_run queued 1)]}" 0 no sync.yml 240
case_run "no run at all" '{"workflow_runs":[]}' 0 yes status.yml 120
check "the runs list is the newest 100 runs on main" \
  "gh api repos/pkgforge-dev/mirror-archlinux/actions/workflows/status.yml/runs?branch=main&per_page=100" \
  "$(grep 'runs?' "$work/calls.log")" "scripts/dispatch-overdue status.yml 120; cat calls.log"

# sync.yml: only a run of every target counts for the age. upstream-watch
# starts runs of some targets, and they must not hold back the full sync.
case_run "sync.yml: a recent sync of one target and a full run 300 min old" \
  "{\"workflow_runs\":[$(a_run completed 10 workflow_dispatch 'Sync x86_64-core'),$(a_run completed 300)]}" 0 yes sync.yml 240
case_run "sync.yml: a full dispatch 30 min old counts, by its title" \
  "{\"workflow_runs\":[$(a_run completed 30 workflow_dispatch),$(a_run completed 300)]}" 0 no sync.yml 240
case_run "sync.yml: only runs of some targets" \
  "{\"workflow_runs\":[$(a_run completed 10 workflow_dispatch 'Sync x86_64-core')]}" 0 yes sync.yml 240
if grep -q 'no run of every target on main' "$work/out.log"; then
  ok "sync.yml: only runs of some targets: the warning says no run of every target"
else
  fail "sync.yml: only runs of some targets: the warning says no run of every target" "$(cat "$work/out.log")" \
    "reproduce: scripts/dispatch-overdue sync.yml 240 with one run titled Sync x86_64-core"
fi
case_run "sync.yml: a sync of one target in progress still counts as busy" \
  "{\"workflow_runs\":[$(a_run in_progress 10 workflow_dispatch 'Sync x86_64-core'),$(a_run completed 300)]}" 0 no sync.yml 240
case_run "status.yml: a dispatch 30 min old counts, whatever its title" \
  "{\"workflow_runs\":[$(a_run completed 30 workflow_dispatch Status)]}" 0 no status.yml 120
case_run "a workflow name that is not a file name" '{"workflow_runs":[]}' 2 no 'sync yml' 240
case_run "a limit that is not a number" '{"workflow_runs":[]}' 2 no sync.yml soon

STUB_FAIL=1 case_run "the runs list does not read" '{"workflow_runs":[]}' 1 no sync.yml 240
STUB_STATE=disabled_manually case_run "a workflow a person disabled" '{"workflow_runs":[]}' 0 no sync.yml 240
STUB_STATE=disabled_inactivity case_run "a workflow GitHub disabled for inactivity" '{"workflow_runs":[]}' 0 no sync.yml 240

summary
