#!/usr/bin/env bash
#
# The status page on fixed inputs, with no network.
#
# scripts/status-collect runs against fixture databases. The upstream, the
# registry and the Worker are answered by tests/fixtures/status/fake-curl,
# first on PATH as curl. scripts/status-render then runs on what was
# collected, with a fixture history and bench file. Every SVG must parse as
# XML, every badge must carry its text, and the page must reference every
# chart and badge. With one registry read that fails, and with none that
# answers, a sum over part of the targets must say which part, and nothing
# may say "not mirrored" for a registry that did not answer. Each time on the
# page must be UTC text in a <time> element, the page must have one inline
# script and no other, and each sum of the size table must equal the sum of
# its targets. The synced badge must say its age and colour at 30 min, 5 h,
# 12 h and 30 h, and fall back to the fetched time. check-staleness and
# status-collect must end within their budgets when the first db_server of 8
# targets is a local listener that never answers, and ask that host once.
# Neither may take a first db_server that is behind the second, or that
# answers 200 with an HTML page, for upstream. A Worker probe must follow
# its 302 to the signed URL, as a consumer does. The smallest database
# downloaded through the Worker must be the one latest names.
#
# ⚠ db_records needs GNU tar, and status-render needs python3. A shell that
# lacks one skips that part and says why: busybox has neither, Arch has no
# python3. The runner job has both.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
# The local listeners a test starts, stopped on exit
listeners=""
cleanup() {
  local p rc
  for p in $listeners; do
    rc=0
    kill "$p" || rc=$?
    [ "$rc" -eq 0 ] || echo "# listener $p had ended already (kill $rc)"
  done
  rm -rf "$work"
}
trap cleanup EXIT

# listen NAME: a local TCP listener that accepts each connection and never
# answers. Sets port; each connection adds a line to $work/NAME.log.
cat > "$work/listen.py" << 'EOF'
import os, socket, sys
log, port = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
s.listen(64)
with open(port + ".tmp", "w") as f:
    f.write("%d\n" % s.getsockname()[1])
os.rename(port + ".tmp", port)
held = []
while True:
    c, _ = s.accept()
    held.append(c)
    with open(log, "a") as f:
        f.write("accepted\n")
EOF
listen() {
  : > "$work/$1.log"
  python3 -I "$work/listen.py" "$work/$1.log" "$work/$1.port" &
  listeners="$listeners $!"
  for _ in $(seq 1 100); do
    [ ! -s "$work/$1.port" ] || break
    sleep 0.1
  done
  port=""
  if [ -s "$work/$1.port" ]; then
    port="$(cat "$work/$1.port")"
  fi
}

#---------------------------------------------------------------------------#
# The sync interval, from a cron
#---------------------------------------------------------------------------#
cron_file() {
  local c
  printf 'on:\n  schedule:\n' > "$work/cron.yml"
  for c in "$@"; do
    printf "    - cron: '%s'\n" "$c" >> "$work/cron.yml"
  done
}
minutes() {
  cron_file "$@"
  "$REPO_ROOT/scripts/cron-tolerance" --minutes "$work/cron.yml"
}
CT="scripts/cron-tolerance --minutes FILE"
check "interval: every 3 hours is 180 minutes" 180 "$(minutes '17 */3 * * *')" "$CT"
check "interval: hourly is 60 minutes" 60 "$(minutes '47 * * * *')" "$CT"
check "interval: daily is 1440 minutes" 1440 "$(minutes '41 7 * * *')" "$CT"
check "interval: a daily and an hourly cron together give 60 minutes" 60 "$(minutes '41 7 * * *' '7 * * * *')" "$CT"
check "interval: weekly is 10080 minutes" 10080 "$(minutes '0 6 * * 1')" "$CT"
check "interval: 05:30 and 17:30 give 720 minutes" 720 "$(minutes '30 5,17 * * *')" "$CT"
# One firing in the four-year walk: the gap runs round to the same firing.
check "interval: only on 29 February is 1461 days, 2103840 minutes" 2103840 "$(minutes '0 0 29 2 *')" "$CT"
cron_file '17 */3 * * *'
check "the day tolerance is unchanged: every 3 hours is 1 3" "1 3" \
  "$("$REPO_ROOT/scripts/cron-tolerance" "$work/cron.yml")" "scripts/cron-tolerance FILE"

#---------------------------------------------------------------------------#
# Fixtures: databases, a registry, an upstream and a Worker
#---------------------------------------------------------------------------#
net="$work/net"
bin="$work/bin"
mkdir -p "$bin" "$net/up.test" "$net/bad.test" "$net/ghcr.io" "$net/worker.test" "$work/targets"
cp "$REPO_ROOT/tests/fixtures/status/fake-curl" "$bin/curl"
chmod +x "$bin/curl"
printf '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}\n' > "$net/ghcr.io/.404"
# The anonymous token, which status-collect asks for with no credential
printf '{"token":"anon"}\n' > "$net/ghcr.io/token"
# The blob host the Worker redirects to: each blob of the registry, and one
# byte at sha256:00 for the package probes
blobs="$net/pkg-containers.githubusercontent.com/ghcrblobs/blobs"
mkdir -p "$blobs"
printf 'x' > "$blobs/sha256:00"
# blob_url FILE -> the signed URL of FILE's blob on the blob host
blob_url() {
  printf 'https://pkg-containers.githubusercontent.com/ghcrblobs/blobs/sha256:%s?se=x\n' "$(sha256sum "$1" | cut -d ' ' -f 1)"
}

# pkg DIR NAME VERSION ARCH CSIZE BUILDDATE [SEED]: one desc entry; SEED
# changes the sha256 and nothing else
pkg() {
  local dir="$1" name="$2" ver="$3" arch="$4" csize="$5" built="$6" seed="${7:-}" sha
  sha="$(printf '%s-%s%s' "$name" "$ver" "$seed" | sha256sum | cut -d ' ' -f 1)"
  mkdir -p "$dir/$name-$ver"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%CSIZE%%\n%s\n\n%%SHA256SUM%%\n%s\n\n%%BUILDDATE%%\n%s\n\n%%ARCH%%\n%s\n\n' \
    "$name-$ver-$arch.pkg.tar.zst" "$name" "$ver" "$csize" "$sha" "$built" "$arch" > "$dir/$name-$ver/desc"
}
mkdb() {
  (cd "$1" && tar -czf "$2" -- *)
}
# mirror ARCH REPO DB FETCHED [CREATED]: the db as the blob latest names;
# with CREATED, latest names it as org.opencontainers.image.created, as oras
# does
mirror() {
  local base="$net/ghcr.io/v2/test/mirror/$1/$2" sha size
  sha="$(sha256sum "$3" | cut -d ' ' -f 1)"
  size="$(wc -c < "$3" | tr -d ' ')"
  mkdir -p "$base/manifests" "$base/blobs"
  cp "$3" "$base/blobs/sha256:$sha"
  cp "$3" "$blobs/sha256:$sha"
  jq -n --arg sha "sha256:$sha" --argjson size "$size" --arg repo "$2" --arg fetched "$4" --arg created "${5:-}" '{
    schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
    layers: [{mediaType: "application/vnd.pkgforge.archlinux.db.v1", digest: $sha, size: $size,
              annotations: {"org.opencontainers.image.title": "\($repo).db"}}],
    annotations: ({"dev.pkgforge.mirror.fetched": $fetched, "dev.pkgforge.mirror.run": "42"}
                  + if $created == "" then {} else {"org.opencontainers.image.created": $created} end)}' \
    > "$base/manifests/latest"
}
redirect() {
  mkdir -p "$(dirname "$net/worker.test/$1")"
  printf '%s\n' "${2:-302}" > "$net/worker.test/$1.code"
  printf '%s\n' "${3:-https://pkg-containers.githubusercontent.com/ghcrblobs/blobs/sha256:00?se=x}" \
    > "$net/worker.test/$1.location"
}
target() {
  local f="$work/targets/$1-$2.conf"
  printf 'arch = %s\nrepo = %s\n' "$1" "$2" > "$f"
  shift 2
  printf '%s\n' "$@" >> "$f"
}

B=1790000000
# x86_64-core: the mirror serves upstream's very database
pkg "$work/up/x86_64-core" acl 2.3.2-1 x86_64 100 "$B"
pkg "$work/up/x86_64-core" bash 5.3.9-1 x86_64 200 "$B"
pkg "$work/up/x86_64-core" zlib 1:1.3.2-3 x86_64 300 "$B"
pkg "$work/up/x86_64-core" coreutils 9.8-1 x86_64 400 "$((B + 60))"
# x86_64-extra: 3 of 5 files match; delta was rebuilt under the same name,
# epsilon moved on
for p in "alpha 1-1 100" "beta 2-1 200" "gamma 1-1 300"; do
  read -r n v s <<< "$p"
  pkg "$work/up/x86_64-extra" "$n" "$v" x86_64 "$s" "$B"
  pkg "$work/mirror/x86_64-extra" "$n" "$v" x86_64 "$s" "$B"
done
pkg "$work/up/x86_64-extra" delta 1-1 x86_64 400 "$B" rebuilt
pkg "$work/mirror/x86_64-extra" delta 1-1 x86_64 400 "$B"
pkg "$work/up/x86_64-extra" epsilon 1-1 x86_64 500 "$((B + 3600))"
pkg "$work/mirror/x86_64-extra" epsilon 0.9-1 x86_64 500 "$B"
# aarch64-core and loong64-core: upstream only
for t in aarch64-core loong64-core; do
  pkg "$work/up/$t" linux 6.17-1 "${t%%-*}" 1000 "$B"
  pkg "$work/up/$t" glibc 2.42-1 "${t%%-*}" 2000 "$B"
done

for t in x86_64-core x86_64-extra aarch64-core loong64-core; do
  a="${t%%-*}" r="${t#*-}"
  mkdir -p "$net/up.test/$a/$r"
  mkdb "$work/up/$t" "$net/up.test/$a/$r/$r.db"
done
mkdb "$work/mirror/x86_64-extra" "$work/extra-mirror.db"

