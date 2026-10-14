#!/usr/bin/env bash
#
# Every python file in the tree compiles, and every file under client/ and
# scripts/ is a script that some static test reads.
#
# The shell tests read only shell: shellcheck, the failure and pipeline rules.
# A shipped python script (scripts/status-render) is compiled here with
# python3 -I -m py_compile, the way it runs: isolated, standard library only.
# A shipped file whose first line names no known language would pass every
# static test unread, so it fails here instead.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

#---------------------------------------------------------------------------#
# Every shipped file is shell or python.
#---------------------------------------------------------------------------#
other="$(shipped_other)"
if [ -z "$other" ]; then
  ok "every file under client/ and scripts/ is a shell or a python script"
else
  while IFS= read -r f; do
    fail "$f is a shell or a python script" \
      "its first line is: $(LC_ALL=C sed -n 1p "$f" | tr -d '\000\r' | cut -c1-80)" \
      "no static test reads it; give it a #! line naming sh, bash or python3" \
      "reproduce: sed -n 1p $f"
  done <<< "$other"
fi

#---------------------------------------------------------------------------#
# Every python file compiles. -X pycache_prefix keeps the bytecode out of the
# tree: python3 -I ignores PYTHONPYCACHEPREFIX, and a __pycache__ under
# scripts/ would be a shipped file of no known kind.
#---------------------------------------------------------------------------#
files="$(
  shipped_python
  test_python
)"
if [ -z "$files" ]; then
  ok "there is no python in the tree, so there is nothing to compile"
elif need_tool python3 "python3 is on PATH, to compile the python in the tree"; then
  ok "python3 is on PATH: $(python3 -I -c 'import sys; print(sys.version.split()[0])')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    out="$(python3 -I -X pycache_prefix="$work/pycache" -m py_compile "$f" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "python3 -I -m py_compile $f"
    else
      fail "python3 -I -m py_compile $f" "$(printf '%s\n' "$out" | sed -n 1,20p)" "reproduce: python3 -I -m py_compile $f"
    fi
  done <<< "$files"
fi

summary
