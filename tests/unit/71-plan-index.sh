#!/usr/bin/env bash
#
# scripts/plan with the index of a ref (scripts/lib.sh index_read). Which
# files a run mirrors (todo.tsv), verifies (new.tsv) and vouches for
# (vouched.tsv), for records that are promoted, indexed, indexed as verified,
# indexed as absent upstream, and planned again by step 4. Then the index
# states (absent, unread, invalid, ignored and the manifest it reads,
# private, and an anonymous read that answers 503), the withdrawal of index
# rows before their tags are written (step 6b, withdrawn-by), the registry
# sources of a todo file (sources.tsv, step 6c), and one upstream read per
# URL in a plan (OUT/.fetch-cache). Last, lib.sh index_read and index_push
# alone, index_push with a relative DIR too.
#
# The upstream and the registry are files under $work/net. A curl stand-in
# answers a token request itself and hands every other request to
# tests/fixtures/status/fake-curl: from $work/net/tok1 when the request
# carries the workflow's token (Bearer tok1) and a file is there, from
# $work/net/anon otherwise. So a file under tok1 reads only with the token.
# scripts/plan runs with REPO_ROOT set to a root of stand-ins: install-oras
# names an oras stand-in that pushes into $work/net/anon, and the wrapper
# serves the database that latest names there.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

if ! need_tool jq "plan: the index of a ref" || ! need_tool tar "plan: the index of a ref"; then
  summary
  exit $?
fi
tar_version="$(tar --version 2>&1 | sed -n 1p)"
case "$tar_version" in
  *'GNU tar'*) ;;
  *)
    skip "plan: the index of a ref" "db_records reads with GNU tar, and this tar is $tar_version"
    summary
    exit $?
    ;;
esac

unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_REF GITHUB_REF_NAME GITHUB_RUN_ID STAGING_TAG INDEX_TAG \
  REGISTRY_TOKEN_CACHE MIRROR_FETCHER INDEX_READ REGISTRY_TOKEN
export MIRROR_NAMESPACE=test/mirror MIRROR_REGISTRY=ghcr.io MIRROR_REGISTRY_AUTH=token MIRROR_REGISTRY_SCHEME=https
export MIRROR_NOW=1790000000
LIB="$REPO_ROOT/scripts/lib.sh"
net="$work/net"
export NET="$net"
A="$net/anon"
T="$net/tok1"
bin="$work/bin"
root="$work/root"
mkdir -p "$bin" "$root/scripts" "$root/client" "$A/ghcr.io" "$A/up.test" "$T" "$work/targets"
printf '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}\n' > "$A/ghcr.io/.404"
export FAKE_CURL="$REPO_ROOT/tests/fixtures/status/fake-curl"
export REAL_WRAPPER="$REPO_ROOT/client/pacman-oci"

#---------------------------------------------------------------------------#
# Stand-ins
#---------------------------------------------------------------------------#
cat > "$bin/curl" << 'EOF'
#!/usr/bin/env bash
# A stand-in for curl. A token request answers "tok1" when a credential
# comes on stdin (--config -), and "anon" when none does. Any other request
# goes to tests/fixtures/status/fake-curl, with --config dropped, from
# $NET/tok1 when it carries Bearer tok1 and the file is there, from
# $NET/anon otherwise.
a=("$@")
pass=()
auth="" out="" wo="" url="" cred=0 i=0
while [ "$i" -lt "${#a[@]}" ]; do
  case "${a[$i]}" in
    --config)
      if [ "${a[$((i + 1))]}" = - ]; then
        cat > /dev/null
        cred=1
      fi
      i=$((i + 2))
      continue
      ;;
    --header) case "${a[$((i + 1))]}" in Authorization:*) auth="${a[$((i + 1))]#Authorization: }" ;; esac ;;
    --output) out="${a[$((i + 1))]}" ;;
    --write-out) wo="${a[$((i + 1))]}" ;;
    http://* | https://*) url="${a[$i]}" ;;
  esac
  pass+=("${a[$i]}")
  i=$((i + 1))
done
case "$url" in
  */token)
    tok=anon
    if [ "$cred" -eq 1 ]; then
      tok=tok1
    fi
    printf '{"token":"%s"}' "$tok" > "$out"
    [ -z "$wo" ] || printf '200'
    exit 0
    ;;
esac
r="$NET/anon"
if [ "$auth" = "Bearer tok1" ]; then
  p="${url#*://}"
  p="${p%%\?*}"
  if [ -e "$NET/tok1/$p" ] || [ -e "$NET/tok1/$p.code" ]; then
    r="$NET/tok1"
  fi
fi
FAKE_CURL_ROOT="$r" exec "$FAKE_CURL" "${pass[@]}"
EOF

cat > "$bin/oras" << 'EOF'
#!/usr/bin/env bash
# A stand-in for oras. Logs each call to $NET/oras.log. login reads its
# password. push fails while $NET/oras-fail exists, and answers in oras's
# words for a 429 while $NET/oras-429 holds a number above 0 (counted down).
# Otherwise it writes each ./FILE:TYPE as a blob and the manifest, with
# --artifact-type and every --annotation, under $NET/anon/ghcr.io.
printf '%s\n' "$*" >> "$NET/oras.log"
case "$1" in
  login)
    cat > /dev/null
    exit 0
    ;;
  push) shift ;;
  *) exit 2 ;;
esac
if [ -f "$NET/oras-fail" ]; then
  echo "Error: failed to push: a stand-in that fails" >&2
  exit 1
fi
n=0
if [ -f "$NET/oras-429" ]; then
  n="$(cat "$NET/oras-429")"
fi
if [ "$n" -gt 0 ]; then
  echo "$((n - 1))" > "$NET/oras-429"
  echo "Error: failed to push: PUT \"https://ghcr.io/v2/x/manifests/t\": response status code 429: Too Many Requests" >&2
  exit 1
