#!/usr/bin/env bash
#
# The run store: one pacman run keeps its files beside OUTPUT under its own
# key, uses only files it owns, and leaves nothing behind.
#
# The parent process is faked with PACMAN_OCI_TEST_PROC: a directory laid out
# like /proc for this shell's pid, with comm, stat and cmdline. The wrapper is
# always run from this shell itself, never from a subshell, so its parent is
# this shell. Port 9 on the loopback refuses at once, so nothing here needs a
# network.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

W="$REPO_ROOT/client/pacman-oci"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"
fake="$work/proc"
mkdir -p "$fake/$$"
: > "$fake/pacman-oci-test-proc"
export PACMAN_OCI_TEST_PROC="$fake"
U="oci+http://127.0.0.1:9/ns/mirror/x86_64/core"

# parent START [COMM] [COMM IN STAT]: this shell, as the process COMM
# (default pacman) that started at START
parent() {
  printf '%s\n' "${2:-pacman}" > "$fake/$$/comm"
  printf '%s (%s) S 1 1 1 0 -1 4194560 837 0 0 0 0 0 0 0 20 0 1 0 %s 62676992 3236\n' \
    "$$" "${3:-${2:-pacman}}" "$1" > "$fake/$$/stat"
}
# argv ARG...: the parent's argument list, NUL separated as in /proc
argv() {
  printf '%s\0' "$@" > "$fake/$$/cmdline"
}
# call OUTPUT URL: the wrapper as pacman calls it; its exit code in $rc, its
# debug output in $work/err
call() {
  rc=0
  PACMAN_OCI_DEBUG=1 "$W" "$1" "$2" > /dev/null 2> "$work/err" || rc=$?
}
gets() {
  awk '/^pacman-oci: GET / { n++ } END { print n + 0 }' "$work/err"
}
# entries DIR: the names of the run store files in DIR, sorted, on one line
entries() {
  find "$1" -maxdepth 1 -name '.pacman-oci.*' | sed 's|.*/||' | sort | tr '\n' ' '
}

# A parent that prints nothing in print mode, so no prefetch has work.
cat > "$work/pacman" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$work/pacman"
ln -s "$work/pacman" "$fake/$$/exe"
argv pacman -S foo

#---------------------------------------------------------------------------#
# The run key is the parent's pid and field 22 of its stat, counted after the
# last ")": a comm may hold ") " itself.
#---------------------------------------------------------------------------#
mkdir -p "$work/key"
parent 777 pacman 'pa) (cm) an'
call "$work/key/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst"
check "the key is the pid and the start time after the last )" ".pacman-oci.$$-777.,down.127.0.0.1:9 .pacman-oci.$$-777.,open .pacman-oci.$$-777.,prefetch .pacman-oci.$$-777.,reaper " \
  "$(entries "$work/key")" "ls -a DIR after a call under a parent named pacman"

mkdir -p "$work/notpacman"
parent 778 bash
call "$work/notpacman/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst"
check "a parent that is not pacman: no store" "" "$(entries "$work/notpacman")" "ls -a DIR"

mkdir -p "$work/short"
parent 779
printf '%s (pacman) S 1 1\n' "$$" > "$fake/$$/stat"
call "$work/short/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst"
check "a stat line with no field 22: no store" "" "$(entries "$work/short")" "ls -a DIR"

mkdir -p "$work/nomark"
parent 779
rm "$fake/pacman-oci-test-proc"
call "$work/nomark/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst"
check "the test hook is ignored without its marker file" "" "$(entries "$work/nomark")" "ls -a DIR"
: > "$fake/pacman-oci-test-proc"

#---------------------------------------------------------------------------#
# A ready entry becomes OUTPUT with no request; anything else is never served.
#---------------------------------------------------------------------------#
parent 800
K="$$-800"
d="$work/ready"
mkdir -p "$d"
printf 'package bytes\n' > "$d/.pacman-oci.$K.ready-1-1-any.pkg.tar.zst"
printf 'stale part\n' > "$d/ready-1-1-any.pkg.tar.zst.part"
call "$d/ready-1-1-any.pkg.tar.zst.part" "$U/ready-1-1-any.pkg.tar.zst"
check "a ready package is OUTPUT, with no request" "0:package bytes:0" \
  "$rc:$(cat "$d/ready-1-1-any.pkg.tar.zst.part"):$(gets)" "client/pacman-oci DIR/ready...part URL"
check "the entry is moved, not copied" "" "$(find "$d" -name ".pacman-oci.$K.ready*")" "ls -a DIR"