#---------------------------------------------------------------------------#
# Can db_records read a database here? It needs GNU tar.
#---------------------------------------------------------------------------#
# pipefail as in the scripts: without it a tar that fails inside db_records'
# pipeline reads as an empty database.
rc=0
bash -c 'set -o pipefail; . "$1"; db_records "$2" "$3"' _ "$REPO_ROOT/scripts/lib.sh" \
  "$net/up.test/x86_64/core/core.db" "$work/probe.tsv" > "$work/probe.err" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(awk 'END { print NR }' "$work/probe.tsv")" != 4 ]; then
  rc=1
  printf 'db_records read %s record(s), not 4\n' "$(awk 'END { print NR }' "$work/probe.tsv")" >> "$work/probe.err"
fi
if [ "$rc" -ne 0 ]; then
  ok "skipped: status-collect, because db_records cannot read a database with this tar ($(sed -n 1p "$work/probe.err"))"
  if command -v python3 > /dev/null; then
    ok "skipped: status-render, because there is no collected status to render"
  fi
  summary
  exit $?
fi

# x86_64-core names a created time with a fraction; x86_64-extra names none
mirror x86_64 core "$net/up.test/x86_64/core/core.db" 2026-10-14T00:00:00Z 2026-10-14T00:30:00.123456Z
mirror x86_64 extra "$work/extra-mirror.db" 2026-10-14T00:00:00Z
# Each database redirect leads to the blob of that database; the Worker says
# its cache answered for core.db
redirect x86_64/core/core.db 302 "$(blob_url "$net/up.test/x86_64/core/core.db")"
printf 'x-mirror-cache: hit\nx-mirror-blob-host: pkg-containers.githubusercontent.com\n' > "$net/worker.test/x86_64/core/core.db.headers"
redirect x86_64/core/acl-2.3.2-1-x86_64.pkg.tar.zst
redirect x86_64/extra/extra.db 302 "$(blob_url "$work/extra-mirror.db")"
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst 503 ''
mkdir -p "$net/bad.test/x86_64/multilib"
printf '500\n' > "$net/bad.test/x86_64/multilib/multilib.db.code"

# $arch and $repo are the target file's own placeholders, not shell's.
# shellcheck disable=SC2016
{
  target x86_64 core 'db_server = https://up.test/$arch/$repo'
  target x86_64 extra 'db_server = https://up.test/$arch/$repo'
  target x86_64 multilib 'db_server = https://bad.test/$arch/$repo'
  target aarch64 core 'db_server = https://up.test/$arch/$repo'
  target loong64 core 'db_server = https://down.test/$arch/$repo' 'db_server = https://up.test/$arch/$repo'
  target riscv64 core 'db_server = https://up.test/$arch/$repo' 'enabled = no'
}

NOW="$(jq -n '"2026-10-14T03:00:00Z" | fromdateiso8601')"
# collect OUT [SECONDS]: status-collect against the fixtures, its stderr in
# OUT.err; returns its status
collect() {
  local rc=0
  mkdir -p "$1"
  PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" FAKE_CURL_LOG="$work/requests.log" \
    TARGETS_DIR="$work/targets" MIRROR_NAMESPACE=test/mirror MIRROR_REGISTRY=ghcr.io \
    GITHUB_REPOSITORY=test/mirror STATUS_WORKER_URL=https://worker.test MIRROR_NOW="${2:-$NOW}" \
    "$REPO_ROOT/scripts/status-collect" "$1" > "$1.out" 2> "$1.err" || rc=$?
  return "$rc"
}
RP="PATH=<fake-curl>:\$PATH FAKE_CURL_ROOT=<fixtures> scripts/status-collect OUT"

out="$work/run1"
rc=0
collect "$out" || rc=$?
check "status-collect measures the fixtures and exits 0" 0 "$rc" "$RP; see $(sed -n '$p' "$out.err")"
if [ "$rc" -ne 0 ]; then
  diag "$(sed -n 1,40p "$out.err")"
fi
q() {
  jq -r "$1" "$out/status.json"
}

check "status.json is schema 1" 1 "$(q .schema)" "jq .schema OUT/status.json"
check "every enabled target, sorted; a disabled one is left out" \
  "aarch64-core loong64-core x86_64-core x86_64-extra x86_64-multilib" \
  "$(q '[.targets[].target] | join(" ")')" "jq '.targets[].target' OUT/status.json"
check "the sync interval is read from sync.yml's cron" \
  "$("$REPO_ROOT/scripts/cron-tolerance" --minutes "$REPO_ROOT/.github/workflows/sync.yml")" \
  "$(q .sync.interval_minutes)" "jq .sync OUT/status.json"

T='.targets[] | select(.target == "x86_64-core")'
check "x86_64-core: the mirror database is upstream's, so it is current" true "$(q "$T | .current")" "jq '$T' OUT/status.json"
check "x86_64-core: coverage is 4 of 4 files, ratio 1" "4 4 1 0" \
  "$(q "$T | .coverage | \"\(.files) \(.of_files) \(.ratio_files) \(.missing)\"")" "jq '$T.coverage' OUT/status.json"
check "x86_64-core: age is now minus the fetched time" 10800 "$(q "$T | .age_seconds")" "jq '$T.age_seconds' OUT/status.json"
check "x86_64-core: no lag" 0 "$(q "$T | .lag_seconds")" "jq '$T.lag_seconds' OUT/status.json"
check "x86_64-core: the Worker answers 302 for the database and for one package" \
  "302 true 302 true acl-2.3.2-1-x86_64.pkg.tar.zst" \
  "$(q "$T | .worker | \"\(.db.code) \(.db.ok) \(.package.code) \(.package.ok) \(.package.url | split(\"/\") | last)\"")" \
  "jq '$T.worker' OUT/status.json"
check "x86_64-core: the redirect host is kept, not the signed URL" pkg-containers.githubusercontent.com \
  "$(q "$T | .worker.db.location")" "jq '$T.worker.db' OUT/status.json"
check "x86_64-core: the signed URL of each 302 answers the runner, with no credential, and its host is expected" \
  "200 false 200 false" \
  "$(q "$T | .worker | \"\(.db.signed_code) \(.db.location_unexpected) \(.package.signed_code) \(.package.location_unexpected)\"")" \
  "jq '$T.worker' OUT/status.json"
check "x86_64-core: the Worker's x-mirror-cache and x-mirror-blob-host headers are kept" \
  "hit pkg-containers.githubusercontent.com null" \
  "$(q "$T | .worker | \"\(.db.cache) \(.db.blob_host) \(.package.cache)\"")" "jq '$T.worker.db' OUT/status.json"
check "the smallest database of a target with latest, downloaded through the Worker, is the one latest names" \
  "1 true 200" \
  "$(q '[.targets[] | .worker.download | select(. != null)] | "\(length) \(.[0].ok) \(.[0].code)"')" \
  "jq '.targets[].worker.download' OUT/status.json"

T='.targets[] | select(.target == "x86_64-extra")'
check "x86_64-extra: a file counts only with the same name and sha256: 3 of 5" "3 5 2" \
  "$(q "$T | .coverage | \"\(.files) \(.of_files) \(.missing)\"")" "jq '$T.coverage' OUT/status.json"
check "x86_64-extra: coverage by bytes is 600 of 1500" "600 1500 0.4" \
  "$(q "$T | .coverage | \"\(.bytes) \(.of_bytes) \(.ratio_bytes)\"")" "jq '$T.coverage' OUT/status.json"
check "x86_64-extra: the missing files are named, sorted" \
  "delta-1-1-x86_64.pkg.tar.zst epsilon-1-1-x86_64.pkg.tar.zst" \
  "$(q "$T | .coverage.missing_names | join(\" \")")" "jq '$T.coverage.missing_names' OUT/status.json"
check "x86_64-extra: lag is upstream's newest build date minus the mirror's" 3600 \
  "$(q "$T | .lag_seconds")" "jq '$T.lag_seconds' OUT/status.json"
check "x86_64-extra: not current" false "$(q "$T | .current")" "jq '$T.current' OUT/status.json"
check "x86_64-extra: a package probe answered 503 fails" "503 false HTTP 503, expected 302" \
  "$(q "$T | .worker.package | \"\(.code) \(.ok) \(.error)\"")" "jq '$T.worker.package' OUT/status.json"

T='.targets[] | select(.target == "aarch64-core")'
check "aarch64-core: no latest is absent, not an error" absent "$(q "$T | .mirror.state")" "jq '$T.mirror' OUT/status.json"
check "aarch64-core: coverage is 0 of 2" "0 2 0" "$(q "$T | .coverage | \"\(.files) \(.of_files) \(.ratio_files)\"")" \
  "jq '$T.coverage' OUT/status.json"
check "aarch64-core: the Worker must answer 404, and does; no package probe" "404 404 true null" \
  "$(q "$T | .worker | \"\(.db.code) \(.db.expect) \(.db.ok) \(.package)\"")" "jq '$T.worker' OUT/status.json"

T='.targets[] | select(.target == "loong64-core")'
check "loong64-core: the second db_server answers when the first does not resolve" \
  "https://up.test/loong64/core https://down.test/loong64/core curl 6" \
  "$(q "$T | .upstream | \"\(.server) \(.tried[0].server) \(.tried[0].result)\"")" "jq '$T.upstream' OUT/status.json"

T='.targets[] | select(.target == "x86_64-multilib")'
check "x86_64-multilib: no db_server answers: upstream not read, coverage unknown" "false HTTP 500 null" \
  "$(q "$T | \"\(.upstream.ok) \(.upstream.tried[0].result) \(.coverage)\"")" "jq '$T' OUT/status.json"

check "summary: 5 targets, 2 promoted, 1 current, 7 of 13 files" "5 2 1 7 13" \
  "$(q '.summary | "\(.targets) \(.promoted) \(.current) \(.mirrored_files) \(.upstream_files)"')" "jq .summary OUT/status.json"
check "summary: the sums count 4 measured targets; x86_64-multilib is not read upstream" "4 0" \
  "$(q '.summary | "\(.measured) \(.mirror_unread)"')" "jq .summary OUT/status.json"
