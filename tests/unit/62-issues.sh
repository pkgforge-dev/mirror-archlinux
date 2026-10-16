#!/usr/bin/env bash
#
# The scripts that raise and clear issues, against a stand-in for gh
# (tests/fixtures/issues/fake-gh) that records each issue it would open,
# update or close.
#
#   check-status-record  status-down when status.yml's build did not succeed
#                        or its record is old; worker-down from a fresh
#                        record only
#   check-status-site    status-down when the record on branch status is old;
#                        pages-stale when the copy on Pages trails it
#   watch-schedules      schedules-stopped when a schedule stopped firing or a
#                        workflow was disabled by hand; cleared when all fire
#   report               refused-<target> when more files than
#                        REFUSED_ISSUE_MIN are upstream-refused; and the
#                        promoted count it gives to GITHUB_OUTPUT
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

if ! need_tool jq "the issue scripts against a stand-in for gh (they need jq)"; then
  summary
  exit $?
fi

bin="$work/bin"
mkdir -p "$bin"
cp "$REPO_ROOT/tests/fixtures/issues/fake-gh" "$bin/gh"
cp "$REPO_ROOT/tests/fixtures/status/fake-curl" "$bin/curl"
chmod +x "$bin/gh" "$bin/curl"
NOW="$(jq -n '"2026-10-15T12:00:00Z" | fromdateiso8601')"

# gh_dir NAME [KEY=NUMBER ...]: a fresh FAKE_GH_DIR with an open issue for
# each KEY, as track-issue writes them. Sets gh.
gh_dir() {
  local kv
  gh="$work/gh-$1"
  shift
  mkdir -p "$gh"
  : > "$gh/calls.log"
  for kv in "$@"; do
    jq -n --arg k "${kv%%=*}" --argjson n "${kv#*=}" '{number: $n, body: "<!-- track: \($k) -->\nbody"}'
  done | jq -s . > "$gh/open.json"
}

# record FILE AGE [WORKER_OK WORKER_DOWN]: a status.json measured AGE seconds
# before NOW
record() {
  jq -n --argjson t "$((NOW - $2))" --argjson ok "${3:-true}" --argjson down "${4:-false}" \
    '{schema: 1, generated: ($t | todate), generated_epoch: $t,
      worker: {ok: $ok, down: $down, failed_runs: (if $ok then 0 else 2 end), failing_seconds: null}}' > "$1"
}

# events: the calls that changed something, on one line
events() {
  tr '\n' ';' < "$gh/calls.log" | sed 's/;$//'
}

run_script() {
  local rc=0
  PATH="$bin:$PATH" FAKE_GH_DIR="$gh" FAKE_CURL_ROOT="$work/net" GH_TOKEN=stub GITHUB_REPOSITORY=test/mirror \
    GITHUB_RUN_ID=77 MIRROR_NOW="$NOW" STATUS_PAGES_URL=https://pages.test/mirror/status.json \
    "$@" > "$work/out" 2>&1 || rc=$?
  return "$rc"
}

#---------------------------------------------------------------------------#
# check-status-record: the worker job of status.yml, after each build
#---------------------------------------------------------------------------#
CR="PATH=<fake-gh>:\$PATH FAKE_GH_DIR=DIR MIRROR_NOW=$NOW scripts/check-status-record BUILD STATUS_JSON WORKER_MD"
record "$work/fresh.json" 1800 true false
printf 'worker body\n' > "$work/worker.md"

gh_dir build-failed worker-down=12
rc=0
run_script "$REPO_ROOT/scripts/check-status-record" failure "$work/fresh.json" "$work/worker.md" || rc=$?
check "check-status-record: a build that failed raises status-down; the fresh record still clears worker-down" \
  "0 open status-down;comment 12;close 12" "$rc $(events)" "$CR; $(tail -n 3 "$work/out" | tr '\n' ' ')"
# shellcheck disable=SC2016 # Markdown backticks, not command substitution
if grep -q 'ended `failure`' "$gh/body-status-down.md" && grep -q 'actions/runs/77' "$gh/body-status-down.md"; then
  ok "check-status-record: the status-down body names the build result and the run"
else
  fail "check-status-record: the status-down body names the build result and the run" \
    "$(sed -n 1,10p "$gh/body-status-down.md")" "$CR"
fi

