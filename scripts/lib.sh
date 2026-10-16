# Shared helpers for the scripts in this directory. Sourced, never executed.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Everything here reads its inputs as data. A target file is parsed, never
# sourced; a database is parsed field by field and every field is checked
# against its grammar before any of it reaches a path, a command line or a tag.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC2034 # read by the scripts that source this file
WRAPPER="$REPO_ROOT/client/pacman-oci"
# The targets directory; the integration suite points this at its own.
TARGETS_DIR="${TARGETS_DIR:-$REPO_ROOT/targets}"

#---------------------------------------------------------------------------#
# Messages
#
# die prints what was measured and what reproduces it, one item per line. In
# Actions the first line is also an error annotation, so it shows on the run's
# summary page without opening the log.
#---------------------------------------------------------------------------#
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"

# A command that ends a script under set -e says which one, where, and how,
# so no exit is ever silent. -E carries the trap into functions; a command in
# an if, while, || or && never triggers it, exactly as set -e is never
# triggered there.
set -E
trap 'printf "%s: line %s: %s ended with status %s\n" "$SCRIPT_NAME" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

log() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
}

warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  else
    printf '%s: warning: %s\n' "$SCRIPT_NAME" "$1" >&2
  fi
  shift
  while [ "$#" -gt 0 ]; do
    printf '  %s\n' "$1" >&2
    shift
  done
}

die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  else
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
  fi
  shift
  while [ "$#" -gt 0 ]; do
    printf '  %s\n' "$1" >&2
    shift
  done
  exit 1
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" > /dev/null || die "$c is required and is not on PATH"
  done
}

#---------------------------------------------------------------------------#
# Targets
#
# targets/<arch>-<repo>.conf: `key = value` lines, # comments, a key may repeat
# where the list below says so. An unknown key is an error: a typo that is
# ignored is a setting that silently does nothing.
#
# The keys that set the trust root of verify (scripts/verify-batch):
#   keyring           the keyring packages, space separated. verify installs
#                     them from the snapshot, then populates again.
#   keyring_from      a target <arch>-<repo> of the same arch whose promoted
#                     latest holds the keyring packages, when the target's own
#                     repository does not.
#   keyring_image     an image name:tag@sha256:<64 hex> whose
#                     /usr/share/pacman/keyrings/* is copied into the verify
#                     container before the first populate. Nothing in it runs.
#   keyring_platform  the platform of keyring_image, e.g. linux/arm64.
#---------------------------------------------------------------------------#
TARGET_KEYS_ONCE="arch repo verify_image verify_platform keyring keyring_from keyring_image keyring_platform enabled db_signed"
TARGET_KEYS_MANY="server db_server"
# An image pinned by digest, with a tag Renovate can follow.
IMAGE_PIN_RE='^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'

# target_check CONF -> exit 0, or die naming the line
target_check() {
  local conf="$1"
  [ -f "$conf" ] || die "no target file $conf"
  awk -v once=" $TARGET_KEYS_ONCE " -v many=" $TARGET_KEYS_MANY " -v f="$conf" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      if (line !~ /^[a-z_]+[[:space:]]*=[[:space:]]*[^[:space:]].*$/) {
        printf "%s:%d: not key = value: %s\n", f, NR, line; bad = 1; next
      }
      k = line; sub(/[[:space:]]*=.*/, "", k)
      if (index(once, " " k " ")) {
        if (seen[k]++) { printf "%s:%d: %s is given twice\n", f, NR, k; bad = 1 }
        next
      }
      if (index(many, " " k " ")) next
      printf "%s:%d: unknown key %s\n", f, NR, k; bad = 1
    }
    END { exit bad }
  ' "$conf" >&2 || die "$conf is not a valid target file" "reproduce: bash -c '. scripts/lib.sh; target_check $conf'"
  local arch repo
  arch="$(target_get "$conf" arch)"
  repo="$(target_get "$conf" repo)"
  [[ "$arch" =~ ^[a-z0-9]+(_[a-z0-9]+)*$ ]] || die "$conf: arch '$arch' is not a pacman architecture"
  [[ "$repo" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]] || die "$conf: repo '$repo' is not a repository name"
  [ "$(basename "$conf")" = "$arch-$repo.conf" ] || die "$conf must be named $arch-$repo.conf"
  [ -n "$(target_all "$conf" db_server)" ] || die "$conf has no db_server"
  case "$(target_get "$conf" db_signed)" in
    '' | yes | no) ;;
    *) die "$conf: db_signed must be yes or no" ;;
  esac

  # The trust root of verify. read -a splits without glob expansion.
  local keyrings k image platform from
  keyrings="$(target_get "$conf" keyring)"
  local names=()
  read -r -a names <<< "$keyrings"
  for k in "${names[@]}"; do
    [[ "$k" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || die "$conf: keyring '$k' is not a package name"
  done
  image="$(target_get "$conf" keyring_image)"
  platform="$(target_get "$conf" keyring_platform)"
  if [ -n "$image" ]; then
    [[ "$image" =~ $IMAGE_PIN_RE ]] || die "$conf: keyring_image '$image' is not name:tag@sha256:<64 hex>"
    [ -n "$platform" ] || die "$conf: keyring_image needs keyring_platform, the platform to pull it for"
  fi
  if [ -n "$platform" ]; then
    [ -n "$image" ] || die "$conf: keyring_platform is set and keyring_image is not"
    [[ "$platform" =~ ^linux/[a-z0-9]+(/v[0-9]+)?$ ]] || die "$conf: keyring_platform '$platform' is not linux/<arch>[/v<n>]"
  fi
  from="$(target_get "$conf" keyring_from)"
  if [ -n "$from" ]; then
    [ "${#names[@]}" -gt 0 ] || die "$conf: keyring_from is set and keyring names no package"
    [[ "$from" =~ ^[a-z0-9]+(_[a-z0-9]+)*-[a-z0-9]+([.-][a-z0-9]+)*$ ]] || die "$conf: keyring_from '$from' is not a target name <arch>-<repo>"
    [ "$from" != "$arch-$repo" ] || die "$conf: keyring_from names the target itself; leave it out instead"
    [ "${from%%-*}" = "$arch" ] || die "$conf: keyring_from '$from' is another arch than $arch"
    [ -f "$(dirname "$conf")/$from.conf" ] || die "$conf: keyring_from names $from, and there is no $(dirname "$conf")/$from.conf"
  fi
}

# target_keyrings CONF -> the keyring packages, one per line
target_keyrings() {
  local names=() k
  read -r -a names <<< "$(target_get "$1" keyring)"
  for k in "${names[@]}"; do
    printf '%s\n' "$k"
  done
}

# target_sources CONF -> every server package bytes may come from: the
# db_servers first, then the other servers, each once
target_sources() {
  { target_all "$1" db_server; target_all "$1" server; } | awk '!seen[$0]++'
}

# target_get CONF KEY -> the value, or empty
target_get() {
  awk -v k="$2" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $0; sub(/[[:space:]]*=.*/, "", key)
      if (key != k) next
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$1"
}

# target_all CONF KEY -> every value, one per line, $repo and $arch expanded
target_all() {
  local conf="$1" key="$2" arch repo
  arch="$(target_get "$conf" arch)"
  repo="$(target_get "$conf" repo)"
  awk -v k="$key" -v arch="$arch" -v repo="$repo" '
    /^[[:space:]]*(#|$)/ { next }
    {
      key = $0; sub(/[[:space:]]*=.*/, "", key)
      if (key != k) next
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/\$repo/, repo, v); gsub(/\$arch/, arch, v)
      print v
    }
  ' "$conf"
}

# target_enabled CONF -> exit 0 when the target is mirrored
target_enabled() {
  case "$(target_get "$1" enabled)" in
    '' | yes) return 0 ;;
    no) return 1 ;;
    *) die "$1: enabled must be yes or no" ;;
  esac
}

# The repository a target is stored in, without the registry host.
target_repository() {
  printf '%s/%s/%s\n' "$MIRROR_NAMESPACE" "$(target_get "$1" arch)" "$(target_get "$1" repo)"
}

#---------------------------------------------------------------------------#
# Registry coordinates. Everything a script needs to run outside Actions too.
#---------------------------------------------------------------------------#
MIRROR_REGISTRY="${MIRROR_REGISTRY:-ghcr.io}"
if [ -z "${MIRROR_NAMESPACE:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  MIRROR_NAMESPACE="$(printf '%s\n' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
fi
MIRROR_NAMESPACE="${MIRROR_NAMESPACE:-}"

# The integration suite runs the same scripts against a local registry that
# speaks plain http and asks for no credential, and against a local upstream
# on plain http. Production sets none of these.
MIRROR_REGISTRY_SCHEME="${MIRROR_REGISTRY_SCHEME:-https}"
MIRROR_REGISTRY_AUTH="${MIRROR_REGISTRY_AUTH:-token}"
# shellcheck disable=SC2034 # OCI_SCHEME is read by the scripts that source this file
case "$MIRROR_REGISTRY_SCHEME" in
  https)
    OCI_SCHEME=oci
    REG_PROTO='=https'
    ;;
  http)
    OCI_SCHEME=oci+http
    REG_PROTO='=http,https'
    ;;
  *) die "MIRROR_REGISTRY_SCHEME must be https or http, not '$MIRROR_REGISTRY_SCHEME'" ;;
esac
REG_URL="$MIRROR_REGISTRY_SCHEME://$MIRROR_REGISTRY"
UPSTREAM_PROTO="${UPSTREAM_PROTO:-=https}"

