#!/usr/bin/env bash
#
# The decisions the sync makes, each on fixed inputs: which target files are
# valid, which database fields are refused, which database is behind another,
# when a package tag may be written, when a target is stale, which snapshot is
# newer, how a shard accounts for every file, which token a registry read
# sends, which server is asked last, how long an upstream read or a registry
# request may take, and which artifacts of a re-run the report reads.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

LIB="$REPO_ROOT/scripts/lib.sh"

# in_lib CMD... -> runs CMD in a shell that sourced lib.sh; prints its output,
# returns its status. die() exits that shell, not this one.
in_lib() {
  # Called as the scripts call a predicate, in a condition: a refusal is an
  # answer, and lib.sh's ERR trap then stays quiet, as it does in the scripts.
  bash -c '. "$1"; shift; "$@" || exit $?' _ "$LIB" "$@"
}

#---------------------------------------------------------------------------#
# Target files
#---------------------------------------------------------------------------#
mkdir -p "$work/targets"
good="$work/targets/x86_64-core.conf"
cat > "$good" << 'EOF'
# a comment
arch = x86_64
repo = core
db_server = https://example.invalid/$repo/os/$arch
server = https://mirror.example.invalid/$repo/os/$arch
keyring = archlinux-keyring
EOF
rc=0
in_lib target_check "$good" > /dev/null 2>&1 || rc=$?
check "a good target file is accepted" 0 "$rc" "bash -c '. scripts/lib.sh; target_check FILE'"
check "server lines expand \$repo and \$arch" "https://mirror.example.invalid/core/os/x86_64" \
  "$(in_lib target_all "$good" server)" "bash -c '. scripts/lib.sh; target_all FILE server'"
check "package sources are the db_servers, then the servers" \
  "$(printf '%s\n' https://example.invalid/core/os/x86_64 https://mirror.example.invalid/core/os/x86_64)" \
  "$(in_lib target_sources "$good")" "bash -c '. scripts/lib.sh; target_sources FILE'"

refused() {
  local label="$1" file="$2" rc=0
  in_lib target_check "$file" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "refused: $label"
  else
    fail "refused: $label" "target_check accepted it" "reproduce: bash -c '. scripts/lib.sh; target_check $file'"
  fi
}
sed '/^db_server/d' "$good" > "$work/targets/x86_64-core.conf.tmp"
mkdir -p "$work/t1" && mv "$work/targets/x86_64-core.conf.tmp" "$work/t1/x86_64-core.conf"
refused "a target with no db_server" "$work/t1/x86_64-core.conf"
mkdir -p "$work/t2" && { cat "$good"; echo 'mirrors = https://x.invalid'; } > "$work/t2/x86_64-core.conf"
refused "an unknown key" "$work/t2/x86_64-core.conf"
mkdir -p "$work/t3" && { cat "$good"; echo 'repo = extra'; } > "$work/t3/x86_64-core.conf"
refused "a key given twice" "$work/t3/x86_64-core.conf"
mkdir -p "$work/t4" && cp "$good" "$work/t4/x86_64-extra.conf"
refused "a file not named arch-repo.conf" "$work/t4/x86_64-extra.conf"
mkdir -p "$work/t5" && { cat "$good"; echo 'db_signed = maybe'; } > "$work/t5/x86_64-core.conf"
refused "db_signed that is not yes or no" "$work/t5/x86_64-core.conf"
mkdir -p "$work/t6" && { cat "$good"; echo 'not a key value line'; } > "$work/t6/x86_64-core.conf"
refused "a line that is not key = value" "$work/t6/x86_64-core.conf"

#---------------------------------------------------------------------------#
# The keys that set verify's trust root
#---------------------------------------------------------------------------#
# tag: aarch64
IMG='ghcr.io/pkgforge-dev/archlinux:aarch64@sha256:dd89780d86c0941d612b5aa6203c5e6c446db7b6d98130b7556c98c5c6dcff06'
# trust NAME LINES...: a target file of x86_64 extra, with x86_64-core beside it
trust() {
  local d="$work/trust-$1"
  shift
  mkdir -p "$d"
  cp "$good" "$d/x86_64-core.conf"
  { sed 's/^repo = core$/repo = extra/; /^keyring/d' "$good"; printf '%s\n' "$@"; } > "$d/x86_64-extra.conf"
  printf '%s\n' "$d/x86_64-extra.conf"
}
accepted() {
  local label="$1" file="$2" rc=0
  in_lib target_check "$file" > "$work/accepted.err" 2>&1 || rc=$?
  check "accepted: $label" 0 "$rc" "bash -c '. scripts/lib.sh; target_check $file' ($(cat "$work/accepted.err"))"
}
accepted "keyring as a list, keyring_from a target of the same arch" \
  "$(trust ok 'keyring = archlinux-keyring archlinux-lcpu-keyring' 'keyring_from = x86_64-core')"
accepted "keyring_image pinned by digest, with keyring_platform" \
  "$(trust image 'keyring = archlinuxarm-keyring' "keyring_image = $IMG" 'keyring_platform = linux/arm64')"
check "target_keyrings lists each keyring package" "$(printf '%s\n' archlinux-keyring archlinux-lcpu-keyring)" \
  "$(in_lib target_keyrings "$work/trust-ok/x86_64-extra.conf")" "bash -c '. scripts/lib.sh; target_keyrings FILE'"
refused "a keyring name with a leading -" "$(trust dash 'keyring = -rf archlinux-keyring')"
refused "a keyring name with a /" "$(trust slash 'keyring = ../archlinux-keyring')"
refused "a keyring name that is a glob" "$(trust glob 'keyring = *')"
refused "keyring_from with no keyring" "$(trust nokr 'keyring_from = x86_64-core')"
refused "keyring_from naming the target itself" "$(trust self 'keyring = a' 'keyring_from = x86_64-extra')"
arch_conf="$(trust arch 'keyring = a' 'keyring_from = aarch64-core')"
sed 's/^arch = x86_64$/arch = aarch64/' "$good" > "$(dirname "$arch_conf")/aarch64-core.conf"
refused "keyring_from naming a target of another arch" "$arch_conf"
refused "keyring_from naming a target with no file" "$(trust none 'keyring = a' 'keyring_from = x86_64-nothere')"
refused "keyring_image with a tag and no digest" "$(trust tag 'keyring_image = ghcr.io/pkgforge-dev/archlinux:aarch64' 'keyring_platform = linux/arm64')"
refused "keyring_image with no keyring_platform" "$(trust noplat "keyring_image = $IMG")"
refused "keyring_platform with no keyring_image" "$(trust noimg 'keyring_platform = linux/arm64')"
refused "keyring_platform that is not linux/<arch>" "$(trust plat "keyring_image = $IMG" 'keyring_platform = arm64')"

#---------------------------------------------------------------------------#
# Database fields
#---------------------------------------------------------------------------#
SHA=41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1
rec() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-$SHA}" "${6:-84690}" "${7:-1790000000}" "${8:-}"
}
valid() {
  local label="$1" want="$2" rc=0
  shift 2
  rec "$@" > "$work/rec.tsv"
  in_lib db_validate "$work/rec.tsv" > /dev/null 2>&1 || rc=$?
  if [ "$want" = accept ]; then
    check "db field check accepts $label" 0 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"
  else
    check "db field check refuses $label" 1 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"
  fi
}
valid "an epoch and a +" accept 'zlib-1:1.3.2+r2-3-x86_64.pkg.tar.zst' zlib '1:1.3.2+r2-3' x86_64
valid "a ~ in a version, which makepkg allows" accept 'foo-1.0~rc1-1-any.pkg.tar.zst' foo '1.0~rc1-1' any
valid "an uncompressed package" accept 'foo-1-1-any.pkg.tar' foo '1-1' any
valid "a path traversal" refuse '../../scripts/stage.pkg.tar.zst' foo '1-1' any
valid "a leading -" refuse '-rf-1-1-any.pkg.tar.zst' -rf '1-1' any
valid "a space" refuse 'foo bar-1-1-any.pkg.tar.zst' 'foo bar' '1-1' any
valid "a / inside" refuse 'foo/bar-1-1-any.pkg.tar.zst' foo '1-1' any
# Only the / is wrong here: the name, version and arch prefix all match, so
# nothing but the character check stands between this and a path.
valid "a / alone, after a valid prefix" refuse 'foo-1-1-any.pkg.tar/../../x.pkg.tar.zst' foo '1-1' any
valid "a sha256 that is not one" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any nothex
valid "a size that is not a number" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any "$SHA" 12k
valid "a filename that is not name-version-arch" refuse 'bar-1-1-any.pkg.tar.zst' foo '1-1' any
valid "a signature that is not base64" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any "$SHA" 1 1 'not base64!'

{ rec 'foo-1-1-any.pkg.tar.zst' foo '1-1' any; rec 'foo-1-1-any.pkg.tar.zst' foo '1-1' any; } > "$work/rec.tsv"
rc=0
in_lib db_validate "$work/rec.tsv" > /dev/null 2>&1 || rc=$?
check "db field check refuses a filename listed twice" 1 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"

#---------------------------------------------------------------------------#
# A whole database: one record per package directory, and a directory whose
# desc holds only NUL bytes passed over and named. db_records reads with GNU
# tar, which every runner and Arch has; another tar skips these.
#---------------------------------------------------------------------------#
# mkdb NAME [ghost|empty|junk|twice ...] -> a gzip database with packages a and
# b, and the extra members asked for
mkdb() {
  local name="$1" d="$work/db-$1" p extra
  shift
  rm -rf "$d"
  for p in a b; do
    mkdir -p "$d/$p-1-1"
    printf '%%FILENAME%%\n%s-1-1-any.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n%%SHA256SUM%%\n%s\n\n%%CSIZE%%\n10\n\n%%BUILDDATE%%\n1700000000\n\n' \
      "$p" "$p" "$SHA" > "$d/$p-1-1/desc"
  done
  for extra in "$@"; do
    case "$extra" in
      ghost) mkdir -p "$d/ghost-1-1" && head -c 1271 /dev/zero > "$d/ghost-1-1/desc" ;;
      empty) mkdir -p "$d/empty-1-1" && : > "$d/empty-1-1/desc" ;;
      junk) mkdir -p "$d/junk-1-1" && printf 'bytes that are no record\n' > "$d/junk-1-1/desc" ;;
      twice) printf '%%FILENAME%%\nc-1-1-any.pkg.tar.zst\n\n%%NAME%%\nc\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n%%SHA256SUM%%\n%s\n\n%%CSIZE%%\n10\n\n%%BUILDDATE%%\n1700000000\n\n' "$SHA" >> "$d/b-1-1/desc" ;;
    esac
  done
  (cd "$d" && tar -czf "$work/$name.db" -- *)
  printf '%s\n' "$work/$name.db"
}
tar_version="$(tar --version 2>&1 | sed -n 1p)"
if case "$tar_version" in *'GNU tar'*) true ;; *) false ;; esac then
  db="$(mkdb whole)"
  rc=0
  why="$(in_lib db_check "$db" "$work/whole.tsv" 2>&1)" || rc=$?
  check "db_check accepts a whole database" "0 2" "$rc $(awk 'END { print NR }' "$work/whole.tsv")" "bash -c '. scripts/lib.sh; db_check DB OUT' ($why)"
  db="$(mkdb nul ghost empty)"
  rc=0
  why="$(in_lib db_check "$db" "$work/nul.tsv" 2>&1)" || rc=$?
  check "db_check accepts package directories whose desc is NUL bytes or empty, and names them" "0 2 empty-1-1 ghost-1-1" \
    "$rc $(awk 'END { print NR }' "$work/nul.tsv") $(sort "$work/nul.tsv.nul" | tr '\n' ' ' | sed 's/ $//')" "bash -c '. scripts/lib.sh; db_check DB OUT' ($why)"
  db="$(mkdb junk ghost junk)"
  rc=0
  why="$(in_lib db_check "$db" "$work/junk.tsv" 2>&1)" || rc=$?
  case "$rc:$why" in
    1:junk-1-1/desc*) ok "db_check refuses an unreadable member that holds other bytes than NUL, and names it" ;;
    *) fail "db_check refuses an unreadable member that holds other bytes than NUL, and names it" "status $rc: $why" "bash -c '. scripts/lib.sh; db_check DB OUT'" ;;
  esac
  db="$(mkdb twice twice)"
  rc=0
  why="$(in_lib db_check "$db" "$work/twice.tsv" 2>&1)" || rc=$?
  case "$rc:$why" in
    1:*"2 package directories, 3 readable records"*) ok "db_check refuses a desc that holds two records" ;;
    *) fail "db_check refuses a desc that holds two records" "status $rc: $why" "bash -c '. scripts/lib.sh; db_check DB OUT'" ;;
  esac