gh_dir build-ok status-down=11
rc=0
run_script "$REPO_ROOT/scripts/check-status-record" success "$work/fresh.json" "$work/worker.md" || rc=$?
check "check-status-record: a build that succeeded with a fresh record clears status-down" \
  "0 comment 11;close 11" "$rc $(events)" "$CR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

record "$work/down.json" 600 false true
gh_dir worker-down status-down=11
rc=0
run_script "$REPO_ROOT/scripts/check-status-record" success "$work/down.json" "$work/worker.md" || rc=$?
check "check-status-record: a fresh record with worker.down raises worker-down" \
  "0 comment 11;close 11;open worker-down" "$rc $(events)" "$CR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

record "$work/old.json" 14400 false true
gh_dir old status-down=11
rc=0
run_script "$REPO_ROOT/scripts/check-status-record" success "$work/old.json" "$work/worker.md" || rc=$?
check "check-status-record: a record 4 h old raises status-down, judges no Worker, and fails" \
  "1 update 11 status-down" "$rc $(events)" "$CR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

gh_dir none
rc=0
run_script "$REPO_ROOT/scripts/check-status-record" skipped "$work/no-such.json" "$work/no-such.md" || rc=$?
check "check-status-record: a skipped build and no record raise status-down, and fail" \
  "1 open status-down" "$rc $(events)" "$CR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

#---------------------------------------------------------------------------#
# check-status-site: the watchdog, from outside status.yml
#---------------------------------------------------------------------------#
CS="PATH=<fake-gh,fake-curl>:\$PATH FAKE_GH_DIR=DIR STATUS_PAGES_URL=https://pages.test/mirror/status.json MIRROR_NOW=$NOW scripts/check-status-site STATUS_JSON"
mkdir -p "$work/net/pages.test/mirror"

record "$work/net/pages.test/mirror/status.json" 1800
gh_dir site-ok pages-stale=13
rc=0
run_script "$REPO_ROOT/scripts/check-status-site" "$work/fresh.json" || rc=$?
check "check-status-site: a fresh record and its copy on Pages clear pages-stale and leave status-down alone" \
  "0 comment 13;close 13" "$rc $(events)" "$CS; $(tail -n 3 "$work/out" | tr '\n' ' ')"

record "$work/old7.json" 25200
record "$work/net/pages.test/mirror/status.json" 25200
gh_dir site-old
rc=0
run_script "$REPO_ROOT/scripts/check-status-site" "$work/old7.json" || rc=$?
check "check-status-site: a record 7 h old raises status-down, exit 3" \
  "3 open status-down" "$rc $(events)" "$CS; $(tail -n 3 "$work/out" | tr '\n' ' ')"

record "$work/net/pages.test/mirror/status.json" $((1800 + 14400))
gh_dir site-behind
rc=0
run_script "$REPO_ROOT/scripts/check-status-site" "$work/fresh.json" || rc=$?
check "check-status-site: a copy on Pages 4 h behind the branch raises pages-stale, exit 3" \
  "3 open pages-stale" "$rc $(events)" "$CS; $(tail -n 3 "$work/out" | tr '\n' ' ')"

printf '404\n' > "$work/net/pages.test/mirror/status.json.code"
gh_dir site-404
rc=0
run_script "$REPO_ROOT/scripts/check-status-site" "$work/fresh.json" || rc=$?
check "check-status-site: a copy on Pages that answers 404 raises pages-stale" \
  "3 open pages-stale" "$rc $(events)" "$CS; $(tail -n 3 "$work/out" | tr '\n' ' ')"
if grep -q 'answered HTTP 404' "$gh/body-pages-stale.md"; then
  ok "check-status-site: the pages-stale body says what Pages answered"
else
  fail "check-status-site: the pages-stale body says what Pages answered" "$(sed -n 1,10p "$gh/body-pages-stale.md")" "$CS"
fi
rm "$work/net/pages.test/mirror/status.json.code"

gh_dir site-none
rc=0
run_script "$REPO_ROOT/scripts/check-status-site" "$work/no-such.json" || rc=$?
check "check-status-site: no record on branch status raises status-down; the copy on Pages is not compared" \
  "3 open status-down" "$rc $(events)" "$CS; $(tail -n 3 "$work/out" | tr '\n' ' ')"

