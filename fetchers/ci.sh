#!/usr/bin/env bash
#
# Install the fetcher clients on a build runner, then check them.
#
#   fetchers/ci.sh [--with-deps] [CLIENT...]
#
# CLIENT is curl-impersonate, chromium, cloak-browser or playwright. With no
# argument it installs curl-impersonate and chromium, which is what a runner
# needs to read a host that answers curl with an interstitial. curl needs no
# installer.
#
# --with-deps asks the chromium installer for the system packages the browser
# needs (PLAYWRIGHT_WITH_DEPS).
#
# Every client that was asked for must be available after its install, and
# fetchers/self-check.sh --strict must read a small URL through each available
# client. Set FETCHER_SELFCHECK_URL to read another URL.
#
# Exit status: 0 all of that happened, 1 it did not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

with_deps=0
clients=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-deps)
      with_deps=1
      shift
      ;;
    --help | -h)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      fetcher_die "unknown option $1" "reproduce: fetchers/ci.sh --help"
      ;;
    *)
      clients+=("$1")
      shift
      ;;
  esac
done
if [ "${#clients[@]}" -eq 0 ]; then
  clients=(curl-impersonate chromium)
fi
for c in "${clients[@]}"; do
  client_known "$c" || fetcher_die "unknown client $c" "reproduce: fetchers/fetcher.sh --list"
done
if [ "$with_deps" -eq 1 ]; then
  export PLAYWRIGHT_WITH_DEPS=1
fi

rc=0
for c in "${clients[@]}"; do
  [ "$c" = curl ] && continue
  fetcher_log "installing $c"
  if ! "$HERE/$c/install.sh"; then
    fetcher_warn "$c did not install"
    rc=1
    continue
  fi
  if ! FETCHER_NO_AVAILABLE_CACHE=1 "$HERE/$c/available"; then
    fetcher_warn "$c installed but is not available"
    rc=1
  fi
done
[ "$rc" -eq 0 ] || exit "$rc"

FETCHER_NO_AVAILABLE_CACHE=1 "$HERE/self-check.sh" --strict
