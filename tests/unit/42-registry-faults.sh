#!/usr/bin/env bash
#
# The scripts that write to the registry, run against stand-ins for curl and
# oras, with no network: what each one does when the registry fails, refuses
# or limits it. stage, promote and index-write install oras through
# REPO_ROOT/scripts/install-oras, so they run with REPO_ROOT set to a root of
# stand-ins; lib.sh still comes from the real scripts directory. Then the
# files stage gives verify, the files at fault that verify-batch names, and
# the rows, the verify credit and the writer guard of index-write. Last, the
# re-run guard of mirror-shard (lib.sh index_guard), and in mirror-file: the
# sources of the package bytes (its own repository on a repush, the siblings
# plan names, upstream), the absent rule, MIRROR_REPAIR=0, the repush rule
# (INDEX_STATE) and the re-run guard; then the INDEX_STATE that mirror-shard
# reads from the plan's meta.env and gives mirror-file.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

FAKE="$work/fake"
# The scripts under test, from the real tree
SCRIPTS="$REPO_ROOT/scripts"
mkdir -p "$FAKE/bin" "$FAKE/root/scripts" "$FAKE/root/client" "$FAKE/up" "$work/targets"
export FAKE

#---------------------------------------------------------------------------#
# Stand-ins
#---------------------------------------------------------------------------#
cat > "$FAKE/bin/curl" << 'EOF'
#!/usr/bin/env bash
# A stand-in for curl. Logs "URL<TAB>AUTH" to $FAKE/calls.log. Answers:
#   */token          a token: "tok1" with a credential on stdin (--config -),
#                    "anon" with none
#   */manifests/REF  from $FAKE/answers.tsv, AUTH<TAB>CODE<TAB>BODY-FILE[<TAB>REF],
#                    the first line whose AUTH matches, and whose REF is REF
#                    or not given; no line is no answer
#   */v2/REPO/blobs/*  from $FAKE/blobs.tsv, REPO<TAB>CODE<TAB>BODY-FILE, the
#                    first line of REPO; with no line, as any other URL
#   any other URL    $FAKE/up/<last path element, less a sha256: prefix>:
#                    the code in that file's .code, or 200 with the file,
#                    or 404
# With --write-out, prints the HTTP code.
out="" auth="" url="" cred="" wo="" blob=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --header) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift 2 ;;
    --config) if [ "$2" = - ]; then cred="$(cat)"; fi; shift 2 ;;
    --write-out) wo="$2"; shift 2 ;;
    --user | --data-urlencode | --connect-timeout | --max-time | --retry | --retry-delay | --retry-max-time | \
      --max-filesize | --proto | --proto-redir | --max-redirs | --speed-limit | --speed-time | --user-agent) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\t%s\n' "$url" "$auth" >> "$FAKE/calls.log"
case "$url" in
  */v2/*/blobs/*)
    r="${url#*/v2/}"
    blob="$(awk -F '\t' -v r="${r%%/blobs/*}" '$1 == r && !f { print $2 "\t" $3; f = 1 }' "$FAKE/blobs.tsv")"
    ;;
esac
case "$url" in
  */token)
    case "$cred" in
      *'user = '*) printf '{"token":"tok1"}' > "$out" ;;
      *) printf '{"token":"anon"}' > "$out" ;;
    esac
    code=200
    ;;
  */manifests/*)
    line="$(awk -F '\t' -v a="$auth" -v r="${url##*/manifests/}" '$1 == a && ($4 == "" || $4 == r) && !f { print $2 "\t" $3; f = 1 }' "$FAKE/answers.tsv")"
    if [ -z "$line" ]; then
      [ -z "$wo" ] || printf '000'
      exit 7
    fi
    cp "$FAKE/${line#*$'\t'}" "$out"
    code="${line%%$'\t'*}"
    ;;
  *)
    f="${url##*/}"
    f="$FAKE/up/${f#sha256:}"
    if [ -n "$blob" ]; then
      cp "$FAKE/${blob#*$'\t'}" "$out"
      code="${blob%%$'\t'*}"
    elif [ -f "$f.code" ]; then
      printf 'service unavailable\n' > "$out"
      code="$(cat "$f.code")"
    elif [ -f "$f" ]; then
      cp "$f" "$out"
      code=200
    else
      printf 'not found\n' > "$out"
      code=404
    fi
    ;;
esac
[ -z "$wo" ] || printf '%s' "$code"
EOF

cat > "$FAKE/bin/oras" << 'EOF'
#!/usr/bin/env bash
# A stand-in for oras. Logs each call to $FAKE/oras.log. login reads its
# password and succeeds. push and tag: while $FAKE/oras-429 holds a number
# above 0, each call counts it down, prints oras's own words for a 429 and
# exits 1. Otherwise push writes the manifest of its layers (./FILE:TYPE, in
# the current directory), its --artifact-type and its --annotation values to
# $FAKE/pushed.json, a copy of each layer file to $FAKE/pushed/, and copies
# $FAKE/after-push.tsv to $FAKE/answers.tsv when it exists.
printf '%s\n' "$*" >> "$FAKE/oras.log"
case "$1" in
  login)
    cat > /dev/null
    exit 0
    ;;
esac
n=0
if [ -f "$FAKE/oras-429" ]; then
  n="$(cat "$FAKE/oras-429")"
fi
if [ "$n" -gt 0 ]; then
  echo "$((n - 1))" > "$FAKE/oras-429"
  echo "Error: failed to $1: PUT \"https://ghcr.io/v2/it/mirror/x86_64/core/manifests/t\": response status code 429: Too Many Requests" >&2
  exit 1
