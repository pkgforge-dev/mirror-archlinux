#!/usr/bin/env bash
#
# The scripts that write to the registry, run against stand-ins for curl and
# oras, with no network: what each one does when the registry fails, refuses
# or limits it. stage and promote install oras through
# REPO_ROOT/scripts/install-oras, so they run with REPO_ROOT set to a root of
# stand-ins; lib.sh still comes from the real scripts directory.
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
#   */manifests/*    from $FAKE/answers.tsv, AUTH<TAB>CODE<TAB>BODY-FILE, the
#                    first line whose AUTH matches; no line is no answer
#   any other URL    $FAKE/up/<last path element> with 200, or 404
# With --write-out, prints the HTTP code.
out="" auth="" url="" cred="" wo=""
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
  */token)
    case "$cred" in
      *'user = '*) printf '{"token":"tok1"}' > "$out" ;;
      *) printf '{"token":"anon"}' > "$out" ;;
    esac
    code=200
    ;;
  */manifests/*)
    line="$(awk -F '\t' -v a="$auth" '$1 == a && !f { print $2 "\t" $3; f = 1 }' "$FAKE/answers.tsv")"
    if [ -z "$line" ]; then
      [ -z "$wo" ] || printf '000'
      exit 7
    fi
    cp "$FAKE/${line#*$'\t'}" "$out"
    code="${line%%$'\t'*}"
    ;;
  *)
    f="$FAKE/up/${url##*/}"
    if [ -f "$f" ]; then
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
# the current directory) to $FAKE/pushed.json, and copies $FAKE/after-push.tsv
# to $FAKE/answers.tsv when it exists.
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
  layers='[]'
  for a in "$@"; do
    case "$a" in
      ./*)
        p="${a%:*}"
        layers="$(jq -c --arg t "${a##*:}" --arg d "sha256:$(sha256sum "$p" | cut -d ' ' -f 1)" \
          --argjson s "$(wc -c < "$p" | tr -d ' ')" --arg n "${p#./}" \
          '. + [{mediaType: $t, digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $n}}]' <<< "$layers")"
        ;;
    esac
  done
  jq -cn --argjson l "$layers" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: $l}' > "$FAKE/pushed.json"
  if [ -f "$FAKE/after-push.tsv" ]; then
    cp "$FAKE/after-push.tsv" "$FAKE/answers.tsv"
  fi
fi
exit 0
EOF

# The root of stand-ins: install-oras names the stand-in oras, and the
# wrapper serves $FAKE/promoted.db as the database a consumer reads.
cat > "$FAKE/root/scripts/install-oras" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE/bin/oras"
EOF
cat > "$FAKE/root/client/pacman-oci" << 'EOF'
#!/usr/bin/env bash
cp "$FAKE/promoted.db" "$1"
EOF
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
unset GITHUB_ACTIONS GITHUB_OUTPUT

# reset ANSWERS AFTER-PUSH 429S: the registry's answers now and after a push,
# and how many oras calls get a 429 first
reset() {
  printf '%b' "$1" > "$FAKE/answers.tsv"
  printf '%b' "$2" > "$FAKE/after-push.tsv"
  printf '%s\n' "$3" > "$FAKE/oras-429"
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

# The anonymous read answers: staged.
reset '' 'Bearer QQ==\t200\tpushed.json\n' 0
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

reset '' 'Bearer QQ==\t200\tpushed.json\n' 3
rc="$(stage_run 429)"
check "stage: three 429s on the staging push: three pauses, four pushes, staged" "0 3 4 staged" \
  "$rc $(pauses "$work/stage-429.err") $(oras_calls push) $(cat "$work/stage-429/x86_64-core/state" 2> /dev/null)" \
  "$ST with an oras that answers 429 three times; cat $work/stage-429.err"

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
#   run   writes the image (the argument before "bash") to $FAKE/ran; the
#         container passes.
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
# verify_run NAME MIRRORS-UP: scripts/verify-batch into $work/verify-NAME
verify_run() {
  local rc=0
  printf '%b' "$2" > "$FAKE/mirrors-up"
  : > "$FAKE/pulls.log"
  rm -f "$FAKE/ran"
  env -u VERIFY_IMAGE_MIRRORS CONTAINER_RUNTIME="$FAKE/bin/runtime" "$SCRIPTS/verify-batch" "$work/vstage" x86_64-vimg 0 "$work/verify-$1" \
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

summary