#---------------------------------------------------------------------------#
# watch-schedules: the schedules job of watchdog.yml and the keepalive job of
# sync.yml. The stand-in lists every workflow of the tree, and the last
# scheduled run of each; SCHEDULES_TODAY moves the clock (docs/tests.md).
#---------------------------------------------------------------------------#
# schedules NAME LAST_RUN [PATH=STATE ...]: a fresh FAKE_GH_DIR in which each
# workflow of the tree is active, unless named, and last ran on schedule at
# LAST_RUN; schedules-stopped is open as issue 21
schedules() {
  local name="$1" last="$2" f i=1000 base kv state
  shift 2
  gh_dir "$name" schedules-stopped=21
  : > "$gh/workflows.tsv"
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    i=$((i + 1))
    base="$(basename "$f")"
    state=active
    for kv in "$@"; do
      if [ "${kv%%=*}" = "$base" ]; then
        state="${kv#*=}"
      fi
    done
    printf '%s\t.github/workflows/%s\t%s\n' "$i" "$base" "$state" >> "$gh/workflows.tsv"
    jq -n --arg t "$last" '{total_count: 1, workflow_runs: [{event: "schedule", created_at: $t}]}' > "$gh/runs-$base.json"
  done
  jq -R -n '[inputs | split("\t") | {id: (.[0] | tonumber), path: .[1], name: .[1], state: .[2]}] | {total_count: length, workflows: .}' \
    < "$gh/workflows.tsv" > "$gh/workflows.json"
}
# issue_events: the calls on issues only, on one line
issue_events() {
  awk '!/^enable /' "$gh/calls.log" | tr '\n' ';' | sed 's/;$//'
}
WS="PATH=<fake-gh>:\$PATH FAKE_GH_DIR=DIR SCHEDULES_TODAY=2026-10-15 scripts/watch-schedules"

schedules firing 2026-10-14T10:00:00Z
rc=0
SCHEDULES_TODAY=2026-10-15 run_script "$REPO_ROOT/scripts/watch-schedules" || rc=$?
check "watch-schedules: every schedule fired a day ago: schedules-stopped is cleared, exit 0" \
  "0 comment 21;close 21" "$rc $(issue_events)" "$WS; $(tail -n 3 "$work/out" | tr '\n' ' ')"
check "watch-schedules: every active workflow of the tree is enabled again" \
  "$(find "$REPO_ROOT/.github/workflows" -name '*.yml' | awk 'END { print NR }')" \
  "$(awk '/^enable /' "$gh/calls.log" | awk 'END { print NR }')" "$WS"

schedules stopped 2026-10-05T10:00:00Z
rc=0
SCHEDULES_TODAY=2026-10-15 run_script "$REPO_ROOT/scripts/watch-schedules" || rc=$?
check "watch-schedules: the last scheduled runs are 10 days old: schedules-stopped is raised, and the run stays red (exit 3)" \
  "3 update 21 schedules-stopped" "$rc $(issue_events)" "$WS; $(tail -n 3 "$work/out" | tr '\n' ' ')"
if grep -q '^STOPPED   sync.yml' "$gh/body-schedules-stopped.md" && grep -q '^reproduce:' "$gh/body-schedules-stopped.md"; then
  ok "watch-schedules: the issue body holds each workflow's line and how to reproduce it"
else
  fail "watch-schedules: the issue body holds each workflow's line and how to reproduce it" \
    "$(sed -n 1,20p "$gh/body-schedules-stopped.md")" "$WS"
fi

schedules manual 2026-10-14T10:00:00Z status.yml=disabled_manually
echo '[]' > "$gh/open.json"
rc=0
SCHEDULES_TODAY=2026-10-15 run_script "$REPO_ROOT/scripts/watch-schedules" || rc=$?
check "watch-schedules: a workflow disabled by hand raises schedules-stopped, and is no failure" \
  "0 open schedules-stopped" "$rc $(issue_events)" "$WS; $(tail -n 3 "$work/out" | tr '\n' ' ')"
if grep -q 'status.yml was disabled by hand' "$gh/body-schedules-stopped.md"; then
  ok "watch-schedules: the issue body names the workflow disabled by hand"
else
  fail "watch-schedules: the issue body names the workflow disabled by hand" "$(sed -n 1,30p "$gh/body-schedules-stopped.md")" "$WS"
