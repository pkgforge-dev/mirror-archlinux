#!/usr/bin/env bash
#
# Check the fetchers on this host: which clients are available, and whether
# each can read a small known URL. Run it on a runner or a workstation after
# fetchers/install.sh.
#
#   fetchers/self-check.sh [--strict] [URL]
#
# URL defaults to the ArchPOWER powerpc64le database signature, 119 bytes.
# --expect is read from the URL: .db and .files are databases, .sig is a
# signature, anything else is any.
#
# The manager's own answer decides the exit status. --strict also requires
# every available client to read the URL, which is what a runner that installed
# a browser wants to know.
#
# Exit status: 0 the manager read the URL (and, with --strict, every available
# client did), 1 it did not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

strict=0
case "${1:-}" in
  --strict)
    strict=1
    shift
    ;;
esac
url="${1:-${FETCHER_SELFCHECK_URL:-https://repo.archlinuxpower.org/base/powerpc64le/base.db.sig}}"
case "$url" in
  *.db | *.files) expect=db ;;
  *.sig) expect=sig ;;
  *) expect=any ;;
esac

printf 'host: %s\n' "$(uname -s -m)"
printf 'url: %s (expect=%s)\n' "$url" "$expect"
"$HERE/fetcher.sh" --explain --no-cache "$url"

work="$(mktemp -d)"
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

rc=0
# The fetcher's own chatter goes to a file: it is not this script's output,
# and its status is what the line below prints.
"$HERE/fetcher.sh" --quiet --no-cache --expect "$expect" "$url" "$work/body" > "$work/manager.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'manager: read it\n'
else
  printf 'manager: status %s\n' "$rc"
fi

strict_rc=0
# A command substitution in an assignment is exempt from set -e, so a --list
# that failed would leave this empty, the loop below would run zero times, and
# --strict would exit 0 having checked no client at all. So the status is read.
list_rc=0
clients="$("$HERE/fetcher.sh" --list --no-cache)" || list_rc=$?
if [ "$list_rc" -ne 0 ]; then
  fetcher_die "could not list the clients (status $list_rc)" \
    "reproduce: fetchers/fetcher.sh --list"
fi
checked=0
for c in $clients; do
  [ -n "$c" ] || continue
  crc=0
  # As above: the chatter goes to a file per client, the status is printed.
  "$HERE/fetcher.sh" --quiet --no-cache --client "$c" --expect "$expect" "$url" "$work/body-$c" > "$work/log-$c" 2>&1 || crc=$?
  checked=$((checked + 1))
  if [ "$crc" -eq 0 ]; then
    printf '%s: read it\n' "$c"
  else
    printf '%s: status %s\n' "$c" "$crc"
    strict_rc=1
  fi
done
# No client answered --list, so nothing was checked. That is not a pass.
if [ "$checked" -eq 0 ]; then
  fetcher_die "no client could run here, so no client was checked" \
    "reproduce: fetchers/fetcher.sh --list"
fi

if [ "$strict" -eq 1 ]; then
  exit "$strict_rc"
fi
exit "$rc"