check "mirror.created is latest's org.opencontainers.image.created, the fraction cut; null when latest names none" \
  "2026-10-14T00:30:00Z null" \
  "$(q '[.targets[] | select(.target == "x86_64-core" or .target == "x86_64-extra") | .mirror.created] | map(tostring) | join(" ")')" \
  "jq '.targets[].mirror' OUT/status.json"
check "summary: last_synced is the newest of each target's created time, or its fetched time" \
  2026-10-14T00:30:00Z "$(q .summary.last_synced)" "jq .summary OUT/status.json"
check "worker: one failed probe fails the run, the first in a row" "false 1 1 2026-10-14T03:00:00Z" \
  "$(q '.worker | "\(.ok) \(.failures) \(.failed_runs) \(.failing_since)"')" "jq .worker OUT/status.json"
check "worker: one failed run is not down" "0 false" \
  "$(q '.worker | "\(.failing_seconds) \(.down)"')" "jq .worker OUT/status.json"
check "history.jsonl has one line for one run" 1 "$(awk 'END { print NR }' "$out/history.jsonl")" "wc -l OUT/history.jsonl"
check "history keeps files, mirrored files and age per target" "5 3 10800" \
  "$(jq -r '.x["x86_64-extra"] | "\(.n) \(.m) \(.a)"' "$out/history.jsonl")" "jq -c . OUT/history.jsonl"
if grep -q 'HTTP 503, expected 302' "$out/worker.md" && grep -q 'reproduce:' "$out/worker.md"; then
  ok "worker.md names the failed probe and how to reproduce it"
else
  fail "worker.md names the failed probe and how to reproduce it" "$(sed -n 1,30p "$out/worker.md")" "cat OUT/worker.md"
fi
bad_hosts="$(awk '{ h = $0; sub(/^[a-z]+:\/\//, "", h); sub(/\/.*/, "", h); if (h !~ /^(up|bad|down|worker)\.test$/ && h != "ghcr.io" && h != "pkg-containers.githubusercontent.com") print }' "$work/requests.log")"
check "every request went to a fixture host" "" "$bad_hosts" "cat \$work/requests.log"

# A second run: the package probe now redirects to plain http. The failure
# count goes on, and the first failure's time is kept.
out1="$out"
out="$work/run2"
mkdir -p "$out"
cp "$out1/history.jsonl" "$out/history.jsonl"
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst 302 http://pkg-containers.githubusercontent.com/x
rc=0
collect "$out" "$((NOW + 3600))" || rc=$?
check "a second run measures and exits 0" 0 "$rc" "$RP"
check "worker: two failed runs in a row, failing since the first" "false 2 2026-10-14T03:00:00Z" \
  "$(q '.worker | "\(.ok) \(.failed_runs) \(.failing_since)"')" "jq .worker OUT/status.json"
check "worker: two failed runs an hour apart are down" "3600 true" \
  "$(q '.worker | "\(.failing_seconds) \(.down)"')" "jq .worker OUT/status.json"
check "worker: a 302 to http fails: the Location must be https" \
  "302 to 'pkg-containers.githubusercontent.com', not to an https URL" \
  "$(q '.targets[] | select(.target == "x86_64-extra") | .worker.package.error')" "jq .targets OUT/status.json"
check "history.jsonl has two lines after two runs" 2 "$(awk 'END { print NR }' "$out/history.jsonl")" "wc -l OUT/history.jsonl"

# A third run: the Worker passes again, and the count starts from 0.
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst
rc=0
collect "$out" "$((NOW + 7200))" || rc=$?
check "worker: a run that passes clears the count" "true 0 null false" \
  "$(q '.worker | "\(.ok) \(.failed_runs) \(.failing_since) \(.down)"')" "jq .worker OUT/status.json"

# sync.yml starts a status run when it ends, so the :47 run can follow it
# within minutes. Two failed runs 7 minutes apart are not yet down.
out="$work/run2b"
mkdir -p "$out"
cp "$out1/history.jsonl" "$out/history.jsonl"
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst 503 ''
rc=0
collect "$out" "$((NOW + 420))" || rc=$?
check "worker: two failed runs 7 minutes apart are not down; down needs 50 minutes" "false 2 420 false" \
  "$(q '.worker | "\(.ok) \(.failed_runs) \(.failing_seconds) \(.down)"')" "jq .worker OUT/status.json"
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst

# The Worker answers 302, and the blob host refuses the signed URL to any
# other client than the Worker: every download through the Worker fails.
mkdir -p "$net/pkg-containers.githubusercontent.com/bound"
printf '403\n' > "$net/pkg-containers.githubusercontent.com/bound/acl.code"
redirect x86_64/core/acl-2.3.2-1-x86_64.pkg.tar.zst 302 'https://pkg-containers.githubusercontent.com/bound/acl?sip=104.16.0.1'
out="$work/run-bound"
mkdir -p "$out"
rc=0
collect "$out" || rc=$?
check "worker: a signed URL that answers 403 to the runner fails the probe, whatever the 302 looks like" \
  "0 302 403 false the signed URL answered 403 false" \
  "$rc $(q '.targets[] | select(.target == "x86_64-core") | .worker.package | "\(.code) \(.signed_code) \(.ok) \(.error)"') $(q .worker.ok)" \
  "$RP; jq '.targets[].worker' OUT/status.json"
rc=0
collect "$out" "$((NOW + 3600))" || rc=$?
check "worker: a signed URL that answers 403 in 2 runs an hour apart is down" "0 true" "$rc $(q .worker.down)" \
  "$RP, twice; jq .worker OUT/status.json"
if grep -q 'the signed URL answered 403' "$out/worker.md" && grep -q -- '-r 0-0' "$out/worker.md"; then
  ok "worker.md names the signed URL that failed, and how to ask it for one byte"
else
  fail "worker.md names the signed URL that failed, and how to ask it for one byte" "$(sed -n 1,30p "$out/worker.md")" "cat OUT/worker.md"
fi
redirect x86_64/core/acl-2.3.2-1-x86_64.pkg.tar.zst

# A blob host outside githubusercontent.com whose signed URL works: it is
# recorded, and passes. The database through it is the one latest names.
mkdir -p "$net/blobs.other.test"
cp "$net/up.test/x86_64/core/core.db" "$net/blobs.other.test/core.db"
cp "$work/extra-mirror.db" "$net/blobs.other.test/extra.db"
redirect x86_64/core/core.db 302 https://blobs.other.test/core.db
redirect x86_64/extra/extra.db 302 https://blobs.other.test/extra.db
out="$work/run-other"
mkdir -p "$out"
rc=0
collect "$out" || rc=$?
check "worker: a working blob host outside githubusercontent.com passes, marked location_unexpected" \
  "0 true true blobs.other.test" \
  "$rc $(q '.targets[] | select(.target == "x86_64-core") | .worker.db | "\(.ok) \(.location_unexpected) \(.location)"')" \
  "$RP; jq '.targets[].worker.db' OUT/status.json"
check "worker: the download through that host is the database latest names" "true" \
  "$(q '[.targets[] | .worker.download | select(. != null)] | .[0].ok')" "$RP; jq '.targets[].worker.download' OUT/status.json"

# The Worker redirects each database to other bytes: each one-byte probe
# passes, and the download does not.
printf 'not a database\n' > "$net/blobs.other.test/core.db"
printf 'not a database\n' > "$net/blobs.other.test/extra.db"
out="$work/run-wrong"
mkdir -p "$out"
rc=0
collect "$out" || rc=$?
check "worker: a database through the Worker that is not the one latest names fails the download probe" \
  "0 false true false" \
  "$rc $(q '[.targets[] | .worker.download | select(. != null)] | .[0] | "\(.ok) \(.error | startswith("the file has sha256"))"') $(q .worker.ok)" \
  "$RP; jq '.targets[].worker.download' OUT/status.json"
redirect x86_64/core/core.db 302 "$(blob_url "$net/up.test/x86_64/core/core.db")"
redirect x86_64/extra/extra.db 302 "$(blob_url "$work/extra-mirror.db")"

# The median answer time of the Worker leaves the download out: it moves a
# whole file. The 7 probes take 0.1 to 0.7 s, the download 9 s.
i=0
for p in x86_64/core/core.db x86_64/core/acl-2.3.2-1-x86_64.pkg.tar.zst x86_64/extra/extra.db \
  x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst aarch64/core/core.db loong64/core/core.db x86_64/multilib/multilib.db; do
  i=$((i + 1))
  mkdir -p "$(dirname "$net/worker.test/$p")"
  printf '0.%s\n' "$i" > "$net/worker.test/$p.time"
done
for f in "$net/up.test/x86_64/core/core.db" "$work/extra-mirror.db"; do
  printf '9\n' > "$blobs/sha256:$(sha256sum "$f" | cut -d ' ' -f 1).time"
done
out="$work/run-median"
mkdir -p "$out"
rc=0
collect "$out" || rc=$?
check "worker: the median answer time is of the 7 probes, 0.4 s; the 9 s download is left out" "0 8 0.4 400" \
  "$rc $(q '"\(.worker.probes) \(.worker.median_seconds)"') $(jq -r '.w.ms' "$out/history.jsonl")" \
  "$RP; jq '.worker, [.targets[].worker[] | select(. != null) | .seconds]' OUT/status.json"
find "$net/worker.test" "$blobs" -name '*.time' -exec rm -f {} +

# History is cut to the last 2000 lines, the new line last.
out="$work/run3"
mkdir -p "$out"
awk 'BEGIN { for (i = 1; i <= 2005; i++) printf "{\"t\":\"2026-09-01T00:00:00Z\",\"w\":{\"f\":0},\"i\":%d}\n", i }' > "$out/history.jsonl"
rc=0
collect "$out" || rc=$?
check "history keeps the last 2000 lines" 2000 "$(awk 'END { print NR }' "$out/history.jsonl")" "wc -l OUT/history.jsonl"
check "the oldest lines go first and the new one is last" "7 2026-10-14T03:00:00Z" \
  "$(jq -rs '"\(.[0].i) \(.[-1].t)"' "$out/history.jsonl")" "sed -n '1p;\$p' OUT/history.jsonl"

