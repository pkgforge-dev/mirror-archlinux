#!/usr/bin/env bash
#
# Renovate can move every image pin in the tree, and merges on its own only
# what CI can judge.
#
# An image is pinned as name:tag@sha256:<64 hex>, under a "# tag: <tag>"
# marker line at most three lines before it. The regex manager in
# .github/renovate.json reads that shape, in the files its managerFilePatterns
# name. A pin that it does not match never moves, and nothing says so. Each
# pin is checked here three ways: its file is one the manager reads, the
# manager's regex matches it, and the marker's tag is the pin's tag.
#
# The automerge rules are checked too:
#   - no rule automerges a major update
#   - platformAutomerge is false: main has no required checks, so GitHub's
#     own auto-merge would merge a pull request whose checks are red
#   - ignorePaths is set and names no tests directory: the preset default
#     ignores **/tests/**, and the test pins would never move
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
CONFIG=.github/renovate.json

# Where images are run from: the targets, the workflows, the scripts and the
# test suites. Fixtures are data, and docs are prose.
SCAN_DIRS=(targets .github/workflows scripts client tests)
PIN='(docker\.io|ghcr\.io|quay\.io|gcr\.io|registry\.k8s\.io|public\.ecr\.aws)/[a-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}'

if ! need_tool jq "$CONFIG is read with jq"; then
  summary
  exit 0
fi

if out="$(jq -e . "$CONFIG" 2>&1 > /dev/null)"; then
  ok "$CONFIG is JSON"
else
  fail "$CONFIG is JSON" "$out" "reproduce: jq . $CONFIG"
  summary
  exit 1
fi

#---------------------------------------------------------------------------#
# The automerge rules.
#---------------------------------------------------------------------------#
majors="$(jq -r '.packageRules // [] | to_entries[] | select(.value.automerge == true) | select((.value.matchUpdateTypes // ["(all)"]) | any(. == "major" or . == "(all)")) | "packageRules[\(.key)]"' "$CONFIG")"
check "no rule in $CONFIG automerges a major update" "" "$majors" "jq '.packageRules' $CONFIG"
check "$CONFIG sets platformAutomerge to false" false "$(jq -r '.platformAutomerge' "$CONFIG")" "jq .platformAutomerge $CONFIG"