# The tags of a ref. A run on main, or with no GITHUB_REF, writes staging and
# index. A run on another branch writes staging-<slug> and index-<slug>. The
# slug is GITHUB_REF_NAME in lower case, each other character a -, no two -
# together, at most 40 characters, no - at either end; empty gives branch.
# STAGING_TAG and INDEX_TAG, when set, are used as given. Each tag is checked
# against its grammar.
#
# staging_tag -> staging or staging-<slug>
# index_tag   -> index${staging_tag#staging}: index or index-<slug>
staging_tag() {
  local t slug
  if [ -n "${STAGING_TAG:-}" ]; then
    t="$STAGING_TAG"
  elif [ -z "${GITHUB_REF:-}" ] || [ "$GITHUB_REF" = refs/heads/main ]; then
    t=staging
  else
    slug="$(printf '%s' "${GITHUB_REF_NAME:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g' | cut -c1-40 | sed 's/^-//; s/-$//')"
    t="staging-${slug:-branch}"
  fi
  [[ "$t" =~ ^staging(-[a-z0-9]+(-[a-z0-9]+)*)?$ ]] ||
    die "STAGING_TAG must be staging or staging-<slug>, not '$t'"
  printf '%s\n' "$t"
}

index_tag() {
  local t s
  if [ -n "${INDEX_TAG:-}" ]; then
    t="$INDEX_TAG"
  else
    s="$(staging_tag)" || return 1
    t="index${s#staging}"
  fi
  [[ "$t" =~ ^index(-[a-z0-9]+(-[a-z0-9]+)*)?$ ]] ||
    die "INDEX_TAG must be index or index-<slug>, not '$t'"
  printf '%s\n' "$t"
}

# oras_args: what every oras call needs to reach the registry
oras_args() {
  printf '%s\n' --registry-config "$ORAS_CONFIG"
  if [ "$MIRROR_REGISTRY_SCHEME" = http ]; then
    printf '%s\n' --plain-http
  fi
}

# oras_login ORAS CONFIG: log in through a configuration file of its own, so
# the token never lands in ~/.docker and dies with the caller's work dir
oras_login() {
  [ "$MIRROR_REGISTRY_AUTH" != none ] || return 0
  local plain=()
  if [ "$MIRROR_REGISTRY_SCHEME" = http ]; then
    plain=(--plain-http)
  fi
  printf '%s' "$REGISTRY_TOKEN" | timeout 120 "$1" login --registry-config "$2" "${plain[@]}" \
    --username "${REGISTRY_USER:-token}" --password-stdin "$MIRROR_REGISTRY" > /dev/null
}

#---------------------------------------------------------------------------#
# Databases
#
# ⛔ A database that tar cannot read whole fails here, loudly. It must never
# yield a partial record set and exit 0: the records it did read look exactly
# like a smaller repository, and a mirror that plans from them stages a
# database that names only part of what upstream published.
#
# Why the status is read from tar and not from the last stage of the pipeline.
# scripts/lib.sh sets `set -E` but not `set -o pipefail`, so in
#
#     tar -xOf "$db" --wildcards '*/desc' | tr | sed > out || rc=$?
#
# $? is sed's status. tar ending 2 on a truncated database gives records for
# every package before the cut, rc 0, and no message. Measured 2026-10-15 on
# the first 40000 bytes of the 724416-byte powerpc64le base.db: 136 records,
# exit 0, and db_check refused it only because its own member listing failed.
# PIPESTATUS reads tar's status without turning on pipefail for every caller,
# which would change the meaning of every other pipeline in the tree.
#
# db_tar DB ARGS... -> tar on the database with its own arguments, and its exit
# status. It names the compression when tar cannot start one, because
# "Cannot exec: No such file or directory" from a child is not something a
# reader can act on.
db_tar() {
  local db="$1"
  shift
  local err rc=0
  err="$(mktemp)"
  tar "$@" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qE 'Cannot exec|not found' "$err"; then
    # GNU tar shells out for zstd, bzip2 and lzma. Which one is in the message.
    local tool
    tool="$(sed -nE "s/^tar \(child\): ([A-Za-z0-9+_-]+): Cannot exec.*/\1/p" "$err" | sed -n 1p)"
    if [ -n "$tool" ]; then
      printf '%s: the database is compressed with %s and the %s program is not installed\n' "$SCRIPT_NAME" "$tool" "$tool" >&2
      printf '  %s\n' "$(sed -n 1,3p "$err")" >&2
      printf '  reproduce: tar -tf %s\n' "$db" >&2
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s: tar ended %s on %s\n' "$SCRIPT_NAME" "$rc" "$db" >&2
    sed -n 1,5p "$err" >&2
  fi
  rm -f -- "$err"
  return "$rc"
}

# db_records DB OUT.tsv
#
# One line per package, tab separated:
#   filename name version arch sha256 csize builddate pgpsig
#
# ⛔ The database is unsigned for most upstreams, and any of a target's servers
# could have supplied it, so every field is checked before it is written. One
# bad field refuses the whole database: a database with one hostile name in it
# is not one to take the rest of from.
#
# ⚠ GNU tar seeks over a sparse member when extracting to a file and overwrites
# what it wrote before (riscv64, 2026-09). Extraction goes through a pipe, NUL
# bytes are dropped, and a record boundary is restored before %FILENAME%.
#---------------------------------------------------------------------------#
db_records() {
  local db="$1" out="$2" work rc=0 _st
  work="$(mktemp -d)"
  # ⛔ A caller under `set -e` must not call this bare. The pipeline below
  # fails first when the database does not read, and errexit ends the caller's
  # shell there, before the status is read, so the function exits with tar's 2
  # instead of its own 1, and the cleanup below does not run. Bash does not let
  # a function restore the caller's errexit reliably, because `return 1` is
  # itself a failing command. So the rule is at the call site: `if !` or
  # `|| rc=$?`, which both exempt this call from errexit. See scripts/plan:489
  # and scripts/lib.sh:428 for the form, and the caller_documented_status note
  # in docs/design.md.
  #
  # PIPESTATUS, not $?: see the note at the head of this section. The awk that
  # reads the result is a separate step, so its status is its own.
  db_tar "$db" -xOf "$db" --wildcards '*/desc' |
    tr -d '\000' |
    sed 's/%FILENAME%/\n&/g' > "$work/desc.txt"
  # The statuses of the stages, one per stage. ⛔ This must be the very next
  # command after the pipeline: `local` is a command too, and it resets
  # PIPESTATUS, so declaring an array here first and reading it after gives
  # [0] for every input, which is how this check passed a truncated database
  # the first time it was written.
  _st="${PIPESTATUS[*]}"
  local -a st=()
  read -ra st <<< "$_st"
  if [ "${st[0]}" -ne 0 ]; then
    # The partial record set is removed rather than left: a file of 136 records
    # beside a database of 3735 is what this whole check exists to prevent, and
    # leaving it is leaving the fault one rename away from being believed.
    rm -f -- "$out"
    rm -rf "$work"
    return 1
  fi
  awk '
    function flush() {
      if (fn == "") return
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", fn, nm, ver, ar, sha, cs, bd, sig
      fn = nm = ver = ar = sha = cs = bd = sig = ""
    }
    /^%[A-Z0-9]+%$/ { key = $0; next }
    /^$/ { key = ""; next }
    {
      if (key == "%FILENAME%") { flush(); fn = $0 }
      else if (key == "%NAME%") nm = $0
      else if (key == "%VERSION%") ver = $0
      else if (key == "%ARCH%") ar = $0
      else if (key == "%SHA256SUM%") sha = $0
      else if (key == "%CSIZE%") cs = $0
      else if (key == "%BUILDDATE%") bd = $0
      else if (key == "%PGPSIG%") sig = sig $0
    }
    END { flush() }
  ' "$work/desc.txt" > "$out" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# db_members DB -> how many package directories the archive holds. A database
# tar cannot list gives nothing and a non-zero status, never 0: a count of 0
# from an unreadable file is the same number as an empty repository.
db_members() {
  local rc=0 n _st
  db_tar "$1" -tf "$1" | awk -F / 'NF >= 2 && $2 == "desc" { n++ } END { print n + 0 }'
  _st="${PIPESTATUS[*]}"
  local -a st=()
  read -ra st <<< "$_st"
  [ "${st[0]}" -eq 0 ] || rc=1
  # shellcheck disable=SC2034 # read below
  n=0
  return "$rc"
}

# db_validate RECORDS.tsv -> exit 0, or print every bad line and exit 1
#
# Only what makepkg can never produce is refused, so a port whose version holds
# a ~ is not shut out for good; a name outside the tag alphabet is stored under
# its fn- hash tag. What is refused is what turns a field into a path or an
# option: a /, a space, a leading - or ., a control character, a byte above 0x7e.
db_validate() {
  LC_ALL=C awk -F '\t' '
    function bad(why) { printf "line %d: %s: %s\n", NR, why, $0; n++ }
    NF != 8 { bad("expected 8 fields, found " NF); next }
    $1 !~ /^[A-Za-z0-9@_+][!-.0-~]*[.]pkg[.]tar([.][A-Za-z0-9]+)?$/ { bad("filename"); next }
    length($1) > 255 { bad("filename longer than 255"); next }
    $2 !~ /^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$/ { bad("name"); next }
    $3 !~ /^[!-~]+$/ { bad("version"); next }
    $4 !~ /^[A-Za-z0-9_]+$/ { bad("arch"); next }
    $5 !~ /^[0-9a-f]+$/ || length($5) != 64 { bad("sha256"); next }
    $6 !~ /^[0-9]+$/ || length($6) > 15 { bad("csize"); next }
    $7 !~ /^[0-9]+$/ || length($7) > 12 { bad("builddate"); next }
    $8 != "" && $8 !~ /^[A-Za-z0-9+\/]+=*$/ { bad("pgpsig"); next }
    index($1, $2 "-" $3 "-" $4 ".pkg.tar") != 1 { bad("filename is not name-version-arch.pkg.tar"); next }
    seen[$1]++ { bad("filename listed twice"); next }
    seen_name[$2]++ { bad("name listed twice"); next }
    END { exit n > 0 }
  ' "$1"
}

# db_check DB RECORDS -> 0 when DB is a whole, well-formed database, with its
# records in RECORDS (db_records) and the package directories it cannot read
# in RECORDS.nul. Otherwise 1, and one line on stdout says why.
#
# Every package directory must give exactly one record, named after it. The
# one exception is a desc member that holds nothing but NUL bytes, or nothing:
# it carries no field at all, pacman lists it with every field None and cannot
# download it, so nothing is lost by passing over it. Measured 2026-10-14:
# findnewest-0.3-4/desc in Arch Linux ARM aarch64 extra (1271 NUL bytes) and
# ntk-1.3.1001-4/desc in Arch Linux RISC-V extra (576), both GNU sparse
# members. Any other unreadable member refuses the database, as before.
DB_MAX_NUL_MEMBERS=16
db_check() {
  local db="$1" rec="$2" records members unread nonul n f _st
  local -a nonul_st=() one_st=()
  : > "$rec.nul"
  if ! db_records "$db" "$rec"; then
    echo "it does not read as a tar archive"
    return 1
  fi
  records="$(awk 'END { print NR + 0 }' "$rec")"
  if [ "$records" -eq 0 ]; then
    echo "it lists no package"
    return 1
  fi
  if ! db_validate "$rec" > "$rec.bad"; then
    echo "$(awk 'END { print NR + 0 }' "$rec.bad") record(s) fail their grammar, first: $(sed -n 1p "$rec.bad")"
    return 1
  fi
  if ! db_tar "$db" -tf "$db" > "$rec.members"; then
    echo "its member list does not read"
    return 1
  fi
  # The package directories with a desc, and those no record is named after.
  awk -F / 'NF >= 2 && $2 == "desc" { print $1 }' "$rec.members" > "$rec.dirs"
  members="$(awk 'END { print NR + 0 }' "$rec.dirs")"
  awk -F '\t' 'FILENAME == ARGV[1] { have[$2 "-" $3] = 1; next } !($0 in have)' "$rec" "$rec.dirs" > "$rec.unread"
  unread="$(awk 'END { print NR + 0 }' "$rec.unread")"
  if [ "$unread" -gt 0 ]; then
    if [ "$unread" -gt "$DB_MAX_NUL_MEMBERS" ]; then
      echo "$unread package directories give no record, more than the $DB_MAX_NUL_MEMBERS accepted as NUL-only, first: $(sed -n 1p "$rec.unread")"
      return 1
    fi
    if LC_ALL=C awk '!/^[A-Za-z0-9@_+][A-Za-z0-9@._+:~-]*$/ { bad = 1 } END { exit !bad }' "$rec.unread"; then
      echo "a package directory has a name no package has: $(LC_ALL=C awk '!/^[A-Za-z0-9@_+][A-Za-z0-9@._+:~-]*$/' "$rec.unread" | sed -n 1p)"
      return 1
    fi
    sed 's|$|/desc|' "$rec.unread" > "$rec.unread-desc"
    # One read for all of them; the bytes left once NULs are dropped.
    # tar's own status decides: a member that could not be read is -1, not a
    # count of the bytes that were.
    nonul="$(db_tar "$db" -xOf "$db" -T "$rec.unread-desc" | tr -d '\000' | wc -c | tr -d ' ')"
    _st="${PIPESTATUS[*]}"
    read -ra nonul_st <<< "$_st"
    [ "${nonul_st[0]}" -eq 0 ] || nonul=-1
    if [ "$nonul" != 0 ]; then
      n=0
      while IFS= read -r f; do
        n="$(db_tar "$db" -xOf "$db" "$f/desc" | tr -d '\000' | wc -c | tr -d ' ')"
        _st="${PIPESTATUS[*]}"
        read -ra one_st <<< "$_st"
        [ "${one_st[0]}" -eq 0 ] || n=-1
        if [ "$n" != 0 ]; then
          echo "$f/desc gives no record named after its directory, and holds $n byte(s) that are not NUL"
          return 1
        fi
      done < "$rec.unread"
      echo "the members that give no record do not read ($nonul)"
      return 1
    fi
    cp "$rec.unread" "$rec.nul"
  fi
  if [ "$((records + unread))" -ne "$members" ]; then
    echo "it holds $members package directories, $records readable records and $unread NUL-only member(s)"
    return 1
  fi
  return 0
}

# behind A.tsv B.tsv -> "NEWER OLDER": how many packages of B were built
# after, and before, the same package in A. B is behind A when OLDER > 0.
# Measured on Arch's archived core.db, 2026-10-01 to 10-12: in every pair of
# consecutive days the newer database had no package older than the earlier
# one, and the earlier had at least one older package whenever the bytes
# differed, including the pairs whose newest build date was the same.
behind() {
  awk -F '\t' '
    FILENAME == ARGV[1] { built[$2] = $7; next }
    ($2 in built) { if ($7 + 0 > built[$2] + 0) n++; else if ($7 + 0 < built[$2] + 0) o++ }
    END { print n + 0, o + 0 }
  ' "$1" "$2"
}

# iso_now -> the time as ISO 8601 UTC, from MIRROR_NOW (seconds) when a test
# pins the clock. ISO strings of this one shape sort as the times they name.
iso_now() {
  if [ -n "${MIRROR_NOW:-}" ]; then
    date -u -d "@$MIRROR_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# fetched_not_older STAGED LIVE -> 0 when STAGED is the same time as LIVE or
# later. Both are ISO 8601 UTC of one shape, which sort as the times they name.
fetched_not_older() {
  local smaller
  smaller="$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | sed -n 1p)"
  [ "$smaller" = "$2" ]
}

# stale_verdict PROMOTED_SHA UPSTREAM_SHA FETCHED_ISO TODAY TOLERANCE_DAYS
#   current  latest serves upstream's database
#   fresh    they differ, and the snapshot was fetched within the tolerance
#   stale    they differ, and it was fetched longer ago, or never
#   unknown  upstream could not be read; nothing can be said
stale_verdict() {
  local promoted="$1" upstream="$2" fetched="$3" today="$4" tolerance="$5" age
  if [ -z "$upstream" ]; then
    echo unknown
    return 0
  fi
  if [ -n "$promoted" ] && [ "$promoted" = "$upstream" ]; then
    echo current
    return 0
  fi
  if [ -z "$promoted" ] || [ -z "$fetched" ]; then
    echo stale
    return 0
  fi
  age="$("$REPO_ROOT/scripts/date-age" "$fetched" "$today")"
  if [ "$age" -gt "$tolerance" ]; then
    echo stale
  else
    echo fresh
  fi
}

#---------------------------------------------------------------------------#
# The signature of a signed database
#
# A .db.sig that exists is not a .db.sig that verifies. For a target with
# db_signed = yes, which is all six PowerPC targets, the signature decides
# whether a consumer with DatabaseRequired can use the database at all. So plan
# checks it before the snapshot is staged, rather than leaving a consumer to
# find out.
#
# gpgv, not gpg: gpgv verifies and does not import, so the check cannot change
# the trust store it verified against.
#---------------------------------------------------------------------------#
# db_sig_ok DIR REPO WHICH -> 0 when DIR/upstream.WHICH.sig verifies against the
# keyring files in DIR/keyrings, 1 otherwise with the reason on stderr.
db_sig_ok() {
  local dir="$1" repo="$2" which="$3" rc=0 out=""
  local -a kv=()
  command -v gpgv > /dev/null || {
    warn "gpgv is not installed, so the signature of $repo.$which cannot be checked" \
      "reproduce: gpgv --keyring DIR/$repo.$which.sig $repo.$which"
    return 1
  }
  local f
  for f in "$dir"/keyrings/*.gpg "$dir"/keyrings/*.kbx; do
    [ -f "$f" ] || continue
    kv+=(--keyring "$f")
  done
  if [ "${#kv[@]}" -eq 0 ]; then
    warn "no keyring file under $dir/keyrings, so the signature of $repo.$which cannot be checked" \
      "reproduce: ls $dir/keyrings"
    return 1
  fi
  out="$(gpgv "${kv[@]}" "$dir/upstream.$which.sig" "$dir/upstream.$which" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "$repo.$which.sig does not verify against the keyring files (gpgv status $rc)" \
      "$(printf '%s\n' "$out" | sed -n 1,5p)" \
      "reproduce: gpgv ${kv[*]} $repo.$which.sig $repo.$which"
    return 1
  fi
  return 0
}

# keyring_copy DIR CONF: the keyring files of CONF's keyring_image into DIR.
# create and cp run nothing from the image, so no emulation is needed. This is
# the same set of files scripts/keyring-files prints, and CI checks those
# against targets/keyrings.sha256.
keyring_copy() {
  local dir="$1" conf="$2" image platform cid="" rc=0
  image="$(target_get "$conf" keyring_image)"
  platform="$(target_get "$conf" keyring_platform)"
  [ -n "$image" ] || return 0
  mkdir -p "$dir"
  local runtime="${CONTAINER_RUNTIME:-docker}"
  command -v "$runtime" > /dev/null || {
    warn "$runtime is not installed, so the keyring of $image cannot be copied out" \
      "reproduce: $runtime pull --platform $platform $image"
    return 1
  }
  timeout -k 30 300 "$runtime" pull --platform "$platform" "$image" > "$dir/pull.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "could not pull $image for $platform (status $rc)" "$(sed -n 1,3p "$dir/pull.log")" \
      "reproduce: $runtime pull --platform $platform $image"
    return 1
  fi
  cid="$(timeout 120 "$runtime" create --platform "$platform" "$image" true)" || return 1
  timeout 120 "$runtime" cp "$cid:/usr/share/pacman/keyrings/." "$dir/" > "$dir/cp.log" 2>&1 || rc=$?
  timeout 60 "$runtime" rm "$cid" > /dev/null || log "could not remove container $cid"
  [ "$rc" -eq 0 ] || {
    warn "could not copy /usr/share/pacman/keyrings out of $image (status $rc)" \
      "reproduce: $runtime create --platform $platform $image true, then $runtime cp ID:/usr/share/pacman/keyrings/. DIR"
    return 1
  }
  # gpgv reads .gpg and .kbx only. A keyring image also ships archlinux-trusted
  # and archlinux-revoked, which are lists of names and not keyrings.
  local found=0 f
  for f in "$dir"/*.gpg "$dir"/*.kbx; do
    [ -f "$f" ] || continue
    found=1
  done
  if [ "$found" -eq 0 ]; then
    warn "$image holds no file gpgv can read under /usr/share/pacman/keyrings" \
      "reproduce: $runtime create --platform $platform $image true, then $runtime cp ID:/usr/share/pacman/keyrings/. DIR"
    return 1
  fi
  return 0
}

#---------------------------------------------------------------------------#
# The verify context
#
# A verdict of scripts/verify-batch holds for the inputs it ran with. The
# verify context is one sha256 of these inputs, in this order:
#   the line index-format=1
#   the key = value lines of the target file, as key=value; comments and
#     blank lines do not count
#   the bytes of scripts/verify-batch, client/pacman-oci and scripts/lib.sh
#   fields 1, 5 and 8 of the records of the keyring packages verify
#     installs, sorted
# An index row verified under another context is verified again
# (scripts/plan).
#
# verify_context CONF RECORDS -> the sha256, or status 1 when an input does
# not read. RECORDS is a records file (db_records). Only the records whose
# name is in the keyring list of CONF count. A RECORDS file that holds the
# one line none stands for a keyring_from target with no latest.
#---------------------------------------------------------------------------#
verify_context() {
  local conf="$1" records="$2" names tmpf sum
  tmpf="$(mktemp)"
  names="$(target_keyrings "$conf" | tr '\n' ' ')"
  if printf 'index-format=1\n' > "$tmpf" &&
    awk '
      /^[[:space:]]*(#|$)/ { next }
      {
        k = $0; sub(/[[:space:]]*=.*/, "", k)
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        print k "=" v
      }
    ' "$conf" >> "$tmpf" &&
    cat "$REPO_ROOT/scripts/verify-batch" "$WRAPPER" "$REPO_ROOT/scripts/lib.sh" >> "$tmpf" &&
    awk -F '\t' -v names=" $names" '
      $0 == "none" { print; next }
      $2 != "" && index(names, " " $2 " ") { print $1 "\t" $5 "\t" $8 }
    ' "$records" > "$tmpf.keyrings" &&
    LC_ALL=C sort "$tmpf.keyrings" >> "$tmpf"; then
    sum="$(sha256sum "$tmpf" | cut -d ' ' -f 1)"
    rm -f -- "$tmpf" "$tmpf.keyrings"
    printf '%s\n' "$sum"
    return 0
  fi
  rm -f -- "$tmpf" "$tmpf.keyrings"
  warn "the verify context of $conf is not known: an input does not read" \
    "reproduce: ls $conf $records $REPO_ROOT/scripts/verify-batch $WRAPPER $REPO_ROOT/scripts/lib.sh"
  return 1
}

#---------------------------------------------------------------------------#
# The write-once rule for package tags
#
# decide_push MANIFEST FILE SHA256 CSIZE SIG_SHA256
#   MANIFEST    the manifest the tag holds now
#   SIG_SHA256  the sha256 of the signature this file must carry, or empty
#               when the database has no %PGPSIG% for it
# prints one word:
#   present   the tag holds this file and its signature as they should be
#   repush    the package layer is right and something else is not (signature
#             missing or different, a title or media type, a layer count):
#             push again, the package blob is reused
#   needsig   no %PGPSIG% and no signature layer: fetch the .sig, then push
#   replaced  the tag holds other bytes under this name: never push
#
# ⛔ A tag whose package layer is not this file's bytes is never written
# again. The promoted database, or an older snapshot, may name those bytes,
# and a consumer handed new bytes under an old name gets a file pacman refuses
# with no fallback to another Server.
#---------------------------------------------------------------------------#
PKG_MEDIA_TYPE=application/vnd.pkgforge.archlinux.pkg.v1
SIG_MEDIA_TYPE=application/pgp-signature

decide_push() {
  local m="$1" file="$2" sha="$3" csize="$4" sig_sha="$5" count d sz mt
  if ! jq -e '.layers | type == "array"' "$m" > /dev/null; then
    echo replaced
    return 0
  fi
  read -r d sz mt <<< "$(manifest_layer "$m" "$file")"
  if [ "$d" != "sha256:$sha" ]; then
    echo replaced
    return 0
  fi
  if [ "$sz" != "$csize" ] || [ "$mt" != "$PKG_MEDIA_TYPE" ]; then
    echo repush
    return 0
  fi
  count="$(jq '.layers | length' "$m")"
  read -r d sz mt <<< "$(manifest_layer "$m" "$file.sig")"
  if [ -n "$sig_sha" ]; then
    if [ "$d" != "sha256:$sig_sha" ] || [ "$mt" != "$SIG_MEDIA_TYPE" ] || [ "$count" != 2 ]; then
      echo repush
      return 0
    fi
    echo present
    return 0
  fi
  if [ -z "$d" ]; then
    if [ "$count" = 1 ]; then
      echo needsig
    else
      echo repush
    fi
    return 0
  fi
  if [ "$mt" != "$SIG_MEDIA_TYPE" ] || [ "$count" != 2 ]; then
    echo repush
    return 0
  fi
  echo present
}

#---------------------------------------------------------------------------#
# Results
#
# reconcile_results SHARD.tsv RESULTS_DIR OUT.tsv
#
# One result line per work line, in work-line order:
#   target filename status seconds detail
# A line with no result file is a failure: the item died before writing one,
# or xargs never started it. Prints the number of lines that are not pushed or
# present.
#---------------------------------------------------------------------------#
reconcile_results() {
  local shard="$1" results="$2" outfile="$3" lines i
  lines="$(awk 'END { print NR + 0 }' "$shard")"
  : > "$outfile"
  for ((i = 1; i <= lines; i++)); do
    if [ -s "$results/$i.tsv" ]; then
      cat "$results/$i.tsv" >> "$outfile"
    else
      printf '%s\tfailed\t0\tno result was recorded\n' "$(sed -n "${i}p" "$shard" | cut -f 1,2)" >> "$outfile"
    fi
  done
  # "absent" is not bad: the file is gone from upstream (404 everywhere) though
  # its database still names it, so mirror-file skipped it rather than failing.
  awk -F '\t' '$3 != "pushed" && $3 != "present" && $3 != "absent" { n++ } END { print n + 0 }' "$outfile"
}

# results_of_plan RESULTS PLAN_ID OUT
#
# Every result line of the mirror shards of plan PLAN_ID into OUT: target
# filename status seconds detail. RESULTS holds the shards' outputs at any
# depth: every results.tsv under it is read, and every lines/*.tsv, which a
# shard killed before its results.tsv leaves behind. A results.tsv and the
# lines/ beside it say the same, so a line can come twice. No results at all
# is ordinary: a database that changed by dropping packages names no new file.
#
# ⛔ Only a directory whose plan-id is PLAN_ID is read (scripts/mirror-shard).
# "Re-run all jobs" plans again, and the download of results-<target>-* still
# returns the earlier attempt's artifacts. Their lines are about another
# plan: a stale "failed" could hold the target, a stale "pushed" could count
# a file that is not there. Each directory left out is named in a warning.
results_of_plan() {
  local results="$1" plan_id="$2" outfile="$3" paths dirs d got
  paths="$(mktemp)"
  dirs="$(mktemp)"
  : > "$outfile"
  if [ -d "$results" ]; then
    find "$results" \( -name results.tsv -type f \) -o \( -name lines -type d \) > "$paths"
    sed 's|/[^/]*$||' "$paths" | sort -u > "$dirs"
  fi
  while IFS= read -r d; do
    got=""
    if [ -f "$d/plan-id" ]; then
      got="$(cat "$d/plan-id")"
    fi
    if [ "$got" != "$plan_id" ]; then
      warn "$d holds the results of plan '$got', not of this plan '$plan_id'; they are not read" \
        "an earlier attempt of the run left them: Re-run all jobs plans again, and the artifacts of the earlier attempt stay"
      continue
    fi
    if [ -f "$d/results.tsv" ]; then
      cat "$d/results.tsv" >> "$outfile"
    fi
    if [ -d "$d/lines" ]; then
      find "$d/lines" -maxdepth 1 -name '[0-9]*.tsv' -type f -exec cat {} + >> "$outfile"
    fi
  done < "$dirs"
  rm -f -- "$paths" "$dirs"
}

#---------------------------------------------------------------------------#
# Registry reads
#
# Every answer is classified exactly. A repository or manifest is absent only
# when the registry says so in its own words: 404 with NAME_UNKNOWN or
# MANIFEST_UNKNOWN. A 401, a 403, a 5xx, a body that is not the expected JSON,
# or no answer at all is an error, never "nothing there yet". Reading an error
# as an empty repository is how a mirror decides to push everything again, or
# to promote over a database it could not see.
#
# REGISTRY_USER and REGISTRY_TOKEN, when set, are exchanged for a scoped token.
# Without them the reads are anonymous, the way any consumer reads: the token
# endpoint is asked with no credential.
#
# REGISTRY_TOKEN_CACHE, when set, is a directory that keeps each scoped token
# in a file of its own. Every process that reads it uses the same token, so a
# shard asks the token endpoint once, not once per read. A 401 or a 403 drops
# the file and asks again, once. ⛔ Only a token got with REGISTRY_TOKEN is
# kept. A read with REGISTRY_TOKEN empty is a consumer's read: it never uses
# the cache, or it would send the workflow's token and read a private package.
#
# On GHCR a read tries the dummy token Bearer QQ== first, which every public
# package accepts, so a read costs one request. GHCR answers QQ== with 404
# MANIFEST_UNKNOWN for a repository it does not show to anonymous readers
# (measured 2026-10-14). With REGISTRY_TOKEN set, only the 200 of QQ== is the
# answer, and any other answer is asked again with the real token. With
# REGISTRY_TOKEN empty, the answer of QQ== is the answer, except a 401 or a
# 403: GHCR does not document QQ==, so a refusal of it is asked again with the
# anonymous token flow, and a warning says so. The token endpoint answers that
# flow with 403 for a repository it does not show (measured 2026-10-15): for
# an anonymous read that is absent, the same answer as QQ== gives today.
# Only that 403: a 401 of the token endpoint is not measured, and is an
# error.
#
# REG_LAST_CODE is the HTTP code of the last answer registry_manifest read:
# 000 when nothing answered, the token endpoint's code when it gave no token.
#---------------------------------------------------------------------------#
REG_STATUS_OK=0
REG_STATUS_ERROR=1
REG_STATUS_ABSENT=4
REG_LAST_CODE=000
# shellcheck disable=SC2034 # REG_TOKEN and REG_TOKEN_CODE are read by the functions below
REG_TOKEN=""
REG_TOKEN_CODE=""

# registry_token_file REPO SCOPE -> the cache file for that token, or nothing
# when there is no cache, or when the read is anonymous
registry_token_file() {
  [ -n "${REGISTRY_TOKEN_CACHE:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ] || return 0
  printf '%s/%s\n' "$REGISTRY_TOKEN_CACHE" "$(printf '%s %s %s' "$MIRROR_REGISTRY" "$1" "$2" | sha256sum | cut -d ' ' -f 1)"
}

# registry_token_drop REPO SCOPE: forget a cached token the registry refused
registry_token_drop() {
  local f
  f="$(registry_token_file "$1" "$2")"
  if [ -n "$f" ]; then
    rm -f -- "$f"
  fi
}

# registry_token_get REPO SCOPE: a bearer token in REG_TOKEN, set in the
# caller's shell, not in $( ). SCOPE is pull or pull,push. The token comes from
# the cache, or from the token endpoint, with REGISTRY_TOKEN or with no
# credential. REG_TOKEN_CODE is the token endpoint's HTTP code: empty when no
# request was made, 000 when nothing answered.
#   returns 0 a token, 1 none
registry_token_get() {
  local repo="$1" scope="$2" out rc=0 code="" tok cache tmp max="${REG_TOKEN_MAX_TIME:-90}"
  REG_TOKEN=""
  REG_TOKEN_CODE=""
  if [ "$MIRROR_REGISTRY_AUTH" = none ]; then
    REG_TOKEN=none
    return 0
  fi
  cache="$(registry_token_file "$repo" "$scope")"
  if [ -n "$cache" ] && [ -s "$cache" ]; then
    REG_TOKEN="$(cat -- "$cache")"
    return 0
  fi
  # ⛔ The whole call, its retries included, ends within REG_TOKEN_MAX_TIME,
  # as registry_blob's does. With --max-time alone a token endpoint that
  # stalls held each call about 250 s, and status-collect asks once for
  # every target.
  case "$max" in
    '' | *[!0-9]* | 0) die "REG_TOKEN_MAX_TIME must be a positive number of seconds, not '$max'" ;;
  esac
  out="$(mktemp)"
  if [ -n "${REGISTRY_TOKEN:-}" ]; then
    # The credential goes to curl on stdin, as a config line, never on its
    # command line, where every process of the runner could read it.
    code="$(printf 'user = "%s:%s"\n' "${REGISTRY_USER:-token}" "$REGISTRY_TOKEN" |
      timeout -k 5 "$((max + 5))" curl -q --silent --show-error --connect-timeout 20 \
        --max-time "$max" --retry-max-time "$max" \
        --retry 3 --retry-connrefused --retry-delay 2 --config - \
        --get --data-urlencode "service=$MIRROR_REGISTRY" --data-urlencode "scope=repository:$repo:$scope" \
        --output "$out" --write-out '%{http_code}' "https://$MIRROR_REGISTRY/token")" || rc=$?
  else
    code="$(timeout -k 5 "$((max + 5))" curl -q --silent --show-error --connect-timeout 20 \
      --max-time "$max" --retry-max-time "$max" \
      --retry 3 --retry-connrefused --retry-delay 2 \
      --get --data-urlencode "service=$MIRROR_REGISTRY" --data-urlencode "scope=repository:$repo:$scope" \
      --output "$out" --write-out '%{http_code}' "https://$MIRROR_REGISTRY/token")" || rc=$?
  fi
  REG_TOKEN_CODE="${code:-000}"
  if [ "$rc" -eq 0 ] && [ "$REG_TOKEN_CODE" = 403 ] && registry_anon_ghcr; then
    log "GHCR gives no anonymous $scope token for $repo (HTTP $REG_TOKEN_CODE): it does not show that repository"
    rm -f "$out"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ "$REG_TOKEN_CODE" != 200 ]; then
    warn "no $scope token for $MIRROR_REGISTRY/$repo (curl $rc, HTTP $REG_TOKEN_CODE)" "$(head -c 300 "$out")"
    rm -f "$out"
    return 1
  fi
  tok="$(jq -r '.token // .access_token // empty' "$out")"
  rm -f "$out"
  if [ -z "$tok" ]; then
    warn "the token endpoint of $MIRROR_REGISTRY answered 200 with no token for $repo"
    return 1
  fi
  if [ -n "$cache" ]; then
    tmp="$(mktemp "$REGISTRY_TOKEN_CACHE/.token.XXXXXX")"
    printf '%s\n' "$tok" > "$tmp"
    mv -f -- "$tmp" "$cache"
  fi
  REG_TOKEN="$tok"
  return 0
}

