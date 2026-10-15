#!/usr/bin/env bash
#
# Read a URL through the api.rv.pkgforge.dev read-through proxy. The proxy dials
# the origin from its own network, so a runner that the origin refuses still
# reads the file: the origin never sees the runner's address.
#
#   fetchers/rv-proxy/fetch.sh URL OUT [HEADER...]
#
# HEADER is one "Name: Value" per extra request header. The proxy serves curl
# clients, so the request keeps curl's own User-Agent and adds no browser one.
#
# Environment:
#   RV_PROXY_BASE  the proxy, without a trailing slash (default
#                  https://api.rv.pkgforge.dev)
#
# Exit status: 0 read, 4 the origin says the URL is absent, 1 anything else.
set -euo pipefail

url="${1:-}"
out="${2:-}"
[ -n "$url" ] && [ -n "$out" ] || { echo "usage: fetch.sh URL OUT [HEADER...]" >&2; exit 2; }
shift 2
hdr=()
for h in "$@"; do
  [ -n "$h" ] || continue
  hdr+=(--header "$h")
done
base="${RV_PROXY_BASE:-https://api.rv.pkgforge.dev}"

code=""
rc=0
# The target URL is appended whole: api.rv.pkgforge.dev/<scheme>://<host>/<path>.
# curl keeps its default User-Agent, which is what the proxy serves.
code="$(curl -q --location --silent --show-error --max-redirs 5 \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout "${FETCHER_CONNECT_TIMEOUT:-20}" \
  --speed-limit 1024 --speed-time 60 \
  --max-time "${FETCHER_MAX_TIME:-300}" "${hdr[@]}" \
  --output "$out" --write-out '%{http_code}' "$base/$url")" || rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$out"
  exit 1
fi
case "$code" in
  200) exit 0 ;;
  404 | 410) rm -f "$out"; exit 4 ;;
  *) rm -f "$out"; echo "HTTP $code" >&2; exit 1 ;;
esac
