#!/usr/bin/env bash
#
# Read a URL through the r.jina.ai reader, which dials the origin from its own
# network. ⚠ r.jina.ai reads a web page: it refuses a binary content type (a
# database, a signature or a package file) with 422, so for this tree it is a
# best-effort last resort and the next client takes over. It is kept for a text
# origin and for defence in depth.
#
#   fetchers/jina/fetch.sh URL OUT [HEADER...]
#
# Environment:
#   JINA_BASE  the reader, without a trailing slash (default https://r.jina.ai)
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
base="${JINA_BASE:-https://r.jina.ai}"

code=""
rc=0
# X-Respond-With: no-content keeps the reader from wrapping the body, so a text
# origin comes through as itself. A binary content type is still refused with
# 422, which this maps to status 1 so the next client is tried.
code="$(curl -q --location --silent --show-error --max-redirs 5 \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout "${FETCHER_CONNECT_TIMEOUT:-20}" \
  --speed-limit 1024 --speed-time 60 \
  --max-time "${FETCHER_MAX_TIME:-300}" \
  --header 'X-Respond-With: no-content' "${hdr[@]}" \
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