fi

schedules unreadable 2026-10-14T10:00:00Z
rm "$gh/workflows.json"
rc=0
SCHEDULES_TODAY=2026-10-15 run_script "$REPO_ROOT/scripts/watch-schedules" || rc=$?
check "watch-schedules: a check that could not run clears nothing, and fails" \
  "1 " "$rc $(issue_events)" "$WS; $(tail -n 3 "$work/out" | tr '\n' ' ')"

#---------------------------------------------------------------------------#
# report: refused-<target> when a chain collected more upstream-refused files
# than REFUSED_ISSUE_MIN (16), as a revoked or rotated upstream key makes them
#---------------------------------------------------------------------------#
# report_run NAME STATE REFUSED [KEY=NUMBER ...]: a plan with aarch64-core
# pending, its chain's summary in STATE with REFUSED upstream-refused files,
# then scripts/report with TRACK_ISSUES=1. Sets rc and gh.
report_run() {
  local name="$1" r="$work/report-$1" state="$2" n="$3" i
  shift 3
  gh_dir "report-$name" "$@"
  mkdir -p "$r/plan" "$r/sum/aarch64-core"
  printf 'plan-1\n' > "$r/plan/plan-id"
  printf 'target\tstate\tfiles\tMiB\twhy\naarch64-core\tpending\t20\t1\t20 file(s) to mirror\n' > "$r/plan/summary.tsv"
  printf 'aarch64-core\t%s\tsha256:new latest\n' "$state" > "$r/sum/aarch64-core/state.tsv"
  printf 'plan-1\n' > "$r/sum/aarch64-core/plan-id"
  : > "$r/sum/aarch64-core/refused.tsv"
  for i in $(seq 1 "$n"); do
    printf 'pkg%s-1-1-aarch64.pkg.tar.xz\tsig-refused\terror: pkg%s: signature from "Arch Linux ARM" is invalid\n' "$i" "$i"
  done >> "$r/sum/aarch64-core/refused.tsv"
  rc=0
  : > "$r/github-output"
  GITHUB_OUTPUT="$r/github-output" TRACK_ISSUES=1 run_script env -u GITHUB_STEP_SUMMARY bash "$REPO_ROOT/scripts/report" "$r/plan" "$r/sum" || rc=$?
  github_output="$(cat "$r/github-output")"
}
RR="PATH=<fake-gh>:\$PATH FAKE_GH_DIR=DIR TRACK_ISSUES=1 scripts/report PLAN SUMMARIES"

report_run many promoted 20
check "report: 20 upstream-refused files of a promoted target raise refused-<target>; the run stays green" \
  "0 open refused-aarch64-core" "$rc $(events)" "$RR; $(tail -n 3 "$work/out" | tr '\n' ' ')"
check "report: a promoted target gives promoted=1 to GITHUB_OUTPUT, for the status kick of sync.yml" \
  "promoted=1" "$github_output" "GITHUB_OUTPUT=FILE $RR; cat FILE"
if grep -q 'pkg20-1-1-aarch64.pkg.tar.xz' "$gh/body-refused-aarch64-core.md" &&
  grep -q 'revoked or rotated' "$gh/body-refused-aarch64-core.md"; then
  ok "report: the refused-<target> body lists the files and asks a person to check the key"
else
  fail "report: the refused-<target> body lists the files and asks a person to check the key" \
    "$(sed -n 1,12p "$gh/body-refused-aarch64-core.md")" "$RR"
fi

report_run few promoted 3
check "report: 3 upstream-refused files raise nothing" "0 " "$rc $(events)" "$RR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

report_run none promoted 0 refused-aarch64-core=31
check "report: a later promoted run with none clears refused-<target>" \
  "0 comment 31;close 31" "$rc $(events)" "$RR; $(tail -n 3 "$work/out" | tr '\n' ' ')"

report_run held held 0 refused-aarch64-core=31
check "report: a held target clears nothing: it did not show the files pass" \
  "1 " "$rc $(events)" "$RR; $(tail -n 3 "$work/out" | tr '\n' ' ')"
check "report: a held target gives promoted=0 to GITHUB_OUTPUT, also when the run fails" \
  "promoted=0" "$github_output" "GITHUB_OUTPUT=FILE $RR; cat FILE"

summary