fi
if [ "$1" = push ]; then
  layers='[]' at='' ann='{}' prev=''
  rm -rf "$FAKE/pushed"
  mkdir -p "$FAKE/pushed"
  for a in "$@"; do
    case "$prev" in
      --artifact-type) at="$a" ;;
      --annotation) ann="$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '. + {($k): $v}' <<< "$ann")" ;;
    esac
    prev="$a"
    case "$a" in
      ./*)
        p="${a%:*}"
        layers="$(jq -c --arg t "${a##*:}" --arg d "sha256:$(sha256sum "$p" | cut -d ' ' -f 1)" \
          --argjson s "$(wc -c < "$p" | tr -d ' ')" --arg n "${p#./}" \
          '. + [{mediaType: $t, digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $n}}]' <<< "$layers")"
        cp "$p" "$FAKE/pushed/${p#./}"
        ;;
    esac
  done
  jq -cn --arg at "$at" --argjson a "$ann" --argjson l "$layers" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $at, layers: $l, annotations: $a}' > "$FAKE/pushed.json"
  if [ -f "$FAKE/after-push.tsv" ]; then
    cp "$FAKE/after-push.tsv" "$FAKE/answers.tsv"
  fi
fi
exit 0
EOF

# The root of stand-ins: install-oras names the stand-in oras, and the
# wrapper serves $FAKE/promoted.db as the database a consumer reads. It
# gives the tags of files as the real wrapper does.
cat > "$FAKE/root/scripts/install-oras" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE/bin/oras"
EOF
cat > "$FAKE/root/client/pacman-oci" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  --tag | --tags) exec "$REAL_WRAPPER" "$@" ;;
esac
cp "$FAKE/promoted.db" "$1"
EOF
export REAL_WRAPPER="$REPO_ROOT/client/pacman-oci"
chmod +x "$FAKE/bin/curl" "$FAKE/bin/oras" "$FAKE/root/scripts/install-oras" "$FAKE/root/client/pacman-oci"

printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' > "$FAKE/unknown.json"
printf 'service unavailable' > "$FAKE/busy.txt"

# shellcheck disable=SC2016 # $repo and $arch are the target file's
printf 'arch = x86_64\nrepo = core\ndb_server = https://up.test/$repo/os/$arch\n' > "$work/targets/x86_64-core.conf"
export TARGETS_DIR="$work/targets"
export MIRROR_NAMESPACE=it/mirror
export MIRROR_REGISTRY=ghcr.io
export MIRROR_REGISTRY_AUTH=token
export MIRROR_REGISTRY_SCHEME=https
export REGISTRY_TOKEN=secret
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_REF GITHUB_REF_NAME GITHUB_RUN_ID GITHUB_RUN_ATTEMPT MIRROR_REPAIR \
  STAGING_TAG INDEX_TAG REGISTRY_TOKEN_CACHE INDEX_STATE

# reset ANSWERS AFTER-PUSH 429S: the registry's answers now and after a push,
# and how many oras calls get a 429 first. No blob has an answer of its own
# ($FAKE/blobs.tsv is empty).
reset() {
  printf '%b' "$1" > "$FAKE/answers.tsv"
  printf '%b' "$2" > "$FAKE/after-push.tsv"
  printf '%s\n' "$3" > "$FAKE/oras-429"
  : > "$FAKE/blobs.tsv"
  : > "$FAKE/calls.log"
  : > "$FAKE/oras.log"
}

#---------------------------------------------------------------------------#
# stage: a plan with nothing new, so stage goes straight to its push
#---------------------------------------------------------------------------#
plan="$work/plan"
mkdir -p "$plan/x86_64-core" "$work/results"
printf 'pending\n' > "$plan/x86_64-core/state"
printf 'test\n' > "$plan/x86_64-core/why"
printf 'p1\n' > "$plan/x86_64-core/plan-id"
: > "$plan/x86_64-core/todo.tsv"
: > "$plan/x86_64-core/new.tsv"
: > "$plan/x86_64-core/vouched.tsv"
printf 'the core database\n' > "$plan/x86_64-core/upstream.db"
printf 'the core files database\n' > "$plan/x86_64-core/upstream.files"
printf 'a-1-1-any.pkg.tar.zst\ta\t1-1\tany\t%s\t10\t1700000000\t\n' "$(printf a | sha256sum | cut -d ' ' -f 1)" > "$plan/x86_64-core/records.tsv"
printf 'ARCH=x86_64\nREPO=core\nUPSTREAM=https://up.test/core/os/x86_64\nPACKAGES=1\nBYTES=10\nNEWEST_BUILDDATE=1700000000\nFETCHED=2026-10-15T00:00:00Z\nPRIVATE=0\n' \
  > "$plan/x86_64-core/meta.env"

# stage_run NAME: scripts/stage into $work/stage-NAME, its stderr in .err
stage_run() {
  local rc=0
  REPO_ROOT="$FAKE/root" PATH="$FAKE/bin:$PATH" "$SCRIPTS/stage" "$plan" "$work/results" "$work/stage-$1" x86_64-core \
    > "$work/stage-$1.out" 2> "$work/stage-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
# anon_reads -> how many manifest reads by digest went out with no credential
anon_reads() {
  awk -F '\t' '$1 ~ /\/manifests\/sha256:/ && $2 == "Bearer QQ==" { n++ } END { print n + 0 }' "$FAKE/calls.log"
}
ST="REPO_ROOT=<stand-ins> scripts/stage PLAN RESULTS OUT x86_64-core"

# The anonymous read answers 503: that says nothing about the package. It is
# asked 5 times, and the target is in error, never private.
reset '' 'Bearer QQ==\t503\tbusy.txt\nBearer tok1\t200\tpushed.json\n' 0
rc="$(stage_run anon503)"
check "stage: an anonymous read that answers 503 is asked 5 times" "0 5" "$rc $(anon_reads)" "$ST; cat $FAKE/calls.log"
case "$(cat "$work/stage-anon503/x86_64-core/state" 2> /dev/null):$(cat "$work/stage-anon503/x86_64-core/why" 2> /dev/null)" in
  error:*'HTTP 503'*) ok "stage: an anonymous read that answers 503 sets error, naming HTTP 503, not private" ;;
  *) fail "stage: an anonymous read that answers 503 sets error, naming HTTP 503, not private" \
    "state: $(cat "$work/stage-anon503/x86_64-core/state" 2> /dev/null) why: $(cat "$work/stage-anon503/x86_64-core/why" 2> /dev/null)" "$ST" ;;
esac

# The registry refuses the anonymous read: private, at once.
reset '' 'Bearer QQ==\t404\tunknown.json\nBearer tok1\t200\tpushed.json\n' 0
rc="$(stage_run anon404)"
check "stage: an anonymous read that the registry refuses sets private, with one read" "0 private 1" \
  "$rc $(cat "$work/stage-anon404/x86_64-core/state" 2> /dev/null) $(anon_reads)" "$ST; cat $work/stage-anon404.err"

# The anonymous read answers: staged. The tag of a holds its bytes, so a is
# the smallest canary.
jq -cn --arg d "sha256:$(printf a | sha256sum | cut -d ' ' -f 1)" \
  '{schemaVersion: 2, layers: [{mediaType: "application/vnd.pkgforge.archlinux.pkg.v1", digest: $d, size: 10, annotations: {"org.opencontainers.image.title": "a-1-1-any.pkg.tar.zst"}}]}' \
  > "$FAKE/tag-a-first.json"
TAG_A='Bearer QQ==\t200\ttag-a-first.json\ta-1-1-any.pkg.tar.zst\n'
reset '' "${TAG_A}Bearer QQ==\t200\tpushed.json\n" 0
rc="$(stage_run anon200)"
check "stage: an anonymous read that answers stages the target" "0 staged" \
  "$rc $(cat "$work/stage-anon200/x86_64-core/state" 2> /dev/null)" "$ST; cat $work/stage-anon200.err"

#---------------------------------------------------------------------------#
# A 429 in oras's own words, three times, then the push goes through. Each
# script pauses, costs no attempt, and goes on. The pauses are 1 s here.
#---------------------------------------------------------------------------#
export RATE_PAUSE_MIN=1 RATE_PAUSE_MAX=1
# pauses FILE -> how many 429 pauses FILE logs
pauses() {
  awk '/the registry limits requests \(429\); a pause of/ { n++ } END { print n + 0 }' "$1"
}
# oras_calls VERB -> how many oras calls of VERB the stand-in saw
oras_calls() {
  awk -v v="$1" '$1 == v { n++ } END { print n + 0 }' "$FAKE/oras.log"
}
# pushes REF -> how many oras pushes to REF (registry/repository:tag) the
# stand-in saw
pushes() {
  awk -v r="$1" '$1 == "push" && index($0, " " r " ") { n++ } END { print n + 0 }' "$FAKE/oras.log"
}

reset '' "${TAG_A}Bearer QQ==\t200\tpushed.json\n" 3
rc="$(stage_run 429)"
check "stage: three 429s on the staging push: three pauses, four pushes of the staging tag, staged" "0 3 4 staged" \
  "$rc $(pauses "$work/stage-429.err") $(pushes ghcr.io/it/mirror/x86_64/core:staging) $(cat "$work/stage-429/x86_64-core/state" 2> /dev/null)" \
  "$ST with an oras that answers 429 three times; cat $work/stage-429.err $FAKE/oras.log"

# promote: a staged snapshot whose one batch passed, and no latest yet
st="$work/promote-stage"
mkdir -p "$st/x86_64-core/batches" "$work/verify"
printf 'the promoted database\n' > "$FAKE/promoted.db"
pdigest="sha256:$(printf 'a staged manifest' | sha256sum | cut -d ' ' -f 1)"
printf 'staged\n' > "$st/x86_64-core/state"
printf 'DIGEST=%s\nTAG=staging\nDB_SHA256=%s\nFILES_SHA256=%s\nFETCHED=2026-10-15T00:00:00Z\nNEWEST_BUILDDATE=1700000000\n' \
  "$pdigest" "$(sha256sum "$FAKE/promoted.db" | cut -d ' ' -f 1)" "$(printf files | sha256sum | cut -d ' ' -f 1)" > "$st/x86_64-core/staged.env"
printf 'a\n' > "$st/x86_64-core/batches/0.txt"
printf 'x86_64-core\t0\tpassed\t1 package(s)\t%s\n' "$pdigest" > "$work/verify/verify-x86_64-core-0.tsv"
# promote_run NAME: scripts/promote, its stderr in $work/promote-NAME.err
promote_run() {
  local rc=0
  rm -f "$st/x86_64-core/promoted.tsv"
  REPO_ROOT="$FAKE/root" PATH="$FAKE/bin:$PATH" "$SCRIPTS/promote" "$st" "$work/verify" x86_64-core \
    > "$work/promote-$1.out" 2> "$work/promote-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
PR="REPO_ROOT=<stand-ins> scripts/promote STAGE VERIFY x86_64-core"
absent='Bearer QQ==\t404\tunknown.json\nBearer tok1\t404\tunknown.json\n'

reset "$absent" '' 3
rc="$(promote_run 429)"
check "promote: three 429s on the first tag: three pauses, seven tag calls, promoted" "0 3 7 promoted" \
  "$rc $(pauses "$work/promote-429.err") $(oras_calls tag) $(cut -f 1 "$st/x86_64-core/promoted.tsv" 2> /dev/null)" \
  "$PR with an oras that answers 429 three times; cat $work/promote-429.err"

reset "$absent" '' 5
rc="$(PROMOTE_RATE_WAIT=1 promote_run cap)"
case "$rc:$(cat "$work/promote-cap.err")" in
  1:*'1s of 429 pauses of at most PROMOTE_RATE_WAIT=1s'*) ok "promote: 429s past PROMOTE_RATE_WAIT fail it, naming the pauses" ;;
  *) fail "promote: 429s past PROMOTE_RATE_WAIT fail it, naming the pauses" "exit $rc" "$(tail -n 5 "$work/promote-cap.err")" "PROMOTE_RATE_WAIT=1 $PR" ;;
esac

# mirror-file: one new file, from a db_server the stand-in serves
pkg='a-1-1-any.pkg.tar.zst'
printf 'the bytes of package a\n' > "$FAKE/up/$pkg"
mf="$work/mirror-file"
mkdir -p "$mf/results" "$mf/work"
printf 'x86_64-core\t%s\t%s\t%s\t%s\ta\tnew\t1700000000\t%s\n' "$pkg" "$("$REPO_ROOT/client/pacman-oci" --tag "$pkg")" \
  "$(sha256sum "$FAKE/up/$pkg" | cut -d ' ' -f 1)" "$(wc -c < "$FAKE/up/$pkg" | tr -d ' ')" "$(printf 'a signature' | base64)" > "$mf/shard.tsv"
reset "$absent" 'Bearer QQ==\t200\tpushed.json\n' 3
rc=0
RESULTS="$mf/results" WORK="$mf/work" ORAS="$FAKE/bin/oras" ORAS_CONFIG="$mf/oras.json" SHARD_INDEX=0 MIRROR_RATE_WAIT=30 \
  PATH="$FAKE/bin:$PATH" "$SCRIPTS/mirror-file" "$mf/shard.tsv" 1 > "$mf/out" 2> "$mf/err" || rc=$?
check "mirror-file: three 429s in oras's words: three pauses, the shard's throttle file, pushed" "0 3 yes pushed" \
  "$rc $(pauses "$mf/err") $([ -s "$mf/work/throttle" ] && echo yes || echo no) $(cut -f 3 "$mf/results/1.tsv" 2> /dev/null)" \
  "RESULTS=R WORK=W ORAS=<stand-in> scripts/mirror-file SHARD 1; cat $mf/err $mf/results/1.tsv"

#---------------------------------------------------------------------------#
# stage: the files to verify are new.tsv (the todo files, and the files the
# index does not name as verified), less the files absent upstream, plus the
# canaries. The accounting reads todo.tsv only. The smallest canary is the
# smallest file whose tag holds its bytes, of the 10 smallest.
#   a       10 bytes  promoted: the smallest
#   b       20 bytes  to verify only (new.tsv, action verify), no result
#   c       30 bytes  todo, pushed
#   d       40 bytes  todo, absent upstream
#   e to l  promoted, larger
#---------------------------------------------------------------------------#
vplan="$work/vplan"
vp="$vplan/x86_64-core"
mkdir -p "$vp" "$work/vresults/0"
cp "$plan/x86_64-core/upstream.db" "$plan/x86_64-core/upstream.files" "$plan/x86_64-core/meta.env" "$vp/"
printf 'pending\n' > "$vp/state"
printf 'test\n' > "$vp/why"
printf 'vp1\n' > "$vp/plan-id"
: > "$vp/records.tsv"
size=0
for n in a b c d e f g h i j k l; do
  size=$((size + 10))
  printf '%s-1-1-any.pkg.tar.zst\t%s\t1-1\tany\t%s\t%s\t1700000000\t\n' "$n" "$n" "$(printf '%s' "$n" | sha256sum | cut -d ' ' -f 1)" "$size" >> "$vp/records.tsv"
done
# wline NAME ACTION -> the work line of NAME (its tag is its filename)
wline() {
  awk -F '\t' -v OFS='\t' -v n="$1" -v a="$2" '$2 == n { print "x86_64-core", $1, $1, $5, $6, $2, a, $7, $8 }' "$vp/records.tsv"
}
{
  wline c todo
  wline d todo
} > "$vp/todo.tsv"
{
  cat "$vp/todo.tsv"
  wline b verify
} > "$vp/new.tsv"
printf 'b-1-1-any.pkg.tar.zst\t0\t0\n' > "$vp/vouched.tsv"
printf 'vp1\n' > "$work/vresults/0/plan-id"
printf 'x86_64-core\tc-1-1-any.pkg.tar.zst\tpushed\t1\tok\nx86_64-core\td-1-1-any.pkg.tar.zst\tabsent\t1\tevery server answered 404\n' \
  > "$work/vresults/0/results.tsv"
# tag_manifest NAME [SHA256]: $FAKE/tag-NAME.json, the manifest of NAME's tag,
# its package layer the record's sha256, or SHA256
tag_manifest() {
  local f sha size
  IFS=$'\t' read -r f _ _ _ sha size _ <<< "$(awk -F '\t' -v n="$1" '$2 == n' "$vp/records.tsv")"
  jq -cn --arg f "$f" --arg d "sha256:${2:-$sha}" --argjson s "$size" \
    '{schemaVersion: 2, layers: [{mediaType: "application/vnd.pkgforge.archlinux.pkg.v1", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $f}}]}' \
    > "$FAKE/tag-$1.json"
}
# vstage_run NAME: scripts/stage of this plan into $work/vstage-NAME
vstage_run() {
  local rc=0
  REPO_ROOT="$FAKE/root" PATH="$FAKE/bin:$PATH" "$SCRIPTS/stage" "$vplan" "$work/vresults" "$work/vstage-$1" x86_64-core \
    > "$work/vstage-$1.out" 2> "$work/vstage-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
# batched NAME -> the state, and the package names of every batch, sorted
batched() {
  printf '%s ' "$(cat "$work/vstage-$1/x86_64-core/state" 2> /dev/null)"
  cat "$work/vstage-$1/x86_64-core/batches/"*.txt | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}
VST="REPO_ROOT=<stand-ins> scripts/stage VPLAN VRESULTS OUT x86_64-core"
tag_manifest a
ans='Bearer QQ==\t200\ttag-a.json\ta-1-1-any.pkg.tar.zst\nBearer QQ==\t200\tpushed.json\n'
reset "$ans" "$ans" 0
rc="$(vstage_run new)"
check "stage: the files to verify are new.tsv less the files absent upstream, and the canary" "0 staged a b c" \
  "$rc $(batched new)" "$VST; cat $work/vstage-new.err; ls $work/vstage-new/x86_64-core/batches"

mv "$vp/new.tsv" "$work/new.tsv.kept"
reset "$ans" "$ans" 0
rc="$(vstage_run nonew)"
mv "$work/new.tsv.kept" "$vp/new.tsv"
check "stage: a plan with no new.tsv verifies its todo files and the canary" "0 staged a c" \
  "$rc $(batched nonew)" "$VST with no new.tsv; cat $work/vstage-nonew.err"

# a has no tag (a promoted file upstream no longer serves), b's tag holds
# other bytes, c's tag holds c: c is the smallest canary.
tag_manifest b 0000000000000000000000000000000000000000000000000000000000000001
tag_manifest c
ans='Bearer QQ==\t404\tunknown.json\ta-1-1-any.pkg.tar.zst\nBearer tok1\t404\tunknown.json\ta-1-1-any.pkg.tar.zst\n'
ans="${ans}Bearer QQ==\t200\ttag-b.json\tb-1-1-any.pkg.tar.zst\nBearer QQ==\t200\ttag-c.json\tc-1-1-any.pkg.tar.zst\nBearer QQ==\t200\tpushed.json\n"
reset "$ans" "$ans" 0
rc="$(vstage_run canary)"
check "stage: the smallest canary is the smallest file whose tag holds its bytes" "0 c" \
  "$rc $(cat "$work/vstage-canary/x86_64-core/canaries.txt" 2> /dev/null)" "$VST; cat $work/vstage-canary.err"

# No tag holds its file: 10 tags are read, smallest first, and then there is
# no smallest canary.
ans='Bearer QQ==\t200\tpushed.json\n'
reset "$ans" "$ans" 0
rc="$(vstage_run nocanary)"
check "stage: no tag holds its file: 10 tags read, no canary, and the rest is verified" "0 10 0 staged b c" \
  "$rc $(awk -F '\t' '$1 ~ /\/manifests\/[a-z]-1-1-any\.pkg\.tar\.zst$/ { r[$1] = 1 } END { n = 0; for (k in r) n++; print n }' "$FAKE/calls.log") $(awk 'END { print NR + 0 }' "$work/vstage-nocanary/x86_64-core/canaries.txt") $(batched nocanary)" \
  "$VST; cat $FAKE/calls.log $work/vstage-nocanary.err"
if grep -q 'there is no smallest canary' "$work/vstage-nocanary.err"; then
  ok "stage: no smallest canary is a warning"
else
  fail "stage: no smallest canary is a warning" "$(cat "$work/vstage-nocanary.err")" "$VST"
fi
check "stage: no canary, and files to verify: batch 0 gets them, as any batch does" "0.txt 2" \
  "$(cd "$work/vstage-nocanary/x86_64-core/batches" 2> /dev/null && ls) $(awk 'END { print NR + 0 }' "$work/vstage-nocanary/x86_64-core/batches/0.txt" 2> /dev/null)" \
  "$VST; ls $work/vstage-nocanary/x86_64-core/batches"

# No canary, and nothing to verify: no batch, and the target is held.
mv "$vp/todo.tsv" "$work/todo.tsv.kept"
mv "$vp/new.tsv" "$work/new.tsv.kept"
: > "$vp/todo.tsv"
: > "$vp/new.tsv"
reset "$ans" "$ans" 0
rc="$(vstage_run empty)"
mv "$work/todo.tsv.kept" "$vp/todo.tsv"
mv "$work/new.tsv.kept" "$vp/new.tsv"
check "stage: no canary and nothing to verify: held, with no batch and no verify job" \
  "0 held|nothing to verify, and no canary tag reads|0|{\"include\":[]}" \
  "$rc $(cat "$work/vstage-empty/x86_64-core/state" 2> /dev/null)|$(cat "$work/vstage-empty/x86_64-core/why" 2> /dev/null)|$(find "$work/vstage-empty/x86_64-core/batches" -name '*.txt' 2> /dev/null | awk 'END { print NR + 0 }')|$(cat "$work/vstage-empty/verify-matrix.json" 2> /dev/null)" \
  "$VST with an empty todo.tsv and new.tsv; cat $work/vstage-empty.err"

#---------------------------------------------------------------------------#
# verify-batch: Docker Hub limits the pull of the verify image. The same
# digest comes from a mirror, the container runs the reference that was
# pulled, and the log names the source and the limit.
#---------------------------------------------------------------------------#
cat > "$FAKE/bin/runtime" << 'EOF'
#!/usr/bin/env bash
# A stand-in for docker or podman.
#   pull  logs the reference (the last argument) to $FAKE/pulls.log. A
#         docker.io reference gets Docker Hub's pull limit while
#         $FAKE/hub-limited exists. A reference under a prefix that a line of
#         $FAKE/mirrors-up names is pulled. Any other fails.
#   run   writes the image (the argument before "bash") to $FAKE/ran. The
#         container passes, or, while $FAKE/run-out exists, prints it and
#         exits with the status in $FAKE/run-rc; first it removes the file
#         that $FAKE/run-rm names, when that exists.
case "$1" in
  pull)
    ref="${!#}"
    printf '%s\n' "$ref" >> "$FAKE/pulls.log"
    case "$ref" in
      docker.io/*)
        if [ -f "$FAKE/hub-limited" ]; then
          echo "Error: initializing source docker://$ref: reading manifest in docker.io/library/archlinux: toomanyrequests: You have reached your unauthenticated pull rate limit. https://www.docker.com/increase-rate-limit" >&2
          exit 125
        fi
        exit 0
        ;;
    esac
    while IFS= read -r p; do
      case "$ref" in
        "$p"/*) exit 0 ;;
      esac
    done < "$FAKE/mirrors-up"
    echo "Error: initializing source docker://$ref: manifest unknown" >&2
    exit 125
    ;;
  run)
    prev=""
    for a in "$@"; do
      if [ "$a" = bash ]; then
        printf '%s\n' "$prev" > "$FAKE/ran"
        break
      fi
      prev="$a"
    done
    if [ -f "$FAKE/run-out" ]; then
      if [ -f "$FAKE/run-rm" ]; then
        rm -f "$(cat "$FAKE/run-rm")"
      fi
      cat "$FAKE/run-out"
      exit "$(cat "$FAKE/run-rc")"
    fi
    echo '@@done'
    exit 0
    ;;
esac
echo "runtime stand-in: $1 is not handled" >&2
exit 2
EOF
chmod +x "$FAKE/bin/runtime"

vdigest="sha256:$(printf 'the verify image' | sha256sum | cut -d ' ' -f 1)"
vimage="docker.io/library/archlinux:base@$vdigest"
# shellcheck disable=SC2016 # $repo and $arch are the target file's
printf 'arch = x86_64\nrepo = vimg\ndb_server = https://up.test/$repo/os/$arch\nverify_image = %s\nverify_platform = linux/amd64\n' \
  "$vimage" > "$work/targets/x86_64-vimg.conf"
mkdir -p "$work/vstage/x86_64-vimg/batches"
printf 'DIGEST=sha256:%s\nFILES_SHA256=%s\n' "$(printf staged | sha256sum | cut -d ' ' -f 1)" "$(printf files | sha256sum | cut -d ' ' -f 1)" \
  > "$work/vstage/x86_64-vimg/staged.env"
printf 'a\n' > "$work/vstage/x86_64-vimg/batches/0.txt"
# verify_run NAME MIRRORS-UP [BATCH]: scripts/verify-batch of BATCH (default
# 0) into $work/verify-NAME
verify_run() {
  local rc=0
  printf '%b' "$2" > "$FAKE/mirrors-up"
  : > "$FAKE/pulls.log"
  rm -f "$FAKE/ran"
  env -u VERIFY_IMAGE_MIRRORS CONTAINER_RUNTIME="$FAKE/bin/runtime" PATH="$FAKE/bin:$PATH" \
    "$SCRIPTS/verify-batch" "$work/vstage" x86_64-vimg "${3:-0}" "$work/verify-$1" \
    > "$work/verify-$1.out" 2> "$work/verify-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
VR="CONTAINER_RUNTIME=<stand-in> scripts/verify-batch STAGE x86_64-vimg 0 OUT"

touch "$FAKE/hub-limited"
rc="$(verify_run hub429 'mirror.gcr.io/library\n')"
check "verify-batch: Docker Hub's pull limit: the digest comes from the first mirror, and the container runs it" \
  "0 mirror.gcr.io/library/archlinux@$vdigest" "$rc $(cat "$FAKE/ran" 2> /dev/null)" "$VR; cat $work/verify-hub429.err"
check "verify-batch: a pull limit is not asked again: one pull from Docker Hub, one from the mirror" \
  "$vimage mirror.gcr.io/library/archlinux@$vdigest" "$(tr '\n' ' ' < "$FAKE/pulls.log" | sed 's/ $//')" "cat $FAKE/pulls.log"
if grep -q "pull: the verify image came from mirror.gcr.io/library/archlinux@$vdigest" "$work/verify-hub429/verify-x86_64-vimg-0.log" &&
  grep -q "pull: $vimage: the registry limits pulls (toomanyrequests)" "$work/verify-hub429/verify-x86_64-vimg-0.log"; then
  ok "verify-batch: the log names the source of the image and the pull limit"
else
  fail "verify-batch: the log names the source of the image and the pull limit" "$(cat "$work/verify-hub429/verify-x86_64-vimg-0.log")" "$VR"
fi
check "verify-batch: the verdict comes from the container" "passed" \
  "$(cut -f 3 "$work/verify-hub429/verify-x86_64-vimg-0.tsv" 2> /dev/null)" "cat $work/verify-hub429/verify-x86_64-vimg-0.tsv"

rc="$(verify_run nosource '')"
case "$rc:$(cut -f 3,4 "$work/verify-nosource/verify-x86_64-vimg-0.tsv" 2> /dev/null)" in
  1:failed*'mirror.gcr.io/library, public.ecr.aws/docker/library'*toomanyrequests*) ok "verify-batch: every source fails: the verdict names the mirrors and toomanyrequests" ;;
  *) fail "verify-batch: every source fails: the verdict names the mirrors and toomanyrequests" "exit $rc" \
    "$(cat "$work/verify-nosource/verify-x86_64-vimg-0.tsv" 2> /dev/null)" "$VR" ;;
esac

rm -f "$FAKE/hub-limited"
rc="$(verify_run hub '')"
check "verify-batch: Docker Hub answers: the container runs the image as the target names it, with one pull" "0 $vimage 1" \
  "$rc $(cat "$FAKE/ran" 2> /dev/null) $(awk 'END { print NR + 0 }' "$FAKE/pulls.log")" "$VR; cat $work/verify-hub.err"
check "verify-batch: a passed batch writes no faults file; a failure that names no file writes an empty one" "absent 0" \
  "$([ -e "$work/verify-hub/faults-x86_64-vimg-0.txt" ] && echo present || echo absent) $(awk 'END { print NR + 0 }' "$work/verify-nosource/faults-x86_64-vimg-0.txt" 2> /dev/null)" \
  "ls $work/verify-hub $work/verify-nosource"

#---------------------------------------------------------------------------#
# verify-batch: the files at fault of a failed batch (faults-TARGET-BATCH.txt)
#   a  @@sigbad: its .sig is not its %PGPSIG%     at fault
#   b  refused, and its tag does not read         at fault
#   c  refused, and the mirror serves upstream's bytes (upstream-refused)
#---------------------------------------------------------------------------#
vs="$work/vstage/x86_64-vimg"
: > "$vs/records.tsv"
size=0
for n in a b c; do
  size=$((size + 10))
  printf '%s-1-1-any.pkg.tar.zst\t%s\t1-1\tany\t%s\t%s\t1700000000\t\n' "$n" "$n" "$(printf 'v%s' "$n" | sha256sum | cut -d ' ' -f 1)" "$size" >> "$vs/records.tsv"
done
printf 'a\nb\nc\n' > "$vs/batches/1.txt"
jq -cn --arg d "sha256:$(printf 'vc' | sha256sum | cut -d ' ' -f 1)" \
  '{schemaVersion: 2, layers: [{mediaType: "application/vnd.pkgforge.archlinux.pkg.v1", digest: $d, size: 30, annotations: {"org.opencontainers.image.title": "c-1-1-any.pkg.tar.zst"}}]}' \
  > "$FAKE/vtag-c.json"
reset 'Bearer QQ==\t200\tvtag-c.json\tc-1-1-any.pkg.tar.zst\n' '' 0
printf '@@sigbad\ta-1-1-any.pkg.tar.zst\tits .sig is sha256 1, its %%PGPSIG%% decodes to sha256 2\n@@refused\tb\n@@refused\tc\n@@done\n' > "$FAKE/run-out"
printf '1\n' > "$FAKE/run-rc"
rc="$(verify_run faults '' 1)"
VF="CONTAINER_RUNTIME=<stand-in> scripts/verify-batch STAGE x86_64-vimg 1 OUT"
check "verify-batch: a failed batch names its files at fault: the @@sigbad file and the refused one, not the upstream-refused one" \
  "1 failed a-1-1-any.pkg.tar.zst b-1-1-any.pkg.tar.zst" \
  "$rc $(cut -f 3 "$work/verify-faults/verify-x86_64-vimg-1.tsv" 2> /dev/null) $(tr '\n' ' ' < "$work/verify-faults/faults-x86_64-vimg-1.txt" 2> /dev/null | sed 's/ $//')" \
  "$VF; cat $work/verify-faults.err $work/verify-faults/verify-x86_64-vimg-1.tsv"

# The step ends before a verdict (here the batch file goes during the
# container): the EXIT trap writes the verdict and the files at fault so far.
printf '@@refused\tb\n' > "$FAKE/run-out"
printf '%s\n' "$vs/batches/1.txt" > "$FAKE/run-rm"
rc="$(verify_run trapped '' 1)"
printf 'a\nb\nc\n' > "$vs/batches/1.txt"
rm -f "$FAKE/run-out" "$FAKE/run-rm" "$FAKE/run-rc"
case "$rc:$(cut -f 3,4 "$work/verify-trapped/verify-x86_64-vimg-1.tsv" 2> /dev/null):$(tr '\n' ' ' < "$work/verify-trapped/faults-x86_64-vimg-1.txt" 2> /dev/null)" in
  [1-9]*:failed*'before reaching a verdict; at fault so far: b':'b-1-1-any.pkg.tar.zst ') ok "verify-batch: the EXIT trap writes the files at fault so far" ;;
  *) fail "verify-batch: the EXIT trap writes the files at fault so far" "exit $rc" \
    "$(cat "$work/verify-trapped/verify-x86_64-vimg-1.tsv" 2> /dev/null)" "$(cat "$work/verify-trapped/faults-x86_64-vimg-1.txt" 2> /dev/null)" \
    "$VF; cat $work/verify-trapped.err" ;;
esac

#---------------------------------------------------------------------------#
# index-write: the rows of a run, the verify credit, and the writer guard
#   n1  vouched, verified                                   m 1 0
#   n2  vouched, not verified; batch 0 passed               m 1 0
#   n3  todo, pushed; batch 0 passed                        m 1 0
#   n4  todo, pushed; batch 1 failed with n4 at fault       no row
#   n5  todo, absent upstream                               a 0 0
#   n6  todo, no result (pushed in another plan's results)  no row
#   n7  todo, present unsigned; batch 1 failed, not at fault  m 0 1
#   n8  vouched, not verified; batch 2 has no verdict       m 0 0
#   n9  todo, failed                                        no row
#---------------------------------------------------------------------------#
ip="$work/iplan/x86_64-core"
is="$work/istage/x86_64-core"
mkdir -p "$ip" "$is/batches" "$work/iresults/0" "$work/iresults/1" "$work/iverify/v0" "$work/iverify/v1"
printf 'pending\n' > "$ip/state"
printf 'test\n' > "$ip/why"
printf 'ip1\n' > "$ip/plan-id"
printf 'the core database of the index\n' > "$ip/upstream.db"
: > "$ip/records.tsv"
for n in 1 2 3 4 5 6 7 8 9; do
  printf 'n%s-1-1-any.pkg.tar.zst\tn%s\t1-1\tany\t%s\t%s\t1700000000\t\n' "$n" "$n" "$(printf 'n%s' "$n" | sha256sum | cut -d ' ' -f 1)" "$((n * 100))" >> "$ip/records.tsv"
done
for n in 3 4 5 6 7 9; do
  awk -F '\t' -v OFS='\t' -v n="n$n" '$2 == n { print "x86_64-core", $1, $1, $5, $6, $2, "todo", $7, $8 }' "$ip/records.tsv"
done > "$ip/todo.tsv"
printf 'n1-1-1-any.pkg.tar.zst\t1\t0\nn2-1-1-any.pkg.tar.zst\t0\t0\nn8-1-1-any.pkg.tar.zst\t0\t0\n' > "$ip/vouched.tsv"
ICTX="$(printf 'a verify context' | sha256sum | cut -d ' ' -f 1)"
# imeta STATE DIGEST [PRIOR]: the plan's meta.env, with that INDEX_STATE,
# INDEX_DIGEST and INDEX_PRIOR. VERIFY_CONTEXT is $IVC when it is set, else
# ICTX.
imeta() {
  printf 'TARGET=x86_64-core\nFETCHED=2026-10-15T00:00:00Z\nINDEX_TAG=index\nINDEX_STATE=%s\nINDEX_DIGEST=%s\nINDEX_PRIOR=%s\nINDEX_CONTEXT=%s\nVERIFY_CONTEXT=%s\nINDEX_CONTEXT_OUT=%s\n' \
    "$1" "$2" "${3:-}" "$ICTX" "${IVC-$ICTX}" "$ICTX" > "$ip/meta.env"
}
printf 'ip1\n' > "$work/iresults/0/plan-id"
{
  printf 'x86_64-core\tn3-1-1-any.pkg.tar.zst\tpushed\t1\tok\n'
  printf 'x86_64-core\tn4-1-1-any.pkg.tar.zst\tpushed\t1\tok\n'
  printf 'x86_64-core\tn5-1-1-any.pkg.tar.zst\tabsent\t1\tevery server answered 404\n'
  printf 'x86_64-core\tn7-1-1-any.pkg.tar.zst\tpresent\t1\tunsigned: no server has its .sig\n'
  printf 'x86_64-core\tn9-1-1-any.pkg.tar.zst\tfailed\t1\tupstream answered 503\n'
} > "$work/iresults/0/results.tsv"
printf 'ip0\n' > "$work/iresults/1/plan-id"
printf 'x86_64-core\tn6-1-1-any.pkg.tar.zst\tpushed\t1\tok\n' > "$work/iresults/1/results.tsv"
printf 'staged\n' > "$is/state"
printf 'ip1\n' > "$is/plan-id"
sdigest="sha256:$(printf 'the staged manifest of the index run' | sha256sum | cut -d ' ' -f 1)"
printf 'DIGEST=%s\nTAG=staging\n' "$sdigest" > "$is/staged.env"
cp "$ip/records.tsv" "$is/records.tsv"
printf 'n2\nn3\n' > "$is/batches/0.txt"
printf 'n4\nn7\n' > "$is/batches/1.txt"
printf 'n8\n' > "$is/batches/2.txt"
printf 'x86_64-core\t0\tpassed\t2 package(s)\t%s\n' "$sdigest" > "$work/iverify/v0/verify-x86_64-core-0.tsv"
printf 'x86_64-core\t1\tfailed\tthe batch failed its checks\t%s\n' "$sdigest" > "$work/iverify/v1/verify-x86_64-core-1.tsv"
printf 'n4-1-1-any.pkg.tar.zst\n' > "$work/iverify/v1/faults-x86_64-core-1.txt"
# live_index NAME PLAN-ID [ROWS [WITHDRAWN-BY]]: $FAKE/live-NAME.json, an
# index manifest of that plan; with ROWS, an index.tsv layer that $FAKE/up
# serves; with WITHDRAWN-BY, the plan that withdrew rows from it
live_index() {
  local layers='[]' sha
  if [ -n "${3:-}" ]; then
    sha="$(sha256sum "$3" | cut -d ' ' -f 1)"
    cp "$3" "$FAKE/up/$sha"
    layers="$(jq -cn --arg d "sha256:$sha" --argjson s "$(wc -c < "$3" | tr -d ' ')" \
      '[{mediaType: "application/vnd.pkgforge.archlinux.index.v1+tsv", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": "index.tsv"}}]')"
  fi
  jq -cn --arg p "$2" --argjson l "$layers" --arg w "${4:-}" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: "application/vnd.pkgforge.archlinux.index.v1", layers: $l,
      annotations: ({"dev.pkgforge.mirror.index-format": "1", "dev.pkgforge.mirror.plan-id": $p}
        + (if $w == "" then {} else {"dev.pkgforge.mirror.withdrawn-by": $w} end))}' > "$FAKE/live-$1.json"
}
live_index older older.1.1
live_index newer newer.1.1
LIVE_OLDER="sha256:$(sha256sum "$FAKE/live-older.json" | cut -d ' ' -f 1)"
LIVE_NEWER="sha256:$(sha256sum "$FAKE/live-newer.json" | cut -d ' ' -f 1)"
INDEX_REF=ghcr.io/it/mirror/x86_64/core:index
# iw_run NAME: scripts/index-write, its stderr in $work/iw-NAME.err
iw_run() {
  local rc=0
  rm -rf "$FAKE/pushed" "$FAKE/pushed.json"
  REPO_ROOT="$FAKE/root" PATH="$FAKE/bin:$PATH" "$SCRIPTS/index-write" "$work/iplan" "$work/iresults" "$work/istage" "$work/iverify" x86_64-core \
    > "$work/iw-$1.out" 2> "$work/iw-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
# rows -> the rows pushed, "name state verified unsigned|" each
rows() {
  awk -F '\t' '{ n = $1; sub(/-1-1-any\.pkg\.tar\.zst$/, "", n); printf "%s %s %s %s|", n, $2, $3, $4 }' "$FAKE/pushed/index.tsv" 2> /dev/null
}
# kept NAME -> 0 when the log of the run says the live tag is kept
kept() {
  grep -q "index is kept, and this run's rows are not pushed" "$work/iw-$1.err"
}
IW="REPO_ROOT=<stand-ins> scripts/index-write PLAN RESULTS STAGE VERIFY x86_64-core"

# a: the live index is the one plan read
imeta ok "$LIVE_OLDER"
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run rows)"
check "index-write: the live index is the one plan read: one push of the index" "0 1" "$rc $(pushes "$INDEX_REF")" "$IW; cat $work/iw-rows.err"
check "index-write: the rows: the vouched files, the files pushed or present, the files absent upstream; no other plan's result" \
  "n1 m|n2 m|n3 m|n5 a|n7 m|n8 m|" "$(rows | awk -v RS='|' 'NF { printf "%s %s|", $1, $2 }')" "$IW; cat $FAKE/pushed/index.tsv"
check "index-write: verify credit: the files of a passed batch get verified 1; unsigned comes from the result" \
  "n1 m 1 0|n2 m 1 0|n3 m 1 0|n5 a 0 0|n7 m 0 1|n8 m 0 0|" "$(rows)" "$IW; cat $FAKE/pushed/index.tsv"
check "index-write: the artifact type, the layers and the annotations" \
  "application/vnd.pkgforge.archlinux.index.v1 ref.db index.tsv 1 ip1 2026-10-15T00:00:00Z $(sha256sum "$ip/upstream.db" | cut -d ' ' -f 1) $ICTX local" \
  "$(jq -r '[.artifactType, (.layers[].annotations["org.opencontainers.image.title"]), .annotations["dev.pkgforge.mirror.index-format"], .annotations["dev.pkgforge.mirror.plan-id"], .annotations["dev.pkgforge.mirror.fetched"], .annotations["dev.pkgforge.mirror.db-sha256"], .annotations["dev.pkgforge.mirror.verify-context"], .annotations["dev.pkgforge.mirror.run"]] | join(" ")' "$FAKE/pushed.json" 2> /dev/null)" \
  "jq . $FAKE/pushed.json"

# A stage of another plan gives no credit and removes nothing.
printf 'ip0\n' > "$is/plan-id"
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run nocredit)"
printf 'ip1\n' > "$is/plan-id"
check "index-write: a stage of another plan gives no verify credit and removes no file at fault" \
  "0 n1 m 1 0|n2 m 0 0|n3 m 0 0|n4 m 0 0|n5 a 0 0|n7 m 0 1|n8 m 0 0|" "$rc $(rows)" "$IW; cat $work/iw-nocredit.err"

# Verdicts about another staged digest, as an earlier attempt leaves them:
# no credit, and nothing removed.
printf 'DIGEST=sha256:%s\nTAG=staging\n' "$(printf 'another staged manifest' | sha256sum | cut -d ' ' -f 1)" > "$is/staged.env"
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run otherdigest)"
printf 'DIGEST=%s\nTAG=staging\n' "$sdigest" > "$is/staged.env"
check "index-write: verdicts about another staged digest give no verify credit and remove no file at fault" \
  "0 n1 m 1 0|n2 m 0 0|n3 m 0 0|n4 m 0 0|n5 a 0 0|n7 m 0 1|n8 m 0 0|" "$rc $(rows)" "$IW; cat $work/iw-otherdigest.err"

# The plan did not know the verify context (VERIFY_CONTEXT empty): a batch
# that passed gives no verified 1, and each row keeps its carried flag. The
# file at fault still loses its row.
IVC='' imeta ok "$LIVE_OLDER"
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run noctx)"
imeta ok "$LIVE_OLDER"
check "index-write: with no verify context, a passed batch gives no verified 1; the carried flags stay" \
  "0 n1 m 1 0|n2 m 0 0|n3 m 0 0|n5 a 0 0|n7 m 0 1|n8 m 0 0|" "$rc $(rows)" "$IW with VERIFY_CONTEXT empty; cat $work/iw-noctx.err"

# Another index is live: kept.
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run newer)"
if [ "$rc" = 0 ] && [ "$(pushes "$INDEX_REF")" = 0 ] && kept newer; then
  ok "index-write: a live index that is not the one plan read is kept, with a warning"
else
  fail "index-write: a live index that is not the one plan read is kept, with a warning" "exit $rc, $(pushes "$INDEX_REF") push(es)" \
    "$(cat "$work/iw-newer.err")" "$IW"
fi

# The live tag does not read: kept.
reset '' '' 0
rc="$(iw_run noanswer)"
check "index-write: a live tag that does not read is kept" "0 0 yes" \
  "$rc $(pushes "$INDEX_REF") $(kept noanswer && echo yes || echo no)" "$IW; cat $work/iw-noanswer.err"

# An earlier attempt of this plan wrote the live index: replaced, and its
# verified 1 stays.
printf 'n4-1-1-any.pkg.tar.zst\tm\t1\t0\nn7-1-1-any.pkg.tar.zst\tm\t1\t1\n' > "$work/ours-rows.tsv"
live_index ours ip1 "$work/ours-rows.tsv"
reset 'Bearer QQ==\t200\tlive-ours.json\tindex\n' '' 0
rc="$(iw_run ours)"
check "index-write: a live index of this plan is replaced, and keeps its verified 1 for the same file" \
  "0 1 n1 m 1 0|n2 m 1 0|n3 m 1 0|n5 a 0 0|n7 m 1 1|n8 m 0 0|" "$rc $(pushes "$INDEX_REF") $(rows)" "$IW; cat $work/iw-ours.err"

# The live index names this plan, and another plan withdrew rows from it
# since: it is not this plan's own. Kept.
live_index oursw ip1 "$work/ours-rows.tsv" newer.1.1
reset 'Bearer QQ==\t200\tlive-oursw.json\tindex\n' '' 0
rc="$(iw_run oursw)"
check "index-write: a live index of this plan that another plan withdrew rows from is kept" "0 0 yes" \
  "$rc $(pushes "$INDEX_REF") $(kept oursw && echo yes || echo no)" "$IW; cat $work/iw-oursw.err"
# withdrawn-by names this plan: still this plan's own.
live_index oursself ip1 "$work/ours-rows.tsv" ip1
reset 'Bearer QQ==\t200\tlive-oursself.json\tindex\n' '' 0
rc="$(iw_run oursself)"
check "index-write: a live index of this plan, withdrawn by this plan, is replaced and keeps its verified 1" \
  "0 1 n1 m 1 0|n2 m 1 0|n3 m 1 0|n5 a 0 0|n7 m 1 1|n8 m 0 0|" "$rc $(pushes "$INDEX_REF") $(rows)" "$IW; cat $work/iw-oursself.err"

# Plan did not read the index: nothing is read or pushed.
imeta unread ''
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run unread)"
check "index-write: an index plan did not read is not read or written" "0 0 0" \
  "$rc $(pushes "$INDEX_REF") $(awk -F '\t' '$1 ~ /\/manifests\/index$/ { n++ } END { print n + 0 }' "$FAKE/calls.log")" \
  "$IW; cat $work/iw-unread.err"

# Plan found no index: written while there is none, kept once there is one.
imeta absent ''
reset 'Bearer QQ==\t404\tunknown.json\tindex\nBearer tok1\t404\tunknown.json\tindex\n' '' 0
rc="$(iw_run absent)"
check "index-write: no index, as plan found: written" "0 1" "$rc $(pushes "$INDEX_REF")" "$IW; cat $work/iw-absent.err"
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run absentnow)"
check "index-write: plan found no index, and one is live now: kept" "0 0 yes" \
  "$rc $(pushes "$INDEX_REF") $(kept absentnow && echo yes || echo no)" "$IW; cat $work/iw-absentnow.err"

# INDEX_READ=0, a reset: the new index replaces the one plan saw, and no
# other. With no answer to plan's read of the tag, nothing is pushed.
imeta ignored "$LIVE_NEWER"
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run ignored)"
check "index-write: a reset replaces the index plan saw" "0 1" "$rc $(pushes "$INDEX_REF")" "$IW; cat $work/iw-ignored.err"
imeta ignored "$LIVE_OLDER"
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run ignorednewer)"
check "index-write: a reset keeps an index that a newer run wrote after plan saw another" "0 0 yes" \
  "$rc $(pushes "$INDEX_REF") $(kept ignorednewer && echo yes || echo no)" "$IW; cat $work/iw-ignorednewer.err"
imeta ignored '' absent
reset 'Bearer QQ==\t404\tunknown.json\tindex\nBearer tok1\t404\tunknown.json\tindex\n' '' 0
rc="$(iw_run ignoredabsent)"
check "index-write: a reset where plan saw no tag, and there is none: written" "0 1" "$rc $(pushes "$INDEX_REF")" "$IW; cat $work/iw-ignoredabsent.err"
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run ignoredabsentnow)"
check "index-write: a reset where plan saw no tag, and one is live now: kept" "0 0 yes" \
  "$rc $(pushes "$INDEX_REF") $(kept ignoredabsentnow && echo yes || echo no)" "$IW; cat $work/iw-ignoredabsentnow.err"
imeta ignored ''
reset 'Bearer QQ==\t200\tlive-newer.json\tindex\n' '' 0
rc="$(iw_run ignorednoanswer)"
case "$rc $(pushes "$INDEX_REF"):$(cat "$work/iw-ignorednoanswer.err")" in
  "0 0:"*"is not written: the plan's read of the tag gave no answer (INDEX_STATE ignored)"*"the reset can be run again"*) ok "index-write: a reset whose read of the tag got no answer writes nothing, and says the reset can be run again" ;;
  *) fail "index-write: a reset whose read of the tag got no answer writes nothing, and says the reset can be run again" \
    "exit $rc, $(pushes "$INDEX_REF") push(es)" "$(cat "$work/iw-ignorednoanswer.err")" "$IW" ;;
esac

# A target the plan did not mark pending has no index to write.
imeta ok "$LIVE_OLDER"
printf 'held\n' > "$ip/state"
reset 'Bearer QQ==\t200\tlive-older.json\tindex\n' '' 0
rc="$(iw_run held)"
printf 'pending\n' > "$ip/state"
check "index-write: a target that is not pending: nothing read or written" "0 0 0" \
  "$rc $(pushes "$INDEX_REF") $(awk 'END { print NR + 0 }' "$FAKE/calls.log")" "$IW; cat $work/iw-held.err"

#---------------------------------------------------------------------------#
# lib.sh index_guard, the re-run guard of mirror-shard: the live index of the
# plan's meta.env (TARGET, INDEX_TAG), read once. Its m rows are listed in
# WORK/index-listed.txt; when it does not read, WORK/index-unread says why.
#---------------------------------------------------------------------------#
gp="$work/gplan/x86_64-core"
mkdir -p "$gp"
printf 'TARGET=x86_64-core\nINDEX_TAG=index\n' > "$gp/meta.env"
printf 'c-1-1-any.pkg.tar.zst\tm\t0\t1\nd-1-1-any.pkg.tar.zst\ta\t0\t0\nb-1-1-any.pkg.tar.zst\tm\t1\t0\n' > "$work/guard-rows.tsv"
live_index guard p9 "$work/guard-rows.tsv"
GUARD_ROWS="$(sha256sum "$work/guard-rows.tsv" | cut -d ' ' -f 1)"
# guard_run NAME: index_guard of the plan, with the work directory
# $work/guard-NAME, called in an if, as mirror-shard calls it
guard_run() {
  local rc=0
  rm -rf "$work/guard-$1"
  mkdir -p "$work/guard-$1"
  PATH="$FAKE/bin:$PATH" bash -c 'set -euo pipefail; . "$1"; if index_guard "$2" "$3"; then exit 0; fi; exit 1' \
    _ "$SCRIPTS/lib.sh" "$gp" "$work/guard-$1" > "$work/guard-$1.out" 2> "$work/guard-$1.err" || rc=$?
  printf '%s\n' "$rc"
}
# guard_out NAME -> "listed:" and the files listed, or "unread:" and why
guard_out() {
  if [ -f "$work/guard-$1/index-listed.txt" ]; then
    printf 'listed:%s\n' "$(tr '\n' ' ' < "$work/guard-$1/index-listed.txt" | sed 's/ $//')"
  else
    printf 'unread:%s\n' "$(cat "$work/guard-$1/index-unread" 2> /dev/null)"
  fi
}
# index_reads -> how many reads of the manifest index the stand-in saw
index_reads() {
  awk -F '\t' '$1 ~ /\/manifests\/index$/ { n++ } END { print n + 0 }' "$FAKE/calls.log"
}
GR="PATH=<stand-ins>:\$PATH bash -c '. scripts/lib.sh; index_guard PLAN/x86_64-core WORK'"

reset 'Bearer QQ==\t200\tlive-guard.json\tindex\n' '' 0
rc="$(guard_run listed)"
check "index_guard: one read of the live index lists its m rows, sorted, and no a row" \
  "0 1 listed:b-1-1-any.pkg.tar.zst c-1-1-any.pkg.tar.zst" "$rc $(index_reads) $(guard_out listed)" "$GR; cat $work/guard-listed.err"

reset "$absent" '' 0
rc="$(guard_run absent)"
check "index_guard: no index tag lists no file" "0 listed:" "$rc $(guard_out absent)" "$GR; cat $work/guard-absent.err"

reset 'Bearer QQ==\t503\tbusy.txt\tindex\nBearer tok1\t503\tbusy.txt\tindex\n' '' 0
rc="$(guard_run busy)"
case "$rc $(awk -F '\t' '$1 ~ /\/manifests\/index$/ && $2 == "Bearer tok1" { n++ } END { print n + 0 }' "$FAKE/calls.log") $(guard_out busy)" in
  "1 3 unread:it/mirror/x86_64/core:index did not read in 3 tries (HTTP 503)") ok "index_guard: a live index that answers 503 is asked 3 times, and is unread" ;;
  *) fail "index_guard: a live index that answers 503 is asked 3 times, and is unread" "got: exit $rc, $(guard_out busy)" "$GR; cat $work/guard-busy.err" ;;
esac

reset 'Bearer QQ==\t200\tlive-guard.json\tindex\n' '' 0
printf 'it/mirror/x86_64/core\t503\tbusy.txt\n' > "$FAKE/blobs.tsv"
rc="$(guard_run noblob)"
case "$rc:$(guard_out noblob)" in
  "1:unread:the index.tsv of it/mirror/x86_64/core:index (sha256:$GUARD_ROWS) did not read in 3 tries") ok "index_guard: an index.tsv that does not read is unread" ;;
  *) fail "index_guard: an index.tsv that does not read is unread" "got: exit $rc, $(guard_out noblob)" "$GR; cat $work/guard-noblob.err" ;;
esac

jq -c '.artifactType = "application/vnd.pkgforge.archlinux.package.v1"' "$FAKE/live-guard.json" > "$FAKE/live-notindex.json"
reset 'Bearer QQ==\t200\tlive-notindex.json\tindex\n' '' 0
rc="$(guard_run notindex)"
check "index_guard: a live tag that is not an index of format 1 is unread" \
  "1 unread:it/mirror/x86_64/core:index is not an index of format 1" "$rc $(guard_out notindex)" "$GR; cat $work/guard-notindex.err"

printf 'TARGET=x86_64-core\nINDEX_TAG=latest\n' > "$gp/meta.env"
reset 'Bearer QQ==\t200\tlive-guard.json\n' '' 0
rc="$(guard_run badtag)"
check "index_guard: an INDEX_TAG that is not index or index-<slug> is unread, with no read" \
  "1 0 unread:$gp/meta.env: INDEX_TAG is 'latest', not index or index-<slug>" \
  "$rc $(awk 'END { print NR + 0 }' "$FAKE/calls.log") $(guard_out badtag)" "$GR; cat $work/guard-badtag.err"

printf 'TARGET=../x86_64-core\nINDEX_TAG=index\n' > "$gp/meta.env"
reset 'Bearer QQ==\t200\tlive-guard.json\n' '' 0
rc="$(guard_run badtarget)"
printf 'TARGET=x86_64-core\nINDEX_TAG=index\n' > "$gp/meta.env"
check "index_guard: a TARGET that is not a target name is unread, with no read" \
  "1 0 unread:$gp/meta.env: TARGET '../x86_64-core' names no target file in $TARGETS_DIR" \
  "$rc $(awk 'END { print NR + 0 }' "$FAKE/calls.log") $(guard_out badtarget)" "$GR; cat $work/guard-badtarget.err"

#---------------------------------------------------------------------------#
# mirror-file: where the package bytes come from, MIRROR_REPAIR=0, and the
# re-run guard. The shard is PLAN/x86_64-core/shards/0.tsv, so the sources
# plan names are in PLAN/x86_64-core/sources.tsv.
#   line 1  b  upstream serves it
#   line 2  c  upstream serves it
#   line 3  d  upstream answers 404
# The repositories: the target's own (OWN), and two siblings (SIB1, SIB2).
#---------------------------------------------------------------------------#
mp="$work/mplan/x86_64-core"
mkdir -p "$mp/shards"
for n in b c d; do
  printf 'the bytes of package %s\n' "$n" > "$FAKE/blob-$n"
  printf 'x86_64-core\t%s\t%s\t%s\t%s\t%s\tnew\t1700000000\t%s\n' "$n-1-1-any.pkg.tar.zst" \
    "$("$REPO_ROOT/client/pacman-oci" --tag "$n-1-1-any.pkg.tar.zst")" "$(sha256sum "$FAKE/blob-$n" | cut -d ' ' -f 1)" \
    "$(wc -c < "$FAKE/blob-$n" | tr -d ' ')" "$n" "$(printf 'the signature of %s' "$n" | base64)"
done > "$mp/shards/0.tsv"
cp "$FAKE/blob-b" "$FAKE/up/b-1-1-any.pkg.tar.zst"
cp "$FAKE/blob-c" "$FAKE/up/c-1-1-any.pkg.tar.zst"
# The size of b, and other bytes
printf 'the bytes of package B\n' > "$FAKE/blob-other"
printf '{"errors":[{"code":"BLOB_UNKNOWN"}]}' > "$FAKE/blob-unknown.json"
printf '{"errors":[{"code":"TOOMANYREQUESTS"}]}' > "$FAKE/limited.json"
# b's tag with its package layer and no signature layer: a repush
jq -cn --arg d "sha256:$(sha256sum "$FAKE/blob-b" | cut -d ' ' -f 1)" --argjson s "$(wc -c < "$FAKE/blob-b" | tr -d ' ')" \
  '{schemaVersion: 2, layers: [{mediaType: "application/vnd.pkgforge.archlinux.pkg.v1", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": "b-1-1-any.pkg.tar.zst"}}]}' \
  > "$FAKE/tag-b-nosig.json"
OWN=it/mirror/x86_64/core
SIB1=it/mirror/sib/one
SIB2=it/mirror/sib/two
REF_B="ghcr.io/$OWN:$("$REPO_ROOT/client/pacman-oci" --tag b-1-1-any.pkg.tar.zst)"
UP=https://up.test/core/os/x86_64
after='Bearer QQ==\t200\tpushed.json\n'
# mf_run NAME LINE [VAR=VALUE ...]: scripts/mirror-file of LINE of the shard,
# with the work directory $work/mf-NAME/work. Two runs of one NAME share it,
# as two files of one shard do. Its stderr is added to $work/mf-NAME.err.
mf_run() {
  local name="$1" line="$2" rc=0
  shift 2
  mkdir -p "$work/mf-$name/results" "$work/mf-$name/work"
  env "$@" RESULTS="$work/mf-$name/results" WORK="$work/mf-$name/work" ORAS="$FAKE/bin/oras" ORAS_CONFIG="$work/mf-$name/oras.json" \
    SHARD_INDEX=0 MIRROR_RATE_WAIT=30 PATH="$FAKE/bin:$PATH" "$SCRIPTS/mirror-file" "$mp/shards/0.tsv" "$line" \
    > "$work/mf-$name.out" 2>> "$work/mf-$name.err" || rc=$?
  printf '%s\n' "$rc"
}
# mf_result NAME LINE -> the status of the result, and its detail up to the
# first comma or semicolon
mf_result() {
  awk -F '\t' '{ d = $5; sub(/[,;].*/, "", d); print $3, d }' "$work/mf-$1/results/$2.tsv" 2> /dev/null
}
# up_gets -> how many requests went to the upstream server
up_gets() {
  awk -F '\t' -v u="$UP/" 'index($1, u) == 1 { n++ } END { print n + 0 }' "$FAKE/calls.log"
}
# blob_gets [REPO] -> how many blob reads went to REPO, or to any repository
blob_gets() {
  awk -F '\t' -v r="/v2/${1:-}" 'index($1, r) && index($1, "/blobs/") { n++ } END { print n + 0 }' "$FAKE/calls.log"
}
# down REPO NAME -> yes when the work directory of NAME marks REPO down
down() {
  if [ -e "$work/mf-$2/work/down/r-$(printf '%s' "$1" | tr '/' '_')" ]; then echo yes; else echo no; fi
}
# names REPO NAME -> how many lines of the stderr of NAME name REPO
names() {
  awk -v r="$1" 'index($0, r) { n++ } END { print n + 0 }' "$work/mf-$2.err"
}
MF="RESULTS=R WORK=W ORAS=<stand-in> PATH=<stand-ins>:\$PATH scripts/mirror-file PLAN/x86_64-core/shards/0.tsv"