# A last line that does not read is named, and the count starts again.
out="$work/run4"
mkdir -p "$out"
printf '{"t":"2026-10-14T02:00:00Z","w":{"f":5,"s":"2026-10-13T00:00:00Z"}}\nnot json\n' > "$out/history.jsonl"
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst 503 ''
rc=0
collect "$out" || rc=$?
check "a history line that does not read does not stop the collect" 0 "$rc" "$RP"
check "and the failure count starts again from it" 1 "$(q .worker.failed_runs)" "jq .worker OUT/status.json"
if grep -q 'history.jsonl does not read' "$out.err"; then
  ok "the line that does not read is named on stderr"
else
  fail "the line that does not read is named on stderr" "$(sed -n 1,20p "$out.err")" "$RP"
fi
redirect x86_64/extra/alpha-1-1-x86_64.pkg.tar.zst

# The registry answers 503 for x86_64-extra's latest. Its coverage is not
# measured: the sums say over which targets they are, and the history keeps
# its last measured files.
out="$work/run5"
mkdir -p "$out"
cp "$out1/history.jsonl" "$out/history.jsonl"
printf '503\n' > "$net/ghcr.io/v2/test/mirror/x86_64/extra/manifests/latest.code"
rc=0
collect "$out" "$((NOW + 3600))" || rc=$?
rm "$net/ghcr.io/v2/test/mirror/x86_64/extra/manifests/latest.code"
check "a registry that answers 503 for one target: the collect measures and exits 0" 0 "$rc" "$RP"
check "x86_64-extra: latest answers 503: mirror state error, coverage unknown" "error null" \
  "$(q '.targets[] | select(.target == "x86_64-extra") | "\(.mirror.state) \(.coverage)"')" "jq .targets OUT/status.json"
check "summary: 1 promoted, 3 measured, 1 not read from the registry, 4 of 8 files" "1 3 1 4 8" \
  "$(q '.summary | "\(.promoted) \(.measured) \(.mirror_unread) \(.mirrored_files) \(.upstream_files)"')" "jq .summary OUT/status.json"
check "history: x86_64-extra keeps its last measured files, marked carried" "5 3 1500 600 1" \
  "$(jq -rs '.[-1].x["x86_64-extra"] | "\(.n) \(.m) \(.b) \(.mb) \(.k)"' "$out/history.jsonl")" "tail -n 1 OUT/history.jsonl | jq ."
check "history: a measured target is not marked carried" "4 4 null" \
  "$(jq -rs '.[-1].x["x86_64-core"] | "\(.n) \(.m) \(.k)"' "$out/history.jsonl")" "tail -n 1 OUT/history.jsonl | jq ."
check "history: a target never measured stays unknown" "null null null" \
  "$(jq -rs '.[-1].x["x86_64-multilib"] | "\(.n) \(.m) \(.k)"' "$out/history.jsonl")" "tail -n 1 OUT/history.jsonl | jq ."

# GHCR does not resolve: no target's registry reads. Nothing says a target
# is not mirrored, and no sum is 0.
out="$work/run6"
mkdir -p "$out"
cp "$out1/history.jsonl" "$out/history.jsonl"
mv "$net/ghcr.io" "$net/ghcr.io.off"
rc=0
collect "$out" "$((NOW + 3600))" || rc=$?
mv "$net/ghcr.io.off" "$net/ghcr.io"
check "a registry that does not resolve: the collect measures and exits 0" 0 "$rc" "$RP"
check "summary: no registry read: 0 promoted, 5 not read, 0 measured, every sum unknown" "0 5 0 null null null null null" \
  "$(q '.summary | "\(.promoted) \(.mirror_unread) \(.measured) \(.mirrored_files) \(.upstream_files) \(.mirrored_bytes) \(.upstream_bytes) \(.coverage_files)"')" \
  "jq .summary OUT/status.json"
check "summary: no registry read: last_synced is unknown" null "$(q .summary.last_synced)" "jq .summary OUT/status.json"

# No latest names a created time: the newest fetched time counts. Here
# x86_64-core was fetched at 00:20 and x86_64-extra at 00:00.
out="$work/run7"
mkdir -p "$out"
mirror x86_64 core "$net/up.test/x86_64/core/core.db" 2026-10-14T00:20:00Z
rc=0
collect "$out" || rc=$?
mirror x86_64 core "$net/up.test/x86_64/core/core.db" 2026-10-14T00:00:00Z 2026-10-14T00:30:00.123456Z
check "no latest names a created time: the collect measures and exits 0" 0 "$rc" "$RP"
check "no latest names a created time: last_synced falls back to the newest fetched time" \
  "2026-10-14T00:20:00Z null" "$(q '"\(.summary.last_synced) \([.targets[].mirror.created | select(. != null)] | first)"')" \
  "jq '.summary, [.targets[].mirror]' OUT/status.json"

#---------------------------------------------------------------------------#
# check-staleness: a target with no latest is new while git says its file is
# younger than the tolerance, and stale after, or when git cannot say
#---------------------------------------------------------------------------#
if ! command -v git > /dev/null; then
  ok "skipped: the new verdict of check-staleness, because git is not on PATH"
else
  srepo="$work/stale-repo"
  mkdir -p "$srepo/targets"
  git -C "$srepo" init --quiet
  add_target() {
    # shellcheck disable=SC2016 # the target file's own placeholders
    printf 'arch = %s\nrepo = core\ndb_server = https://up.test/$arch/$repo\n' "$1" > "$srepo/targets/$1-core.conf"
    git -C "$srepo" add "targets/$1-core.conf"
    GIT_AUTHOR_DATE="$2T12:00:00Z" GIT_COMMITTER_DATE="$2T12:00:00Z" \
      git -C "$srepo" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "add $1-core"
  }
  add_target aarch64 2026-10-01
  add_target loong64 2026-10-13
  # riscv64-core: added with enabled = no long ago, enabled one day ago. Its
  # grace starts when it is enabled.
  mkdir -p "$net/up.test/riscv64/core"
  cp "$net/up.test/aarch64/core/core.db" "$net/up.test/riscv64/core/core.db"
  # shellcheck disable=SC2016 # the target file's own placeholders
  printf 'arch = riscv64\nrepo = core\ndb_server = https://up.test/$arch/$repo\nenabled = no\n' > "$srepo/targets/riscv64-core.conf"
  git -C "$srepo" add targets/riscv64-core.conf
  GIT_AUTHOR_DATE="2026-09-01T12:00:00Z" GIT_COMMITTER_DATE="2026-09-01T12:00:00Z" \
    git -C "$srepo" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "add riscv64-core, disabled"
  # shellcheck disable=SC2016 # the target file's own placeholders
  printf 'arch = riscv64\nrepo = core\ndb_server = https://up.test/$arch/$repo\n' > "$srepo/targets/riscv64-core.conf"
  git -C "$srepo" add targets/riscv64-core.conf
  GIT_AUTHOR_DATE="2026-10-13T12:00:00Z" GIT_COMMITTER_DATE="2026-10-13T12:00:00Z" \
    git -C "$srepo" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "enable riscv64-core"
  staleness() {
    local rc=0
    PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" TARGETS_DIR="$2" MIRROR_NAMESPACE=test/mirror \
      MIRROR_REGISTRY=ghcr.io MIRROR_NOW="$NOW" \
      "$REPO_ROOT/scripts/check-staleness" "$1" > "$1.out" 2> "$1.err" || rc=$?
    return "$rc"
  }
  RS="PATH=<fake-curl>:\$PATH TARGETS_DIR=<git repo>/targets scripts/check-staleness OUT"
  rc=0
  staleness "$work/stale1" "$srepo/targets" || rc=$?
  check "check-staleness: one target stale, so exit 3" 3 "$rc" "$RS; $(sed -n '$p' "$work/stale1.err")"
  check "check-staleness: no latest, added 13 days ago, tolerance 3: stale" stale \
    "$(cat "$work/stale1/aarch64-core.state")" "$RS"
  check "check-staleness: no latest, added 1 day ago, tolerance 3: new" new \
    "$(cat "$work/stale1/loong64-core.state")" "$RS"
  check "check-staleness: no latest, added disabled 43 days ago, enabled 1 day ago: new" new \
    "$(cat "$work/stale1/riscv64-core.state")" "$RS; git -C <repo> log -- targets/riscv64-core.conf"
  if grep -q '| target file added or enabled | 2026-10-01 |' "$work/stale1/aarch64-core.md"; then
    ok "check-staleness: the issue body says when the target was added"
  else
    fail "check-staleness: the issue body says when the target was added" \
      "$(sed -n 1,20p "$work/stale1/aarch64-core.md")" "$RS"
  fi
  git clone --quiet --depth 1 "file://$srepo" "$work/stale-shallow"
  rc=0
  staleness "$work/stale2" "$work/stale-shallow/targets" || rc=$?
  check "check-staleness: in a shallow clone the age is unknown, so stale, never new" "3 stale" \
    "$rc $(cat "$work/stale2/loong64-core.state")" "git clone --depth 1 ...; $RS"
  if grep -q 'shallow' "$work/stale2.err"; then
    ok "check-staleness: says that the clone is shallow"
  else
    fail "check-staleness: says that the clone is shallow" "$(sed -n 1,20p "$work/stale2.err")" "$RS"
  fi
fi

#---------------------------------------------------------------------------#
# Upstream is never only the first db_server that answers.
#   aarch64-lag   the first db_server serves database A, the second B, in
#                 which alpha was built a day later. latest is A, fetched 5
#                 days before now. A is behind B: the target is stale.
#   aarch64-html  the first db_server answers 200 with an HTML page, the
#                 second serves B, which latest holds: the target is current.
#---------------------------------------------------------------------------#
pkg "$work/beh-a" alpha 1-1 aarch64 100 "$B"
pkg "$work/beh-a" beta 1-1 aarch64 200 "$B"
pkg "$work/beh-b" alpha 1-2 aarch64 100 "$((B + 86400))"
pkg "$work/beh-b" beta 1-1 aarch64 200 "$B"
mkdir -p "$net/lag.test/aarch64/lag" "$net/new.test/aarch64/lag" "$net/new.test/aarch64/html" \
  "$net/html.test/aarch64/html" "$work/behind-targets"
