#!/usr/bin/env bash
#
# The decisions the sync makes, each on fixed inputs: which target files are
# valid, which database fields are refused, which database is behind another,
# when a package tag may be written, when a target is stale, which snapshot is
# newer, how a shard accounts for every file, which token a registry read
# sends, which server is asked last, how long an upstream read may take, and
# which artifacts of a re-run the report reads.
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
IMG='ghcr.io/pkgforge-dev/archlinux:aarch64@sha256:15031c4e061148f93f4942bc0bc0ec05e3da69007889d6808020e91a5e26d162'
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
reason "an architecture is not a signature reason" \
  "$(printf '%s\n' ':: package port-1-1-aarch64 does not have a valid architecture' 'error: failed to prepare transaction (package architecture is not valid)')" 0 0 other
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
# Logs "URL<TAB>AUTH" to $FAKE/calls.log; answers a token request that
# carries a credential (a user line on stdin, --config -) with
# $FAKE/next-token, one with none with "anon", and a manifest request from
# $FAKE/answers.tsv: AUTH<TAB>CODE<TAB>BODY-FILE, the first line whose AUTH
# matches.
out="" auth="" url="" cred=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --header) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift 2 ;;
    --config) if [ "$2" = - ]; then cred="$(cat)"; fi; shift 2 ;;
    --write-out | --user | --data-urlencode | --connect-timeout | --max-time | --retry | --retry-delay | \
      --max-filesize | --proto | --proto-redir | --max-redirs | --speed-limit | --speed-time | --user-agent) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\t%s\n' "$url" "$auth" >> "$FAKE/calls.log"
case "$url" in
  */token)
    case "$cred" in
      *'user = '*) printf '{"token":"%s"}' "$(cat "$FAKE/next-token")" > "$out" ;;
      *) printf '{"token":"anon"}' > "$out" ;;
    esac
    ;;
  */manifests/*)
    line="$(awk -F '\t' -v a="$auth" '$1 == a && !f { print $2 "\t" $3; f = 1 }' "$FAKE/answers.tsv")"
    [ -n "$line" ] || { printf '000'; exit 7; }
    cp "$FAKE/${line#*$'\t'}" "$out"
    printf '%s' "${line%%$'\t'*}"
    ;;
esac
EOF
chmod +x "$fake/bin/curl"
printf '{"schemaVersion":2,"layers":[]}' > "$fake/manifest.json"
printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' > "$fake/unknown.json"
printf '{"errors":[{"code":"UNAUTHORIZED"}]}' > "$fake/denied.json"
# reg NAME ANSWERS [CACHE] -> "STATUS CALLS TOKEN-CALLS", one registry_manifest
reg() {
  local rc=0
  printf '%b' "$2" > "$fake/answers.tsv"
  : > "$fake/calls.log"
  FAKE="$fake" PATH="$fake/bin:$PATH" MIRROR_REGISTRY="${REG_REGISTRY:-ghcr.io}" MIRROR_REGISTRY_AUTH=token MIRROR_REGISTRY_SCHEME=https \
    REGISTRY_TOKEN="${REG_TOKEN-secret}" REGISTRY_TOKEN_CACHE="${3:-}" \
    in_lib registry_manifest it/repo latest "$fake/out.json" > /dev/null 2> "$fake/err" || rc=$?
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
fi

summary
