#!/usr/bin/env bash
#
# The prefetch plan: which print run the wrapper asks pacman for, and what it
# makes of the lines pacman prints.
#
# pacman's argument list is rewritten for a print run: every refresh,
# --confirm, --noconfirm and --print-format go, everything after -- stays, and
# an argument list it cannot read with certainty means no prefetch at all. The
# print lines carry the URL, sha256, size and base64 signature of each file to
# download; a signature is written from that line, with no request.
#
# The parent process is faked with PACMAN_OCI_TEST_PROC (see 31-run-store.sh);
# its exe is a script that records its arguments and prints prepared lines.
# Port 9 on the loopback refuses at once, so nothing here needs a network.
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
export FAKE_ARGS="$work/args" FAKE_LINES="$work/lines" FAKE_CONF="$work/conf.log"
U="oci+http://127.0.0.1:9/ns/mirror/x86_64/core"
TAB=$'\t'
FMT="%l$TAB%h$TAB%s$TAB%g"

cat > "$work/pacman" << 'EOF'
#!/bin/sh
# Stands in for pacman's print run.
for a in "$@"; do
  printf '%s\n' "$a"
done > "$FAKE_ARGS"
cat "$FAKE_LINES"
EOF
chmod +x "$work/pacman"
ln -s "$work/pacman" "$fake/$$/exe"
: > "$work/lines"

start=1000
# run ARG...: a fresh pacman run with these arguments, then one package request
# from it; the print run's arguments, if it ran, are in $work/args
run() {
  start=$((start + 1))
  printf 'pacman\n' > "$fake/$$/comm"
  printf '%s (pacman) S 1 1 1 0 -1 4194560 837 0 0 0 0 0 0 0 20 0 1 0 %s 62676992 3236\n' "$$" "$start" > "$fake/$$/stat"
  printf '%s\0' pacman "$@" > "$fake/$$/cmdline"
  rm -f "$work/args"
  dl="$work/dl.$start"
  mkdir -p "$dl"
  rc=0
  PACMAN_OCI_DEBUG=1 "$W" "$dl/foo-1-1-any.pkg.tar.zst.part" "$U/foo-1-1-any.pkg.tar.zst" > /dev/null 2> "$work/err" || rc=$?
}

# rewritten: the print run's arguments after the five the wrapper puts first
rewritten() {
  if [ -f "$work/args" ]; then
    sed -n '6,$p' "$work/args" | tr '\n' ' '
  else
    printf 'no print run'
  fi
}

#---------------------------------------------------------------------------#
# The rewrite
#---------------------------------------------------------------------------#
run -Syu
check "the print run starts with --print and the format" "--print|--print-format|$FMT|--noconfirm|--noprogressbar" \
  "$(sed -n '1,5p' "$work/args" | paste -sd '|' -)" "PACMAN_OCI_TEST_PROC=DIR client/pacman-oci OUT URL; cat args"

while IFS='|' read -r label want args; do
  # shellcheck disable=SC2086 # the arguments are words on purpose
  run $args
  check "rewrite: $label" "$want" "$(rewritten)" "pacman $args, then the print run's arguments"
done << 'EOF'
-Syu drops the refresh|-Su |-Syu
-Syyu drops both refreshes|-Su |-Syyu
-S -y -u drops the lone -y|-S -u |-S -y -u
--sync --refresh drops --refresh|--sync |--sync --refresh
-Sb /x keeps b's value|-Sb /x |-Sb /x
-Syb/x drops the y before b and keeps b's value|-Sb/x |-Syb/x
a y after b is b's value|-Sb/y |-Sb/y
everything after -- stays|-S -- -y foo |-Sy -- -y foo
--noconfirm, --confirm and --print-format go|-S foo |-S --noconfirm --confirm --print-format %n foo
an option's value is never rewritten|-Su --ignore -yfoo |-Syu --ignore -yfoo
--config=FILE stays|--config=/etc/x.conf -Su |--config=/etc/x.conf -Syu
-r with its value apart stays|-Sr / foo |-Syr / foo
EOF

while IFS='|' read -r label args; do
  # shellcheck disable=SC2086 # the arguments are words on purpose
  run $args
  check "no print run: $label" "no print run" "$(rewritten)" "pacman $args, then ls args"
