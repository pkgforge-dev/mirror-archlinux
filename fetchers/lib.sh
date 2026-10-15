# Shared helpers for the fetchers in this directory. Sourced, never executed.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# The interface of a client is the same for every one:
#
#   <client> <url> <out>
#
# It writes the body to <out> and exits 0 when it read it, 4 when the server
# answered 404 or 410, and anything else otherwise. Nothing else is assumed
# about the reason. fetcher.sh picks the clients, in an order, and stops at the
# first body that passes the structural check its caller asked for.

FETCHER_HOME="${FETCHER_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FETCHER_CACHE="${FETCHER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mirror-archlinux/fetcher}"

# Extra request headers ("Name: Value"), set by fetcher.sh --header. curl and
# curl-impersonate get them as --header; the browser clients read them from
# FETCHER_HEADERS, one per line.
HEADERS=()

# The clients, in the order auto mode tries them. Plain curl is left out on
# purpose: an origin behind Cloudflare refuses the runner's own address and
# fingerprint, so a plain-curl call is a wasted round trip before the browser
# profile that answers. Each engine is tried twice, first against the origin and
# then through the api.rv.pkgforge.dev read-through proxy (the "-rv" variant),
# which dials the origin from its own network: curl-impersonate (a curl with a
# browser's TLS and HTTP/2 profile) direct, curl-impersonate through the proxy,
# then a full Chromium direct and through the proxy. A host with a known answer
# starts at the client that answered it last.
# shellcheck disable=SC2034 # read by fetcher.sh and drift.sh
FETCHER_CLIENTS_DEFAULT="curl-impersonate curl-impersonate-rv chromium chromium-rv"

# The read-through proxy the "-rv" client variants dial through. It fetches the
# origin URL from its own network and hands the body back, so a runner the
# origin refuses still reads. The engine and its fingerprint are unchanged; only
# the URL it asks for is rewritten to "<base>/<origin url>".
FETCHER_RV_BASE="${FETCHER_RV_BASE:-https://api.rv.pkgforge.dev}"

fetcher_log() {
  printf 'fetcher: %s\n' "$*" >&2
}

fetcher_warn() {
  printf 'fetcher: warning: %s\n' "$*" >&2
}

fetcher_die() {
  printf 'fetcher: %s\n' "$*" >&2
  exit 1
}

# has_cmd NAME -> 0 when NAME is on PATH. A presence probe, and the status is
# its answer, so nothing is thrown away here. Written as a function so every
# probe reads the same way and the reason is in one place.
has_cmd() {
  command -v "$1" > /dev/null
}

