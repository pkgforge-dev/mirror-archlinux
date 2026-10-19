#!/usr/bin/env bash
#
# The whole mirror, end to end, against a registry and an upstream of its own.
#
# A local registry (registry:3) stands in for GHCR and a local web server for
# the upstream mirrors. A second web server stands in for an upstream host
# that never answers, or answers 503. Three targets are built, each a signed
# repository:
#   x86_64-test   filenames that stress the tag mapping; its keyring package
#                 comes from x86_64-kr (keyring_from)
#   x86_64-kr     the keyring package of the test keys
#   aarch64-port  another arch, verified in the x86_64 image with
#                 Architecture = aarch64; a package upstream signs nowhere, one
#                 signed by a key that has expired, and a package directory
#                 whose desc is NUL bytes only
# The trust root of every target is a keyring image of the suite's own,
# pushed to the local registry (keyring_image). Then the real scripts run as
# the workflows run them, each target in a chain of its own: plan,
# mirror-shard, stage, verify-batch, promote, report, index-write. pacman in
# an Arch container then installs from the mirror through the wrapper, with
# and without DownloadUser, and the cases that must be refused are driven on
# purpose. The runs are attempt 1 of a run on main: the tags are staging and
# index, whatever ref CI runs on.
#
# Every port is chosen by the container runtime at run time and every
# container name carries this shell's pid, so several runs share one host.
#
# Needs docker or podman (CONTAINER_RUNTIME), curl, jq, tar, sha256sum, and
# network to pull the pinned images and oras. IT_ORAS_CACHE names a directory
# that keeps the oras download between runs (scripts/install-oras).
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

# tag: base
ARCH_IMAGE=docker.io/library/archlinux:base@sha256:e43f1fd80e073992c5f173efbbbf65144170bf60aeb7369940087d63eacea8f4
# tag: 3
REGISTRY_IMAGE=docker.io/library/registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
# tag: 1.38
HTTPD_IMAGE=docker.io/library/busybox:1.38@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e

runtime_detect
work="$(work_dir)"
suffix="$$-$RANDOM"
reg_name="mirror-it-registry-$suffix"
up_name="mirror-it-upstream-$suffix"
broken_name="mirror-it-broken-$suffix"
kimage_local="mirror-it-keyring-$suffix"
cleanup() {
  "$RUNTIME" rm -f "$reg_name" "$up_name" "$broken_name" > "$work/cleanup.log" 2>&1 || echo "# cleanup: $(cat "$work/cleanup.log")" >&2
  if [ "${IT_KEEP:-0}" = 1 ]; then
    echo "# kept $work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

# Containers that write into the work directory do so as the calling user,
# so the directory can be removed afterwards without root.
as_me=(--user "$(id -u):$(id -g)")
podman=0
case "$(basename "$RUNTIME")" in
  *podman*)
    as_me=(--userns keep-id)
    podman=1
    ;;
esac

mkdir -p "$work/upstream" "$work/targets" "$work/out" "$work/broken/cgi-bin" "$work/broken-log"