# registry_token REPO SCOPE -> a bearer token on stdout (registry_token_get).
# GHCR gives no anonymous token for a repository it does not show (403,
# measured), such as a target with no push yet. Then the token is QQ==, with
# which GHCR answers that repository with 404 MANIFEST_UNKNOWN: the caller
# reads it as absent, as a consumer does (scripts/status-collect).
registry_token() {
  if registry_token_get "$1" "$2"; then
    printf '%s\n' "$REG_TOKEN"
    return 0
  fi
  if registry_anon_ghcr && [ "$2" = pull ] && [ "$REG_TOKEN_CODE" = 403 ]; then
    printf 'QQ==\n'
    return 0
  fi
  return 1
}

# registry_anon_ghcr -> 0 when a read goes to GHCR with no credential of its own
registry_anon_ghcr() {
  [ "$MIRROR_REGISTRY_AUTH" != none ] && [ "$MIRROR_REGISTRY" = ghcr.io ] && [ -z "${REGISTRY_TOKEN:-}" ]
}

# registry_error_code BODY -> the first error code in a registry error body
registry_error_code() {
  jq -s -R -r '(fromjson? // {}) | .errors[0].code? // empty' "$1" | tr -d '\r'
}

# registry_get_manifest URL TOKEN OUT -> the HTTP status on stdout, curl's
# status as the return value
registry_get_manifest() {
  curl -q --silent --show-error --connect-timeout 20 --max-time 60 \
    --retry 3 --retry-connrefused --retry-delay 2 --max-filesize 4194304 \
    --header "Authorization: Bearer $2" \
    --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
    --output "$3" --write-out '%{http_code}' "$1"
}

