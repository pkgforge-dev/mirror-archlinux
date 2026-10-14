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

summary
