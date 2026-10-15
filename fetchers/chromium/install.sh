#!/usr/bin/env bash
#
# Install the playwright package and its full Chrome-for-Testing build into
# chromium/ beside this file.
#
#   fetchers/chromium/install.sh
#
# Environment: PLAYWRIGHT_VERSION overrides the npm version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

command -v npm > /dev/null || fetcher_die "npm is required"
command -v node > /dev/null || fetcher_die "node is required"

version="${PLAYWRIGHT_VERSION:-}"
if [ -z "$version" ]; then
  version="$("$HERE/../drift.sh" --key playwright | cut -f 2)"
fi
[ -n "$version" ] || fetcher_die "could not resolve the playwright version"

fetcher_log "installing playwright@$version"
npm install --prefix "$HERE" --no-save --no-package-lock --no-audit --no-fund "playwright@$version" ||
  fetcher_die "npm could not install playwright@$version"
deps=()
if [ "${PLAYWRIGHT_WITH_DEPS:-0}" = 1 ]; then
  deps=(--with-deps)
fi
"$HERE/node_modules/.bin/playwright" install "${deps[@]}" chromium ||
  fetcher_die "the chromium build could not be installed"
"$HERE/available"
