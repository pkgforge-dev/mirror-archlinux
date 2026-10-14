#!/usr/bin/env bash
#
# Every workflow keeps the shape that makes the mirror safe to leave alone.
#
# Push access to this repository is the mirror's trust root: any workflow on
# any branch can ask for packages: write. These rules keep that write narrow
# and visible:
#   - permissions: {} at the top, and each job asks for what it needs
#   - pages: write and id-token: write only in status.yml's deploy job, and
#     contents: write only in status.yml's build job
#   - shell: bash by default, so every run: block has -eo pipefail
#   - timeout-minutes on every job, so a hang ends in minutes, not six hours.
#     A job that calls a reusable workflow cannot have one; the jobs of the
#     workflow it calls are held to the rule instead.
#   - actions pinned by commit, and checkouts that keep no token on disk. A
#     local path (./.github/workflows/x.yml) is the same commit, so it is pinned.
#   - no ${{ inputs, matrix, needs or event }} inside a run: block, where a
#     value would become shell code; those go through env:
#   - no pull_request_target or workflow_run trigger, which run with a write
#     token on code from elsewhere
#   - no use of the packages DELETE API anywhere: nothing is ever deleted
#   - no unquoted `if: !`, which YAML reads as a tag
#   - nothing needs the jobs that watch the others
#   - every workflow with a schedule: is one scripts/keep-schedules-enabled
#     enables
#   - a re-run does not stop on an artifact of the same name: upload-artifact
#     sets overwrite: true, and the Pages artifact is named per run attempt
#   - a step that starts another workflow skips one that is not active
#   - each run of ci.yml outside a pull request has a concurrency group of
#     its own, so no commit on main loses its verdict to a newer push
#   - a concurrency queue is single or max, max never with
#     cancel-in-progress: true, and sync.yml queues every pending run
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