mkdb "$work/beh-a" "$net/lag.test/aarch64/lag/lag.db"
mkdb "$work/beh-b" "$net/new.test/aarch64/lag/lag.db"
cp "$net/new.test/aarch64/lag/lag.db" "$net/new.test/aarch64/html/html.db"
printf '<html><body>This mirror is down for maintenance.</body></html>\n' > "$net/html.test/aarch64/html/html.db"
mirror aarch64 lag "$net/lag.test/aarch64/lag/lag.db" 2026-10-09T03:00:00Z
mirror aarch64 html "$net/new.test/aarch64/html/html.db" 2026-10-09T03:00:00Z
# shellcheck disable=SC2016 # the target file's own placeholders
{
  printf 'arch = aarch64\nrepo = lag\ndb_server = https://lag.test/$arch/$repo\ndb_server = https://new.test/$arch/$repo\n' \
    > "$work/behind-targets/aarch64-lag.conf"
  printf 'arch = aarch64\nrepo = html\ndb_server = https://html.test/$arch/$repo\ndb_server = https://new.test/$arch/$repo\n' \
    > "$work/behind-targets/aarch64-html.conf"
}
sha_b="$(sha256sum "$net/new.test/aarch64/lag/lag.db" | cut -d ' ' -f 1)"
RU="PATH=<fake-curl>:\$PATH TARGETS_DIR=<aarch64-lag, aarch64-html> MIRROR_NOW=$NOW"

rc=0
PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" TARGETS_DIR="$work/behind-targets" MIRROR_NAMESPACE=test/mirror \
  MIRROR_REGISTRY=ghcr.io MIRROR_NOW="$NOW" \
  "$REPO_ROOT/scripts/check-staleness" "$work/behind1" > "$work/behind1.out" 2> "$work/behind1.err" || rc=$?
touch "$work/behind1/aarch64-lag.state" "$work/behind1/aarch64-html.state" "$work/behind1/aarch64-lag.md"
check "check-staleness: a first db_server behind the second does not stand for upstream: stale, exit 3" \
  "3 stale" "$rc $(cat "$work/behind1/aarch64-lag.state")" "$RU scripts/check-staleness OUT; $(sed -n '$p' "$work/behind1.err")"
if grep -q '| https://lag.test/aarch64/lag | behind by 1 package(s), against https://new.test/aarch64/lag |' "$work/behind1/aarch64-lag.md"; then
  ok "check-staleness: the issue body names the db_server that is behind"
else
  fail "check-staleness: the issue body names the db_server that is behind" "$(sed -n 1,30p "$work/behind1/aarch64-lag.md")" \
    "$RU scripts/check-staleness OUT"
fi
check "check-staleness: an HTML page that answers 200 is refused, and the second db_server shows latest is current" \
  current "$(cat "$work/behind1/aarch64-html.state")" "$RU scripts/check-staleness OUT; $(grep html.test "$work/behind1.err" | sed -n 1p)"
if grep -q 'refused the database from https://html.test/aarch64/html' "$work/behind1.err"; then
  ok "check-staleness: the log names the db_server whose answer was refused"
else
  fail "check-staleness: the log names the db_server whose answer was refused" "$(sed -n 1,20p "$work/behind1.err")" \
    "$RU scripts/check-staleness OUT"
fi

rc=0
PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" TARGETS_DIR="$work/behind-targets" MIRROR_NAMESPACE=test/mirror \
  MIRROR_REGISTRY=ghcr.io GITHUB_REPOSITORY=test/mirror STATUS_WORKER_URL='' MIRROR_NOW="$NOW" \
  "$REPO_ROOT/scripts/status-collect" "$work/behind2" > "$work/behind2.out" 2> "$work/behind2.err" || rc=$?
touch "$work/behind2/status.json"
T='.targets[] | select(.target == "aarch64-lag") | .upstream'
check "status-collect: upstream is the second db_server when the first is behind it, and tried names the first as behind" \
  "0 $sha_b https://new.test/aarch64/lag behind by 1 package(s), against https://new.test/aarch64/lag|ok" \
  "$rc $(jq -r "$T"' | "\(.sha256) \(.server) \([.tried[].result] | join("|"))"' "$work/behind2/status.json")" \
  "$RU scripts/status-collect OUT; jq '$T' OUT/status.json"
T='.targets[] | select(.target == "aarch64-html") | .upstream'
check "status-collect: an HTML page that answers 200 is refused, and named in tried" \
  "$sha_b https://new.test/aarch64/html true" \
  "$(jq -r "$T"' | "\(.sha256) \(.server) \(.tried[0].result | startswith("refused: "))"' "$work/behind2/status.json")" \
  "$RU scripts/status-collect OUT; jq '$T' OUT/status.json"

#---------------------------------------------------------------------------#
# check-staleness within STALENESS_BUDGET: 8 targets whose first db_server
# accepts and never answers, as one stalled host of Arch Linux ARM does for
# 8 targets. Each read without a deadline of its own costs 184 s there.
#---------------------------------------------------------------------------#
real_curl="$(command -v curl)"
if ! command -v python3 > /dev/null; then
  ok "skipped: check-staleness against a db_server that never answers, because python3 is not on PATH"
elif listen stall-a && [ -n "$port" ]; then
  mkdir -p "$work/stall-targets"
  for i in 1 2 3 4 5 6 7 8; do
    mkdir -p "$net/up.test/aarch64/s$i"
    cp "$net/up.test/aarch64/core/core.db" "$net/up.test/aarch64/s$i/s$i.db"
    # shellcheck disable=SC2016 # the target file's own placeholders
    printf 'arch = aarch64\nrepo = s%s\ndb_server = http://127.0.0.1:%s/$arch/$repo\ndb_server = https://up.test/$arch/$repo\n' \
      "$i" "$port" > "$work/stall-targets/aarch64-s$i.conf"
  done
  RB="PATH=<fake-curl>:\$PATH FAKE_CURL_REAL=<curl> STALENESS_BUDGET=80 UPSTREAM_PROTO='=http,https' TARGETS_DIR=<8 targets> timeout 120 scripts/check-staleness OUT"
  start="$SECONDS"
  rc=0
  PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" FAKE_CURL_REAL="$real_curl" TARGETS_DIR="$work/stall-targets" \
    MIRROR_NAMESPACE=test/mirror MIRROR_REGISTRY=ghcr.io MIRROR_NOW="$NOW" STALENESS_BUDGET=80 \
    UPSTREAM_PROTO='=http,https' timeout 120 "$REPO_ROOT/scripts/check-staleness" "$work/stall1" \
    > "$work/stall1.out" 2> "$work/stall1.err" || rc=$?
  took=$((SECONDS - start))
  check "check-staleness: a db_server that never answers: the check ends by itself, 3 for stale targets" 3 "$rc" \
    "$RB; $(sed -n '$p' "$work/stall1.err")"
  if [ "$took" -le 80 ]; then
    ok "check-staleness: a db_server that never answers: the check ends within STALENESS_BUDGET (${took}s of 80s)"
  else
    fail "check-staleness: a db_server that never answers: the check ends within STALENESS_BUDGET" "it took ${took}s" "$RB"
  fi
  check "check-staleness: a db_server that never answers: every target has a state" 8 \
    "$(find "$work/stall1" -name '*.state' | awk 'END { print NR + 0 }')" "$RB; ls OUT"
  check "check-staleness: a db_server that never answers is asked once in the run, not once per target" 1 \
    "$(awk 'END { print NR + 0 }' "$work/stall-a.log")" "$RB; count the listener's connections"
  mkdir -p "$work/stall1"
  touch "$work/stall1/aarch64-s1.md" "$work/stall1/aarch64-s2.md"
  if grep -q "127.0.0.1:$port/aarch64/s1 | curl [0-9]*: no whole answer within" "$work/stall1/aarch64-s1.md" &&
    grep -q "127.0.0.1:$port/aarch64/s2 | not asked" "$work/stall1/aarch64-s2.md"; then
    ok "check-staleness: the issue body names the db_server that did not answer, and that later targets did not ask it"
  else
    fail "check-staleness: the issue body names the db_server that did not answer, and that later targets did not ask it" \
      "aarch64-s1.md: $(sed -n 1,30p "$work/stall1/aarch64-s1.md")" "aarch64-s2.md: $(grep -c 127.0.0.1 "$work/stall1/aarch64-s2.md")" "$RB"
  fi
else
  fail "check-staleness against a db_server that never answers: the local listener starts" "no port in $work/stall-a.port" \
    "reproduce: python3 -I listen.py LOG PORTFILE (this file)"
fi

#---------------------------------------------------------------------------#
# status-collect within STATUS_BUDGET: the same 8 targets, against a
# listener of its own. With no time left for a read, a target is a
# measurement whose upstream.error names STATUS_BUDGET.
#---------------------------------------------------------------------------#
if ! command -v python3 > /dev/null; then
  ok "skipped: status-collect against a db_server that never answers, because python3 is not on PATH"
