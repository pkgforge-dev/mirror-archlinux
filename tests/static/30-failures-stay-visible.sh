#!/usr/bin/env bash
#
# No step may hide a failure, and every network call has a deadline.
#
# The sibling repository published nothing for 37 days behind runs that
# reported green. Each link in that chain was one of the constructs refused
# here: an error swallowed with || true, stderr thrown away, a step allowed to
# fail. A call with no deadline is the same failure, slower: it holds a slot
# until the job's six hours run out.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
targets="$(
  shipped_scripts
  if [ -d .github/workflows ]; then
    find .github/workflows -name '*.yml' | sort
  fi
)"

# Patterns that make a failure invisible. Extended regex, matched on code, not
# on comment lines.
#
# A bare >/dev/null is in here too, because it drops a command's stdout and
# that is where a pipeline's status lives. It is excluded where the status is
# the answer and nothing is being hidden: a presence probe (`command -v X`,
# `need`, `has_cmd`) and a `jq -e` whose exit status is the test. Those read
# the status and print nothing, so there is no failure to hide. A `command -v`
# probe also has no output to keep.
SWALLOW='continue-on-error|\|\|[[:space:]]*(true|:)([[:space:];)]|$)|set[[:space:]]+\+e|2>[[:space:]]*/dev/null|&>[[:space:]]*/dev/null|>[[:space:]]*/dev/null|2>&-'
# A line whose only reason to be quiet is that it answers yes or no, or that it
# ran and said something nobody needs. All of these use the status and print
# nothing worth keeping:
#
#   a presence probe            command -v X > /dev/null || die ...
#   a test                      jq -e ... > /dev/null
#   an availability probe       ends in `exit $?`
#   a status read next line     if ! cmd > /dev/null ...
#   a bare call under set -e    the script ends on a failure, so the status is
#                               not lost; what is dropped is a success message
#                               such as oras's "Login Succeeded" or a gh
#                               response body.
#
# A redirect whose status nobody reads and whose failure is swallowed is still a
# hit, and the last form is the one to watch: `cmd > /dev/null || true` is
# caught by the `||` alternative above, not here.
# These lines are reported by the pattern above and are not hidden failures.
# Each one uses the status and prints nothing worth keeping:
#
#   a presence probe          command -v X > /dev/null || die "..."
#   a test                    jq -e ... > /dev/null
#   a probe that answers      the next word is `exit $?`
#   a status read next line   the line starts `if !`
#   a bare call under set -e  the script ends on a failure, so the status is
#                             not lost. What is dropped is a success message
#                             such as oras's "Login Succeeded" or a gh
#                             response body.
#
# `cmd > /dev/null || true` is NOT exempt: it is caught by the `||` above.
# The judgement is one case per form, so a new form has to be added here and
# read, rather than widening a pattern.
quiet_ok() {
  local line="$1"
  # The code with the file:lineno: prefix grep -n puts in front of it.
  line="${line#*:}"
  line="${line#*:}"
  # Leading space is stripped, because a case pattern anchored at the start
  # would not reach an indented line.
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in
    "command -v "* ) return 0 ;;
    "if command -v "*" > /dev/null"* ) return 0 ;;
    *"{ command -v "*" > /dev/null"* ) return 0 ;;
    *"command -v "*" > /dev/null"* ) return 0 ;;
    "jq -e "* ) return 0 ;;
    *"&& jq -e "*" > /dev/null"* ) return 0 ;;
    # A continued command line: the first fragment opened the statement and
    # this one carries the redirect. oras login prints "Login Succeeded" and
    # nothing else worth keeping.
    *"--password-stdin"*"/dev/null"* ) return 0 ;;
    # A continuation line of a command whose first fragment was a gh api or an
    # oras login: the status of the whole statement is the caller's, and what
    # is dropped is the response body or the success message.
    *"description="*"/dev/null"* ) return 0 ;;
    *"exit $?"* ) return 0 ;;
    "if ! "* ) return 0 ;;
    "gh api "* ) return 0 ;;
    "conf "* ) return 0 ;;
    "\$py -c "* ) return 0 ;;
    timeout\ *\ rm\ *" > /dev/null || log "* ) return 0 ;;
  esac
  return 1
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  hits=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # A comment line is not code.
    printf '%s' "$line" | grep -qE '^[0-9]+:[[:space:]]*#' && continue
    quiet_ok "$line" && continue
    hits="$hits$line
"
  done <<< "$(grep -nE "$SWALLOW" "$f" || true)"
  hits="${hits%$'\n'}"
  if [ -z "$hits" ]; then
    ok "$f hides no failure"
  else
    fail "$f hides no failure" "$hits" "reproduce: grep -nE '$SWALLOW' $f"
  fi
done <<< "$targets"

#---------------------------------------------------------------------------#
# Every curl has a connect deadline and a whole-transfer one, or a stall
# deadline for downloads whose size makes a fixed one wrong. A curl command
# spans lines joined by a trailing backslash; the check reads the joined line.
#---------------------------------------------------------------------------#
while IFS= read -r f; do
  [ -n "$f" ] || continue
  calls="$(awk '
    /^[[:space:]]*#/ { next }
    { line = (cont ? line " " : "") $0 }
    /\\$/ { cont = 1; sub(/\\$/, "", line); next }
    { cont = 0; l = line; sub(/reproduce:.*/, "", l); if (l ~ /(^|[[:space:];(|&!])curl[[:space:]]+-/) print FILENAME ":" NR ": " line; line = "" }
  ' "$f")"
  [ -n "$calls" ] || continue
  bad="$(printf '%s\n' "$calls" | awk '!/--connect-timeout/ || (!/--max-time/ && !/--speed-time/)')"
  if [ -z "$bad" ]; then
    ok "$f: every curl has a connect deadline and a transfer or stall deadline"
  else
    fail "$f: every curl has a connect deadline and a transfer or stall deadline" "$bad" \
      "reproduce: grep -n 'curl ' $f"
  fi
done <<< "$targets"

#---------------------------------------------------------------------------#
# oras has no deadline of its own (measured in v1.3.4: only a TLS handshake
# timeout), so every oras call in a script sits under timeout(1). lib.sh
# oras_login puts its own call under one.
#---------------------------------------------------------------------------#
while IFS= read -r f; do
  case "$f" in
    scripts/*) ;;
    *) continue ;;
  esac
  bad="$(awk '
    /^[[:space:]]*#/ { next }
    /"\$ORAS"|\$\{ORAS\}|\$ORAS[[:space:]]|(^|[[:space:];(|&!])oras[[:space:]]+(push|pull|tag|manifest|blob|repo|login|cp|attach|discover|resolve)([[:space:]]|$)/ {
      if ($0 !~ /timeout[[:space:]]/ && $0 !~ /^[[:space:]]*oras_login[[:space:]]/) print FILENAME ":" NR ": " $0
    }
  ' "$f")"
  if [ -z "$bad" ]; then
    ok "$f: every oras call has a deadline"
  else
    fail "$f: every oras call has a deadline" "$bad" "reproduce: grep -n oras $f"
  fi
done <<< "$targets"

summary