else
  ok "skipped: db_check reads with GNU tar, and this tar is $tar_version"
fi

#---------------------------------------------------------------------------#
# A database tar cannot read whole fails, and fails in every reader.
#
# Three cases, because they fail in different places:
#   truncated    tar reads the members before the cut and then errors. The
#                record set it produced looks exactly like a smaller repository.
#   zstd         the PowerPC databases are zstd (measured 2026-10-15: the first
#                four bytes of powerpc64le base.db are 28 b5 2f fd). GNU tar
#                shells out for zstd, so a host without the program reads none
#                of it. busybox tar cannot read it at all.
#   notatar      bytes that are not an archive at all.
#
# Each must give a non-zero status and leave no record file. The status is read
# from PIPESTATUS, and `local` resets PIPESTATUS, so the capture has to be the
# first command after the pipeline. That is the fault this block was written
# for: with the array declared first, every case reported 0.
#---------------------------------------------------------------------------#
if case "$tar_version" in *'GNU tar'*) true ;; *) false ;; esac; then
  # mkbig N -> a database with N packages, big enough that a cut lands inside it
  mkbig() {
    local n="$1" d="$work/big-$1" p
    rm -rf "$d"
    for ((p = 0; p < n; p++)); do
      mkdir -p "$d/p$p-1-1"
      printf '%%FILENAME%%\np%s-1-1-any.pkg.tar.zst\n\n%%NAME%%\np%s\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n%%SHA256SUM%%\n%s\n\n%%CSIZE%%\n10\n\n%%BUILDDATE%%\n1700000000\n\n' \
        "$p" "$p" "$SHA" > "$d/p$p-1-1/desc"
    done
    (cd "$d" && tar -czf "$work/big-$1.db" -- *)
    printf '%s\n' "$work/big-$1.db"
  }

  whole="$(mkbig 40)"
  rc=0
  in_lib db_records "$whole" "$work/big-ok.tsv" > /dev/null 2>&1 || rc=$?
  check "a whole database gives 40 records and a zero status" "0 40" \
    "$rc $(awk 'END { print NR + 0 }' "$work/big-ok.tsv")" "bash -c '. scripts/lib.sh; db_records DB OUT'"

  # Truncated at half: tar reads the first packages, then errors with status 2.
  cut_db="$work/cut.db"
  head -c "$(($(wc -c < "$whole") / 2))" "$whole" > "$cut_db"
  rc=0
  in_lib db_records "$cut_db" "$work/cut.tsv" > /dev/null 2>&1 || rc=$?
  check "a truncated database gives a non-zero status, not a partial record set" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_records $cut_db OUT' (tar ended 2, premature end)"
  check "a truncated database leaves no record file" "absent" \
    "$([ -e "$work/cut.tsv" ] && echo present || echo absent)" "bash -c '. scripts/lib.sh; db_records $cut_db OUT'; ls OUT"

  rc=0
  in_lib db_members "$cut_db" > /dev/null 2>&1 || rc=$?
  check "db_members gives a non-zero status on a truncated database" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_members $cut_db'"

  rc=0
  in_lib db_check "$cut_db" "$work/cut-check.tsv" > /dev/null 2>&1 || rc=$?
  check "db_check refuses a truncated database" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_check $cut_db OUT'"

  # Bytes that are not an archive.
  printf 'this is not a tar archive at all\n' > "$work/notatar.db"
  rc=0
  in_lib db_records "$work/notatar.db" "$work/notatar.tsv" > /dev/null 2>&1 || rc=$?
  check "db_records gives a non-zero status on bytes that are not an archive" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_records $work/notatar.db OUT'"

  # A zstd database, which is what all six PowerPC targets serve. tar needs the
  # zstd program for it, so the case that matters is a host without it.
  if command -v zstd > /dev/null && command -v tar > /dev/null; then
    zdb="$work/zstd.db"
    # The member list names the fixture directory itself: a `-- *` on this line
    # expands against the test's own directory, not the fixture's.
    (cd "$work/big-40" && tar --use-compress-program zstd -cf "$zdb" -- *)
    if [ -s "$zdb" ] && [ "$(od -An -tx1 -N4 "$zdb" | tr -d ' \n')" = 28b52ffd ]; then
      # The magic is measured here and asserted below, so a tar that silently
      # wrote something else cannot pass as a zstd database.
      magic="$(od -An -tx1 -N4 "$zdb" | tr -d ' \n')"
      rc=0
      in_lib db_records "$zdb" "$work/zstd.tsv" > /dev/null 2>&1 || rc=$?
      check "a zstd database is read whole, magic 28b52ffd" "0 40 28b52ffd" \
        "$rc $(awk 'END { print NR + 0 }' "$work/zstd.tsv") $magic" \
        "bash -c '. scripts/lib.sh; db_records $zdb OUT'; od -An -tx1 -N4 $zdb"
      rc=0
      in_lib db_check "$zdb" "$work/zstd-check.tsv" > /dev/null 2>&1 || rc=$?
      check "db_check accepts a zstd database" 0 "$rc" \
        "bash -c '. scripts/lib.sh; db_check $zdb OUT'"

      # With no zstd available tar cannot start the decompressor. That must be
      # a non-zero status with the program named, not 0 records.
      #
      # A directory of programs is the wrong instrument here: on this host bash
      # and zstd are both in /usr/bin, so any PATH that reaches the shell also
      # reaches zstd, and the case cannot be set up by removing a directory.
      # So zstd is shadowed by a program of the same name that refuses, which
      # is exactly what a host without it looks like to tar.
      stub="$work/no-zstd"
      mkdir -p "$stub"
      cat > "$stub/zstd" << 'STUB'
#!/bin/sh
printf 'zstd: stub, this host has no zstd\n' >&2
exit 127
STUB
      chmod +x "$stub/zstd"
      rc=0
      why="$(PATH="$stub:$PATH" bash -c '. "$1"; db_records "$2" "$3"' _ "$LIB" "$zdb" "$work/nozstd.tsv" 2>&1)" || rc=$?
      check "a zstd database with no zstd program gives a non-zero status" 1 "$rc" \
        "bash -c '. scripts/lib.sh; PATH=$stub db_records DB OUT'"
      case "$why" in
        *zstd*) ok "and the message names the zstd program" ;;
        *) fail "and the message names the zstd program" "$why" "bash -c '. scripts/lib.sh; PATH=$stub db_records DB OUT'" ;;
      esac
    else
      skip "a zstd database is read whole" "tar could not write one with zstd here"
    fi
  else
    skip "a zstd database is read whole" "zstd or tar is not on PATH"
  fi
else
  ok "skipped: an unreadable database fails, and this tar is $tar_version"
fi

#---------------------------------------------------------------------------#
# Behind: compared per package by build date. Fixtures are Arch's archived
# core.db of four days, reduced to name and build date: 10-02 and 10-03 share
# their newest build date and differ in bytes, and so do 10-10 and 10-11. The
# newest build date alone would pick either; the per-package rule does not.
#---------------------------------------------------------------------------#
fx="$REPO_ROOT/tests/fixtures/builddates"
as_records() {
  awk -F '\t' '{ printf "f\t%s\tv\ta\ts\t1\t%s\t\n", $1, $2 }' "$1"
}
for pair in "02 03" "10 11"; do
  read -r a b <<< "$pair"
  as_records "$fx/core-2026-10-$a.builddates" > "$work/a.tsv"
  as_records "$fx/core-2026-10-$b.builddates" > "$work/b.tsv"
  read -r newer older <<< "$(in_lib behind "$work/a.tsv" "$work/b.tsv")"
  if [ "$older" -eq 0 ] && [ "$newer" -gt 0 ]; then
    ok "core of 10-$b is not behind 10-$a ($newer newer, $older older)"
  else
    fail "core of 10-$b is not behind 10-$a" "newer $newer, older $older" "reproduce: bash -c '. scripts/lib.sh; behind A B'"
  fi
  read -r newer older <<< "$(in_lib behind "$work/b.tsv" "$work/a.tsv")"
  if [ "$older" -gt 0 ]; then
    ok "core of 10-$a is behind 10-$b ($older package(s) older)"
  else
    fail "core of 10-$a is behind 10-$b" "newer $newer, older $older" "reproduce: bash -c '. scripts/lib.sh; behind B A'"
  fi
done
cp "$work/a.tsv" "$work/a-again.tsv"
check "a database is not behind itself" "0 0" "$(in_lib behind "$work/a.tsv" "$work/a-again.tsv")" "bash -c '. scripts/lib.sh; behind A COPY-OF-A'"