# registry_manifest REPO REF OUT -> the manifest bytes in OUT
#   returns 0 read, 4 the registry has no such manifest, 1 could not read
registry_manifest() {
  local repo="$1" ref="$2" outfile="$3" code="" rc=0 err url
  REG_LAST_CODE=000
  url="$REG_URL/v2/$repo/manifests/$ref"
  if [ "$MIRROR_REGISTRY_AUTH" != none ] && [ "$MIRROR_REGISTRY" = ghcr.io ]; then
    code="$(registry_get_manifest "$url" 'QQ==' "$outfile")" || rc=$?
    if [ -n "${REGISTRY_TOKEN:-}" ]; then
      if [ "$rc" -ne 0 ] || [ "$code" != 200 ]; then
        code=""
        rc=0
      fi
    elif [ "$rc" -eq 0 ] && { [ "$code" = 401 ] || [ "$code" = 403 ]; }; then
      warn "GHCR refused Bearer QQ== for $repo (HTTP $code); the anonymous token flow was used"
      code=""
    fi
  fi
  if [ -z "$code" ] && [ "$rc" -eq 0 ]; then
    if ! registry_token_get "$repo" pull; then
      REG_LAST_CODE="${REG_TOKEN_CODE:-000}"
      if registry_anon_ghcr && [ "$REG_LAST_CODE" = 403 ]; then
        return "$REG_STATUS_ABSENT"
      fi
      return "$REG_STATUS_ERROR"
    fi
    code="$(registry_get_manifest "$url" "$REG_TOKEN" "$outfile")" || rc=$?
    if [ "$rc" -eq 0 ] && { [ "$code" = 401 ] || [ "$code" = 403 ]; } && [ -n "$(registry_token_file "$repo" pull)" ]; then
      registry_token_drop "$repo" pull
      if ! registry_token_get "$repo" pull; then
        REG_LAST_CODE="${REG_TOKEN_CODE:-000}"
        return "$REG_STATUS_ERROR"
      fi
      code="$(registry_get_manifest "$url" "$REG_TOKEN" "$outfile")" || rc=$?
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    warn "no answer for $repo:$ref (curl $rc)"
    return "$REG_STATUS_ERROR"
  fi
  REG_LAST_CODE="$code"
  if [ "$code" = 404 ]; then
    err="$(registry_error_code "$outfile")"
    case "$err" in
      MANIFEST_UNKNOWN | NAME_UNKNOWN) return "$REG_STATUS_ABSENT" ;;
    esac
  fi
  if [ "$code" != 200 ]; then
    warn "$repo:$ref answered HTTP $code" "$(head -c 300 "$outfile")"
    return "$REG_STATUS_ERROR"
  fi
  if ! jq -e '.schemaVersion == 2' "$outfile" > /dev/null; then
    warn "$repo:$ref answered 200 with something that is not a manifest" "$(head -c 300 "$outfile")"
    return "$REG_STATUS_ERROR"
  fi
  case "$ref" in
    sha256:*)
      if [ "$(sha256sum "$outfile" | cut -d ' ' -f 1)" != "${ref#sha256:}" ]; then
        warn "$repo answered $ref with a manifest of another digest"
        return "$REG_STATUS_ERROR"
      fi
      ;;
  esac
  return "$REG_STATUS_OK"
}