done << 'EOF'
-U is not sync|-U /tmp/x.pkg.tar.zst
-Sp prints already|-Sp foo
--print prints already|-S --print foo
an abbreviated option|-S --refr foo
an option pacman does not have|-S --frobnicate foo
a relative config|-S --config rel.conf foo
a relative cachedir|-S --cachedir=cache foo
a target read from stdin|-S -
an option with no value|-S foo --dbpath
EOF

run -S "$(printf 'a\nb')"
check "no print run: an argument holds a newline" "no print run" "$(rewritten)" "pacman -S 'a<newline>b'"

PACMAN_OCI_PREFETCH=0 run -Su
check "no print run: PACMAN_OCI_PREFETCH=0" "no print run" "$(rewritten)" "PACMAN_OCI_PREFETCH=0 ..."
PACMAN_OCI_JOBS=1 run -Su
check "no print run: PACMAN_OCI_JOBS=1" "no print run" "$(rewritten)" "PACMAN_OCI_JOBS=1 ..."
PACMAN_OCI_NO_DUMMY=1 run -Su
check "no print run: PACMAN_OCI_NO_DUMMY=1" "no print run" "$(rewritten)" "PACMAN_OCI_NO_DUMMY=1 ..."
run -Su
first="$(rewritten)"
rm -f "$work/args"
rc=0
PACMAN_OCI_DEBUG=1 "$W" "$dl/bar-1-1-any.pkg.tar.zst.part" "$U/bar-1-1-any.pkg.tar.zst" > /dev/null 2> "$work/err" || rc=$?
check "one print run per pacman run" "-Su :no print run" "$first:$(rewritten)" "two requests in one run, then ls args"

#---------------------------------------------------------------------------#
# The print lines. A signature comes from %g; the planned sha256 and size of
# each package go to the index; anything else is skipped.
#---------------------------------------------------------------------------#
H1="$(printf 'one' | sha256sum | cut -d ' ' -f 1)"
H2="$(printf 'two' | sha256sum | cut -d ' ' -f 1)"
SIG="$(printf 'SIGNATURE of good\001\000\377' | base64 | tr -d '\n')"
{
  printf 'file:///var/cache/pacman/pkg/cached-1-1-any.pkg.tar.zst\t%s\t0\t%s\n' "$H1" "$SIG"
  printf '%s/good-1-1-any.pkg.tar.zst\t%s\t123\t%s\n' "$U" "$H1" "$SIG"
  printf 'http://127.0.0.1:9/core/os/x86_64/plain-1-1-any.pkg.tar.zst\t%s\t45\t%s\n' "$H2" "$SIG"
  printf '%s/badhex-1-1-any.pkg.tar.zst\txyz\t10\t%s\n' "$U" "$SIG"
  printf '%s/badsig-1-1-any.pkg.tar.zst\t%s\t10\t!!not base64\n' "$U" "$H1"
  printf '%s/nosig-1-1-any.pkg.tar.zst\t%s\t10\t\n' "$U" "$H2"
  printf 'a line pacman prints for itself\n'
  printf '%s/three-1-1-any.pkg.tar.zst\t%s\t10\n' "$U" "$H1"
  printf '%s/core.db\t%s\t10\t%s\n' "$U" "$H1" "$SIG"
  printf '%s/badsize-1-1-any.pkg.tar.zst\t%s\tlots\t%s\n' "$U" "$H1" "$SIG"
} > "$work/lines"
run -Su
K="$$-$start"
sigs="$(find "$dl" -name ".pacman-oci.$K.*.sig" | sed "s|.*/.pacman-oci.$K.||" | sort | tr '\n' ' ')"
check "a .sig is written for each package line with a valid %g" \
  "badhex-1-1-any.pkg.tar.zst.sig good-1-1-any.pkg.tar.zst.sig plain-1-1-any.pkg.tar.zst.sig " "$sigs" \
  "ls -a DIR after a print run with the prepared lines"