# A second upstream host that fails, on a port of its own: each request is
# logged in broken-log/hits, then a path under /stall/ gets no answer for
# 300 s, and a path under /fail/ gets 503 at once.
cat > "$work/broken/cgi-bin/b" << 'EOF'
#!/bin/sh
printf '%s\n' "$PATH_INFO" >> /log/hits
case "$PATH_INFO" in
  /stall/*) sleep 300 ;;
esac
printf 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 5\r\n\r\nbusy\n'
EOF
chmod 0755 "$work/broken/cgi-bin/b"
: > "$work/broken-log/hits"

#---------------------------------------------------------------------------#
# The registry and the upstream, on ports the runtime picks
#---------------------------------------------------------------------------#
# port_of NAME PORT -> the host port the runtime mapped to the container's PORT
port_of() {
  "$RUNTIME" port "$1" "$2/tcp" | sed -n 's/^127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' | sed -n 1p
}
"$RUNTIME" run -d --rm --name "$reg_name" -p 127.0.0.1::5000 "$REGISTRY_IMAGE" > /dev/null
"$RUNTIME" run -d --rm --name "$up_name" -p 127.0.0.1::8000 -v "$work/upstream:/srv:ro" \
  "$HTTPD_IMAGE" httpd -f -p 8000 -h /srv > /dev/null
"$RUNTIME" run -d --rm --name "$broken_name" "${as_me[@]}" -p 127.0.0.1::8000 -v "$work/broken:/srv:ro" \
  -v "$work/broken-log:/log" "$HTTPD_IMAGE" httpd -f -p 8000 -h /srv > /dev/null
REG_PORT="$(port_of "$reg_name" 5000)"
UP_PORT="$(port_of "$up_name" 8000)"
BROKEN_PORT="$(port_of "$broken_name" 8000)"
ready=0
if [ -n "$REG_PORT" ] && [ -n "$UP_PORT" ] && [ -n "$BROKEN_PORT" ]; then
  for _ in $(seq 1 30); do
    if curl -q -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" > /dev/null &&
      curl -q -sS --connect-timeout 2 --max-time 5 -o /dev/null "http://127.0.0.1:$UP_PORT/" &&
      curl -q -sS --connect-timeout 2 --max-time 5 -o /dev/null "http://127.0.0.1:$BROKEN_PORT/"; then
      ready=1
      break
    fi
    sleep 1
  done
fi
if [ "$ready" -ne 1 ]; then
  fail "the local registry and upstream answer" "registry port '$REG_PORT', upstream ports '$UP_PORT' and '$BROKEN_PORT', after 30 s" \
    "reproduce: $RUNTIME logs $reg_name; $RUNTIME logs $up_name; $RUNTIME logs $broken_name"
  summary
  exit 1
fi
echo "# registry on 127.0.0.1:$REG_PORT, upstream on 127.0.0.1:$UP_PORT, failing upstream on 127.0.0.1:$BROKEN_PORT"

# podman reads a registry over plain http only when its configuration says
# so; docker does for any registry on the loopback.
if [ "$podman" -eq 1 ]; then
  printf '[[registry]]\nlocation = "127.0.0.1:%s"\ninsecure = true\n' "$REG_PORT" > "$work/registries.conf"
  export CONTAINERS_REGISTRIES_CONF="$work/registries.conf"
fi

# build STATE [DIR] [DB]: tests/fixtures/build-repo in the Arch image
build() {
  "$RUNTIME" run --rm "${as_me[@]}" -e HOME=/tmp -v "$work/upstream:/out" \
    -v "$REPO_ROOT/tests/fixtures/build-repo:/build-repo.sh:ro" \
    "$ARCH_IMAGE" bash /build-repo.sh "$@" > "$work/build-$1.log" 2>&1
}

export TARGETS_DIR="$work/targets"
export MIRROR_REGISTRY="127.0.0.1:$REG_PORT"
export MIRROR_REGISTRY_SCHEME=http
export MIRROR_REGISTRY_AUTH=none
export MIRROR_NAMESPACE=it/mirror
export UPSTREAM_PROTO='=http,https'
export VERIFY_NETWORK=host
export CONTAINER_RUNTIME="$RUNTIME"
export SHARD_FILES=2
export PARALLEL=2
export ORAS_CACHE="${IT_ORAS_CACHE:-$work/oras-cache}"
# A run on main, attempt 1 (scripts/lib.sh staging_tag and index_tag,
# scripts/mirror-shard). CI sets GITHUB_REF and GITHUB_RUN_ATTEMPT for its
# own run, which would give other tags and, on a re-run of CI, the re-run
# guard.
export STAGING_TAG=staging
export INDEX_TAG=index
export GITHUB_RUN_ATTEMPT=1
export MIRROR_REPAIR=1
REPO="it/mirror/x86_64/test"
BASE="http://127.0.0.1:$REG_PORT/v2/$REPO"
UP="http://127.0.0.1:$UP_PORT"
BROKEN="http://127.0.0.1:$BROKEN_PORT/cgi-bin/b"

#---------------------------------------------------------------------------#
# The upstream repositories, and the suite's keyring image
#---------------------------------------------------------------------------#
build one
build keyring x86_64/kr kr
build port aarch64/port port

mkdir -p "$work/kimage/keyrings"
cp "$work/upstream/trust-root/test.gpg" "$work/upstream/trust-root/test-trusted" "$work/upstream/trust-root/test-revoked" "$work/kimage/keyrings/"
printf 'FROM %s\nCOPY keyrings/ /usr/share/pacman/keyrings/\n' "$HTTPD_IMAGE" > "$work/kimage/Containerfile"
"$RUNTIME" build -t "$kimage_local" -f "$work/kimage/Containerfile" "$work/kimage" > "$work/kimage.log" 2>&1
"$RUNTIME" tag "$kimage_local" "127.0.0.1:$REG_PORT/it/keyring:test"
"$RUNTIME" push "127.0.0.1:$REG_PORT/it/keyring:test" >> "$work/kimage.log" 2>&1
"$RUNTIME" rmi "$kimage_local" "127.0.0.1:$REG_PORT/it/keyring:test" >> "$work/kimage.log" 2>&1
kdigest="$(curl -q -sS --connect-timeout 5 --max-time 20 -o /dev/null -D - \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://127.0.0.1:$REG_PORT/v2/it/keyring/manifests/test" |
  tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')"
KEYRING_IMAGE="127.0.0.1:$REG_PORT/it/keyring:test@$kdigest"
check "the suite's keyring image is on the local registry" 1 "$(printf '%s' "$kdigest" | grep -cE '^sha256:[0-9a-f]{64}$')" \
  "read $work/kimage.log"

# conf ARCH REPO [EXTRA LINES...]: a target file. The package sources are the
# upstream twice, by two URLs for the same bytes, so two shards start from
# different servers.
conf() {
  local arch="$1" repo="$2"
  shift 2
  {
    printf 'arch = %s\nrepo = %s\n' "$arch" "$repo"
    # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
    printf 'db_server = %s/$arch/$repo\nserver = %s/$arch/./$repo\n' "$UP" "$UP"
    printf '# tag: base\nverify_image = %s\nverify_platform = linux/amd64\n' "$ARCH_IMAGE"
    printf '# tag: test\nkeyring_image = %s\nkeyring_platform = linux/amd64\n' "$KEYRING_IMAGE"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
  } > "$work/targets/$arch-$repo.conf"
}
conf x86_64 test 'keyring = test-keyring' 'keyring_from = x86_64-kr'
conf x86_64 kr 'keyring = test-keyring'
conf aarch64 port

# index_write N TARGET: the last step of the chain, as the summary job runs
# it, whatever the steps before it did. Its exit status goes to
# out/N/index-TARGET.rc.
index_write() {
  local o="$work/out/$1" rc=0
  "$REPO_ROOT/scripts/index-write" "$o/plan" "$o/results/$2" "$o/stage" "$o/verify" "$2" > "$o/index-$2.log" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$o/index-$2.rc"
  if [ "$rc" -ne 0 ]; then
    diag "sync $1: index-write of $2 ended $rc"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 5 "$o/index-$2.log")
  fi
}

# sync N [TARGET ...]: one run, as the workflows run it: plan for every
# target, then each pending target's chain in the order given (default kr,
# test, port), each one ending in index_write, then the report; state in
# $work/out/N. AFTER_STAGE names a function that runs with the target after
# each stage, before verify. BEFORE_VERIFY names a function that runs with
# the target and the batch before each verify-batch, in this shell: what it
# exports, verify-batch sees.
sync() {
  local n="$1" o t s b rc
  shift
  o="$work/out/$n"
  mkdir -p "$o/summaries"
  if ! "$REPO_ROOT/scripts/plan" "$o/plan" > "$o/plan.log" 2>&1; then
    diag "sync $n: plan failed"
    logs_of "$n"
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    set -- x86_64-kr x86_64-test aarch64-port
  fi
  for t in "$@"; do
    [ -f "$o/plan/$t/state" ] && [ "$(cat "$o/plan/$t/state")" = pending ] || continue
    for s in "$o/plan/$t"/shards/*.tsv; do
      [ -e "$s" ] || continue
      rc=0
      SHARD_INDEX="$(basename "$s" .tsv)" "$REPO_ROOT/scripts/mirror-shard" "$s" "$o/results/$t/$(basename "$s" .tsv)" \
        > "$o/mirror-$t-$(basename "$s" .tsv).log" 2>&1 || rc=$?
    done
    if ! "$REPO_ROOT/scripts/stage" "$o/plan" "$o/results/$t" "$o/stage" "$t" > "$o/stage-$t.log" 2>&1; then
      diag "sync $n: stage of $t failed"
      logs_of "$n"
      index_write "$n" "$t"
      continue
    fi
    if [ -n "${AFTER_STAGE:-}" ]; then
      "$AFTER_STAGE" "$t"
    fi
    for b in "$o/stage/$t"/batches/*.txt; do
      [ -e "$b" ] || continue
      if [ -n "${BEFORE_VERIFY:-}" ]; then
        "$BEFORE_VERIFY" "$t" "$(basename "$b" .txt)"
      fi
      rc=0
      "$REPO_ROOT/scripts/verify-batch" "$o/stage" "$t" "$(basename "$b" .txt)" "$o/verify" \
        > "$o/verify-$t-$(basename "$b" .txt).log" 2>&1 || rc=$?
    done
    rc=0
    "$REPO_ROOT/scripts/promote" "$o/stage" "$o/verify" "$t" > "$o/promote-$t.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\tpromoted\t%s\n' "$t" "$(cut -f 3,4 "$o/stage/$t/promoted.tsv" | tr '\t' ' ')" > "$o/promote-$t.tsv"
    else
      printf '%s\tfailed\t%s\n' "$t" "$(grep -m 1 'promote:' "$o/promote-$t.log" | tr '\t' ' ')" > "$o/promote-$t.tsv"
    fi
    "$REPO_ROOT/scripts/report" collect "$t" "$o/stage" "$o/verify" "$o/promote-$t.tsv" "$o/summaries/$t" \
      > "$o/collect-$t.log" 2>&1
    index_write "$n" "$t"
  done
  rc=0
  # report writes its table to GITHUB_STEP_SUMMARY when that is set, as it is
  # on a runner; here the table must go to stdout.
  env -u GITHUB_STEP_SUMMARY "$REPO_ROOT/scripts/report" "$o/plan" "$o/summaries" > "$o/report.md" 2> "$o/report.log" || rc=$?
  printf '%s\n' "$rc" > "$o/report.rc"
  return 0
}

state_of() {
  local t="${3:-x86_64-test}"
  if [ -f "$work/out/$1/$2/$t/state" ]; then
    cat "$work/out/$1/$2/$t/state"
  else
    echo "no state"
  fi
}

# verdict_of N [TARGET] [BATCH] -> result and detail of a verify verdict
verdict_of() {
  local f="$work/out/$1/verify/verify-${2:-x86_64-test}-${3:-0}.tsv"
  if [ -f "$f" ]; then
    cut -f 3,4 "$f"
  else
    echo "no verdict"
  fi
}

manifest() {
  curl -q -fsS --connect-timeout 5 --max-time 20 -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://127.0.0.1:$REG_PORT/v2/${2:-$REPO}/manifests/$1"
}

# digest_of TAG [REPOSITORY] -> the digest the tag names, or nothing
digest_of() {
  curl -q -sS --connect-timeout 5 --max-time 20 -o /dev/null -D - \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://127.0.0.1:$REG_PORT/v2/${2:-$REPO}/manifests/$1" |
    tr -d '\r' | awk '$1 ~ /^HTTP/ { ok = ($2 == 200) } ok && tolower($1) == "docker-content-digest:" { print $2 }'
}

# put_manifest TAG FILE: write a manifest the way any writer with push rights can
put_manifest() {
  curl -q -fsS --connect-timeout 5 --max-time 20 -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary "@$2" -o /dev/null "$BASE/manifests/$1"
}

# tamper_canary: give the smallest package of the upstream test database,
# verify's canary, the signature layer of another package, as a writer with
# push rights could. The manifest it replaces is kept in canary-good.json, and
# $canary and $canary_tag name it.
tamper_canary() {
  local other='beta_pc-2.0-1-x86_64.pkg.tar.zst' rc=0
  canary="$(smallest)"
  canary_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$canary")"
  [ "$canary" != "$other" ] || other='gamma-3.0-2-any.pkg.tar.zst'
  {
    manifest "$canary_tag" > "$work/canary-good.json" &&
      manifest "$("$REPO_ROOT/client/pacman-oci" --tag "$other")" > "$work/other.json" &&
      jq -c --arg t "$canary.sig" --argjson l "$(jq -c --arg t "$other.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t)' "$work/other.json")" \
        '.layers |= map(if .annotations["org.opencontainers.image.title"] == $t then (.digest = $l.digest | .size = $l.size) else . end)' \
        "$work/canary-good.json" > "$work/canary-bad.json" &&
      put_manifest "$canary_tag" "$work/canary-bad.json"
  } || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "the canary $canary is given another package's signature layer, on the registry"
  else
    fail "the canary $canary is given another package's signature layer, on the registry" "status $rc" \
      "the canary must be a file the registry holds already: curl $BASE/manifests/$canary_tag"
  fi
}

# layer_of MANIFEST-FILE TITLE -> its digest
layer_of() {
  jq -r --arg t "$2" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest' "$1"
}

# swap_sig REPOSITORY FILE OTHER: give the tag of FILE the signature layer of
# the tag of OTHER, as a writer with push rights could
swap_sig() {
  local ftag otag rc=0
  ftag="$("$REPO_ROOT/client/pacman-oci" --tag "$2")"
  otag="$("$REPO_ROOT/client/pacman-oci" --tag "$3")"
  {
    manifest "$ftag" "$1" > "$work/swap-good.json" &&
      manifest "$otag" "$1" > "$work/swap-other.json" &&
      jq -c --arg t "$2.sig" --argjson l "$(jq -c --arg t "$3.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t)' "$work/swap-other.json")" \
        '.layers |= map(if .annotations["org.opencontainers.image.title"] == $t then (.digest = $l.digest | .size = $l.size) else . end)' \
        "$work/swap-good.json" > "$work/swap-bad.json" &&
      curl -q -fsS --connect-timeout 5 --max-time 20 -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
        --data-binary "@$work/swap-bad.json" -o /dev/null "http://127.0.0.1:$REG_PORT/v2/$1/manifests/$ftag"
  } || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$2 is given the signature layer of $3, on the registry"
  else
    fail "$2 is given the signature layer of $3, on the registry" "status $rc" \
      "both tags must be on the registry: curl http://127.0.0.1:$REG_PORT/v2/$1/manifests/$ftag"
  fi
}

# index_rows REPOSITORY -> the rows of REPOSITORY:index, one line each as
# "filename state verified unsigned", joined by "; "; "no index" when the
# tag or its index.tsv does not read
index_rows() {
  local d
  d="$(manifest index "$1" | jq -r '[.layers[] | select(.annotations["org.opencontainers.image.title"] == "index.tsv") | .digest] | first // empty')" || d=""
  if [ -z "$d" ]; then
    echo "no index"
    return 0
  fi
  curl -q -fsS --location --connect-timeout 5 --max-time 20 "http://127.0.0.1:$REG_PORT/v2/$1/blobs/$d" |
    awk -F '\t' '{ printf "%s%s %s %s %s", (NR > 1 ? "; " : ""), $1, $2, $3, $4 } END { print "" }'
}

# pgpsig_count [DIR]: how many %PGPSIG% the upstream database carries
pgpsig_count() {
  tar -xOzf "$work/upstream/${1:-x86_64/test}/${2:-test}.db" | awk '$0 == "%PGPSIG%" { n++ } END { print n + 0 }'
}

# pgpsig_of FILE [DIR]: the %PGPSIG% the upstream test database of DIR
# (default x86_64/test) carries for FILE
pgpsig_of() {
  tar -xOzf "$work/upstream/${2:-x86_64/test}/test.db" |
    awk -v f="$1" 'k == "F" { cur = $0 } k == "P" && cur == f { print } { k = ($0 == "%FILENAME%") ? "F" : ($0 == "%PGPSIG%") ? "P" : "" }'
}

# smallest -> the filename of the smallest package in the upstream test database
smallest() {
  tar -xOzf "$work/upstream/x86_64/test/test.db" |
    awk 'k == "F" { f = $0 } k == "C" { print $0 "\t" f } { k = ($0 == "%FILENAME%") ? "F" : ($0 == "%CSIZE%") ? "C" : "" }' |
    sort -n | awk -F '\t' 'NR == 1 { print $2 }'
}

logs_of() {
  local f
  for f in "$work/out/$1"/*.log; do
    [ -e "$f" ] || continue
    diag "--- $(basename "$f")"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 15 "$f")
  done
}

#---------------------------------------------------------------------------#
# 0. The shard cap binds and says so
#---------------------------------------------------------------------------#
rc=0
MAX_SHARDS=1 "$REPO_ROOT/scripts/plan" "$work/out/cap" "$work/targets/x86_64-test.conf" > "$work/out/cap.log" 2>&1 || rc=$?
check "MAX_SHARDS caps a target's shards" 1 "$(find "$work/out/cap/x86_64-test/shards" -name '*.tsv' | awk 'END { print NR + 0 }')" "read out/cap.log (plan exit $rc)"
if grep -q 'want 2 shard(s); MAX_SHARDS=1 caps them at 1' "$work/out/cap.log"; then
  ok "the plan logs that the shard cap binds"
else
  fail "the plan logs that the shard cap binds" "$(cat "$work/out/cap.log")"
fi

#---------------------------------------------------------------------------#
# 1. First sync: everything is new. The test chain runs first, before its
#    keyring_from target has a latest.
#---------------------------------------------------------------------------#
check "the fixture's database carries a %PGPSIG% for each of its 3 packages, as core's does" 3 "$(pgpsig_count)" \
  "tar -xOzf upstream/x86_64/test/test.db | grep -c PGPSIG; tests/fixtures/build-repo must run repo-add --include-sigs"
sync 1 x86_64-test x86_64-kr aarch64-port
check "first sync: the plan finds work" pending "$(state_of 1 plan)" "tests/integration/10-pipeline.sh, then read out/1/plan.log"
check "first sync: the database is staged" staged "$(state_of 1 stage)" "read out/1/stage-x86_64-test.log"
if [ -s "$work/out/1/stage/x86_64-test/promoted.tsv" ]; then
  ok "first sync: the database is promoted"
else
  fail "first sync: the database is promoted" "no promoted.tsv"
  logs_of 1
fi
check "each target gets shards of its own" \
  '[{"target":"aarch64-port","n":2},{"target":"x86_64-kr","n":1},{"target":"x86_64-test","n":2}]' \
  "$(jq -c '[.include[] | {target, n: (.shards | length)}] | sort_by(.target)' "$work/out/1/plan/targets.json")" \
  "jq . out/1/plan/targets.json"
check "no pending target is without files" '{"include":[]}' "$(jq -c . "$work/out/1/plan/pending.json")" "jq . out/1/plan/pending.json"
check "a shard holds the work of its own target only" 0 \
  "$(for t in x86_64-test x86_64-kr aarch64-port; do awk -F '\t' -v t="$t" '$1 != t' "$work/out/1/plan/$t"/shards/*.tsv; done | awk 'END { print NR + 0 }')" \
  "cut -f 1 out/1/plan/*/shards/*.tsv"
check "verify compares each .sig pacman stored with its %PGPSIG%, in both caches" 4 \
  "$(sed -n 's/^\([0-9][0-9]*\) signature(s) compared$/\1/p' "$work/out/1/verify/verify-x86_64-test-0.log")" \
  "read out/1/verify/verify-x86_64-test-0.log"
if grep -q 'keyring_from x86_64-kr has no latest yet; the refresh is skipped' "$work/out/1/verify/verify-x86_64-test-0.log"; then
  ok "keyring_from with no latest yet: the refresh is skipped, with a warning, and verify goes on"
else
  fail "keyring_from with no latest yet: the refresh is skipped, with a warning, and verify goes on" \
    "read out/1/verify/verify-x86_64-test-0.log"
fi
check "the keyring_from target is promoted" staged "$(state_of 1 stage x86_64-kr)" "read out/1/stage-x86_64-kr.log"
check "the keyring_from target's keyring package is a canary of its own" test-keyring \
  "$(cat "$work/out/1/stage/x86_64-kr/canaries.txt" 2> /dev/null || echo none)" "cat out/1/stage/x86_64-kr/canaries.txt"

for f in 'alpha-1:1.0+r2-1-any.pkg.tar.zst' 'beta_pc-2.0-1-x86_64.pkg.tar.zst' 'gamma-3.0-1-any.pkg.tar.zst'; do
  tag="$("$REPO_ROOT/client/pacman-oci" --tag "$f")"
  m="$(manifest "$tag")" || m=""
  titles="$(printf '%s' "$m" | jq -r '[.layers[]?.annotations["org.opencontainers.image.title"]] | join(" ")')"
  check "$f is under $tag with itself and its signature" "$f $f.sig" "$titles" "curl $BASE/manifests/$tag"
  want="$(sha256sum "$work/upstream/x86_64/test/$f" | cut -d ' ' -f 1)"
  got="$(printf '%s' "$m" | jq -r --arg t "$f" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
  check "$f layer is the upstream bytes" "sha256:$want" "$got" "curl $BASE/manifests/$tag"
  sig_want="$(pgpsig_of "$f" | base64 -d | sha256sum | cut -d ' ' -f 1)"
  sig_got="$(printf '%s' "$m" | jq -r --arg t "$f.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
  check "$f signature layer is its %PGPSIG%, decoded" "sha256:$sig_want" "$sig_got" "curl $BASE/manifests/$tag"
done

latest1="$(digest_of latest)"
day="$(sed -n 's/^FETCHED=\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T.*/\1.\2.\3/p' "$work/out/1/plan/x86_64-test/meta.env")"
check "latest and the dated tag name the same snapshot" "$latest1" "$(digest_of "$day")" "curl -I $BASE/manifests/$day"
db_hex="$(sha256sum "$work/upstream/x86_64/test/test.db" | cut -d ' ' -f 1)"
check "the snapshot is also tagged by its database's content" "$latest1" "$(digest_of "db-$db_hex")" "curl -I $BASE/manifests/db-$db_hex"

# The index of each target: what the run left on the registry, for the next
# run (scripts/index-write)
indexed=""
for t in x86_64-test x86_64-kr aarch64-port; do
  indexed="$indexed $(cat "$work/out/1/index-$t.rc" 2> /dev/null || echo none):$([ -n "$(digest_of index "it/mirror/${t%%-*}/${t#*-}")" ] && echo tag || echo 'no tag')"
done
check "first sync: index-write ends 0, and each target has its tag index" " 0:tag 0:tag 0:tag" "$indexed" "read out/1/index-*.log"
check "the index of x86_64-test vouches for its 3 files, each verified" \
  "alpha-1:1.0+r2-1-any.pkg.tar.zst m 1 0; beta_pc-2.0-1-x86_64.pkg.tar.zst m 1 0; gamma-3.0-1-any.pkg.tar.zst m 1 0" \
  "$(index_rows "$REPO")" "read out/1/index-x86_64-test.log"
check "the index is an artifact of its own type, of this plan, about the database it describes" \
  "application/vnd.pkgforge.archlinux.index.v1 $(cat "$work/out/1/plan/plan-id") $db_hex 1" \
  "$(manifest index | jq -r '[.artifactType, .annotations["dev.pkgforge.mirror.plan-id"], .annotations["dev.pkgforge.mirror.db-sha256"], .annotations["dev.pkgforge.mirror.index-format"]] | join(" ")')" \
  "curl $BASE/manifests/index | jq '.artifactType, .annotations'"

#---------------------------------------------------------------------------#
# 1b. Package manifests are the same bytes whoever pushes them: a second
#     writer, in another repository, starting each shard from the other
#     server, pushes manifests of the same digests.
#---------------------------------------------------------------------------#
alpha='alpha-1:1.0+r2-1-any.pkg.tar.zst'
manifest "$("$REPO_ROOT/client/pacman-oci" --tag "$alpha")" > "$work/alpha.json"
check "a package manifest's created time is its build date" 2023-11-14T22:13:20Z \
  "$(jq -r '.annotations["org.opencontainers.image.created"]' "$work/alpha.json")" "curl $BASE/manifests/<alpha tag> | jq .annotations"
