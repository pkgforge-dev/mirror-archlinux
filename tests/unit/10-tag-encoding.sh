#!/usr/bin/env bash
#
# Every package file maps to exactly one tag, and no two files share one.
#
# A collision would let one package's manifest answer for another's name. The
# wrapper would hand pacman the wrong bytes, pacman would refuse them, and an
# integrity failure does not fall through to the next Server: the install stops.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

W="$REPO_ROOT/client/pacman-oci"
FIXTURE="$REPO_ROOT/tests/fixtures/filenames.txt"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

#---------------------------------------------------------------------------#
# Hand-checked cases. The first two are the shapes measured in x86_64 core on
# 2026-10-13: an epoch, and a version with +.
#---------------------------------------------------------------------------#
while IFS='|' read -r name want; do
  got="$("$W" --tag "$name")"
  check "tag of $name" "$want" "$got" "client/pacman-oci --tag '$name'"
done <<'EOF'
zlib-1:1.3.2-3-x86_64.pkg.tar.zst|zlib-1_c1.3.2-3-x86_64.pkg.tar.zst
gcc-libs-15.2.1+r22+gc4e96a094636-1-x86_64.pkg.tar.zst|gcc-libs-15.2.1_pr22_pgc4e96a094636-1-x86_64.pkg.tar.zst
python-typing_extensions-4.15.0-1-any.pkg.tar.zst|python-typing_extensions-4.15.0-1-any.pkg.tar.zst
a_pb-1-1-any.pkg.tar.zst|a_upb-1-1-any.pkg.tar.zst
a_+b-1-1-any.pkg.tar.zst|a__pb-1-1-any.pkg.tar.zst
a__p-1-1-any.pkg.tar.zst|a__up-1-1-any.pkg.tar.zst
@x-1-1-any.pkg.tar.zst|_ax-1-1-any.pkg.tar.zst
+x-1-1-any.pkg.tar.zst|_px-1-1-any.pkg.tar.zst
EOF

#---------------------------------------------------------------------------#
# Names the mapping cannot carry, and names with upper case (GHCR folds the case
# of tags), are stored under the hash of the name.
#---------------------------------------------------------------------------#
long="$(printf '%*s' 120 '' | tr ' ' a)-1-1-any.pkg.tar.zst"
for name in 'bad name-1-1-any.pkg.tar.zst' '.hidden-1-1-any.pkg.tar.zst' '-dash-1-1-any.pkg.tar.zst' "$long" 'caf%C3%A9-1-1-any.pkg.tar.zst' 'lshw-B.02.20-3-x86_64.pkg.tar.zst' 'dhcp-4.4.3.P1-4-x86_64.pkg.tar.zst'; do
  want="fn-$(printf '%s' "$name" | sha256sum | cut -d ' ' -f 1)"
  got="$("$W" --tag "$name")"
  check "a name outside the mapping hashes: ${name:0:40}" "$want" "$got" "client/pacman-oci --tag '$name'"
done

# The 128 character limit, at its edge: a name that escapes to exactly 128
# characters keeps its readable tag, one more character and it is hashed.
at_limit="$(printf '%*s' 108 '' | tr ' ' a)-1-1-any.pkg.tar.zst"
over_limit="$(printf '%*s' 109 '' | tr ' ' a)-1-1-any.pkg.tar.zst"
check "a name of exactly 128 characters keeps its readable tag" "$at_limit" "$("$W" --tag "$at_limit")" \
  "client/pacman-oci --tag <128 characters>"
check "a name of 129 characters is hashed" "fn-$(printf '%s' "$over_limit" | sha256sum | cut -d ' ' -f 1)" \
  "$("$W" --tag "$over_limit")" "client/pacman-oci --tag <129 characters>"
check "the boundary fixture is the length it claims" "128 129" "${#at_limit} ${#over_limit}" "echo \${#name}"

#---------------------------------------------------------------------------#
# The inverse, written independently of the wrapper. A literal _ is kept unless
# the next character is p c a u, so _ followed by one of them is an escape.
#---------------------------------------------------------------------------#
decode() {
  awk '{
    s = $0; n = length(s); out = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "_" && i < n) {
        d = substr(s, i + 1, 1)
        if (d == "p") { out = out "+"; i++; continue }
        if (d == "c") { out = out ":"; i++; continue }
        if (d == "a") { out = out "@"; i++; continue }
        if (d == "u") { out = out "_"; i++; continue }
      }
      out = out c
    }
    print out
  }'
}