# A repush: the target's own repository holds the package blob. The plan
# read the index (INDEX_STATE ok).
: > "$mp/sources.tsv"
reset 'Bearer QQ==\t200\ttag-b-nosig.json\n' "$after" 0
printf '%s\t200\tblob-b\n' "$OWN" > "$FAKE/blobs.tsv"
rc="$(mf_run own 1 INDEX_STATE=ok)"
check "mirror-file: a repush reads the package from the target's own repository, with no upstream request" \
  "0 pushed from ghcr.io/$OWN 0 1" "$rc $(mf_result own 1) $(up_gets) $(pushes "$REF_B")" "INDEX_STATE=ok $MF 1; cat $work/mf-own.err $FAKE/calls.log"

# The repush rule: a repush only after a plan that read the index. absent and
# invalid allow it, as ok does above.
for s in absent invalid; do
  reset 'Bearer QQ==\t200\ttag-b-nosig.json\n' "$after" 0
  printf '%s\t200\tblob-b\n' "$OWN" > "$FAKE/blobs.tsv"
  rc="$(mf_run "state-$s" 1 INDEX_STATE="$s")"
  check "mirror-file: INDEX_STATE $s allows a repush" "0 pushed from ghcr.io/$OWN 1" \
    "$rc $(mf_result "state-$s" 1) $(pushes "$REF_B")" "INDEX_STATE=$s $MF 1; cat $work/mf-state-$s.err"