#---------------------------------------------------------------------------#
# The signature of a signed database, checked with gpgv before it is used.
#
# Four cases, and the keys are made here so the test needs no network and no
# keyring from an image:
#   good      a signature by the key the keyring holds
#   other     a signature by a second key, which the keyring does not hold
#   changed   one byte changed in the .sig
#   wrong     the .sig of one file beside the bytes of another
# And one refusal with no keyring file at all, which is what a target whose
# keyring_image could not be read gives.
#---------------------------------------------------------------------------#
if need_tool gpg "the signature of a signed database is checked with gpgv, with keys made here"; then
  # mkkey NAME -> a keyring file holding one signing key, and the GNUPGHOME
  # beside it that can sign with it
  mkkey() {
    local name="$1"
    local home="$work/gnupg-$name"
    rm -rf "$home"
    mkdir -p "$home"
    chmod 700 "$home"
    cat > "$work/key-$name.batch" << EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: $name
Name-Email: $name@example.invalid
Expire-Date: 0
%commit
EOF
    GNUPGHOME="$home" gpg --batch --quiet --gen-key "$work/key-$name.batch" > "$work/key-$name.log" 2>&1
    GNUPGHOME="$home" gpg --batch --quiet --export > "$work/key-$name.gpg"
  }
  printf 'package bytes for the signature test\n' > "$work/signed.db"
  printf 'other package bytes\n' > "$work/other.db"

  mkkey trusted
  mkkey other
  sg="$work/sig"
  mkdir -p "$sg/keyrings"
  cp "$work/key-trusted.gpg" "$sg/keyrings/trusted.gpg"
  cp "$work/signed.db" "$sg/upstream.db"

  # sig_of KEY FILE OUT: a detached signature of FILE, made by KEY's key.
  # gpg refuses to overwrite an existing signature file, so it is removed first;
  # several cases re-sign the same output path.
  sig_of() {
    rm -f -- "$3"
    GNUPGHOME="$work/gnupg-$1" gpg --batch --quiet --detach-sign --output "$3" "$2"
  }

  sig_of trusted "$work/signed.db" "$sg/upstream.db.sig"
  rc=0
  why="$(in_lib db_sig_ok "$sg" base db 2>&1)" || rc=$?
  check "a signature by the key the keyring holds verifies" 0 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $sg base db' ($why)"

  # A second key signs the same bytes. The keyring holds only the first.
  sig_of other "$work/signed.db" "$sg/upstream.db.sig"
  rc=0
  why="$(in_lib db_sig_ok "$sg" base db 2>&1)" || rc=$?
  check "a signature by a key the keyring does not hold is refused" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $sg base db' (the keyring holds only key-trusted)"
  case "$why" in
    *base.db.sig*) ok "and the refusal names base.db.sig" ;;
    *) fail "and the refusal names base.db.sig" "$why" "bash -c '. scripts/lib.sh; db_sig_ok $sg base db'" ;;
  esac

  # One byte changed in the signature.
  sig_of trusted "$work/signed.db" "$sg/upstream.db.sig"
  printf 'X' | dd of="$sg/upstream.db.sig" bs=1 seek=60 conv=notrunc status=none 2> /dev/null
  rc=0
  why="$(in_lib db_sig_ok "$sg" base db 2>&1)" || rc=$?
  check "a signature with one byte changed is refused" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $sg base db' (byte 60 of the .sig is now X)"

  # The signature of one file beside the bytes of another.
  cp "$work/signed.db" "$sg/upstream.files"
  sig_of trusted "$work/other.db" "$sg/upstream.files.sig"
  rc=0
  why="$(in_lib db_sig_ok "$sg" base files 2>&1)" || rc=$?
  check "the signature of another file beside these bytes is refused" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $sg base files' (upstream.files.sig signs other.db)"
  case "$why" in
    *base.files.sig*) ok "and that refusal names base.files.sig" ;;
    *) fail "and that refusal names base.files.sig" "$why" "bash -c '. scripts/lib.sh; db_sig_ok $sg base files'" ;;
  esac

  # No keyring file: what a target whose keyring_image could not be read gives.
  empty="$work/sig-empty"
  mkdir -p "$empty/keyrings"
  cp "$work/signed.db" "$empty/upstream.db"
  sig_of trusted "$work/signed.db" "$empty/upstream.db.sig"
  rc=0
  why="$(in_lib db_sig_ok "$empty" base db 2>&1)" || rc=$?
  check "with no keyring file the signature cannot be checked, and the database is refused" 1 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $empty base db'"
  case "$why" in
    *keyring*) ok "and that refusal names the keyring directory" ;;
    *) fail "and that refusal names the keyring directory" "$why" "bash -c '. scripts/lib.sh; db_sig_ok $empty base db'" ;;
  esac

  # The acceptance half of the last case: with the keyring there, the same bytes
  # verify. A check that refuses everything is indistinguishable from one that
  # works, so the accepting row is what makes the refusing rows mean something.
  cp "$work/key-trusted.gpg" "$empty/keyrings/trusted.gpg"
  rc=0
  in_lib db_sig_ok "$empty" base db > /dev/null 2>&1 || rc=$?
  check "and the same bytes verify once the keyring is there" 0 "$rc" \
    "bash -c '. scripts/lib.sh; db_sig_ok $empty base db'"
else
  ok "skipped: the signature of a signed database is checked with gpgv"
fi


#---------------------------------------------------------------------------#
# The write-once rule
#---------------------------------------------------------------------------#
F='zlib-1:1.3.2-3-x86_64.pkg.tar.zst'
SIG=0000000000000000000000000000000000000000000000000000000000000001
OTHER=1111111111111111111111111111111111111111111111111111111111111111
manifest() {
  # manifest PKG_DIGEST PKG_SIZE PKG_TYPE [SIG_DIGEST SIG_TYPE]
  local layers
  layers="$(jq -cn --arg d "sha256:$1" --argjson s "$2" --arg t "$3" --arg f "$F" \
    '[{mediaType: $t, digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $f}}]')"
  if [ -n "${4:-}" ]; then
    layers="$(printf '%s' "$layers" | jq -c --arg d "sha256:$4" --arg t "$5" --arg f "$F.sig" \
      '. + [{mediaType: $t, digest: $d, size: 119, annotations: {"org.opencontainers.image.title": $f}}]')"
  fi
  jq -cn --argjson l "$layers" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: $l}' > "$work/m.json"
}
PKG_T=application/vnd.pkgforge.archlinux.pkg.v1
SIG_T=application/pgp-signature
decide() {
  in_lib decide_push "$work/m.json" "$F" "$SHA" 84690 "$1"
}
manifest "$SHA" 84690 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: the tag holds this file and its signature" present "$(decide "$SIG")" "lib.sh decide_push"
manifest "$OTHER" 84690 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: other bytes under this name are never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
jq -cn '{schemaVersion: 2, layers: [{mediaType: "x", digest: "sha256:'"$SHA"'", size: 1, annotations: {"org.opencontainers.image.title": "another-file"}}]}' > "$work/m.json"
check "write-once: a tag holding another file is never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
echo '{"schemaVersion":2}' > "$work/m.json"
check "write-once: a tag holding no layers at all is never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T"
check "write-once: the right package with its signature missing is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T" "$OTHER" "$SIG_T"
check "write-once: the right package with another signature is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 1 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: the right digest with the wrong size is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 application/octet-stream "$SIG" "$SIG_T"
check "write-once: the right digest with the wrong media type is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T"
check "write-once: no %PGPSIG% and no signature layer: fetch the .sig" needsig "$(decide '')" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T" "$OTHER" "$SIG_T"
check "write-once: no %PGPSIG%, and the signature layer present is kept" present "$(decide '')" "lib.sh decide_push"

#---------------------------------------------------------------------------#
# Staleness, with a fixed clock
#---------------------------------------------------------------------------#
A=aaaa B=bbbb
check "stale: latest serves upstream's database" current \
  "$(in_lib stale_verdict "$A" "$A" 2026-01-01T00:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: different, fetched within the tolerance" fresh \
  "$(in_lib stale_verdict "$A" "$B" 2026-10-11T23:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: different, fetched longer ago than the tolerance" stale \
  "$(in_lib stale_verdict "$A" "$B" 2026-10-09T23:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: nothing promoted at all" stale \
  "$(in_lib stale_verdict "" "$B" "" 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: upstream unreadable says nothing" unknown \
  "$(in_lib stale_verdict "$A" "" 2026-10-01T00:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"

#---------------------------------------------------------------------------#
# latest never moves backwards: the staged snapshot's fetched time against
# the live one's
#---------------------------------------------------------------------------#
order() {
  local rc=0
  in_lib fetched_not_older "$1" "$2" || rc=$?
  printf '%s\n' "$rc"
}
check "a later snapshot may be promoted" 0 "$(order 2026-10-13T09:17:00Z 2026-10-13T06:17:00Z)" "lib.sh fetched_not_older"
check "the same snapshot may be promoted again" 0 "$(order 2026-10-13T09:17:00Z 2026-10-13T09:17:00Z)" "lib.sh fetched_not_older"
check "an earlier snapshot is refused" 1 "$(order 2026-10-12T23:59:59Z 2026-10-13T00:00:00Z)" "lib.sh fetched_not_older"

#---------------------------------------------------------------------------#
# A shard accounts for every work line, and a line with no result failed.
#---------------------------------------------------------------------------#
printf 't\ta.pkg.tar.zst\n' > "$work/shard.tsv"
printf 't\tb.pkg.tar.zst\n' >> "$work/shard.tsv"
printf 't\tc.pkg.tar.zst\n' >> "$work/shard.tsv"
mkdir -p "$work/results"
printf 't\ta.pkg.tar.zst\tpushed\t1\tok\n' > "$work/results/1.tsv"
printf 't\tc.pkg.tar.zst\tpresent\t0\tok\n' > "$work/results/3.tsv"
bad="$(in_lib reconcile_results "$work/shard.tsv" "$work/results" "$work/all.tsv")"
check "an item that left no result is counted as failed" 1 "$bad" "lib.sh reconcile_results"
check "every work line has exactly one result line" 3 "$(awk 'END { print NR }' "$work/all.tsv")" "lib.sh reconcile_results"
check "the missing one is named, with its target" "t b.pkg.tar.zst failed" "$(awk -F '\t' '$3 == "failed" { print $1 " " $2 " " $3 }' "$work/all.tsv")" "lib.sh reconcile_results"

#---------------------------------------------------------------------------#
# How work is split: shards per target, verify batches per target
#---------------------------------------------------------------------------#
check "shards: by files" "2 2" "$(in_lib shard_count 3 1000 2 536870912 32)" "lib.sh shard_count"
check "shards: x86_64 extra's seed wants 216 by bytes and gets MAX_SHARDS" "32 216" \
  "$(in_lib shard_count 15041 115541940123 400 536870912 32)" "lib.sh shard_count"
check "shards: never more than files" "1 3" "$(in_lib shard_count 1 1610612736 400 536870912 32)" "lib.sh shard_count"
check "shards: no file, no shard" "0 0" "$(in_lib shard_count 0 0 400 536870912 32)" "lib.sh shard_count"
check "batches: under the cap, the limits stay" "1 400 2147483648 1" "$(in_lib batch_count 3 1000 400 2147483648 40)" "lib.sh batch_count"
read -r k flimit blimit wanted <<< "$(in_lib batch_count 15041 115541940123 400 2147483648 40)"
if [ "$wanted" -eq 54 ] && [ "$k" -le 40 ] && [ "$k" -ge 36 ] && [ "$flimit" -gt 400 ] && [ "$blimit" -gt 2147483648 ]; then
  ok "batches: x86_64 extra's seed wants 54, both limits grow, and it gets 36 to 40 ($k, $flimit files, $blimit bytes)"