# Every string of length 1 to 4 over the characters that interact with the
# escape, as the start of a package name. 4680 names.
synthetic() {
  local alphabet=(a _ p c u + : @) a b c d
  for a in "${alphabet[@]}"; do
    printf '%s-1-1-any.pkg.tar.zst\n' "$a"
    for b in "${alphabet[@]}"; do
      printf '%s%s-1-1-any.pkg.tar.zst\n' "$a" "$b"
      for c in "${alphabet[@]}"; do
        printf '%s%s%s-1-1-any.pkg.tar.zst\n' "$a" "$b" "$c"
        for d in "${alphabet[@]}"; do
          printf '%s%s%s%s-1-1-any.pkg.tar.zst\n' "$a" "$b" "$c" "$d"
        done
      done
    done
  done
}

check_set() {
  local label="$1" names="$2"
  local pairs="$work/$label.pairs"
  "$W" --tags < "$names" > "$pairs"

  check "$label: one tag per name" "$(wc -l < "$names" | tr -d ' ')" "$(wc -l < "$pairs" | tr -d ' ')" \
    "client/pacman-oci --tags < $names | wc -l"

  local bad
  bad="$(cut -f 2 "$pairs" | awk '!/^[A-Za-z0-9_][A-Za-z0-9._-]*$/ || length($0) > 128 { n++ } END { print n + 0 }')"
  check "$label: every tag fits the OCI tag grammar" 0 "$bad" \
    "client/pacman-oci --tags < $names | cut -f 2 | grep -vE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\$'"

  local roundtrip
  roundtrip="$(grep -vE $'\tfn-[0-9a-f]{64}$' "$pairs" | cut -f 2 | decode |
    paste - <(grep -vE $'\tfn-[0-9a-f]{64}$' "$pairs" | cut -f 1) |
    awk -F '\t' '$1 != $2 { n++ } END { print n + 0 }')"
  check "$label: decoding every tag gives the name back" 0 "$roundtrip" \
    "tests/unit/10-tag-encoding.sh (decode vs names, $label)"

  check "$label: no two names share a tag" "$(sort -u "$names" | wc -l | tr -d ' ')" "$(cut -f 2 "$pairs" | sort -u | wc -l | tr -d ' ')" \
    "client/pacman-oci --tags < $names | cut -f 2 | sort | uniq -d"

  # GHCR resolves latest, LATEST and Latest to one manifest, so distinct tags
  # are not enough: they must stay distinct once the case is folded.
  check "$label: no two names share a tag once GHCR folds the case" "$(sort -u "$names" | wc -l | tr -d ' ')" \
    "$(cut -f 2 "$pairs" | tr '[:upper:]' '[:lower:]' | sort -u | wc -l | tr -d ' ')" \
    "client/pacman-oci --tags < $names | cut -f 2 | tr [:upper:] [:lower:] | sort | uniq -d"
  check "$label: no tag carries upper case" 0 "$(cut -f 2 "$pairs" | awk '/[A-Z]/ { n++ } END { print n + 0 }')" \
    "client/pacman-oci --tags < $names | cut -f 2 | grep '[A-Z]'"

  # The database tags: latest, the dates, staging and staging-<slug>, and the
  # index of a ref, index and index-<slug> (scripts/lib.sh index_tag).
  local reserved
  reserved="$(cut -f 2 "$pairs" | awk '/^(latest|staging|index)$/ || /^(staging|index)-[a-z0-9]+(-[a-z0-9]+)*$/ || /^[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]$/ { n++ } END { print n + 0 }')"
  check "$label: no package tag is a reserved database tag" 0 "$reserved" \
    "client/pacman-oci --tags < $names | cut -f 2 | grep -E '^(latest|staging|index|(staging|index)-[a-z0-9-]+|[0-9.]{10})\$'"
}

synthetic > "$work/synthetic.txt"
check_set synthetic "$work/synthetic.txt"
check_set real "$FIXTURE"

#---------------------------------------------------------------------------#
# --tag and --tags are the same mapping.
#---------------------------------------------------------------------------#
mismatch=0
while IFS= read -r name; do
  one="$("$W" --tag "$name")"
  many="$(printf '%s\n' "$name" | "$W" --tags | cut -f 2)"
  if [ "$one" != "$many" ]; then
    mismatch=$((mismatch + 1))
    diag "differs for $name: --tag $one, --tags $many"
  fi
done < <(awk 'NR % 100 == 1' "$FIXTURE")
check "--tag and --tags agree on a sample of the real names" 0 "$mismatch" \
  "client/pacman-oci --tag NAME vs printf 'NAME\\n' | client/pacman-oci --tags"

summary