# registry_get_blob URL TOKEN OUT MAX_SECONDS [MAX_BYTES] -> the HTTP status
# of the last answer on stdout, curl's status as the return value. The whole
# call, its retries and the redirect to the blob host included, ends within
# MAX_SECONDS, as fetch_upstream's does. MAX_BYTES, when above 0, stops a
# body that is larger (curl --max-filesize).
registry_get_blob() {
  local limit=()
  if [ "${5:-0}" -gt 0 ]; then
    limit=(--max-filesize "$5")
  fi
  timeout -k 5 "$(($4 + 5))" curl -q --location --silent --show-error --proto "$REG_PROTO" --proto-redir "$REG_PROTO" --max-redirs 5 \
    --connect-timeout 20 --speed-limit 1024 --speed-time 60 --max-time "$4" --retry-max-time "$4" \
    --retry 3 --retry-connrefused --retry-delay 2 "${limit[@]}" \
    --header "Authorization: Bearer $2" \
    --output "$3" --write-out '%{http_code}' "$1"
}

# registry_blob REPO DIGEST OUT -> the blob in OUT, its sha256 checked
#   returns 0 read and checked, 1 anything else
# REG_BLOB_MAX_TIME (seconds, default 600) bounds each read. On GHCR with no
# credential, Bearer QQ== is tried first, as in registry_manifest.
registry_blob() {
  local repo="$1" digest="$2" outfile="$3" code="" rc=0 url max="${REG_BLOB_MAX_TIME:-600}"
  case "$digest" in
    sha256:*) ;;
    *) warn "not a sha256 digest: $digest"; return 1 ;;
  esac
  case "$max" in
    '' | *[!0-9]* | 0) die "REG_BLOB_MAX_TIME must be a positive number of seconds, not '$max'" ;;
  esac
  url="$REG_URL/v2/$repo/blobs/$digest"
  if registry_anon_ghcr; then
    code="$(registry_get_blob "$url" 'QQ==' "$outfile" "$max")" || rc=$?
    if [ "$rc" -eq 0 ] && { [ "$code" = 401 ] || [ "$code" = 403 ]; }; then
      warn "GHCR refused Bearer QQ== for $repo (HTTP $code); the anonymous token flow was used"
      code=""
    fi
  fi
  if [ -z "$code" ] && [ "$rc" -eq 0 ]; then
    registry_token_get "$repo" pull || return 1
    code="$(registry_get_blob "$url" "$REG_TOKEN" "$outfile" "$max")" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    warn "could not read blob $digest of $repo within ${max}s (curl $rc)"
    rm -f "$outfile"
    return 1
  fi
  if [ "$code" != 200 ]; then
    warn "blob $digest of $repo answered HTTP $code" "$(head -c 300 "$outfile")"
    rm -f "$outfile"
    return 1
  fi
  if [ "$(sha256sum "$outfile" | cut -d ' ' -f 1)" != "${digest#sha256:}" ]; then
    warn "blob $digest of $repo does not hash to its digest"
    rm -f "$outfile"
    return 1
  fi
  return 0
}

