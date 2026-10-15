#!/usr/bin/env bash
#
# The fetcher CLI: which client each call picks, the fallback from one client
# to the next, the structural check of the body, and the version resolver.
# Everything runs against a curl stand-in and a faked curl-impersonate, so no
# browser and no network are needed.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

# A copy of the fetchers tree, so the browser clients can be left out and the
# curl-impersonate client replaced by a stand-in.
cp -r "$REPO_ROOT/fetchers" "$work/fetchers"
mkdir -p "$work/fetchers/curl-impersonate"
cat > "$work/fetchers/curl-impersonate/available" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/fetchers/curl-impersonate/fetch.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="$1"
out="$2"
printf '%s\n' "$url" >> "${FAKE_CI_CALLS:?}"
if [ "${FAKE_CI_RC:-0}" -ne 0 ]; then
  exit "${FAKE_CI_RC}"
fi
cp "${FAKE_CI_BODY:?}" "$out"
exit 0
EOF
chmod 0755 "$work/fetchers/curl-impersonate/available" "$work/fetchers/curl-impersonate/fetch.sh"

# The curl stand-in.
mkdir -p "$work/bin" "$work/fakecurl"
cp "$REPO_ROOT/tests/fixtures/fetcher/fake-curl" "$work/bin/curl"
chmod 0755 "$work/bin/curl"
export PATH="$work/bin:$PATH"
export FAKE_CURL_DIR="$work/fakecurl"

# Bodies. The curl stand-in reads its files from FAKE_CURL_DIR, so they live
# there.
mkdir -p "$work/db/p-1"
printf 'p\tp\t1-1\tany\t%s\t10\t1700000000\t\n' "$(printf 'p' | sha256sum | cut -d ' ' -f 1)" > "$work/db/p-1/desc"
(cd "$work/db" && tar -czf "$work/fakecurl/good.db" -- .)
printf 'this is not a tar archive\n' > "$work/fakecurl/notatar"
printf '\x88\x01\x00' > "$work/fakecurl/good.sig"
printf '\x00\x01\x00' > "$work/fakecurl/bad.sig"
printf 'not the file\n' > "$work/fakecurl/nonbody.html"
jq -n '{tag_name: "v9.9.9"}' > "$work/fakecurl/release.json"
good_db="$work/fakecurl/good.db"
: > "$work/ci.calls"

# A database whose desc member comes before a listing far larger than a pipe
# buffer: a reader that stops at the first match would kill tar and fail the
# whole check.
mkdir -p "$work/many/aaa-1" "$work/many/bulk"
printf 'aaa\taaa\t1-1\tany\t%s\t10\t1700000000\t\n' "$(printf 'aaa' | sha256sum | cut -d ' ' -f 1)" > "$work/many/aaa-1/desc"
i=1
while [ "$i" -le 4000 ]; do
  printf 'x\n' > "$work/many/bulk/package-$(printf '%05d' "$i")-1.0.0"
  i=$((i + 1))
done
# aaa-1 first, then bulk, so the aaa-1/desc member is early in the archive.
# No --sort: busybox tar does not take it, and listing the two directories in
# order gives the same early member on GNU tar and on busybox.
(cd "$work/many" && tar -czf "$work/fakecurl/many.db" -- aaa-1 bulk)

# A fresh behaviour for the curl stand-in. default CODE BODY
behaviour() {
  printf '%s %s\n' "$1" "$2" > "$work/fakecurl/default"
  : > "$work/fakecurl/rules"
  : > "$work/fakecurl/calls"
}
rule() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$work/fakecurl/rules"
}

# run CLIENT-ARGS... -> runs the fetchers copy, with its own cache and summary
run() {
  FETCHER_CACHE="$work/cache" FETCHER_SUMMARY="$work/summary.tsv" \
    FAKE_CI_BODY="${FAKE_CI_BODY:-$good_db}" FAKE_CI_CALLS="$work/ci.calls" \
    "$work/fetchers/fetcher.sh" "$@"
}

#---------------------------------------------------------------------------#
# Which clients can run, and what --list says
#---------------------------------------------------------------------------#
got="$(FETCHER_CACHE="$work/list-cache" "$work/fetchers/fetcher.sh" --list | tr '\n' ' ' | sed 's/ $//')"
check "fetcher --list names the clients that answer here" "curl curl-impersonate rv-proxy jina" "$got" \
  "fetchers/fetcher.sh --list"