check "a package manifest names no upstream server" 0 \
  "$(jq '[.annotations | keys[] | select(test("upstream"))] | length' "$work/alpha.json")" "curl $BASE/manifests/<alpha tag> | jq .annotations"
for s in "$work/out/1/plan/x86_64-test"/shards/*.tsv; do
  i="$(basename "$s" .tsv)"
  rc=0
  MIRROR_NAMESPACE=it/second SHARD_INDEX="$((i + 1))" "$REPO_ROOT/scripts/mirror-shard" "$s" "$work/out/second/$i" \
    > "$work/out/second-$i.log" 2>&1 || rc=$?
done
same=0
differ=""
while IFS=$'\t' read -r _ f tag _; do
  if [ -n "$(digest_of "$tag")" ] && [ "$(digest_of "$tag")" = "$(digest_of "$tag" it/second/x86_64/test)" ]; then
    same=$((same + 1))
  else
    differ="$differ $f"
  fi
done < <(cat "$work/out/1/plan/x86_64-test"/shards/*.tsv)
check "two writers push byte-identical package manifests" "3" "$same" "differ:$differ; read out/second-*.log"
check "the second writer read the bytes from the other server" 1 \
  "$(cat "$work/out/second/0/results.tsv" "$work/out/1/results/x86_64-test/0/results.tsv" | awk -F '\t' '{ sub(/, pushed in.*/, "", $5); print $5 }' | sort -u | awk 'END { print (NR >= 2) ? 1 : 0 }')" \
  "cut -f 5 out/second/0/results.tsv out/1/results/x86_64-test/0/results.tsv"

#---------------------------------------------------------------------------#
# 1c. Another arch, verified in the x86_64 image; a NUL-only package directory;
#     upstream-refused packages promoted and listed
#---------------------------------------------------------------------------#
check "a database with a NUL-only package directory is planned" pending "$(state_of 1 plan aarch64-port)" "read out/1/plan.log"
check "the NUL-only package directory is named" ghost-1-1 "$(cat "$work/out/1/plan/aarch64-port/nul.txt" 2> /dev/null || echo none)" \
  "cat out/1/plan/aarch64-port/nul.txt"
check "the plan summary names it" 1 "$(awk -F '\t' '$1 == "aarch64-port" && $5 ~ /ghost-1-1/ { n++ } END { print n + 0 }' "$work/out/1/plan/summary.tsv")" \
  "cat out/1/plan/summary.tsv"
check "verify writes Architecture from the target" 1 "$(grep -c '^Architecture = aarch64$' "$work/out/1/verify/verify-aarch64-port-0.log")" \
  "read out/1/verify/verify-aarch64-port-0.log"
case "$(verdict_of 1 aarch64-port)" in
  passed*'2 of them upstream-refused'*) ok "an aarch64 batch passes in the x86_64 image, its upstream-refused packages listed in the verdict" ;;
  *) fail "an aarch64 batch passes in the x86_64 image, its upstream-refused packages listed in the verdict" "verdict: $(verdict_of 1 aarch64-port)" \
    "read out/1/verify/verify-aarch64-port-0.log" ;;
esac
check "the refusals are listed with their reasons" "expired-1-1-any.pkg.tar.zst sig-refused
unsigned-1-1-any.pkg.tar.zst sig-missing" \
  "$(awk -F '\t' '{ split($2, r, ":"); print $1 " " r[1] }' "$work/out/1/verify/refused-aarch64-port-0.tsv" 2> /dev/null | sort)" \
  "cat out/1/verify/refused-aarch64-port-0.tsv"
if [ -n "$(digest_of latest it/mirror/aarch64/port)" ]; then
  ok "a target with upstream-refused packages is promoted"
else
  fail "a target with upstream-refused packages is promoted" "read out/1/promote-aarch64-port.log"
fi
check "the report lists the upstream-refused packages" 2 \
  "$(grep -cE '^(expired|unsigned)-1-1-any\.pkg\.tar\.zst'$'\t''sig-' "$work/out/1/report.md")" "cat out/1/report.md"
check "the report has a row for every target" 3 "$(grep -cE '^\| (x86_64-test|x86_64-kr|aarch64-port) \| promoted \|' "$work/out/1/report.md")" \
  "cat out/1/report.md"

#---------------------------------------------------------------------------#
# 1d. The same batch with no trust root at all: pacman refuses every package
#     for its signature, and the mirror serves upstream's bytes for each. With
#     no keyring package installed and no package accepted, nothing shows the
#     trust root works, so nothing is excused.
#---------------------------------------------------------------------------#
mkdir -p "$work/targets-notrust"
grep -v '^keyring_' "$work/targets/aarch64-port.conf" > "$work/targets-notrust/aarch64-port.conf"
rc=0
TARGETS_DIR="$work/targets-notrust" "$REPO_ROOT/scripts/verify-batch" "$work/out/1/stage" aarch64-port 0 "$work/out/notrust" \
  > "$work/out/notrust.log" 2>&1 || rc=$?
case "$rc:$(cut -f 3,4 "$work/out/notrust/verify-aarch64-port-0.tsv" 2> /dev/null)" in
  1:failed*'every package of the batch was refused, and no keyring package was installed'*) ok "a trust root that accepts nothing excuses nothing" ;;
  *) fail "a trust root that accepts nothing excuses nothing" "exit $rc: $(cat "$work/out/notrust/verify-aarch64-port-0.tsv" 2> /dev/null)" \
    "read out/notrust/verify-aarch64-port-0.log" ;;
esac

#---------------------------------------------------------------------------#
# 1d2. verify looks up no key on the network. The start of verify.sh, as
#      verify-batch writes it, up to its key lockdown, runs in the verify
#      image. Then gpg looks up a packager's key by WKD on archlinux.org, as
#      pacman does for a key that is missing or expired. The lookup must fail
#      within 5 s, with the network on and off. With no lockdown and the
#      network on, it reads the key from openpgpkey.archlinux.org in about
#      1.3 s and succeeds.
#---------------------------------------------------------------------------#
awk '/^cat > "\$work\/verify.sh" << .EOS.$/ { on = 1; next } on && /^copied=\(\)$/ { exit } on { print }' \
  "$REPO_ROOT/scripts/verify-batch" > "$work/lockdown.sh"
cat >> "$work/lockdown.sh" << 'EOS'
started="$(date +%s)"
rc=0
timeout 30 gpg --homedir /etc/pacman.d/gnupg --batch --locate-external-keys eworm@archlinux.org > /tmp/wkd.log 2>&1 || rc=$?
printf '@@wkd %s %s\n' "$rc" "$(($(date +%s) - started))"
sed 's/^/  /' /tmp/wkd.log
EOS
for net in default none; do
  net_arg=()
  [ "$net" = default ] || net_arg=(--network none)
  rc=0
  "$RUNTIME" run --rm "${net_arg[@]}" -v "$REPO_ROOT/client/pacman-oci:/in/pacman-oci:ro" -v "$work/lockdown.sh:/in/lockdown.sh:ro" \
    "$ARCH_IMAGE" bash /in/lockdown.sh test x86_64 oci://x/y '' '' '' '' DatabaseOptional x > "$work/lockdown-$net.log" 2>&1 || rc=$?
  read -r w_rc w_secs <<< "$(awk '$1 == "@@wkd" { print $2, $3 }' "$work/lockdown-$net.log")"
  if [ "$rc" -eq 0 ] && [ -n "${w_rc:-}" ] && [ "$w_rc" -ne 0 ] && [ "${w_secs:-99}" -le 5 ]; then
    ok "verify's key lockdown, network $net: a WKD lookup on archlinux.org fails within 5 s"
  else
    fail "verify's key lockdown, network $net: a WKD lookup on archlinux.org fails within 5 s" \
      "container exit $rc, lookup exit ${w_rc:-none} after ${w_secs:-?} s" "read $work/lockdown-$net.log"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 12 "$work/lockdown-$net.log")
  fi
done

#---------------------------------------------------------------------------#
# 1d3. A keyring package that upstream renamed: it does not install, and the
#      verdict names the package and pacman's own words, not only the status
#      of the container.
#---------------------------------------------------------------------------#
mkdir -p "$work/targets-nokr"
sed 's/^keyring = test-keyring$/keyring = missing-keyring/' "$work/targets/x86_64-kr.conf" > "$work/targets-nokr/x86_64-kr.conf"
rc=0
TARGETS_DIR="$work/targets-nokr" "$REPO_ROOT/scripts/verify-batch" "$work/out/1/stage" x86_64-kr 0 "$work/out/nokr" \
  > "$work/out/nokr.log" 2>&1 || rc=$?
case "$rc:$(cut -f 3,4 "$work/out/nokr/verify-x86_64-kr-0.tsv" 2> /dev/null)" in
  1:failed*'missing-keyring did not install from [kr]'*'target not found'*) ok "a keyring package that does not install: the verdict names it and pacman's error line" ;;
  *) fail "a keyring package that does not install: the verdict names it and pacman's error line" \
    "exit $rc: $(cat "$work/out/nokr/verify-x86_64-kr-0.tsv" 2> /dev/null)" "read out/nokr/verify-x86_64-kr-0.log" ;;
esac

#---------------------------------------------------------------------------#
# 1e. A database with an unreadable member that is not NUL bytes is refused
#---------------------------------------------------------------------------#
build port-junk aarch64/port-junk port
mkdir -p "$work/targets-junk"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-junk|; s|/\$arch/\./\$repo$|/$arch/./port-junk|' "$work/targets/aarch64-port.conf" > "$work/targets-junk/aarch64-port.conf"
rc=0
TARGETS_DIR="$work/targets-junk" "$REPO_ROOT/scripts/plan" "$work/out/junk" > "$work/out/junk.log" 2>&1 || rc=$?
check "a database whose unreadable member is not NUL bytes is refused" error \
  "$(cat "$work/out/junk/aarch64-port/state" 2> /dev/null || echo "no state, plan exit $rc")" "read out/junk.log"
if grep -q 'junk-1-1/desc gives no record named after its directory' "$work/out/junk.log"; then
  ok "the refusal names the member"
else
  fail "the refusal names the member" "$(cat "$work/out/junk.log")"
fi

#---------------------------------------------------------------------------#
# 1e2. A plain server that does not answer, the closed port 9 on the loopback,
#      does not hold a file that upstream signs nowhere: every db_server
#      answers 404 for its .sig, so it is mirrored unsigned, its result names
#      the closed host, and verify excuses it. The same closed port as a
#      db_server holds the target. Each in a namespace of its own.
#---------------------------------------------------------------------------#
closed='http://127.0.0.1:9'
mkdir -p "$work/targets-closed" "$work/targets-closeddb"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
{ cat "$work/targets/aarch64-port.conf"; printf 'server = %s/$arch/$repo\n' "$closed"; } > "$work/targets-closed/aarch64-port.conf"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
{ cat "$work/targets/aarch64-port.conf"; printf 'db_server = %s/$arch/$repo\n' "$closed"; } > "$work/targets-closeddb/aarch64-port.conf"
TARGETS_DIR="$work/targets-closed" MIRROR_NAMESPACE=it/closed sync closed aarch64-port
unsigned_result="$(cat "$work/out/closed/results/aarch64-port"/*/results.tsv 2> /dev/null | awk -F '\t' '$2 == "unsigned-1-1-any.pkg.tar.zst" { print $3 "\t" $5 }')"
case "$unsigned_result" in
  pushed$'\t'unsigned:*'no answer from 127.0.0.1:9'*) ok "a plain server that does not answer: the file upstream signs nowhere is pushed unsigned, naming the host" ;;
  *) fail "a plain server that does not answer: the file upstream signs nowhere is pushed unsigned, naming the host" \
    "result: $unsigned_result" "cat out/closed/results/aarch64-port/*/results.tsv; read out/closed/mirror-aarch64-port-*.log" ;;
esac
check "a plain server that does not answer: the target stages, verify excuses the file as sig-missing, and it is promoted" \
  "staged passed unsigned-1-1-any.pkg.tar.zst sig-missing promoted" \
  "$(state_of closed stage aarch64-port) $(verdict_of closed aarch64-port | cut -f 1) $(awk -F '\t' '$1 == "unsigned-1-1-any.pkg.tar.zst" { split($2, r, ":"); print $1 " " r[1] }' "$work/out/closed/verify/refused-aarch64-port-0.tsv" 2> /dev/null) $([ -n "$(digest_of latest it/closed/aarch64/port)" ] && echo promoted || echo 'no latest')" \
  "read out/closed/stage-aarch64-port.log out/closed/verify/verify-aarch64-port-0.log out/closed/promote-aarch64-port.log"
TARGETS_DIR="$work/targets-closeddb" MIRROR_NAMESPACE=it/closeddb sync closeddb aarch64-port
case "$(state_of closeddb stage aarch64-port):$(cat "$work/out/closeddb/stage/aarch64-port/why" 2> /dev/null)" in
  held:*'a db_server gave no answer that decides: no answer from 127.0.0.1:9'*) ok "a db_server that does not answer holds a file that upstream signs nowhere, and the stage names the host" ;;
  *) fail "a db_server that does not answer holds a file that upstream signs nowhere, and the stage names the host" \
    "$(state_of closeddb stage aarch64-port): $(cat "$work/out/closeddb/stage/aarch64-port/why" 2> /dev/null)" "read out/closeddb/stage-aarch64-port.log" ;;
esac

#---------------------------------------------------------------------------#
# 1f. A file promoted with no signature, because upstream had none, gets its
#     signature once upstream publishes a .sig, while the database stays the
#     same: the snapshot names the file, plan asks for its .sig on each run,
#     and plans it again when one answers.
#---------------------------------------------------------------------------#
unsigned_f='unsigned-1-1-any.pkg.tar.zst'
port_repo=it/mirror/aarch64/port
check "the snapshot names the file it holds with no signature" "$unsigned_f" \
  "$(manifest latest "$port_repo" | jq -r '.annotations["dev.pkgforge.mirror.unsigned"] // "none"')" \
  "curl http://127.0.0.1:$REG_PORT/v2/$port_repo/manifests/latest | jq .annotations; read out/1/stage-aarch64-port.log"
