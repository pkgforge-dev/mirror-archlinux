#!/usr/bin/env bash
#
# The client against a registry of its own.
#
# A local registry (registry:3) holds two signed repositories in the mirror's
# layout: each package under its own tag, with layers titled FILE and FILE.sig,
# and each database under latest. pacman in an Arch container then reads them
# through client/pacman-oci: with the prefetch and without it, with and
# without DownloadUser, with the signatures from the registry, with a provider
# other than the default, through a proxy that answers 503, through a proxy
# that cuts every blob in half, through a proxy that stops sending a large
# blob, through a proxy that changes one byte of the first answer for each
# blob, and from a plain http Server that ignores Range.
#
# Needs docker or podman (CONTAINER_RUNTIME), curl, jq, sha256sum, and network
# to pull the pinned images and oras. Ports are picked at run time and every
# container name carries this shell's pid and a random number, so several runs
# can share one host.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

# tag: base
ARCH_IMAGE=docker.io/library/archlinux:base@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
# tag: 3
REGISTRY_IMAGE=docker.io/library/registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
# tag: 3.15-alpine
PYTHON_IMAGE=docker.io/library/python:3.15-alpine@sha256:ff4d3c9b1a48f646eedd93182aaea385c7a5452f4c8a8cd7cef686babacf4928

FIX="$REPO_ROOT/tests/fixtures/client"
runtime_detect
work="$(work_dir)"
id="$$-$RANDOM"
reg_name="client-it-registry-$id"
cut_name="client-it-cut-$id"
dead_name="client-it-dead-$id"
flip_name="client-it-flip-$id"
stall_name="client-it-stall-$id"
norange_name="client-it-norange-$id"
cleanup() {
  local out
  out="$("$RUNTIME" rm -f "$reg_name" "$cut_name" "$dead_name" "$flip_name" "$stall_name" "$norange_name" 2>&1)" || diag "cleanup: $out"
  if [ "${IT_KEEP:-0}" = 1 ]; then
    echo "# kept $work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

# The build container writes into the work directory as the calling user, so
# the directory can be removed afterwards without root.
as_me=(--user "$(id -u):$(id -g)")
case "$(basename "$RUNTIME")" in
  *podman*) as_me=(--userns keep-id) ;;
esac

stop() {
  fail "$1" "${@:2}"
  summary
  exit 1
}

#---------------------------------------------------------------------------#
# The registry, on a port the runtime picks
#---------------------------------------------------------------------------#
"$RUNTIME" run -d --rm --name "$reg_name" -p 127.0.0.1::5000 "$REGISTRY_IMAGE" > /dev/null
reg_port="$("$RUNTIME" port "$reg_name" 5000/tcp)"
reg_port="${reg_port##*:}"
ready=0
for _ in $(seq 1 30); do
  if curl -q -fsS --connect-timeout 2 --max-time 5 -o /dev/null "http://127.0.0.1:$reg_port/v2/"; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || stop "the local registry answers" "after 30 s on port '$reg_port'" "reproduce: $RUNTIME logs $reg_name"
REG="127.0.0.1:$reg_port"
SERVER="oci+http://$REG/it/client/x86_64"

#---------------------------------------------------------------------------#
# Two signed repositories, pushed in the mirror's layout
#---------------------------------------------------------------------------#
mkdir -p "$work/up"
if ! "$RUNTIME" run --rm "${as_me[@]}" -e HOME=/tmp -v "$work/up:/out" -v "$FIX/build-repos:/build-repos:ro" \
  "$ARCH_IMAGE" bash /build-repos > "$work/build.log" 2>&1; then
  stop "the fixture repositories build" "$(tail -n 5 "$work/build.log")" "reproduce: bash tests/fixtures/client/build-repos in $ARCH_IMAGE"
fi
ORAS="$("$REPO_ROOT/scripts/install-oras" "$work/bin")"