# fetcher_cache_dir SUB -> that directory under the cache root, made
fetcher_cache_dir() {
  local d="$FETCHER_CACHE/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# body_magic FILE -> the first four bytes in hex
body_magic() {
  od -An -tx1 -N4 "$1" | tr -d ' \n'
}

# body_validate FILE EXPECT -> 0 when FILE is what EXPECT names, else prints why
#   any   not empty, and not an HTML document
#   sig   one OpenPGP signature packet, under 64 KiB (lib.sh sig_packet)
#   db    a tar archive, zstd or gzip, that holds a package desc member
#   tar   a tar archive, zstd or gzip, whatever its members
body_validate() {
  local file="$1" expect="$2" size magic first err why list_err head_tmp
  [ -f "$file" ] || { echo "no file"; return 1; }
  head_tmp="$(mktemp)"
  size="$(wc -c < "$file" | tr -d ' ')"
  [ "$size" -gt 0 ] || { echo "empty"; return 1; }
  case "$expect" in
    any)
      # An origin that answers 200 with a page has not served the file that
      # was asked for. No database, signature or package file starts with an
      # HTML document, so this is refused whatever the caller expected.
      #
      # The first 4 KiB go to a file and the file is read. A pipeline into
      # `grep -q` closes the pipe while the producer is still writing, which
      # under pipefail is status 141 from a check that passed; the doc of
      # tests/static/35-pipeline-traps.sh has a measured instance of it.
      head -c 4096 -- "$file" > "$head_tmp"
      if grep -qiE '<!doctype html|<html|</html>' "$head_tmp"; then
        rm -f "$head_tmp"
        echo "an HTML document"
        return 1
      fi
      rm -f "$head_tmp"
      return 0
      ;;
    sig)
      first="$(od -An -tx1 -N1 "$file" | tr -d ' \n')"
      if [ "$size" -ge 65536 ]; then echo "signature of $size bytes"; return 1; fi
      case "$first" in
        88 | 89 | c2) ;;
        *) echo "no OpenPGP signature packet (first byte $first)"; return 1 ;;
      esac
      return 0
      ;;
    db | tar) ;;
    *) echo "unknown expect '$expect'"; return 1 ;;
  esac
  magic="$(body_magic "$file")"
  case "$magic" in
    28b52ffd | 1f8b*) ;;
    *) echo "not a zstd or gzip archive (magic $magic)"; return 1 ;;
  esac
  # tar's own complaint is kept, so a database that is a valid archive with a
  # broken member is not reported the same way as one that is not an archive.
  err="$(mktemp)"
  if ! tar -tf "$file" > /dev/null 2> "$err"; then
    why="$(sed -n 1p "$err")"
    rm -f "$err"
    echo "it does not read as a tar archive${why:+: $why}"
    return 1
  fi
  rm -f "$err"
  if [ "$expect" = db ]; then
    # grep without -q reads to the end, so the tar on the left is never sent
    # SIGPIPE and `set -o pipefail` does not read a missing desc as failure.
    # tar's own complaint is kept: an archive that lists but cannot read a
    # member is not the same fault as one with no member, and only tar knows
    # which it was.
    list_err="$(mktemp)"
    if ! tar -tf "$file" 2> "$list_err" | grep '/desc$' > /dev/null; then
      why="$(sed -n 1p "$list_err")"
      rm -f "$list_err"
      if [ -n "$why" ]; then
        echo "a package desc member does not read: $why"
      else
        echo "the archive holds no package desc member"
      fi
      return 1
    fi
    rm -f "$list_err"
  fi
  return 0
}

# sig_verify SIG DATA KEYRING... -> 0 when SIG is a valid detached signature over
# DATA under one of KEYRINGs. The signature is the first argument on purpose:
# gpgv takes the signature first and the signed data second, and given them the
# other way round it reports "no valid OpenPGP data found".
#
# Every keyring given is passed to one gpgv call, so a signature that is signed
# by the second of two is verified rather than reported as unsigned. gpgv and
# not gpg: gpgv verifies and does not import, so a check here cannot change the
# trust store it verified against.
sig_verify() {
  local sig="$1" data="$2"
  shift 2
  local gpgv_bin="" candidate rc=0 kr
  local -a args=()
  if [ "$#" -eq 0 ]; then
    echo "a signature check needs a keyring"
    return 1
  fi
  for candidate in gpgv gpgv2 /usr/bin/gpgv; do
    if has_cmd "$candidate"; then
      gpgv_bin="$candidate"
      break
    fi
  done
  if [ -z "$gpgv_bin" ]; then
    echo "gpgv is not installed, so the signature cannot be checked"
    return 1
  fi
  # Every keyring is passed to the one call. gpgv takes several and uses the
  # first that holds the key, which is what "one of these keyrings" means, and
  # a signature made by the second of two is verified rather than reported as
  # unsigned.
  for kr in "$@"; do
    args+=(--keyring "$kr")
  done
  # The signature first, the data second. gpgv reads the position, not the
  # extension, so this order is the check and the other one is not.
  "$gpgv_bin" "${args[@]}" "$sig" "$data"
  rc=$?
  return "$rc"
}

# A memo of availability answers for this process, keyed by engine. An "-rv"
# variant shares its base engine's answer, so a --list or --explain that holds
# both an engine and its "-rv" does not run the probe twice, and --no-cache
# (which skips the on-disk cache) still asks each engine once per run rather than
# once per variant. It is reset per process, so it never outlives a probe.
declare -A FETCHER_AVAIL_MEMO=()