port_db_before="$(sha256sum "$work/upstream/aarch64/port/port.db.tar.gz" | cut -d ' ' -f 1)"
port_latest_before="$(digest_of latest "$port_repo")"
build port-signed aarch64/port port
sync 1f
check "upstream signs it later, and its database stays the same" "$port_db_before" \
  "$(sha256sum "$work/upstream/aarch64/port/port.db.tar.gz" | cut -d ' ' -f 1)" "read $work/build-port-signed.log"
check "a file promoted with no signature that upstream signs now is planned again, alone" "pending $unsigned_f" \
  "$(state_of 1f plan aarch64-port) $(cut -f 2 "$work/out/1f/plan/aarch64-port/todo.tsv" 2> /dev/null | tr '\n' ' ' | sed 's/ $//')" \
  "read out/1f/plan.log"
check "its tag gets upstream's new .sig as its signature layer" \
  "sha256:$(sha256sum "$work/upstream/aarch64/port/$unsigned_f.sig" | cut -d ' ' -f 1)" \
  "$(manifest "$("$REPO_ROOT/client/pacman-oci" --tag "$unsigned_f")" "$port_repo" | jq -r --arg t "$unsigned_f.sig" '[.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest] | first // "none"')" \
  "read out/1f/mirror-aarch64-port-0.log"
port_latest_after="$(digest_of latest "$port_repo")"
check "the snapshot is verified and promoted, and names no file with no signature" "passed moved none" \
  "$(verdict_of 1f aarch64-port | cut -f 1) $([ -n "$port_latest_after" ] && [ "$port_latest_after" != "$port_latest_before" ] && echo moved || echo stayed) $(manifest latest "$port_repo" | jq -r '.annotations["dev.pkgforge.mirror.unsigned"] // "none"')" \
  "read out/1f/verify/verify-aarch64-port-0.log out/1f/promote-aarch64-port.log"

#---------------------------------------------------------------------------#
# 1g. A files database that leaves out a package of the database is upstream's
#     own defect: planned, the package named, and verify runs pacman -Fl only
#     over the names the files database holds. One that names a package the
#     database does not is planned too, and the package named. One that names
#     a file of the database with other bytes is refused. Each in a namespace
#     of its own.
#---------------------------------------------------------------------------#
build port-files-missing aarch64/port-fmiss port
mkdir -p "$work/targets-fmiss"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-fmiss|; s|/\$arch/\./\$repo$|/$arch/./port-fmiss|' "$work/targets/aarch64-port.conf" > "$work/targets-fmiss/aarch64-port.conf"
TARGETS_DIR="$work/targets-fmiss" MIRROR_NAMESPACE=it/fmiss sync fmiss aarch64-port
check "a files database that leaves out a package of the database is planned" pending "$(state_of fmiss plan aarch64-port)" \
  "read out/fmiss/plan.log"
if grep -q 'port.files leaves out package(s) of port.db, as upstream serves it: 1: expired-1-1-any.pkg.tar.zst' "$work/out/fmiss/plan.log"; then
  ok "the plan names the package the files database leaves out"
else
  fail "the plan names the package the files database leaves out" "read out/fmiss/plan.log"
fi
if grep -q 'the files database holds no entry for 1 package(s) of the batch, as upstream serves it: expired' "$work/out/fmiss/verify/verify-aarch64-port-0.log"; then
  ok "verify names the package the files database has no entry for"
else
  fail "verify names the package the files database has no entry for" "read out/fmiss/verify/verify-aarch64-port-0.log"
fi
check "verify runs pacman -Fl over the other names, passes, and the snapshot is promoted" "passed promoted" \
  "$(verdict_of fmiss aarch64-port | cut -f 1) $(cut -f 2 "$work/out/fmiss/promote-aarch64-port.tsv" 2> /dev/null)" \
  "read out/fmiss/verify/verify-aarch64-port-0.log out/fmiss/promote-aarch64-port.log"

build port-files-extra aarch64/port-fextra port
mkdir -p "$work/targets-fextra"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-fextra|; s|/\$arch/\./\$repo$|/$arch/./port-fextra|' "$work/targets/aarch64-port.conf" > "$work/targets-fextra/aarch64-port.conf"
rc=0
TARGETS_DIR="$work/targets-fextra" MIRROR_NAMESPACE=it/fextra "$REPO_ROOT/scripts/plan" "$work/out/fextra" > "$work/out/fextra.log" 2>&1 || rc=$?
check "a files database that names a package the database does not is planned" pending \
  "$(cat "$work/out/fextra/aarch64-port/state" 2> /dev/null)" "plan exit $rc; read out/fextra.log"
if grep -q 'port.files names package file(s) that port.db does not, as upstream serves it: 1: stray-1-1-any.pkg.tar.zst' "$work/out/fextra.log"; then
  ok "the plan names the package only the files database names"
else
  fail "the plan names the package only the files database names" "read out/fextra.log"
fi
# More drift than FILES_DRIFT_MAX: the files database is of another repository.
rc=0
FILES_DRIFT_MAX=0 TARGETS_DIR="$work/targets-fextra" MIRROR_NAMESPACE=it/fextra "$REPO_ROOT/scripts/plan" "$work/out/fextra0" > "$work/out/fextra0.log" 2>&1 || rc=$?
check "drift over FILES_DRIFT_MAX is refused" error \
  "$(cat "$work/out/fextra0/aarch64-port/state" 2> /dev/null)" "plan exit $rc; read out/fextra0.log"
if grep -q 'port.files differs from port.db by 1 package file(s), over FILES_DRIFT_MAX=0' "$work/out/fextra0.log"; then
  ok "the refusal names the drift and the limit"
else
  fail "the refusal names the drift and the limit" "read out/fextra0.log"
fi

# The same file name with other bytes: the files database of another snapshot.
build port-files-conflict aarch64/port-fconflict port
mkdir -p "$work/targets-fconflict"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-fconflict|; s|/\$arch/\./\$repo$|/$arch/./port-fconflict|' "$work/targets/aarch64-port.conf" > "$work/targets-fconflict/aarch64-port.conf"
rc=0
TARGETS_DIR="$work/targets-fconflict" MIRROR_NAMESPACE=it/fconflict "$REPO_ROOT/scripts/plan" "$work/out/fconflict" > "$work/out/fconflict.log" 2>&1 || rc=$?
case "$(cat "$work/out/fconflict/aarch64-port/state" 2> /dev/null):$(cat "$work/out/fconflict/aarch64-port/why" 2> /dev/null)" in
  "error:no db_server that served port.db "*" also served a port.files that matches it"*) ok "a files database that names a file of the database with other bytes is refused" ;;
  *) fail "a files database that names a file of the database with other bytes is refused" "plan exit $rc: $(cat "$work/out/fconflict/aarch64-port/why" 2> /dev/null)" \
    "read out/fconflict.log" ;;
esac
if grep -q 'port.files and port.db name 1 file(s) with other sha256 values, e.g. unsigned-1-1-any.pkg.tar.zst' "$work/out/fconflict.log"; then
  ok "the refusal names the file"
else
  fail "the refusal names the file" "read out/fconflict.log"
fi

#---------------------------------------------------------------------------#
# 1e3. A package the database names but upstream no longer serves: every server
#      answers 404 for its file. The mirror skips it as absent and still stages
#      and promotes the target, rather than holding the whole target for one
#      stale upstream entry. As ArchPOWER's powerpc base names
#      kwayland-server-debug with the file gone.
#---------------------------------------------------------------------------#
build pkg-missing aarch64/port-gone port
mkdir -p "$work/targets-gone"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-gone|; s|/\$arch/\./\$repo$|/$arch/./port-gone|' "$work/targets/aarch64-port.conf" > "$work/targets-gone/aarch64-port.conf"
TARGETS_DIR="$work/targets-gone" MIRROR_NAMESPACE=it/gone sync gone aarch64-port
check "a file upstream no longer serves is skipped as absent, and the target stages and promotes" "staged promoted" \
  "$(state_of gone stage aarch64-port) $(cut -f 2 "$work/out/gone/promote-aarch64-port.tsv" 2> /dev/null)" \
  "read out/gone/stage-aarch64-port.log out/gone/promote-aarch64-port.log"
if grep -q 'gone from upstream (404)' "$work/out/gone/stage-aarch64-port.log"; then
  ok "the stage names the file(s) it skipped as absent"
else
  fail "the stage names the file(s) it skipped as absent" "read out/gone/stage-aarch64-port.log"
fi

#---------------------------------------------------------------------------#
# 1e4. A package the database lists for another architecture (upstream mixes
#      arches, as ArchPOWER's powerpc64 base carries powerpc64le packages):
#      pacman refuses it, but the mirror serves it faithfully, so verify excuses
#      it as upstream-refused and the target stages and promotes.
#---------------------------------------------------------------------------#
build pkg-crossarch aarch64/port-cross port
mkdir -p "$work/targets-cross"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-cross|; s|/\$arch/\./\$repo$|/$arch/./port-cross|' "$work/targets/aarch64-port.conf" > "$work/targets-cross/aarch64-port.conf"
TARGETS_DIR="$work/targets-cross" MIRROR_NAMESPACE=it/cross sync cross aarch64-port
check "a cross-arch package is excused as upstream-refused, and the target stages and promotes" "staged promoted" \
  "$(state_of cross stage aarch64-port) $(cut -f 2 "$work/out/cross/promote-aarch64-port.tsv" 2> /dev/null)" \
  "read out/cross/stage-aarch64-port.log out/cross/verify/verify-aarch64-port-0.log out/cross/promote-aarch64-port.log"
if grep -h -- 'cross-1-1-x86_64.pkg.tar.zst' "$work/out/cross/verify"/refused-aarch64-port-*.tsv 2>/dev/null | grep -q 'arch:'; then
  ok "verify names the cross-arch package as upstream-refused for its architecture"
else
  fail "verify names the cross-arch package as upstream-refused for its architecture" \
    "read out/cross/verify/refused-aarch64-port-0.tsv out/cross/verify/verify-aarch64-port-0.log"
fi

# A files database that lags a mass rebuild: 12 of 40 packages at their
# earlier file names, 24 file names that only one of the two databases names.
# That is more than the larger of 16 and half the records, and is still the
# files database of this repository: every package is named. One that names
# none of the packages is of another repository.
# files_plan NAME STATE: plan a target whose upstream is build-repo STATE
files_plan() {
  local rc=0
  build "$2" "aarch64/port-$1" port
  mkdir -p "$work/targets-$1"
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  sed 's|/\$arch/\$repo$|/$arch/port-'"$1"'|; s|/\$arch/\./\$repo$|/$arch/./port-'"$1"'|' "$work/targets/aarch64-port.conf" > "$work/targets-$1/aarch64-port.conf"
  TARGETS_DIR="$work/targets-$1" MIRROR_NAMESPACE="it/$1" "$REPO_ROOT/scripts/plan" "$work/out/$1" > "$work/out/$1.log" 2>&1 || rc=$?
  printf '%s\n' "$(cat "$work/out/$1/aarch64-port/state" 2> /dev/null || echo "no state, plan exit $rc")"
}
check "a files database that lags 12 rebuilt packages of 40 is planned" pending "$(files_plan flag files-lag)" "read out/flag.log"
if grep -q 'port.files names package(s) of port.db at another file name, as upstream serves it (the files database lags): 12: p01 p02 p03 p04 p05 p06 p07 p08 p09 p10 p11 p12$' "$work/out/flag.log"; then
  ok "the plan names the 12 packages the files database names at an earlier file name"
else
  fail "the plan names the 12 packages the files database names at an earlier file name" "read out/flag.log"
fi
check "a files database that names none of the packages is refused" error "$(files_plan fother files-other)" "read out/fother.log"
if grep -q 'port.files names 0 of the 40 packages of port.db: it is the files database of another repository' "$work/out/fother.log"; then
  ok "the refusal names how many packages the files database names"
else
  fail "the refusal names how many packages the files database names" "read out/fother.log"
fi

#---------------------------------------------------------------------------#
# 2. Consumers: pacman through the wrapper, nothing else
#---------------------------------------------------------------------------#
consumer() {
  local label="$1" server="$2" keep_download_user="$3" extra="${4:-}"
  cat > "$work/consumer.sh" << 'EOS'
set -euo pipefail
server="$1" keep="$2" extra="$3"
install -m 0755 /in/pacman-oci /usr/local/bin/pacman-oci
awk '
  /^\[/ { inopt = ($0 == "[options]") }
  inopt && /^[[:space:]]*XferCommand/ { next }
  inopt { print }
  /^\[options\]/ && !d { print "XferCommand = /usr/local/bin/pacman-oci %o %u"; d = 1 }
' /etc/pacman.conf > /tmp/pacman.conf
if [ "$keep" != yes ]; then
  sed -i '/^[[:space:]]*DownloadUser/d' /tmp/pacman.conf
fi
printf '\n[test]\nServer = %s\n' "$server" >> /tmp/pacman.conf
if [ -n "$extra" ]; then
  printf 'Server = %s\n' "$extra" >> /tmp/pacman.conf
fi
pacman-key --init > /tmp/key.log 2>&1
pacman-key --add /in/test.asc >> /tmp/key.log 2>&1
pacman-key --lsign-key "$(gpg --with-colons --show-keys /in/test.asc | awk -F : '$1 == "fpr" && f == "" { f = $10 } END { print f }')" >> /tmp/key.log 2>&1
pac() { pacman --config /tmp/pacman.conf --noconfirm "$@"; }
pac -Sy
pac -S alpha beta_pc gamma
cat /usr/share/mirror-test/alpha /usr/share/mirror-test/beta_pc /usr/share/mirror-test/gamma
pac -Fy
pacman --config /tmp/pacman.conf -Fl gamma
echo CONSUMER-OK
EOS
  local rc=0
  "$RUNTIME" run --rm --network host \
    -v "$REPO_ROOT/client/pacman-oci:/in/pacman-oci:ro" \
    -v "$work/upstream/test.asc:/in/test.asc:ro" \
    -v "$work/consumer.sh:/in/consumer.sh:ro" \
    "$ARCH_IMAGE" bash /in/consumer.sh "$server" "$keep_download_user" "$extra" > "$work/consumer-$label.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -q CONSUMER-OK "$work/consumer-$label.log"; then
    ok "consumer, $label: pacman -Sy, -S and -Fy through the wrapper"
  else
    fail "consumer, $label: pacman -Sy, -S and -Fy through the wrapper" "exit $rc"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 25 "$work/consumer-$label.log")
  fi
}