check "the index holds each package line with a valid %h" \
  "good-1-1-any.pkg.tar.zst $H1 123|plain-1-1-any.pkg.tar.zst $H2 45|badsig-1-1-any.pkg.tar.zst $H1 10|nosig-1-1-any.pkg.tar.zst $H2 10" \
  "$(tr '\t' ' ' < "$dl/.pacman-oci.$K.,index" | paste -sd '|' -)" "cat DIR/.pacman-oci.KEY.,index"

rc=0
PACMAN_OCI_DEBUG=1 "$W" "$dl/good-1-1-any.pkg.tar.zst.sig.part" "$U/good-1-1-any.pkg.tar.zst.sig" > /dev/null 2> "$work/err" || rc=$?
check "the .sig request is served from %g, decoded byte for byte, with no request" \
  "0:$(printf 'SIGNATURE of good\001\000\377' | sha256sum | cut -d ' ' -f 1):0" \
  "$rc:$(sha256sum < "$dl/good-1-1-any.pkg.tar.zst.sig.part" | cut -d ' ' -f 1):$(awk '/^pacman-oci: GET / { n++ } END { print n + 0 }' "$work/err")" \
  "client/pacman-oci DIR/good...sig.part URL"

PACMAN_OCI_SIG=registry run -Su
check "PACMAN_OCI_SIG=registry: no .sig from %g" "" \
  "$(find "$dl" -name ".pacman-oci.$$-$start.*.sig")" "PACMAN_OCI_SIG=registry ...; ls -a DIR"
: > "$work/lines"

#---------------------------------------------------------------------------#
# pacman can hold a .part in the cache. %s leaves it out, so the index adds
# its size back, from the file's metadata, as pacman's own stat() does. Under
# DownloadUser, a .part that root left with mode 0600 is not readable. It
# must still have its size, and the prefetch must go on.
#
# The wrapper runs as a user who cannot read locked...part. A user that is
# not root runs it with the file at mode 000. Root runs it as uid 65534,
# through setpriv or busybox su. Each must keep this shell as the parent, and
# a probe checks that first. busybox su also reads options after the user, so
# no argument after it starts with -.
#---------------------------------------------------------------------------#
cache="$work/cache"
dlp="$cache/download-PaRt01"
locked="$cache/locked-1-1-any.pkg.tar.zst.part"
mkdir -p "$dlp"
head -c 1000 /dev/zero > "$cache/held-1-1-any.pkg.tar.zst.part"
head -c 3000 /dev/zero > "$locked"
as_other=()
how=''
why=''
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$locked"
  how="this user, with the .part at mode 000"
else
  chmod 755 "$work"
  mkdir -p "$work/probe"
  chmod 777 "$work/probe"
  cat > "$work/probe/probe" << 'EOF'
#!/bin/sh
printf '%s %s\n' "$PPID" "$(id -u)" > "$1"
EOF
  chmod 755 "$work/probe/probe"
  for try in setpriv su; do
    command -v "$try" > /dev/null 2>&1 || continue
    case $try in
      setpriv) cand=(setpriv --reuid=65534 --regid=65534 --clear-groups --) ;;
      *)
        # shellcheck disable=SC2016 # the shell su starts expands it, this one must not
        cand=(su -s /bin/sh nobody -c 'exec "$0" "$@"')
        ;;
    esac
    rm -f "$work/probe/out"
    rc=0
    "${cand[@]}" "$work/probe/probe" "$work/probe/out" > "$work/probe/log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$work/probe/out" ] && [ "$(cat "$work/probe/out")" = "$$ 65534" ]; then
      as_other=("${cand[@]}")
      how="uid 65534 through $try, with the .part of root at mode 0600"
      break
    fi
    printed=''
    if [ -f "$work/probe/out" ]; then
      printed="$(cat "$work/probe/out")"
    fi
    why="$why; $try: exit $rc, printed '$printed', said '$(cat "$work/probe/log")'"
  done
  if [ -n "$how" ]; then
    chmod 600 "$locked"
    chown 65534:65534 "$dlp"
    chmod 700 "$dlp"
  fi