elif listen stall-b && [ -n "$port" ]; then
  mkdir -p "$work/stall-targets-b"
  for i in 1 2 3 4 5 6 7 8; do
    mkdir -p "$net/up.test/aarch64/s$i"
    cp "$net/up.test/aarch64/core/core.db" "$net/up.test/aarch64/s$i/s$i.db"
    # shellcheck disable=SC2016 # the target file's own placeholders
    printf 'arch = aarch64\nrepo = s%s\ndb_server = http://127.0.0.1:%s/$arch/$repo\ndb_server = https://up.test/$arch/$repo\n' \
      "$i" "$port" > "$work/stall-targets-b/aarch64-s$i.conf"
  done
  # stall_collect OUT BUDGET -> status-collect's status, under timeout 120
  stall_collect() {
    local rc=0
    mkdir -p "$1"
    PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" FAKE_CURL_REAL="$real_curl" TARGETS_DIR="$work/stall-targets-b" \
      MIRROR_NAMESPACE=test/mirror MIRROR_REGISTRY=ghcr.io GITHUB_REPOSITORY=test/mirror STATUS_WORKER_URL='' \
      MIRROR_NOW="$NOW" STATUS_BUDGET="$2" UPSTREAM_PROTO='=http,https' \
      timeout 120 "$REPO_ROOT/scripts/status-collect" "$1" > "$1.out" 2> "$1.err" || rc=$?
    return "$rc"
  }
  RSC="PATH=<fake-curl>:\$PATH FAKE_CURL_REAL=<curl> STATUS_BUDGET=80 UPSTREAM_PROTO='=http,https' TARGETS_DIR=<8 targets> timeout 120 scripts/status-collect OUT"
  start="$SECONDS"
  rc=0
  stall_collect "$work/stall2" 80 || rc=$?
  took=$((SECONDS - start))
  check "status-collect: a db_server that never answers: the collect ends by itself and exits 0" 0 "$rc" \
    "$RSC; $(sed -n '$p' "$work/stall2.err")"
  if [ "$took" -le 80 ]; then
    ok "status-collect: a db_server that never answers: the collect ends within STATUS_BUDGET (${took}s of 80s)"
  else
    fail "status-collect: a db_server that never answers: the collect ends within STATUS_BUDGET" "it took ${took}s" "$RSC"
  fi
  touch "$work/stall2/status.json"
  check "status-collect: a db_server that never answers: every target is read from the second db_server" \
    "8 8 https://up.test/aarch64/s1" \
    "$(jq -r '"\(.targets | length) \([.targets[] | select(.upstream.ok)] | length) \(.targets[0].upstream.server)"' "$work/stall2/status.json")" \
    "$RSC; jq '.targets[].upstream' OUT/status.json"
  check "status-collect: a db_server that never answers is asked once in the run, not once per target" 1 \
    "$(awk 'END { print NR + 0 }' "$work/stall-b.log")" "$RSC; count the listener's connections"
  check "status-collect: upstream.tried names the stalled db_server, then that later targets did not ask it" \
    "true true" \
    "$(jq -r '[(.targets[0].upstream.tried[0].result | test("^curl [0-9]+: no whole answer within")),
               (.targets[1].upstream.tried[0].result | startswith("not asked"))] | map(tostring) | join(" ")' "$work/stall2/status.json")" \
    "$RSC; jq '.targets[].upstream.tried' OUT/status.json"
  rc=0
  stall_collect "$work/stall3" 1 || rc=$?
  touch "$work/stall3/status.json"
  check "status-collect: no time left for a read: each target is measured, with an upstream.error that names STATUS_BUDGET" \
    "0 8 8" \
    "$rc $(jq -r '"\(.targets | length) \([.targets[] | select(.upstream.ok == false and (.upstream.error // "" | contains("STATUS_BUDGET")))] | length)"' "$work/stall3/status.json")" \
    "STATUS_BUDGET=1 ${RSC#*STATUS_BUDGET=80 }; jq '.targets[].upstream.error' OUT/status.json"
  check "status-collect: no time left for a read: no request reaches the stalled db_server" 1 \
    "$(awk 'END { print NR + 0 }' "$work/stall-b.log")" "STATUS_BUDGET=1 ${RSC#*STATUS_BUDGET=80 }"
else
  fail "status-collect against a db_server that never answers: the local listener starts" "no port in $work/stall-b.port" \
    "reproduce: python3 -I listen.py LOG PORTFILE (this file)"
fi

#---------------------------------------------------------------------------#
# status-render
#---------------------------------------------------------------------------#
if ! command -v python3 > /dev/null; then
  ok "skipped: status-render, because python3 is not on PATH"
  summary
  exit $?
fi

in="$work/render-in"
mkdir -p "$in"
cp "$work/run1/status.json" "$in/status.json"
cp "$REPO_ROOT/tests/fixtures/status/bench.json" "$in/bench.json"
# 30 days of history at 6 hour steps, ending at the collect time
jq -nc --argjson end "$NOW" '
  range(119; -1; -1) as $i | ($end - $i * 21600) as $t
  | {t: ($t | todate), w: {ok: true, f: 0, s: null, ms: 140}, g: {ms: 400},
     x: {"x86_64-core": {n: 4, m: 4, b: 1000, mb: 1000, a: (3600 + ($i % 3) * 3600), l: 0, c: 1},
         "x86_64-extra": {n: 5, m: ([3, ((119 - $i) / 30 | floor)] | min), b: 1500, mb: 600, a: 10800, l: 3600, c: 0},
         "aarch64-core": {n: 2, m: 0, b: 3000, mb: 0, a: null, l: null, c: 0}}}' > "$in/history.jsonl"

cat > "$work/check.py" << 'EOF'
import json, os, re, sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

site, spec = sys.argv[1], json.loads(sys.argv[2])


def say(ok, desc, detail=""):
    print("%s\t%s\t%s" % ("PASS" if ok else "FAIL", desc, detail.replace("\n", " ")))


def texts(path):
    root = ET.parse(path).getroot()
    return " ".join("".join(e.itertext()) for e in root.iter() if e.tag.endswith("}text"))


missing = [f for f in spec["files"] if not os.path.isfile(os.path.join(site, f))]
say(not missing, "every page, chart, badge and data file is written", " ".join(missing))

bad = []
svgs = 0
for d in ("charts", "badges"):
    for dirpath, _, names in os.walk(os.path.join(site, d)):
        for f in sorted(names):
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, site)
            svgs += 1
            try:
                root = ET.parse(p).getroot()
            except ET.ParseError as e:
                bad.append("%s: %s" % (rel, e))
                continue
            if not root.tag.endswith("}svg"):
                bad.append("%s: the root is %s" % (rel, root.tag))
            if not any(e.tag.endswith("}title") and "".join(e.itertext()).strip() for e in root):
                bad.append("%s: no title" % rel)
            style = " ".join("".join(e.itertext()) for e in root.iter() if e.tag.endswith("}style"))
            if "prefers-color-scheme:dark" not in style.replace(" ", ""):
                bad.append("%s: no dark style" % rel)
say(not bad and svgs == spec["svgs"],
    "all %d SVG files parse as XML, each with a title and its own dark style" % spec["svgs"],
    "found %d; %s" % (svgs, "; ".join(bad)))

for name, words in sorted(spec["badges"].items()):
    p = os.path.join(site, "badges", name + ".svg")
    try:
        t = texts(p)
    except (OSError, ET.ParseError) as e:
        say(False, "badge %s carries its text" % name, str(e))
        continue
    lost = [w for w in words if w not in t]
    say(not lost, "badge %s carries its text: %s" % (name, " | ".join(words)), "text: %s; not found: %s" % (t, lost))

for name, words in sorted(spec.get("badges_without", {}).items()):
    try:
        t = texts(os.path.join(site, "badges", name + ".svg"))
    except (OSError, ET.ParseError) as e:
        say(False, "badge %s does not say %s" % (name, " | ".join(words)), str(e))
        continue
    seen = [w for w in words if w in t]
    say(not seen, "badge %s does not say %s" % (name, " | ".join(words)), "text: %s; found: %s" % (t, seen))

for name, words in sorted(spec.get("chart_text", {}).items()):
    try:
        t = texts(os.path.join(site, "charts", name + ".svg"))
    except (OSError, ET.ParseError) as e:
        say(False, "chart %s shows %s" % (name, ", ".join(words)), str(e))
        continue
    lost = [w for w in words if w not in t]
    say(not lost, "chart %s shows %s" % (name, ", ".join(words)), "not found: %s" % lost)


class Refs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = set()
        self.text = []

    def handle_starttag(self, tag, attrs):
        for k, v in attrs:
            if k in ("src", "href", "srcset") and v and "://" not in v and not v.startswith("#"):
                self.refs.add(v)

    def handle_data(self, data):
        self.text.append(data)


r = Refs()
with open(os.path.join(site, "index.html"), encoding="utf-8") as f:
    r.feed(f.read())
page_text = " ".join(" ".join(r.text).split())
for words in spec.get("page_text", []):
    say(words in page_text, "index.html says: %s" % words, "not found in the page text")
want = (["charts/%s.svg" % c for c in spec["charts"]] + ["charts/narrow/%s.svg" % c for c in spec["charts"]]
        + ["badges/%s.svg" % b for b in spec["badges"]])
lost = [w for w in want if w not in r.refs]
say(not lost, "index.html references every chart and badge", " ".join(lost))
broken = sorted(x for x in r.refs if not os.path.isfile(os.path.join(site, x)))
say(not broken, "every file index.html references exists", " ".join(broken))

TIME = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}):\d{2}Z$")
LOOSE = re.compile(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}")


class Page(HTMLParser):
    """The <time> elements, the scripts, the event handler attributes, any
    time text outside a <time>, and the rows of the size table."""

    def __init__(self):
        super().__init__()
        self.times, self.scripts, self.handlers, self.loose, self.rows = [], [], [], [], []
        self.time = self.script = self.row = self.cell = None
        self.style = self.in_size = False
        self.section = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.handlers += ["%s=%s" % (k, v) for k, v in attrs if k.startswith("on")
                          or (k in ("href", "src") and (v or "").strip().lower().startswith("javascript:"))]
        if tag == "time":
            self.time = [a.get("datetime"), ""]
        elif tag == "script":
            self.script = [a, ""]
        elif tag == "style":
            self.style = True
        elif tag == "table" and "size" in (a.get("class") or "").split():
            self.in_size = True
        elif self.in_size and tag in ("thead", "tbody", "tfoot"):
            self.section = tag
        elif self.in_size and tag == "tr":
            self.row = {"section": self.section, "attrs": a, "cells": []}
        elif self.row is not None and tag in ("td", "th"):
            self.cell = [a, ""]

    def handle_endtag(self, tag):
        if tag == "time" and self.time is not None:
            self.times.append(tuple(self.time))
            self.time = None
        elif tag == "script" and self.script is not None:
            self.scripts.append(tuple(self.script))
            self.script = None
        elif tag == "style":
            self.style = False
        elif tag == "table":
            self.in_size = False
        elif tag in ("td", "th") and self.cell is not None:
            self.row["cells"].append(tuple(self.cell))
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None

    def handle_data(self, data):
        if self.script is not None:
            self.script[1] += data
            return
        if self.style:
            return
        if self.cell is not None:
            self.cell[1] += data
        if self.time is not None:
            self.time[1] += data
        elif LOOSE.search(data):
            self.loose.append(data.strip())


pg = Page()
with open(os.path.join(site, "index.html"), encoding="utf-8") as f:
    pg.feed(f.read())

bad = []
for dt, text in pg.times:
    m = TIME.match(dt or "")
    if not m:
        bad.append("datetime=%r" % dt)
    elif text != "%s %s UTC" % (m.group(1), m.group(2)):
        bad.append("datetime=%s shows %r" % (dt, text))
say(pg.times and not bad, "every <time> has a datetime ending in Z and shows that time as UTC text",
    "%d <time>; %s" % (len(pg.times), "; ".join(bad)))
say(not pg.loose, "index.html shows no time outside a <time> element", " | ".join(pg.loose))

srcs = [a.get("src") for a, _ in pg.scripts if "src" in a]
say(len(pg.scripts) == 1 and not srcs, "index.html has one script, inline, and no other",
    "%d script(s), src: %s" % (len(pg.scripts), srcs))
code = pg.scripts[0][1] if pg.scripts else ""
lost = [w for w in ('addEventListener("load"', 'querySelectorAll("time[datetime]")', "timeZoneName",
                    ".title =", " h ago") if w not in code]
say(not lost, "the script sets each <time> title to the local time, its time zone and its age, after load",
    "not in the script: %s" % lost)
say(not pg.handlers, "index.html has no event handler attribute and no javascript: URL", " ".join(pg.handlers))

with open(os.path.join(site, "status.json"), encoding="utf-8") as f:
    st = json.load(f)


def side(t, which):
    """What the size table must show for one target: (bytes, files) or None."""
    if which == "mirror":
        m = t.get("mirror") or {}
        if m.get("state") == "absent":
            return 0, 0
        if m.get("state") == "promoted" and isinstance(m.get("bytes"), int):
            return m["bytes"], m["files"]
        return None
    u = t.get("upstream") or {}
    return (u["bytes"], u["files"]) if u.get("ok") is True and isinstance(u.get("bytes"), int) else None


def want(ts):
    out = []
    for which in ("mirror", "upstream"):
        got = [x for x in (side(t, which) for t in ts) if x is not None]
        out += [sum(b for b, _ in got), sum(n for _, n in got)] if got else [None, None]
    return out


def shown(row):
    vals, bad = [], []
    for a, text in row["cells"][1:]:
        k = "data-bytes" if "data-bytes" in a else "data-files"
        v = None if a.get(k) in (None, "") else int(a[k])
        vals.append(v)
        text = text.strip()
        if v is None:
            ok = text == "-"
        elif k == "data-files":
            ok = text == "{:,}".format(v)
        else:
            digits = len(text.split(".")[1]) if "." in text else 0
            ok = abs(float(text) - v / 1073741824) <= 0.5 * 10 ** -digits + 1e-9
        if not ok:
            bad.append("%s=%s shows %r" % (k, v, text))
    return vals, bad


targets = st["targets"]
arches = sorted({t["target"].split("-", 1)[0] for t in targets})
rows_t = {r["attrs"].get("data-target"): r for r in pg.rows if r["attrs"].get("data-target")}
rows_a = {r["attrs"].get("data-arch"): r for r in pg.rows if r["attrs"].get("data-arch")}
rows_f = [r for r in pg.rows if r["section"] == "tfoot"]
lost = [t["target"] for t in targets if t["target"] not in rows_t] + [a for a in arches if a not in rows_a]
say(not lost and len(rows_f) == 1, "the size table has a row per architecture, per repository and one total row",
    "no row for %s; %d total row(s)" % (lost, len(rows_f)))
bad_t, bad_a, bad_s = [], [], []
for t in targets:
    if t["target"] in rows_t:
        vals, b = shown(rows_t[t["target"]])
        bad_s += b
        if vals != want([t]):
            bad_t.append("%s: %s, not %s" % (t["target"], vals, want([t])))
for a in arches:
    if a in rows_a:
        vals, b = shown(rows_a[a])
        bad_s += b
        ts = [t for t in targets if t["target"].split("-", 1)[0] == a]
        if vals != want(ts):
            bad_a.append("%s: %s, not %s" % (a, vals, want(ts)))
total = None
if rows_f:
    total, b = shown(rows_f[0])
    bad_s += b
say(not bad_t, "size table: each repository row holds its target's mirror and upstream bytes and files",
    "; ".join(bad_t))
say(not bad_a, "size table: each architecture row is the sum of its targets", "; ".join(bad_a))
say(total == want(targets), "size table: the total row is the sum of every target",
    "%s, not %s" % (total, want(targets)))
say(not bad_s, "size table: each cell shows its value in GiB or in files", "; ".join(bad_s))

bad = []
for a in arches:
    try:
        t = texts(os.path.join(site, "badges", "size-%s.svg" % a))
    except (OSError, ET.ParseError) as e:
        bad.append("%s: %s" % (a, e))
        continue
    if "%s size" % a not in t:
        bad.append("%s: text %r" % (a, t))
say(not bad, "a size badge for each architecture (%s) parses as XML" % " ".join(arches), "; ".join(bad))

with open(os.path.join(site, "history.json"), encoding="utf-8") as f:
    h = json.load(f)
say(isinstance(h, list) and len(h) == spec["history"], "history.json holds %d point(s)" % spec["history"],
    "found %s" % (len(h) if isinstance(h, list) else type(h).__name__))
with open(os.path.join(site, "bench.json"), encoding="utf-8") as f:
    b = json.load(f)
say(len(b.get("cases", [])) == spec["bench_cases"], "bench.json holds %d case(s)" % spec["bench_cases"],
    "found %d" % len(b.get("cases", [])))
EOF

# render IN SITE SPEC: status-render, then check.py's verdicts as TAP
render() {
  local rc=0 verdict desc detail
  python3 -I "$REPO_ROOT/scripts/status-render" "$1" "$2" > "$2.out" 2> "$2.err" || rc=$?
  check "status-render $(basename "$2") exits 0" 0 "$rc" "python3 -I scripts/status-render IN SITE; $(sed -n 1p "$2.err")"
  [ "$rc" -eq 0 ] || return 0
  rc=0
  python3 -I "$work/check.py" "$2" "$3" > "$2.check" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the site checks run" "$(sed -n 1,20p "$2.check")" "python3 -I check.py SITE SPEC"
    return 0
  fi
  while IFS=$'\t' read -r verdict desc detail; do
    if [ "$verdict" = PASS ]; then
      ok "$(basename "$2"): $desc"
    else
      fail "$(basename "$2"): $desc" "$detail" "python3 -I scripts/status-render IN SITE"
    fi
  done < "$2.check"
}

CHARTS='["coverage","freshness","size","history-coverage","history-age","speed"]'
spec() {
  # spec BENCH_CASES HISTORY SPEED_WORDS [OVERRIDES]: OVERRIDES is merged
  # into the spec, an object at a time; a list in it replaces the list.
  # page_text_more adds to page_text.
  local over="${4:-}"
  [ -n "$over" ] || over='{}'
  jq -nc --argjson charts "$CHARTS" --argjson cases "$1" --argjson history "$2" --argjson speed "$3" \
    --argjson over "$over" '{
    charts: $charts, bench_cases: $cases, history: $history,
    svgs: (($charts | length) * 2 + 15),
    files: (["index.html", "status.json", "history.json", "bench.json"]
            + ($charts | map("charts/\(.).svg")) + ($charts | map("charts/narrow/\(.).svg"))),
    badges: {
      "x86_64-core": ["x86_64-core", "100%", "3.0 h"],
      "x86_64-extra": ["x86_64-extra", "60%", "3.0 h"],
      "x86_64-multilib": ["x86_64-multilib", "not mirrored"],
      "aarch64-core": ["aarch64-core", "not mirrored"],
      "loong64-core": ["loong64-core", "not mirrored"],
      "x86_64": ["x86_64", "77.7%", "3.0 h", "2 of 3 measured"],
      "aarch64": ["aarch64", "not mirrored"],
      "loong64": ["loong64", "not mirrored"],
      "all": ["mirror", "53.8%", "2/5 repos", "4 of 5 measured"],
      "synced": ["synced", "2 h ago"],
      "size": ["size", "2.4 KiB"],
      "size-x86_64": ["x86_64 size", "2.4 KiB"],
      "size-aarch64": ["aarch64 size", "not mirrored"],
      "size-loong64": ["loong64 size", "not mirrored"],
      "speed": $speed},
    badges_without: {"x86_64-core": ["measured"], "speed": ["ago", "date unknown"], "size": ["measured"]},
    chart_text: {
      coverage: ["Coverage by repository", "53.8%", "in 4 of 5 repositories", "x86_64", "aarch64", "loong64", "core", "extra", "multilib", "upstream only"],
      freshness: ["Snapshot age", "3.0 h", "sync every 3 h", "not mirrored yet", "matches upstream"],
      size: ["Size by repository", "GiB", "in 4 of 5 repositories", "x86_64 · 1.6 KiB of 2.4 KiB, 2 of 3 measured",
             "aarch64 · 0 B of 2.9 KiB", "loong64 · 0 B of 2.9 KiB"],
      "history-coverage": ["Coverage, last 30 days", "x86_64", "aarch64", "Time, UTC"],
      "history-age": ["Snapshot age, last 30 days", "sync every 3 h", "log scale"]},
    page_text: ([
      "over the 4 of 5 repositories measured in this run. 1 could not be read.",
      "of 13 upstream, in 4 of 5 repositories",
      "Failed probes in 2 runs in a row, over 50 minutes or more, open the worker-down issue.",
      "Measured 2026-10-14 03:00 UTC", "The mirror last changed at 2026-10-14 00:30 UTC",
      "so the synced badge says 2 h ago.",
      "x86_64-core ok 100% 4 4 0 0.00 3.0 h 2 h ago 0 min 2026-10-14 00:00 UTC",
      "epsilon-1-1-x86_64.pkg.tar.zst 0.00 3.0 h 3 h ago 1.0 h 2026-10-14 00:00 UTC",
      "A sum counts only the repositories read on that side: upstream in 4 of 5.",
      "https://up.test/loong64/core 1 db_server(s) not taken https://down.test/loong64/core : curl 6",
      "pkg-containers.githubusercontent.com hit ok"]
      + ($over.page_text_more // []))}
    * ($over | del(.page_text_more))'
}

render "$in" "$work/site" "$(spec 12 120 '["pacman speed", "oci 13.3 s", "official 15.6 s"]' \
  '{"page_text_more": ["official mirror 15.6 s; measured 2026-10-14"]}')"

# No bench, and a history line that does not read
in2="$work/render-in2"
mkdir -p "$in2"
cp "$in/status.json" "$in2/status.json"
{
  sed -n 1,10p "$in/history.jsonl"
  printf 'not json\n'
} > "$in2/history.jsonl"
render "$in2" "$work/site2" "$(spec 0 10 '["pacman speed", "no data"]')"
if grep -q 'history.jsonl line 11 is not JSON' "$work/site2.err"; then
  ok "a history line that does not read is named by its number"
else
  fail "a history line that does not read is named by its number" "$(cat "$work/site2.err")" "python3 -I scripts/status-render IN SITE"
fi
if grep -q 'No measurement yet' "$work/site2/charts/speed.svg"; then
  ok "with no bench.json the speed chart says so"
else
  fail "with no bench.json the speed chart says so" "$(sed -n 1,5p "$work/site2/charts/speed.svg")" "python3 -I scripts/status-render IN SITE"
fi

# The first run: one history line, in which some targets have no age
in3="$work/render-in3"
mkdir -p "$in3"
cp "$work/run1/status.json" "$work/run1/history.jsonl" "$in3/"
render "$in3" "$work/site3" "$(spec 0 1 '["pacman speed", "no data"]')"

# x86_64-extra's registry answered 503 (run5, an hour after run1): the
# x86_64 and all badges say over how many targets they count, and the
# history keeps x86_64 at 77.7%.
in5="$work/render-in5"
mkdir -p "$in5"
cp "$work/run5/status.json" "$work/run5/history.jsonl" "$in5/"
render "$in5" "$work/site5" "$(spec 0 2 '["pacman speed", "no data"]' '{
  "badges": {
    "x86_64-core": ["x86_64-core", "100%", "4.0 h"],
    "x86_64-extra": ["x86_64-extra", "unknown"],
    "x86_64": ["x86_64", "100%", "4.0 h", "1 of 3 measured"],
    "all": ["mirror", "50%", "1/5 repos", "3 of 5 measured"],
    "synced": ["synced", "3 h ago"],
    "size": ["size", "1000 B", "4 of 5 measured"],
    "size-x86_64": ["x86_64 size", "1000 B", "2 of 3 measured"]},
  "badges_without": {"size": []},
  "chart_text": {
    "coverage": ["Coverage by repository", "50%", "in 3 of 5 repositories", "registry not read"],
    "freshness": ["Snapshot age", "4.0 h", "sync every 3 h", "not mirrored yet", "matches upstream"],
    "size": ["Size by repository", "in 3 of 5 repositories", "x86_64 · 1000 B of 1000 B, 1 of 3 measured"]},
  "page_text": [
    "over the 3 of 5 repositories measured in this run. 2 could not be read.",
    "1 of 4 read", "1 not read from the registry; 1 match upstream now",
    "x86_64 2026-10-14 03:00 UTC 77.7% 77.7%",
    "A sum counts only the repositories read on that side: the mirror in 4 of 5 and upstream in 4 of 5."]}')"

# No registry read at all (run6): every group is unknown, never "not
# mirrored", and no sum reads as 0.
in6="$work/render-in6"
mkdir -p "$in6"
cp "$work/run6/status.json" "$work/run6/history.jsonl" "$in6/"
render "$in6" "$work/site6" "$(spec 0 2 '["pacman speed", "no data"]' '{
  "badges": {
    "x86_64-core": ["x86_64-core", "unknown"], "x86_64-extra": ["x86_64-extra", "unknown"],
    "x86_64-multilib": ["x86_64-multilib", "unknown"], "aarch64-core": ["aarch64-core", "unknown"],
    "loong64-core": ["loong64-core", "unknown"],
    "x86_64": ["x86_64", "unknown"], "aarch64": ["aarch64", "unknown"], "loong64": ["loong64", "unknown"],
    "all": ["mirror", "unknown"], "synced": ["synced", "unknown"], "size": ["size", "unknown"],
    "size-x86_64": ["x86_64 size", "unknown"], "size-aarch64": ["aarch64 size", "unknown"],
    "size-loong64": ["loong64 size", "unknown"]},
  "badges_without": {"x86_64": ["not mirrored"], "all": ["not mirrored"], "size": ["not mirrored"],
                     "size-x86_64": ["not mirrored"]},
  "chart_text": {
    "coverage": ["Coverage by repository", "unknown"],
    "freshness": ["Snapshot age", "none", "sync every 3 h"],
    "size": ["Size by repository", "unknown"]},
  "page_text": [
    "Coverage is not known: no repository could be read on both sides in this run.",
    "the registry did not answer for any of the 5", "Files in the mirror unknown",
    "Size in the mirror unknown"]}')"

# A bench from 2026-08-01, 73 days before the measurement: the badge and the
# tile show its age in the warning colour.
in7="$work/render-in7"
mkdir -p "$in7"
cp "$in/status.json" "$in7/status.json"
jq '.date = "2026-08-01T05:50:00Z"' "$REPO_ROOT/tests/fixtures/status/bench.json" > "$in7/bench.json"
render "$in7" "$work/site7" "$(spec 12 0 '["pacman speed", "oci 13.3 s", "official 15.6 s", "73 d ago"]' '{
  "badges_without": {"speed": []},
  "chart_text": {"speed": ["Measured 2026-08-01 (73 d ago)"],
                 "history-coverage": ["Coverage, last 30 days", "No history yet"]},
  "page_text_more": ["official mirror 15.6 s; measured 2026-08-01 05:50 UTC", "73 d ago"]}')"