consumer "stock DownloadUser" "oci+http://127.0.0.1:$REG_PORT/$REPO" yes
consumer "no DownloadUser" "oci+http://127.0.0.1:$REG_PORT/$REPO" no
consumer "a snapshot pinned by digest" "oci+http://127.0.0.1:$REG_PORT/$REPO@$latest1" yes
consumer "a dated snapshot" "oci+http://127.0.0.1:$REG_PORT/$REPO:$day" yes
consumer "the registry missing, upstream after it" "oci+http://127.0.0.1:$REG_PORT/it/nowhere/x86_64/test" yes \
  "$UP/x86_64/test"

#---------------------------------------------------------------------------#
# 3. Nothing changed upstream: nothing to do
#---------------------------------------------------------------------------#
sync 2
check "an unchanged upstream is current" current "$(state_of 2 plan)" "read out/2/plan.log"
check "an unchanged upstream leaves latest where it was" "$latest1" "$(digest_of latest)" "curl -I $BASE/manifests/latest"
check "every target is current, and the report says so" "current current current 0" \
  "$(state_of 2 plan x86_64-test) $(state_of 2 plan x86_64-kr) $(state_of 2 plan aarch64-port) $(cat "$work/out/2/report.rc")" \
  "cat out/2/plan/summary.tsv out/2/report.md"

#---------------------------------------------------------------------------#
# 3b. A db_server that accepts and never answers, listed first. Each read of
#     it ends within its part of the target's share of PLAN_BUDGET, the next
#     db_server is read, and the plan ends within PLAN_BUDGET. A target whose
#     only db_server never answers is in error, and its why names the budget.
#     With no deadline over the retries, each read of it took 184 s.
#---------------------------------------------------------------------------#
mkdir -p "$work/targets-slow"
for t in x86_64-kr x86_64-test; do
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  { printf 'db_server = %s/stall/$arch/$repo\n' "$BROKEN"; cat "$work/targets/$t.conf"; } > "$work/targets-slow/$t.conf"
done
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
printf 'arch = x86_64\nrepo = stalled\ndb_server = %s/stall/$arch/$repo\n' "$BROKEN" > "$work/targets-slow/x86_64-stalled.conf"
started_at=$SECONDS
rc=0
TARGETS_DIR="$work/targets-slow" PLAN_BUDGET=40 "$REPO_ROOT/scripts/plan" "$work/out/slow" > "$work/out/slow.log" 2>&1 || rc=$?
took=$((SECONDS - started_at))
check "a db_server that never answers gives way to the next one, and the targets are current" "0 current current" \
  "$rc $(cat "$work/out/slow/x86_64-kr/state" 2> /dev/null || echo none) $(cat "$work/out/slow/x86_64-test/state" 2> /dev/null || echo none)" \
  "read out/slow.log"
check "the plan ends within PLAN_BUDGET=40 s, with 15 s for its registry reads" "within 55 s" \
  "$([ "$took" -le 55 ] && echo 'within 55 s' || echo "after $took s")" "read out/slow.log"
check "each read of the stalled db_server ends within its part of the share, not DB_MAX_TIME (300 s)" 3 \
  "$(grep -cE "/stall/x86_64/(kr|test|stalled)/(kr|test|stalled)\.db did not answer within [0-9]{1,2}s" "$work/out/slow.log")" "read out/slow.log"
case "$(cat "$work/out/slow/x86_64-stalled/state" 2> /dev/null):$(cat "$work/out/slow/x86_64-stalled/why" 2> /dev/null)" in
  error:*PLAN_BUDGET=40s*) ok "a target whose only db_server never answers is in error, and its why names the budget" ;;
  *) fail "a target whose only db_server never answers is in error, and its why names the budget" \
    "$(cat "$work/out/slow/x86_64-stalled/why" 2> /dev/null)" "read out/slow.log" ;;
esac

#---------------------------------------------------------------------------#
# 4. Two packages new, one of them signed by a key only the keyring package
#    of x86_64-kr holds: only they are mirrored, verify installs that keyring
#    package from kr's latest, latest moves, the day's tag keeps the first
#    snapshot
#---------------------------------------------------------------------------#
build two
sync 3
check "an update is planned as its new files only" 2 "$(awk 'END { print NR + 0 }' "$work/out/3/plan/x86_64-test/todo.tsv")" "read out/3/plan/x86_64-test/todo.tsv"
check "the update is staged" staged "$(state_of 3 stage)" "read out/3/stage-x86_64-test.log"
case "$(verdict_of 3)" in
  *upstream-refused*) fail "a package signed by a key only keyring_from's keyring package holds passes, refused by nothing" \
    "verdict: $(verdict_of 3)" "the keyring package was not installed: read out/3/verify/verify-x86_64-test-0.log" ;;
  passed*) ok "a package signed by a key only keyring_from's keyring package holds passes, refused by nothing" ;;
  *) fail "a package signed by a key only keyring_from's keyring package holds passes, refused by nothing" "verdict: $(verdict_of 3)" \
    "read out/3/verify/verify-x86_64-test-0.log" ;;
esac
if grep -q '^== .* keyring: install test-keyring from \[kr\]$' "$work/out/3/verify/verify-x86_64-test-0.log"; then
  ok "verify installs the keyring package from keyring_from's repository"
else
  fail "verify installs the keyring package from keyring_from's repository" "read out/3/verify/verify-x86_64-test-0.log"
fi
kr_latest="$(digest_of latest it/mirror/x86_64/kr)"
check "verify reads keyring_from's repository pinned by the digest its latest names" 1 \
  "$(grep -cxF "Server = oci+http://127.0.0.1:$REG_PORT/it/mirror/x86_64/kr@$kr_latest" "$work/out/3/verify/verify-x86_64-test-0.log")" \
  "read out/3/verify/verify-x86_64-test-0.log"
latest3="$(digest_of latest)"
if [ -n "$latest3" ] && [ "$latest3" != "$latest1" ]; then
  ok "latest moved to the new snapshot"
else
  fail "latest moved to the new snapshot" "latest is $latest3"
  logs_of 3
fi
check "the dated tag still names the day's first snapshot" "$latest1" "$(digest_of "$day")" "curl -I $BASE/manifests/$day"

# The first run's stage and verdicts, promoted again after a later run: what a
# "re-run failed jobs" days later would do. It must not move latest back.
rc=0
"$REPO_ROOT/scripts/promote" "$work/out/1/stage" "$work/out/1/verify" x86_64-test > "$work/out/promote-again.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'before the one latest names' "$work/out/promote-again.log"; then
  ok "promoting an older run's snapshot again is refused"
else
  fail "promoting an older run's snapshot again is refused" "exit $rc" "$(tail -n 3 "$work/out/promote-again.log")"