# push REPO TAG FILE:TYPE...: one manifest, from the repository's directory
push() {
  local repo="$1" tag="$2" artifact="$3" rc=0
  shift 3
  (cd "$work/up/$repo" && timeout 120 "$ORAS" push --plain-http --artifact-type "$artifact" \
    "$REG/it/client/x86_64/$repo:$tag" "$@") >> "$work/push.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || stop "oras pushes $repo:$tag" "exit $rc" "$(tail -n 3 "$work/push.log")"
}
for repo in one two; do
  for f in "$work/up/$repo"/*.pkg.tar.zst; do
    f="${f##*/}"
    push "$repo" "$("$REPO_ROOT/client/pacman-oci" --tag "$f")" application/vnd.pkgforge.archlinux.package.v1 \
      "./$f:application/vnd.pkgforge.archlinux.pkg.v1" "./$f.sig:application/pgp-signature"
  done
  push "$repo" latest application/vnd.pkgforge.archlinux.db.v1 \
    "./$repo.db:application/vnd.pkgforge.archlinux.db.v1" "./$repo.files:application/vnd.pkgforge.archlinux.files.v1"
done
titles="$(curl -q -fsS --connect-timeout 5 --max-time 20 -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://$REG/v2/it/client/x86_64/one/manifests/$("$REPO_ROOT/client/pacman-oci" --tag alpha-1.0-1-any.pkg.tar.zst)" |
  jq -r '[.layers[].annotations["org.opencontainers.image.title"]] | join(" ")')"
check "a package is pushed as the mirror lays it out" "alpha-1.0-1-any.pkg.tar.zst alpha-1.0-1-any.pkg.tar.zst.sig" "$titles" \
  "curl http://$REG/v2/it/client/x86_64/one/manifests/<alpha tag>"

#---------------------------------------------------------------------------#
# The four proxies and the plain server, on ports they pick themselves
#---------------------------------------------------------------------------#
# proxy NAME MODE: start one and print its port. The norange mode serves the
# files of the repositories, mounted at /up, and no registry.
proxy() {
  local p='' up="$REG"
  if [ "$2" = norange ]; then
    up=/up
  fi
  "$RUNTIME" run -d --rm --name "$1" --network host -v "$FIX/fault-proxy.py:/proxy.py:ro" \
    -v "$work/up:/up:ro" "$PYTHON_IMAGE" python3 -I -u /proxy.py "$2" "$up" > /dev/null
  for _ in $(seq 1 30); do
    p="$("$RUNTIME" logs "$1" 2>&1 | awk '$1 == "PORT" { print $2 }')"
    [ -z "$p" ] || break
    sleep 1
  done
  printf '%s\n' "$p"
}
cut_port="$(proxy "$cut_name" cut)"
dead_port="$(proxy "$dead_name" 503)"
flip_port="$(proxy "$flip_name" flip)"
stall_port="$(proxy "$stall_name" stall)"
norange_port="$(proxy "$norange_name" norange)"
[ -n "$cut_port" ] && [ -n "$dead_port" ] && [ -n "$flip_port" ] && [ -n "$stall_port" ] && [ -n "$norange_port" ] ||
  stop "the fault proxies start" \
    "cut '$cut_port' 503 '$dead_port' flip '$flip_port' stall '$stall_port' norange '$norange_port'" \
    "reproduce: $RUNTIME logs $cut_name"

#---------------------------------------------------------------------------#
# The cases
#---------------------------------------------------------------------------#
# consumer CASE SERVER: one case in a fresh container; its output in
# $work/case-CASE.log
consumer() {
  local rc=0
  "$RUNTIME" run --rm --network host \
    -v "$REPO_ROOT/client/pacman-oci:/in/pacman-oci:ro" \
    -v "$work/up/gnupg:/in/gnupg:ro" \
    -v "$FIX/consumer:/in/consumer:ro" \
    "$ARCH_IMAGE" bash /in/consumer "$1" "$2" > "$work/case-$1.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "case $1 runs" "exit $rc" "$(tail -n 10 "$work/case-$1.log")"
  fi
}

# want CASE NAME EXPECTED DESCRIPTION
want() {
  local got
  got="$(awk -v n="$2" '$1 == "RESULT" && $2 == n { print $3 }' "$work/case-$1.log")"
  if [ "$got" = "$3" ]; then
    ok "$1: $4"
  else
    fail "$1: $4" "expected $2 = $3" "got:      $2 = ${got:-nothing}" \
      "reproduce: IT_KEEP=1 tests/integration/20-client.sh, then read case-$1.log"
    while IFS= read -r l; do diag "$l"; done < <(grep -v '^RESULT' "$work/case-$1.log" | tail -n 15)
  fi
}