# registry_blob_probe REPO DIGEST OUT MAX CSIZE -> a package blob from a
# registry repository, a source mirror-file asks before the upstream servers
#   0  read: CSIZE bytes, and its sha256 is the digest
#   4  the repository does not hold it: 404 with BLOB_UNKNOWN or NAME_UNKNOWN,
#      or GHCR gives no anonymous token for the repository (403), as
#      registry_manifest reads it. No warning.
#   5  the registry limits requests (429): the caller pauses (throttle_pause)
#      and asks its next source
#   1  anything else, with a log line
# MAX (seconds) bounds the read, its retries included; the token request has
# its own REG_TOKEN_MAX_TIME. The read stops after CSIZE bytes. OUT exists
# only on status 0. On GHCR with no credential, Bearer QQ== is tried first,
# as in registry_blob.
registry_blob_probe() {
  local repo="$1" digest="$2" outfile="$3" max="$4" csize="$5" code="" rc=0 url err size
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "registry_blob_probe: not a sha256 digest: '$digest'"
  case "$max" in
    '' | *[!0-9]* | 0) die "registry_blob_probe: MAX must be a positive number of seconds, not '$max'" ;;
  esac
  case "$csize" in
    '' | *[!0-9]*) die "registry_blob_probe: CSIZE must be a number of bytes, not '$csize'" ;;
  esac
  rm -f -- "$outfile"
  url="$REG_URL/v2/$repo/blobs/$digest"
  if registry_anon_ghcr; then
    code="$(registry_get_blob "$url" 'QQ==' "$outfile" "$max" "$csize")" || rc=$?
    if [ "$rc" -eq 0 ] && { [ "$code" = 401 ] || [ "$code" = 403 ]; }; then
      code=""
    fi
  fi
  if [ -z "$code" ] && [ "$rc" -eq 0 ]; then
    if ! registry_token_get "$repo" pull; then
      rm -f -- "$outfile"
      if registry_anon_ghcr && [ "$REG_TOKEN_CODE" = 403 ]; then
        return 4
      fi
      if [ "$REG_TOKEN_CODE" = 429 ]; then
        return 5
      fi
      return 1
    fi
    code="$(registry_get_blob "$url" "$REG_TOKEN" "$outfile" "$max" "$csize")" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$outfile"
    log "blob $digest of $repo did not read within ${max}s or ${csize} bytes (curl $rc)"
    return 1
  fi
  case "$code" in
    200) ;;
    404)
      err="$(registry_error_code "$outfile")"
      rm -f -- "$outfile"
      case "$err" in
        BLOB_UNKNOWN | NAME_UNKNOWN) return 4 ;;
      esac
      log "blob $digest of $repo answered HTTP 404 with ${err:-no error code}"
      return 1
      ;;
    429)
      rm -f -- "$outfile"
      log "blob $digest of $repo answered HTTP 429: the registry limits requests"
      return 5
      ;;
    *)
      rm -f -- "$outfile"
      log "blob $digest of $repo answered HTTP $code"
      return 1
      ;;
  esac
  size="$(wc -c < "$outfile" | tr -d ' ')"
  if [ "$size" != "$csize" ]; then
    rm -f -- "$outfile"
    log "blob $digest of $repo is $size bytes, not $csize"
    return 1
  fi
  if [ "$(sha256sum "$outfile" | cut -d ' ' -f 1)" != "${digest#sha256:}" ]; then
    rm -f -- "$outfile"
    log "blob $digest of $repo does not hash to its digest"
    return 1
  fi
  return 0
}

#---------------------------------------------------------------------------#
# Rate limits
#
# GHCR limits the requests of one token (measured: "toomanyrequests ...
# allowed: 2000/minute", run 38570044665), and every push of every job shares
# the workflow's token. A 429 costs no attempt: the caller pauses for
# RATE_PAUSE_MIN to RATE_PAUSE_MAX seconds (20 to 60) and tries again. The
# pauses of one process add up to at most the cap its caller gives.
#
# rate_limited LOG -> 0 when LOG holds a 429, in the registry's words
#   (toomanyrequests, 429 Too Many) or in oras's ("response status code 429:
#   Too Many Requests")
# throttle_wait DIR: wait until the time in DIR/throttle, when it is later
# throttle_pause DIR MAX_WAIT WHAT: pause, after DIR/throttle says when the
#   pause ends, so that every process that shares DIR waits too. The pause is
#   added to THROTTLE_WAITED. Returns 1, with no pause, when the pause would
#   take THROTTLE_WAITED over MAX_WAIT.
#---------------------------------------------------------------------------#
THROTTLE_WAITED=0

rate_limited() {
  grep -qiE 'toomanyrequests|status code 429|429 Too Many' "$1"
}

throttle_wait() {
  local until now
  [ -f "$1/throttle" ] || return 0
  until="$(cat "$1/throttle")"
  case "$until" in
    '' | *[!0-9]*) return 0 ;;
  esac
  now="$(date -u +%s)"
  if [ "$until" -gt "$now" ]; then
    sleep "$((until - now))"
  fi
}

throttle_pause() {
  local dir="$1" max="$2" what="$3" lo="${RATE_PAUSE_MIN:-20}" hi="${RATE_PAUSE_MAX:-60}" pause tmp v
  for v in "$lo" "$hi" "$max"; do
    case "$v" in
      '' | *[!0-9]*) die "RATE_PAUSE_MIN ($lo), RATE_PAUSE_MAX ($hi) and the cap of the pauses ($max) must be whole seconds" ;;
    esac
  done
  [ "$hi" -ge "$lo" ] || die "RATE_PAUSE_MAX ($hi) is below RATE_PAUSE_MIN ($lo)"
  pause=$((lo + RANDOM % (hi - lo + 1)))
  if [ "$((THROTTLE_WAITED + pause))" -gt "$max" ]; then
    warn "$what: the registry still limits requests (429) after ${THROTTLE_WAITED}s of pauses; the cap is ${max}s"
    return 1
  fi
  THROTTLE_WAITED=$((THROTTLE_WAITED + pause))
  tmp="$(mktemp "$dir/.throttle.XXXXXX")"
  printf '%s\n' "$(($(date -u +%s) + pause))" > "$tmp"
  mv -f -- "$tmp" "$dir/throttle"
  log "$what: the registry limits requests (429); a pause of ${pause}s, ${THROTTLE_WAITED}s of the ${max}s cap"
  sleep "$pause"
}

# manifest_layer MANIFEST TITLE -> "DIGEST SIZE MEDIATYPE" of the one layer
# with that title, or nothing
manifest_layer() {
  jq -r --arg t "$2" '
    [.layers[]? | select(.annotations["org.opencontainers.image.title"]? == $t)]
    | if length == 1 then "\(.[0].digest) \(.[0].size) \(.[0].mediaType)" else empty end
  ' "$1"
}

#---------------------------------------------------------------------------#
# The index of a ref
#
# One OCI artifact per target repository and per ref, at the tag index_tag
# gives. It holds what the runs of the ref left on the registry, so a run
# that fails, is held or is cancelled leaves its work to the next run. Its
# artifactType is INDEX_ARTIFACT_TYPE, its annotation
# dev.pkgforge.mirror.index-format is 1, and it has two layers, by title:
#   ref.db     the upstream database the rows describe
#   index.tsv  filename, state, verified, unsigned; tab separated, sorted by
#              filename. State m: the tag holds exactly the package bytes of
#              the ref.db record, and the signature mirror-file expects for
#              it. State a: every server answered 404 (absent upstream).
#              verified and unsigned are 0 or 1, and both 0 for state a.
# scripts/plan reads it and withdraws rows. scripts/index-write writes it.
# ⛔ It is not a database: index and index-<slug> are reserved tag names that
# no package tag can take (tests/unit/10-tag-encoding.sh), and the Worker and
# the wrapper must never serve them.
#
# index_read REPO TAG OUTDIR [DB ...] -> one word on stdout, status 0:
#   ok       read and valid. OUTDIR/index.tsv holds the valid lines,
#            OUTDIR/ref.db the database, OUTDIR/ref.tsv its records.
#   absent   the registry has no such tag
#   invalid  read, and not a valid index of format 1: do not use it
#   unread   no answer that decides: a transport error, an HTTP error, a
#            blob that is not its digest
# OUTDIR/manifest.json holds the manifest when the state is ok or invalid.
# A DB whose sha256 is the digest of the ref.db layer is copied, not read.
# The reads send REGISTRY_TOKEN as it is set (registry_manifest,
# registry_blob). A line of index.tsv that does not fit the grammar, or whose
# filename ref.db does not name, is dropped; so are both lines of a filename
# given twice. More than 1% of the lines dropped makes the index invalid.
#
# index_push ORAS REPO TAG DIR ANNOTATION... -> 0 pushed, 1 not: DIR/ref.db
# and DIR/index.tsv as REPO:TAG, each ANNOTATION (key=value) on the
# manifest. DIR may be relative. Needs ORAS_CONFIG (oras_args). A 429 costs no attempt: its pauses
# add up to INDEX_RATE_WAIT (default 120 s), a cap of their own; the
# THROTTLE_WAITED of the caller is kept. At most 2 attempts, each within
# 120 s.
#
# index_listed REPO TAG OUT -> 0: OUT holds the filenames of the m rows of
# REPO:TAG, sorted, each once; OUT is empty when the registry has no such
# tag. 1: no answer that decides, or not an index of format 1 with an
# index.tsv layer; INDEX_LISTED_WHY says which. The manifest and the
# index.tsv blob each get 3 tries, a blob read 60 s. The reads send
# REGISTRY_TOKEN as it is set. ref.db is not read: a row is listed whether
# ref.db names its file or not.
#
# index_guard PLAN_DIR WORK -> the re-run guard of scripts/mirror-shard. It
# reads PLAN_DIR/meta.env as data: TARGET names the target file in
# TARGETS_DIR, INDEX_TAG the tag. Then it reads that tag once (index_listed).
#   0  WORK/index-listed.txt holds the filenames of the m rows
#   1  no answer that decides: WORK/index-unread says why, and a warning
#      says so. scripts/mirror-file then writes no tag.
#---------------------------------------------------------------------------#
INDEX_ARTIFACT_TYPE=application/vnd.pkgforge.archlinux.index.v1
INDEX_DB_MEDIA_TYPE=application/vnd.pkgforge.archlinux.db.v1
INDEX_TSV_MEDIA_TYPE=application/vnd.pkgforge.archlinux.index.v1+tsv

