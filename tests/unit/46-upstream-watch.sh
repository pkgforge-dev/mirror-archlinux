#!/usr/bin/env bash
#
# scripts/upstream-watch starts a sync of a target only when a HEAD of its
# <repo>.db answers other headers than the last tick kept, and keeps the old
# state of a change that started no sync.
#
# Upstream is answered by tests/fixtures/status/fake-curl (F.code and
# F.headers), and GitHub by a stub gh that records every call, one argument in
# each <>. scripts/dispatch-sync runs as it is. The test needs no network and
# no token.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

need_tool jq "upstream-watch starts syncs through dispatch-sync, which reads the runs list with jq" || { summary; exit; }

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
net="$work/net"
mkdir -p "$bin" "$net" "$work/targets"
cp "$REPO_ROOT/tests/fixtures/status/fake-curl" "$bin/curl"
cat > "$bin/gh" << 'EOF'
#!/usr/bin/env bash
{
  printf 'gh'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$STUB_DIR/calls.log"
case "$1 $2" in
  "api repos/"*/runs\?*) cat "$STUB_DIR/runs.json" ;;
  "api repos/"*) printf '{"state":"active"}\n' ;;
  "workflow run")
    [ "${STUB_RUN_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
  *)
    echo "stub gh: no answer for: gh $*" >&2
    exit 9
    ;;
esac
EOF
chmod 0755 "$bin/curl" "$bin/gh"
echo '{"workflow_runs":[]}' > "$work/runs.json"

# conf NAME LINE...: a target file NAME.conf with an arch and repo from NAME
conf() {
  local name="$1"
  shift
  {
    printf 'arch = %s\nrepo = %s\n' "${name%%-*}" "${name#*-}"
    printf '%s\n' "$@"
  } > "$work/targets/$name.conf"
}
# shellcheck disable=SC2016 # the target file's own placeholders
{
  conf aarch64-core 'db_server = https://arm.test/$arch/$repo'
  conf loong64-core 'db_server = https://lc.test/loongarch/$repo/os/$arch' 'db_server = https://down.test/loongarch/$repo/os/$arch'
  conf powerpc-base 'db_server = https://ppc.test/$repo/$arch'
  conf riscv64-core 'enabled = no' 'db_server = https://rv.test/repo/$repo'
  conf x86_64-core 'db_server = https://one.test/$repo/os/$arch' 'db_server = https://two.test/$repo/os/$arch'
  conf x86_64-extra 'db_server = https://one.test/$repo/os/$arch' 'db_server = https://down.test/$repo/os/$arch'
}

# head_answer HOST/PATH ETAG LAST_MODIFIED CONTENT_LENGTH: a 200 with these
# three headers
head_answer() {
  mkdir -p "$net/$(dirname "$1")"
  printf '200\n' > "$net/$1.code"
  printf 'ETag: %s\nLast-Modified: %s\nContent-Length: %s\n' "$2" "$3" "$4" > "$net/$1.headers"
}
LM='Thu, 15 Oct 2026 10:00:00 GMT'
LM2='Thu, 15 Oct 2026 11:00:00 GMT'
CORE1=https://one.test/core/os/x86_64/core.db
CORE2=https://two.test/core/os/x86_64/core.db
EXTRA=https://one.test/extra/os/x86_64/extra.db
ARM=https://arm.test/aarch64/core/core.db
head_answer one.test/core/os/x86_64/core.db '"c1"' "$LM" 1000
head_answer two.test/core/os/x86_64/core.db '"c1"' "$LM" 1000
head_answer one.test/extra/os/x86_64/extra.db '"e1"' "$LM" 5000
# arm_answer LAST_MODIFIED CONTENT_LENGTH: aarch64-core's db_server answers a
# 302 with an ETag of its own, and the answer it leads to has no ETag. The
# fields of that last answer count, and only they.
arm_answer() {
  mkdir -p "$net/arm.test/aarch64/core" "$net/arm2.test/aarch64/core"
  printf '302\n' > "$net/arm.test/aarch64/core/core.db.code"
  printf 'https://arm2.test/aarch64/core/core.db\n' > "$net/arm.test/aarch64/core/core.db.location"
  printf 'ETag: "redirect-1"\n' > "$net/arm.test/aarch64/core/core.db.headers"
  printf '200\n' > "$net/arm2.test/aarch64/core/core.db.code"
  printf 'Last-Modified: %s\nContent-Length: %s\n' "$1" "$2" > "$net/arm2.test/aarch64/core/core.db.headers"
}
arm_answer "$LM" 2000
# loong64-core: one db_server answers 503, the other does not resolve
mkdir -p "$net/lc.test/loongarch/core/os/loong64"
printf '503\n' > "$net/lc.test/loongarch/core/os/loong64/core.db.code"
# Hosts that answer, and must not be asked
head_answer ppc.test/base/powerpc/base.db '"p1"' "$LM" 3000
head_answer rv.test/repo/core/core.db '"r1"' "$LM" 3000