# want_cmp CASE NAME OP NUMBER DESCRIPTION, with OP one of lt ge
want_cmp() {
  local got pass=0
  got="$(awk -v n="$2" '$1 == "RESULT" && $2 == n { print $3 }' "$work/case-$1.log")"
  case "$3:$got" in
    *: | *:*[!0-9]*) ;;
    lt:*) if [ "$got" -lt "$4" ]; then pass=1; fi ;;
    ge:*) if [ "$got" -ge "$4" ]; then pass=1; fi ;;
  esac
  if [ "$pass" = 1 ]; then
    ok "$1: $5"
  else
    fail "$1: $5" "expected $2 $3 $4" "got:      $2 = ${got:-nothing}" \
      "reproduce: IT_KEEP=1 tests/integration/20-client.sh, then read case-$1.log"
  fi
}

for c in main-du main-root; do
  consumer "$c" "$SERVER"
  want "$c" sy_rc 0 "pacman -Sy of two repositories succeeds"
  want "$c" sy_prefetch_get 4 "the first database request reads both manifests and both databases in one prefetch"
  want "$c" sy_get 0 "no single request: the second database and both missing .db.sig come from the run store"
  want "$c" sy_served 2 "both databases are handed over from the run store"
  want "$c" sy_db_sigs 0 "no database signature is stored in the sync directory"
  want "$c" s_rc 0 "pacman -S of three packages from two repositories succeeds"
  want "$c" s_prefetch_get 3 "the prefetch reads the three packages; the signatures come from %PGPSIG%"
  want "$c" s_get 0 "the serial pass makes no network request"
  want "$c" s_served 6 "every package and every .sig is handed over from the run store"
  want "$c" installed_alpha 0 "alpha is installed"
  want "$c" installed_gamma 0 "gamma, from the second repository, is installed"
  want "$c" fy_rc 0 "pacman -Fy succeeds"
  want "$c" fy_served 2 "both .files databases come from one prefetch"
  want "$c" fl 0:1 "pacman -Fl reads the files database"
  want "$c" main_store_files 0 "no store file is left once pacman has ended"
  want "$c" main_download_dirs 0 "no download directory is left behind"
done
# The 2 s pause pacman takes after each failed download: under the sandbox the
# two absent database signatures are empty files, which pacman removes, so -Sy
# pauses never. With no sandbox they stay misses, so -Sy pauses twice.
want main-du sy_empty_sig 2 "both absent database signatures are answered with an empty file"
want_cmp main-du sy_wall_ms lt 1900 "-Sy of two repositories takes less than one 2 s pause"
want main-root sy_empty_sig 0 "with no sandbox, an absent database signature stays a miss"
want_cmp main-root sy_wall_ms ge 4000 "with no sandbox, pacman pauses 2 s after each absent signature"

consumer noprefetch "$SERVER"
want noprefetch s_rc 0 "PACMAN_OCI_PREFETCH=0: pacman -S succeeds"
want noprefetch s_prefetch_get 0 "PACMAN_OCI_PREFETCH=0: no prefetch request"
want noprefetch s_get 8 "PACMAN_OCI_PREFETCH=0: two requests per file, as version 1 made them"
want noprefetch noprefetch_store_files 0 "PACMAN_OCI_PREFETCH=0: no store file is left"

consumer registry "$SERVER"
want registry s_rc 0 "PACMAN_OCI_SIG=registry: pacman -S succeeds"
want registry s_sig_layers 3 "PACMAN_OCI_SIG=registry: each .sig is the registry's layer"
want registry s_get 0 "PACMAN_OCI_SIG=registry: the serial pass makes no network request"

consumer provider "$SERVER"
want provider s_rc 0 "another provider: pacman -S virt succeeds"
want provider s_prefetched_default 1 "another provider: the prefetch took the first provider, as print mode does"
want_cmp provider s_get_chosen ge 2 "another provider: the chosen one is read alone"
want provider chosen_installed 0 "another provider: the chosen one is installed"