done
# unread, ignored and no INDEX_STATE at all (unknown): failed, with no push,
# no blob read and no upstream request.
for s in unread ignored unknown; do
  st=()
  if [ "$s" != unknown ]; then
    st=("INDEX_STATE=$s")
  fi
  reset 'Bearer QQ==\t200\ttag-b-nosig.json\n' "$after" 0
  printf '%s\t200\tblob-b\n' "$OWN" > "$FAKE/blobs.tsv"
  rc="$(mf_run "state-$s" 1 "${st[@]}")"
  check "mirror-file: INDEX_STATE $s refuses a repush: failed, with no push, no blob read and no upstream request" \
    "1 failed a signature repair waits for a run that read the index (INDEX_STATE $s) 0 0 0" \
    "$rc $(mf_result "state-$s" 1) $(pushes "$REF_B") $(blob_gets) $(up_gets)" "${st[*]:-env -u INDEX_STATE} $MF 1; cat $work/mf-state-$s.err"
done

# A push: the sibling plan names holds the package. MIRROR_REPAIR=0 is for a
# repush only.
printf 'b-1-1-any.pkg.tar.zst\t%s\n' "$SIB1" > "$mp/sources.tsv"
reset "$absent" "$after" 0
printf '%s\t200\tblob-b\n' "$SIB1" > "$FAKE/blobs.tsv"
rc="$(mf_run sib 1 MIRROR_REPAIR=0)"
check "mirror-file: the sibling plan names gives the package, with no upstream request; MIRROR_REPAIR=0 stops no push" \
  "0 pushed from ghcr.io/$SIB1 0 1" "$rc $(mf_result sib 1) $(up_gets) $(pushes "$REF_B")" "MIRROR_REPAIR=0 $MF 1; cat $work/mf-sib.err $FAKE/calls.log"
