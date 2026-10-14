#!/usr/bin/env bash
#
# Every target file parses, names a database server and a package server, and
# pins its images by digest with a tag Renovate can follow. Every target
# verifies in the one x86_64 image; a trust root brought in from another image
# comes from pkgforge-dev's own Arch images only. The sync workflow can upload
# the plan of every enabled target.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

cd "$REPO_ROOT"

# get CONF KEY -> the value, read the way the scripts read it
get() {
  SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_get "$1" "$2"' _ "$1" "$2"
}

# tag_marker CONF KEY -> the tag on the "# tag:" line right before KEY's line
tag_marker() {
  awk -v k="$2" '
    { line = $0; key = line; sub(/[[:space:]]*=.*/, "", key) }
    key == k && line ~ /=/ { print prev; found = 1 }
    { prev = line }
    END { if (!found) print "" }
  ' "$1" | sed -n 's/^#[[:space:]]*tag:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p'
}

found=0
enabled=0
verify_images=""
for conf in targets/*.conf; do
  [ -e "$conf" ] || continue
  found=$((found + 1))
  out="$(SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_check "$1"' _ "$conf" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$conf parses"
  else
    fail "$conf parses" "$out" "reproduce: bash -c '. scripts/lib.sh; target_check $conf'"
  fi
  if SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_enabled "$1"' _ "$conf"; then
    enabled=$((enabled + 1))
  fi

  for key in verify_image keyring_image; do
    image="$(get "$conf" "$key")"
    if [ -z "$image" ]; then
      if [ "$key" = verify_image ]; then
        fail "$conf names a verify image" "no verify_image" "reproduce: grep verify_image $conf"
      fi
      continue
    fi
    if printf '%s\n' "$image" | grep -Eq '^[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'; then
      ok "$conf pins its $key as name:tag@sha256"
    else
      fail "$conf pins its $key as name:tag@sha256" "$key = $image" \
        "a digest alone gives Renovate no tag to follow, a tag alone is not a pin" \
        "reproduce: grep $key $conf"
    fi
    tag="${image%@*}"
    tag="${tag##*:}"
    check "$conf: the line before $key says '# tag: $tag', for Renovate" "$tag" "$(tag_marker "$conf" "$key")" \
      "grep -B1 '^$key' $conf"
  done
  verify_images="$verify_images$(get "$conf" verify_image) $(get "$conf" verify_platform)"$'\n'

  image="$(get "$conf" keyring_image)"
  if [ -n "$image" ]; then
    case "$image" in
      ghcr.io/pkgforge-dev/archlinux:*) ok "$conf: keyring_image is one of pkgforge-dev's own Arch images" ;;
      *) fail "$conf: keyring_image is one of pkgforge-dev's own Arch images" "keyring_image = $image" \
        "the trust root of verify comes from ghcr.io/pkgforge-dev/archlinux only" "reproduce: grep keyring_image $conf" ;;
    esac
    if [ -n "$(get "$conf" keyring_platform)" ]; then
      ok "$conf: keyring_image comes with keyring_platform"
    else
      fail "$conf: keyring_image comes with keyring_platform" "no keyring_platform" "reproduce: grep keyring_ $conf"
    fi
  fi

  from="$(get "$conf" keyring_from)"
  if [ -n "$from" ]; then
    if [ -f "targets/$from.conf" ] && SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_enabled "$1"' _ "targets/$from.conf"; then
      ok "$conf: keyring_from $from is an enabled target"
    else
      fail "$conf: keyring_from $from is an enabled target" "targets/$from.conf is missing or not enabled" "reproduce: ls targets/$from.conf"
    fi
  fi

  for key in server db_server; do
    bad="$(SCRIPT_NAME=target bash -c '. scripts/lib.sh; target_all "$1" "$2"' _ "$conf" "$key" | grep -v '^https://' || [ "$?" -eq 1 ])"
    if [ -z "$bad" ]; then
      ok "$conf: every $key is https"
    else
      fail "$conf: every $key is https" "$bad" "reproduce: grep '^$key' $conf"
    fi
  done
done
if [ "$found" -eq 0 ]; then
  fail "there is a target to mirror" "no targets/*.conf" "reproduce: ls targets"
fi

# One verify image for every target: x86_64 Arch, Architecture set from the
# target, so Renovate moves them all in one change and no target needs QEMU.
distinct="$(printf '%s' "$verify_images" | sort -u)"
if [ "$(printf '%s\n' "$distinct" | awk 'NF { n++ } END { print n + 0 }')" -eq 1 ] && [ "${distinct##* }" = linux/amd64 ]; then
  ok "every target verifies in the one image, on linux/amd64"
else
  fail "every target verifies in the one image, on linux/amd64" "$distinct" "reproduce: grep -h -A1 '^verify_image' targets/*.conf | sort -u"
fi

# The plan job uploads each pending target's plan from a slot step of its
# own; there must be a slot for every enabled target.
slots="$(grep -oE 'steps\.plan\.outputs\.slot[0-9]+' .github/workflows/sync.yml | sort -u | awk 'END { print NR + 0 }')"
if [ "$slots" -ge "$enabled" ]; then
  ok "sync.yml has a plan upload slot for each of the $enabled enabled target(s) ($slots)"
else
  fail "sync.yml has a plan upload slot for each of the $enabled enabled target(s)" "$slots slot(s)" \
    "add slot steps to the plan job" "reproduce: grep -c 'outputs.slot' .github/workflows/sync.yml"
fi

# sync-target.yml downloads a chain's artifacts by <kind>-<target>-[0-9]*. A
# target named like another plus "-" and a digit (x86_64-core-2 beside
# x86_64-core) would match that pattern and read the other chain's files.
overlap="$(for c in targets/*.conf; do basename "$c" .conf; done | awk '
  { name[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) for (j = 1; j <= NR; j++)
      if (i != j && index(name[j], name[i] "-") == 1 && substr(name[j], length(name[i]) + 2, 1) ~ /[0-9]/)
        print name[j] " extends " name[i]
  }')"
if [ -z "$overlap" ]; then
  ok "no target name is another's name, a dash and a digit"
else
  fail "no target name is another's name, a dash and a digit" "$overlap" \
    "the artifact patterns of sync-target.yml would mix the two chains" "reproduce: ls targets"
fi

summary