state="$work/state.tsv"
clock=1760000000
# tick: one run of upstream-watch on $state, in place, at $clock. Sets rc;
# the log is $work/log, the gh calls $work/calls.log, the URLs read
# $work/curl.log.
tick() {
  rc=0
  : > "$work/calls.log"
  : > "$work/curl.log"
  PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" FAKE_CURL_LOG="$work/curl.log" STUB_DIR="$work" \
    TARGETS_DIR="${TICK_TARGETS:-$work/targets}" MIRROR_NOW="$clock" GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux \
    bash "$REPO_ROOT/scripts/upstream-watch" "$state" "$state" "$work/out" > "$work/log" 2>&1 || rc=$?
}
# started: the targets input of each gh workflow run, or none
started() {
  awk '/^gh <workflow> <run> / { sub(/.*<targets=/, ""); sub(/>$/, ""); print; n++ } END { if (!n) print "none" }' "$work/calls.log"
}
# uline URL: the ETag, Last-Modified and Content-Length of URL in the state,
# joined by |, or none
uline() {
  awk -F '\t' -v u="$1" '$1 == "u" && $2 == u { v = $3 "|" $4 "|" $5 } END { print (v == "" ? "none" : v) }' "$state"
}
# tline TARGET: the epoch of TARGET's last sync in the state, or none
tline() {
  awk -F '\t' -v t="$1" '$1 == "t" && $2 == t { v = $3 } END { print (v == "" ? "none" : v) }' "$state"
}
# changed: the lines of OUT/changed.txt, space separated
changed() {
  tr '\n' ' ' < "$work/out/changed.txt" | sed 's/ $//'
}
RW="PATH=<fake-curl, stub gh>:\$PATH FAKE_CURL_ROOT=<net> TARGETS_DIR=<targets> MIRROR_NOW=\$clock scripts/upstream-watch STATE STATE OUT"

#---------------------------------------------------------------------------#
# The first tick has no state: every URL is new, and no sync starts
#---------------------------------------------------------------------------#
rm -f "$state"
tick
check "first tick: exit 0, no sync, no changed target" "0 none " "$rc $(started) $(changed)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "first tick: a u line for each URL that answered, and no t line" "4 0" \
  "$(awk -F '\t' '$1 == "u" { u++ } $1 == "t" { t++ } END { print u + 0, t + 0 }' "$state")" "$RW; cat STATE"
check "first tick: the u line holds ETag, Last-Modified and Content-Length" "\"c1\"|$LM|1000" "$(uline "$CORE1")" "$RW; cat STATE"
check "first tick: the answer after the 302 counts, not the 302's own ETag" "|$LM|2000" "$(uline "$ARM")" "$RW; cat STATE"
check "first tick: one HEAD per URL of 7, none to a host that failed before; no powerpc or disabled target is asked" \
  "6 0" "$(awk 'END { print NR + 0 }' "$work/curl.log") $(awk '/ppc\.test|rv\.test/ { n++ } END { print n + 0 }' "$work/curl.log")" \
  "$RW; cat curl.log"
if grep -q 'loong64-core: no db_server answered' "$work/log"; then
  ok "first tick: a target with no db_server that answered is named"
else
  fail "first tick: a target with no db_server that answered is named" "$(cat "$work/log")" "$RW"
fi
check "first tick: OUT/urls.tsv names the 503, the host that does not resolve, and its URL not asked again" \
  "no answer: HTTP 503|no answer: curl 6|no answer: not asked: its host failed earlier in this tick" \
  "$(awk -F '\t' '/lc\.test|down\.test/ { printf "%s%s", s, $2; s = "|" }' "$work/out/urls.tsv")" "$RW; cat OUT/urls.tsv"

#---------------------------------------------------------------------------#
# Nothing changed
#---------------------------------------------------------------------------#
cp "$state" "$work/state.before"
clock=$((clock + 900))
tick
check "no change: exit 0, no sync" "0 none" "$rc $(started)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
if same_bytes "$work/state.before" "$state"; then
  ok "no change: the state is the same"
