#!/usr/bin/env bash
#
# Install the cloakbrowser package into cloak-browser/ beside this file.
#
#   fetchers/cloak-browser/install.sh
#
# Environment: CLOAK_BROWSER_VERSION overrides the npm version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

command -v npm > /dev/null || fetcher_die "npm is required"
command -v node > /dev/null || fetcher_die "node is required"

version="${CLOAK_BROWSER_VERSION:-}"
if [ -z "$version" ]; then
  version="$("$HERE/../drift.sh" --key cloak-browser | cut -f 2)"
fi
[ -n "$version" ] || fetcher_die "could not resolve the cloakbrowser version"

fetcher_log "installing cloakbrowser@$version"
npm install --prefix "$HERE" --no-save --no-package-lock --no-audit --no-fund "cloakbrowser@$version" ||
  fetcher_die "npm could not install cloakbrowser@$version"
"$HERE/available"
