#!/usr/bin/env bash
#
# scripts/dispatch-overdue starts a workflow only when its newest run on main
# is older than the limit and no run of it is still going.
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
  "{\"workflow_runs\":[{\"status\":\"completed\",\"created_at\":\"$(iso 30)\"}]}" 0 no sync.yml 240
case_run "a newest run 300 min old, limit 240" \
  "{\"workflow_runs\":[{\"status\":\"completed\",\"created_at\":\"$(iso 300)\"},{\"status\":\"completed\",\"created_at\":\"$(iso 500)\"}]}" 0 yes sync.yml 240
case_run "an old run and a newer one 10 min old" \
  "{\"workflow_runs\":[{\"status\":\"completed\",\"created_at\":\"$(iso 900)\"},{\"status\":\"completed\",\"created_at\":\"$(iso 10)\"}]}" 0 no sync.yml 240
case_run "an old run that is still in progress" \
  "{\"workflow_runs\":[{\"status\":\"in_progress\",\"created_at\":\"$(iso 600)\"}]}" 0 no sync.yml 240
case_run "an old run and a queued one" \
  "{\"workflow_runs\":[{\"status\":\"completed\",\"created_at\":\"$(iso 600)\"},{\"status\":\"queued\",\"created_at\":\"$(iso 1)\"}]}" 0 no sync.yml 240
case_run "no run at all" '{"workflow_runs":[]}' 0 yes status.yml 120
case_run "a workflow name that is not a file name" '{"workflow_runs":[]}' 2 no 'sync yml' 240
case_run "a limit that is not a number" '{"workflow_runs":[]}' 2 no sync.yml soon

STUB_FAIL=1 case_run "the runs list does not read" '{"workflow_runs":[]}' 1 no sync.yml 240
STUB_STATE=disabled_manually case_run "a workflow a person disabled" '{"workflow_runs":[]}' 0 no sync.yml 240
STUB_STATE=disabled_inactivity case_run "a workflow GitHub disabled for inactivity" '{"workflow_runs":[]}' 0 no sync.yml 240

summary
