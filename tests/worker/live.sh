#!/usr/bin/env bash
#
# A smoke test of the deployed Worker. It runs only when WORKER_LIVE=1, so the
# worker suite stays free of network otherwise.
#
#   WORKER_LIVE=1 REPO_ROOT=$PWD bash tests/worker/live.sh
#
# WORKER_URL names the Worker (default https://ghcr.mirror.archlinux.pkgforge.dev).
# WORKER_ARCH and WORKER_REPO name the repository (default x86_64 core).
# It only reads: from the Worker, from GHCR with the anonymous token, and from
# the blob host. It needs curl, tar, gzip, awk and sha256sum.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

if [ "${WORKER_LIVE:-0}" != 1 ]; then
  ok "skipped: set WORKER_LIVE=1 to check the deployed Worker"
  summary
  exit 0
fi

BASE="${WORKER_URL:-https://ghcr.mirror.archlinux.pkgforge.dev}"
BASE="${BASE%/}"
ARCH="${WORKER_ARCH:-x86_64}"
REPO="${WORKER_REPO:-core}"
GHCR="https://ghcr.io/v2/pkgforge-dev/mirror-archlinux/$ARCH/$REPO"
MANIFEST_TYPE='application/vnd.oci.image.manifest.v1+json'

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

# probe NAME METHOD PATH: one request to the Worker, no redirect followed.
# Sets CODE, LOCATION and SECONDS_TAKEN; the body is in $work/NAME.body.
probe() {
  local name="$1" method="$2" path="$3" out rc=0
  local -a args=(-sS --connect-timeout 10 --max-time 60 -o "$work/$name.body" -D "$work/$name.headers"
    -w '%{http_code} %{time_total}')
  if [ "$method" = HEAD ]; then
    args+=(-I)
  fi
  out="$(curl "${args[@]}" "$BASE$path")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    CODE="curl-$rc" LOCATION="" SECONDS_TAKEN=""
    return 0
  fi
  CODE="${out%% *}"
  SECONDS_TAKEN="${out#* }"
  LOCATION="$(awk 'tolower($1) == "location:" { sub(/\r$/, "", $2); print $2 }' "$work/$name.headers")"
}

# fetch URL FILE: follow a signed URL; prints the HTTP code.
fetch() {
  local out rc=0
  out="$(curl -sS --connect-timeout 10 --max-time 300 -o "$2" -w '%{http_code}' "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'curl-%s\n' "$rc"
  else
    printf '%s\n' "$out"
  fi
}