fi
at="" ref="" ann='{}' layers='[]'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry-config) shift 2 ;;
    --plain-http) shift ;;
    --artifact-type) at="$2"; shift 2 ;;
    --annotation) ann="$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<< "$ann")"; shift 2 ;;
    ./*)
      f="${1%:*}"
      sha="$(sha256sum "$f" | cut -d ' ' -f 1)"
      layers="$(jq -c --arg t "${1##*:}" --arg d "sha256:$sha" --argjson s "$(wc -c < "$f" | tr -d ' ')" --arg n "${f#./}" \
        '. + [{mediaType: $t, digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $n}}]' <<< "$layers")"
      ref_layers="${ref_layers:-} $f:$sha"
      shift
      ;;
    *) ref="$1"; shift ;;
  esac
done
repo="${ref#*/}"
tag="${repo##*:}"
repo="${repo%:*}"
mkdir -p "$NET/anon/ghcr.io/v2/$repo/blobs" "$NET/anon/ghcr.io/v2/$repo/manifests"
for l in $ref_layers; do
  cp "${l%:*}" "$NET/anon/ghcr.io/v2/$repo/blobs/sha256:${l##*:}"
done
jq -cn --arg at "$at" --argjson a "$ann" --argjson l "$layers" \
  '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $at, layers: $l, annotations: $a}' \
  > "$NET/anon/ghcr.io/v2/$repo/manifests/$tag"
EOF

cat > "$root/scripts/install-oras" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_BIN/oras"
EOF

cat > "$root/client/pacman-oci" << 'EOF'
#!/usr/bin/env bash
# The tags as the wrapper makes them. A database: the blob that latest names
# under $NET/anon, as a consumer reads it.
case "$1" in
  --tag | --tags) exec "$REAL_WRAPPER" "$@" ;;
esac
u="${2#*://}"
u="${u#*/}"
repo="${u%/*}"
file="${u##*/}"
d="$(jq -r --arg t "$file" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest' \
  "$NET/anon/ghcr.io/v2/$repo/manifests/latest")"
cp "$NET/anon/ghcr.io/v2/$repo/blobs/$d" "$1"
EOF
cp "$REPO_ROOT/scripts/verify-batch" "$REPO_ROOT/scripts/lib.sh" "$root/scripts/"
chmod +x "$bin/curl" "$bin/oras" "$root/scripts/install-oras" "$root/client/pacman-oci"
export TEST_BIN="$bin"