if [ -f "$FAKE/pushed.json" ]; then
  cp "$FAKE/pushed.json" "$FAKE/tag-b-full.json"
fi

# The first sibling answers 503: down for the shard, and the next one gives
# the package. The next file of the shard does not ask the first again.
printf '%s\t%s\n' b-1-1-any.pkg.tar.zst "$SIB1" b-1-1-any.pkg.tar.zst "$SIB2" c-1-1-any.pkg.tar.zst "$SIB1" c-1-1-any.pkg.tar.zst "$SIB2" \
  > "$mp/sources.tsv"
reset "$absent" "$after" 0
printf '%s\t503\tbusy.txt\n%s\t200\tblob-b\n' "$SIB1" "$SIB2" > "$FAKE/blobs.tsv"
rc="$(mf_run down 1)"
check "mirror-file: a sibling that answers 503 is marked down for the shard, and the next sibling gives the package" \
  "0 pushed from ghcr.io/$SIB2 0 1 yes" "$rc $(mf_result down 1) $(up_gets) $(blob_gets "$SIB1") $(down "$SIB1" down)" \
  "$MF 1; cat $work/mf-down.err $FAKE/calls.log"
reset "$absent" "$after" 0
printf '%s\t503\tbusy.txt\n%s\t200\tblob-c\n' "$SIB1" "$SIB2" > "$FAKE/blobs.tsv"
rc="$(mf_run down 2)"
check "mirror-file: a sibling marked down is not asked again by the shard" \
  "0 pushed from ghcr.io/$SIB2 0" "$rc $(mf_result down 2) $(blob_gets "$SIB1")" "$MF 2, after line 1 in the same WORK; cat $FAKE/calls.log"

