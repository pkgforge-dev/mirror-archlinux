#!/usr/bin/env bash
#
# Resolve the newest release of each tool the fetchers use, and cache it.
#
#   fetchers/drift.sh [--json | --env] [--key NAME] [--ttl SECONDS] [--force]
#
# Nothing here is pinned by hand: each value comes from the release the tool's
# own project publishes, at the time it is read. A value is kept in the cache
# (FETCHER_CACHE/drift.json, default 24 h) so a workflow does not ask on every
# job, and a lookup that fails keeps the cached value rather than moving
# backwards. --force ignores the cache.
#
# KEYS
#   curl-impersonate      lexiforest/curl-impersonate, the maintained fork
#   cloak-browser         the cloakbrowser npm package
#   invisible-playwright  feder-cr/invisible_playwright
#   playwright            the playwright npm package
#
# Exit status: 0 every asked key resolved (from the network or the cache), 1 a
# key has no value at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

command -v jq > /dev/null || fetcher_die "jq is required"
command -v curl > /dev/null || fetcher_die "curl is required"

mode="tsv"
ttl="${DRIFT_TTL:-86400}"
force=0
only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) mode=json; shift ;;
    --env) mode="env"; shift ;;
    --key)
      [ "$#" -ge 2 ] || fetcher_die "--key needs a value"
      only="$2"
      shift 2
      ;;
    --ttl)
      [ "$#" -ge 2 ] || fetcher_die "--ttl needs a value"
      ttl="$2"
      shift 2
      ;;
    --force) force=1; shift ;;
    *) fetcher_die "unknown option $1" ;;
  esac
done
case "$ttl" in
  '' | *[!0-9]*) fetcher_die "--ttl must be a number of seconds, not '$ttl'" ;;
esac

# The key, its owner/repo, and the JSON path to the version, as
# PROJECT-OR-EMPTY<TAB>REPO<TAB>KIND.
drift_sources() {
  cat << 'EOF'
curl-impersonate	lexiforest/curl-impersonate	release
cloak-browser	cloakbrowser	npm
invisible-playwright	feder-cr/invisible_playwright	release
playwright	playwright	npm
EOF
}

if [ -n "$only" ]; then
  known="$(drift_sources | awk -F '\t' -v k="$only" '$1 == k { print $1 }')"
  [ -n "$known" ] || fetcher_die "unknown key $only" "reproduce: fetchers/drift.sh --json"
fi

cache_file="$FETCHER_CACHE/drift.json"
mkdir -p "$FETCHER_CACHE"
stamp=0
if [ -s "$cache_file" ]; then
  # A cache file that does not read is a cache miss, not an error: the lookup
  # below runs anyway. So the status goes unused on purpose, and a stamp that
  # is not a number reads as 0, which is the same as no cache.
  if stamp="$(jq -r '.fetched // 0' "$cache_file")"; then
    case "$stamp" in
      '' | *[!0-9]*) stamp=0 ;;
    esac
  else
    stamp=0
  fi
fi
now="$(date -u +%s)"
fresh=0
if [ "$force" -eq 0 ] && [ "$stamp" -gt 0 ] && [ $((now - stamp)) -lt "$ttl" ]; then
  fresh=1
fi

# fetch_release REPO -> the newest release tag, or empty
fetch_release() {
  local repo="$1" out rc=0
  out="$(mktemp)"
  rc=0
  curl -q --fail --silent --show-error --location \
    --connect-timeout 20 --max-time 60 \
    --header 'Accept: application/vnd.github+json' \
    --user-agent 'mirror-archlinux-fetcher (+https://github.com/pkgforge-dev/mirror-archlinux)' \
    --output "$out" "https://api.github.com/repos/$repo/releases/latest" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    return 1
  fi
  jq -r '.tag_name // empty' "$out"
  rm -f "$out"
}

# fetch_npm NAME -> the newest version, or empty
fetch_npm() {
  local name="$1" out rc=0
  out="$(mktemp)"
  rc=0
  curl -q --fail --silent --show-error --location \
    --connect-timeout 20 --max-time 60 \
    --user-agent 'mirror-archlinux-fetcher (+https://github.com/pkgforge-dev/mirror-archlinux)' \
    --output "$out" "https://registry.npmjs.org/$name/latest" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out"
    return 1
  fi
  jq -r '.version // empty' "$out"
  rm -f "$out"
}

values="{}"
if [ -s "$cache_file" ]; then
  # The cached values are always loaded, so a stale cache whose lookup fails
  # keeps its value instead of moving backwards.
  values="$(jq -c '.values // {}' "$cache_file")"
fi

failed=0
while IFS=$'\t' read -r key repo kind; do
  [ -n "$key" ] || continue
  if [ -n "$only" ] && [ "$only" != "$key" ]; then continue; fi
  have="$(jq -r --arg k "$key" '.[$k] // empty' <<< "$values")"
  if [ "$fresh" -eq 1 ] && [ -n "$have" ]; then
    continue
  fi
  val=""
  case "$kind" in
    # A lookup that fails leaves val empty, and the empty case below keeps the
    # cached value rather than moving the version backwards. The status is
    # read into a named variable so the failure is not a silent `|| true`.
    release)
      val="$(fetch_release "$repo")" || val=""
      ;;
    npm)
      val="$(fetch_npm "$repo")" || val=""
      ;;
  esac
  if [ -n "$val" ]; then
    values="$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<< "$values")"
  elif [ -n "$have" ]; then
    fetcher_warn "kept the cached $key=$have; the lookup for $repo failed"
  else
    fetcher_warn "no value for $key ($repo)"
    failed=1
  fi
done < <(drift_sources)

if [ "$fresh" -eq 0 ]; then
  # Written aside, then moved, so a caller that reads the cache while this one
  # writes never reads a half-written file.
  tmp="$cache_file.$$"
  if jq -n --argjson v "$values" --argjson f "$now" '{fetched: $f, values: $v}' > "$tmp"; then
    mv -f "$tmp" "$cache_file"
  else
    rm -f "$tmp"
  fi
fi

case "$mode" in
  json) jq -c . <<< "$values" ;;
  env)
    while IFS=$'\t' read -r key _ _; do
      [ -n "$key" ] || continue
      if [ -n "$only" ] && [ "$only" != "$key" ]; then continue; fi
      v="$(jq -r --arg k "$key" '.[$k] // empty' <<< "$values")"
      printf 'export DRIFT_%s=%q\n' "$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')" "$v"
    done < <(drift_sources)
    ;;
  tsv)
    while IFS=$'\t' read -r key _ _; do
      [ -n "$key" ] || continue
      if [ -n "$only" ] && [ "$only" != "$key" ]; then continue; fi
      printf '%s\t%s\n' "$key" "$(jq -r --arg k "$key" '.[$k] // empty' <<< "$values")"
    done < <(drift_sources)
    ;;
esac
exit "$failed"