#---------------------------------------------------------------------------#
# A host that answers curl: curl is used, once, and the host is remembered
#---------------------------------------------------------------------------#
behaviour 200 good.db
rc=0
run --expect db https://fast.test/base.db "$work/fast.db" > /dev/null 2>&1 || rc=$?
check "a host that answers curl is read" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/fast.db" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db https://fast.test/base.db OUT"
check "the client that read the host is remembered" curl "$(cat "$work/cache/hosts/fast.test" 2> /dev/null)" \
  "cat \$FETCHER_CACHE/hosts/fast.test"
check "curl read the host with one call" 1 "$(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "cat \$FAKE_CURL_DIR/calls"
check "the summary names the host, the client and the outcome" 1 \
  "$(awk -F '\t' '$1 == "fast.test" && $2 == "curl" && $3 == "ok" { n++ } END { print n + 0 }' "$work/summary.tsv")" \
  "cat \$FETCHER_SUMMARY"
check "no curl-impersonate call was made" 0 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"

#---------------------------------------------------------------------------#
# A host that answers curl with an interstitial: curl-impersonate reads it,
# and the next call for the same host starts with it
#---------------------------------------------------------------------------#
behaviour 200 good.db
rule interstitial 403 nonbody.html
: > "$work/ci.calls"
rc=0
run --expect db https://interstitial.test/base.db "$work/interstitial.db" > /dev/null 2>&1 || rc=$?
check "a 403 from curl falls back to curl-impersonate" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/interstitial.db" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db https://interstitial.test/base.db OUT"
check "the host is then remembered as curl-impersonate" curl-impersonate \
  "$(cat "$work/cache/hosts/interstitial.test" 2> /dev/null)" "cat \$FETCHER_CACHE/hosts/interstitial.test"
check "curl-impersonate read the host with one call" 1 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"
: > "$work/fakecurl/calls"
rc=0
run --expect db https://interstitial.test/base.db "$work/interstitial2.db" > /dev/null 2>&1 || rc=$?
check "the next call for that host starts at curl-impersonate" "0 0" \
  "$rc $(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "the remembered client is tried first, so curl is not called again"

#---------------------------------------------------------------------------#
# A 404 is the server's answer, not a client that needs changing
#---------------------------------------------------------------------------#
behaviour 200 good.db
rule gone 404 nonbody.html
: > "$work/ci.calls"
rc=0
run --expect db https://host.test/gone/base.db "$work/gone.db" > /dev/null 2>&1 || rc=$?
check "a 404 ends the call with status 4" 4 "$rc" "fetchers/fetcher.sh --expect db URL OUT"
check "a 404 does not try a second client" 0 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"

#---------------------------------------------------------------------------#
# The structural check: a body that is not what was asked for is refused
#---------------------------------------------------------------------------#
behaviour 200 notatar
FAKE_CI_BODY="$work/fakecurl/notatar"
rc=0
run --expect db https://bad.test/base.db "$work/bad.db" > /dev/null 2>&1 || rc=$?
check "a body that is not a database is refused" 1 "$rc" \
  "fetchers/fetcher.sh --expect db URL OUT"
FAKE_CI_BODY="$good_db"
behaviour 200 many.db
rc=0
run --expect db https://many.test/base.db "$work/many.out" > /dev/null 2>&1 || rc=$?
check "a database with an early desc member is read" "0 $(sha256sum "$work/fakecurl/many.db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/many.out" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db URL OUT"
behaviour 200 good.sig
rc=0
run --expect sig https://sig.test/x.sig "$work/x.sig" > /dev/null 2>&1 || rc=$?
check "an OpenPGP signature passes the sig check" 0 "$rc" "fetchers/fetcher.sh --expect sig URL OUT"
behaviour 200 bad.sig
rc=0
run --expect sig https://sig.test/x.sig "$work/y.sig" > /dev/null 2>&1 || rc=$?
check "a body that is not a signature packet is refused" 1 "$rc" \
  "fetchers/fetcher.sh --expect sig URL OUT"
printf '<!DOCTYPE html>\n<html><body>not the file</body></html>\n' > "$work/fakecurl/page.html"
printf 'a plain body\n' > "$work/fakecurl/text.txt"
behaviour 200 page.html
rc=0
run --client curl --no-cache --expect any https://page.test/a "$work/page.out" > /dev/null 2>&1 || rc=$?
check "a 200 that is an HTML document is not a body" 1 "$rc" \
  "fetchers/fetcher.sh --expect any URL OUT against an origin that answers a page"
behaviour 200 text.txt
rc=0
run --client curl --no-cache --expect any https://text.test/a "$work/text.out" > /dev/null 2>&1 || rc=$?
check "a body that is not HTML passes --expect any" 0 "$rc" \
  "fetchers/fetcher.sh --expect any URL OUT"

