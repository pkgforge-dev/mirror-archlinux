#!/usr/bin/env bash
#
# Install the maintained curl-impersonate fork (lexiforest/curl-impersonate)
# into dist/, next to this file. The release is the newest one the project
# publishes; the archive is checked against the release asset's sha256 digest,
# which GitHub publishes per asset, or against a checksum file when the release
# has one.
#
#   fetchers/curl-impersonate/install.sh
#
# Environment: CURL_IMPERSONATE_TAG overrides the release tag (a test or a pin),
# CURL_IMPERSONATE_RELEASE_JSON reads the release from a file instead of the
# API, CURL_IMPERSONATE_PRINT_ASSET prints the chosen asset and exits,
# FETCHER_ALLOW_UNVERIFIED=1 accepts an archive with no digest and no checksum
# file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

need_net() { command -v curl > /dev/null || fetcher_die "curl is required"; }
command -v jq > /dev/null || fetcher_die "jq is required"

arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) arch_re='x86_64|amd64' ;;
  aarch64 | arm64) arch_re='aarch64|arm64' ;;
  *) fetcher_die "no curl-impersonate build is known for $arch" ;;
esac

tag="${CURL_IMPERSONATE_TAG:-}"
if [ -z "$tag" ]; then
  need_net
  tag="$("$HERE/../drift.sh" --key curl-impersonate | cut -f 2)"
fi
[ -n "$tag" ] || fetcher_die "could not resolve the curl-impersonate release tag"

work="$(mktemp -d)"
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

release="$work/release.json"
if [ -n "${CURL_IMPERSONATE_RELEASE_JSON:-}" ]; then
  # A fixture, so a test can drive the asset choice with no network.
  cp "$CURL_IMPERSONATE_RELEASE_JSON" "$release" || fetcher_die "could not read the release fixture"
else
  need_net
  curl -q --fail --silent --show-error --location --connect-timeout 20 --max-time 120 \
    --retry 3 --retry-connrefused --retry-delay 2 --retry-all-errors \
    --header 'Accept: application/vnd.github+json' \
    --user-agent 'mirror-archlinux-fetcher (+https://github.com/pkgforge-dev/mirror-archlinux)' \
    --output "$release" "https://api.github.com/repos/lexiforest/curl-impersonate/releases/tags/$tag" \
    || fetcher_die "could not read the release $tag"
fi

# Picked deterministically: the CLI archive, not the libcurl library, for this
# architecture and linux, gnu before musl, and the name breaks any tie. Asset
# order is not relied on.
asset="$(jq -c --arg re "$arch_re" '
  [ .assets[]
    | select(.name | test("linux"))
    | select(.name | test($re))
    | select(.name | test("debug|symbols|\\.deb|\\.rpm|android|freebsd|macos|win32") | not)
    | select(.name | test("libcurl") | not)
    | { name: .name, url: .browser_download_url, digest: (.digest // ""),
        score: (if (.name | test("gnu")) then 0 else 1 end) }
  ]
  | sort_by(.score, .name) | (.[0] // empty)' "$release")"
[ -n "$asset" ] || fetcher_die "release $tag has no linux $arch asset" \
  "reproduce: curl -s https://api.github.com/repos/lexiforest/curl-impersonate/releases/tags/$tag | jq -r '.assets[].name'"
asset_url="$(printf '%s' "$asset" | jq -r '.url')"
asset_digest="$(printf '%s' "$asset" | jq -r '.digest')"

if [ "${CURL_IMPERSONATE_PRINT_ASSET:-0}" = 1 ]; then
  printf '%s\n' "$asset_url"
  exit 0
fi

# A checksum file, if the release still publishes one; some older releases did.
sum_url="$(jq -r '
  [.assets[] | select(.name | test("check|sha|SUM"; "i"))][0].browser_download_url // empty' "$release")"

name="$(basename "$asset_url")"
curl -q --fail --silent --show-error --location --connect-timeout 20 --max-time 600 \
  --retry 3 --retry-connrefused --retry-delay 2 --retry-all-errors \
  --user-agent 'mirror-archlinux-fetcher (+https://github.com/pkgforge-dev/mirror-archlinux)' \
  --output "$work/$name" "$asset_url" || fetcher_die "could not download $asset_url"

got="$(sha256sum "$work/$name" | cut -d ' ' -f 1)"
case "$asset_digest" in
  sha256:*)
    # GitHub publishes a sha256 digest per asset, computed from the uploaded
    # bytes, so the newest release format needs no separate checksum file.
    want="${asset_digest#sha256:}"
    [ "$want" = "$got" ] || fetcher_die "$name is sha256 $got, the release asset digest says $want"
    fetcher_log "checked $name against the release asset digest"
    ;;
  *)
    if [ -n "$sum_url" ]; then
      curl -q --fail --silent --show-error --location --connect-timeout 20 --max-time 120 \
        --user-agent 'mirror-archlinux-fetcher (+https://github.com/pkgforge-dev/mirror-archlinux)' \
        --output "$work/checksums" "$sum_url" || fetcher_die "could not download the checksums of $tag"
      want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$work/checksums" | sed -n 1p)"
      [ -n "$want" ] || fetcher_die "the checksum file of $tag names no $name"
      [ "$want" = "$got" ] || fetcher_die "$name is sha256 $got, the release says $want"
      fetcher_log "checked $name against the release checksum"
    elif [ "${FETCHER_ALLOW_UNVERIFIED:-0}" != 1 ]; then
      fetcher_die "release $tag gives $name no asset digest and no checksum file; set FETCHER_ALLOW_UNVERIFIED=1 to accept it"
    fi
    ;;
esac

# Unpack to a staging directory first, then read the shape. --strip-components
# on a flat archive (v2.x ships the binary and the wrappers at the top, with no
# directory) exits 0 yet drops every file, so the shape cannot be guessed by
# trying --strip first. One top-level directory is unwrapped; files at the top
# are taken as they are.
stage="$work/stage"
mkdir -p "$stage"
tar -xf "$work/$name" -C "$stage" 2> "$work/untar.err" \
  || fetcher_die "the downloaded asset does not unpack: $(sed -n 1p "$work/untar.err")"
entries=("$stage"/*)
if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
  src="${entries[0]}"
else
  src="$stage"
fi
rm -rf "$HERE/dist"
mkdir -p "$HERE/dist"
mv "$src"/* "$HERE/dist/" || fetcher_die "the asset $name unpacked to no files"
fetcher_log "installed $tag into $HERE/dist"
"$HERE/available"