else
  fail "no change: the state is the same" "before: $(tr '\n' ' ' < "$work/state.before")" "after:  $(tr '\n' ' ' < "$state")" "$RW"
fi

#---------------------------------------------------------------------------#
# A change starts a sync of its target, and the state takes it
#---------------------------------------------------------------------------#
head_answer one.test/core/os/x86_64/core.db '"c2"' "$LM2" 1100
clock=$((clock + 900))
tick
check "a new ETag on one db_server: a sync of x86_64-core starts" "0 x86_64-core x86_64-core" \
  "$rc $(started) $(changed)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "the sync is one run on main, with the target as its targets input" \
  "gh <workflow> <run> <sync.yml> <--ref> <main> <--repo> <pkgforge-dev/mirror-archlinux> <-f> <targets=x86_64-core>" \
  "$(grep '^gh <workflow> <run> ' "$work/calls.log")" "$RW; cat calls.log"
check "after the start, the URL keeps the new answer and the target the time" "\"c2\"|$LM2|1100 $clock" \
  "$(uline "$CORE1") $(tline x86_64-core)" "$RW; cat STATE"
t_start="$clock"

#---------------------------------------------------------------------------#
# SYNC_MIN_INTERVAL: a change soon after a start waits, and is not lost
#---------------------------------------------------------------------------#
head_answer one.test/core/os/x86_64/core.db '"c2"' "$LM2" 1200
clock=$((t_start + 900))
tick
check "a change 15 min after its last start: no sync" "0 none " "$rc $(started) $(changed)" \
  "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "a change that waits: the URL keeps its old answer, the target its old time" "\"c2\"|$LM2|1100 $t_start" \
  "$(uline "$CORE1") $(tline x86_64-core)" "$RW; cat STATE"
if grep -q 'under SYNC_MIN_INTERVAL (60 min), so it waits' "$work/log"; then
  ok "a change that waits: the log says why"
else
  fail "a change that waits: the log says why" "$(cat "$work/log")" "$RW"
fi
clock=$((t_start + 3600))
tick
check "the same answer 60 min after the last start: the change is seen again, and a sync starts" "0 x86_64-core" \
  "$rc $(started)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "then the URL keeps the new answer" "\"c2\"|$LM2|1200 $clock" "$(uline "$CORE1") $(tline x86_64-core)" "$RW; cat STATE"

#---------------------------------------------------------------------------#
# Two targets in one tick: one run; a header of the 302 alone changes nothing
#---------------------------------------------------------------------------#
head_answer one.test/extra/os/x86_64/extra.db '"e2"' "$LM2" 5100
arm_answer "$LM2" 2100
clock=$((clock + 900))
tick
check "two targets change in one tick: one run for both" "0 aarch64-core x86_64-extra" "$rc $(started)" \
  "$RW; cat calls.log"
check "two targets change in one tick: each URL keeps its new answer" "\"e2\"|$LM2|5100 |$LM2|2100" \
  "$(uline "$EXTRA") $(uline "$ARM")" "$RW; cat STATE"
printf 'ETag: "redirect-2"\n' > "$net/arm.test/aarch64/core/core.db.headers"
clock=$((clock + 7200))
tick
check "a new ETag on the 302 alone: no sync" "0 none" "$rc $(started)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"

#---------------------------------------------------------------------------#
# A URL with no answer keeps its line, and changes nothing
#---------------------------------------------------------------------------#
before="$(uline "$CORE1")"
printf '503\n' > "$net/one.test/core/os/x86_64/core.db.code"
clock=$((clock + 900))
tick
check "a db_server that answers 503: no sync, and its URL keeps its line" "0 none $before" \
  "$rc $(started) $(uline "$CORE1")" "$RW; cat STATE"
printf '200\n' > "$net/one.test/core/os/x86_64/core.db.code"

#---------------------------------------------------------------------------#
# A start that fails, a run that waits, and a dry run keep the old line
#---------------------------------------------------------------------------#
head_answer two.test/core/os/x86_64/core.db '"c3"' "$LM2" 1300
before="$(uline "$CORE2") $(tline x86_64-core)"
clock=$((clock + 900))
STUB_RUN_FAIL=1 tick
check "GitHub refuses the start: exit 1" "1 x86_64-core" "$rc $(started)" "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "GitHub refuses the start: the URL keeps its old line, the target its old time" "$before" \
  "$(uline "$CORE2") $(tline x86_64-core)" "$RW; cat STATE"