#---------------------------------------------------------------------------#
# An explicit client list is used as given
#---------------------------------------------------------------------------#
behaviour 200 good.db
rc=0
run --client curl-impersonate --expect db https://only.test/base.db "$work/only.db" > /dev/null 2>&1 || rc=$?
check "an explicit --client is used" "0 0" "$rc $(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "curl is left out when only curl-impersonate is named"

#---------------------------------------------------------------------------#
# The version resolver: the newest release, cached, and printed
#---------------------------------------------------------------------------#
rm -rf "$work/drift-cache"
behaviour 200 release.json
rule api.github.com 200 release.json
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --force --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift reads the newest release tag" "0 curl-impersonate	v9.9.9" "$rc $(printf '%s' "$out" | tr -d '\n')" \
  "fetchers/drift.sh --force --key curl-impersonate"
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift serves the value from its cache" "0 curl-impersonate	v9.9.9" "$rc $(printf '%s' "$out" | tr -d '\n')" \
  "fetchers/drift.sh --key curl-impersonate"
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --json --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift --json prints every value" "0 v9.9.9" "$rc $(printf '%s' "$out" | jq -r '.["curl-impersonate"]')" \
  "fetchers/drift.sh --json --key curl-impersonate"
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --env --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift --env prints an export line" "0 1" \
  "$rc $(printf '%s\n' "$out" | awk '/^export DRIFT_CURL_IMPERSONATE=/ { n++ } END { print n + 0 }')" \
  "fetchers/drift.sh --env --key curl-impersonate"
rc=0
FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --key nope > /dev/null 2>&1 || rc=$?
check "an unknown drift key is refused" 1 "$rc" "fetchers/drift.sh --key nope"
behaviour 200 release.json
rule api.github.com 500 nonbody.html
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --ttl 0 --key curl-impersonate 2> /dev/null)" || rc=$?
check "a lookup that fails keeps the cached value" "0 curl-impersonate v9.9.9" \
  "$rc $(printf '%s' "$out" | tr '\t' ' ' | tr -d '\n')" \
  "fetchers/drift.sh --ttl 0 --key curl-impersonate, against a lookup that fails"

#---------------------------------------------------------------------------#
# The usage, the order, and a client name that no build defines
#---------------------------------------------------------------------------#
rc=0
help_out="$("$work/fetchers/fetcher.sh" --help 2>&1)" || rc=$?
check "--help names the options and exits 0" "0 1" \
  "$rc $(printf '%s\n' "$help_out" | awk '/--expect/ { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --help"

explain_out="$(FETCHER_CACHE="$work/cache" "$work/fetchers/fetcher.sh" --explain https://explain.test/a 2>&1)"
check "--explain names the order and the availability" "1 1" \
  "$(printf '%s\n' "$explain_out" | awk '/^order: curl/ { n++ } END { print n + 0 }') $(printf '%s\n' "$explain_out" | awk -F '\t' '$1 == "curl" && $2 == "available" { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --explain URL"
check "--explain names the host and no cached preference" 2 \
  "$(printf '%s\n' "$explain_out" | awk '/^host: explain.test$/ { n++ } /^preferred: none$/ { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --explain https://explain.test/a"

rc=0
"$work/fetchers/install.sh" --check curl > /dev/null 2>&1 || rc=$?
check "install.sh --check passes for an available client" 0 "$rc" "fetchers/install.sh --check curl"
rc=0
"$work/fetchers/install.sh" --check chromium > /dev/null 2>&1 || rc=$?
check "install.sh --check fails for a client that is not installed" 1 "$rc" "fetchers/install.sh --check chromium"
rc=0
"$work/fetchers/install.sh" --check bogus > /dev/null 2>&1 || rc=$?
check "install.sh --check refuses an unknown client" 1 "$rc" "fetchers/install.sh --check bogus"
rc=0
"$work/fetchers/install.sh" --check > /dev/null 2>&1 || rc=$?
check "install.sh --check with no client asks for the default set" 1 "$rc" "fetchers/install.sh --check"

case "$(uname -m)" in
  x86_64 | amd64) want="https://example.test/curl-x86_64-linux-gnu.tar.gz" ;;
  aarch64 | arm64) want="https://example.test/curl-aarch64-linux-gnu.tar.gz" ;;
  *) want="" ;;