else
  fail "batches: x86_64 extra's seed wants 54, both limits grow, and it gets 36 to 40" "$k $flimit $blimit $wanted" "lib.sh batch_count"
fi
check "a build date as ISO 8601 UTC" 2023-11-14T22:13:20Z "$(in_lib iso_of_epoch 1700000000)" "lib.sh iso_of_epoch"
rc=0
in_lib iso_of_epoch 17x > /dev/null 2>&1 || rc=$?
check "a build date that is not a number is refused" 1 "$rc" "lib.sh iso_of_epoch"

#---------------------------------------------------------------------------#
# Why pacman refused one package. The logs are pacman 7.1's own words,
# measured in the integration suite on 2026-10-14.
#---------------------------------------------------------------------------#
reason() {
  printf '%s\n' "$2" > "$work/one.log"
  in_lib refusal_reason "$work/one.log" "${3:-0}" "${4:-0}" | cut -f 1 > "$work/reason"
  check "refusal: $1" "$5" "$(cat "$work/reason")" "lib.sh refusal_reason"
}
reason "a primary key that expired is a signature reason" \
  "$(printf '%s\n' 'checking keyring...' 'downloading required keys...' \
    ':: Import PGP key 2CD2A1B4BDFA4272, "x"? [Y/n] error: key "2CD2A1B4BDFA4272" could not be looked up remotely' \
    'error: required key missing from keyring' 'error: failed to commit transaction (unexpected error)')" 0 0 sig-refused
reason "a signature that is not valid is a signature reason" \
  "$(printf '%s\n' 'error: alpha: signature from "mirror-archlinux test <test@example.invalid>" is invalid' \
    ':: File /var/cache/pacman/pkg/alpha-1-1-any.pkg.tar.zst is corrupted (invalid or corrupted package (PGP signature)).' \
    'error: failed to commit transaction (invalid or corrupted package (PGP signature))')" 0 0 sig-refused
reason "no .sig served for a package that is served is a missing signature" \
  "$(printf '%s\n' 'pacman-oci: unsigned-1-1-any.pkg.tar.zst.sig: no signature layer' 'error: failed to commit transaction (failed to retrieve some files)')" 0 1 sig-missing
reason "pacman's own words for a missing signature" "error: unsigned: missing required signature" 0 0 sig-missing
reason "a package the wrapper does not serve is not excused" \
  "$(printf '%s\n' 'error: failed to commit transaction (failed to retrieve some files)')" 1 1 other
reason "a checksum is not a signature reason" \
  "$(printf '%s\n' 'error: alpha: signature from "x" is unknown trust' ':: File x is corrupted (invalid or corrupted package (checksum)).')" 0 0 other
reason "an architecture is its own class, not a signature reason" \
  "$(printf '%s\n' ':: package port-1-1-aarch64 does not have a valid architecture' 'error: failed to prepare transaction (package architecture is not valid)')" 0 0 arch
reason "an architecture wins over the wrapper not serving it, so pacman's real reason is kept" \
  "$(printf '%s\n' 'error: failed to prepare transaction (package architecture is not valid)')" 1 0 arch
reason "a failure pacman names no reason for is not excused" "error: something else" 0 0 other

#---------------------------------------------------------------------------#
# Registry reads on GHCR, against a stand-in for curl: the dummy token first,
# only its 200 believed; any other answer asked again with the real token,
# which every process of a shard shares through REGISTRY_TOKEN_CACHE and
# asks for again once when the registry refuses it.
#---------------------------------------------------------------------------#
fake="$work/fake"
mkdir -p "$fake/bin"
cat > "$fake/bin/curl" << 'EOF'
#!/usr/bin/env bash
# Logs "URL<TAB>AUTH" to $FAKE/calls.log. Answers a token request that
# carries a credential (a user line on stdin, --config -) with
# $FAKE/next-token, and one with none with "anon"; when $FAKE/token-code
# exists, every token request gets that HTTP code and no token. Answers a
# manifest or a blob request from $FAKE/answers.tsv: AUTH<TAB>CODE<TAB>BODY-FILE,
# the first line whose AUTH matches. With --write-out, prints the HTTP code.
# Each call's arguments go to $FAKE/curl-args, one call per line.
printf '%s\n' "$*" >> "$FAKE/curl-args"
out="" auth="" url="" cred="" wo="" maxt="" retmax=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --header) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift 2 ;;
    --config) if [ "$2" = - ]; then cred="$(cat)"; fi; shift 2 ;;
    --write-out) wo="$2"; shift 2 ;;
    --max-time) maxt="$2"; shift 2 ;;
    --retry-max-time) retmax="$2"; shift 2 ;;
    --user | --data-urlencode | --connect-timeout | --retry | --retry-delay | \
      --max-filesize | --proto | --proto-redir | --max-redirs | --speed-limit | --speed-time | --user-agent) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\t%s\n' "$url" "$auth" >> "$FAKE/calls.log"