# job_permissions WORKFLOW -> "job<TAB>scope<TAB>level" for each permission a
# job asks for, in block form or in flow form ({ a: read, b: write }).
job_permissions() {
  awk '
    function emit(pair,   kv) {
      gsub(/[[:space:]]/, "", pair)
      if (pair == "") return
      split(pair, kv, ":")
      print job "\t" kv[1] "\t" kv[2]
    }
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { job = $1; sub(/:$/, "", job); inperm = 0; next }
    /^    permissions:/ {
      rest = $0
      sub(/^    permissions:[[:space:]]*/, "", rest)
      sub(/[[:space:]]*#.*$/, "", rest)
      inperm = (rest == "")
      if (rest ~ /^\{/) {
        gsub(/[{}]/, "", rest)
        n = split(rest, pairs, ",")
        for (i = 1; i <= n; i++) emit(pairs[i])
      } else if (rest != "") {
        print job "\t*\t" rest
      }
      next
    }
    inperm && /^      [A-Za-z-]+:/ { line = $0; sub(/[[:space:]]*#.*$/, "", line); emit(line); next }
    inperm && /^[[:space:]]*(#.*)?$/ { next }
    inperm { inperm = 0 }
  ' "$1"
}

found=0
workflows=()
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$wf" ] || continue
  found=$((found + 1))
  workflows+=("$wf")

  if grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' "$wf"; then
    ok "$wf: top-level permissions: {}"
  else
    fail "$wf: top-level permissions: {}" "every job asks for its own; the top level grants nothing" "reproduce: grep -n '^permissions' $wf"
  fi
  bad="$(grep -nE 'permissions:[[:space:]]*(write-all|read-all)' "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no blanket write-all or read-all"
  else
    fail "$wf: no blanket write-all or read-all" "$bad" "reproduce: grep -n 'permissions:' $wf"
  fi

  # Pages and the OIDC token deploy the status site; contents: write pushes
  # the status branch. Each is one job's, in one workflow.
  bad=""
  while IFS=$'\t' read -r job scope level; do
    [ -n "$job" ] || continue
    case "$scope:$level" in
      pages:write | id-token:write) allowed=status.yml:deploy ;;
      contents:write) allowed=status.yml:build ;;
      *) continue ;;
    esac
    if [ "$(basename "$wf"):$job" != "$allowed" ]; then
      bad="${bad}job $job asks for $scope: $level, which only $allowed may; "
    fi
  done <<< "$(job_permissions "$wf")"
  if [ -z "$bad" ]; then
    ok "$wf: pages, id-token and contents write only where the status site needs them"
  else
    fail "$wf: pages, id-token and contents write only where the status site needs them" "$bad" \
      "reproduce: grep -n -A6 'permissions:' $wf"
  fi

  if awk '/^defaults:/ { d = 1; next } d && /^  run:/ { r = 1; next } d && r && /^    shell: bash[[:space:]]*$/ { found = 1 } /^[a-z]/ { d = 0; r = 0 } END { exit !found }' "$wf"; then
    ok "$wf: defaults run shell bash"
  else
    fail "$wf: defaults run shell bash" "an unspecified shell runs bash -e without pipefail" "reproduce: grep -n -A2 '^defaults' $wf"
  fi

  missing="$(awk '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[a-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (job != "" && !t && !u) print job; job = $1; t = 0; u = 0; next }
    in_jobs && /^    timeout-minutes:/ { t = 1 }
    in_jobs && /^    uses:/ { u = 1 }
    END { if (job != "" && !t && !u) print job }
  ' "$wf")"
  if [ -z "$missing" ]; then
    ok "$wf: every job has timeout-minutes"
  else
    fail "$wf: every job has timeout-minutes" "missing: $missing" "reproduce: grep -n timeout-minutes $wf"
  fi

  unpinned="$(grep -nE '^[[:space:]]*(-[[:space:]]*)?uses:' "$wf" | grep -vE 'uses:[[:space:]]*(\./[^@[:space:]]+|[^@[:space:]]+@[0-9a-f]{40})([[:space:]]|$)' || [ "$?" -eq 1 ])"
  if [ -z "$unpinned" ]; then
    ok "$wf: every action is pinned by commit"
  else
    fail "$wf: every action is pinned by commit" "$unpinned" "reproduce: grep -n 'uses:' $wf"
  fi

  checkouts="$(grep -c 'uses: actions/checkout@' "$wf" || [ "$?" -eq 1 ])"
  kept="$(grep -c 'persist-credentials: false' "$wf" || [ "$?" -eq 1 ])"
  check "$wf: every checkout keeps no token on disk" "${checkouts:-0}" "${kept:-0}" "grep -n -A2 'actions/checkout' $wf"

  interpolated="$(awk '
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>]/ { inrun = 1; ind = -1; next }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/ { if ($0 ~ /\$\{\{[^}]*(inputs|matrix|needs|github\.event|github\.head_ref|steps\.[A-Za-z0-9_-]+\.outputs)/) print FILENAME ":" NR ": " $0; next }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^[[:space:]]*/)
      if (ind < 0) ind = RLENGTH
      if (RLENGTH < ind) { inrun = 0 }
      else if ($0 ~ /\$\{\{[^}]*(inputs|matrix|needs|github\.event|github\.head_ref|steps\.[A-Za-z0-9_-]+\.outputs)/) print FILENAME ":" NR ": " $0
    }
  ' "$wf")"
  if [ -z "$interpolated" ]; then
    ok "$wf: no untrusted value is expanded inside a run: block"
  else
    fail "$wf: no untrusted value is expanded inside a run: block" "$interpolated" "reproduce: grep -n '\${{' $wf"
  fi

  bad="$(grep -nE '^[[:space:]]*(pull_request_target|workflow_run)[[:space:]]*:' "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no pull_request_target or workflow_run trigger"
  else
    fail "$wf: no pull_request_target or workflow_run trigger" "$bad" "reproduce: grep -nE 'pull_request_target|workflow_run' $wf"
  fi

  bad="$(grep -nE "^[[:space:]]*if:[[:space:]]*!" "$wf" || [ "$?" -eq 1 ])"
  if [ -z "$bad" ]; then
    ok "$wf: no unquoted if: !"
  else
    fail "$wf: no unquoted if: !" "$bad" "an if: starting with ! must be inside \${{ }}" "reproduce: grep -n 'if: !' $wf"
  fi

  bad="$(awk '
    /^[[:space:]]*needs:/ {
      if ($0 ~ /(keepalive|staleness|schedules)/) print FILENAME ":" NR ": " $0
      inneeds = ($0 ~ /needs:[[:space:]]*$/)
      next
    }
    inneeds && /^[[:space:]]*-[[:space:]]/ { if ($0 ~ /(keepalive|staleness|schedules)/) print FILENAME ":" NR ": " $0; next }
    { inneeds = 0 }
  ' "$wf")"
  if [ -z "$bad" ]; then
    ok "$wf: nothing needs the jobs that watch the others"
  else
    fail "$wf: nothing needs the jobs that watch the others" "$bad" "reproduce: grep -n needs: $wf"
  fi
done
if [ "$found" -eq 0 ]; then
  fail "there are workflows" "no .github/workflows/*.yml or *.yaml" "reproduce: ls .github/workflows"
fi

#---------------------------------------------------------------------------#
# Nothing is ever deleted: no script or workflow calls the packages DELETE API.
#---------------------------------------------------------------------------#
deleters="$(grep -rnE '(-X|--method|--request)[[:space:]=]*DELETE|\bDELETE\b.*packages|oras[^#]*(manifest|blob)[[:space:]]+delete|delete-package-versions' scripts .github/workflows client || [ "$?" -eq 1 ])"
if [ -z "$deleters" ]; then
  ok "no script or workflow deletes a package or a version"
else
  fail "no script or workflow deletes a package or a version" "$deleters" "reproduce: grep -rn DELETE scripts .github client"
fi

#---------------------------------------------------------------------------#
# Every scheduled workflow is one scripts/keep-schedules-enabled enables.
#
# ⛔ GitHub turns off the schedules of a repository with 60 days of no
# activity. A scheduled workflow that the script does not enable again stops,
# and leaves no run behind to say so. The script runs here against a stub gh:
# the stub lists every workflow in the tree as active, with an id, and records
# each enable call. So the rule holds whether the script names the workflows
# or finds them.
#---------------------------------------------------------------------------#
scheduled=()
for wf in "${workflows[@]}"; do
  if awk '/^on:/ { on = 1; next } on && /^[^[:space:]#]/ { on = 0 } on && /^  schedule:/ { s = 1 } END { exit !s }' "$wf"; then
    scheduled+=("$wf")
  fi
done

if [ "${#scheduled[@]}" -eq 0 ]; then
  ok "no workflow has a schedule, so none needs keep-schedules-enabled"
elif need_tool jq "keep-schedules-enabled enables every scheduled workflow (the script and the stub need jq)"; then
  mkdir -p "$work/bin"
  : > "$work/enabled.log"
  : > "$work/calls.log"
  i=0
  for wf in "${workflows[@]}"; do
    i=$((i + 1))
    printf '%s\t%s\n' "$((1000 + i))" "$wf"
  done > "$work/ids.tsv"
  jq -Rn '[inputs | split("\t") | {id: (.[0] | tonumber), name: .[1], path: .[1], state: "active"}] | {total_count: length, workflows: .}' \
    < "$work/ids.tsv" > "$work/workflows.json"
  cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
# A stand-in for gh: answers the workflow list, records enable calls, refuses
# anything else by name.
set -euo pipefail
printf 'gh %s\n' "$*" >> "$STUB_DIR/calls.log"
args="$*"
jq_expr=""
prev=""
for a in "$@"; do
  case "$prev" in
    --jq | -q) jq_expr="$a" ;;
  esac
  prev="$a"
