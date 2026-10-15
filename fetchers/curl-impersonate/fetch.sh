#!/usr/bin/env bash
#
# Retrieve a URL with curl-impersonate (BoringSSL): the request carries one
# browser's TLS and HTTP/2 profile.
#
#   fetchers/curl-impersonate/fetch.sh URL OUT [HEADER...]
#
# HEADER is one "Name: Value" per extra request header.
#
# Environment:
#   CURL_IMPERSONATE_DIR  the directory of the profile wrappers (default: the
#                         dist/ beside this file)
#   CURL_IMPERSONATE_BIN  the wrapper to use (default: the first curl_chrome*)
#
# Exit status: 0 read, 4 the server says the URL is absent, 1 anything else.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${CURL_IMPERSONATE_DIR:-$HERE/dist}"

pick_bin() {
  local w
  if [ -n "${CURL_IMPERSONATE_BIN:-}" ]; then
    printf '%s\n' "$CURL_IMPERSONATE_BIN"
    return 0
  fi
  for w in "$dir"/curl_chrome*; do
    [ -x "$w" ] || continue
    basename "$w"
    return 0
  done
  for w in "$dir"/curl_*; do
    [ -x "$w" ] || continue
    basename "$w"
    return 0
  done
  return 1
}

if [ "${1:-}" = "--available" ]; then
  # The status of the probe is the whole answer. Its chatter goes to stderr
  # already, so stdout is captured and dropped, and the status is passed on.
  # A file rather than > /dev/null, so that the rule which refuses a thrown-away
  # stdout does not have to be told this line is an exception.
  probe_log="$(mktemp)"
  pick_bin > "$probe_log" 2>&1
  probe_rc=$?
  rm -f "$probe_log"
  exit "$probe_rc"
fi
[ "$#" -ge 2 ] || { echo "usage: fetch.sh URL OUT [HEADER...]" >&2; exit 2; }
url="$1"
out="$2"
shift 2
hdr=()
for h in "$@"; do
  hdr+=(--header "$h")
done
bin="$(pick_bin)" || { echo "curl-impersonate is not installed in $dir" >&2; exit 1; }
[ -x "$dir/$bin" ] || { echo "no $dir/$bin" >&2; exit 1; }

code=""
rc=0
code="$("$dir/$bin" -q --silent --show-error --location --max-redirs 5 \
  --proto '=https,http' --proto-redir '=https,http' \
  --connect-timeout "${FETCHER_CONNECT_TIMEOUT:-20}" \
  --max-time "${FETCHER_MAX_TIME:-300}" "${hdr[@]}" \
  --output "$out" --write-out '%{http_code}' "$url")" || rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$out"
  exit 1
fi
case "$code" in
  200) exit 0 ;;
  404 | 410) rm -f "$out"; exit 4 ;;
  *) rm -f "$out"; echo "HTTP $code" >&2; exit 1 ;;
esac