#---------------------------------------------------------------------------#
# Fixtures
#---------------------------------------------------------------------------#
SIG_OTHER=b3RoZXIgc2lnbmF0dXJl
# pkg DIR NAME ARCH SIG [SHA]: one package directory, version 1-1
pkg() {
  local dir="$1" name="$2" arch="$3" sig="$4" sha="${5:-}"
  [ -n "$sha" ] || sha="$(printf '%s-1-1' "$name" | sha256sum | cut -d ' ' -f 1)"
  mkdir -p "$dir/$name-1-1"
  {
    printf '%%FILENAME%%\n%s-1-1-%s.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n' "$name" "$arch" "$name"
    printf '%%CSIZE%%\n1000\n\n%%SHA256SUM%%\n%s\n\n%%BUILDDATE%%\n1790000000\n\n%%ARCH%%\n%s\n\n' "$sha" "$arch"
    if [ -n "$sig" ]; then
      printf '%%PGPSIG%%\n%s\n\n' "$sig"
    fi
  } > "$dir/$name-1-1/desc"
}
# mkdb DIR OUT.db [OUT.files]: the database of DIR, and a files database of
# the same packages
mkdb() {
  local d
  (cd "$1" && tar -czf "$2" -- *)
  [ -n "${3:-}" ] || return 0
  rm -rf "$1.files"
  cp -r "$1" "$1.files"
  for d in "$1.files"/*/; do
    printf '%%FILES%%\nusr/bin/%s\n\n' "$(basename "$d")" > "$d/files"
  done
  (cd "$1.files" && tar -czf "$3" -- *)
}
# blob_put TREE REPO FILE -> the sha256 of FILE, stored as a blob of REPO
blob_put() {
  local sha
  sha="$(sha256sum "$3" | cut -d ' ' -f 1)"
  mkdir -p "$1/ghcr.io/v2/$2/blobs"
  cp "$3" "$1/ghcr.io/v2/$2/blobs/sha256:$sha"
  printf '%s\n' "$sha"
}
# put_latest REPO DB TITLE: latest of REPO names DB as its TITLE layer
put_latest() {
  local sha
  sha="$(blob_put "$A" "$1" "$2")"
  mkdir -p "$A/ghcr.io/v2/$1/manifests"
  jq -cn --arg d "sha256:$sha" --argjson s "$(wc -c < "$2" | tr -d ' ')" --arg t "$3" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: "application/vnd.pkgforge.archlinux.db.v1",
      layers: [{mediaType: "application/vnd.pkgforge.archlinux.db.v1", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $t}}],
      annotations: {"dev.pkgforge.mirror.fetched": "2026-10-01T00:00:00Z"}}' > "$A/ghcr.io/v2/$1/manifests/latest"
}
# put_index TREE REPO REF.DB INDEX.TSV CONTEXT [ARTIFACT_TYPE]: the index of
# REPO at the tag index, under TREE
put_index() {
  local dsha tsha
  dsha="$(blob_put "$1" "$2" "$3")"
  tsha="$(blob_put "$1" "$2" "$4")"
  mkdir -p "$1/ghcr.io/v2/$2/manifests"
  jq -cn --arg at "${6:-application/vnd.pkgforge.archlinux.index.v1}" --arg dd "sha256:$dsha" --arg td "sha256:$tsha" \
    --argjson ds "$(wc -c < "$3" | tr -d ' ')" --argjson ts "$(wc -c < "$4" | tr -d ' ')" --arg c "$5" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $at,
      layers: [{mediaType: "application/vnd.pkgforge.archlinux.db.v1", digest: $dd, size: $ds, annotations: {"org.opencontainers.image.title": "ref.db"}},
        {mediaType: "application/vnd.pkgforge.archlinux.index.v1+tsv", digest: $td, size: $ts, annotations: {"org.opencontainers.image.title": "index.tsv"}}],
      annotations: {"dev.pkgforge.mirror.index-format": "1", "dev.pkgforge.mirror.plan-id": "older.1.1",
        "dev.pkgforge.mirror.verify-context": $c, "dev.pkgforge.mirror.run": "older"}}' > "$1/ghcr.io/v2/$2/manifests/index"
}
# rows LINE...: an index.tsv, NAME STATE VERIFIED UNSIGNED per argument,
# for the file NAME-1-1-x86_64.pkg.tar.zst
rows() {
  local r n s v u
  for r in "$@"; do
    read -r n s v u <<< "$r"
    printf '%s-1-1-x86_64.pkg.tar.zst\t%s\t%s\t%s\n' "$n" "$s" "$v" "$u"
  done
}
# ctx_of CONF -> the verify context plan computes for CONF, with no keyring
ctx_of() {
  : > "$work/no-records.tsv"
  # shellcheck disable=SC2016 # the positional parameters of the inner script
  REPO_ROOT="$root" bash -c '. "$1"; verify_context "$2" "$3"' _ "$LIB" "$1" "$work/no-records.tsv"
}

# run_plan NAME CONF... -> plan's status; its output in $work/out-NAME, its
# log in $work/NAME.err, its requests in $work/NAME.calls
PLAN="$REPO_ROOT/scripts/plan"
run_plan() {
  local name="$1" rc=0
  shift
  rm -rf "$work/out-$name"
  : > "$work/$name.calls"
  : > "$net/oras.log"
  REPO_ROOT="$root" PATH="$bin:$PATH" FAKE_CURL_LOG="$work/$name.calls" PLAN_BUDGET=120 TARGETS_DIR="$work/targets" \
    "$PLAN" "$work/out-$name" "$@" > "$work/$name.out" 2> "$work/$name.err" || rc=$?
  return "$rc"
}
# names FILE [COLUMN] -> the package names of a file column (default 1), sorted
names() {
  awk -F '\t' -v c="${2:-1}" '{ n = $c; sub(/-1-1-[a-z0-9_]+\.pkg\.tar\.zst$/, "", n); print n }' "$1" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}
# meta NAME TARGET KEY -> the value of KEY in the target's meta.env
meta() {
  sed -n "s/^$3=//p" "$work/out-$1/$2/meta.env"
}
# subset NAME TARGET: a check that every todo file is in new.tsv
subset() {
  local d="$work/out-$1/$2" missing
  missing="$(awk -F '\t' 'FILENAME == ARGV[1] { n[$2] = 1; next } !($2 in n) { print $2 }' "$d/new.tsv" "$d/todo.tsv")"
  check "$1: every todo file of $2 is in new.tsv" "" "$missing" "cat $d/todo.tsv $d/new.tsv"
}
RP="REPO_ROOT=<stand-ins> PATH=<curl stand-in>:\$PATH scripts/plan OUT CONF"

#---------------------------------------------------------------------------#
# x86_64-core: one record per case
#   p1   promoted                                   skip
#   p2   indexed, verified, this context            skip, vouched 1
#   p3   indexed, not verified                      verify, vouched 0
#   p4   index row of another sha256                todo, withdrawn
#   p5   indexed as absent upstream                 todo
#   p6   new                                        todo
#   p7   promoted and indexed, verified             skip, vouched 1
#   p8   indexed with no signature, signed now      todo (step 4), withdrawn
#   p9   promoted with another %PGPSIG%             todo
#   p10  indexed with no signature, none upstream   skip, vouched 1 1
#   p11  index row of another %PGPSIG%              todo, withdrawn
#   p12  promoted, and indexed as absent upstream   skip: a promoted
#        database names it
#---------------------------------------------------------------------------#
CORE="test/mirror/x86_64/core"
# shellcheck disable=SC2016 # $repo and $arch are the target file's
printf 'arch = x86_64\nrepo = core\ndb_server = https://up.test/$repo/os/$arch\n' > "$work/targets/x86_64-core.conf"
CONF="$work/targets/x86_64-core.conf"
up="$work/core-up"
for n in p1 p2 p3 p4 p5 p6 p7 p9 p11 p12; do
  pkg "$up" "$n" x86_64 c2ln
done
pkg "$up" p8 x86_64 ''
pkg "$up" p10 x86_64 ''
mkdir -p "$A/up.test/core/os/x86_64"
mkdb "$up" "$A/up.test/core/os/x86_64/core.db" "$A/up.test/core/os/x86_64/core.files"
# The .sig of p8: a signature packet (0x89). p10 has none.
printf '\211 a signature packet' > "$A/up.test/core/os/x86_64/p8-1-1-x86_64.pkg.tar.zst.sig"

prom="$work/core-promoted"
pkg "$prom" p1 x86_64 c2ln
pkg "$prom" p7 x86_64 c2ln
pkg "$prom" p9 x86_64 "$SIG_OTHER"
pkg "$prom" p12 x86_64 c2ln
mkdb "$prom" "$work/core-promoted.db"
put_latest "$CORE" "$work/core-promoted.db" core.db

ref="$work/core-ref"
for n in p2 p3 p5 p7 p12; do
  pkg "$ref" "$n" x86_64 c2ln
done
pkg "$ref" p4 x86_64 c2ln 4444444444444444444444444444444444444444444444444444444444444444
pkg "$ref" p8 x86_64 ''
pkg "$ref" p10 x86_64 ''
pkg "$ref" p11 x86_64 "$SIG_OTHER"
mkdb "$ref" "$work/core-ref.db"
rows 'p10 m 1 1' 'p11 m 1 0' 'p12 a 0 0' 'p2 m 1 0' 'p3 m 0 0' 'p4 m 1 0' 'p5 a 0 0' 'p7 m 1 0' 'p8 m 1 1' > "$work/core-index.tsv"
CTX="$(ctx_of "$CONF")"
OTHER_CTX=0000000000000000000000000000000000000000000000000000000000000001

put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX"
rc=0
REGISTRY_TOKEN=secret run_plan matrix "$CONF" || rc=$?
D="$work/out-matrix/x86_64-core"
check "matrix: plan exits 0, the target pending, the index ok" "0 pending ok" \
  "$rc $(cat "$D/state" 2> /dev/null) $(meta matrix x86_64-core INDEX_STATE)" "$RP; cat $work/matrix.err"
check "matrix: todo is what is not promoted or indexed, absent upstream, or signed now" "p11 p4 p5 p6 p8 p9" \
  "$(names "$D/todo.tsv" 2)" "$RP; cat $D/todo.tsv"
check "matrix: new is todo and what is not promoted and not indexed as verified" "p11 p3 p4 p5 p6 p8 p9" \
  "$(names "$D/new.tsv" 2)" "$RP; cat $D/new.tsv"
check "matrix: the file only to verify has the action verify" "p3-1-1-x86_64.pkg.tar.zst verify" \
  "$(awk -F '\t' '$7 == "verify" { print $2 " " $7 }' "$D/new.tsv")" "cat $D/new.tsv"
check "matrix: vouched names the indexed files not planned again, with their flags" \
  "p10-1-1-x86_64.pkg.tar.zst 1 1|p2-1-1-x86_64.pkg.tar.zst 1 0|p3-1-1-x86_64.pkg.tar.zst 0 0|p7-1-1-x86_64.pkg.tar.zst 1 0|" \
  "$(LC_ALL=C sort "$D/vouched.tsv" | tr '\t\n' ' |')" "cat $D/vouched.tsv"
check "matrix: the indexed file with no .sig upstream stays unsigned" "p10-1-1-x86_64.pkg.tar.zst" "$(cat "$D/unsigned.txt")" "cat $D/unsigned.txt"
subset matrix x86_64-core
check "matrix: the verify context is the one lib.sh verify_context gives, and goes out" "$CTX $CTX $CTX" \
  "$(meta matrix x86_64-core VERIFY_CONTEXT) $(meta matrix x86_64-core INDEX_CONTEXT) $(meta matrix x86_64-core INDEX_CONTEXT_OUT)" "cat $D/meta.env"
check "matrix: the rows of the todo files are withdrawn: one push of the index" 1 \
  "$(awk -v r="ghcr.io/$CORE:index" '$1 == "push" && index($0, r) { n++ } END { print n + 0 }' "$net/oras.log")" "cat $net/oras.log"
live="$A/ghcr.io/v2/$CORE/manifests/index"
# layer_of MANIFEST TITLE -> the digest of the layer with that title
layer_of() {
  jq -r --arg t "$2" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest' "$1"
}
check "matrix: the index pushed keeps the other rows, the same ref.db and the same annotations, and names this plan in withdrawn-by" \
  "p10 p12 p2 p3 p5 p7|sha256:$(sha256sum "$work/core-ref.db" | cut -d ' ' -f 1)|older.1.1 1 $CTX $(cat "$work/out-matrix/plan-id" 2> /dev/null)" \
  "$(names "$A/ghcr.io/v2/$CORE/blobs/$(layer_of "$live" index.tsv)")|$(layer_of "$live" ref.db)|$(jq -r '.annotations["dev.pkgforge.mirror.plan-id"] + " " + .annotations["dev.pkgforge.mirror.index-format"] + " " + .annotations["dev.pkgforge.mirror.verify-context"] + " " + (.annotations["dev.pkgforge.mirror.withdrawn-by"] // "none")' "$live")" \
  "jq . $live"
check "matrix: INDEX_DIGEST is the digest of the index read back" "sha256:$(sha256sum "$live" | cut -d ' ' -f 1)" \
  "$(meta matrix x86_64-core INDEX_DIGEST)" "cat $D/meta.env; sha256sum $live"
check "matrix: the artifact holds no read of the index" "absent absent" \
  "$([ -e "$D/index" ] && echo present || echo absent) $([ -e "$D/indexed.tsv" ] && echo present || echo absent)" "ls $D"
check "matrix: no upstream read is kept after the plan" absent \
  "$([ -e "$work/out-matrix/.fetch-cache" ] && echo present || echo absent)" "ls -a $work/out-matrix"
case "$(cat "$D/why")" in
  '6 file(s) to mirror, 7 to verify, '*) ok "matrix: the why names the files to mirror and to verify" ;;
  *) fail "matrix: the why names the files to mirror and to verify" "$(cat "$D/why")" "$RP" ;;
esac

# Another verify context: no file counts as verified, and no file is mirrored
# for it.
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$OTHER_CTX"
rc=0
REGISTRY_TOKEN=secret run_plan context "$CONF" || rc=$?
D="$work/out-context/x86_64-core"
check "context: another verify context keeps todo" "0 p11 p4 p5 p6 p8 p9" "$rc $(names "$D/todo.tsv" 2)" "$RP; cat $work/context.err"
check "context: another verify context verifies every indexed file again" "p10 p11 p2 p3 p4 p5 p6 p8 p9" \
  "$(names "$D/new.tsv" 2)" "cat $D/new.tsv"
check "context: and vouches for them with verified 0" \
  "p10-1-1-x86_64.pkg.tar.zst 0 1|p2-1-1-x86_64.pkg.tar.zst 0 0|p3-1-1-x86_64.pkg.tar.zst 0 0|p7-1-1-x86_64.pkg.tar.zst 0 0|" \
  "$(LC_ALL=C sort "$D/vouched.tsv" | tr '\t\n' ' |')" "cat $D/vouched.tsv"
check "context: the index this run writes takes this run's context" "$CTX $OTHER_CTX" \
  "$(meta context x86_64-core INDEX_CONTEXT_OUT) $(meta context x86_64-core INDEX_CONTEXT)" "cat $D/meta.env"
subset context x86_64-core

# The withdrawal fails: the target is in error, and nothing is sharded.
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX"
touch "$net/oras-fail"
rc=0
REGISTRY_TOKEN=secret run_plan nowithdraw "$CONF" || rc=$?
rm -f "$net/oras-fail"
D="$work/out-nowithdraw/x86_64-core"
check "withdrawal: a push that fails puts the target in error" "0 error" "$rc $(cat "$D/state" 2> /dev/null)" "$RP; cat $work/nowithdraw.err"
case "$(cat "$D/why" 2> /dev/null)" in
  'could not withdraw 3 index row(s) before their tags are written'*) ok "withdrawal: the why names the rows not withdrawn" ;;
  *) fail "withdrawal: the why names the rows not withdrawn" "$(cat "$D/why" 2> /dev/null)" "$RP" ;;
esac
check "withdrawal: the target has no shard" '{"include":[]}' "$(cat "$work/out-nowithdraw/targets.json")" "cat $work/out-nowithdraw/targets.json"

# No index: plan as before the index.
rm -f "$A/ghcr.io/v2/$CORE/manifests/index"
rc=0
REGISTRY_TOKEN=secret run_plan absent "$CONF" || rc=$?
D="$work/out-absent/x86_64-core"
check "absent: no index: every file not promoted is todo, and nothing is vouched" "0 absent p10 p11 p2 p3 p4 p5 p6 p8 p9 0" \
  "$rc $(meta absent x86_64-core INDEX_STATE) $(names "$D/todo.tsv" 2) $(awk 'END { print NR + 0 }' "$D/vouched.tsv")" "$RP; cat $work/absent.err"
subset absent x86_64-core

# The index answers 503: unread, a warning, and the plan goes on as with none.
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX"
printf '503\n' > "$A/ghcr.io/v2/$CORE/manifests/index.code"
rc=0
REGISTRY_TOKEN=secret run_plan unread "$CONF" || rc=$?
rm -f "$A/ghcr.io/v2/$CORE/manifests/index.code"
D="$work/out-unread/x86_64-core"
check "unread: a 503 leaves the target pending, the index unread, no digest, nothing vouched" "0 pending unread  0" \
  "$rc $(cat "$D/state" 2> /dev/null) $(meta unread x86_64-core INDEX_STATE) $(meta unread x86_64-core INDEX_DIGEST) $(awk 'END { print NR + 0 }' "$D/vouched.tsv")" \
  "$RP; cat $work/unread.err"
if grep -q "warning: x86_64-core: $CORE:index did not read" "$work/unread.err"; then
  ok "unread: a warning names the index"
else
  fail "unread: a warning names the index" "$(grep -i index "$work/unread.err")" "$RP"
fi
check "unread: no push of the index" 0 "$(awk '$1 == "push" { n++ } END { print n + 0 }' "$net/oras.log")" "cat $net/oras.log"

# x86_64-pub, with no latest yet: the anonymous read of its index answers
# 503, and the read with the token is ok. The index is used, and the package
# is not private: a 503 says nothing about who may read the package. Its one
# file is indexed and verified, so nothing is withdrawn.
PUB="test/mirror/x86_64/pub"
# shellcheck disable=SC2016 # $repo and $arch are the target file's
printf 'arch = x86_64\nrepo = pub\ndb_server = https://up.test/$repo/os/$arch\n' > "$work/targets/x86_64-pub.conf"
PUBCONF="$work/targets/x86_64-pub.conf"
pkg "$work/pub-up" r1 x86_64 c2ln
mkdir -p "$A/up.test/pub/os/x86_64" "$A/ghcr.io/v2/$PUB/manifests"
mkdb "$work/pub-up" "$A/up.test/pub/os/x86_64/pub.db" "$A/up.test/pub/os/x86_64/pub.files"
rows 'r1 m 1 0' > "$work/pub-index.tsv"
put_index "$T" "$PUB" "$A/up.test/pub/os/x86_64/pub.db" "$work/pub-index.tsv" "$(ctx_of "$PUBCONF")"
printf '503\n' > "$A/ghcr.io/v2/$PUB/manifests/index.code"
rc=0
REGISTRY_TOKEN=secret run_plan anon503 "$PUBCONF" || rc=$?
check "anonymous 503, then ok with the token: the index is ok, and PRIVATE=0" "0 pending ok 0" \
  "$rc $(cat "$work/out-anon503/x86_64-pub/state" 2> /dev/null) $(meta anon503 x86_64-pub INDEX_STATE) $(meta anon503 x86_64-pub PRIVATE)" \
  "$RP; cat $work/anon503.err"
if grep -q 'the package is private' "$work/anon503.err"; then
  fail "anonymous 503, then ok with the token: no warning says the package is private" "$(grep 'private' "$work/anon503.err")" "$RP"
else
  ok "anonymous 503, then ok with the token: no warning says the package is private"
fi

# An artifact of another type at the tag: invalid, with its digest.
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX" application/vnd.example.other
rc=0
REGISTRY_TOKEN=secret run_plan foreign "$CONF" || rc=$?
D="$work/out-foreign/x86_64-core"
check "invalid: a foreign artifactType is not used, and its digest is kept" \
  "0 invalid sha256:$(sha256sum "$A/ghcr.io/v2/$CORE/manifests/index" | cut -d ' ' -f 1) p10 p11 p2 p3 p4 p5 p6 p8 p9" \
  "$rc $(meta foreign x86_64-core INDEX_STATE) $(meta foreign x86_64-core INDEX_DIGEST) $(names "$D/todo.tsv" 2)" "$RP; cat $work/foreign.err"
check "invalid: no push of the index" 0 "$(awk '$1 == "push" { n++ } END { print n + 0 }' "$net/oras.log")" "cat $net/oras.log"

# 2 bad lines of 8: more than 1%.
{
  rows 'p2 m 1 0' 'p3 m 2 0' 'p5 a 0 0' 'p7 m 1 0' 'p8 m 1 1' 'p10 m 1 1' 'p11 m 1 0'
  printf 'p99-1-1-x86_64.pkg.tar.zst\tm\t0\t0\n'
} > "$work/core-bad.tsv"
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-bad.tsv" "$CTX"
rc=0
REGISTRY_TOKEN=secret run_plan badlines "$CONF" || rc=$?
check "invalid: 2 bad lines of 8 make the index invalid" "0 invalid" "$rc $(meta badlines x86_64-core INDEX_STATE)" "$RP; cat $work/badlines.err"

# INDEX_READ=0: the rows are not read. The manifest of the tag is read alone,
# so index-write knows which index the reset replaces: its digest, or that
# there is no tag; neither when it does not read.
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX"
rc=0
REGISTRY_TOKEN=secret INDEX_READ=0 run_plan ignored "$CONF" || rc=$?
D="$work/out-ignored/x86_64-core"
check "ignored: INDEX_READ=0 reads the manifest of the index alone, no blob, and plans as with no index" "0 ignored 1 0 p10 p11 p2 p3 p4 p5 p6 p8 p9" \
  "$rc $(meta ignored x86_64-core INDEX_STATE) $(awk '/\/manifests\/index$/ { n++ } END { print n + 0 }' "$work/ignored.calls") $(awk '/\/blobs\// { n++ } END { print n + 0 }' "$work/ignored.calls") $(names "$D/todo.tsv" 2)" \
  "INDEX_READ=0 $RP; cat $work/ignored.calls"
check "ignored: INDEX_DIGEST is the digest of the manifest plan saw, and INDEX_PRIOR is empty" \
  "sha256:$(sha256sum "$A/ghcr.io/v2/$CORE/manifests/index" | cut -d ' ' -f 1)|" \
  "$(meta ignored x86_64-core INDEX_DIGEST)|$(meta ignored x86_64-core INDEX_PRIOR)" "cat $D/meta.env"
rm -f "$A/ghcr.io/v2/$CORE/manifests/index"
rc=0
REGISTRY_TOKEN=secret INDEX_READ=0 run_plan ignoredabsent "$CONF" || rc=$?
check "ignored: no index tag: INDEX_PRIOR is absent, and INDEX_DIGEST is empty" "0 ignored |absent" \
  "$rc $(meta ignoredabsent x86_64-core INDEX_STATE) $(meta ignoredabsent x86_64-core INDEX_DIGEST)|$(meta ignoredabsent x86_64-core INDEX_PRIOR)" \
  "INDEX_READ=0 $RP; cat $work/ignoredabsent.err"
put_index "$A" "$CORE" "$work/core-ref.db" "$work/core-index.tsv" "$CTX"
printf '503\n' > "$A/ghcr.io/v2/$CORE/manifests/index.code"
rc=0
REGISTRY_TOKEN=secret INDEX_READ=0 run_plan ignoredbusy "$CONF" || rc=$?
rm -f "$A/ghcr.io/v2/$CORE/manifests/index.code"
check "ignored: a tag that answers 503: both empty, and the target still plans" "0 ignored pending |" \
  "$rc $(meta ignoredbusy x86_64-core INDEX_STATE) $(cat "$work/out-ignoredbusy/x86_64-core/state" 2> /dev/null) $(meta ignoredbusy x86_64-core INDEX_DIGEST)|$(meta ignoredbusy x86_64-core INDEX_PRIOR)" \
  "INDEX_READ=0 $RP; cat $work/ignoredbusy.err"
if grep -q "warning: x86_64-core: INDEX_READ=0: the manifest of $CORE:index did not read" "$work/ignoredbusy.err"; then
  ok "ignored: a warning says the manifest did not read, and this run writes no index"
else
  fail "ignored: a warning says the manifest did not read, and this run writes no index" "$(grep -i index "$work/ignoredbusy.err")" "INDEX_READ=0 $RP"
fi

#---------------------------------------------------------------------------#
# x86_64-priv: a private package with no latest yet. Its index and its tags
# read only with the token. Step 4b reads the tags with the token too, so the
# signatures compare equal and nothing escalates.
#---------------------------------------------------------------------------#
PRIV="test/mirror/x86_64/priv"
# shellcheck disable=SC2016 # $repo and $arch are the target file's
printf 'arch = x86_64\nrepo = priv\ndb_server = https://up.test/$repo/os/$arch\n' > "$work/targets/x86_64-priv.conf"
PCONF="$work/targets/x86_64-priv.conf"
pup="$work/priv-up"
mkdir -p "$A/up.test/priv/os/x86_64"
for n in q1 q2 q3; do
  pkg "$pup" "$n" x86_64 ''
  printf '\211 the signature of %s' "$n" > "$A/up.test/priv/os/x86_64/$n-1-1-x86_64.pkg.tar.zst.sig"
  sigsha="$(sha256sum "$A/up.test/priv/os/x86_64/$n-1-1-x86_64.pkg.tar.zst.sig" | cut -d ' ' -f 1)"
  mkdir -p "$T/ghcr.io/v2/$PRIV/manifests"
  jq -cn --arg f "$n-1-1-x86_64.pkg.tar.zst" --arg p "sha256:$(printf '%s-1-1' "$n" | sha256sum | cut -d ' ' -f 1)" --arg s "sha256:$sigsha" \
    '{schemaVersion: 2, layers: [{mediaType: "application/vnd.pkgforge.archlinux.pkg.v1", digest: $p, size: 1000, annotations: {"org.opencontainers.image.title": $f}},
      {mediaType: "application/pgp-signature", digest: $s, size: 30, annotations: {"org.opencontainers.image.title": ($f + ".sig")}}]}' \
    > "$T/ghcr.io/v2/$PRIV/manifests/$("$REAL_WRAPPER" --tag "$n-1-1-x86_64.pkg.tar.zst")"
done
mkdb "$pup" "$A/up.test/priv/os/x86_64/priv.db" "$A/up.test/priv/os/x86_64/priv.files"
rows 'q1 m 1 0' 'q2 m 1 0' 'q3 m 0 0' > "$work/priv-index.tsv"
put_index "$T" "$PRIV" "$A/up.test/priv/os/x86_64/priv.db" "$work/priv-index.tsv" "$(ctx_of "$PCONF")"
rc=0
REGISTRY_TOKEN=secret SIGCHECK_ESCALATE=1 run_plan private "$PCONF" || rc=$?
D="$work/out-private/x86_64-priv"
check "private: the index reads only with the token: ok, and PRIVATE=1" "0 ok 1" \
  "$rc $(meta private x86_64-priv INDEX_STATE) $(meta private x86_64-priv PRIVATE)" "$RP; cat $work/private.err"
if grep -q "warning: x86_64-priv: $PRIV:index reads only with the workflow's token; the package is private" "$work/private.err"; then
  ok "private: a warning says the package is private"
else
  fail "private: a warning says the package is private" "$(grep -i private "$work/private.err")" "$RP"
fi
if grep -q 'every detached signature is checked this run' "$work/private.err" || ! grep -q '3 of 3 file(s) with a detached signature only compared with their tags, 0 changed upstream' "$work/private.err"; then
  fail "private: step 4b reads the tags with the token: 3 compared, 0 changed, no escalation" "$(grep -E 'detached|signed' "$work/private.err")" "SIGCHECK_ESCALATE=1 $RP"
else
  ok "private: step 4b reads the tags with the token: 3 compared, 0 changed, no escalation"
fi
check "private: nothing to mirror, one file to verify: pending with no shard" "pending 0 1 {\"include\":[{\"target\":\"x86_64-priv\",\"shards\":[]}]}" \
  "$(cat "$D/state") $(awk 'END { print NR + 0 }' "$D/todo.tsv") $(awk 'END { print NR + 0 }' "$D/new.tsv") $(cat "$work/out-private/pending.json")" \
  "cat $D/why $work/out-private/pending.json"
case "$(cat "$D/why")" in
  '0 file(s) to mirror, 1 to verify, '*) ok "private: the why names both counts" ;;
  *) fail "private: the why names both counts" "$(cat "$D/why")" "$RP" ;;
esac
subset private x86_64-priv

#---------------------------------------------------------------------------#
# The base-any targets: two enabled ones and a disabled one share a
# db_server. Their sources (sources.tsv) and their upstream reads.
#   powerpc64-base-any latest: s1 (same bytes) and s2 (other bytes); its
#     index: s1 m (no signature), s3 m, s4 a
#   powerpc-base-any: no latest; its index: s1 m (no signature)
#   powerpc64le-base-any, enabled = no: latest names s5
#---------------------------------------------------------------------------#
bup="$work/any-up"
pkg "$bup" s1 any ''
for n in s2 s3 s4 s5; do
  pkg "$bup" "$n" any c2ln
done
mkdir -p "$A/up.test/base/any"
mkdb "$bup" "$A/up.test/base/any/base-any.db" "$A/up.test/base/any/base-any.files"
printf 'a db signature' > "$A/up.test/base/any/base-any.db.sig"
printf 'a files signature' > "$A/up.test/base/any/base-any.files.sig"
printf '\211 the signature of s1' > "$A/up.test/base/any/s1-1-1-any.pkg.tar.zst.sig"
for a in powerpc powerpc64 powerpc64le; do
  printf 'arch = %s\nrepo = base-any\ndb_server = https://up.test/base/any\n' "$a" > "$work/targets/$a-base-any.conf"
done
printf 'enabled = no\n' >> "$work/targets/powerpc64le-base-any.conf"
P64="test/mirror/powerpc64/base-any"
P32="test/mirror/powerpc/base-any"
P64LE="test/mirror/powerpc64le/base-any"
s64="$work/any-64"
pkg "$s64" s1 any ''
pkg "$s64" s2 any c2ln 2222222222222222222222222222222222222222222222222222222222222222
mkdb "$s64" "$work/any-64.db"
put_latest "$P64" "$work/any-64.db" base-any.db
printf 's1-1-1-any.pkg.tar.zst\tm\t0\t1\ns3-1-1-any.pkg.tar.zst\tm\t1\t0\ns4-1-1-any.pkg.tar.zst\ta\t0\t0\n' > "$work/any-64-index.tsv"
put_index "$A" "$P64" "$A/up.test/base/any/base-any.db" "$work/any-64-index.tsv" ""
printf 's1-1-1-any.pkg.tar.zst\tm\t0\t1\n' > "$work/any-32-index.tsv"
put_index "$A" "$P32" "$A/up.test/base/any/base-any.db" "$work/any-32-index.tsv" ""
s64le="$work/any-64le"
pkg "$s64le" s5 any c2ln
mkdb "$s64le" "$work/any-64le.db"
put_latest "$P64LE" "$work/any-64le.db" base-any.db
rc=0
REGISTRY_TOKEN=secret run_plan anypair "$work/targets/powerpc-base-any.conf" "$work/targets/powerpc64-base-any.conf" || rc=$?
D="$work/out-anypair/powerpc-base-any"
check "sources: both base-any targets pending" "0 pending pending" \
  "$rc $(cat "$D/state" 2> /dev/null) $(cat "$work/out-anypair/powerpc64-base-any/state" 2> /dev/null)" "$RP; cat $work/anypair.err"
check "sources: a todo file whose bytes the latest or the index of a sibling holds names it; other bytes, state a and a disabled target do not" \
  "s1-1-1-any.pkg.tar.zst $P64|s3-1-1-any.pkg.tar.zst $P64|" \
  "$(LC_ALL=C sort "$D/sources.tsv" | tr '\t\n' ' |')" "$RP; cat $D/sources.tsv $D/todo.tsv"
check "sources: a sibling's ref.db that is the upstream database is not downloaded" 0 \
  "$(awk -v d="blobs/sha256:$(sha256sum "$A/up.test/base/any/base-any.db" | cut -d ' ' -f 1)" 'index($0, d) { n++ } END { print n + 0 }' "$work/anypair.calls")" \
  "cat $work/anypair.calls"
# calls URL -> how many requests of the plan went to URL
calls() {
  awk -v u="$1" '$0 == u { n++ } END { print n + 0 }' "$work/anypair.calls"
}
check "fetch cache: base-any.db is read by each target, and never kept" 2 "$(calls https://up.test/base/any/base-any.db)" "cat $work/anypair.calls"
check "fetch cache: base-any.files, its signature and the database's are read once for both targets" "1 1 1" \
  "$(calls https://up.test/base/any/base-any.files) $(calls https://up.test/base/any/base-any.files.sig) $(calls https://up.test/base/any/base-any.db.sig)" \
  "cat $work/anypair.calls"
check "fetch cache: the .sig of a package that both targets ask again is read once" 1 \
  "$(calls https://up.test/base/any/s1-1-1-any.pkg.tar.zst.sig)" "cat $work/anypair.calls"
check "fetch cache: both targets plan s1 again, from the one read" "s1-1-1-any.pkg.tar.zst s1-1-1-any.pkg.tar.zst" \
  "$(awk -F '\t' '$2 == "s1-1-1-any.pkg.tar.zst" { print $2 }' "$D/todo.tsv") $(awk -F '\t' '$2 == "s1-1-1-any.pkg.tar.zst" { print $2 }' "$work/out-anypair/powerpc64-base-any/todo.tsv")" \
  "cat $work/anypair.err"
check "fetch cache: nothing is kept after the plan" absent \
  "$([ -e "$work/out-anypair/.fetch-cache" ] && echo present || echo absent)" "ls -a $work/out-anypair"
subset anypair powerpc-base-any
subset anypair powerpc64-base-any

# A .files.sig that answers 503 is not kept: each target asks it.
put_index "$A" "$P32" "$A/up.test/base/any/base-any.db" "$work/any-32-index.tsv" ""
put_index "$A" "$P64" "$A/up.test/base/any/base-any.db" "$work/any-64-index.tsv" ""
printf '503\n' > "$A/up.test/base/any/base-any.files.sig.code"
rc=0
REGISTRY_TOKEN=secret run_plan anybusy "$work/targets/powerpc-base-any.conf" "$work/targets/powerpc64-base-any.conf" || rc=$?
rm -f "$A/up.test/base/any/base-any.files.sig.code"
check "fetch cache: a read that answers 503 is asked again by the next target" "0 2 error error" \
  "$rc $(awk '$0 == "https://up.test/base/any/base-any.files.sig" { n++ } END { print n + 0 }' "$work/anybusy.calls") $(cat "$work/out-anybusy/powerpc-base-any/state") $(cat "$work/out-anybusy/powerpc64-base-any/state")" \
  "cat $work/anybusy.calls $work/anybusy.err"

#---------------------------------------------------------------------------#
# lib.sh index_read alone: a filename on two lines drops both, and the index
# stays ok while at most 1% of its lines are dropped
#---------------------------------------------------------------------------#
BIG="test/mirror/x86_64/big"
big="$work/big-up"
: > "$work/big-index.tsv"
for i in $(seq 1 200); do
  pkg "$big" "b$i" x86_64 c2ln
  printf 'b%s-1-1-x86_64.pkg.tar.zst\tm\t1\t0\n' "$i" >> "$work/big-index.tsv"
done
mkdb "$big" "$work/big.db"
printf 'b7-1-1-x86_64.pkg.tar.zst\tm\t0\t0\n' >> "$work/big-index.tsv"
put_index "$A" "$BIG" "$work/big.db" "$work/big-index.tsv" ""
# read_index NAME -> the state index_read prints; its output in $work/read-NAME,
# its log in $work/read-NAME.err, its requests in $work/read-NAME.calls
read_index() {
  # shellcheck disable=SC2016 # the positional parameters of the inner script
  PATH="$bin:$PATH" FAKE_CURL_LOG="$work/read-$1.calls" bash -c '. "$1"; index_read "$2" index "$3" "$4"' _ "$LIB" "$BIG" "$work/read-$1" "$work/big.db" \
    2> "$work/read-$1.err"
}
IR="bash -c '. scripts/lib.sh; index_read $BIG index OUT DB' against the stand-in"
check "index_read: 2 of 201 lines dropped (a filename twice) is ok, with 199 rows and no b7" "ok 199 0" \
  "$(read_index dup) $(awk 'END { print NR + 0 }' "$work/read-dup/index.tsv") $(awk -F '\t' '$1 == "b7-1-1-x86_64.pkg.tar.zst" { n++ } END { print n + 0 }' "$work/read-dup/index.tsv")" \
  "$IR; cat $work/read-dup.err"
check "index_read: a ref.db that is the DB given is copied, not read: 2 requests, no ref.db" "2 0" \
  "$(awk 'END { print NR + 0 }' "$work/read-dup.calls") $(awk -v d="blobs/sha256:$(sha256sum "$work/big.db" | cut -d ' ' -f 1)" 'index($0, d) { n++ } END { print n + 0 }' "$work/read-dup.calls")" \
  "$IR; cat $work/read-dup.calls"
put_index "$A" "$BIG" "$work/big.db" "$work/big-index.tsv" "not a context"
check "index_read: a verify-context that is not 64 hex digits is invalid" invalid "$(read_index ctx)" "$IR; cat $work/read-ctx.err"
printf 'nothere-1-1-x86_64.pkg.tar.zst\tm\t0\t0\n' >> "$work/big-index.tsv"
put_index "$A" "$BIG" "$work/big.db" "$work/big-index.tsv" ""
check "index_read: 3 of 202 lines dropped is more than 1%: invalid" invalid "$(read_index over)" "$IR; cat $work/read-over.err"
rm -f "$A/ghcr.io/v2/$BIG/manifests/index"
check "index_read: no tag is absent" absent "$(read_index none)" "$IR"

#---------------------------------------------------------------------------#
# lib.sh index_push alone: the layers, the type and the annotations; a 429
# costs no attempt and the caller's THROTTLE_WAITED is kept
#---------------------------------------------------------------------------#
ip="$work/push"
mkdir -p "$ip"
cp "$work/big.db" "$ip/ref.db"
printf 'b1-1-1-x86_64.pkg.tar.zst\tm\t0\t0\n' > "$ip/index.tsv"
printf '1\n' > "$net/oras-429"
: > "$net/oras.log"
rc=0
# shellcheck disable=SC2016 # the positional parameters of the inner script
got="$(RATE_PAUSE_MIN=1 RATE_PAUSE_MAX=1 PATH="$bin:$PATH" bash -c '. "$1"; ORAS_CONFIG="$2/oras.json"; THROTTLE_WAITED=7
  index_push "$3" test/mirror/x86_64/pushed index-feature "$2" a=1 "b=two words" || exit $?
  printf "%s\n" "$THROTTLE_WAITED"' _ "$LIB" "$ip" "$bin/oras" 2> "$work/push.err")" || rc=$?
pm="$A/ghcr.io/v2/test/mirror/x86_64/pushed/manifests/index-feature"
check "index_push: one 429, then pushed; the caller's THROTTLE_WAITED is kept" "0 7 2" \
  "$rc $got $(awk '$1 == "push" { n++ } END { print n + 0 }' "$net/oras.log")" "index_push; cat $work/push.err $net/oras.log"
check "index_push: the artifactType, the layers and the annotations" \
  "application/vnd.pkgforge.archlinux.index.v1 ref.db=application/vnd.pkgforge.archlinux.db.v1 index.tsv=application/vnd.pkgforge.archlinux.index.v1+tsv a=1 b=two words" \
  "$(jq -r '[.artifactType, (.layers[] | .annotations["org.opencontainers.image.title"] + "=" + .mediaType), "a=" + .annotations.a, "b=" + .annotations.b] | join(" ")' "$pm" 2> /dev/null)" \
  "jq . $pm"
touch "$net/oras-fail"
rc=0
# shellcheck disable=SC2016 # the positional parameters of the inner script
PATH="$bin:$PATH" bash -c '. "$1"; ORAS_CONFIG="$2/oras.json"; index_push "$3" test/mirror/x86_64/pushed index "$2"' _ "$LIB" "$ip" "$bin/oras" \
  > /dev/null 2> "$work/push-fail.err" || rc=$?
rm -f "$net/oras-fail"
check "index_push: a push that fails is tried twice, then 1" "1 2" \
  "$rc $(grep -c 'index push attempt' "$work/push-fail.err")" "index_push; cat $work/push-fail.err"

# A DIR relative to the current directory, as scripts/plan OUT gives it with
# a relative OUT: the push runs from inside DIR, and its log is still found.
: > "$net/oras.log"
rc=0
# shellcheck disable=SC2016 # the positional parameters of the inner script
(cd "$work" && PATH="$bin:$PATH" bash -c '. "$1"; ORAS_CONFIG="$PWD/push/oras.json"; index_push "$2" test/mirror/x86_64/pushed index-rel push' _ "$LIB" "$bin/oras") \
  > /dev/null 2> "$work/push-rel.err" || rc=$?
check "index_push: a relative DIR is pushed on the first attempt" "0 1 yes" \
  "$rc $(awk '$1 == "push" { n++ } END { print n + 0 }' "$net/oras.log") $([ -f "$A/ghcr.io/v2/test/mirror/x86_64/pushed/manifests/index-rel" ] && echo yes || echo no)" \
  "cd WORK && index_push ORAS REPO index-rel push; cat $work/push-rel.err"

summary