done
if [[ $args =~ (-X|--method)[[:space:]=]*PUT[[:space:]].*actions/workflows/([^/[:space:]]+)/enable ]]; then
  printf '%s\n' "${BASH_REMATCH[2]}" >> "$STUB_DIR/enabled.log"
elif [[ $args =~ ^workflow[[:space:]]+enable[[:space:]]+([^[:space:]]+) ]]; then
  printf '%s\n' "${BASH_REMATCH[1]}" >> "$STUB_DIR/enabled.log"
elif [[ $args =~ ^api[[:space:]].*actions/workflows(\?[^[:space:]]*)?([[:space:]]|$) ]]; then
  if [ -n "$jq_expr" ]; then
    jq -r "$jq_expr" "$STUB_DIR/workflows.json"
  else
    cat "$STUB_DIR/workflows.json"
  fi
else
  echo "stub gh: no answer for: gh $args" >&2
  exit 1
fi
EOF
  chmod +x "$work/bin/gh"
  rc=0
  out="$(STUB_DIR="$work" GH_TOKEN=stub GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux PATH="$work/bin:$PATH" \
    scripts/keep-schedules-enabled 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "keep-schedules-enabled runs against the stub gh" "exit $rc" "$(printf '%s\n' "$out" | sed -n 1,10p)" \
      "calls: $(tr '\n' ';' < "$work/calls.log")" \
      "reproduce: this file's stub, then GH_TOKEN=x GITHUB_REPOSITORY=o/r PATH=stub:\$PATH scripts/keep-schedules-enabled"
  else
    for wf in "${scheduled[@]}"; do
      id="$(awk -F '\t' -v p="$wf" '$2 == p { print $1 }' "$work/ids.tsv")"
      if grep -qxF -e "$id" -e "$(basename "$wf")" -e "$wf" "$work/enabled.log"; then
        ok "$wf has a schedule, and keep-schedules-enabled enables it"
      else
        fail "$wf has a schedule, and keep-schedules-enabled enables it" \
          "the stub listed it as id $id; the script enabled: $(tr '\n' ' ' < "$work/enabled.log")" \
          "GitHub turns its schedule off after 60 days of no activity, and nothing turns it on again" \
          "reproduce: grep -n schedule: $wf; read scripts/keep-schedules-enabled"
      fi
    done
  fi
