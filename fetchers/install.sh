#!/usr/bin/env bash
#
# Install one or more clients for fetchers/fetcher.sh, or report which ones
# are usable here.
#
#   fetchers/install.sh [--check] [CLIENT...]
#
# CLIENT is curl-impersonate, chromium, cloak-browser or playwright. With no
# argument every client is installed. curl needs no installer: it is a system
# tool. Each client keeps its own install.sh, so this runs them in order and
# reports which ones landed.
#
# --check installs nothing: it reports each asked client's availability, with
# a fresh probe, and exits 0 only when every one of them is available.
#
# Exit status: 0 every asked client installed, 1 one did not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

check=0
args=()
for a in "$@"; do
  case "$a" in
    --check) check=1 ;;
    *) args+=("$a") ;;
  esac
done
clients="${args[*]:-$FETCHER_CLIENTS_DEFAULT}"
rc=0
if [ "$check" -eq 1 ]; then
  FETCHER_NO_AVAILABLE_CACHE=1
  export FETCHER_NO_AVAILABLE_CACHE
  for c in $clients; do
    if ! client_known "$c"; then
      fetcher_warn "unknown client $c"
      rc=1
    elif client_available "$c"; then
      fetcher_log "$c is available"
    else
      fetcher_warn "$c is not available"
      rc=1
    fi
  done
  exit "$rc"
fi
for c in $clients; do
  case "$c" in
    curl) continue ;;
    curl-impersonate | chromium | cloak-browser | playwright) ;;
    *) fetcher_warn "unknown client $c"; rc=1; continue ;;
  esac
  if [ ! -x "$HERE/$c/install.sh" ]; then
    fetcher_warn "no installer for $c"
    rc=1
    continue
  fi
  if "$HERE/$c/install.sh"; then
    fetcher_log "$c is installed"
  else
    fetcher_warn "$c did not install"
    rc=1
  fi
done
exit "$rc"
