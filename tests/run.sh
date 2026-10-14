#!/usr/bin/env bash
#
# Test entry point.
#
#   tests/run.sh [SUITE [FILE]]
#   tests/run.sh --list SUITE
#
#   SUITE  static       the tree: shellcheck, actionlint, py_compile, policy
#          unit         the wrapper and the scripts, no network (the default)
#          integration  a local registry, oras and pacman in a container
#          worker       the Cloudflare Worker under node --test
#          all          the four suites, in that order
#   FILE   one file of SUITE, by name (20-client.sh, or 20-client) or by path
#          (tests/integration/20-client.sh). SUITE all takes no FILE.
#   --list prints the name of each file SUITE runs, one per line. CI makes its
#          integration matrix from it, so a new file gets a job with no edit.
#
# The files of a suite are tests/SUITE/*.sh, found when the run starts.
# ⚠ A file named live.sh talks to a deployed service. It runs only when
# <SUITE>_LIVE=1 (WORKER_LIVE=1 for tests/worker/live.sh), also when named.
#
# static needs shellcheck, actionlint and jq on PATH (scripts/install-test-tools),
# and python3 when there is python to compile. integration needs docker or
# podman (CONTAINER_RUNTIME picks one) and network to pull the pinned images.
# worker needs node 22 or newer.
#
# Exit status: 0 every file passed, 1 a file failed or no file ran, 2 usage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

SUITES="static unit integration worker"

usage() {
  echo "usage: tests/run.sh [static|unit|integration|worker|all [FILE]]" >&2
  echo "       tests/run.sh --list static|unit|integration|worker" >&2
  exit 2
}

list=0
if [ "${1:-}" = --list ]; then
  list=1
  shift
  [ "$#" -eq 1 ] || usage
fi
[ "$#" -le 2 ] || usage
suite="${1:-unit}"
file="${2:-}"

case "$suite" in
  all)
    [ "$list" -eq 0 ] && [ -z "$file" ] || usage
    suites="$SUITES"
    ;;
  *)
    case " $SUITES " in
      *" $suite "*) suites="$suite" ;;
      *) usage ;;
    esac
    ;;
esac

# gated SUITE NAME: 0 when NAME is a live test whose switch is off.
gated() {
  local switch
  [ "$2" = live.sh ] || return 1
  switch="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_LIVE"
  [ "${!switch:-0}" != 1 ]
}

# files_of SUITE: the test files of SUITE, by path, sorted.
files_of() {
  local t
  for t in "$REPO_ROOT/tests/$1"/*.sh; do
    [ -e "$t" ] || continue
    printf '%s\n' "$t"
  done
}

if [ -n "$file" ]; then
  name="$(basename "$file")"
  case "$name" in
    *.sh) ;;
    *) name="$name.sh" ;;
  esac
  if [ ! -f "$REPO_ROOT/tests/$suite/$name" ]; then
    echo "tests/run.sh: no file $name in tests/$suite" >&2
    echo "  the files there:" >&2
    files_of "$suite" | sed "s|^$REPO_ROOT/|    |" >&2
    exit 2
  fi
fi

if [ "$list" -eq 1 ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! gated "$suite" "$(basename "$t")"; then
      basename "$t"
    fi
  done <<< "$(files_of "$suite")"
  exit 0
fi

failed_files=0
total_files=0
failed_names=()

for s in $suites; do
  # A glob, not a read loop, so each test keeps the caller's stdin.
  for t in "$REPO_ROOT/tests/$s"/*.sh; do
    [ -e "$t" ] || continue
    n="$(basename "$t")"
    if [ -n "$file" ] && [ "$n" != "$name" ]; then
      continue
    fi
    if gated "$s" "$n"; then
      s_upper="$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')"
      printf '\n# ===== %s/%s: not run, it needs %s_LIVE=1 =====\n' "$s" "$n" "$s_upper"
      continue
    fi
    total_files=$((total_files + 1))
    printf '\n# ===== %s/%s =====\n' "$s" "$n"
    start="$SECONDS"
    if ! bash "$t"; then
      failed_files=$((failed_files + 1))
      failed_names+=("$s/$n")
    fi
    printf '# ----- %s/%s took %d s\n' "$s" "$n" "$((SECONDS - start))"
  done
done

printf '\n# ===== summary =====\n'
if [ "$total_files" -eq 0 ]; then
  printf '# no test file ran for suite: %s%s\n' "$suites" "${file:+, file $file}"
  exit 1
fi
printf '# test files: %d, failed: %d\n' "$total_files" "$failed_files"
for n in "${failed_names[@]}"; do
  printf '# failed: %s, reproduce: tests/run.sh %s %s\n' "$n" "${n%%/*}" "${n#*/}"
done
[ "$failed_files" -eq 0 ]