fi
check "latest stays on the newer snapshot" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 4a. "Re-run all jobs" plans again, and the download of results-<target>-*
#     still returns an earlier attempt's results beside this plan's. stage
#     reads only this plan's: a stale "failed" for a file this plan's shard
#     pushed holds nothing. The layout is the workflow's, one directory per
#     artifact, and the stale line comes last, as it would win.
#---------------------------------------------------------------------------#
rr="$work/out/rerun-results"
rm -rf "$rr"
for d in "$work/out/3/results/x86_64-test"/*/; do
  n="$(basename "$d")"
  mkdir -p "$rr/results-x86_64-test-$n/$n"
  cp "$d/results.tsv" "$d/plan-id" "$rr/results-x86_64-test-$n/$n/"
done
stale_f="$(cut -f 2 "$work/out/3/plan/x86_64-test/todo.tsv" | sed -n 1p)"
mkdir -p "$rr/results-x86_64-test-7/7/lines"
printf 'earlier-attempt\n' > "$rr/results-x86_64-test-7/7/plan-id"
printf 'x86_64-test\t%s\tfailed\t600\tpush timed out\n' "$stale_f" > "$rr/results-x86_64-test-7/7/lines/1.tsv"
rc=0
STAGING_TAG=staging-rerun "$REPO_ROOT/scripts/stage" "$work/out/3/plan" "$rr" "$work/out/rerun-stage" x86_64-test \
  > "$work/out/rerun-stage.log" 2>&1 || rc=$?
check "a re-run's stage reads no result of an earlier plan" "0 staged" \
  "$rc $(cat "$work/out/rerun-stage/x86_64-test/state" 2> /dev/null || echo 'no state')" "read out/rerun-stage.log"
if grep -q "results-x86_64-test-7/7 holds the results of plan 'earlier-attempt'" "$work/out/rerun-stage.log"; then
  ok "the stage log names the results it left out"
else
  fail "the stage log names the results it left out" "read out/rerun-stage.log"
fi
check "the stage carries its plan id, for the report" "$(cat "$work/out/3/plan/plan-id")" \
  "$(cat "$work/out/rerun-stage/x86_64-test/plan-id" 2> /dev/null || echo none)" "ls out/rerun-stage/x86_64-test"

#---------------------------------------------------------------------------#
# 4b. Upstream signs a file again, its bytes unchanged: the file is planned,
#     and its signature layer is repaired under the same tag
#---------------------------------------------------------------------------#
alpha_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$alpha")"
alpha_pkg_before="$(manifest "$alpha_tag" | jq -r --arg t "$alpha" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
build resigned
sync 4
check "a file signed again with the same bytes is planned" "$alpha" "$(cut -f 2 "$work/out/4/plan/x86_64-test/todo.tsv")" \
  "read out/4/plan/x86_64-test/todo.tsv"
check "its signature layer is pushed again" pushed "$(cat "$work/out/4/results/x86_64-test"/*/results.tsv | awk -F '\t' -v f="$alpha" '$2 == f { print $3 }')" \
  "cat out/4/results/x86_64-test/*/results.tsv"
manifest "$alpha_tag" > "$work/alpha.json"
check "the repaired signature layer is the new %PGPSIG%" "sha256:$(pgpsig_of "$alpha" | base64 -d | sha256sum | cut -d ' ' -f 1)" \
  "$(layer_of "$work/alpha.json" "$alpha.sig")" "curl $BASE/manifests/$alpha_tag"
check "its package layer is the same blob" "$alpha_pkg_before" "$(layer_of "$work/alpha.json" "$alpha")" "curl $BASE/manifests/$alpha_tag"
latest4="$(digest_of latest)"
if [ -n "$latest4" ] && [ "$latest4" != "$latest3" ]; then
  ok "the snapshot with the new signature is promoted"
else
  fail "the snapshot with the new signature is promoted" "latest is $latest4" "read out/4/verify/verify-x86_64-test-0.log"
fi

#---------------------------------------------------------------------------#
# 4c. A signature layer that is not the %PGPSIG%, written on the registry
#     behind the mirror's back to a file plan skips: verify fails the batch,
#     and nothing excuses it as upstream's
#---------------------------------------------------------------------------#
build four
tamper_canary
sync 5
check "the smallest package, the canary, is not new in this update" "theta-1-1-any.pkg.tar.zst" "$(cut -f 2 "$work/out/5/plan/x86_64-test/todo.tsv")" \
  "read out/5/plan/x86_64-test/todo.tsv; the canary is $canary"
case "$(verdict_of 5)" in
  failed*"$canary: its .sig is sha256"*) ok "a signature layer that is not the %PGPSIG% fails verify, and is named" ;;
  *) fail "a signature layer that is not the %PGPSIG% fails verify, and is named" "verdict: $(verdict_of 5)" "read out/5/verify/verify-x86_64-test-0.log" ;;
esac
check "a batch with a bad signature layer is never promoted" "$latest4" "$(digest_of latest)" "curl -I $BASE/manifests/latest"
put_manifest "$canary_tag" "$work/canary-good.json" || diag "the canary manifest could not be written back"
check "the canary's manifest is restored" "sha256:$(sha256sum "$work/canary-good.json" | cut -d ' ' -f 1)" "$(digest_of "$canary_tag")" \
  "curl -I $BASE/manifests/$canary_tag"

#---------------------------------------------------------------------------#
# 5. Upstream goes back to an older database: refused, latest stays
#---------------------------------------------------------------------------#
build one
sync 6
check "an older upstream database is refused as behind" behind "$(state_of 6 plan)" "read out/6/plan.log"
check "latest does not move backwards" "$latest4" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 6. A file changes under its own name: held, nothing overwritten
#---------------------------------------------------------------------------#
build replaced
beta_tag="$("$REPO_ROOT/client/pacman-oci" --tag 'beta_pc-2.0-1-x86_64.pkg.tar.zst')"
beta_before="$(digest_of "$beta_tag")"
sync 7
check "a file whose bytes changed under its own name holds the target" replaced "$(state_of 7 stage)" "read out/7/stage-x86_64-test.log"
check "its tag is not overwritten" "$beta_before" "$(digest_of "$beta_tag")" "curl -I $BASE/manifests/$beta_tag"
check "latest stays" "$latest4" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 7. A new file whose tag already holds other bytes: held, never pushed over
#---------------------------------------------------------------------------#
build three
delta='delta-1-1-any.pkg.tar.zst'
delta_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$delta")"
mkdir -p "$work/bogus"
printf 'not the package\n' > "$work/bogus/$delta"
ORAS_BIN="$("$REPO_ROOT/scripts/install-oras" "$work/bin")"
(cd "$work/bogus" && timeout 120 "$ORAS_BIN" push --plain-http "$MIRROR_REGISTRY/$REPO:$delta_tag" \
  "./$delta:application/vnd.pkgforge.archlinux.pkg.v1" > /dev/null)
bogus="$(digest_of "$delta_tag")"
sync 8
check "a new file whose tag already holds other bytes holds the target" replaced "$(state_of 8 stage)" "read out/8/stage-x86_64-test.log"
check "the conflicting tag is not overwritten" "$bogus" "$(digest_of "$delta_tag")" "curl -I $BASE/manifests/$delta_tag"
check "latest stays through a conflict" "$latest4" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 8. Two db_servers that disagree: each is ahead of the other on one package
#    and behind on another, and neither is behind what is promoted. Nothing
#    says which is newer, so the target is held, not guessed.
#---------------------------------------------------------------------------#
build ahead-alpha
build ahead-gamma x86_64/test-b
mkdir -p "$work/targets-two"
cp "$work/targets/x86_64-kr.conf" "$work/targets-two/"
{
  grep -v '^db_server' "$work/targets/x86_64-test.conf"
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  printf 'db_server = %s/$arch/$repo\ndb_server = %s/$arch/test-b\n' "$UP" "$UP"
} > "$work/targets-two/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-two" "$REPO_ROOT/scripts/plan" "$work/out/held" "$work/targets-two/x86_64-test.conf" > "$work/out/held.log" 2>&1 || rc=$?
check "db_servers that disagree hold the target" held \
  "$(cat "$work/out/held/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc")" "read out/held.log"

#---------------------------------------------------------------------------#
# 9. A package signed by a key nobody trusts: pacman refuses it, from the
#    mirror as from upstream, and the mirror serves upstream's bytes and
#    signature. It is upstream-refused: listed, and the snapshot promoted.
#---------------------------------------------------------------------------#
build untrusted
sync 9
check "a package with an untrusted signature is staged" staged "$(state_of 9 stage)" "read out/9/stage-x86_64-test.log"
case "$(verdict_of 9)" in
  passed*'1 of them upstream-refused'*epsilon*) ok "verify lists it as upstream-refused, and passes the batch" ;;
  *) fail "verify lists it as upstream-refused, and passes the batch" "verdict: $(verdict_of 9)" "read out/9/verify/verify-x86_64-test-0.log" ;;
esac
latest9="$(digest_of latest)"
if [ -n "$latest9" ] && [ "$latest9" != "$latest4" ]; then
  ok "a snapshot whose only fault is upstream's is promoted"
else
  fail "a snapshot whose only fault is upstream's is promoted" "latest is $latest9" "read out/9/promote-x86_64-test.log"
fi

#---------------------------------------------------------------------------#
# 9b. A database with no %PGPSIG%, as most of archriscv's: the signature of a
#     new package comes from upstream's detached .sig, byte for byte, and
#     pacman verifies against it through the wrapper.
#---------------------------------------------------------------------------#
build nopgpsig
check "the fixture's database carries no %PGPSIG%" 0 "$(pgpsig_count)" "tar -xOzf upstream/x86_64/test/test.db | grep -c PGPSIG"
sync 10
check "a database without %PGPSIG% stages" staged "$(state_of 10 stage)" "read out/10/stage-x86_64-test.log"
zeta='zeta-1-1-any.pkg.tar.zst'
zeta_sig="$(manifest "$("$REPO_ROOT/client/pacman-oci" --tag "$zeta")" | jq -r --arg t "$zeta.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
check "its signature layer is upstream's detached .sig" "sha256:$(sha256sum "$work/upstream/x86_64/test/$zeta.sig" | cut -d ' ' -f 1)" "$zeta_sig" "curl $BASE/manifests/<zeta tag>"
check "pacman verifies it against that .sig" passed "$(verdict_of 10 | cut -f 1)" "read out/10/verify/verify-x86_64-test-0.log"
latest10="$(digest_of latest)"

#---------------------------------------------------------------------------#
# 9c. A lagging db_server that only drops a package: its database differs from
#     the promoted one with no package built earlier or later, so nothing says
#     it is newer. Listed first, it would win; the promoted database, still
#     served by the other db_server, is kept instead.
#---------------------------------------------------------------------------#
build two x86_64/test-b
mkdir -p "$work/targets-lag"
cp "$work/targets/x86_64-kr.conf" "$work/targets-lag/"
{
  grep -v '^db_server' "$work/targets/x86_64-test.conf"
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  printf 'db_server = %s/$arch/test-b\ndb_server = %s/$arch/$repo\n' "$UP" "$UP"
} > "$work/targets-lag/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-lag" "$REPO_ROOT/scripts/plan" "$work/out/lag" "$work/targets-lag/x86_64-test.conf" > "$work/out/lag.log" 2>&1 || rc=$?
check "a lagging db_server that only drops a package does not move latest" current \
  "$(cat "$work/out/lag/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc")" "read out/lag.log"

#---------------------------------------------------------------------------#
# 9d. With no %PGPSIG%, a signature layer that is not upstream's .sig: pacman
#     refuses the package for its signature, and the account of the refusal
#     finds the mirror at fault, not upstream: the batch fails. plan compares
#     a sample of these layers with upstream's .sig and repairs one that
#     differs (9g), so the layer is written after stage, before verify.
#---------------------------------------------------------------------------#
build nopgpsig-four
# tamper_test_canary TARGET: tamper_canary, for x86_64-test only
tamper_test_canary() {
  [ "$1" = x86_64-test ] || return 0
  tamper_canary
}
AFTER_STAGE=tamper_test_canary sync 11
check "the canary is not new in this update either" "theta-1-1-any.pkg.tar.zst" "$(cut -f 2 "$work/out/11/plan/x86_64-test/todo.tsv")" \
  "read out/11/plan/x86_64-test/todo.tsv; the canary is $canary"
case "$(verdict_of 11)" in
  failed*"${canary%%-[0-9]*} (sig-refused"*) ok "a signature layer that is not upstream's .sig is not excused as upstream-refused" ;;
  *) fail "a signature layer that is not upstream's .sig is not excused as upstream-refused" "verdict: $(verdict_of 11)" \
    "read out/11/verify/verify-x86_64-test-0.log" ;;
esac
check "it is never promoted" "$latest10" "$(digest_of latest)" "curl -I $BASE/manifests/latest"
put_manifest "$canary_tag" "$work/canary-good.json" || diag "the canary manifest could not be written back"

#---------------------------------------------------------------------------#
# 9e. With no %PGPSIG%, the signature layer is the .sig of the target's
#     servers in their own order, the db_servers first, as verify reads it.
#     A shard whose package reads start at a plain server that serves other
#     .sig bytes still pushes the db_server's. Each in a namespace of its own.
#---------------------------------------------------------------------------#
rm -rf "$work/upstream/x86_64/test-plain"
cp -r "$work/upstream/x86_64/test" "$work/upstream/x86_64/test-plain"
mapfile -t plain_sigs < <(cd "$work/upstream/x86_64/test-plain" && ls -- *.pkg.tar.zst.sig)
for ((i = 0; i < ${#plain_sigs[@]}; i++)); do
  cp "$work/upstream/x86_64/test/${plain_sigs[$(((i + 1) % ${#plain_sigs[@]}))]}" "$work/upstream/x86_64/test-plain/${plain_sigs[$i]}"
done
mkdir -p "$work/targets-sigsrc"
cp "$work/targets/x86_64-kr.conf" "$work/targets-sigsrc/"
# shellcheck disable=SC2016 # $arch is the target file's, not the shell's
sed 's|^server = .*$|server = '"$UP"'/$arch/test-plain|' "$work/targets/x86_64-test.conf" > "$work/targets-sigsrc/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-sigsrc" MIRROR_NAMESPACE=it/sigsrc MAX_SHARDS=1 "$REPO_ROOT/scripts/plan" "$work/out/sigsrc" \
  "$work/targets-sigsrc/x86_64-test.conf" > "$work/out/sigsrc.log" 2>&1 || rc=$?
# Shard index 1 of two servers: the shard reads packages from test-plain first.
TARGETS_DIR="$work/targets-sigsrc" MIRROR_NAMESPACE=it/sigsrc SHARD_INDEX=1 "$REPO_ROOT/scripts/mirror-shard" \
  "$work/out/sigsrc/x86_64-test/shards/0.tsv" "$work/out/sigsrc-results" >> "$work/out/sigsrc.log" 2>&1 || rc=$?
same=0
differ=""
while IFS=$'\t' read -r _ f tag _; do
  if [ "$(manifest "$tag" it/sigsrc/x86_64/test | jq -r --arg t "$f.sig" '[.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest] | first // "none"')" = \
    "sha256:$(sha256sum "$work/upstream/x86_64/test/$f.sig" | cut -d ' ' -f 1)" ]; then
    same=$((same + 1))
  else
    differ="$differ $f"
  fi
done < "$work/out/sigsrc/x86_64-test/shards/0.tsv"
check "a shard that reads packages from a plain server first takes each .sig from the db_server" \
  "${#plain_sigs[@]} of ${#plain_sigs[@]}" "$same of $(awk 'END { print NR + 0 }' "$work/out/sigsrc/x86_64-test/shards/0.tsv")" \
  "status $rc; layers not the db_server's .sig:$differ; read out/sigsrc.log"

#---------------------------------------------------------------------------#
# 9f. A server that fails, first in a shard's order: after it fails for one
#     file, every file of the shard asks it last. It gets one file's requests
#     (curl's three tries of a 503), not every file's.
#---------------------------------------------------------------------------#
mkdir -p "$work/targets-down"
cp "$work/targets/x86_64-kr.conf" "$work/targets-down/"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|^server = .*$|server = '"$BROKEN"'/fail/$arch/$repo|' "$work/targets/x86_64-test.conf" > "$work/targets-down/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-down" MIRROR_NAMESPACE=it/down MAX_SHARDS=1 "$REPO_ROOT/scripts/plan" "$work/out/down" \
  "$work/targets-down/x86_64-test.conf" > "$work/out/down.log" 2>&1 || rc=$?
: > "$work/broken-log/hits"
TARGETS_DIR="$work/targets-down" MIRROR_NAMESPACE=it/down SHARD_INDEX=1 PARALLEL=1 "$REPO_ROOT/scripts/mirror-shard" \
  "$work/out/down/x86_64-test/shards/0.tsv" "$work/out/down-results" >> "$work/out/down.log" 2>&1 || rc=$?
down_files="$(awk 'END { print NR + 0 }' "$work/out/down/x86_64-test/shards/0.tsv")"
check "every file of the shard is pushed from the next server" "$down_files pushed" \
  "$(awk -F '\t' '$3 == "pushed" { n++ } END { print n + 0 }' "$work/out/down-results/results.tsv" 2> /dev/null) pushed" \
  "status $rc; read out/down.log"
check "the failing server gets the requests of one file only, for $down_files files" 3 \
  "$(awk '/^\/fail\// { n++ } END { print n + 0 }' "$work/broken-log/hits")" "cat $work/broken-log/hits; read out/down.log"
if grep -q 'every file of this shard asks it last from now on' "$work/out/down.log"; then
  ok "the shard log names the server it asks last"
else
  fail "the shard log names the server it asks last" "read out/down.log"
fi

#---------------------------------------------------------------------------#
# 9g. With no %PGPSIG%, upstream makes a detached .sig again and keeps the
#     database bytes. plan compares a sample of the .sig files with the
#     signature layers of their tags: the file is planned again, its layer is
#     repaired, and the snapshot is promoted. When more than
#     SIGCHECK_ESCALATE of one sample differ, every such file is planned. In
#     a namespace of its own, with x86_64-kr beside it for keyring_from.
#---------------------------------------------------------------------------#
build nopgpsig x86_64/test-resig test
mkdir -p "$work/targets-resig"
cp "$work/targets/x86_64-kr.conf" "$work/targets-resig/"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/test-resig|; s|/\$arch/\./\$repo$|/$arch/./test-resig|' "$work/targets/x86_64-test.conf" > "$work/targets-resig/x86_64-test.conf"
resig_repo=it/resig/x86_64/test
TARGETS_DIR="$work/targets-resig" MIRROR_NAMESPACE=it/resig sync resig1 x86_64-kr x86_64-test
resig_latest1="$(digest_of latest "$resig_repo")"
check "a database with no %PGPSIG% is promoted in its own namespace" "promoted 0" \
  "$(cut -f 2 "$work/out/resig1/promote-x86_64-test.tsv" 2> /dev/null) $(pgpsig_count x86_64/test-resig)" \
  "read out/resig1/plan.log out/resig1/promote-x86_64-test.log"
resig_db="$(sha256sum "$work/upstream/x86_64/test-resig/test.db.tar.gz" | cut -d ' ' -f 1)"
build resig-one x86_64/test-resig
check "upstream makes alpha's .sig again with the second key, and its database stays the same" "$resig_db" \
  "$(sha256sum "$work/upstream/x86_64/test-resig/test.db.tar.gz" | cut -d ' ' -f 1)" "read $work/build-resig-one.log"
SIGCHECK_SAMPLE=64 TARGETS_DIR="$work/targets-resig" MIRROR_NAMESPACE=it/resig sync resig2 x86_64-test
check "a .sig made again upstream, with the database the same, plans that file alone" "pending $alpha" \
  "$(state_of resig2 plan x86_64-test) $(cut -f 2 "$work/out/resig2/plan/x86_64-test/todo.tsv" 2> /dev/null | tr '\n' ' ' | sed 's/ $//')" \
  "read out/resig2/plan.log"
case "$(cat "$work/out/resig2/plan/x86_64-test/why" 2> /dev/null)" in
  *'1 detached signature(s) changed upstream'*) ok "the plan's why counts the detached signature that changed" ;;
  *) fail "the plan's why counts the detached signature that changed" "$(cat "$work/out/resig2/plan/x86_64-test/why" 2> /dev/null)" \
    "read out/resig2/plan.log" ;;
esac
check "its tag gets upstream's new .sig as its signature layer, with the same package blob" \
  "sha256:$(sha256sum "$work/upstream/x86_64/test-resig/$alpha.sig" | cut -d ' ' -f 1) sha256:$(sha256sum "$work/upstream/x86_64/test-resig/$alpha" | cut -d ' ' -f 1)" \
  "$(manifest "$alpha_tag" "$resig_repo" > "$work/resig-alpha.json" && echo "$(layer_of "$work/resig-alpha.json" "$alpha.sig") $(layer_of "$work/resig-alpha.json" "$alpha")")" \
  "read out/resig2/mirror-x86_64-test-0.log"
resig_latest2="$(digest_of latest "$resig_repo")"
check "pacman verifies the new .sig, and the snapshot is promoted" "passed moved" \
  "$(verdict_of resig2 | cut -f 1) $([ -n "$resig_latest2" ] && [ "$resig_latest2" != "$resig_latest1" ] && echo moved || echo stayed)" \
  "read out/resig2/verify/verify-x86_64-test-0.log out/resig2/promote-x86_64-test.log"

# The sample: 2 of the 5 files, sorted by name, from (now / 10800 * 2) mod 5.
# At 03:00 on the first day the offset is 2.
resig_plan() {
  local o="$work/out/$1" rc=0
  shift
  env "$@" TARGETS_DIR="$work/targets-resig" MIRROR_NAMESPACE=it/resig "$REPO_ROOT/scripts/plan" "$o" \
    "$work/targets-resig/x86_64-test.conf" > "$o.log" 2>&1 || rc=$?
  printf '%s %s\n' "$(cat "$o/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc")" \
    "$(cut -f 2 "$o/x86_64-test/todo.tsv" 2> /dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
}
check "with every .sig the same as its layer, the sample plans nothing" "current " \
  "$(resig_plan resig-same MIRROR_NOW=10800 SIGCHECK_SAMPLE=2)" "read out/resig-same.log"
if grep -q '2 of 5 file(s) with a detached signature only compared with their tags, 0 changed upstream' "$work/out/resig-same.log"; then
  ok "the plan logs how many detached signatures it compared"
else
  fail "the plan logs how many detached signatures it compared" "read out/resig-same.log"
fi
build resig-all x86_64/test-resig
check "a sample of 2 that starts at offset 2 plans the third and fourth file by name" \
  "pending eta-1-1-any.pkg.tar.zst gamma-3.0-2-any.pkg.tar.zst" \
  "$(resig_plan resig-sample MIRROR_NOW=10800 SIGCHECK_SAMPLE=2)" "read out/resig-sample.log"
check "more than SIGCHECK_ESCALATE of one sample changed: every file with a detached signature only is planned" \
  "pending $(LC_ALL=C sort <<< "$alpha
beta_pc-2.0-1-x86_64.pkg.tar.zst
eta-1-1-any.pkg.tar.zst
gamma-3.0-2-any.pkg.tar.zst
$zeta" | tr '\n' ' ' | sed 's/ $//')" \
  "$(resig_plan resig-escalate MIRROR_NOW=10800 SIGCHECK_SAMPLE=2 SIGCHECK_ESCALATE=1)" "read out/resig-escalate.log"
if grep -q 'upstream signed 2 of 2 sampled files again; every detached signature is checked this run' "$work/out/resig-escalate.log"; then
  ok "the plan warns that every detached signature is checked"
else
  fail "the plan warns that every detached signature is checked" "read out/resig-escalate.log"
fi

#---------------------------------------------------------------------------#
# 9h. A run that the mirror holds leaves its work in the index. A db_server
#     that does not answer holds unsigned-1-1, as in 1e2. The next run, with
#     that db_server gone, mirrors that one file, verifies all 3, and
#     promotes. In a namespace of its own.
#---------------------------------------------------------------------------#
build port aarch64/port-heldm port
mkdir -p "$work/targets-heldm" "$work/targets-heldm2"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/port-heldm|; s|/\$arch/\./\$repo$|/$arch/./port-heldm|' "$work/targets/aarch64-port.conf" > "$work/targets-heldm2/aarch64-port.conf"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
{ cat "$work/targets-heldm2/aarch64-port.conf"; printf 'db_server = %s/$arch/$repo\n' "$closed"; } > "$work/targets-heldm/aarch64-port.conf"
heldm_repo=it/heldm/aarch64/port
TARGETS_DIR="$work/targets-heldm" MIRROR_NAMESPACE=it/heldm sync heldm1 aarch64-port
check "held by the mirror: the stage is held, and index-write ends 0" "held 0" \
  "$(state_of heldm1 stage aarch64-port) $(cat "$work/out/heldm1/index-aarch64-port.rc" 2> /dev/null || echo none)" \
  "read out/heldm1/stage-aarch64-port.log out/heldm1/index-aarch64-port.log"
check "held by the mirror: the index names the 2 files the run pushed, not verified" \
  "expired-1-1-any.pkg.tar.zst m 0 0; port-1-1-aarch64.pkg.tar.zst m 0 0" "$(index_rows "$heldm_repo")" \
  "read out/heldm1/index-aarch64-port.log"
TARGETS_DIR="$work/targets-heldm2" MIRROR_NAMESPACE=it/heldm sync heldm2 aarch64-port
check "the next run mirrors only the file that held the target, verifies all 3, and promotes" \
  "pending unsigned-1-1-any.pkg.tar.zst 3 staged passed promoted" \
  "$(state_of heldm2 plan aarch64-port) $(cut -f 2 "$work/out/heldm2/plan/aarch64-port/todo.tsv" 2> /dev/null | tr '\n' ' ')$(awk 'END { print NR + 0 }' "$work/out/heldm2/plan/aarch64-port/new.tsv" 2> /dev/null) $(state_of heldm2 stage aarch64-port) $(verdict_of heldm2 aarch64-port | cut -f 1) $(cut -f 2 "$work/out/heldm2/promote-aarch64-port.tsv" 2> /dev/null)" \
  "read out/heldm2/plan.log out/heldm2/stage-aarch64-port.log out/heldm2/verify/verify-aarch64-port-0.log out/heldm2/promote-aarch64-port.log"
check "after the promote, the index vouches for each file as verified" \
  "expired-1-1-any.pkg.tar.zst m 1 0; port-1-1-aarch64.pkg.tar.zst m 1 0; unsigned-1-1-any.pkg.tar.zst m 1 1" \
  "$(index_rows "$heldm_repo")" "read out/heldm2/index-aarch64-port.log"

#---------------------------------------------------------------------------#
# 9i. A batch that fails with no file at fault: its own budget ends before
#     its container starts. The other batches pass, and the index keeps
#     their verify credit. The next run mirrors nothing, verifies the file of
#     that batch and the canaries only, and promotes. In a namespace of its
#     own, with x86_64-kr beside it for keyring_from.
#---------------------------------------------------------------------------#
build one x86_64/test-fb test
mkdir -p "$work/targets-fb"
cp "$work/targets/x86_64-kr.conf" "$work/targets-fb/"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/test-fb|; s|/\$arch/\./\$repo$|/$arch/./test-fb|' "$work/targets/x86_64-test.conf" > "$work/targets-fb/x86_64-test.conf"
fb_repo=it/fb/x86_64/test
# budget_out_batch_1 TARGET BATCH: batch 1 gets 30 s, less than verify-batch
# gives a container; every other batch gets the default
budget_out_batch_1() {
  if [ "$2" = 1 ]; then
    export VERIFY_BUDGET=30
  else
    unset VERIFY_BUDGET
  fi
}
VERIFY_BATCH_FILES=1 BEFORE_VERIFY=budget_out_batch_1 TARGETS_DIR="$work/targets-fb" MIRROR_NAMESPACE=it/fb sync fb1 x86_64-test
unset VERIFY_BUDGET
fb_name="$(cat "$work/out/fb1/stage/x86_64-test/batches/1.txt" 2> /dev/null || echo none)"
fb_file="$(awk -F '\t' -v n="$fb_name" '$2 == n { print $1 }' "$work/out/fb1/plan/x86_64-test/records.tsv")"
check "a failed batch: of 3 batches, batch 1 fails for its budget with no file at fault, and nothing is promoted" \
  "3 passed failed passed empty failed" \
  "$(find "$work/out/fb1/stage/x86_64-test/batches" -name '*.txt' | awk 'END { print NR + 0 }') $(verdict_of fb1 x86_64-test 0 | cut -f 1) $(verdict_of fb1 x86_64-test 1 | cut -f 1) $(verdict_of fb1 x86_64-test 2 | cut -f 1) $([ -f "$work/out/fb1/verify/faults-x86_64-test-1.txt" ] && [ ! -s "$work/out/fb1/verify/faults-x86_64-test-1.txt" ] && echo empty || echo 'not an empty file') $(cut -f 2 "$work/out/fb1/promote-x86_64-test.tsv" 2> /dev/null)" \
  "read out/fb1/stage-x86_64-test.log out/fb1/verify/verify-x86_64-test-1.log out/fb1/promote-x86_64-test.log"
check "the index keeps the verify credit of the 2 batches that passed, and gives the failed one none" "2 $fb_file m 0 0" \
  "$(index_rows "$fb_repo" | tr ';' '\n' | awk '$3 == "1" { n++ } $3 == "0" { z = $1 " " $2 " " $3 " " $4 } END { print n + 0, z }')" \
  "read out/fb1/index-x86_64-test.log"
TARGETS_DIR="$work/targets-fb" MIRROR_NAMESPACE=it/fb sync fb2 x86_64-test
check "the next run mirrors nothing, verifies the file of the failed batch, and has no shard" "pending 0 $fb_file 0" \
  "$(state_of fb2 plan) $(awk 'END { print NR + 0 }' "$work/out/fb2/plan/x86_64-test/todo.tsv" 2> /dev/null) $(cut -f 2 "$work/out/fb2/plan/x86_64-test/new.tsv" 2> /dev/null | tr '\n' ' ' | sed 's/ $//') $(jq -r '.include[] | select(.target == "x86_64-test") | .shards | length' "$work/out/fb2/plan/pending.json" 2> /dev/null)" \
  "read out/fb2/plan.log; jq . out/fb2/plan/pending.json"
check "it verifies that file and the canaries only, and promotes" \
  "$({ printf '%s\n' "$fb_name"; cat "$work/out/fb2/stage/x86_64-test/canaries.txt" 2> /dev/null; } | LC_ALL=C sort -u | tr '\n' ' ')passed promoted" \
  "$(cut -f 1 "$work/out/fb2/stage/x86_64-test/verify.tsv" 2> /dev/null | LC_ALL=C sort -u | tr '\n' ' ')$(verdict_of fb2 | cut -f 1) $(cut -f 2 "$work/out/fb2/promote-x86_64-test.tsv" 2> /dev/null)" \
  "read out/fb2/stage-x86_64-test.log out/fb2/verify/verify-x86_64-test-0.log out/fb2/promote-x86_64-test.log"

#---------------------------------------------------------------------------#
# 9j. A tag that the index vouches for, changed on the registry: after the
#     stage, alpha's tag gets beta_pc's signature layer. verify fails and
#     names alpha as the file at fault, and index-write drops its row. The
#     next run mirrors alpha again, with the package blob from its own
#     repository: the signature layer is repaired, and the target is
#     promoted. In a namespace of its own, with x86_64-kr beside it for
#     keyring_from.
#---------------------------------------------------------------------------#
build one x86_64/test-tamper test
mkdir -p "$work/targets-tamper"
cp "$work/targets/x86_64-kr.conf" "$work/targets-tamper/"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/test-tamper|; s|/\$arch/\./\$repo$|/$arch/./test-tamper|' "$work/targets/x86_64-test.conf" > "$work/targets-tamper/x86_64-test.conf"
tamper_repo=it/tamper/x86_64/test
tamper_alpha_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$alpha")"
# tamper_alpha TARGET: swap_sig, for x86_64-test only
tamper_alpha() {
  [ "$1" = x86_64-test ] || return 0
  swap_sig "$tamper_repo" "$alpha" 'beta_pc-2.0-1-x86_64.pkg.tar.zst'
}
TARGETS_DIR="$work/targets-tamper" MIRROR_NAMESPACE=it/tamper AFTER_STAGE=tamper_alpha sync tamper1 x86_64-test
case "$(verdict_of tamper1):$(cat "$work/out/tamper1/verify/faults-x86_64-test-0.txt" 2> /dev/null)" in
  failed*"$alpha: its .sig is sha256"*":$alpha") ok "a tampered signature layer fails verify, and alpha is the one file at fault" ;;
  *) fail "a tampered signature layer fails verify, and alpha is the one file at fault" \
    "verdict: $(verdict_of tamper1)" "files at fault: $(cat "$work/out/tamper1/verify/faults-x86_64-test-0.txt" 2> /dev/null || echo 'no file')" \
    "read out/tamper1/verify/verify-x86_64-test-0.log" ;;
esac
check "index-write drops the row of the file at fault" \
  "beta_pc-2.0-1-x86_64.pkg.tar.zst m 0 0; gamma-3.0-1-any.pkg.tar.zst m 0 0" "$(index_rows "$tamper_repo")" \
  "read out/tamper1/index-x86_64-test.log"
TARGETS_DIR="$work/targets-tamper" MIRROR_NAMESPACE=it/tamper sync tamper2 x86_64-test
check "the next run mirrors alpha alone, with the package blob from its own repository" \
  "$alpha pushed from 127.0.0.1:$REG_PORT/$tamper_repo," \
  "$(cut -f 2 "$work/out/tamper2/plan/x86_64-test/todo.tsv" 2> /dev/null) $(cat "$work/out/tamper2/results/x86_64-test"/*/results.tsv 2> /dev/null | awk -F '\t' -v f="$alpha" '$2 == f { print $3, $5 }' | sed 's/ pushed in .*//')" \
  "read out/tamper2/plan.log out/tamper2/mirror-x86_64-test-0.log"
