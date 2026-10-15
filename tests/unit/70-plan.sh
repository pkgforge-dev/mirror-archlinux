#!/usr/bin/env bash
#
# scripts/plan on a signed repository: `<repo>.db.sig` and `<repo>.files.sig`
# are checked with gpgv against the keyring files of the target before the
# database is used. A signature of a key the keyring does not hold, a
# signature of another file, and a database changed after it was signed are
# refused, and the target goes to error.
#
# The upstream and the registry are answered by tests/fixtures/status/fake-curl
# from files under FAKE_CURL_ROOT, so nothing here needs a network. The keyring
# files come from PLAN_KEYRING_DIR, the test seam for keyring_image.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

if ! need_tool gpg "plan: a signed database is checked with gpgv" ||
  ! need_tool gpgv "plan: a signed database is checked with gpgv" ||
  ! need_tool tar "plan: a signed database is checked with gpgv" ||
  ! need_tool jq "plan: a signed database is checked with gpgv"; then
  summary
  exit $?
fi

net="$work/net"
bin="$work/bin"
mkdir -p "$bin" "$net/ghcr.io" "$net/up.test/base/powerpc64le" "$work/targets" "$work/up"
cp "$REPO_ROOT/tests/fixtures/status/fake-curl" "$bin/curl"
chmod +x "$bin/curl"
printf '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}\n' > "$net/ghcr.io/.404"

# pkg DIR NAME VERSION ARCH CSIZE BUILDDATE: one desc entry
pkg() {
  local dir="$1" name="$2" ver="$3" arch="$4" csize="$5" built="$6" sha
  sha="$(printf '%s-%s' "$name" "$ver" | sha256sum | cut -d ' ' -f 1)"
  mkdir -p "$dir/$name-$ver"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%CSIZE%%\n%s\n\n%%SHA256SUM%%\n%s\n\n%%BUILDDATE%%\n%s\n\n%%ARCH%%\n%s\n\n' \
    "$name-$ver-$arch.pkg.tar.zst" "$name" "$ver" "$csize" "$sha" "$built" "$arch" > "$dir/$name-$ver/desc"
}

pkg "$work/up" kernel 6.17-1 powerpc64le 1000 1790000000
pkg "$work/up" musl 1.2.5-1 powerpc64le 2000 1790000000
db="$net/up.test/base/powerpc64le/base.db"
files="$net/up.test/base/powerpc64le/base.files"
( cd "$work/up" && tar -czf "$db" -- * )
# The files database names the same packages, with the same sha256, and holds
# a files member too, so its bytes differ from the database's.
cp -r "$work/up" "$work/upfiles"
printf '%%FILES%%\nusr/bin/kernel\n\n' > "$work/upfiles/kernel-6.17-1/files"
printf '%%FILES%%\nusr/bin/musl\n\n' > "$work/upfiles/musl-1.2.5-1/files"
( cd "$work/upfiles" && tar -czf "$files" -- * )

export GNUPGHOME="$work/home"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-gen-key 'Mirror Sign <sign@mirror.test>' ed25519 sign 1d > /dev/null 2>&1
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-gen-key 'Mirror Other <other@mirror.test>' ed25519 sign 1d > /dev/null 2>&1
mkdir -p "$work/keys-good" "$work/keys-other"
gpg --batch --quiet --export 'sign@mirror.test' > "$work/keys-good/sign.gpg"
gpg --batch --quiet --export 'other@mirror.test' > "$work/keys-other/other.gpg"
sign() {  # sign KEY FILE
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase '' -u "$1" \
    --detach-sign -o "$2.sig" "$2"
}
sign 'sign@mirror.test' "$db"
sign 'sign@mirror.test' "$files"

cat > "$work/targets/powerpc64le-base.conf" << 'EOF'
arch = powerpc64le
repo = base
db_server = https://up.test/$repo/$arch
db_signed = yes
keyring = archpower-keyring
EOF

# run_plan KEYRING_DIR -> scripts/plan's status; the output is in $work/out
run_plan() {
  local rc=0
  rm -rf "$work/out"
  PATH="$bin:$PATH" FAKE_CURL_ROOT="$net" PLAN_KEYRING_DIR="$1" PLAN_BUDGET=60 \
    TARGETS_DIR="$work/targets" MIRROR_NAMESPACE=test/mirror MIRROR_REGISTRY=ghcr.io \
    "$REPO_ROOT/scripts/plan" "$work/out" "$work/targets/powerpc64le-base.conf" \
    > "$work/plan.out" 2> "$work/plan.err" || rc=$?
  return "$rc"
}
state() {
  cat "$work/out/powerpc64le-base/state" 2> /dev/null || printf 'no state file'
}
RP="PLAN_KEYRING_DIR=DIR PATH=<fake-curl>:\$PATH FAKE_CURL_ROOT=<fixtures> scripts/plan OUT targets/powerpc64le-base.conf"

rc=0
run_plan "$work/keys-good" || rc=$?
check "plan: a signed database that verifies exits 0" 0 "$rc" "$RP; see $work/plan.err"
check "plan: a signed database that verifies leaves the target pending" pending "$(state)" "$RP"
if grep -q 'verify against the keyring files' "$work/plan.err"; then
  ok "plan: the log names that both signatures verify"
else
  fail "plan: the log names that both signatures verify" "$(sed -n 1,10p "$work/plan.err")" "$RP"
fi

rc=0
run_plan "$work/keys-other" || rc=$?
check "plan: a signature of a key the keyring does not hold refuses the target" error "$(state)" "$RP"
if grep -q 'base.db.sig does not verify' "$work/plan.err"; then
  ok "plan: the refusal names the file whose signature failed"
else
  fail "plan: the refusal names the file whose signature failed" "$(sed -n 1,10p "$work/plan.err")" "$RP"
fi

# A valid signature, but of the files database: it must not pass for the
# database.
cp "$files.sig" "$db.sig"
rc=0
run_plan "$work/keys-good" || rc=$?
check "plan: a signature of the files database does not pass for the database" error "$(state)" "$RP"
sign 'sign@mirror.test' "$db"

# The database changes after it was signed: the old signature no longer names
# these bytes.
pkg "$work/up" glibc 2.42-1 powerpc64le 3000 1790000000
( cd "$work/up" && tar -czf "$db" -- * )
rc=0
run_plan "$work/keys-good" || rc=$?
check "plan: a database changed after it was signed is refused" error "$(state)" "$RP"
sign 'sign@mirror.test' "$db"
rm -rf "$work/upfiles"
cp -r "$work/up" "$work/upfiles"
for d in "$work/upfiles"/*/; do
  printf '%%FILES%%\nusr/bin/%s\n\n' "$(basename "$d")" > "$d/files"
done
( cd "$work/upfiles" && tar -czf "$files" -- * )
sign 'sign@mirror.test' "$files"

rc=0
run_plan "$work/keys-good" || rc=$?
check "plan: the same database, signed again, passes" pending "$(state)" "$RP"

summary