fi
start=$((start + 1))
printf '%s (pacman) S 1 1 1 0 -1 4194560 837 0 0 0 0 0 0 0 20 0 1 0 %s 62676992 3236\n' "$$" "$start" > "$fake/$$/stat"
printf '%s\0' pacman -S held locked > "$fake/$$/cmdline"
{
  printf '%s/held-1-1-any.pkg.tar.zst\t%s\t24\t%s\n' "$U" "$H1" "$SIG"
  printf '%s/locked-1-1-any.pkg.tar.zst\t%s\t7\t%s\n' "$U" "$H2" "$SIG"
} > "$work/lines"
rc=0
FAKE_ARGS=/dev/null PACMAN_OCI_DEBUG=1 ${as_other[@]+"${as_other[@]}"} "$W" "$dlp/held-1-1-any.pkg.tar.zst.part" "$U/held-1-1-any.pkg.tar.zst" > /dev/null 2> "$work/err" || rc=$?
index="$dlp/.pacman-oci.$$-$start.,index"
if [ -f "$index" ]; then
  got="$(tr '\t' ' ' < "$index" | paste -sd '|' -)"
else
  got="no index; the wrapper ended $rc: $(awk '!/^pacman-oci: /' "$work/err" | paste -sd ' ' -)"
fi
check "a .part pacman holds is added back to the planned size" \
  "held-1-1-any.pkg.tar.zst $H1 1024" "${got%%|*}" "head -c 1000 > CACHE/held...part; a print line with %s 24; cat DIR/.pacman-oci.KEY.,index"
if [ -n "$how" ]; then
  check "a .part the wrapper cannot read is sized from its metadata ($how)" \
    "held-1-1-any.pkg.tar.zst $H1 1024|locked-1-1-any.pkg.tar.zst $H2 3007" "$got" \
    "an unreadable CACHE/locked...part of 3000 bytes; a print line with %s 7; cat DIR/.pacman-oci.KEY.,index"
else
  diag "no command here runs the wrapper as uid 65534 with this shell ($$) as its parent${why:-; no setpriv and no su}"
  ok "skipped: no way here to run the wrapper as a user who cannot read a .part"
fi
: > "$work/lines"

#---------------------------------------------------------------------------#
# The database prefetch reads pacman's config through pacman-conf, never
# with --sysroot.
#---------------------------------------------------------------------------#
mkdir -p "$work/bin"
cat > "$work/bin/pacman-conf" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CONF"
case "$*" in
  *--repo-list*) printf 'core\n' ;;
  *) printf 'oci+http://127.0.0.1:9/ns/mirror/x86_64/core\n' ;;
esac
EOF
chmod +x "$work/bin/pacman-conf"

# dbrun ARG...: a fresh run with these arguments, then core.db
dbrun() {
  start=$((start + 1))
  printf '%s (pacman) S 1 1 1 0 -1 4194560 837 0 0 0 0 0 0 0 20 0 1 0 %s 62676992 3236\n' "$$" "$start" > "$fake/$$/stat"
  printf '%s\0' pacman "$@" > "$fake/$$/cmdline"
  rm -f "$work/conf.log"
  dl="$work/db.$start"
  mkdir -p "$dl"
  rc=0
  PATH="$work/bin:$PATH" PACMAN_OCI_DEBUG=1 "$W" "$dl/core.db.part" "$U/core.db" > /dev/null 2> "$work/err" || rc=$?
}
conf_calls() {
  if [ -f "$work/conf.log" ]; then
    paste -sd '|' - < "$work/conf.log"
  else
    printf 'no call'
  fi
}
dbrun -Sy
check "the database prefetch reads /etc/pacman.conf by default" \
  "--config /etc/pacman.conf --repo-list|--config /etc/pacman.conf --repo core Server" "$(conf_calls)" "pacman -Sy; cat conf.log"
dbrun --config /etc/other.conf -Sy
check "the database prefetch reads the config pacman was given" \
  "--config /etc/other.conf --repo-list|--config /etc/other.conf --repo core Server" "$(conf_calls)" "pacman --config /etc/other.conf -Sy"
dbrun --sysroot /mnt -Sy
check "no database prefetch with --sysroot" "no call" "$(conf_calls)" "pacman --sysroot /mnt -Sy"
dbrun --arch aarch64 -Sy
check "no database prefetch with --arch" "no call" "$(conf_calls)" "pacman --arch aarch64 -Sy"

summary