index_read() {
  local repo="$1" tag="$2" outdir="$3" rc=0 f ctx db_digest db_type tsv_digest tsv_type counts total bad
  shift 3
  if ! mkdir -p "$outdir"; then
    echo unread
    return 0
  fi
  rm -f -- "$outdir/manifest.json" "$outdir/ref.db" "$outdir/ref.tsv" "$outdir/ref.bad" "$outdir/index.raw" "$outdir/index.tsv"
  registry_manifest "$repo" "$tag" "$outdir/manifest.json" || rc=$?
  case "$rc" in
    "$REG_STATUS_OK") ;;
    "$REG_STATUS_ABSENT")
      rm -f -- "$outdir/manifest.json"
      echo absent
      return 0
      ;;
    *)
      rm -f -- "$outdir/manifest.json"
      echo unread
      return 0
      ;;
  esac
  if ! jq -e --arg t "$INDEX_ARTIFACT_TYPE" '.artifactType == $t and .annotations["dev.pkgforge.mirror.index-format"]? == "1" and (.layers | length) == 2' "$outdir/manifest.json" > /dev/null; then
    warn "$repo:$tag is not an index of format 1: its artifactType, its index-format annotation or its layer count differs" \
      "$(head -c 300 "$outdir/manifest.json")"
    echo invalid
    return 0
  fi
  ctx="$(jq -r '.annotations["dev.pkgforge.mirror.verify-context"] // ""' "$outdir/manifest.json")"
  read -r db_digest _ db_type <<< "$(manifest_layer "$outdir/manifest.json" ref.db)"
  read -r tsv_digest _ tsv_type <<< "$(manifest_layer "$outdir/manifest.json" index.tsv)"
  if [ "$db_type" != "$INDEX_DB_MEDIA_TYPE" ] || [ "$tsv_type" != "$INDEX_TSV_MEDIA_TYPE" ] ||
    [[ ! "$db_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || [[ ! "$tsv_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    [[ ! "$ctx" =~ ^([0-9a-f]{64})?$ ]]; then
    warn "$repo:$tag is not an index of format 1: a layer ref.db ($db_type) and a layer index.tsv ($tsv_type), each with a sha256 digest, and a verify-context of 64 hex digits or none" \
      "$(head -c 300 "$outdir/manifest.json")"
    echo invalid
    return 0
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ "sha256:$(sha256sum "$f" | cut -d ' ' -f 1)" = "$db_digest" ] && cp "$f" "$outdir/ref.db"; then
      break
    fi
  done
  if [ ! -f "$outdir/ref.db" ] && ! registry_blob "$repo" "$db_digest" "$outdir/ref.db"; then
    echo unread
    return 0
  fi
  if ! registry_blob "$repo" "$tsv_digest" "$outdir/index.raw"; then
    echo unread
    return 0
  fi
  # `if !`: db_records must not be called bare (see db_records).
  if ! db_records "$outdir/ref.db" "$outdir/ref.tsv"; then
    warn "$repo:$tag: its ref.db ($db_digest) does not read as a tar archive"
    echo invalid
    return 0
  fi
  if ! db_validate "$outdir/ref.tsv" > "$outdir/ref.bad"; then
    warn "$repo:$tag: records of its ref.db ($db_digest) fail their grammar" "$(sed -n 1,3p "$outdir/ref.bad")"
    echo invalid
    return 0
  fi
  # Each line: 4 fields, state m or a, flags 0 or 1, both 0 for a, and a
  # filename ref.db names. A filename on two lines drops both.
  if ! counts="$(awk -F '\t' -v out="$outdir/index.tsv" '
    FILENAME == ARGV[1] { named[$1] = 1; next }
    {
      n++
      l[n] = $0
      g[n] = (NF == 4 && ($1 in named) && ($2 == "m" || $2 == "a") && ($3 == "0" || $3 == "1") && ($4 == "0" || $4 == "1") && ($2 == "m" || ($3 == "0" && $4 == "0")))
      if (g[n]) { f[n] = $1; seen[$1]++ }
    }
    END {
      printf "" > out
      for (i = 1; i <= n; i++) {
        if (g[i] && seen[f[i]] == 1) print l[i] > out
        else bad++
      }
      print n + 0, bad + 0
    }
  ' "$outdir/ref.tsv" "$outdir/index.raw")"; then
    echo unread
    return 0
  fi
  read -r total bad <<< "$counts"
  if [ "$((bad * 100))" -gt "$total" ]; then
    warn "$repo:$tag: $bad of $total line(s) of its index.tsv fail their grammar, name no file of its ref.db or name a file twice; more than 1%"
    echo invalid
    return 0
  fi
  if [ "$bad" -gt 0 ]; then
    log "$repo:$tag: $bad of $total line(s) of its index.tsv are dropped: they fail their grammar, name no file of its ref.db or name a file twice"
  fi
  echo ok
}

index_push() {
  local oras="$1" repo="$2" tag="$3" dir="$4" cap="${INDEX_RATE_WAIT:-120}" saved="$THROTTLE_WAITED" rc=0 attempt=0 a
  shift 4
  case "$cap" in
    '' | *[!0-9]*) die "INDEX_RATE_WAIT must be whole seconds, not '$cap'" ;;
  esac
  if [ ! -f "$dir/ref.db" ] || [ ! -f "$dir/index.tsv" ]; then
    warn "$repo:$tag: $dir holds no ref.db and index.tsv to push"
    return 1
  fi
  # An absolute path: the push runs from inside DIR, and its log is DIR/push.log.
  if ! dir="$(cd "$dir" && pwd)"; then
    warn "$repo:$tag: $dir could not be made an absolute path"
    return 1
  fi
  local oargs=() args=()
  mapfile -t oargs < <(oras_args)
  args=(push "${oargs[@]}" --artifact-type "$INDEX_ARTIFACT_TYPE")
  for a in "$@"; do
    args+=(--annotation "$a")
  done
  args+=("$MIRROR_REGISTRY/$repo:$tag" "./ref.db:$INDEX_DB_MEDIA_TYPE" "./index.tsv:$INDEX_TSV_MEDIA_TYPE")
  THROTTLE_WAITED=0
  while :; do
    rc=0
    (cd "$dir" && timeout -k 10 120 "$oras" "${args[@]}" > "$dir/push.log" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || break
    if rate_limited "$dir/push.log"; then
      throttle_pause "$dir" "$cap" "$repo:$tag: index push" || break
      continue
    fi
    attempt=$((attempt + 1))
    warn "$repo:$tag: index push attempt $attempt ended $rc" "$(tail -n 3 "$dir/push.log")"
    [ "$attempt" -lt 2 ] || break
    sleep 5
  done
  if [ "$rc" -ne 0 ]; then
    warn "$repo:$tag: the index was not pushed ($attempt failed attempt(s), ${THROTTLE_WAITED}s of 429 pauses of at most INDEX_RATE_WAIT=${cap}s): $(tail -n 1 "$dir/push.log")"
  fi
  THROTTLE_WAITED="$saved"
  return "$rc"
}

# ⛔ Each step is checked on its own: the caller calls it in an if, where
# set -e does not act, and a list that is not whole lets a tag be written.
INDEX_LISTED_WHY=""
index_listed() {
  local repo="$1" tag="$2" outfile="$3" tmpd try rc=0 d t
  INDEX_LISTED_WHY=""
  rm -f -- "$outfile"
  if ! tmpd="$(mktemp -d)"; then
    INDEX_LISTED_WHY="no temporary directory for the read of $repo:$tag"
    return 1
  fi
  for try in 1 2 3; do
    rc=0
    registry_manifest "$repo" "$tag" "$tmpd/manifest.json" || rc=$?
    if [ "$rc" -eq "$REG_STATUS_OK" ] || [ "$rc" -eq "$REG_STATUS_ABSENT" ] || [ "$try" -eq 3 ]; then
      break
    fi
    sleep "$try"
  done
  if [ "$rc" -eq "$REG_STATUS_ABSENT" ]; then
    : > "$tmpd/index.tsv"
  elif [ "$rc" -ne "$REG_STATUS_OK" ]; then
    INDEX_LISTED_WHY="$repo:$tag did not read in 3 tries (HTTP $REG_LAST_CODE)"
  elif [ "$(jq -r --arg t "$INDEX_ARTIFACT_TYPE" '.artifactType == $t and .annotations["dev.pkgforge.mirror.index-format"]? == "1"' "$tmpd/manifest.json")" != true ]; then
    INDEX_LISTED_WHY="$repo:$tag is not an index of format 1"
  else
    read -r d _ t <<< "$(manifest_layer "$tmpd/manifest.json" index.tsv)"
    if [[ ! "${d:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || [ "${t:-}" != "$INDEX_TSV_MEDIA_TYPE" ]; then
      INDEX_LISTED_WHY="$repo:$tag has no index.tsv layer of $INDEX_TSV_MEDIA_TYPE"
    else
      for try in 1 2 3; do
        rc=0
        REG_BLOB_MAX_TIME=60 REG_TOKEN_MAX_TIME=60 registry_blob "$repo" "$d" "$tmpd/index.tsv" || rc=$?
        if [ "$rc" -eq 0 ] || [ "$try" -eq 3 ]; then
          break
        fi
        sleep "$try"
      done
      if [ "$rc" -ne 0 ]; then
        INDEX_LISTED_WHY="the index.tsv of $repo:$tag ($d) did not read in 3 tries"
      fi
    fi
  fi
  if [ -z "$INDEX_LISTED_WHY" ] && ! awk -F '\t' '$2 == "m" { print $1 }' "$tmpd/index.tsv" | LC_ALL=C sort -u > "$outfile"; then
    INDEX_LISTED_WHY="the m rows of $repo:$tag could not be written to $outfile"
  fi
  rm -rf -- "$tmpd"
  if [ -n "$INDEX_LISTED_WHY" ]; then
    rm -f -- "$outfile"
    return 1
  fi
  return 0
}

# ⛔ Each step is checked on its own, as in index_listed. WORK/index-listed.txt
# exists only when the whole list is written.
index_guard() {
  local pdir="$1" work="$2" tgt="" tag="" conf repo why=""
  rm -f -- "$work/index-listed.txt" "$work/index-unread"
  if [ -f "$pdir/meta.env" ]; then
    tgt="$(awk 'index($0, "TARGET=") == 1 { v = substr($0, 8) } END { print v }' "$pdir/meta.env")"
    tag="$(awk 'index($0, "INDEX_TAG=") == 1 { v = substr($0, 11) } END { print v }' "$pdir/meta.env")"
  fi
  conf="$TARGETS_DIR/$tgt.conf"
  if [ ! -f "$pdir/meta.env" ]; then
    why="$pdir/meta.env does not exist, so the index tag is not known"
  elif [ -z "$tgt" ] || [[ "$tgt" == *[!a-z0-9_.-]* ]] || [ ! -f "$conf" ]; then
    why="$pdir/meta.env: TARGET '$tgt' names no target file in $TARGETS_DIR"
  elif [[ ! "$tag" =~ ^index(-[a-z0-9]+(-[a-z0-9]+)*)?$ ]]; then
    why="$pdir/meta.env: INDEX_TAG is '$tag', not index or index-<slug>"
  else
    target_check "$conf"
    repo="$(target_repository "$conf")"
    if index_listed "$repo" "$tag" "$work/index-listed.txt"; then
      log "a re-run: $repo:$tag lists $(awk 'END { print NR + 0 }' "$work/index-listed.txt") file(s) on the registry; no tag of these is written"
      return 0
    fi
    why="$INDEX_LISTED_WHY"
  fi
  printf '%s\n' "$why" > "$work/index-unread"
  warn "a re-run: the live index did not read ($why); no tag is written in this shard" \
    "a file whose tag holds it already still counts; the next run plans again"
  return 1
}

# fetch_upstream URL OUT [MAX_SECONDS] -> 0 fetched, 4 the server says it has
# no such file, 1 anything else. Every fetch has a stall deadline (60 s below
# 4096 B/s). With MAX_SECONDS the whole call also ends within MAX_SECONDS, its
# retries included, so a server that trickles moves the caller on to the next
# server. The caller sets MAX_SECONDS: a fixed one for a database or a
# signature, one from the size for a package file.
#
# curl gives each retry a new --max-time. --retry-max-time starts no retry
# after MAX_SECONDS, and timeout(1) ends a retry that started just before it.
# Without them a call took 3 x MAX_SECONDS + 4 s (measured with curl 8.22).
#
# An answer other than 200, 404 and 410 is logged with its HTTP code, and
# with Cloudflare's cf-mitigated header when the answer has one: a block or a
# challenge then shows as what it is, not as a server that did not answer.
# 404 and 410 are not logged: mirror-file asks for many .sig files that are
# not there. %header{} needs curl 7.84; an older curl prints it as it is,
# and that is ignored.
fetch_upstream() {
  local url="$1" outfile="$2" out code cf="" rc=0 max=() limit=() fmax
  if [ -n "${3:-}" ]; then
    max=(--max-time "$3" --retry-max-time "$3")
    limit=(timeout -k 5 "$(($3 + 5))")
  fi
  # MIRROR_FETCHER names another reader (fetchers/fetcher.sh): it picks a
  # client, keeps its own deadlines and states absence with 4, as curl does.
  # It names the client and the reason in its own log lines, so this path has
  # no cf-mitigated detail to report: only the curl path below reads that.
  if [ -n "${MIRROR_FETCHER:-}" ]; then
    # The whole call keeps the caller's budget, as the curl path does: the hard
    # stop is MAX_SECONDS + 10, and the fetcher gets MAX_SECONDS as its
    # per-attempt deadline with one attempt per client. A client that a host
    # refuses (403 or a challenge page) answers fast, so the ordered fallback
    # still fits the budget; only a client that reads the file, or one that
    # stalls, spends it, and a stall ends all clients the same. The pipeline
    # retries a file across runs.
    fmax="${3:-300}"
    rc=0
    timeout -k 5 "$((fmax + 10))" \
      "$MIRROR_FETCHER" --quiet --retries 1 --timeout "$fmax" --expect any "$url" "$outfile" || rc=$?
    case "$rc" in
      0) return 0 ;;
      4) rm -f "$outfile"; return 4 ;;
      *) rm -f "$outfile"; return 1 ;;
    esac
  fi
  out="$("${limit[@]}" curl -q --location --silent --show-error --max-redirs 5 \
    --proto "$UPSTREAM_PROTO" --proto-redir "$UPSTREAM_PROTO" \
    --connect-timeout 20 --speed-limit 4096 --speed-time 60 "${max[@]}" \
    --retry 2 --retry-connrefused --retry-delay 2 \
    --user-agent "mirror-archlinux (+https://github.com/${GITHUB_REPOSITORY:-pkgforge-dev/mirror-archlinux})" \
    --output "$outfile" --write-out '%{http_code}\t%header{cf-mitigated}' "$url")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$outfile"
    return 1
  fi
  code="${out:0:3}"
  case "$out" in
    *$'\t'*) cf="${out#*$'\t'}" ;;
  esac
  case "$cf" in
    *%* | *[![:print:]]*) cf="" ;;
  esac
  case "$code" in
    200) return 0 ;;
    404 | 410)
      rm -f "$outfile"
      return 4
      ;;
    *)
      log "$url answered HTTP $code${cf:+ (cf-mitigated: $cf)}"
      rm -f "$outfile"
      return 1
      ;;
  esac
}