check "alpha's signature layer is its %PGPSIG% again, with the same package blob, and the target is promoted" \
  "sha256:$(pgpsig_of "$alpha" x86_64/test-tamper | base64 -d | sha256sum | cut -d ' ' -f 1) $(layer_of "$work/swap-good.json" "$alpha") passed promoted" \
  "$(manifest "$tamper_alpha_tag" "$tamper_repo" > "$work/tamper-alpha.json" && echo "$(layer_of "$work/tamper-alpha.json" "$alpha.sig") $(layer_of "$work/tamper-alpha.json" "$alpha")") $(verdict_of tamper2 | cut -f 1) $(cut -f 2 "$work/out/tamper2/promote-x86_64-test.tsv" 2> /dev/null)" \
  "curl http://127.0.0.1:$REG_PORT/v2/$tamper_repo/manifests/$tamper_alpha_tag; read out/tamper2/verify/verify-x86_64-test-0.log"
check "the index then vouches for each file as verified" \
  "$alpha m 1 0; beta_pc-2.0-1-x86_64.pkg.tar.zst m 1 0; gamma-3.0-1-any.pkg.tar.zst m 1 0" "$(index_rows "$tamper_repo")" \
  "read out/tamper2/index-x86_64-test.log"

#---------------------------------------------------------------------------#
# 9k. The chain of an older run, run again after a newer run wrote the
#     index, as "Re-run failed jobs" can do days later. Run A plans alpha,
#     signed again upstream, and withdraws its row. Upstream signs alpha
#     once more, and run B mirrors it, promotes, and writes the index. A's
#     shard, run again as attempt 2, writes no tag that the index lists: it
#     would put back the signature B replaced. A's index-write keeps B's
#     index. In a namespace of its own, with x86_64-kr beside it for
#     keyring_from. ⚠ build resigned replaces alpha's kept signature (see
#     tests/fixtures/build-repo), so no section after this one builds alpha.
#---------------------------------------------------------------------------#
build two x86_64/test-old test
mkdir -p "$work/targets-old"
cp "$work/targets/x86_64-kr.conf" "$work/targets-old/"
# shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
sed 's|/\$arch/\$repo$|/$arch/test-old|; s|/\$arch/\./\$repo$|/$arch/./test-old|' "$work/targets/x86_64-test.conf" > "$work/targets-old/x86_64-test.conf"
old_repo=it/old/x86_64/test
old_alpha_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$alpha")"
TARGETS_DIR="$work/targets-old" MIRROR_NAMESPACE=it/old sync old1 x86_64-kr x86_64-test
check "an older run's chain: the first run promotes x86_64-test, and writes its index" "promoted 0" \
  "$(cut -f 2 "$work/out/old1/promote-x86_64-test.tsv" 2> /dev/null) $(cat "$work/out/old1/index-x86_64-test.rc" 2> /dev/null || echo none)" \
  "read out/old1/promote-x86_64-test.log out/old1/index-x86_64-test.log"