fi

#---------------------------------------------------------------------------#
# step_lines WORKFLOW -> "job<TAB>where<TAB>text" for each line of each job.
# where is the line number of the step that holds the line, "out" for a line
# of the job's outputs, or "-" for any other line. text has no indentation
# and no "- "; an input of a step's with: block reads "with.<input>: value".
#---------------------------------------------------------------------------#
step_lines() {
  awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^[:space:]#]/ { injobs = 0 }
    !injobs { next }
    /^[[:space:]]*(#.*)?$/ { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { job = $1; sub(/:$/, "", job); where = "-"; wi = -1; next }
    /^    [^[:space:]]/ { where = ($0 ~ /^    outputs:[[:space:]]*$/) ? "out" : "-"; wi = -1 }
    /^      - / && where != "out" { where = NR; wi = -1 }
    {
      match($0, /^[[:space:]]*/)
      ind = RLENGTH
      t = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?/, "", t)
      if (wi >= 0 && ind <= wi) wi = -1
      pre = (wi >= 0) ? "with." : ""
      if (where != "-" && where != "out" && t ~ /^with:[[:space:]]*$/) wi = ind
      print job "\t" where "\t" pre t
    }
  ' "$1"
}

#---------------------------------------------------------------------------#
# A re-run uploads its artifacts again into the same run. upload-artifact
# refuses a name that is there already unless overwrite: true. deploy-pages
# refuses a name that two artifacts share, and upload-pages-artifact has no
# overwrite: so the Pages artifact is named per run attempt, and deploy-pages
# reads that name from an output of the job that uploads it.
#---------------------------------------------------------------------------#
for wf in "${workflows[@]}"; do
  bad="$(step_lines "$wf" | awk -F '\t' '
    { key = $1 SUBSEP $2 }
    $3 ~ /^uses: actions\/upload-artifact@/ { up[key] = 1 }
    $3 ~ /^with\.overwrite:[[:space:]]*true[[:space:]]*$/ { ow[key] = 1 }
    $3 ~ /^uses: actions\/upload-pages-artifact@/ { pg[key] = 1 }
    $3 ~ /^with\.name:/ { v = $3; sub(/^with\.name:[[:space:]]*/, "", v); nm[key] = v }
    $3 ~ /^uses: actions\/deploy-pages@/ { dp[key] = 1 }
    $3 ~ /^with\.artifact_name:/ { v = $3; sub(/^with\.artifact_name:[[:space:]]*/, "", v); an[key] = v }
    $2 == "out" { v = $3; k = v; sub(/:.*/, "", k); sub(/^[^:]*:[[:space:]]*/, "", v); out[$1 SUBSEP k] = v }
    END {
      for (k in up) if (!(k in ow)) {
        split(k, p, SUBSEP)
        printf "job %s, step at line %s: upload-artifact with no overwrite: true; ", p[1], p[2]
      }
      for (k in pg) {
        split(k, p, SUBSEP)
        if (nm[k] !~ /github\.run_attempt/)
          printf "job %s, step at line %s: the Pages artifact name \"%s\" does not hold github.run_attempt; ", p[1], p[2], nm[k]
        pname[p[1]] = nm[k]
      }
      for (k in dp) {
        split(k, p, SUBSEP)
        if (!match(an[k], /needs\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+/)) {
          printf "job %s, step at line %s: deploy-pages artifact_name \"%s\" is not an output of the job that uploads; ", p[1], p[2], an[k]
          continue
        }
        split(substr(an[k], RSTART, RLENGTH), r, ".")
        if (!((r[2] SUBSEP r[4]) in out) || !(r[2] in pname) || out[r[2] SUBSEP r[4]] != pname[r[2]])
          printf "job %s, step at line %s: output %s of job %s is \"%s\", and its Pages upload is named \"%s\"; ", p[1], p[2], r[4], r[2], out[r[2] SUBSEP r[4]], pname[r[2]]
      }
    }')"
  if [ -z "$bad" ]; then
    ok "$wf: a re-run does not stop on an artifact of the same name"
  else
    fail "$wf: a re-run does not stop on an artifact of the same name" "$bad" \
      "a re-run uploads each artifact again into the same run: upload-artifact refuses the name with no overwrite: true, and deploy-pages refuses a name that two artifacts share" \
      "reproduce: grep -n -A6 -E 'upload-artifact|upload-pages-artifact|deploy-pages|outputs:' $wf"
  fi