printf 'served through http\n' > "$d/.pacman-oci.$K.plain-1-1-any.pkg.tar.zst"
call "$d/plain-1-1-any.pkg.tar.zst.part" "http://127.0.0.1:9/core/os/x86_64/plain-1-1-any.pkg.tar.zst"
check "a ready package is OUTPUT whichever Server pacman asks" "0:served through http" \
  "$rc:$(cat "$d/plain-1-1-any.pkg.tar.zst.part")" "client/pacman-oci DIR/plain...part http://..."

printf 'database bytes\n' > "$d/.pacman-oci.$K.core.db"
call "$d/core.db.part" "http://127.0.0.1:9/core/os/x86_64/core.db"
check "a ready database is never OUTPUT for a plain Server" 1 "$rc" "client/pacman-oci DIR/core.db.part http://..."
call "$d/core.db.part" "$U/core.db"
check "a ready database is OUTPUT for an oci:// Server" "0:database bytes" \
  "$rc:$(cat "$d/core.db.part")" "client/pacman-oci DIR/core.db.part oci+http://..."

printf 'planted\n' > "$work/target"
ln -s "$work/target" "$d/.pacman-oci.$K.link-1-1-any.pkg.tar.zst"
call "$d/link-1-1-any.pkg.tar.zst.part" "$U/link-1-1-any.pkg.tar.zst"
check "a symbolic link is never served" 1 "$rc" "ln -s ... DIR/.pacman-oci.KEY.link...; client/pacman-oci"
check "the file a link points to is left as it was" planted "$(cat "$work/target")" "cat target"

#---------------------------------------------------------------------------#
# Markers: a .sig the database manifest does not have misses with no request,
# and a host that failed is skipped for the rest of the run, never for a .sig.
# A .sig that fails marks no host.
#---------------------------------------------------------------------------#
parent 810
K="$$-810"
d="$work/marks"
mkdir -p "$d"
: > "$d/.pacman-oci.$K.,open"
: > "$d/.pacman-oci.$K.,absent.core.db.sig"
call "$d/core.db.sig.part" "$U/core.db.sig"
check "an absent database signature misses with no request" "1:0" "$rc:$(gets)" "client/pacman-oci DIR/core.db.sig.part URL"

call "$d/one-1-1-any.pkg.tar.zst.part" "$U/one-1-1-any.pkg.tar.zst"
check "a host that does not answer misses" 1 "$rc" "client/pacman-oci DIR/one...part oci+http://127.0.0.1:9/..."
check "and is marked down for this run" 1 "$(find "$d" -name ".pacman-oci.$K.,down.127.0.0.1:9" | wc -l | tr -d ' ')" "ls -a DIR"
call "$d/two-1-1-any.pkg.tar.zst.part" "$U/two-1-1-any.pkg.tar.zst"
check "the next package from that host misses with no request" "1:0" "$rc:$(gets)" "client/pacman-oci DIR/two...part URL"
call "$d/two-1-1-any.pkg.tar.zst.sig.part" "$U/two-1-1-any.pkg.tar.zst.sig"
check "a .sig is still asked of that host" "1:1" "$rc:$(gets)" "client/pacman-oci DIR/two...sig.part URL"

# A signature that gets no answer marks no host down. pacman ignores a failed
# optional signature, then asks the same host for the next file.
start=811
while IFS='|' read -r label sig next; do
  start=$((start + 1))
  parent "$start"
  d="$work/sig.$start"
  mkdir -p "$d"
  call "$d/${sig##*/}.part" "$sig"
  marks="$rc:$(gets):$(find "$d" -name ".pacman-oci.$$-$start.,down.*" | wc -l | tr -d ' ')"
  call "$d/${next##*/}.part" "$next"
  check "$label: no host is marked down, so the next file is still asked for" "1:1:0 1:1" \
    "$marks $rc:$(gets)" \
    "client/pacman-oci DIR/SIG.part '$sig'; ls -a DIR; client/pacman-oci DIR/NEXT.part '$next'"
done << EOF
a database signature|$U/core.db.sig|$U/two-1-1-any.pkg.tar.zst
a package signature|$U/one-1-1-any.pkg.tar.zst.sig|$U/two-1-1-any.pkg.tar.zst
a database signature from a plain Server|http://127.0.0.1:9/core/os/x86_64/core.db.sig|http://127.0.0.1:9/core/os/x86_64/core.db
EOF

