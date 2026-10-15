#!/usr/bin/env bash
#
# The workflow steps that raise and clear issues run when they are needed.
#
#   - watchdog.yml: the step that raises or clears stale-<target> runs with
#     always(), so a check that failed or was stopped still reports the
#     states it reached; the check-staleness step stops before the job does
#   - status.yml: job worker runs whatever build did, and gives
#     scripts/check-status-record the result of build through env
#   - watchdog.yml: scripts/check-status-site runs with always()
#   - watchdog.yml job schedules and sync.yml job keepalive run
#     scripts/watch-schedules, with issues: write
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"

# step_of WORKFLOW JOB TEXT -> every line of the first step of JOB that holds
# TEXT, its indentation removed
step_of() {
  awk -v job="$2" -v text="$3" '
    function flush() { if (buf != "" && index(buf, text) && !done) { printf "%s", buf; done = 1 } buf = "" }
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { flush(); cur = $1; sub(/:$/, "", cur); next }
    cur != job { next }
    /^      - / { flush(); instep = 1 }
    /^    [^[:space:]]/ { flush(); instep = 0 }
    instep && !/^[[:space:]]*#/ { line = $0; sub(/^[[:space:]]*(-[[:space:]]+)?/, "", line); buf = buf line "\n" }
    END { flush() }
  ' "$1"
}

# job_key WORKFLOW JOB KEY -> the value of KEY at the job level
job_key() {
  awk -v job="$2" -v key="$3" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { cur = $1; sub(/:$/, "", cur); next }
    cur == job && $0 ~ "^    " key ":" { v = $0; sub("^    " key ":[[:space:]]*", "", v); sub(/[[:space:]]+#.*$/, "", v); print v }
  ' "$1"
}

wd=.github/workflows/watchdog.yml
step="$(step_of "$wd" staleness 'scripts/track-issue raise "stale-')"
if [ -z "$step" ]; then
  fail "$wd: a step of job staleness raises stale-<target>" "no step holds scripts/track-issue raise \"stale-" \
    "reproduce: grep -n track-issue $wd"
elif printf '%s' "$step" | grep -qE '^if:.*always\(\)'; then
  ok "$wd: the step that raises or clears stale-<target> runs with always(), also after a check that failed or was stopped"
else
  fail "$wd: the step that raises or clears stale-<target> runs with always(), also after a check that failed or was stopped" \
    "its if: $(printf '%s' "$step" | grep -E '^if:' || [ "$?" -eq 1 ])" \
    "reproduce: grep -n -B3 -A3 'track-issue raise \"stale-' $wd"
fi

step="$(step_of "$wd" staleness 'scripts/check-staleness')"
limit="$(printf '%s' "$step" | awk '/^timeout-minutes:/ { print $2 }')"
job_limit="$(job_key "$wd" staleness timeout-minutes)"
if [ -n "$limit" ] && [ -n "$job_limit" ] && [ "$limit" -lt "$job_limit" ]; then
  ok "$wd: the check-staleness step stops after $limit minutes, before the job's $job_limit"
else
  fail "$wd: the check-staleness step stops before the job does" "step timeout-minutes '${limit}', job '${job_limit}'" \
    "a job stopped by its own limit runs no step after it" "reproduce: grep -n -A3 'check-staleness' $wd"
fi

st=.github/workflows/status.yml
job_if="$(job_key "$st" worker if)"
if [ -z "$job_if" ]; then
  fail "$st: job worker has an if" "no if: at the job level" "reproduce: grep -n -A3 '^  worker:' $st"
elif printf '%s' "$job_if" | grep -q 'needs\.build\.result'; then
  fail "$st: job worker runs whatever build did, so a build that fails raises status-down" "if: $job_if" \
    "a build that fails pushes no record, and a worker job it skips raises nothing" \
    "reproduce: grep -n -A3 '^  worker:' $st"
else
  ok "$st: job worker runs whatever build did, so a build that fails raises status-down"
fi
step="$(step_of "$st" worker 'scripts/check-status-record')"
# shellcheck disable=SC2016 # the step's own text, not an expansion
if printf '%s' "$step" | grep -qE '^BUILD_RESULT: \$\{\{ needs\.build\.result \}\}' &&
  printf '%s' "$step" | grep -q 'check-status-record "$BUILD_RESULT"'; then
  ok "$st: job worker gives scripts/check-status-record the result of build, through env"
else
  fail "$st: job worker gives scripts/check-status-record the result of build, through env" "$step" \
    "reproduce: grep -n -B12 check-status-record $st"
fi

for where in "$wd schedules" ".github/workflows/sync.yml keepalive"; do
  read -r f job <<< "$where"
  step="$(step_of "$f" "$job" 'scripts/watch-schedules')"
  perm="$(awk -v job="$job" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { cur = $1; sub(/:$/, "", cur); inperm = 0; next }
    cur == job && /^    permissions:/ { inperm = 1; next }
    cur == job && inperm && /^      issues:[[:space:]]*write/ { print "write" }
    cur == job && /^    [^[:space:]]/ { inperm = 0 }
  ' "$f")"
  if [ -n "$step" ] && [ "$perm" = write ]; then
    ok "$f: job $job runs scripts/watch-schedules with issues: write, so a stopped schedule raises schedules-stopped"
  else
    fail "$f: job $job runs scripts/watch-schedules with issues: write, so a stopped schedule raises schedules-stopped" \
      "step: ${step:-none runs scripts/watch-schedules}; issues: ${perm:-not write}" \
      "reproduce: grep -n -A14 '^  $job:' $f"
  fi
done

step="$(step_of "$wd" staleness 'scripts/check-status-site')"
if printf '%s' "$step" | grep -qE '^if:.*always\(\)'; then
  ok "$wd: job staleness checks the status record and its copy on Pages, with always()"
else
  fail "$wd: job staleness checks the status record and its copy on Pages, with always()" "${step:-no step runs scripts/check-status-site}" \
    "reproduce: grep -n -B3 check-status-site $wd"
fi

summary