consumer dead "oci+http://127.0.0.1:$dead_port/it/client/x86_64"
want dead dead_first_rc 1 "a registry that answers 503: the first file misses"
want dead dead_second_rc 1 "a registry that answers 503: the second file misses"
want dead dead_second_get 0 "a registry that answers 503: the second file makes no request"
want_cmp dead dead_second_ms lt 1000 "a registry that answers 503: the second file misses in under 1 s"
want_cmp dead dead_sig_get ge 1 "a registry that answers 503: a .sig is still asked for"

big_hex="$(sha256sum "$work/up/one/big-1-1-any.pkg.tar.zst" | cut -d ' ' -f 1)"
for c in resume resume-serial; do
  before="$("$RUNTIME" logs "$cut_name" 2>&1 | awk -v b="/blobs/sha256:$big_hex" 'index($0, b) && /range=bytes=/ { n++ } END { print n + 0 }')"
  consumer "$c" "oci+http://127.0.0.1:$cut_port/it/client/x86_64"
  after="$("$RUNTIME" logs "$cut_name" 2>&1 | awk -v b="/blobs/sha256:$big_hex" 'index($0, b) && /range=bytes=/ { n++ } END { print n + 0 }')"
  want "$c" sy_rc 0 "every blob cut in half: pacman -Sy succeeds"
  want "$c" s_rc 0 "every blob cut in half: pacman -S big succeeds"
  want "$c" installed_big 0 "every blob cut in half: big is installed"
  check "$c: the cut package was resumed with a Range request" 1 "$((after - before))" \
    "$RUNTIME logs $cut_name | grep $big_hex"
done
want resume s_get 0 "every blob cut in half: the prefetch resumed it, the serial pass made no request"

consumer stall "oci+http://127.0.0.1:$stall_port/it/client/x86_64"
ranges="$("$RUNTIME" logs "$stall_name" 2>&1 | awk -v b="/blobs/sha256:$big_hex" 'index($0, b) && /range=bytes=65536-/ { n++ } END { print n + 0 }')"
want stall sy_rc 0 "a blob that stops after 64 KiB: pacman -Sy succeeds"
want stall s_rc 0 "a blob that stops after 64 KiB: pacman -S big succeeds"
want stall installed_big 0 "a blob that stops after 64 KiB: big is installed"
want stall s_get 0 "a blob that stops after 64 KiB: the prefetch got it, the serial pass made no request"
want_cmp stall s_ms lt 20000 "a blob that stops for 40 s: pacman -S big takes less than 20 s"
check "stall: the prefetch cut the stopped transfer and resumed it from 64 KiB" 1 "$ranges" \
  "$RUNTIME logs $stall_name | grep $big_hex"

# The plain Server ignores Range. The first GET of big stops after 64 KiB for
# 35 s, so the attempt that resumes it starts after 30 s. That attempt gets
# curl exit 33, and the next one reads big from zero.
consumer norange "http://127.0.0.1:$norange_port"
big_gets="$("$RUNTIME" logs "$norange_name" 2>&1 | awk '$1 == "GET" && $2 == "/one/big-1-1-any.pkg.tar.zst" { print $3 }' | paste -sd ' ' -)"
want norange sy_rc 0 "a plain Server that ignores Range: pacman -Sy succeeds"
want norange s_rc 0 "a plain Server that ignores Range: pacman -S big succeeds after its range is refused past 30 s"
want norange installed_big 0 "a plain Server that ignores Range: big is installed"
check "norange: the refused range is followed by one GET from zero" "range=- range=bytes=65536- range=-" "$big_gets" \
  "$RUNTIME logs $norange_name | grep big"

consumer flip "oci+http://127.0.0.1:$flip_port/it/client/x86_64"
want flip sy_rc 0 "one byte changed in each first answer: pacman -Sy succeeds"
want flip sy_refused 2 "one byte changed in each first answer: the prefetch keeps neither database"
want flip sy_get 4 "one byte changed in each first answer: each database is read again alone"
want flip s_rc 0 "one byte changed in each first answer: pacman -S alpha gamma succeeds"
want flip s_refused 2 "one byte changed in each first answer: the prefetch keeps neither package"
want flip s_get 4 "one byte changed in each first answer: each package is read again alone"
want flip installed_alpha 0 "one byte changed in each first answer: alpha is installed"
want flip installed_gamma 0 "one byte changed in each first answer: gamma is installed"

summary