if grep -q 'fill:#9a6700' "$work/site7/badges/speed.svg"; then
  ok "site7: a bench older than 2 days gives the speed badge the warning colour"
else
  fail "site7: a bench older than 2 days gives the speed badge the warning colour" \
    "$(sed -n 3,4p "$work/site7/badges/speed.svg")" "python3 -I scripts/status-render IN SITE"
fi

# The synced badge: the age rounded down, green under 6 h, yellow under 24
# h, red after. The colour is the message's light fill.
badge_says() {
  local label fill
  label="$(sed -n 's/.*aria-label="\([^"]*\)".*/\1/p' "$1")"
  fill="$(grep -o '[.]msg{fill:#[0-9a-f]*}' "$1" | awk 'NR == 1 { sub(/^[.]msg[{]fill:/, ""); sub(/[}]$/, ""); print }')"
  printf '%s %s\n' "$label" "$fill"
}
# synced_case NAME FILTER EXPECTED DESC: render run1's status.json through
# the jq FILTER, then read badges/synced.svg
synced_case() {
  local d="$work/$1" rc=0
  mkdir -p "$d"
  jq --argjson now "$NOW" "$2" "$work/run1/status.json" > "$d/status.json"
  python3 -I "$REPO_ROOT/scripts/status-render" "$d" "$d/site" > "$d.out" 2> "$d.err" || rc=$?
  check "$1: status-render exits 0" 0 "$rc" "python3 -I scripts/status-render IN SITE; $(sed -n 1p "$d.err")"
  check "$1: $4" "$3" "$(badge_says "$d/site/badges/synced.svg")" \
    "jq --argjson now $NOW '$2' run1/status.json > IN/status.json; python3 -I scripts/status-render IN SITE"
}
# $now is jq's variable, not shell's.
# shellcheck disable=SC2016
{
  synced_case synced-30m '.summary.last_synced = ($now - 1800 | todate)' "synced: 30 min ago #1a7f37" \
    "30 min ago is green"
  synced_case synced-5h '.summary.last_synced = ($now - 18000 | todate)' "synced: 5 h ago #1a7f37" \
    "5 h ago is green"
  synced_case synced-12h '.summary.last_synced = ($now - 43200 - 3599 | todate)' "synced: 12 h ago #9a6700" \
    "12 h 59 min ago rounds down to 12 h, yellow"
  synced_case synced-30h '.summary.last_synced = ($now - 108000 | todate)' "synced: 1 d ago #cf222e" \
    "30 h ago is 1 d ago, red"
  synced_case synced-fetched 'del(.summary.last_synced) | .targets[].mirror.created = null' \
    "synced: 3 h ago #1a7f37" "a status.json with no created time falls back to the newest fetched time, 3 h ago"
}

# A redirect host outside githubusercontent.com whose signed URL works: the
# probe table says so, in the warning colour, and the probe passes
d="$work/render-other"
mkdir -p "$d"
cp "$work/run-other/status.json" "$d/status.json"
rc=0
python3 -I "$REPO_ROOT/scripts/status-render" "$d" "$d/site" > "$d.out" 2> "$d.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'dot warning" aria-hidden="true"></span>ok, the redirect host is outside \*.githubusercontent.com' "$d/site/index.html"; then
  ok "site: a probe whose redirect host is outside githubusercontent.com is shown as a warning that passes"
else
  fail "site: a probe whose redirect host is outside githubusercontent.com is shown as a warning that passes" \
    "status-render exit $rc; $(sed -n 1p "$d.err")" "cp run-other/status.json IN; python3 -I scripts/status-render IN SITE; grep outside SITE/index.html"
fi

# No status.json: refused, with the path named
rc=0
python3 -I "$REPO_ROOT/scripts/status-render" "$work/empty" "$work/site4" > "$work/site4.out" 2> "$work/site4.err" || rc=$?
check "status-render with no status.json exits 1" 1 "$rc" "python3 -I scripts/status-render EMPTY SITE"
if grep -q 'status.json: no such file' "$work/site4.err"; then
  ok "and names the file it looked for"
else
  fail "and names the file it looked for" "$(cat "$work/site4.err")" "python3 -I scripts/status-render EMPTY SITE"
fi

summary