done

#---------------------------------------------------------------------------#
# A step that starts another workflow skips one that is not active. GitHub
# refuses to start it (HTTP 422), and a person may disable a workflow on
# purpose: that is a notice, not a red run. A state that does not read still
# fails the step. Each run: block with "gh workflow run" runs here against a
# stub gh, under the shell GitHub uses for shell: bash.
#---------------------------------------------------------------------------#
# run_blocks WORKFLOW DIR: each run: block, its indentation removed, in
# DIR/<base>.<line>.sh
run_blocks() {
  awk -v dir="$2" -v base="$(basename "$1")" '
    function flush() { if (out != "") close(out); out = "" }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/ {
      flush(); out = dir "/" base "." NR ".sh"; printf "" > out; ind = -1; next
    }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/ {
      flush(); line = $0; sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", line)
      f = dir "/" base "." NR ".sh"; print line > f; close(f); next
    }
    out != "" {
      if ($0 ~ /^[[:space:]]*$/) { print "" > out; next }
      match($0, /^[[:space:]]*/)
      if (ind < 0) ind = RLENGTH
      if (RLENGTH < ind) { flush(); next }
      print substr($0, ind + 1) > out
    }
    END { flush() }
  ' "$1"
}

if need_tool jq "a step that starts another workflow skips one that is not active (the stub gh needs jq)"; then
  mkdir -p "$work/blocks" "$work/dispatch-bin"
  for wf in "${workflows[@]}"; do
    run_blocks "$wf" "$work/blocks"
  done
  cat > "$work/dispatch-bin/gh" << 'EOF'
#!/usr/bin/env bash
# A stand-in for gh: a workflow in the state STUB_STATE ("unreadable": the
# read fails). It refuses to start a workflow that is not active, as GitHub
# does, and records each start it accepts.
set -euo pipefail
printf 'gh %s\n' "$*" >> "$STUB_DIR/calls.log"
args="$*"
jq_expr=""
prev=""
for a in "$@"; do
  case "$prev" in
    --jq | -q) jq_expr="$a" ;;
  esac
  prev="$a"
done
if [[ $args =~ ^api[[:space:]]+/?repos/[^[:space:]]+/actions/workflows/([^/?[:space:]]+)([[:space:]]|$) ]]; then
  if [ "$STUB_STATE" = unreadable ]; then
    echo "gh: HTTP 502: Bad Gateway" >&2
    exit 1
  fi
  json="$(jq -n --arg p ".github/workflows/${BASH_REMATCH[1]}" --arg s "$STUB_STATE" '{id: 4242, path: $p, state: $s}')"
  if [ -n "$jq_expr" ]; then
    jq -r "$jq_expr" <<< "$json"
  else
    printf '%s\n' "$json"
  fi
elif [[ $args =~ ^workflow[[:space:]]+run[[:space:]]+([^[:space:]]+) ]]; then
  if [ "$STUB_STATE" != active ]; then
    echo "could not create workflow dispatch event: HTTP 422: Cannot trigger a 'workflow_dispatch' on a disabled workflow" >&2
    exit 1
  fi
  printf '%s\n' "${BASH_REMATCH[1]}" >> "$STUB_DIR/started.log"
else
  echo "stub gh: no answer for: gh $args" >&2
  exit 1