# The first sibling answers 429: a pause, and the next sibling.
printf '%s\t%s\n' b-1-1-any.pkg.tar.zst "$SIB1" b-1-1-any.pkg.tar.zst "$SIB2" > "$mp/sources.tsv"
reset "$absent" "$after" 0
printf '%s\t429\tlimited.json\n%s\t200\tblob-b\n' "$SIB1" "$SIB2" > "$FAKE/blobs.tsv"
rc="$(mf_run limit 1)"
check "mirror-file: a sibling that answers 429 pauses the shard, is not marked down, and the next sibling gives the package" \
  "0 pushed from ghcr.io/$SIB2 1 yes no" \
  "$rc $(mf_result limit 1) $(pauses "$work/mf-limit.err") $([ -s "$work/mf-limit/work/throttle" ] && echo yes || echo no) $(down "$SIB1" limit)" \
  "$MF 1; cat $work/mf-limit.err"

# The sibling gives other bytes of the same size: refused, and upstream
# gives the package.
printf 'b-1-1-any.pkg.tar.zst\t%s\n' "$SIB1" > "$mp/sources.tsv"
reset "$absent" "$after" 0
printf '%s\t200\tblob-other\n' "$SIB1" > "$FAKE/blobs.tsv"
rc="$(mf_run other 1)"
check "mirror-file: a sibling that gives other bytes is refused and marked down, and upstream gives the package" \
  "0 pushed from $UP 1 yes same" \
  "$rc $(mf_result other 1) $(up_gets) $(down "$SIB1" other) $(same_bytes "$FAKE/pushed/b-1-1-any.pkg.tar.zst" "$FAKE/blob-b" && echo same || echo other)" \
  "$MF 1; cat $work/mf-other.err"