esac
if [ -n "$want" ]; then
  rc=0
  got="$(CURL_IMPERSONATE_TAG=v-test \
    CURL_IMPERSONATE_RELEASE_JSON="$REPO_ROOT/tests/fixtures/fetcher/curl-impersonate-release.json" \
    CURL_IMPERSONATE_PRINT_ASSET=1 "$work/fetchers/curl-impersonate/install.sh" 2> /dev/null)" || rc=$?
  check "curl-impersonate picks the CLI gnu asset for this arch" "0 $want" "$rc $got" \
    "CURL_IMPERSONATE_RELEASE_JSON=... CURL_IMPERSONATE_PRINT_ASSET=1 fetchers/curl-impersonate/install.sh"
fi

behaviour 200 good.db
: > "$work/fakecurl/calls"
rc=0
run --client bogus --expect any https://bogus.test/a "$work/bogus.out" > /dev/null 2>&1 || rc=$?
check "an unknown client is refused" 1 "$rc" "fetchers/fetcher.sh --client bogus URL OUT"
check "the refusal makes no request" 0 "$(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "cat \$FAKE_CURL_DIR/calls"

#---------------------------------------------------------------------------#
# A body the caller already knows the digest of
#---------------------------------------------------------------------------#
behaviour 200 good.db
sha="$(sha256sum "$good_db" | cut -d ' ' -f 1)"
rc=0
run --client curl --no-cache --expect db --sha256 "$sha" https://sha.test/base.db "$work/sha.out" > /dev/null 2>&1 || rc=$?
check "a body with the asked sha256 passes" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/sha.out" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --sha256 $sha --expect db URL OUT"
rc=0
run --client curl --no-cache --expect db --sha256 "$(printf '0%.0s' $(seq 1 64))" https://sha.test/base.db "$work/sha2.out" > /dev/null 2>&1 || rc=$?
check "a body with another sha256 is refused" 1 "$rc" \
  "fetchers/fetcher.sh --sha256 000...0 --expect db URL OUT"
rc=0
run --client curl --expect any --sha256 zz https://sha.test/base.db "$work/sha3.out" > /dev/null 2>&1 || rc=$?
check "--sha256 that is not 64 hex characters is refused" 1 "$rc" \
  "fetchers/fetcher.sh --sha256 zz URL OUT"

#---------------------------------------------------------------------------#
# A cap on the body, and the retry backoff
#---------------------------------------------------------------------------#
behaviour 200 good.db
rc=0
run --client curl --no-cache --expect db --max-bytes 10 https://cap.test/base.db "$work/cap.out" > /dev/null 2>&1 || rc=$?
check "a body over --max-bytes is refused" 1 "$rc" \
  "fetchers/fetcher.sh --max-bytes 10 --expect db URL OUT"
rc=0
run --client curl --no-cache --expect db --max-bytes 100000000 https://cap.test/base.db "$work/cap2.out" > /dev/null 2>&1 || rc=$?
check "a body under --max-bytes passes" 0 "$rc" \
  "fetchers/fetcher.sh --max-bytes 100000000 --expect db URL OUT"
rc=0
run --client curl --expect any --max-bytes nope https://cap.test/a "$work/cap3.out" > /dev/null 2>&1 || rc=$?
check "--max-bytes that is not a number is refused" 1 "$rc" \
  "fetchers/fetcher.sh --max-bytes nope URL OUT"
r="$(bash -c '. "$1"; printf "%s %s %s %s" "$(retry_delay 1)" "$(retry_delay 2)" "$(retry_delay 3)" "$(retry_delay 9)"' _ "$REPO_ROOT/fetchers/lib.sh")"
check "retry_delay grows 2, 4, 8 and stops at 30" "2 4 8 30" "$r" "bash -c '. fetchers/lib.sh; retry_delay 1 2 3 9'"

#---------------------------------------------------------------------------#
# An extra header and a referer reach the client
#---------------------------------------------------------------------------#
behaviour 200 good.db
: > "$work/fakecurl/headers"
: > "$work/fakecurl/referers"
rc=0
run --client curl --no-cache --expect any --header 'X-Test: yes' --referer https://ref.test/ https://hdr.test/a "$work/hdr.out" > /dev/null 2>&1 || rc=$?
check "an extra header reaches curl" 1 \
  "$(awk '/^X-Test: yes$/ { n++ } END { print n + 0 }' "$work/fakecurl/headers")" "cat \$FAKE_CURL_DIR/headers"
check "the referer reaches curl" 1 \
  "$(awk '/^https:\/\/ref.test\/$/ { n++ } END { print n + 0 }' "$work/fakecurl/referers")" "cat \$FAKE_CURL_DIR/referers"
rc=0
run --no-cache --header 'no colon' --expect any https://hdr.test/a "$work/hdr2.out" > /dev/null 2>&1 || rc=$?
check "a header with no colon is refused" 1 "$rc" "fetchers/fetcher.sh --header 'no colon' URL OUT"