build resigned x86_64/test-old test
rc=0
TARGETS_DIR="$work/targets-old" MIRROR_NAMESPACE=it/old "$REPO_ROOT/scripts/plan" "$work/out/oldA" "$work/targets-old/x86_64-test.conf" \
  > "$work/out/oldA.log" 2>&1 || rc=$?
check "run A plans alpha, signed again, and first withdraws its row from the index" "pending $alpha 1 0" \
  "$(cat "$work/out/oldA/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc") $(cut -f 2 "$work/out/oldA/x86_64-test/todo.tsv" 2> /dev/null) $(grep -c "1 row(s) withdrawn from $old_repo:index" "$work/out/oldA.log") $(index_rows "$old_repo" | tr ';' '\n' | awk -v f="$alpha" '$1 == f { n++ } END { print n + 0 }')" \
  "read out/oldA.log"
old_db_a="$(sha256sum "$work/upstream/x86_64/test-old/test.db.tar.gz" | cut -d ' ' -f 1)"
build resigned x86_64/test-old test
check "upstream signs alpha once more: its database changes" changed \
  "$([ "$(sha256sum "$work/upstream/x86_64/test-old/test.db.tar.gz" | cut -d ' ' -f 1)" != "$old_db_a" ] && echo changed || echo 'the same')" \
  "read $work/build-resigned.log"
TARGETS_DIR="$work/targets-old" MIRROR_NAMESPACE=it/old sync oldB x86_64-test
old_alpha_b="$(digest_of "$old_alpha_tag" "$old_repo")"
old_index_b="$(digest_of index "$old_repo")"
check "run B mirrors alpha with the newest signature, promotes, and writes the index" \
  "promoted sha256:$(pgpsig_of "$alpha" x86_64/test-old | base64 -d | sha256sum | cut -d ' ' -f 1) 0 $alpha m 1 0" \
  "$(cut -f 2 "$work/out/oldB/promote-x86_64-test.tsv" 2> /dev/null) $(manifest "$old_alpha_tag" "$old_repo" | jq -r --arg t "$alpha.sig" '[.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest] | first // "none"') $(cat "$work/out/oldB/index-x86_64-test.rc" 2> /dev/null || echo none) $(index_rows "$old_repo" | tr ';' '\n' | awk -v f="$alpha" '$1 == f { print $1, $2, $3, $4 }')" \
  "read out/oldB/plan.log out/oldB/promote-x86_64-test.log out/oldB/index-x86_64-test.log"
rc=0
for s in "$work/out/oldA/x86_64-test"/shards/*.tsv; do
  i="$(basename "$s" .tsv)"
  TARGETS_DIR="$work/targets-old" MIRROR_NAMESPACE=it/old GITHUB_RUN_ATTEMPT=2 SHARD_INDEX="$i" "$REPO_ROOT/scripts/mirror-shard" \
    "$s" "$work/out/oldA-results/$i" > "$work/out/oldA-mirror-$i.log" 2>&1 || rc=$?
done
old_result="$(cat "$work/out/oldA-results"/*/results.tsv 2> /dev/null | awk -F '\t' -v f="$alpha" '$2 == f { print $3 "\t" $5 }')"
case "$old_result" in
  failed$'\t'"the index lists it; a newer run vouches for this tag"*) ok "run A's shard, run again as attempt 2, does not write the tag of a file the index lists" ;;
  *) fail "run A's shard, run again as attempt 2, does not write the tag of a file the index lists" "result: $old_result" \
    "status $rc; read out/oldA-mirror-*.log" ;;
esac
check "alpha's tag keeps the signature run B wrote" "$old_alpha_b" "$(digest_of "$old_alpha_tag" "$old_repo")" \
  "curl -I http://127.0.0.1:$REG_PORT/v2/$old_repo/manifests/$old_alpha_tag"
rc=0
TARGETS_DIR="$work/targets-old" MIRROR_NAMESPACE=it/old "$REPO_ROOT/scripts/index-write" "$work/out/oldA" "$work/out/oldA-results" \
  "$work/out/oldA-stage" "$work/out/oldA-verify" x86_64-test > "$work/out/oldA-index.log" 2>&1 || rc=$?
check "run A's index-write ends 0, and keeps the index of run B" "0 $old_index_b" "$rc $(digest_of index "$old_repo")" \
  "read out/oldA-index.log"
if grep -qF "$old_repo:index is kept, and this run's rows are not pushed" "$work/out/oldA-index.log"; then
  ok "run A's index-write says that it keeps the live index"
else
  fail "run A's index-write says that it keeps the live index" "read out/oldA-index.log"
fi

#---------------------------------------------------------------------------#
# 10. What the wrapper must refuse, served by a plain web server standing in
#    for a registry that lies: a manifest whose bytes are not the digest the
#    URL pins, a manifest with two layers of the same name, and a package
#    manifest with no signature layer.
#---------------------------------------------------------------------------#
fake="$work/upstream/v2/fake/repo/manifests"
mkdir -p "$fake"
honest='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}'
pinned="$(printf '%s' "$honest" | sha256sum | cut -d ' ' -f 1)"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"x","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}}]}' \
  > "$fake/sha256:$pinned"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"x","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}},{"mediaType":"x","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}}]}' \
  > "$fake/latest"
nosig_tag="$("$REPO_ROOT/client/pacman-oci" --tag 'nosig-1-1-any.pkg.tar.zst')"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"application/vnd.pkgforge.archlinux.pkg.v1","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"nosig-1-1-any.pkg.tar.zst"}}]}' \
  > "$fake/$nosig_tag"

refuses() {
  local label="$1" url="$2" want="$3" rc=0
  "$REPO_ROOT/client/pacman-oci" "$work/refuse.part" "$url" > /dev/null 2> "$work/refuse.err" || rc=$?
  if [ "$rc" -eq 1 ] && { [ -z "$want" ] || grep -q -- "$want" "$work/refuse.err"; } && [ ! -e "$work/refuse.part" ]; then
    ok "the wrapper refuses $label"
  else
    fail "the wrapper refuses $label" "exit $rc" "stderr: $(cat "$work/refuse.err")" "reproduce: client/pacman-oci out.part '$url'"
  fi
}
refuses "a manifest whose bytes are not the pinned digest" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo@sha256:$pinned/test.db" "another digest"
refuses "a manifest with two layers of the same name" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo/test.db" "more than one layer"
refuses "a package manifest with no signature layer, loudly" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo/nosig-1-1-any.pkg.tar.zst.sig" "pacman tries no other server"

# The index of a ref is not a database. Its tag holds no layer of the name
# pacman asks for, so a Server line at :index gives no database, and pacman
# asks its next server.
check "the repository of x86_64-test has the tag index" present \
  "$([ -n "$(digest_of index)" ] && echo present || echo absent)" "curl -I $BASE/manifests/index"
for f in test.db test.files; do
  rc=0
  PACMAN_OCI_DEBUG=1 "$REPO_ROOT/client/pacman-oci" "$work/index-$f.part" "oci+http://127.0.0.1:$REG_PORT/$REPO:index/$f" \
    2> "$work/index-$f.err" || rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "$REPO:index has no layer named $f" "$work/index-$f.err" && [ ! -e "$work/index-$f.part" ]; then
    ok "a Server line at :index: the wrapper gives no $f"
  else
    fail "a Server line at :index: the wrapper gives no $f" "exit $rc" "stderr: $(cat "$work/index-$f.err")" \
      "reproduce: PACMAN_OCI_DEBUG=1 client/pacman-oci out.part 'oci+http://127.0.0.1:$REG_PORT/$REPO:index/$f'"
  fi
done

# A manifest far larger than any real one: curl stops reading at 64 KiB and the
# file falls through at once, rather than leaving awk to parse it while pacman
# waits.
awk 'BEGIN { printf "{\"schemaVersion\":2,\"layers\":["; for (i = 0; i < 1000000; i++) printf "%s1", (i ? "," : ""); print "]}" }' > "$fake/huge"
started_at="$(date +%s)"
refuses "a manifest over 64 KiB, quickly" "oci+http://127.0.0.1:$UP_PORT/fake/repo:huge/test.db" "Maximum file size exceeded"
check "the oversized manifest is given up within 20 seconds" 1 "$(($(date +%s) - started_at < 20 ? 1 : 0))" "time client/pacman-oci out.part oci+http://.../fake/repo:huge/test.db"

# serve_layer TAG TITLE BYTES_FILE DIGEST SIZE: a one-layer manifest at TAG
# whose descriptor says DIGEST and SIZE, and BYTES_FILE served as that blob
blobs="$work/upstream/v2/fake/repo/blobs"
mkdir -p "$blobs"
serve_layer() {
  jq -cn --arg t "$2" --arg d "sha256:$4" --argjson s "$5" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: [{mediaType: "x", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $t}}]}' \
    > "$fake/$1"
  cp "$3" "$blobs/sha256:$4"
}
printf 'the bytes the manifest names\n' > "$work/right"
right="$(sha256sum "$work/right" | cut -d ' ' -f 1)"
serve_layer wrongsize test.db "$work/right" "$right" 999
refuses "a blob whose size is not its descriptor's" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo:wrongsize/test.db" "the manifest says 999"
printf 'other bytes of the same length\n' > "$work/tampered"
serve_layer tampered test.db "$work/tampered" "$right" "$(wc -c < "$work/tampered" | tr -d ' ')"
refuses "a blob whose sha256 is not its descriptor's" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo:tampered/test.db" "has sha256"

# A database signature is read from the manifest of the database beside it.
mkdir -p "$work/pair"
printf 'the database pacman holds\n' > "$work/pair/test.db"
held_hex="$(sha256sum "$work/pair/test.db" | cut -d ' ' -f 1)"
printf 'its signature\n' > "$work/pair-sig"
sig_hex="$(sha256sum "$work/pair-sig" | cut -d ' ' -f 1)"
jq -cn --arg d "sha256:$held_hex" --argjson ds "$(wc -c < "$work/pair/test.db" | tr -d ' ')" \
  --arg g "sha256:$sig_hex" --argjson gs "$(wc -c < "$work/pair-sig" | tr -d ' ')" \
  '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: [
     {mediaType: "x", digest: $d, size: $ds, annotations: {"org.opencontainers.image.title": "test.db"}},
     {mediaType: "application/pgp-signature", digest: $g, size: $gs, annotations: {"org.opencontainers.image.title": "test.db.sig"}}]}' \
  > "$fake/db-$held_hex"
cp "$work/pair-sig" "$blobs/sha256:$sig_hex"
rc=0
"$REPO_ROOT/client/pacman-oci" "$work/pair/test.db.sig.part" "oci+http://127.0.0.1:$UP_PORT/fake/repo/test.db.sig" 2> "$work/pair.err" || rc=$?
check "a database signature comes from the manifest of the database beside it" "0:its signature" \
  "$rc:$(cat "$work/pair/test.db.sig.part" 2> /dev/null)" "client/pacman-oci DIR/test.db.sig.part oci+http://.../fake/repo/test.db.sig"

mkdir -p "$work/moved"
printf 'an older database\n' > "$work/moved/test.db"
serve_layer moved test.db "$work/right" "$right" "$(wc -c < "$work/right" | tr -d ' ')"
rc=0
PACMAN_OCI_DEBUG=1 "$REPO_ROOT/client/pacman-oci" "$work/moved/test.db.sig.part" "oci+http://127.0.0.1:$UP_PORT/fake/repo:moved/test.db.sig" 2> "$work/moved.err" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'moved on' "$work/moved.err" && [ ! -e "$work/moved/test.db.sig.part" ]; then
  ok "no signature is paired with a database the snapshot has moved on from"
else
  fail "no signature is paired with a database the snapshot has moved on from" "exit $rc" "$(cat "$work/moved.err")"
fi

summary
