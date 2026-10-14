# Shared harness for the test suites. Sourced, never executed.
#
# Output is TAP. Each test file is one plan. A failing assertion prints the
# measurement and the command that reproduces it, so a CI log is enough to act
# on without re-deriving anything.
#
# A test that needs a tool which may be absent calls need_tool. It is skipped
# where the tool is absent, with a TAP "# SKIP" line, unless
# TESTS_REQUIRE_TOOLS names the tool: then it fails. CI sets
# TESTS_REQUIRE_TOOLS in each job that has the tool, so a skip never hides
# there.

if [ -z "${REPO_ROOT:-}" ]; then
  echo "harness: REPO_ROOT is not set" >&2
  exit 2
fi

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0

ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

not_ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
}

# skip DESC REASON
skip() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf 'ok %d - %s # SKIP %s\n' "$TESTS_RUN" "$1" "$2"
}

diag() {
  printf '#   %s\n' "$1"
}

# fail DESC [DIAG ...]
fail() {
  local desc="$1"
  shift
  not_ok "$desc"
  while [ "$#" -gt 0 ]; do
    diag "$1"
    shift
  done
}

# check DESC EXPECTED GOT REPRODUCE
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1" "expected: $2" "got:      $3" "reproduce: $4"
  fi
}

# need_tool NAME DESC: 0 when NAME is on PATH. Otherwise the test DESC fails
# when TESTS_REQUIRE_TOOLS names NAME, or is skipped when it does not, and
# the return is 1.
need_tool() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  case " ${TESTS_REQUIRE_TOOLS:-} " in
    *" $1 "*)
      fail "$2" "$1 is not on PATH, and TESTS_REQUIRE_TOOLS names it" "reproduce: command -v $1"
      ;;
    *)
      skip "$2" "$1 is not on PATH"
      ;;
  esac
  return 1
}

summary() {
  printf '1..%d\n' "$TESTS_RUN"
  if [ "$TESTS_RUN" -eq 0 ]; then
    printf '# no assertions ran, which is itself a failure\n'
    return 1
  fi
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf '# failed %d of %d\n' "$TESTS_FAILED" "$TESTS_RUN"
    return 1
  fi
  if [ "$TESTS_SKIPPED" -gt 0 ]; then
    printf '# passed %d of %d, %d of them skipped\n' "$TESTS_RUN" "$TESTS_RUN" "$TESTS_SKIPPED"
  else
    printf '# passed %d of %d\n' "$TESTS_RUN" "$TESTS_RUN"
  fi
  return 0
}

# work_dir -> a scratch directory; the caller removes it in its EXIT trap
work_dir() {
  mktemp -d
}

#---------------------------------------------------------------------------#
# grep_matches PATTERN FILE
#
# Prints matching lines with line numbers. No match is a normal result and
# exits 0 with no output. A real grep failure exits 2 and is not swallowed,
# which is the difference between "nothing matched" and "the check did not run".
#---------------------------------------------------------------------------#
grep_matches() {
  local out rc=0
  out="$(grep -nE "$1" "$2")" || rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$out"
      return 0
      ;;
    1) return 0 ;;
    *)
      echo "harness: grep exited $rc on $2 for pattern: $1" >&2
      return 2
      ;;
  esac
}

#---------------------------------------------------------------------------#
# Container runtime, for the integration suite.
#---------------------------------------------------------------------------#
# shellcheck disable=SC2034 # read by the integration suite
RUNTIME=""

runtime_detect() {
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    RUNTIME="$CONTAINER_RUNTIME"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
  else
    echo "harness: no container runtime found, set CONTAINER_RUNTIME" >&2
    return 1
  fi
  export RUNTIME
}

#---------------------------------------------------------------------------#
# Which files are scripts, and in which language. The scripts carry no
# extension, so a find by suffix would miss them; the first line decides.
#---------------------------------------------------------------------------#

# script_kind FILE -> sh, bash, python or other.
#   A #! line names the interpreter, through env(1) or not.
#   With no #! line, a .sh file is bash (sourced, like scripts/lib.sh) and a
#   .py file is python (imported). Anything else is other.
script_kind() {
  local file="$1" first="" interp="" w words=()
  first="$(LC_ALL=C sed -n '1p' "$file" | tr -d '\000\r')"
  case "$first" in
    '#!'*)
      read -r -a words <<< "${first#'#!'}"
      interp="${words[0]:-}"
      interp="${interp##*/}"
      if [ "$interp" = env ]; then
        interp=""
        for w in "${words[@]:1}"; do
          case "$w" in
            -* | *=*) ;;
            *)
              interp="${w##*/}"
              break
              ;;
          esac
        done
      fi
      case "$interp" in
        sh | dash | ash | ksh | mksh | posh) echo sh ;;
        bash) echo bash ;;
        python | python3 | python3.*) echo python ;;
        *) echo other ;;
      esac
      ;;
    *)
      case "$file" in
        *.sh) echo bash ;;
        *.py) echo python ;;
        *) echo other ;;
      esac
      ;;
  esac
}

# script_has_shebang FILE: 0 when the first line starts with #!.
script_has_shebang() {
  [ "$(LC_ALL=C head -c 2 "$1")" = '#!' ]
}

# Every file the repository ships under client/ and scripts/, by path
# relative to REPO_ROOT. A __pycache__ directory is never shipped.
shipped_files() {
  (
    cd "$REPO_ROOT" || exit 2
    find client scripts -type f ! -path '*/__pycache__/*' | LC_ALL=C sort
  )
}

# _files_of_kind KIND... reads paths on stdin, prints those of a KIND.
_files_of_kind() {
  local f k want
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    k="$(script_kind "$REPO_ROOT/$f")"
    for want in "$@"; do
      if [ "$k" = "$want" ]; then
        printf '%s\n' "$f"
        break
      fi
    done
  done
}

# The shipped shell scripts: sh or bash by their first line.
shipped_scripts() {
  shipped_files | _files_of_kind sh bash
}

# The shipped python scripts, linted by tests/static/70-python.sh.
shipped_python() {
  shipped_files | _files_of_kind python
}

# Shipped files that are neither, which no static test reads.
shipped_other() {
  shipped_files | _files_of_kind other
}

# Every file under tests/, by path relative to REPO_ROOT.
_test_files() {
  (
    cd "$REPO_ROOT" || exit 2
    find tests -type f ! -path '*/__pycache__/*' ! -path '*/node_modules/*' | LC_ALL=C sort
  )
}

# The shell scripts of the test suites: run.sh, this harness and each
# suite's files, by their first line. ⚠ Not yet tests/fixtures: its scripts
# (build-repo) do not pass shellcheck today.
test_scripts() {
  _test_files | grep -v '^tests/fixtures/' | _files_of_kind sh bash
}

# The python scripts under tests/, fixtures included, by their first line.
test_python() {
  _test_files | _files_of_kind python
}