# client_available NAME -> 0 when NAME can run here. The answer is kept for
# FETCHER_AVAILABLE_TTL seconds (default 300; 0 asks every time, and
# FETCHER_NO_AVAILABLE_CACHE=1 asks every time too), because a browser probe
# starts node or python and costs more than the fetch it guards.
client_available() {
  local name="$1" script rc=0 stamp now ttl="${FETCHER_AVAILABLE_TTL:-300}" cache
  # An "-rv" variant runs the same engine through the proxy, so it can run
  # wherever the engine can: the suffix is dropped and the engine is probed.
  name="${name%-rv}"
  case "$name" in
    curl) has_cmd curl; return $? ;;
    curl-impersonate | chromium | cloak-browser | playwright) ;;
    *) return 1 ;;
  esac
  # Already answered for this engine in this process: an -rv variant and its
  # base never probe twice, whatever the on-disk cache says.
  if [ -n "${FETCHER_AVAIL_MEMO[$name]+set}" ]; then
    return "${FETCHER_AVAIL_MEMO[$name]}"
  fi
  case "$ttl" in
    '' | *[!0-9]*) ttl=0 ;;
  esac
  cache="$FETCHER_CACHE/available/$name"
  if [ "$ttl" -gt 0 ] && [ "${FETCHER_NO_AVAILABLE_CACHE:-0}" -eq 0 ] && [ -r "$cache" ]; then
    now="$(date -u +%s)"
    stamp=""
    # A cache entry that does not read is a cache miss, not a failure: the
    # probe below answers it anyway. The status goes unused on purpose, and
    # the stamp is checked before the status is believed.
    if read -r stamp rc < "$cache"; then
      :
    else
      stamp=""
    fi
    # The entry holds a stamp and a status. Both are checked before either is
    # believed: a status that is not 0 or 1 is not a status, and returning it
    # would make bash complain about a non-numeric argument and the caller
    # would skip the probe for this entry's whole ttl.
    case "$rc" in
      0 | 1) ;;
      *) rc= ;;
    esac
    case "$stamp" in
      '' | *[!0-9]*) rc= ;;
      *)
        if [ "$rc" != '' ] && [ $((now - stamp)) -lt "$ttl" ]; then
          FETCHER_AVAIL_MEMO[$name]="$rc"
          return "$rc"
        fi
        ;;
    esac
  fi
  script="$FETCHER_HOME/$name/available"
  rc=1
  if [ -x "$script" ]; then
    if "$script"; then rc=0; else rc=1; fi
  fi
  if [ "$ttl" -gt 0 ] && [ "${FETCHER_NO_AVAILABLE_CACHE:-0}" -eq 0 ]; then
    # Not caching is not a failure of the probe, and the answer is already in
    # $rc. So an unwritable cache directory is passed over, and a half-written
    # entry is removed rather than left for the next reader to trust.
    if mkdir -p "$FETCHER_CACHE/available"; then
      if printf '%s\t%s\n' "$(date -u +%s)" "$rc" > "$FETCHER_CACHE/available/.$name.$$"; then
        mv -f "$FETCHER_CACHE/available/.$name.$$" "$FETCHER_CACHE/available/$name" ||
          rm -f "$FETCHER_CACHE/available/.$name.$$"
      fi
    fi
  fi
  FETCHER_AVAIL_MEMO[$name]="$rc"
  return "$rc"
}

# retry_delay ATTEMPT -> the whole seconds to wait before ATTEMPT: 2, 4, 8,
# 16, then 30. retry_sleep adds up to 0.9 s of jitter, so two callers that
# back off from the same host do not retry in lockstep.
retry_delay() {
  local attempt="$1" delay=2 i=1
  while [ "$i" -lt "$attempt" ] && [ "$delay" -lt 30 ]; do
    delay=$((delay * 2))
    i=$((i + 1))
  done
  [ "$delay" -le 30 ] || delay=30
  printf '%s\n' "$delay"
}

retry_sleep() {
  sleep "$(retry_delay "$1").$((RANDOM % 10))"
}

# retry_run LABEL CMD... -> run CMD, and on failure retry it up to
# FETCHER_INSTALL_RETRIES times (default 4) with the shared backoff. The npm
# registry and the browser CDN reset a connection now and then; a transient
# failure here would leave a runner without the client it installs, so a shard
# that needs a browser to read a host would fall back to curl and get a 403 for
# every file. The retry keeps that one hiccup from failing the whole shard. The
# last attempt's own output is left for the caller, which reports it.
retry_run() {
  local label="$1" attempt=1 max="${FETCHER_INSTALL_RETRIES:-4}"
  shift
  case "$max" in
    '' | *[!0-9]* | 0) max=4 ;;
  esac
  while :; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      fetcher_warn "$label did not succeed in $attempt attempt(s)"
      return 1
    fi
    fetcher_warn "$label failed (attempt $attempt of $max); retrying after a pause"
    retry_sleep "$attempt"
    attempt=$((attempt + 1))
  done
}