#---------------------------------------------------------------------------#
# A client probe is cached, and --no-cache asks again
#---------------------------------------------------------------------------#
mkdir -p "$work/fetchers/chromium"
cat > "$work/fetchers/chromium/available" << EOF
#!/usr/bin/env bash
printf 'x' >> "$work/probe-count"
exit 1
EOF
chmod 0755 "$work/fetchers/chromium/available"
: > "$work/probe-count"
FETCHER_CACHE="$work/avail-cache" FETCHER_AVAILABLE_TTL=300 "$work/fetchers/fetcher.sh" --list > /dev/null 2>&1
FETCHER_CACHE="$work/avail-cache" FETCHER_AVAILABLE_TTL=300 "$work/fetchers/fetcher.sh" --list > /dev/null 2>&1
check "a client probe is cached for its ttl" 1 "$(wc -c < "$work/probe-count" | tr -d ' ')" \
  "run fetcher.sh --list twice with the same FETCHER_CACHE"
FETCHER_CACHE="$work/avail-cache" "$work/fetchers/fetcher.sh" --list --no-cache > /dev/null 2>&1
check "--no-cache asks the probe again" 2 "$(wc -c < "$work/probe-count" | tr -d ' ')" \
  "run fetcher.sh --list --no-cache"

#---------------------------------------------------------------------------#
# A cached host preference that names no client is ignored
#---------------------------------------------------------------------------#
mkdir -p "$work/cache/hosts"
printf 'nonsense-client\n' > "$work/cache/hosts/badpref.test"
pref_out="$(FETCHER_CACHE="$work/cache" "$work/fetchers/fetcher.sh" --explain https://badpref.test/a 2>&1)"
check "an unknown cached client is ignored" 1 \
  "$(printf '%s\n' "$pref_out" | awk '/^order: curl curl-impersonate/ { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --explain URL with a host preference that is not a client"

#---------------------------------------------------------------------------#
# A client that hangs is stopped within --timeout
#---------------------------------------------------------------------------#
cp "$work/fetchers/curl-impersonate/fetch.sh" "$work/ci-fast.sh"
cat > "$work/fetchers/curl-impersonate/fetch.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 30
EOF
chmod 0755 "$work/fetchers/curl-impersonate/fetch.sh"
started=$SECONDS
rc=0
run --client curl-impersonate --no-cache --retries 1 --timeout 2 --expect any https://slow.test/a "$work/slow.out" > /dev/null 2>&1 || rc=$?
took=$((SECONDS - started))
check "a client that hangs is stopped within --timeout" "1 yes" \
  "$rc $([ "$took" -lt 15 ] && echo yes || echo "no, $took s")" \
  "fetchers/fetcher.sh --client curl-impersonate --timeout 2 URL OUT, against a client that sleeps 30 s"
cp "$work/ci-fast.sh" "$work/fetchers/curl-impersonate/fetch.sh"

#---------------------------------------------------------------------------#
# Every client is dispatched to its own program, not to another's
#---------------------------------------------------------------------------#
# The tree probes above left a cached answer; ask fresh from here.
export FETCHER_AVAILABLE_TTL=0
# self-check.sh calls fetcher.sh directly, so the stand-ins need these.
export FAKE_CI_BODY="$good_db"
export FAKE_CI_CALLS="$work/ci.calls"
: > "$work/dispatch"
export FAKE_DISPATCH="$work/dispatch"
mkdir -p "$work/fetchers/playwright/venv/bin"
cat > "$work/bin/node" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'node %s\n' "$1" >> "${FAKE_DISPATCH:?}"
out="$3"
cp "${FAKE_CI_BODY:?}" "$out"
EOF
cat > "$work/fetchers/playwright/venv/bin/python" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'python %s\n' "$1" >> "${FAKE_DISPATCH:?}"
out="$3"
cp "${FAKE_CI_BODY:?}" "$out"
EOF
chmod 0755 "$work/bin/node" "$work/fetchers/playwright/venv/bin/python"
for c in chromium cloak-browser playwright; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/fetchers/$c/available"
  chmod 0755 "$work/fetchers/$c/available"
done
behaviour 200 good.db
for c in chromium cloak-browser playwright; do
  rc=0
  run --client "$c" --no-cache --expect db "https://$c.test/base.db" "$work/$c.out" > /dev/null 2>&1 || rc=$?
  check "$c reads the body through its own program" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
    "$rc $(sha256sum "$work/$c.out" | cut -d ' ' -f 1)" \
    "fetchers/fetcher.sh --client $c URL OUT"