#---------------------------------------------------------------------------#
# The sweep: entries of runs that are gone go; those of live runs, links, and
# names that are no key stay. A run with a fresh ,open is live.
#---------------------------------------------------------------------------#
parent 820
d="$work/sweep"
mkdir -p "$d" "$fake/4242"
printf '4242 (pacman) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5 1 1\n' > "$fake/4242/stat"
: > "$d/.pacman-oci.999999999-1.gone-1-1-any.pkg.tar.zst"
: > "$d/.pacman-oci.4242-5.live-1-1-any.pkg.tar.zst"
: > "$d/.pacman-oci.4242-6.reused-1-1-any.pkg.tar.zst"
: > "$d/.pacman-oci.notakey"
ln -s "$work/target" "$d/.pacman-oci.999999999-1.link"
call "$d/x.part" "file://$work/no-such-file"
check "the sweep keeps a live run, a link and a name that is no key" \
  ".pacman-oci.4242-5.live-1-1-any.pkg.tar.zst .pacman-oci.999999999-1.link .pacman-oci.notakey " \
  "$(entries "$d")" "ls -a DIR after one call"

# A run in another pid namespace has a pid that this /proc cannot show. Its
# ,open had a heartbeat less than 2 minutes ago, so its entries stay. A run
# whose ,open is older than that is gone.
parent 821
d="$work/heartbeat"
mkdir -p "$d"
: > "$d/.pacman-oci.999999998-2.,open"
: > "$d/.pacman-oci.999999998-2.tmp.AbCdEf"
: > "$d/.pacman-oci.999999997-3.,open"
: > "$d/.pacman-oci.999999997-3.tmp.GhIjKl"
touch -t 200001010000 "$d/.pacman-oci.999999997-3.,open"
call "$d/x.part" "file://$work/no-such-file"
check "the sweep keeps a run whose ,open is fresh, and removes one whose ,open is old" \
  ".pacman-oci.999999998-2.,open .pacman-oci.999999998-2.tmp.AbCdEf " "$(entries "$d")" \
  "ls -a DIR after one call, with the ,open of 999999997-3 at 2000-01-01"

#---------------------------------------------------------------------------#
# The background remover: when the run ends, its entries go.
#---------------------------------------------------------------------------#
parent 830
K="$$-830"
d="$work/reap"
mkdir -p "$d"
call "$d/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst"
before="$(find "$d" -name ".pacman-oci.$K.*" | wc -l | tr -d ' ')"
# While the run is live, the remover touches its ,open once a second.
beat=''
if [ -f "$d/.pacman-oci.$K.,open" ]; then
  touch -t 200001010000 "$d/.pacman-oci.$K.,open"
  for _ in 1 2 3 4 5 6; do
    sleep 0.5
    beat="$(find "$d/.pacman-oci.$K.,open" -prune -mmin -2)"
    [ -z "$beat" ] || break
  done
fi
check "the remover touches ,open within 3 s while the run is live" "$d/.pacman-oci.$K.,open" "$beat" \
  "touch -t 200001010000 DIR/.pacman-oci.KEY.,open; sleep 3; find it -prune -mmin -2"
parent 831
left=1
for _ in 1 2 3 4 5 6; do
  left="$(find "$d" -name ".pacman-oci.$K.*" | wc -l | tr -d ' ')"
  [ "$left" -ne 0 ] || break
  sleep 0.5
done
if [ "$before" -gt 0 ] && [ "$left" -eq 0 ]; then
  ok "the run's entries are gone within 3 s of its end ($before before)"
else
  fail "the run's entries are gone within 3 s of its end" "before: $before, after: $left" \
    "reproduce: tests/unit/31-run-store.sh, the reap block"
fi

#---------------------------------------------------------------------------#
# Under dash, when it is here: the same key and the same serving.
#---------------------------------------------------------------------------#
if command -v dash > /dev/null 2>&1; then
  parent 840
  d="$work/dash"
  mkdir -p "$d"
  printf 'dash bytes\n' > "$d/.pacman-oci.$$-840.d-1-1-any.pkg.tar.zst"
  rc=0
  dash "$W" "$d/d-1-1-any.pkg.tar.zst.part" "$U/d-1-1-any.pkg.tar.zst" > /dev/null 2>&1 || rc=$?
  check "under dash: a ready package is OUTPUT" "0:dash bytes" "$rc:$(cat "$d/d-1-1-any.pkg.tar.zst.part")" \
    "dash client/pacman-oci DIR/d...part URL"
else
  ok "skipped: dash not installed"
fi

summary