fi
EOF
  chmod +x "$work/dispatch-bin/gh"
  # dispatch BLOCK STATE -> the step's exit status; its output in $work/step.out
  dispatch() {
    : > "$work/calls.log"
    : > "$work/started.log"
    local rc=0
    STUB_DIR="$work" STUB_STATE="$2" GH_TOKEN=stub GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux \
      PATH="$work/dispatch-bin:$PATH" bash --noprofile --norc -eo pipefail "$1" > "$work/step.out" 2>&1 || rc=$?
    return "$rc"
  }
  starters=0
  for block in "$work"/blocks/*.sh; do
    [ -e "$block" ] || continue
    if ! grep -qE '^[^#]*gh workflow run' "$block"; then
      continue
    fi
    starters=$((starters + 1))
    name="$(basename "$block" .sh)"
    where=".github/workflows/${name%.*}, the run: block at line ${name##*.}"
    rc=0
    dispatch "$block" active || rc=$?
    check "$where: starts the workflow when it is active" "0 1" \
      "$rc $(awk 'END { print NR }' "$work/started.log")" \
      "this file's stub gh with STUB_STATE=active; output: $(tr '\n' ' ' < "$work/step.out")"
    rc=0
    dispatch "$block" disabled_manually || rc=$?
    seen="$(awk '/disabled_manually/ { n++ } END { print n + 0 }' "$work/step.out")"
    if [ "$rc" -eq 0 ] && [ ! -s "$work/started.log" ] && [ "$seen" -gt 0 ]; then
      ok "$where: skips a workflow that is not active, and names its state"
    else
      fail "$where: skips a workflow that is not active, and names its state" \
        "exit $rc, started: $(tr '\n' ' ' < "$work/started.log"), state named $seen time(s)" \
        "output: $(tr '\n' ' ' < "$work/step.out")" \
        "GitHub refuses to start a disabled workflow (HTTP 422); a person may disable one on purpose" \
        "reproduce: this file's stub gh with STUB_STATE=disabled_manually"
    fi
    rc=0
    dispatch "$block" unreadable || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok "$where: fails when the workflow's state does not read"
    else
      fail "$where: fails when the workflow's state does not read" "exit 0" \
        "output: $(tr '\n' ' ' < "$work/step.out")" "reproduce: this file's stub gh with STUB_STATE=unreadable"
    fi
  done
  if [ "$starters" -eq 0 ]; then
    ok "no run: block starts another workflow with gh workflow run"
  fi
fi

#---------------------------------------------------------------------------#
# ci.yml: a concurrency group holds one pending run, and a newer run cancels
# it. So each run outside a pull request needs a group of its own, or a
# commit on main between two quick pushes gets no verdict. The group and
# cancel-in-progress expressions are evaluated here for each kind of run.
#---------------------------------------------------------------------------#
# top_concurrency WORKFLOW KEY -> the value of KEY in the top-level
# concurrency block
top_concurrency() {
  awk -v key="$2" '
    /^concurrency:/ { c = 1; next }
    c && /^[^[:space:]#]/ { c = 0 }
    c && $0 ~ "^  " key ":" { v = $0; sub("^  " key ":[[:space:]]*", "", v); sub(/[[:space:]]+#.*$/, "", v); print v }
  ' "$1"
}

ci=.github/workflows/ci.yml
if [ ! -f "$ci" ]; then
  fail "$ci exists" "the concurrency rule of the test runs is checked there" "reproduce: ls .github/workflows"
elif need_tool python3 "$ci: each run outside a pull request has a concurrency group of its own (the evaluator needs python3)"; then
  cat > "$work/expr.py" << 'EOF'
# Evaluate a GitHub Actions template ("text ${{ expr }} text") for each run
# in a JSON list: {"name", "ctx": {"github.x": value}}. Prints
# "name<TAB>value" per run. Covers literals, contexts, ==, !=, !, &&, ||,
# parentheses and format(); any other token stops with a message.
import json
import re
import sys

TOKEN = re.compile(r"\s*(?:('(?:[^']|'')*')|(\d+)|([A-Za-z_][A-Za-z0-9_.-]*)|(==|!=|&&|\|\||!|\(|\)|,))")


def text(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    return str(v)


def truthy(v):
    return v not in (None, False, 0, "")


def fmt(f, *args):
    return re.sub(r"\{(\d+)\}", lambda m: text(args[int(m.group(1))]), f)


def expr(src, ctx):
    src = src.strip()
    toks = []
    pos = 0
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m or m.end() == pos:
            sys.exit("expr.py: cannot read the expression at: %s" % src[pos:])
        pos = m.end()
        s, n, name, op = m.groups()
        if s is not None:
            toks.append(("v", s[1:-1].replace("''", "'")))
        elif n is not None:
            toks.append(("v", int(n)))
        elif name is not None:
            if name in ("true", "false", "null"):
                toks.append(("v", {"true": True, "false": False, "null": None}[name]))
            elif name == "format":
                toks.append(("f", name))
            elif not name.startswith("github."):
                sys.exit("expr.py: unknown name %s" % name)
            else:
                toks.append(("v", ctx.get(name)))
        else:
            toks.append(("o", op))
    i = [0]

    def peek():
        return toks[i[0]] if i[0] < len(toks) else ("end", None)

    def take(want=None):
        t = peek()
        if want is not None and t != ("o", want):
            sys.exit("expr.py: expected %s, found %r in %s" % (want, t, src))
        i[0] += 1
        return t

    def p_or():
        v = p_and()
        while peek() == ("o", "||"):
            take()
            r = p_and()
            v = v if truthy(v) else r
        return v

    def p_and():
        v = p_eq()
        while peek() == ("o", "&&"):
            take()
            r = p_eq()
            v = r if truthy(v) else v
        return v

    def p_eq():
        v = p_not()
        while peek() in (("o", "=="), ("o", "!=")):
            op = take()[1]
            r = p_not()
            same = (v.lower() == r.lower()) if isinstance(v, str) and isinstance(r, str) else v == r
            v = same if op == "==" else not same
        return v

    def p_not():
        if peek() == ("o", "!"):
            take()
            return not truthy(p_not())
        return p_primary()

    def p_primary():
        t = take()
        if t == ("o", "("):
            v = p_or()
            take(")")
            return v
        if t[0] == "f":
            take("(")
            args = [p_or()]
            while peek() == ("o", ","):
                take()
                args.append(p_or())
            take(")")
            return fmt(*args)
        if t[0] == "v":
            return t[1]
        sys.exit("expr.py: unexpected %r in %s" % (t, src))

    v = p_or()
    if peek() != ("end", None):
        sys.exit("expr.py: unread tokens in %s" % src)
    return v


def template(t, ctx):
    out, pos = "", 0
    for m in re.finditer(r"\$\{\{(.*?)\}\}", t):
        out += t[pos:m.start()] + text(expr(m.group(1), ctx))
        pos = m.end()
    return out + t[pos:]


tpl = sys.argv[1]
for run in json.loads(sys.argv[2]):
    print("%s\t%s" % (run["name"], template(tpl, run["ctx"])))
EOF
  runs='[
    {"name": "push1", "ctx": {"github.event_name": "push", "github.ref": "refs/heads/main", "github.run_id": 101, "github.sha": "a1"}},
    {"name": "push2", "ctx": {"github.event_name": "push", "github.ref": "refs/heads/main", "github.run_id": 102, "github.sha": "b2"}},
    {"name": "dispatch", "ctx": {"github.event_name": "workflow_dispatch", "github.ref": "refs/heads/main", "github.run_id": 103, "github.sha": "b2"}},
    {"name": "push7", "ctx": {"github.event_name": "push", "github.ref": "refs/heads/main", "github.run_id": 7, "github.sha": "c3"}},
    {"name": "pr7a", "ctx": {"github.event_name": "pull_request", "github.event.pull_request.number": 7, "github.ref": "refs/pull/7/merge", "github.run_id": 201, "github.sha": "d4"}},
    {"name": "pr7b", "ctx": {"github.event_name": "pull_request", "github.event.pull_request.number": 7, "github.ref": "refs/pull/7/merge", "github.run_id": 202, "github.sha": "e5"}},
    {"name": "pr8", "ctx": {"github.event_name": "pull_request", "github.event.pull_request.number": 8, "github.ref": "refs/pull/8/merge", "github.run_id": 203, "github.sha": "f6"}}]'
  group_tpl="$(top_concurrency "$ci" group)"
  cancel_tpl="$(top_concurrency "$ci" cancel-in-progress)"
  rc=0
  python3 -I "$work/expr.py" "$group_tpl" "$runs" > "$work/groups.tsv" 2> "$work/expr.err" || rc=$?
  python3 -I "$work/expr.py" "$cancel_tpl" "$runs" > "$work/cancels.tsv" 2>> "$work/expr.err" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$group_tpl" ]; then
    fail "$ci: the concurrency group and cancel-in-progress evaluate" "group '$group_tpl', cancel-in-progress '$cancel_tpl'" \
      "$(cat "$work/expr.err")" "reproduce: grep -n -A3 '^concurrency' $ci"
  else
    g() { awk -F '\t' -v n="$1" '$1 == n { print $2 }' "$work/groups.tsv"; }
    c() { awk -F '\t' -v n="$1" '$1 == n { print $2 }' "$work/cancels.tsv"; }
    RC="python3 -I expr.py \"\$(grep -A2 '^concurrency' $ci)\" for each kind of run (this file)"
    if [ "$(g push1)" != "$(g push2)" ] && [ "$(g push1)" != "$(g dispatch)" ] && [ "$(g push2)" != "$(g dispatch)" ]; then
      ok "$ci: two pushes to main and a dispatch get three concurrency groups, so none cancels another's pending run"
    else
      fail "$ci: two pushes to main and a dispatch get three concurrency groups, so none cancels another's pending run" \
        "push 101: '$(g push1)', push 102: '$(g push2)', dispatch 103: '$(g dispatch)'" \
        "a group holds one pending run, and a newer run cancels it" "reproduce: $RC"
    fi
    check "$ci: a run on main never cancels a run in progress" "false false" "$(c push1) $(c dispatch)" "$RC"
    if [ "$(g pr7a)" = "$(g pr7b)" ] && [ "$(c pr7a)" = true ]; then
      ok "$ci: a newer push to a pull request cancels the run of the older one"
    else
      fail "$ci: a newer push to a pull request cancels the run of the older one" \
        "PR 7 run 201: '$(g pr7a)', run 202: '$(g pr7b)', cancel-in-progress '$(c pr7a)'" "reproduce: $RC"
    fi
    if [ "$(g pr7a)" != "$(g push7)" ] && [ "$(g pr7a)" != "$(g pr8)" ]; then
      ok "$ci: the group of a pull request is never the group of another run"
    else
      fail "$ci: the group of a pull request is never the group of another run" \
        "PR 7: '$(g pr7a)', push with run id 7: '$(g push7)', PR 8: '$(g pr8)'" "reproduce: $RC"
    fi
  fi
fi

#---------------------------------------------------------------------------#
# Concurrency queues. actionlint does not know the key queue yet
# (tests/static/20-actionlint.sh ignores it), so its values are checked here:
# single or max, and max never with cancel-in-progress: true, which GitHub
# refuses. sync.yml queues every pending run: with one pending run, a newer
# run cancels it, and a dispatch with allow_older could be replaced by the
# next scheduled run, which plans without it.
#---------------------------------------------------------------------------#
for wf in "${workflows[@]}"; do
  bad="$(awk '
    function done_block() {
      if (inc && q != "") {
        if (q != "single" && q != "max") printf "line %d: queue: %s is not single or max; ", qline, q
        if (q == "max" && cip != "" && cip != "false") printf "line %d: queue: max with cancel-in-progress: %s; ", qline, cip
      }
      inc = 0; q = ""; cip = ""
    }
    /^[[:space:]]*(#.*)?$/ { next }
    {
      match($0, /^[[:space:]]*/)
      ind = RLENGTH
      if (inc && ind <= cind) done_block()
    }
    /^[[:space:]]*concurrency:[[:space:]]*(#.*)?$/ { done_block(); inc = 1; cind = ind; next }
    inc && /^[[:space:]]*queue:/ { q = $0; sub(/^[[:space:]]*queue:[[:space:]]*/, "", q); sub(/[[:space:]]*#.*$/, "", q); qline = NR }
    inc && /^[[:space:]]*cancel-in-progress:/ { cip = $0; sub(/^[[:space:]]*cancel-in-progress:[[:space:]]*/, "", cip); sub(/[[:space:]]*#.*$/, "", cip) }
    END { done_block() }
  ' "$wf")"
  if [ -z "$bad" ]; then
    ok "$wf: every concurrency queue is single or max, and max never cancels in progress"
  else
    fail "$wf: every concurrency queue is single or max, and max never cancels in progress" "$bad" \
      "GitHub refuses queue: max with cancel-in-progress: true" "reproduce: grep -n -A4 'concurrency:' $wf"
  fi
done
sync_wf=.github/workflows/sync.yml
if [ -f "$sync_wf" ]; then
  check "$sync_wf: the group sync queues every pending run, so a dispatch waits its turn" \
    "sync false max" \
    "$(top_concurrency "$sync_wf" group) $(top_concurrency "$sync_wf" cancel-in-progress) $(top_concurrency "$sync_wf" queue)" \
    "grep -n -A4 '^concurrency' $sync_wf"
else
  fail "$sync_wf exists" "the sync is the workflow whose pending runs must not be replaced" "reproduce: ls .github/workflows"
fi

summary