case "$url" in
  */token)
    # The deadlines a token request was given, and a token endpoint that
    # stalls when $FAKE/token-stall exists. exec, so the signal of timeout(1)
    # ends the sleep itself and no child holds the caller's pipe open.
    printf '%s %s\n' "${maxt:-none}" "${retmax:-none}" > "$FAKE/token-args"
    if [ -f "$FAKE/token-stall" ]; then
      exec sleep 60 > /dev/null
    fi
    if [ -f "$FAKE/token-code" ]; then
      printf '{"errors":[{"code":"DENIED"}]}' > "$out"
      code="$(cat "$FAKE/token-code")"
    else
      case "$cred" in
        *'user = '*) printf '{"token":"%s"}' "$(cat "$FAKE/next-token")" > "$out" ;;
        *) printf '{"token":"anon"}' > "$out" ;;
      esac
      code=200
    fi
    ;;
  */manifests/* | */blobs/*)
    # The deadlines a manifest request was given, and a manifest server that
    # stalls when $FAKE/manifest-stall exists, as for a token request.
    case "$url" in
      */manifests/*)
        printf '%s %s\n' "${maxt:-none}" "${retmax:-none}" > "$FAKE/manifest-args"
        if [ -f "$FAKE/manifest-stall" ]; then
          exec sleep 60 > /dev/null
        fi
        ;;
    esac
    line="$(awk -F '\t' -v a="$auth" '$1 == a && !f { print $2 "\t" $3; f = 1 }' "$FAKE/answers.tsv")"
    if [ -z "$line" ]; then
      [ -z "$wo" ] || printf '000'
      exit 7
    fi
    cp "$FAKE/${line#*$'\t'}" "$out"
    code="${line%%$'\t'*}"
    ;;
esac
[ -z "$wo" ] || printf '%s' "$code"
EOF
chmod +x "$fake/bin/curl"
printf '{"schemaVersion":2,"layers":[]}' > "$fake/manifest.json"
printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' > "$fake/unknown.json"
printf '{"errors":[{"code":"UNAUTHORIZED"}]}' > "$fake/denied.json"
printf 'service unavailable' > "$fake/busy.txt"
printf 'the bytes of one blob\n' > "$fake/blob.bin"
BLOB="sha256:$(sha256sum "$fake/blob.bin" | cut -d ' ' -f 1)"
printf 'other bytes\n' > "$fake/other.bin"
# reg NAME ANSWERS [CACHE] -> "STATUS CALLS TOKEN-CALLS", one registry_manifest;
# its REG_LAST_CODE in $fake/last-code. REG_READ=blob reads the blob $BLOB.
reg() {
  local rc=0
  printf '%b' "$2" > "$fake/answers.tsv"
  : > "$fake/calls.log"
  FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY="${REG_REGISTRY:-ghcr.io}" MIRROR_REGISTRY_AUTH=token MIRROR_REGISTRY_SCHEME=https \
    REGISTRY_TOKEN="${REG_TOKEN-secret}" REGISTRY_TOKEN_CACHE="${3:-}" \
    bash -c '. "$1"; rc=0
      if [ "$2" = blob ]; then registry_blob it/repo "$5" "$3" || rc=$?
      else registry_manifest it/repo latest "$3" || rc=$?; fi
      printf "%s\n" "$REG_LAST_CODE" > "$4"; exit "$rc"' _ "$LIB" "${REG_READ:-manifest}" "$fake/out.json" "$fake/last-code" "$BLOB" \
    > /dev/null 2> "$fake/err" || rc=$?
  printf '%s %s %s\n' "$rc" "$(awk 'END { print NR + 0 }' "$fake/calls.log")" "$(awk -F '\t' '$1 ~ /\/token$/ { n++ } END { print n + 0 }' "$fake/calls.log")"
}
echo tok1 > "$fake/next-token"
check "registry: the dummy token's 200 is the answer, and no token is asked for" "0 1 0" \
  "$(reg ok 'Bearer QQ==\t200\tmanifest.json\n')" "lib.sh registry_manifest"
check "registry: the dummy token's 404 is asked again with the real token, which finds it" "0 3 1" \
  "$(reg private 'Bearer QQ==\t404\tunknown.json\nBearer tok1\t200\tmanifest.json\n')" "lib.sh registry_manifest"
check "registry: absent only when the real token says so too" "4 3 1" \
  "$(reg absent 'Bearer QQ==\t404\tunknown.json\nBearer tok1\t404\tunknown.json\n')" "lib.sh registry_manifest"
check "registry: with no token of its own, the dummy token's 404 is the answer" "4 1 0" \
  "$(REG_TOKEN='' reg anonymous 'Bearer QQ==\t404\tunknown.json\n')" "lib.sh registry_manifest"
mkdir -m 0700 "$fake/cache"
answers='Bearer QQ==\t404\tunknown.json\nBearer tok1\t200\tmanifest.json\n'
reg first "$answers" "$fake/cache" > /dev/null
check "registry: a second process reads the token the first one cached" "0 2 0" \
  "$(reg second "$answers" "$fake/cache")" "lib.sh registry_manifest, REGISTRY_TOKEN_CACHE"
echo tok2 > "$fake/next-token"
check "registry: a cached token the registry refuses is asked for again, once" "0 4 1" \
  "$(reg refresh 'Bearer QQ==\t404\tunknown.json\nBearer tok1\t401\tdenied.json\nBearer tok2\t200\tmanifest.json\n' "$fake/cache")" \
  "lib.sh registry_manifest, REGISTRY_TOKEN_CACHE"
check "registry: the cache then holds the new token" tok2 "$(cat "$fake"/cache/* 2> /dev/null)" "ls $fake/cache"

# On a token registry other than GHCR there is no dummy token: an anonymous
# read asks the token endpoint with no credential. It must never send the
# token an authenticated read cached, or a private package reads as public.
mkdir -m 0700 "$fake/cache-other"
echo tok1 > "$fake/next-token"
answers='Bearer tok1\t200\tmanifest.json\nBearer anon\t401\tdenied.json\n'
check "registry, another registry: an authenticated read caches its token and reads the private package" "0 2 1" \
  "$(REG_REGISTRY=registry.example reg auth "$answers" "$fake/cache-other")" "lib.sh registry_manifest, REGISTRY_TOKEN_CACHE"
check "registry, another registry: the anonymous read after it asks for a token of its own, and is refused" "1 2 1" \
  "$(REG_REGISTRY=registry.example REG_TOKEN='' reg anon "$answers" "$fake/cache-other")" \
  "lib.sh registry_token_file must give no cache file when REGISTRY_TOKEN is empty; cat $fake/calls.log"
check "registry, another registry: the anonymous read sent no cached token" "Bearer anon" \
  "$(awk -F '\t' '$1 ~ /manifests/ { print $2 }' "$fake/calls.log")" "cat $fake/calls.log"
check "registry, another registry: the cache holds only the authenticated token" tok1 "$(cat "$fake"/cache-other/*)" "ls $fake/cache-other"

# GHCR does not document Bearer QQ==. When it refuses it, an anonymous read
# asks the anonymous token flow once, says so, and reads on. The anonymous
# token is never cached.
for c in 401 403; do
  mkdir -m 0700 "$fake/cache-anon-$c"
  check "registry, anonymous: GHCR refuses QQ== with $c, and the anonymous token reads the manifest" "0 3 1 200" \
    "$(REG_TOKEN='' reg "qq$c" "Bearer QQ==\t$c\tdenied.json\nBearer anon\t200\tmanifest.json\n" "$fake/cache-anon-$c") $(cat "$fake/last-code")" \
    "lib.sh registry_manifest with REGISTRY_TOKEN empty; cat $fake/calls.log $fake/err"
  if grep -q "GHCR refused Bearer QQ== for it/repo (HTTP $c); the anonymous token flow was used" "$fake/err"; then
    ok "registry, anonymous: the refusal of QQ== with $c is named in a warning"
  else
    fail "registry, anonymous: the refusal of QQ== with $c is named in a warning" "stderr: $(cat "$fake/err")" "lib.sh registry_manifest"
  fi
  check "registry, anonymous: the anonymous token is not cached" "" "$(ls "$fake/cache-anon-$c")" "ls $fake/cache-anon-$c"
done
check "registry, anonymous: an answer of QQ== other than 401 and 403 is the answer, with no token asked" "1 1 0 503" \
  "$(REG_TOKEN='' reg qq503 'Bearer QQ==\t503\tbusy.txt\n') $(cat "$fake/last-code")" "lib.sh registry_manifest; cat $fake/calls.log"
# The token endpoint refuses the anonymous pull scope of a repository GHCR
# does not show (403, measured): absent, as the 404 of QQ== says today.
printf '403\n' > "$fake/token-code"
check "registry, anonymous: a token endpoint that refuses the repository is absent, with its code" "4 2 1 403" \
  "$(REG_TOKEN='' reg qqdenied 'Bearer QQ==\t401\tdenied.json\n') $(cat "$fake/last-code")" "lib.sh registry_manifest; cat $fake/calls.log $fake/err"
printf '503\n' > "$fake/token-code"
check "registry, anonymous: a token endpoint that fails is an error, not an absence" "1 2 1 503" \
  "$(REG_TOKEN='' reg qqtokenfail 'Bearer QQ==\t401\tdenied.json\n') $(cat "$fake/last-code")" "lib.sh registry_manifest; cat $fake/calls.log $fake/err"
# Only the measured 403 is an absence. A 401 of the token endpoint is not
# measured, and is an error.
printf '401\n' > "$fake/token-code"
check "registry, anonymous: a token endpoint that answers 401 is an error, not an absence" "1 2 1 401" \
  "$(REG_TOKEN='' reg qqtoken401 'Bearer QQ==\t401\tdenied.json\n') $(cat "$fake/last-code")" "lib.sh registry_manifest; cat $fake/calls.log $fake/err"
printf '403\n' > "$fake/token-code"
check "registry, with a token: a token endpoint that refuses is an error, never an absence" "1 2 1 403" \
  "$(reg authdenied 'Bearer QQ==\t404\tunknown.json\n') $(cat "$fake/last-code")" \
  "lib.sh registry_manifest; cat $fake/calls.log $fake/err"
# registry_token, which status-collect calls: GHCR gives no anonymous token
# for a repository it does not show, such as a target with no push yet. QQ==
# is given instead, with which GHCR answers 404, so the target reads as absent.
# token NAME -> "STATUS TOKEN" of registry_token it/repo pull, anonymous
token() {
  local rc=0 t
  t="$(FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY=ghcr.io MIRROR_REGISTRY_AUTH=token MIRROR_REGISTRY_SCHEME=https \
    REGISTRY_TOKEN='' in_lib registry_token it/repo pull 2> "$fake/err")" || rc=$?
  printf '%s %s\n' "$rc" "$t"
}
check "registry_token, anonymous: GHCR refuses the repository (403): QQ==, which reads it as absent" "0 QQ==" \
  "$(token denied)" "bash -c '. scripts/lib.sh; registry_token it/repo pull'; cat $fake/err"
printf '503\n' > "$fake/token-code"
check "registry_token, anonymous: a token endpoint that fails gives no token" "1 " \
  "$(token failing)" "bash -c '. scripts/lib.sh; registry_token it/repo pull'; cat $fake/err"
printf '401\n' > "$fake/token-code"
check "registry_token, anonymous: a token endpoint that answers 401 gives no token, not QQ==" "1 " \
  "$(token unauthorized)" "bash -c '. scripts/lib.sh; registry_token it/repo pull'; cat $fake/err"
rm -f "$fake/token-code"
check "registry_token, anonymous: the token endpoint's anonymous token" "0 anon" \
  "$(token granted)" "bash -c '. scripts/lib.sh; registry_token it/repo pull'; cat $fake/err"
check "registry_token: the token request gets REG_TOKEN_MAX_TIME, 90 s by default, as --max-time and --retry-max-time" \
  "90 90" "$(cat "$fake/token-args")" "bash -c '. scripts/lib.sh; registry_token it/repo pull' with curl logging its arguments"

# A token endpoint that stalls. status-collect asks once for every target, so
# the whole call has to end within REG_TOKEN_MAX_TIME, retries included, and
# timeout(1) ends it when curl does not.
touch "$fake/token-stall"
t_started=$SECONDS
t_res="$(REG_TOKEN_MAX_TIME=2 token stalled)"
t_took=$((SECONDS - t_started))
rm -f "$fake/token-stall"
check "registry_token: a token endpoint that stalls is given up within REG_TOKEN_MAX_TIME, and gives no token" \
  "1 , within 15 s" "$t_res, $([ "$t_took" -lt 15 ] && echo 'within 15 s' || echo "after $t_took s")" \
  "REG_TOKEN_MAX_TIME=2 bash -c '. scripts/lib.sh; registry_token it/repo pull' against a token endpoint that does not answer"
rc=0
REG_TOKEN_MAX_TIME=soon FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY=ghcr.io MIRROR_REGISTRY_AUTH=token \
  MIRROR_REGISTRY_SCHEME=https REGISTRY_TOKEN='' in_lib registry_token it/repo pull > /dev/null 2>&1 || rc=$?
check "registry_token: a REG_TOKEN_MAX_TIME that is not a number of seconds is refused" "refused" \
  "$([ "$rc" -ne 0 ] && echo refused || echo "accepted (status $rc)")" "REG_TOKEN_MAX_TIME=soon bash -c '. scripts/lib.sh; registry_token it/repo pull'"

# A manifest server that stalls. With REG_MANIFEST_MAX_TIME, as plan sets it
# for each read of REGISTRY_READ_BUDGET, the whole request ends within it,
# retries included, and timeout(1) ends it when curl does not. With none set,
# a request keeps --max-time 60 and no --retry-max-time.
REG_TOKEN='' reg ok 'Bearer QQ==\t200\tmanifest.json\n' > /dev/null
check "registry_manifest: with no REG_MANIFEST_MAX_TIME, a manifest request gets --max-time 60 and no --retry-max-time" \
  "60 none" "$(cat "$fake/manifest-args")" "bash -c '. scripts/lib.sh; registry_manifest it/repo latest OUT' with curl logging its arguments"
REG_MANIFEST_MAX_TIME=2 REG_TOKEN='' reg ok 'Bearer QQ==\t200\tmanifest.json\n' > /dev/null
check "registry_manifest: REG_MANIFEST_MAX_TIME=2 gives a manifest request --max-time 2 and --retry-max-time 2" \
  "2 2" "$(cat "$fake/manifest-args")" "REG_MANIFEST_MAX_TIME=2 bash -c '. scripts/lib.sh; registry_manifest it/repo latest OUT'"
touch "$fake/manifest-stall"
m_started=$SECONDS
m_res="$(REG_MANIFEST_MAX_TIME=2 REG_TOKEN='' reg stalled 'Bearer QQ==\t200\tmanifest.json\n')"
m_took=$((SECONDS - m_started))
rm -f "$fake/manifest-stall"
check "registry_manifest: a manifest server that stalls is given up within REG_MANIFEST_MAX_TIME and 5 s, with no answer" \
  "1 1 0, within 15 s" "$m_res, $([ "$m_took" -lt 15 ] && echo 'within 15 s' || echo "after $m_took s")" \
  "REG_MANIFEST_MAX_TIME=2 bash -c '. scripts/lib.sh; registry_manifest it/repo latest OUT' against a manifest server that does not answer"
rc=0
rm -f "$fake/manifest-args"
REG_MANIFEST_MAX_TIME=soon FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY=ghcr.io MIRROR_REGISTRY_AUTH=token \
  MIRROR_REGISTRY_SCHEME=https REGISTRY_TOKEN='' in_lib registry_manifest it/repo latest "$fake/out.json" > /dev/null 2>&1 || rc=$?
check "registry_manifest: a REG_MANIFEST_MAX_TIME that is not a number of seconds is refused, with no request" "refused" \
  "$([ "$rc" -ne 0 ] && [ ! -e "$fake/manifest-args" ] && echo refused || echo "accepted (status $rc)")" \
  "REG_MANIFEST_MAX_TIME=soon bash -c '. scripts/lib.sh; registry_manifest it/repo latest OUT'"

# Blobs: the same on GHCR with no credential; with REGISTRY_TOKEN, the real
# token at once; a blob whose bytes are not its digest is refused.
check "registry blob, anonymous: the dummy token's 200 is the answer" "0 1 0" \
  "$(REG_READ=blob REG_TOKEN='' reg blobqq 'Bearer QQ==\t200\tblob.bin\n')" "lib.sh registry_blob; cat $fake/calls.log"
check "registry blob, anonymous: GHCR refuses QQ==, and the anonymous token reads the blob" "0 3 1" \
  "$(REG_READ=blob REG_TOKEN='' reg blob401 'Bearer QQ==\t401\tdenied.json\nBearer anon\t200\tblob.bin\n')" \
  "lib.sh registry_blob; cat $fake/calls.log $fake/err"
if grep -q 'GHCR refused Bearer QQ== for it/repo (HTTP 401); the anonymous token flow was used' "$fake/err"; then
  ok "registry blob, anonymous: the refusal of QQ== is named in a warning"
else
  fail "registry blob, anonymous: the refusal of QQ== is named in a warning" "stderr: $(cat "$fake/err")" "lib.sh registry_blob"
fi
echo tok1 > "$fake/next-token"
check "registry blob, with a token: the real token at once" "0 2 1" \
  "$(REG_READ=blob reg blobauth 'Bearer tok1\t200\tblob.bin\n')" "lib.sh registry_blob; cat $fake/calls.log"
check "registry blob: bytes that are not the digest are refused, and not left behind" "1 absent" \
  "$(REG_READ=blob REG_TOKEN='' reg blobbad 'Bearer QQ==\t200\tother.bin\n' | cut -d ' ' -f 1) $([ -e "$fake/out.json" ] && echo present || echo absent)" \
  "lib.sh registry_blob; cat $fake/err"
check "registry blob: a 404 is refused" "1" \
  "$(REG_READ=blob REG_TOKEN='' reg blob404 'Bearer QQ==\t404\tunknown.json\n' | cut -d ' ' -f 1)" "lib.sh registry_blob; cat $fake/err"

#---------------------------------------------------------------------------#
# registry_blob_probe: a package blob from a registry repository, one source
# of mirror-file. 0 read and checked, 4 not there (quiet), 5 limited, 1
# anything else.
#---------------------------------------------------------------------------#
printf '{"errors":[{"code":"BLOB_UNKNOWN"}]}' > "$fake/blob-unknown.json"
printf '{"errors":[{"code":"NAME_UNKNOWN"}]}' > "$fake/name-unknown.json"
printf '{"errors":[{"code":"TOOMANYREQUESTS"}]}' > "$fake/toomany.json"
BLOB_SIZE="$(wc -c < "$fake/blob.bin" | tr -d ' ')"
# probe NAME ANSWERS [CSIZE] -> "STATUS LINES OUT", LINES the lines of
# stderr, OUT whether the output file is there; REG_TOKEN as in reg
probe() {
  local rc=0
  printf '%b' "$2" > "$fake/answers.tsv"
  : > "$fake/calls.log"
  : > "$fake/curl-args"
  rm -f "$fake/probe.out"
  FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY=ghcr.io MIRROR_REGISTRY_AUTH=token MIRROR_REGISTRY_SCHEME=https \
    REGISTRY_TOKEN="${REG_TOKEN-secret}" \
    bash -c '. "$1"; registry_blob_probe it/sib "$2" "$3" 30 "$4" || exit $?' _ "$LIB" "$BLOB" "$fake/probe.out" "${3:-$BLOB_SIZE}" \
    > /dev/null 2> "$fake/err" || rc=$?
  printf '%s %s %s\n' "$rc" "$(awk 'END { print NR + 0 }' "$fake/err")" "$([ -e "$fake/probe.out" ] && echo kept || echo none)"
}
PB="bash -c '. scripts/lib.sh; registry_blob_probe it/sib DIGEST OUT 30 CSIZE' against a curl stand-in; cat $fake/err"
check "registry_blob_probe: the blob of the right size and digest is 0, quietly" "0 0 kept" \
  "$(REG_TOKEN='' probe ok 'Bearer QQ==\t200\tblob.bin\n')" "$PB"
check "registry_blob_probe, with a token: the real token reads it" "0 0 kept" \
  "$(probe auth 'Bearer tok1\t200\tblob.bin\n')" "$PB"
check "registry_blob_probe: 404 BLOB_UNKNOWN is 4, with no line" "4 0 none" \
  "$(REG_TOKEN='' probe blobunknown 'Bearer QQ==\t404\tblob-unknown.json\n')" "$PB"
check "registry_blob_probe: 404 NAME_UNKNOWN is 4, with no line" "4 0 none" \
  "$(probe nameunknown 'Bearer tok1\t404\tname-unknown.json\n')" "$PB"
check "registry_blob_probe: a 404 with another code is 1" "1 1 none" \
  "$(REG_TOKEN='' probe otherunknown 'Bearer QQ==\t404\tunknown.json\n')" "$PB"
check "registry_blob_probe: 429 is 5" "5 1 none" \
  "$(probe limited 'Bearer tok1\t429\ttoomany.json\n')" "$PB"
check "registry_blob_probe: 503 is 1" "1 1 none" \
  "$(probe busy 'Bearer tok1\t503\tbusy.txt\n')" "$PB"
check "registry_blob_probe: bytes of another size are refused, and not left behind" "1 1 none" \
  "$(probe size 'Bearer tok1\t200\tother.bin\n')" "$PB"
check "registry_blob_probe: bytes of the right size and another digest are refused" "1 1 none" \
  "$(probe digest 'Bearer tok1\t200\tother.bin\n' "$(wc -c < "$fake/other.bin" | tr -d ' ')")" "$PB"
check "registry_blob_probe: the right bytes with another CSIZE are refused" "1 1 none" \
  "$(probe csize 'Bearer tok1\t200\tblob.bin\n' 7)" "$PB"
check "registry_blob_probe: the request stops at CSIZE bytes (--max-filesize)" "--max-filesize $BLOB_SIZE" \
  "$(REG_TOKEN='' probe args 'Bearer QQ==\t200\tblob.bin\n' > /dev/null; grep -o -- "--max-filesize $BLOB_SIZE" "$fake/curl-args" | sed -n 1p)" \
  "$PB; cat $fake/curl-args"
printf '403\n' > "$fake/token-code"
check "registry_blob_probe, anonymous: GHCR refuses QQ== and gives no token for the repository (403): 4" "4" \
  "$(REG_TOKEN='' probe denied 'Bearer QQ==\t401\tdenied.json\n' | cut -d ' ' -f 1)" "$PB"
printf '429\n' > "$fake/token-code"
check "registry_blob_probe: a token endpoint that answers 429 is 5" "5" \
  "$(probe tokenlimited 'Bearer tok1\t200\tblob.bin\n' | cut -d ' ' -f 1)" "$PB"
rm -f "$fake/token-code"

#---------------------------------------------------------------------------#
# A 429, in the registry's words and in oras's own
#---------------------------------------------------------------------------#
limited() {
  local rc=0
  printf '%s\n' "$2" > "$work/push.log"
  in_lib rate_limited "$work/push.log" || rc=$?
  check "rate limit: $1" "$3" "$rc" "bash -c '. scripts/lib.sh; rate_limited LOG' with LOG: $2"
}
limited "oras's words for a 429 with no body" \
  'Error: failed to push: PUT "https://ghcr.io/v2/x/manifests/t": response status code 429: Too Many Requests' 0
limited "the registry's error code" \
  'Error: failed to push: toomanyrequests: retry-after: 680.79µs, allowed: 2000/minute' 0
limited "an error that is not a 429" \
  'Error: failed to push: PUT "https://ghcr.io/v2/x/manifests/t": response status code 500: Internal Server Error' 1

#---------------------------------------------------------------------------#
# Servers that failed: asked last, the rest in their own order
#---------------------------------------------------------------------------#
down="$work/down"
order_of() {
  in_lib down_last "$down" https://a.example/r https://b.example/r/x https://c.example:8443/r https://c.example/r | tr '\n' ' ' | sed 's/ $//'
}
check "down: with no host marked, the order is kept" \
  "https://a.example/r https://b.example/r/x https://c.example:8443/r https://c.example/r" "$(order_of)" "lib.sh down_last"
in_lib down_mark "$down" https://b.example/other/path
in_lib down_mark "$down" https://c.example:8443/z
check "down: a host that failed comes last, by its host and port, and the rest keep their order" \
  "https://a.example/r https://c.example/r https://b.example/r/x https://c.example:8443/r" "$(order_of)" "lib.sh down_mark, down_last"

#---------------------------------------------------------------------------#
# "Re-run all jobs" plans again, and a download by name or pattern still
# returns the earlier attempt's artifacts. The report reads only the summaries
# of its own plan, for targets its plan marks pending; collect reads only the
# verdicts and the promotion of the staged digest.
#---------------------------------------------------------------------------#
rr="$work/rerun"
mkdir -p "$rr/plan" "$rr/sum/x86_64-core" "$rr/sum/x86_64-extra" "$rr/sum/x86_64-multilib"
printf 'plan-2\n' > "$rr/plan/plan-id"
{
  printf 'target\tstate\tfiles\tMiB\twhy\n'
  printf 'x86_64-core\tpending\t1\t1\t1 file(s) to mirror\n'
  printf 'x86_64-extra\tcurrent\t0\t0\tthe promoted extra.db is upstream'\''s\n'
  printf 'x86_64-multilib\tpending\t1\t1\t1 file(s) to mirror\n'
} > "$rr/plan/summary.tsv"
printf 'x86_64-core\tpromoted\tsha256:new 2026.10.14 latest\n' > "$rr/sum/x86_64-core/state.tsv"
printf 'plan-2\n' > "$rr/sum/x86_64-core/plan-id"
# Left by attempt 1: extra was replaced then, and the issue was resolved since.
printf 'x86_64-extra\treplaced\t1 file(s) have a tag holding other bytes\n' > "$rr/sum/x86_64-extra/state.tsv"
printf 'plan-1\n' > "$rr/sum/x86_64-extra/plan-id"
# Left by attempt 1 too: this attempt's chain of multilib left no summary.
printf 'x86_64-multilib\tpromoted\tsha256:old latest\n' > "$rr/sum/x86_64-multilib/state.tsv"
printf 'plan-1\n' > "$rr/sum/x86_64-multilib/plan-id"
rc=0
env -u GITHUB_STEP_SUMMARY TRACK_ISSUES=0 bash "$REPO_ROOT/scripts/report" "$rr/plan" "$rr/sum" > "$rr/table.md" 2> "$rr/report.err" || rc=$?
check "re-run: a summary of an earlier plan is not read for a target this plan finds current" "| x86_64-extra | current |" \
  "$(grep -o '^| x86_64-extra | [a-z]* |' "$rr/table.md")" "scripts/report PLAN SUMMARIES; cat $rr/table.md $rr/report.err"
check "re-run: a pending target whose chain left only an earlier plan's summary failed" "| x86_64-multilib | failed |" \
  "$(grep -o '^| x86_64-multilib | [a-z]* |' "$rr/table.md")" "scripts/report PLAN SUMMARIES; cat $rr/table.md"
check "re-run: the summary of this plan is read" "| x86_64-core | promoted |" \
  "$(grep -o '^| x86_64-core | [a-z]* |' "$rr/table.md")" "scripts/report PLAN SUMMARIES; cat $rr/table.md"
check "re-run: the report fails the run for the target with no summary of this plan, and only for it" "1 0" \
  "$rc $(awk '/replaced/ { n++ } END { print n + 0 }' "$rr/table.md")" "scripts/report PLAN SUMMARIES; cat $rr/table.md"
# A summary of this very plan counts only for a target the plan marks pending.
printf 'plan-2\n' > "$rr/sum/x86_64-extra/plan-id"
rc=0
env -u GITHUB_STEP_SUMMARY TRACK_ISSUES=0 bash "$REPO_ROOT/scripts/report" "$rr/plan" "$rr/sum" > "$rr/table.md" 2> "$rr/report.err" || rc=$?
check "re-run: a chain's word applies only to a target the plan marks pending" "| x86_64-extra | current |" \
  "$(grep -o '^| x86_64-extra | [a-z]* |' "$rr/table.md")" "scripts/report PLAN SUMMARIES; cat $rr/table.md"

# collect: this attempt staged sha256:new in one batch, and it passed. Attempt
# 1 left a failed verdict of a batch 5, its refusal, and a promotion, all of
# sha256:old.
mkdir -p "$rr/stage/x86_64-core/batches" "$rr/verify/verify-x86_64-core-0" "$rr/verify/verify-x86_64-core-5"
printf 'staged\n' > "$rr/stage/x86_64-core/state"
printf 'it/x86_64/core@sha256:new\n' > "$rr/stage/x86_64-core/why"
printf 'DIGEST=sha256:new\n' > "$rr/stage/x86_64-core/staged.env"
printf 'a\n' > "$rr/stage/x86_64-core/batches/0.txt"
printf 'plan-2\n' > "$rr/stage/x86_64-core/plan-id"
printf 'x86_64-core\t0\tpassed\t1 package(s)\tsha256:new\n' > "$rr/verify/verify-x86_64-core-0/verify-x86_64-core-0.tsv"
printf 'x86_64-core\t5\tfailed\tbatch 5 failed\tsha256:old\n' > "$rr/verify/verify-x86_64-core-5/verify-x86_64-core-5.tsv"
printf 'stale-1-1-any.pkg.tar.zst\tsig-missing: x\n' > "$rr/verify/verify-x86_64-core-5/refused-x86_64-core-5.tsv"
printf 'x86_64-core\tpromoted\tsha256:old 2026.10.13 latest\n' > "$rr/promote-old.tsv"
rc=0
bash "$REPO_ROOT/scripts/report" collect x86_64-core "$rr/stage" "$rr/verify" "$rr/promote-old.tsv" "$rr/out/x86_64-core" 2> "$rr/collect.err" || rc=$?
check "re-run: collect reads no verdict, refusal or promotion of another digest" "0 staged 0 plan-2" \
  "$rc $(cut -f 2 "$rr/out/x86_64-core/state.tsv") $(awk 'END { print NR + 0 }' "$rr/out/x86_64-core/refused.tsv") $(cat "$rr/out/x86_64-core/plan-id")" \
  "scripts/report collect x86_64-core STAGE VERIFY PROMOTED OUT; cat $rr/collect.err"
printf 'x86_64-core\tpromoted\tsha256:new 2026.10.14 latest\n' > "$rr/promote-new.tsv"
rc=0
bash "$REPO_ROOT/scripts/report" collect x86_64-core "$rr/stage" "$rr/verify" "$rr/promote-new.tsv" "$rr/out2/x86_64-core" 2> "$rr/collect.err" || rc=$?
check "re-run: collect takes the promotion of the staged digest" "0 promoted" \
  "$rc $(cut -f 2 "$rr/out2/x86_64-core/state.tsv")" "scripts/report collect x86_64-core STAGE VERIFY PROMOTED OUT; cat $rr/collect.err"

#---------------------------------------------------------------------------#
# fetch_upstream names an answer that says nothing about the file: its HTTP
# code, and Cloudflare's cf-mitigated header when there is one. A 404 or a
# 410 is quiet: mirror-file asks for many .sig files that are not there.
#---------------------------------------------------------------------------#
upf="$work/upstream-fake"
mkdir -p "$upf/bin"
cat > "$upf/bin/curl" << 'EOF'
#!/usr/bin/env bash
# Answers HTTP $UP_CODE with the header cf-mitigated: $UP_CF when it is not
# empty, and a body; prints --write-out with %{http_code},
# %header{cf-mitigated} and \t replaced.
out="" wo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --write-out) wo="$2"; shift 2 ;;
    --proto | --proto-redir | --max-redirs | --connect-timeout | --speed-limit | --speed-time | --max-time | \
      --retry-max-time | --retry | --retry-delay | --user-agent) shift 2 ;;
    *) shift ;;
  esac
done
printf 'a body\n' > "$out"
wo="${wo//%\{http_code\}/$UP_CODE}"
wo="${wo//%header\{cf-mitigated\}/$UP_CF}"
printf '%s' "${wo//\\t/$'\t'}"
EOF
chmod +x "$upf/bin/curl"
# upstream CODE CF -> "STATUS LINES", LINES the lines fetch_upstream wrote to
# stderr, which are in $upf/err
upstream() {
  local rc=0
  UP_CODE="$1" UP_CF="$2" PATH="$upf/bin:$PATH" in_lib fetch_upstream https://db.example/extra/os/loong64/extra.db "$upf/out" 30 \
    > /dev/null 2> "$upf/err" || rc=$?
  printf '%s %s\n' "$rc" "$(awk 'END { print NR + 0 }' "$upf/err")"
}
UPR="bash -c '. scripts/lib.sh; fetch_upstream URL OUT 30' against a curl that answers"
check "fetch_upstream: a 403 with a Cloudflare challenge is status 1, with one line" "1 1" "$(upstream 403 challenge)" "$UPR 403"
check "fetch_upstream: the line names the URL, HTTP 403 and the challenge" \
  "fetch_upstream: https://db.example/extra/os/loong64/extra.db answered HTTP 403 (cf-mitigated: challenge)" \
  "$(sed -n 1p "$upf/err" | sed 's/^[^:]*: /fetch_upstream: /')" "$UPR 403; cat $upf/err"
check "fetch_upstream: a 503 with no cf-mitigated header is named with its code alone" "1 answered HTTP 503" \
  "$(upstream 503 '' | cut -d ' ' -f 1) $(sed -n 's/^.* \(answered HTTP [0-9]*\)$/\1/p' "$upf/err")" "$UPR 503; cat $upf/err"
check "fetch_upstream: a 404 is status 4, with no line" "4 0" "$(upstream 404 '')" "$UPR 404"
check "fetch_upstream: a 410 is status 4, with no line" "4 0" "$(upstream 410 '')" "$UPR 410"
check "fetch_upstream: a 200 is status 0, with no line, and the body is kept" "0 0 a body" \
  "$(upstream 200 '') $(cat "$upf/out" 2> /dev/null)" "$UPR 200"

#---------------------------------------------------------------------------#
# fetch_upstream with MAX_SECONDS ends within it, its retries included: a
# server that sends 16 KiB/s, above the 4096 B/s stall floor, is asked once.
# curl gives each retry a new --max-time; without --retry-max-time the call
# took 3 x MAX + 4 s.
#---------------------------------------------------------------------------#
if need_tool python3 "fetch_upstream: a server that trickles is given up within MAX_SECONDS, with one request"; then
  cat > "$work/trickle.py" << 'EOF'
import socket, sys, threading, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
def serve(c):
    try:
        c.recv(65536)
        with open(sys.argv[1], "a") as f:
            f.write("hit\n")
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 104857600\r\n\r\n")
        while True:
            c.sendall(b"\0" * 8192)
            time.sleep(0.5)
    except OSError:
        pass
    finally:
        c.close()
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
EOF
  : > "$work/trickle.hits"
  python3 -I "$work/trickle.py" "$work/trickle.hits" > "$work/trickle.port" 2> "$work/trickle.err" &
  trickle_pid=$!
  trap 'kill "$trickle_pid"; rm -rf "$work"' EXIT
  port=""
  for _ in $(seq 1 50); do
    port="$(sed -n 1p "$work/trickle.port")"
    [ -z "$port" ] || break
    sleep 0.1
  done
  started=$SECONDS
  rc=0
  UPSTREAM_PROTO='=http,https' in_lib fetch_upstream "http://127.0.0.1:$port/big.db" "$work/trickle.out" 3 > /dev/null 2>&1 || rc=$?
  took=$((SECONDS - started))
  # A blob read from the registry ends within REG_BLOB_MAX_TIME the same way.
  : > "$work/trickle.blob-hits"
  cp "$work/trickle.hits" "$work/trickle.upstream-hits"
  : > "$work/trickle.hits"
  b_started=$SECONDS
  b_rc=0
  # shellcheck disable=SC2016 # the positional parameters of the inner script
  MIRROR_REGISTRY="127.0.0.1:$port" MIRROR_REGISTRY_SCHEME=http MIRROR_REGISTRY_AUTH=none REG_BLOB_MAX_TIME=3 \
    timeout 30 bash -c '. "$1"; registry_blob it/repo "$2" "$3" || exit $?' _ "$LIB" "$BLOB" "$work/trickle.blob" > /dev/null 2>&1 || b_rc=$?
  b_took=$((SECONDS - b_started))
  cp "$work/trickle.hits" "$work/trickle.blob-hits"
  cp "$work/trickle.upstream-hits" "$work/trickle.hits"
  kill "$trickle_pid"
  trap 'rm -rf "$work"' EXIT
  # The server ends by the signal (status 143), as it should.
  wait_rc=0
  wait "$trickle_pid" || wait_rc=$?
  [ "$wait_rc" -ne 0 ] || diag "the trickle server ended with status 0 before it was stopped: $(cat "$work/trickle.err")"
  check "fetch_upstream: a server that trickles is given up within MAX_SECONDS, with one request" \
    "status 1, 1 request(s), within 8 s" \
    "status $rc, $(awk 'END { print NR + 0 }' "$work/trickle.hits") request(s), $([ "$took" -lt 8 ] && echo 'within 8 s' || echo "after $took s")" \
    "bash -c '. scripts/lib.sh; UPSTREAM_PROTO==http fetch_upstream http://127.0.0.1:$port/big.db /tmp/out 3' against $work/trickle.py ($(cat "$work/trickle.err"))"
  check "registry_blob: a blob that trickles is given up within REG_BLOB_MAX_TIME, with one request" \
    "status 1, 1 request(s), within 10 s" \
    "status $b_rc, $(awk 'END { print NR + 0 }' "$work/trickle.blob-hits") request(s), $([ "$b_took" -lt 10 ] && echo 'within 10 s' || echo "after $b_took s")" \
    "bash -c '. scripts/lib.sh; registry_blob it/repo $BLOB /tmp/out' with MIRROR_REGISTRY=127.0.0.1:$port MIRROR_REGISTRY_SCHEME=http MIRROR_REGISTRY_AUTH=none REG_BLOB_MAX_TIME=3"
fi

#---------------------------------------------------------------------------#
# fetch_upstream: MIRROR_FETCHER replaces curl, and its status is mapped
#---------------------------------------------------------------------------#
stub="$work/fetcher-stub"
cat > "$stub" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${@: -1}"
rc="${STUB_RC:-0}"
[ "$rc" != 0 ] || printf 'body\n' > "$out"
exit "$rc"
EOF
chmod 0755 "$stub"
for want in 0 4 1; do
  rm -f "$work/stub.out"
  rc=0
  STUB_RC="$want" bash -c '. "$1"; MIRROR_FETCHER="$2" fetch_upstream https://example.invalid/x.db "$3"' \
    _ "$LIB" "$stub" "$work/stub.out" > /dev/null 2>&1 || rc=$?
  wrote=removed
  [ -f "$work/stub.out" ] && wrote=kept
  check "fetch_upstream: MIRROR_FETCHER status $want, file $([ "$want" = 0 ] && echo kept || echo removed)" \
    "$want $([ "$want" = 0 ] && echo kept || echo removed)" "$rc $wrote" \
    "STUB_RC=$want bash -c '. scripts/lib.sh; MIRROR_FETCHER=$stub fetch_upstream https://example.invalid/x.db OUT'"
done

#---------------------------------------------------------------------------#
# The tags of a ref: staging and index on main, staging-<slug> and
# index-<slug> on another branch, as sync-target.yml's slug makes them
#---------------------------------------------------------------------------#
# ref_tags REF NAME [STAGING_TAG [INDEX_TAG]] -> "STAGING INDEX", or
# "refused". REF - leaves GITHUB_REF and GITHUB_REF_NAME unset.
ref_tags() {
  local out rc=0 e=(env -u GITHUB_REF -u GITHUB_REF_NAME -u STAGING_TAG -u INDEX_TAG)
  if [ "$1" != - ]; then
    e+=("GITHUB_REF=$1" "GITHUB_REF_NAME=$2")
  fi
  if [ -n "${3:-}" ]; then
    e+=("STAGING_TAG=$3")
  fi
  if [ -n "${4:-}" ]; then
    e+=("INDEX_TAG=$4")
  fi
  # shellcheck disable=SC2016 # the positional parameters of the inner script
  out="$("${e[@]}" bash -c '. "$1"; s="$(staging_tag)" && i="$(index_tag)" && printf "%s %s\n" "$s" "$i"' _ "$LIB" 2> /dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    out=refused
  fi
  printf '%s\n' "$out"
}
TAGS="bash -c '. scripts/lib.sh; staging_tag; index_tag' with GITHUB_REF and GITHUB_REF_NAME"
a39="$(printf '%*s' 39 '' | tr ' ' a)"
b20="$(printf '%*s' 20 '' | tr ' ' b)"
check "tags: no GITHUB_REF gives staging and index" "staging index" "$(ref_tags - -)" "$TAGS unset"
check "tags: main gives staging and index" "staging index" "$(ref_tags refs/heads/main main)" "$TAGS refs/heads/main"
check "tags: Feature/X_y gives staging-feature-x-y and index-feature-x-y" "staging-feature-x-y index-feature-x-y" \
  "$(ref_tags refs/heads/Feature/X_y Feature/X_y)" "$TAGS refs/heads/Feature/X_y"
check "tags: a 60-character name stops at 40 characters, with no - at the end" "staging-$a39 index-$a39" \
  "$(ref_tags "refs/heads/$a39/$b20" "$a39/$b20")" "$TAGS refs/heads/<39 a>/<20 b>"
check "tags: a name of no letter or digit gives staging-branch" "staging-branch index-branch" \
  "$(ref_tags 'refs/heads////' '///')" "$TAGS refs/heads////"
check "tags: STAGING_TAG names the index tag beside it" "staging-x index-x" \
  "$(ref_tags refs/heads/main main staging-x)" "STAGING_TAG=staging-x $TAGS"
check "tags: INDEX_TAG is used as given" "staging index-y" \
  "$(ref_tags refs/heads/main main '' index-y)" "INDEX_TAG=index-y $TAGS"
check "tags: an INDEX_TAG that is not index-<slug> is refused" refused \
  "$(ref_tags refs/heads/main main '' index_y)" "INDEX_TAG=index_y $TAGS"
check "tags: a STAGING_TAG that is not staging-<slug> is refused" refused \
  "$(ref_tags refs/heads/main main Staging)" "STAGING_TAG=Staging $TAGS"

#---------------------------------------------------------------------------#
# The verify context: one sha256 of what a verdict of verify depends on
#---------------------------------------------------------------------------#
vc="$work/vctx"
mkdir -p "$vc/root/scripts" "$vc/root/client"
cp "$REPO_ROOT/scripts/verify-batch" "$REPO_ROOT/scripts/lib.sh" "$vc/root/scripts/"
cp "$REPO_ROOT/client/pacman-oci" "$vc/root/client/"
# vconf [LINE...]: the target file, with a comment, and LINE added
vconf() {
  {
    printf '# a target\n'
    printf '%s\n' 'arch = x86_64' 'repo = core' "db_server = https://example.invalid/core/os/x86_64" 'keyring = k-keyring' "$@"
  } > "$vc/x86_64-core.conf"
}
KSHA=1111111111111111111111111111111111111111111111111111111111111111
# vrecs KEYRING_SHA KEYRING_SIG KEYRING_BUILDDATE OTHER_SHA: the records file,
# a keyring package and another package
vrecs() {
  {
    printf 'k-keyring-1-1-any.pkg.tar.zst\tk-keyring\t1-1\tany\t%s\t10\t%s\t%s\n' "$1" "$3" "$2"
    printf 'other-1-1-any.pkg.tar.zst\tother\t1-1\tany\t%s\t10\t1700000000\t\n' "$4"
  } > "$vc/records.tsv"
}
vconf
vrecs "$KSHA" c2ln 1700000000 "$SHA"
# ctx CONF RECORDS -> the verify context, with REPO_ROOT the copy in $vc/root
ctx() {
  # shellcheck disable=SC2016 # the positional parameters of the inner script
  REPO_ROOT="$vc/root" bash -c '. "$1"; verify_context "$2" "$3"' _ "$LIB" "$1" "$2"
}
VC="REPO_ROOT=COPY bash -c '. scripts/lib.sh; verify_context CONF RECORDS'"
base="$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")"
check "verify context: a sha256" 64 "$(printf '%s' "$base" | tr -cd '0-9a-f' | awk '{ print length($0) }')" "$VC"
check "verify context: the same inputs give the same value" "$base" "$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")" "$VC, twice"
# differs LABEL: a check that the context now differs from $base
differs() {
  local now
  now="$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")"
  if [ -n "$now" ] && [ "$now" != "$base" ]; then
    ok "verify context: $1 changes it"
  else
    fail "verify context: $1 changes it" "before: $base" "after:  $now" "$VC"
  fi
}
for f in scripts/verify-batch client/pacman-oci scripts/lib.sh; do
  cp "$vc/root/$f" "$vc/saved"
  printf '#' >> "$vc/root/$f"
  differs "one byte more in $f"
  cp "$vc/saved" "$vc/root/$f"
done
vrecs 2222222222222222222222222222222222222222222222222222222222222222 c2ln 1700000000 "$SHA"
differs "another sha256 of a keyring record"
vrecs "$KSHA" c2lnbg== 1700000000 "$SHA"
differs "another %PGPSIG% of a keyring record"
vrecs "$KSHA" c2ln 1700000000 "$KSHA"
check "verify context: another sha256 of a record that is not a keyring package does not change it" "$base" \
  "$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")" "$VC"
vrecs "$KSHA" c2ln 1700000001 "$SHA"
check "verify context: another build date of a keyring record does not change it" "$base" \
  "$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")" "$VC"
vrecs "$KSHA" c2ln 1700000000 "$SHA"
vconf '' '# another comment, after a blank line'
check "verify context: an edit of the comments and blank lines of the target file does not change it" "$base" \
  "$(ctx "$vc/x86_64-core.conf" "$vc/records.tsv")" "$VC"
vconf 'db_signed = yes'
differs "a key of the target file"
vconf
printf 'none\n' > "$vc/none.tsv"
: > "$vc/empty.tsv"
check "verify context: no latest of keyring_from (none) is not the same as no keyring record" "differ" \
  "$([ "$(ctx "$vc/x86_64-core.conf" "$vc/none.tsv")" != "$(ctx "$vc/x86_64-core.conf" "$vc/empty.tsv")" ] && echo differ || echo same)" "$VC"
rc=0
ctx "$vc/x86_64-core.conf" "$vc/no-such-file" > /dev/null 2>&1 || rc=$?
check "verify context: a records file that does not read gives no context" 1 "$rc" "$VC with RECORDS missing"

#---------------------------------------------------------------------------#
# results_of_plan: the result lines of one plan's shards, and no other's
#---------------------------------------------------------------------------#
rp="$work/rop"
mkdir -p "$rp/res/results-x-0/0" "$rp/res/results-x-1/1/lines" "$rp/res/results-x-2/2"
printf 'p2\n' > "$rp/res/results-x-0/0/plan-id"
printf 't\ta.pkg.tar.zst\tpushed\t1\tok\n' > "$rp/res/results-x-0/0/results.tsv"
printf 'p2\n' > "$rp/res/results-x-1/1/plan-id"
printf 't\tb.pkg.tar.zst\tpushed\t1\tok\n' > "$rp/res/results-x-1/1/lines/1.tsv"
printf 't\tc.pkg.tar.zst\tfailed\t1\tno\n' > "$rp/res/results-x-1/1/lines/2.tsv"
printf 'p1\n' > "$rp/res/results-x-2/2/plan-id"
printf 't\td.pkg.tar.zst\tfailed\t1\tstale\n' > "$rp/res/results-x-2/2/results.tsv"
rc=0
in_lib results_of_plan "$rp/res" p2 "$rp/out.tsv" 2> "$rp/err" || rc=$?
check "results_of_plan: the results.tsv and the lines of this plan, and nothing of another plan" "0 a.pkg.tar.zst b.pkg.tar.zst c.pkg.tar.zst" \
  "$rc $(cut -f 2 "$rp/out.tsv" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "bash -c '. scripts/lib.sh; results_of_plan RESULTS p2 OUT'; cat $rp/err"
if grep -q "results-x-2/2 holds the results of plan 'p1', not of this plan 'p2'; they are not read" "$rp/err"; then
  ok "results_of_plan: the directory of another plan is named in a warning"
else
  fail "results_of_plan: the directory of another plan is named in a warning" "$(cat "$rp/err")" "bash -c '. scripts/lib.sh; results_of_plan RESULTS p2 OUT'"
fi
rc=0
in_lib results_of_plan "$rp/none" p2 "$rp/none.tsv" 2> "$rp/err" || rc=$?
check "results_of_plan: no results directory gives no line" "0 0" "$rc $(awk 'END { print NR + 0 }' "$rp/none.tsv")" \
  "bash -c '. scripts/lib.sh; results_of_plan MISSING p2 OUT'"

summary