printf '{"workflow_runs":[{"status":"pending","event":"schedule","display_title":"Sync all targets"}]}\n' > "$work/runs.json"
clock=$((clock + 900))
tick
check "a run of sync.yml waits: exit 0, no start, the change is named" "0 none x86_64-core" "$rc $(started) $(changed)" \
  "$RW; $(tail -n 3 "$work/log" | tr '\n' ' ')"
check "a run of sync.yml waits: the URL keeps its old line" "$before" "$(uline "$CORE2") $(tline x86_64-core)" "$RW; cat STATE"
echo '{"workflow_runs":[]}' > "$work/runs.json"

clock=$((clock + 900))
WATCH_DRY_RUN=1 tick
check "a dry run: exit 0, no gh call, the change is named" "0 0 x86_64-core" \
  "$rc $(awk 'END { print NR + 0 }' "$work/calls.log") $(changed)" "WATCH_DRY_RUN=1 $RW"
check "a dry run: the URL keeps its old line" "$before" "$(uline "$CORE2") $(tline x86_64-core)" "WATCH_DRY_RUN=1 $RW; cat STATE"

clock=$((clock + 900))
tick
check "the next tick that may start: the change is seen again, and the sync starts" "0 x86_64-core \"c3\"|$LM2|1300 $clock" \
  "$rc $(started) $(uline "$CORE2") $(tline x86_64-core)" "$RW; cat STATE"

#---------------------------------------------------------------------------#
# A line that is not a state line is left out, with a warning
#---------------------------------------------------------------------------#
printf 'u\tnot a url\tx\ty\tz\nsomething else\n' >> "$state"
clock=$((clock + 900))
tick
check "two lines that are not state lines: exit 0, no sync, and neither is kept" "0 none 0" \
  "$rc $(started) $(awk '/not a url|something else/ { n++ } END { print n + 0 }' "$state")" "$RW; cat STATE"
if grep -q '2 line(s) of .* are not state lines' "$work/log"; then
  ok "two lines that are not state lines: the warning counts them"
else
  fail "two lines that are not state lines: the warning counts them" "$(cat "$work/log")" "$RW"
fi

#---------------------------------------------------------------------------#
# WATCH_BUDGET: a URL that is not read in time keeps its line
#---------------------------------------------------------------------------#
mkdir -p "$work/slow/bin" "$work/slow/targets"
cat > "$work/slow/bin/curl" << EOF
#!/usr/bin/env bash
case "\$*" in
  *slow.test*) sleep 2 ;;
esac
exec "$bin/curl" "\$@"
EOF
chmod 0755 "$work/slow/bin/curl"
# shellcheck disable=SC2016 # the target file's own placeholders
printf 'arch = x86_64\nrepo = core\ndb_server = https://slow.test/$repo/os/$arch\ndb_server = https://one.test/$repo/os/$arch\n' \
  > "$work/slow/targets/x86_64-core.conf"
head_answer slow.test/core/os/x86_64/core.db '"c3"' "$LM2" 1300
before="$(uline "$CORE1")"
head_answer one.test/core/os/x86_64/core.db '"c9"' "$LM2" 1900
clock=$((clock + 7200))
rc=0
: > "$work/calls.log"
PATH="$work/slow/bin:$bin:$PATH" FAKE_CURL_ROOT="$net" STUB_DIR="$work" TARGETS_DIR="$work/slow/targets" \
  MIRROR_NOW="$clock" GITHUB_REPOSITORY=pkgforge-dev/mirror-archlinux WATCH_BUDGET=1 \
  bash "$REPO_ROOT/scripts/upstream-watch" "$state" "$state" "$work/out" > "$work/log" 2>&1 || rc=$?
check "WATCH_BUDGET=1 and a db_server that takes 2 s: the next URL is not read, no sync starts" \
  "0 none no answer: not read: WATCH_BUDGET (1s) is spent" \
  "$rc $(started) $(awk -F '\t' -v u="$CORE1" '$1 == u { print $2 }' "$work/out/urls.tsv")" \
  "WATCH_BUDGET=1 $RW, a curl that sleeps 2 s for slow.test"
check "WATCH_BUDGET: the URL not read keeps its line" "$before" "$(uline "$CORE1")" "WATCH_BUDGET=1 $RW; cat STATE"
if grep -q 'WATCH_BUDGET (1s) was spent' "$work/log"; then
  ok "WATCH_BUDGET: the warning names the budget"
else
  fail "WATCH_BUDGET: the warning names the budget" "$(cat "$work/log")" "WATCH_BUDGET=1 $RW"
fi

summary