# The sibling answers 404 BLOB_UNKNOWN: a quiet miss.
reset "$absent" "$after" 0
printf '%s\t404\tblob-unknown.json\n' "$SIB1" > "$FAKE/blobs.tsv"
rc="$(mf_run miss 1)"
check "mirror-file: a sibling that answers 404 is a quiet miss: not marked down, no line names it, and upstream gives the package" \
  "0 pushed from $UP 1 no 0" "$rc $(mf_result miss 1) $(blob_gets "$SIB1") $(down "$SIB1" miss) $(names "$SIB1" miss)" \
  "$MF 1; cat $work/mf-miss.err"

# d: every server answers 404. The absent rule looks at the upstream servers
# only: a sibling that answers 404, or 503, leaves it absent. An upstream
# server that errs makes it failed.
printf 'd-1-1-any.pkg.tar.zst\t%s\n' "$SIB1" > "$mp/sources.tsv"
reset "$absent" "$after" 0
printf '%s\t404\tblob-unknown.json\n' "$SIB1" > "$FAKE/blobs.tsv"
rc="$(mf_run gone 3)"
check "mirror-file: a sibling that answers 404, and every server 404: absent" "0 absent" \
  "$rc $(cut -f 3 "$work/mf-gone/results/3.tsv" 2> /dev/null)" "$MF 3; cat $work/mf-gone.err"
