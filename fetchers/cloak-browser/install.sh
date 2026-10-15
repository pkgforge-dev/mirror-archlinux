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
# Retried: the npm registry resets a connection now and then, and a transient
# failure must not leave a runner without the client it installs.
retry_run "npm install cloakbrowser@$version" \
  npm install --prefix "$HERE" --no-save --no-package-lock --no-audit --no-fund \
  --fetch-retries 5 --fetch-retry-maxtimeout 60000 "cloakbrowser@$version" ||
  fetcher_die "npm could not install cloakbrowser@$version"
"$HERE/available"