# The keyring images are the trust root of the non-x86_64 targets, and no CI
# job runs them. Renovate applies packageRules in order and a later rule
# wins, so a rule that names them with automerge false comes after every
# rule with automerge true.
keyring="$(jq -r '
  (.packageRules // []) | to_entries as $r
  | ([$r[] | select(.value.automerge == true) | .key] | max // -1) as $on
  | ([$r[] | select((.value.matchDepNames // []) | index("ghcr.io/pkgforge-dev/archlinux")) | select(.value.automerge == false) | .key] | max // -1) as $off
  | if $off < 0 then "no rule names them with automerge false"
    elif $off < $on then "packageRules[\($on)] comes after packageRules[\($off)] and turns automerge on"
    else "a person merges them" end' "$CONFIG")"
check "the keyring images (ghcr.io/pkgforge-dev/archlinux) never merge on their own" "a person merges them" "$keyring" \
  "jq '.packageRules' $CONFIG"
ignore="$(jq -r '.ignorePaths // ["(unset)"] | .[]' "$CONFIG")"
case "$ignore" in
  *'(unset)'* | *test*)
    fail "$CONFIG sets ignorePaths, and no entry is a tests directory" "ignorePaths: $(printf '%s ' "$ignore")" \
      "config:recommended ignores **/tests/** when ignorePaths is unset" "reproduce: jq .ignorePaths $CONFIG"
    ;;
  *) ok "$CONFIG sets ignorePaths, and no entry is a tests directory" ;;
esac

#---------------------------------------------------------------------------#
# Every image pin is one the regex manager moves.
#---------------------------------------------------------------------------#
patterns="$(jq -r '.customManagers // [] | .[] | select(.customType == "regex" and .datasourceTemplate == "docker") | .managerFilePatterns[]' "$CONFIG")"
regexes="$(jq -r '.customManagers // [] | .[] | select(.customType == "regex" and .datasourceTemplate == "docker") | .matchStrings[]' "$CONFIG")"
if [ -z "$patterns" ] || [ -z "$regexes" ]; then
  fail "$CONFIG has a docker regex manager with file patterns and match strings" \
    "patterns: ${patterns:-none}" "match strings: ${regexes:-none}" "reproduce: jq .customManagers $CONFIG"
  summary
  exit 1
fi

rc=0
grep -P 'x' /dev/null || rc=$?
if [ "$rc" -gt 1 ]; then
  fail "grep -P works here, to run the manager's regex" "grep -P exited $rc" "reproduce: grep -P x /dev/null"
  summary
  exit 1
fi

# read_by_manager FILE: 0 when a managerFilePatterns entry names FILE. An
# entry is a /regex/ or a glob.
read_by_manager() {
  local p re
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      /*/)
        re="${p#/}"
        re="${re%/}"
        if printf '%s\n' "$1" | grep -Eq -- "$re"; then
          return 0
        fi
        ;;
      *)
        # shellcheck disable=SC2053 # a glob, matched as a pattern on purpose
        if [[ $1 == $p ]]; then
          return 0
        fi
        ;;
    esac
  done <<< "$patterns"
  return 1
}

files="$(find "${SCAN_DIRS[@]}" -type f ! -path 'tests/fixtures/*' ! -path '*/__pycache__/*' ! -path '*/node_modules/*' | LC_ALL=C sort)"
pinned_files=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  pins="$(grep -nEo "$PIN" "$f" || [ "$?" -eq 1 ])"
  [ -n "$pins" ] || continue
  pinned_files=$((pinned_files + 1))
  npins="$(printf '%s\n' "$pins" | wc -l)"

  if read_by_manager "$f"; then
    ok "$f: the regex manager reads it ($npins pin(s))"
  else
    fail "$f: the regex manager reads it ($npins pin(s))" "$pins" \
      "no managerFilePatterns entry in $CONFIG names this file" "reproduce: jq '.customManagers[].managerFilePatterns' $CONFIG"
    continue
  fi

  best=0
  wrong=""
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    n=0
    while IFS= read -r -d '' m; do
      n=$((n + 1))
      marker="$(printf '%s\n' "$m" | sed -nE '1s/^.*#[[:space:]]*tag:[[:space:]]*([A-Za-z0-9._-]+).*$/\1/p')"
      tag="$(printf '%s\n' "$m" | grep -oE ':[A-Za-z0-9._-]+@sha256:' | sed -nE '$s/^:(.*)@sha256:$/\1/p')"
      if [ "$marker" != "$tag" ]; then
        wrong="${wrong}marker '# tag: $marker' over a pin tagged '$tag'; "
      fi
    done < <(grep -Pzo -- "$re" "$f" || [ "$?" -eq 1 ])
    if [ "$n" -gt "$best" ]; then
      best="$n"
    fi
  done <<< "$regexes"

  if [ "$best" -eq "$npins" ]; then
    ok "$f: the regex manager matches each of its $npins pin(s)"
  else
    fail "$f: the regex manager matches each of its $npins pin(s)" "matched $best of $npins" "$pins" \
      "each pin needs a '# tag: <tag>' line at most three lines before it" \
      "reproduce: grep -n -B3 '@sha256:' $f"
  fi
  if [ -z "$wrong" ]; then
    ok "$f: each '# tag:' marker names the tag of its pin"
  else
    fail "$f: each '# tag:' marker names the tag of its pin" "$wrong" \
      "Renovate reads the version from the marker, so a stale marker moves the pin to the wrong tag" \
      "reproduce: grep -n -A3 '# tag:' $f"
  fi
done <<< "$files"

if [ "$pinned_files" -gt 0 ]; then
  ok "$pinned_files file(s) in ${SCAN_DIRS[*]} pin an image by digest"
else
  fail "the tree pins images by digest" "no $PIN in ${SCAN_DIRS[*]}" "reproduce: grep -rnE '@sha256:' ${SCAN_DIRS[*]}"
fi

summary