# client_known NAME -> 0 when NAME is a client this manager can run. A client
# that is not available here is still known: only a name no build defines is
# refused.
client_known() {
  case "$1" in
    curl | curl-impersonate | curl-impersonate-rv | chromium | chromium-rv | cloak-browser | playwright) return 0 ;;
    *) return 1 ;;
  esac
}

# client_run NAME URL OUT LOG [REFERER] -> the client's own status. The body
# lands in OUT; the client's own output lands in LOG. Every client is wrapped
# in a hard stop of FETCHER_MAX_TIME + 5 s, so a browser that hangs ends within
# the same deadline curl has. The headers of HEADERS and REFERER, if given,
# reach the client.
client_run() {
  local name="$1" url="$2" out="$3" log="$4" referer="${5:-}" secs="${FETCHER_MAX_TIME:-300}" dead=() cap=() hdrs=() h
  # An "-rv" variant reads the same URL through the api.rv.pkgforge.dev
  # read-through proxy, which dials the origin from its own network, so a runner
  # the origin refuses still reads. The engine and its fingerprint stay the same:
  # only the URL it asks for is the proxied one, and then the dispatch below is
  # the engine's own, unchanged.
  case "$name" in
    *-rv)
      name="${name%-rv}"
      url="${FETCHER_RV_BASE:-https://api.rv.pkgforge.dev}/$url"
      ;;
  esac
  dead=(timeout -k 5 "$((secs + 5))")
  if [ "${FETCHER_MAX_BYTES:-0}" -gt 0 ]; then
    cap=(--max-filesize "$FETCHER_MAX_BYTES")
  fi
  for h in "${HEADERS[@]}"; do
    [ -n "$h" ] || continue
    hdrs+=(--header "$h")
  done
  if [ -n "$referer" ]; then
    hdrs+=(--referer "$referer")
  fi
  case "$name" in
    curl)
      "${dead[@]}" curl -q --location --silent --show-error --max-redirs 5 \
        --proto '=https,http' --proto-redir '=https,http' \
        --connect-timeout "${FETCHER_CONNECT_TIMEOUT:-20}" \
        --speed-limit 1024 --speed-time 60 \
        --max-time "$secs" "${cap[@]}" "${hdrs[@]}" \
        --output "$out" --write-out '%{http_code}' "$url" > "$log.code" 2> "$log"
      ;;
    curl-impersonate)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" "$FETCHER_HOME/curl-impersonate/fetch.sh" \
        "$url" "$out" "${HEADERS[@]}" > "$log" 2>&1
      ;;
    chromium | cloak-browser)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" node "$FETCHER_HOME/$name/fetch.mjs" "$url" "$out" "$referer" > "$log" 2>&1
      ;;
    playwright)
      FETCHER_MAX_TIME="$secs" "${dead[@]}" "$FETCHER_HOME/playwright/venv/bin/python" \
        "$FETCHER_HOME/playwright/fetch.py" "$url" "$out" "$referer" > "$log" 2>&1
      ;;
    *)
      echo "unknown client $name" > "$log"
      return 127
      ;;
  esac
}

# status_class LOG RC -> 0 read, 4 absent, 1 anything else. A client that
# writes the HTTP status to LOG.code reports it; every other client maps its
# own exit status, 4 meaning absent. An HTTP answer is authoritative: a 403
# body is not a body, whatever the file holds.
status_class() {
  local log="$1" rc="$2" code=""
  if [ -f "$log.code" ]; then
    code="$(cat "$log.code")"
    case "$code" in
      200) return 0 ;;
      404 | 410) return 4 ;;
      *) return 1 ;;
    esac
  fi
  case "$rc" in
    0) return 0 ;;
    4) return 4 ;;
    *) return 1 ;;
  esac
}

# body_sha256 FILE -> the sha256 of FILE, lowercase hex
body_sha256() {
  sha256sum "$1" | cut -d ' ' -f 1
}