done
check "chromium runs fetch.mjs through node" 1 \
  "$(awk '/^node .*chromium\/fetch\.mjs$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"
check "cloak-browser runs fetch.mjs through node" 1 \
  "$(awk '/^node .*cloak-browser\/fetch\.mjs$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"
check "playwright runs fetch.py through its venv python" 1 \
  "$(awk '/^python .*playwright\/fetch\.py$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"
rc=0
"$work/fetchers/install.sh" --check chromium > /dev/null 2>&1 || rc=$?
check "install.sh --check passes once the client is available" 0 "$rc" "fetchers/install.sh --check chromium"

rc=0
sc="$("$work/fetchers/self-check.sh" --strict https://selfcheck.test/base.db 2>&1)" || rc=$?
check "self-check reads the URL through every available client" "0 8" \
  "$rc $(printf '%s\n' "$sc" | awk '/: read it$/ { n++ } END { print n + 0 }')" \
  "fetchers/self-check.sh --strict https://selfcheck.test/base.db, with seven clients that answer"

rc=0
"$work/fetchers/ci.sh" --help > /dev/null 2>&1 || rc=$?
check "ci.sh --help exits 0" 0 "$rc" "fetchers/ci.sh --help"
rc=0
"$work/fetchers/ci.sh" bogus > /dev/null 2>&1 || rc=$?
check "ci.sh refuses an unknown client" 1 "$rc" "fetchers/ci.sh bogus"
rc=0
FETCHER_SELFCHECK_URL=https://selfcheck.test/base.db "$work/fetchers/ci.sh" curl > /dev/null 2>&1 || rc=$?
check "ci.sh checks an already-installed client" 0 "$rc" \
  "FETCHER_SELFCHECK_URL=https://selfcheck.test/base.db fetchers/ci.sh curl"

#---------------------------------------------------------------------------#
# The three checks the port brought over: a signature verified with gpgv, a
# magic check on the first bytes, and a client the caller insists on.
#---------------------------------------------------------------------------#
if ! command -v gpgv > /dev/null && ! command -v gpgv2 > /dev/null; then
  ok "skipped: the signature check, because gpgv is not on PATH"
