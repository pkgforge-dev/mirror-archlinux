#!/usr/bin/env bash
#
# The whole mirror, end to end, against a registry and an upstream of its own.
#
# A local registry (registry:3) stands in for GHCR and a local web server for
# the upstream mirrors. Three targets are built, each a signed repository:
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
# mirror-shard, stage, verify-batch, promote, report. pacman in an Arch
# container then installs from the mirror through the wrapper, with and
# without DownloadUser, and the cases that must be refused are driven on
# purpose.
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
ARCH_IMAGE=docker.io/library/archlinux:base@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
# tag: 3
REGISTRY_IMAGE=docker.io/library/registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
# tag: 1.37
HTTPD_IMAGE=docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e

runtime_detect
work="$(work_dir)"
suffix="$$-$RANDOM"
reg_name="mirror-it-registry-$suffix"
up_name="mirror-it-upstream-$suffix"
kimage_local="mirror-it-keyring-$suffix"
cleanup() {
  "$RUNTIME" rm -f "$reg_name" "$up_name" > "$work/cleanup.log" 2>&1 || echo "# cleanup: $(cat "$work/cleanup.log")" >&2
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

mkdir -p "$work/upstream" "$work/targets" "$work/out"

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
REG_PORT="$(port_of "$reg_name" 5000)"
UP_PORT="$(port_of "$up_name" 8000)"
ready=0
if [ -n "$REG_PORT" ] && [ -n "$UP_PORT" ]; then
  for _ in $(seq 1 30); do
    if curl -q -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" > /dev/null &&
      curl -q -sS --connect-timeout 2 --max-time 5 -o /dev/null "http://127.0.0.1:$UP_PORT/"; then
      ready=1
      break
    fi
    sleep 1
  done
fi
if [ "$ready" -ne 1 ]; then
  fail "the local registry and upstream answer" "registry port '$REG_PORT', upstream port '$UP_PORT', after 30 s" \
    "reproduce: $RUNTIME logs $reg_name; $RUNTIME logs $up_name"
  summary
  exit 1
fi
echo "# registry on 127.0.0.1:$REG_PORT, upstream on 127.0.0.1:$UP_PORT"

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
REPO="it/mirror/x86_64/test"
BASE="http://127.0.0.1:$REG_PORT/v2/$REPO"
UP="http://127.0.0.1:$UP_PORT"

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

# sync N [TARGET ...]: one run, as the workflows run it: plan for every
# target, then each pending target's chain in the order given (default kr,
# test, port), then the report; state in $work/out/N
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
      continue
    fi
    for b in "$o/stage/$t"/batches/*.txt; do
      [ -e "$b" ] || continue
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

# put_manifest TAG FILE: write a manifest as an attacker with push rights would
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

# pgpsig_count [DIR]: how many %PGPSIG% the upstream database carries
pgpsig_count() {
  tar -xOzf "$work/upstream/${1:-x86_64/test}/${2:-test}.db" | awk '$0 == "%PGPSIG%" { n++ } END { print n + 0 }'
}

# pgpsig_of FILE: the %PGPSIG% the upstream test database carries for FILE
pgpsig_of() {
  tar -xOzf "$work/upstream/x86_64/test/test.db" |
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
#     finds the mirror at fault, not upstream: the batch fails.
#---------------------------------------------------------------------------#
build nopgpsig-four
tamper_canary
sync 11
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
