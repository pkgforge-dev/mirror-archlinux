#!/usr/bin/env bash
#
# Install invisible_playwright and its browser into playwright/ beside this
# file.
#
#   fetchers/playwright/install.sh
#
# Environment: INVISIBLE_PLAYWRIGHT_VERSION overrides the pip version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

command -v python3 > /dev/null || fetcher_die "python3 is required"

version="${INVISIBLE_PLAYWRIGHT_VERSION:-}"
if [ -z "$version" ]; then
  version="$("$HERE/../drift.sh" --key invisible-playwright | cut -f 2)"
fi
[ -n "$version" ] || fetcher_die "could not resolve the invisible_playwright version"

if [ ! -x "$HERE/venv/bin/python" ]; then
  python3 -m venv "$HERE/venv" || fetcher_die "could not make a virtual environment"
fi
"$HERE/venv/bin/pip" install --quiet "invisible-playwright==${version#v}" ||
  fetcher_die "pip could not install invisible-playwright==${version#v}"
"$HERE/venv/bin/python" -m invisible_playwright fetch ||
  fetcher_die "the browser could not be installed"
"$HERE/available"