else
  # A key and a signature made here, so the check is exercised end to end and
  # a pass cannot come from a fixture that was never signed.
  ghome="$work/gnupg"
  mkdir -p "$ghome"
  # gpg refuses a home that anyone but the owner can read.
  chmod 0700 "$ghome"
  if ! GNUPGHOME="$ghome" gpg --batch --quiet --passphrase '' \
       --quick-generate-key 'Fetcher Test <fetcher@example.invalid>' default default never > "$work/gpg.log" 2>&1; then
    ok "skipped: the signature check, because no key could be made ($(sed -n 1p "$work/gpg.log"))"
  else
    GNUPGHOME="$ghome" gpg --batch --export > "$work/test.gpg" 2>/dev/null
    # The fake curl reads its bodies from FAKE_CURL_DIR, so the signed pair
    # is written there, not in $work.
    cp "$work/fakecurl/good.db" "$work/fakecurl/signed.db"
    cp "$work/fakecurl/good.db" "$work/fakecurl/signed.db.sig"
    GNUPGHOME="$ghome" gpg --batch --quiet --yes --detach-sign \
      -u 'Fetcher Test <fetcher@example.invalid>' "$work/fakecurl/signed.db.sig" "$work/fakecurl/signed.db" > /dev/null 2>&1
    # signed.db and signed.db.sig are served by substring, so --signature's
    # derived URL.sig finds its own rule.
    behaviour 200 signed.db
    rule signed.db.sig 200 signed.db.sig
    rule signed.db 200 signed.db

    rc=0
    run --quiet --client curl --expect db \
      --signature https://sig.test/signed.db --keyring "$work/test.gpg" \
      https://sig.test/signed.db "$work/sig-out.db" > "$work/sig.log" 2>&1 || rc=$?
    check "--signature writes the body once gpgv verifies it" 0 "$rc" \
      "fetchers/fetcher.sh --signature URL --keyring FILE URL OUT; $(sed -n 1p "$work/sig.log")"
    check "--signature wrote the body it verified" \
      "$(sha256sum "$work/fakecurl/signed.db" | cut -d ' ' -f 1)" \
      "$([ -e "$work/sig-out.db" ] && sha256sum "$work/sig-out.db" | cut -d ' ' -f 1 || echo absent)" \
      "sha256sum BODY OUT"

    # The negative control: one byte changed in the body must not verify, and
    # the body must not be written.
    cp "$work/fakecurl/signed.db" "$work/fakecurl/tampered.db"
    cp "$work/fakecurl/signed.db.sig" "$work/fakecurl/tampered.db.sig"
    printf 'X' | dd of="$work/fakecurl/tampered.db" bs=1 seek=64 conv=notrunc 2>/dev/null
    rule tampered.db.sig 200 tampered.db.sig
    rule tampered.db 200 tampered.db
    rm -f "$work/sig-bad.db"
    rc=0
    "$work/fetchers/fetcher.sh" --quiet --client curl --expect db --retries 1 \
      --signature https://sig.test/tampered.db --keyring "$work/test.gpg" \
      https://sig.test/tampered.db "$work/sig-bad.db" > "$work/sigbad.log" 2>&1 || rc=$?
    check "--signature refuses a body one byte off its signature" 1 "$rc" \
      "fetchers/fetcher.sh --signature URL --keyring FILE URL OUT; $(sed -n 1p "$work/sigbad.log")"
    check "and writes no body for it" "absent" \
      "$([ -e "$work/sig-bad.db" ] && echo present || echo absent)" "ls OUT"

    # A signature by a key the keyring does not hold.
    mkdir -p "$work/gnupg2"
    chmod 0700 "$work/gnupg2"
    GNUPGHOME="$work/gnupg2" gpg --batch --quiet --passphrase '' \
      --quick-generate-key 'Other Test <other@example.invalid>' default default never > /dev/null 2>&1
    GNUPGHOME="$work/gnupg2" gpg --batch --export > "$work/other.gpg" 2>/dev/null
    rc=0
    "$work/fetchers/fetcher.sh" --quiet --client curl --expect db --retries 1 \
      --signature https://sig.test/signed.db --keyring "$work/other.gpg" \
      https://sig.test/signed.db "$work/sig-other.db" > "$work/sigother.log" 2>&1 || rc=$?
    check "--signature refuses a signature the keyring does not hold" 1 "$rc" \
      "fetchers/fetcher.sh --signature URL --keyring FILE URL OUT; $(sed -n 1p "$work/sigother.log")"

    # Two keyrings, the right one second: every keyring goes to the one gpgv
    # call, so a signature by the second is verified and not called unsigned.
    rm -f "$work/sig-two.db"
    rc=0
    "$work/fetchers/fetcher.sh" --quiet --client curl --expect db \
      --signature https://sig.test/signed.db --keyring "$work/other.gpg" --keyring "$work/test.gpg" \
      https://sig.test/signed.db "$work/sig-two.db" > "$work/sigtwo.log" 2>&1 || rc=$?
    check "--signature verifies against the second of two --keyrings" 0 "$rc" \
      "fetchers/fetcher.sh --signature URL --keyring A --keyring B URL OUT; $(sed -n 1p "$work/sigtwo.log")"

    # A signature with no keyring would report every signature as unsigned.
    rc=0
    "$work/fetchers/fetcher.sh" --quiet --client curl \
      --signature https://sig.test/signed.db \
      https://sig.test/signed.db "$work/sig-none.db" > "$work/signone.log" 2>&1 || rc=$?
    check "--signature without a --keyring is refused, not reported unsigned" 1 "$rc" \
      "fetchers/fetcher.sh --signature URL URL OUT; $(sed -n 1p "$work/signone.log")"
    if grep -q 'needs at least one --keyring' "$work/signone.log"; then
      ok "and the message says a keyring is what is missing"
    else
      fail "and the message says a keyring is what is missing" "$(sed -n 1p "$work/signone.log")" \
        "fetchers/fetcher.sh --signature URL URL OUT"
    fi
  fi
fi

# --magic: the first bytes of the body, which no structural check compares.
# The database these tests serve is a gzip tar, so its first four bytes are
# 1f8b0800. The value is read from the fixture rather than written here, so
# this cannot go stale if the fixture changes.
magic="$(od -An -tx1 -N4 "$work/fakecurl/good.db" | tr -d ' \n')"
check "the fixture database starts 1f8b0800, which is what the magic cases use" 1f8b0800 "$magic" \
  "od -An -tx1 -N4 \$work/fakecurl/good.db"
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl --expect db --magic "$magic" \
  https://fast.test/base.db "$work/magic.out" > "$work/magic.log" 2>&1 || rc=$?
check "--magic accepts the first bytes the body has" 0 "$rc" \
  "fetchers/fetcher.sh --expect db --magic \$magic URL OUT; $(sed -n 1p "$work/magic.log")"
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl --expect db --retries 1 --magic 28b52ffd \
  https://fast.test/base.db "$work/magic2.out" > "$work/magic2.log" 2>&1 || rc=$?