# sig_packet FILE -> 0 when FILE can be a detached signature: 1 to 65535
# bytes, starting with an OpenPGP signature packet tag (0x88, 0x89 or 0xc2)
sig_packet() {
  local size first_byte
  size="$(wc -c < "$1" | tr -d ' ')"
  first_byte="$(od -An -tx1 -N1 "$1" | tr -d ' \n')"
  [ "$size" -gt 0 ] && [ "$size" -lt 65536 ] && [[ "$first_byte" =~ ^(88|89|c2)$ ]]
}

#---------------------------------------------------------------------------#
# Servers that failed
#
# A directory holds one empty file per host that failed: no answer in time, a
# connection that failed, or an HTTP status other than 200, 404 and 410. The
# processes that share the directory then ask that host last. A host that
# stalls costs one deadline per directory, not one per file. It is still asked
# when every other server fails.
#
# down_mark DIR URL: remember that the host of URL failed
# down_last DIR URL... -> the URLs, one per line, in the order given, except
#   that those whose host failed come last
#---------------------------------------------------------------------------#
# url_host URL -> the host and port of URL
url_host() {
  local h="${1#*://}"
  printf '%s\n' "${h%%/*}"
}

# in_list WORD LIST... -> 0 when WORD is one of LIST
in_list() {
  local w="$1" x
  shift
  for x in "$@"; do
    [ "$x" != "$w" ] || return 0
  done
  return 1
}

# down_key URL -> the file name for the host and port of URL
down_key() {
  local h="${1#*://}"
  h="${h%%/*}"
  printf 'h-%s\n' "$(printf '%s' "$h" | tr -c 'A-Za-z0-9.:_-' '_')"
}

down_mark() {
  mkdir -p -- "$1"
  : > "$1/$(down_key "$2")"
}

down_last() {
  local dir="$1" u
  shift
  for u in "$@"; do
    [ -e "$dir/$(down_key "$u")" ] || printf '%s\n' "$u"
  done
  for u in "$@"; do
    [ ! -e "$dir/$(down_key "$u")" ] || printf '%s\n' "$u"
  done
}

# Seconds since the epoch, from the environment when a test pins the clock.
now_epoch() {
  printf '%s\n' "${MIRROR_NOW:-$(date -u +%s)}"
}

# iso_of_epoch SECONDS -> that time as ISO 8601 UTC
iso_of_epoch() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

#---------------------------------------------------------------------------#
# How work is split
#
# shard_count FILES BYTES SHARD_FILES SHARD_BYTES MAX -> "K WANTED"
#   WANTED = max(ceil(BYTES / SHARD_BYTES), ceil(FILES / SHARD_FILES)), at
#   least 1; K is WANTED clamped to MAX and to FILES. No file: "0 0".
#
# batch_count FILES BYTES BATCH_FILES BATCH_BYTES MAX -> "K FILES_LIMIT BYTES_LIMIT WANTED"
#   As shard_count with the limits given, but when that gives more than MAX
#   batches, both limits grow by an eighth at a time until it does not: every
#   file is still verified, in fewer, larger batches.
#---------------------------------------------------------------------------#
shard_count() {
  awk -v f="$1" -v b="$2" -v sf="$3" -v sb="$4" -v m="$5" 'BEGIN {
    if (f + 0 <= 0) { print "0 0"; exit }
    kb = int((b + sb - 1) / sb); kf = int((f + sf - 1) / sf)
    k = (kb > kf) ? kb : kf
    if (k < 1) k = 1
    w = k
    if (k > m + 0) k = m + 0
    if (k > f + 0) k = f + 0
    printf "%d %d\n", k, w
  }'
}

batch_count() {
  awk -v f="$1" -v b="$2" -v bf="$3" -v bb="$4" -v m="$5" 'BEGIN {
    w = 0
    for (;;) {
      kb = int((b + bb - 1) / bb); kf = int((f + bf - 1) / bf)
      k = (kb > kf) ? kb : kf
      if (k < 1) k = 1
      if (w == 0) w = k
      if (k <= m + 0) break
      bb = bb + int(bb / 8) + 1
      bf = bf + int(bf / 8) + 1
    }
    printf "%d %d %.0f %d\n", k, bf, bb, w
  }'
}

#---------------------------------------------------------------------------#
# Why pacman refused one package
#
# refusal_reason LOG PKG_RC SIG_RC -> "CLASS<TAB>LINE", from pacman's output
# for that one package (pacman -Swdd, pacman 7.1 wording), and from the exit
# status of the wrapper asked for the package and for its .sig alone:
#   sig-missing  no signature could be read: pacman says a required one is
#                missing or the .sig did not download, or the wrapper serves
#                the package and no .sig
#   sig-refused  pacman read a signature and refused it: an expired or unknown
#                key, a trust it does not accept, or a signature that is not
#                valid for the bytes. pacman 7.1 takes a key whose primary has
#                expired for a missing one: it asks a keyserver, then says
#                "required key missing from keyring" (measured 2026-10-14).
#   arch         pacman refuses the package for its architecture: a cross-arch
#                package upstream lists in this repository (ArchPOWER's powerpc64
#                database carries powerpc64le ones). It is upstream's own defect,
#                so verify excuses it once the mirror is seen to serve exactly
#                the database's bytes (scripts/verify-batch upstream_refused).
#   other        anything else: the wrapper does not serve the package, a
#                checksum, a name pacman does not know
# An arch or other line wins over any signature line: a package with two faults
# is classed by the one that is not a signature. arch wins even over "the
# wrapper does not serve it", since pacman naming the architecture is the real
# reason. The wrapper's own lines are not read: they are its wording, which may
# change, not pacman's verdict.
#---------------------------------------------------------------------------#
refusal_reason() {
  awk -v pkg="${2:-}" -v sig="${3:-}" '
    /^pacman-oci:/ { next }
    {
      line = $0
      if (match(line, /failed retrieving file '\''[^'\'']*'\''/)) {
        name = substr(line, RSTART, RLENGTH)
        if (name ~ /\.sig'\''$/) { if (missing == "") missing = line }
        else if (other == "") other = line
        next
      }
      if (line ~ /invalid or corrupted package \(checksum\)/) {
        if (other == "") other = line
        next
      }
      if (line ~ /does not have a valid architecture|package architecture is not valid/) {
        if (arch_err == "") arch_err = line
        next
      }
      if (line ~ /missing required signature/) { if (missing == "") missing = line; next }
      if (line ~ /signature from ".*" is (expired|invalid|unknown trust|marginal trust|never trusted)/ ||
          line ~ /key ".*" (is expired|is unknown|is disabled|could not be looked up remotely)/ ||
          line ~ /required key missing from keyring|signature format error|unsupported signature format/ ||
          line ~ /invalid or corrupted package \(PGP signature\)/) {
        if (refused == "") refused = line
        next
      }
      if (line ~ /^error: / && line !~ /^error: failed to commit transaction/ && other == "") other = line
    }
    END {
      if (arch_err != "") print "arch\t" arch_err
      else if (pkg != "0") print "other\tthe wrapper does not serve the package itself (exit " pkg ")"
      else if (other != "") print "other\t" other
      else if (refused != "") print "sig-refused\t" refused
      else if (missing != "") print "sig-missing\t" missing
      else if (sig != "0") print "sig-missing\tthe wrapper serves the package and no .sig (exit " sig ")"
      else print "other\tpacman named no reason"
    }
  ' "$1"
}