reset "$absent" "$after" 0
printf '%s\t503\tbusy.txt\n' "$SIB1" > "$FAKE/blobs.tsv"
rc="$(mf_run gonebusy 3)"
check "mirror-file: a sibling that answers 503, and every server 404: absent, as upstream decides" "0 absent yes" \
  "$rc $(cut -f 3 "$work/mf-gonebusy/results/3.tsv" 2> /dev/null) $(down "$SIB1" gonebusy)" "$MF 3; cat $work/mf-gonebusy.err"
reset "$absent" "$after" 0
printf '%s\t503\tbusy.txt\n' "$SIB1" > "$FAKE/blobs.tsv"
printf '503\n' > "$FAKE/up/d-1-1-any.pkg.tar.zst.code"
rc="$(mf_run upbusy 3)"
rm -f "$FAKE/up/d-1-1-any.pkg.tar.zst.code"
case "$rc:$(cut -f 3,5 "$work/mf-upbusy/results/3.tsv" 2> /dev/null)" in
  1:failed*"no answer that decides from ghcr.io/$SIB1 (status 1)"*) ok "mirror-file: a sibling that answers 503, and the upstream server errs: failed, not absent, naming the sibling" ;;
  *) fail "mirror-file: a sibling that answers 503, and the upstream server errs: failed, not absent, naming the sibling" \
    "got: exit $rc, $(cat "$work/mf-upbusy/results/3.tsv" 2> /dev/null)" "$MF 3; cat $work/mf-upbusy.err" ;;
esac

# MIRROR_REPAIR=0 (a run on a branch): no repush, and nothing is read.
: > "$mp/sources.tsv"
reset 'Bearer QQ==\t200\ttag-b-nosig.json\n' "$after" 0
printf '%s\t200\tblob-b\n' "$OWN" > "$FAKE/blobs.tsv"
rc="$(mf_run branch 1 MIRROR_REPAIR=0)"
check "mirror-file: MIRROR_REPAIR=0 refuses a repush: failed, with no push, no blob read and no upstream request" \
  "1 failed a signature repair is left to main 0 0 0" "$rc $(mf_result branch 1) $(pushes "$REF_B") $(blob_gets) $(up_gets)" \
  "MIRROR_REPAIR=0 $MF 1; cat $work/mf-branch.err"

# A re-run (GITHUB_RUN_ATTEMPT=2): the list index_guard wrote above names b.
reset "$absent" "$after" 0
mkdir -p "$work/mf-listed/work"
if [ -f "$work/guard-listed/index-listed.txt" ]; then
  cp "$work/guard-listed/index-listed.txt" "$work/mf-listed/work/"
fi
rc="$(mf_run listed 1 GITHUB_RUN_ATTEMPT=2)"
check "mirror-file, a re-run: a file the live index lists gets no tag, and nothing is read for it" \
  "1 failed the index lists it 0 0 0" "$rc $(mf_result listed 1) $(pushes "$REF_B") $(blob_gets) $(up_gets)" \
  "GITHUB_RUN_ATTEMPT=2 $MF 1; cat $work/mf-listed.err"
printf 'b-1-1-any.pkg.tar.zst\n' > "$work/mf-listed/work/index-listed.txt"
reset "$absent" "$after" 0
rc="$(mf_run listed 2 GITHUB_RUN_ATTEMPT=2)"
check "mirror-file, a re-run: a file the live index does not list is pushed" "0 pushed from $UP" \
  "$rc $(mf_result listed 2)" "GITHUB_RUN_ATTEMPT=2 $MF 2; cat $work/mf-listed.err"

# A re-run whose live index did not read: the reason index_guard wrote
# above. No tag is written; a tag that holds its file is still present.
reset "$absent" "$after" 0
mkdir -p "$work/mf-unread/work"
if [ -f "$work/guard-busy/index-unread" ]; then
  cp "$work/guard-busy/index-unread" "$work/mf-unread/work/"
fi
rc="$(mf_run unread 1 GITHUB_RUN_ATTEMPT=2)"
case "$rc:$(pushes "$REF_B"):$(cut -f 3,5 "$work/mf-unread/results/1.tsv" 2> /dev/null)" in
  1:0:failed*'the live index did not read; '*'did not read in 3 tries (HTTP 503)'*) ok "mirror-file, a re-run: with the live index unread, no tag is written, and the result says why" ;;
  *) fail "mirror-file, a re-run: with the live index unread, no tag is written, and the result says why" \
    "got: exit $rc, $(pushes "$REF_B") push(es), $(cat "$work/mf-unread/results/1.tsv" 2> /dev/null)" "GITHUB_RUN_ATTEMPT=2 $MF 1; cat $work/mf-unread.err" ;;
esac
reset 'Bearer QQ==\t200\ttag-b-full.json\n' '' 0
rc="$(mf_run unread 1 GITHUB_RUN_ATTEMPT=2)"
check "mirror-file, a re-run: with the live index unread, a tag that holds its file is present" "0 present" \
  "$rc $(cut -f 3 "$work/mf-unread/results/1.tsv" 2> /dev/null)" "GITHUB_RUN_ATTEMPT=2 $MF 1; cat $work/mf-unread.err"

#---------------------------------------------------------------------------#
# mirror-shard reads INDEX_STATE from the plan's meta.env (PLAN/<target>,
# two levels above the shard file), as data, and gives it to mirror-file:
# unknown when meta.env or the key is missing. A stand-in mirror-file records
# what it got. mirror-shard runs on a GitHub runner, with GNU df and xargs
# (df --output, xargs -d); with busybox's, these cases are skipped.
#---------------------------------------------------------------------------#
# shard_tools -> 0 when df and xargs take the options mirror-shard gives them
shard_tools() {
  df --output=avail -B1 "$work" > /dev/null 2>&1 || return 1
  printf 'x\n' | xargs -d '\n' -n 1 true > /dev/null 2>&1
}
if ! shard_tools; then
  skip "mirror-shard: INDEX_STATE from the plan's meta.env" "df --output or xargs -d is refused here (busybox), and mirror-shard needs both"
  summary
  exit $?
fi
cat > "$FAKE/root/scripts/mirror-file" << 'EOF'
#!/usr/bin/env bash
# A stand-in for scripts/mirror-file SHARD LINE: it records INDEX_STATE as it
# gets it, and the result present for LINE.
printf '%s\n' "${INDEX_STATE-unset}" > "$FAKE/shard-index-state"
printf 'x86_64-core\tline-%s\tpresent\t0\tthe stand-in\n' "$2" > "$RESULTS/$2.tsv"
EOF
chmod +x "$FAKE/root/scripts/mirror-file"
sp="$work/splan/x86_64-core"
mkdir -p "$sp/shards"
sed -n 1p "$mp/shards/0.tsv" > "$sp/shards/0.tsv"
# shard_state NAME -> the exit status of mirror-shard, and the INDEX_STATE
# that mirror-file got
shard_state() {
  local rc=0
  rm -f "$FAKE/shard-index-state"
  REPO_ROOT="$FAKE/root" PATH="$FAKE/bin:$PATH" DEBLOAT=never PARALLEL=1 SHARD_INDEX=0 \
    "$SCRIPTS/mirror-shard" "$sp/shards/0.tsv" "$work/shard-$1" > "$work/shard-$1.out" 2> "$work/shard-$1.err" || rc=$?
  printf '%s %s\n' "$rc" "$(cat "$FAKE/shard-index-state" 2> /dev/null || echo 'no call')"
}
SH="REPO_ROOT=<stand-ins> DEBLOAT=never scripts/mirror-shard SPLAN/x86_64-core/shards/0.tsv OUT"
reset '' '' 0
printf 'TARGET=x86_64-core\nINDEX_TAG=index\nINDEX_STATE=ignored\nINDEX_DIGEST=\n' > "$sp/meta.env"
check "mirror-shard: mirror-file gets the INDEX_STATE of the plan's meta.env" "0 ignored" "$(shard_state ignored)" \
  "$SH; cat $work/shard-ignored.err"
printf 'TARGET=x86_64-core\nINDEX_TAG=index\n' > "$sp/meta.env"
check "mirror-shard: a meta.env with no INDEX_STATE gives unknown" "0 unknown" "$(shard_state nokey)" \
  "$SH; cat $work/shard-nokey.err"
rm -f "$sp/meta.env"
check "mirror-shard: no meta.env gives unknown" "0 unknown" "$(INDEX_STATE=ok shard_state nometa)" \
  "INDEX_STATE=ok $SH; cat $work/shard-nometa.err"

summary