check "--magic refuses a body whose first bytes differ" 1 "$rc" \
  "fetchers/fetcher.sh --expect db --magic 28b52ffd URL OUT; $(sed -n 1p "$work/magic2.log")"
check "and writes no body for it" "absent" \
  "$([ -e "$work/magic2.out" ] && echo present || echo absent)" "ls OUT"
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl --expect db --magic 1f8b \
  https://fast.test/base.db "$work/magic-prefix.out" > "$work/magicp.log" 2>&1 || rc=$?
check "--magic accepts a prefix of the bytes the body has" 0 "$rc" \
  "fetchers/fetcher.sh --expect db --magic 1f8b URL OUT; $(sed -n 1p "$work/magicp.log")"
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl --expect db --magic zz \
  https://fast.test/base.db "$work/magic3.out" > "$work/magic3.log" 2>&1 || rc=$?
check "--magic refuses a value that is not hex" 1 "$rc" \
  "fetchers/fetcher.sh --expect db --magic zz URL OUT; $(sed -n 1p "$work/magic3.log")"
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl --expect db --magic 1f8b080000 \
  https://fast.test/base.db "$work/magic4.out" > "$work/magic4.log" 2>&1 || rc=$?
check "--magic refuses a value longer than the bytes it can read" 1 "$rc" \
  "fetchers/fetcher.sh --expect db --magic 1f8b080000 URL OUT; $(sed -n 1p "$work/magic4.log")"

# --require-tool: one client first, and no silent answer from another.
rc=0
"$work/fetchers/fetcher.sh" --quiet --require-tool curl \
  https://fast.test/base.db "$work/req.out" > "$work/req.log" 2>&1 || rc=$?
check "--require-tool runs the client it names" 0 "$rc" \
  "fetchers/fetcher.sh --require-tool curl URL OUT; $(sed -n 1p "$work/req.log")"
# An earlier section of this file gives every browser client a probe that
# answers true, so --require-tool is asked about one on a tree of its own,
# where the probe is the real one and answers false. A copy is used because the
# option is about the client, not about the URL, and the answer must not depend
# on which sections of this file have run.
unavailable="chromium"
mkdir -p "$work/reqtree"
cp -r "$REPO_ROOT/fetchers/." "$work/reqtree/"
reqfetcher="$work/reqtree/fetcher.sh"
listed="$(FETCHER_CACHE="$work/req-list-cache" FETCHER_AVAILABLE_TTL=0 "$reqfetcher" --list | tr '\n' ' ')"
case " $listed " in
  *" $unavailable "*) listed="present" ;;
  *) listed="absent" ;;
esac
check "the client --require-tool refuses below is not one --list offers" absent "$listed" \
  "fetchers/fetcher.sh --list, on a tree where no browser client is installed"
rc=0
FETCHER_CACHE="$work/req-cache" FETCHER_AVAILABLE_TTL=0 "$reqfetcher" --quiet \
  --require-tool "$unavailable" \
  https://fast.test/base.db "$work/req2.out" > "$work/req2.log" 2>&1 || rc=$?
check "--require-tool refuses to run without the client it names" 1 "$rc" \
  "fetchers/fetcher.sh --require-tool $unavailable URL OUT; $(sed -n 1p "$work/req2.log")"
# The client curl would have answered with is available, so the refusal above
# is the option and not the network. Without it the same URL is read.
rc=0
"$work/fetchers/fetcher.sh" --quiet --client curl \
  https://fast.test/base.db "$work/req2-ok.out" > /dev/null 2>&1 || rc=$?
check "the same URL reads through curl, so the refusal was the option" 0 "$rc" \
  "fetchers/fetcher.sh --client curl URL OUT"
check "and writes nothing, rather than answering through another client" "absent" \
  "$([ -e "$work/req2.out" ] && echo present || echo absent)" "ls OUT"
rc=0
"$work/fetchers/fetcher.sh" --quiet --require-tool nosuch \
  https://fast.test/base.db "$work/req3.out" > "$work/req3.log" 2>&1 || rc=$?
check "--require-tool names a client that is not in the tree" 1 "$rc" \
  "fetchers/fetcher.sh --require-tool nosuch URL OUT; $(sed -n 1p "$work/req3.log")"
if grep -q 'is not a client of this tree' "$work/req3.log"; then
  ok "and the message says it is not a known client, not that it is missing"
else
  fail "and the message says it is not a known client, not that it is missing" "$(sed -n 1p "$work/req3.log")" \
    "fetchers/fetcher.sh --require-tool nosuch URL OUT"
fi

summary