# location_ok: the Location is https on *.githubusercontent.com.
location_ok() {
  case "$LOCATION" in
    https://*.githubusercontent.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The blob digest a signed URL names, from its path.
digest_of() {
  printf '%s\n' "$1" | sed -n 's|^https://[^/]*/.*/blobs/sha256:\([0-9a-f]\{64\}\).*$|\1|p'
}

#---------------------------------------------------------------------------#
# The usage text
#---------------------------------------------------------------------------#
probe root GET /
check "GET / answers 200" 200 "$CODE" "curl -sS $BASE/"
if grep -qF "Server = https://" "$work/root.body"; then
  ok "GET / shows the Server line"
else
  fail "GET / shows the Server line" "$(sed -n 1,5p "$work/root.body")" "reproduce: curl -sS $BASE/"
fi

#---------------------------------------------------------------------------#
# The database, by latest, by HEAD, by pin, and the refusals
#---------------------------------------------------------------------------#
probe db GET "/$ARCH/$REPO/$REPO.db"
check "GET $REPO.db answers 302" 302 "$CODE" "curl -sS -o /dev/null -w '%{http_code}' $BASE/$ARCH/$REPO/$REPO.db"
diag "GET /$ARCH/$REPO/$REPO.db took $SECONDS_TAKEN s"
if location_ok; then
  ok "the $REPO.db Location is https on *.githubusercontent.com"
else
  fail "the $REPO.db Location is https on *.githubusercontent.com" "Location: $LOCATION" "reproduce: curl -sSI $BASE/$ARCH/$REPO/$REPO.db"
fi
db_url="$LOCATION"
db_digest="$(digest_of "$db_url")"

probe dbhead HEAD "/$ARCH/$REPO/$REPO.db"
check "HEAD $REPO.db answers 302" 302 "$CODE" "curl -sSI $BASE/$ARCH/$REPO/$REPO.db"
if location_ok; then
  ok "HEAD $REPO.db has a Location on *.githubusercontent.com"
else
  fail "HEAD $REPO.db has a Location on *.githubusercontent.com" "Location: $LOCATION" "reproduce: curl -sSI $BASE/$ARCH/$REPO/$REPO.db"
fi

got="$(fetch "$db_url" "$work/$REPO.db")"
check "the signed URL of $REPO.db answers 200" 200 "$got" "curl -sS -o /dev/null -w '%{http_code}' '<Location of $REPO.db>'"
check "$REPO.db hashes to the digest its Location names" "$db_digest" "$(sha256sum "$work/$REPO.db" | cut -d ' ' -f 1)" \
  "curl -sSL $BASE/$ARCH/$REPO/$REPO.db | sha256sum"

# What GHCR says latest is, read directly with the anonymous token.
rc=0
curl -sS --connect-timeout 10 --max-time 60 -H 'Authorization: Bearer QQ==' -H "Accept: $MANIFEST_TYPE" \
  -D "$work/latest.headers" -o "$work/latest.json" "$GHCR/manifests/latest" || rc=$?
check "GHCR answers for $ARCH/$REPO:latest" 0 "$rc" "curl -sS -H 'Authorization: Bearer QQ==' $GHCR/manifests/latest"
pin="$(awk 'tolower($1) == "docker-content-digest:" { sub(/\r$/, "", $2); print $2 }' "$work/latest.headers")"
ghcr_db="$(sed -n 's/.*"dev\.pkgforge\.mirror\.db-sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$work/latest.json")"
# A promote between the two reads is the one harmless cause of a difference.
check "the Worker's $REPO.db is the one GHCR latest names" "$ghcr_db" "$db_digest" \
  "compare $BASE/$ARCH/$REPO/$REPO.db with the db-sha256 annotation of $GHCR/manifests/latest"

probe pin GET "/$ARCH/$REPO@$pin/$REPO.db"
check "GET @$pin/$REPO.db answers 302" 302 "$CODE" "curl -sSI $BASE/$ARCH/$REPO@$pin/$REPO.db"
check "the pin names the same $REPO.db" "$db_digest" "$(digest_of "$LOCATION")" "curl -sSI $BASE/$ARCH/$REPO@$pin/$REPO.db"

zero="sha256:$(printf '%064d' 0)"
for path in "/$ARCH/$REPO@$zero/$REPO.db" "/$ARCH/$REPO:staging/$REPO.db" "/$ARCH/$REPO/$REPO.db.sig" "/$ARCH/$REPO/README" "/$ARCH/$REPO/extra-$REPO.db"; do
  probe refused GET "$path"
  check "GET $path answers 404" 404 "$CODE" "curl -sS $BASE$path"
done

probe files GET "/$ARCH/$REPO/$REPO.files"
check "GET $REPO.files answers 302" 302 "$CODE" "curl -sSI $BASE/$ARCH/$REPO/$REPO.files"

#---------------------------------------------------------------------------#
# A package and its .sig, named by the database. One with a + in its name is
# also asked for with %2B.
#---------------------------------------------------------------------------#
mkdir "$work/db"
rc=0
tar -xf "$work/$REPO.db" -C "$work/db" || rc=$?
check "$REPO.db unpacks with tar" 0 "$rc" "curl -sSL $BASE/$ARCH/$REPO/$REPO.db | tar -t"
awk '
  FNR == 1 { if (f != "") print f "\t" s; f = ""; s = "" }
  prev == "%FILENAME%" { f = $0 }
  prev == "%SHA256SUM%" { s = $0 }
  { prev = $0 }
  END { if (f != "") print f "\t" s }
' "$work"/db/*/desc | sort > "$work/files.tsv"
pick="$(awk -F '\t' '$1 ~ /[+]/ { print; n++ } END { if (n == 0) print "" }' "$work/files.tsv" | sed -n 1p)"
if [ -z "$pick" ]; then
  pick="$(sed -n 1p "$work/files.tsv")"
fi
file="${pick%%$'\t'*}"
sum="${pick#*$'\t'}"
if [ -z "$file" ] || [ -z "$sum" ]; then
  fail "$REPO.db names a package with a sha256" "files.tsv: $(sed -n 1,3p "$work/files.tsv")" "reproduce: tar -xOf $REPO.db --wildcards '*/desc'"
else
  ok "$REPO.db names $file"
  probe pkg GET "/$ARCH/$REPO/$file"
  check "GET $file answers 302" 302 "$CODE" "curl -sSI '$BASE/$ARCH/$REPO/$file'"
  diag "GET $file took $SECONDS_TAKEN s (cold or warm)"
  check "the Location of $file names its %SHA256SUM%" "$sum" "$(digest_of "$LOCATION")" "curl -sSI '$BASE/$ARCH/$REPO/$file'"
  probe pkg2 GET "/$ARCH/$REPO/$file"
  check "GET $file again answers 302" 302 "$CODE" "curl -sSI '$BASE/$ARCH/$REPO/$file'"
  diag "GET $file again took $SECONDS_TAKEN s"

  probe sig GET "/$ARCH/$REPO/$file.sig"
  check "GET $file.sig answers 302" 302 "$CODE" "curl -sSI '$BASE/$ARCH/$REPO/$file.sig'"
  diag "GET $file.sig took $SECONDS_TAKEN s"
  got="$(fetch "$LOCATION" "$work/pkg.sig")"
  check "the signed URL of $file.sig answers 200" 200 "$got" "curl -sSL '$BASE/$ARCH/$REPO/$file.sig' | wc -c"
  if [ -s "$work/pkg.sig" ]; then
    ok "$file.sig is not empty"
  else
    fail "$file.sig is not empty" "0 bytes" "reproduce: curl -sSL '$BASE/$ARCH/$REPO/$file.sig' | wc -c"
  fi

  case "$file" in
    *+*)
      encoded="${file//+/%2B}"
      probe enc GET "/$ARCH/$REPO/$encoded"
      check "GET $encoded answers 302" 302 "$CODE" "curl -sSI '$BASE/$ARCH/$REPO/$encoded'"
      check "the %2B name gets the same blob" "$sum" "$(digest_of "$LOCATION")" "curl -sSI '$BASE/$ARCH/$REPO/$encoded'"
      ;;
    *) diag "no package name in $REPO.db has a +; the %2B check did not run" ;;
  esac
fi

summary
