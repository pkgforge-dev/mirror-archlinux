#!/usr/bin/env bash
#
# Retrieve one URL through a client that can present a browser's TLS and HTTP
# profile, with an ordered fallback and a structural check of the body.
#
#   fetchers/fetcher.sh [OPTIONS] URL OUT
#
# The default order is curl, curl-impersonate, chromium, cloak-browser,
# playwright (fetchers/lib.sh). curl is tried first, so a host that answers
# curl costs one curl call. A host that answered another client before starts
# at that client: the answer of each host is kept in the cache, and a client
# that passed a structural check is the one the next call for that host tries
# first.
#
# A client that reads the body but fails the structural check is not an answer:
# the next client is tried. A client that the server answers 404 or 410 for
# ends the call with status 4: the URL is absent, and another client would hear
# the same.
#
# OPTIONS
#   --client LIST   clients to try, in order, comma or space separated; a
#                   client name may also be given as --client NAME
#   --expect KIND   any (default), db, tar or sig: the structural check
#   --sha256 HEX    the sha256 the body must have, on top of the check above
#   --magic HEX     the first four bytes the body must have, lowercase hex, on
#                   top of the check above. Useful where a wrong file is a
#                   valid archive of the wrong thing.
#   --signature URL check the signature of the body at URL, which is read from
#                   URL.sig through the same client, with gpgv against every
#                   --keyring. The two can therefore never be a signature of one
#                   body checked against another. gpgv and not gpg, so the check
#                   cannot change the trust store it verified against. The body
#                   is only written once its signature verifies.
#   --keyring FILE  a keyring for --signature; repeatable
#   --max-bytes N   refuse a body larger than N bytes (default 0, no cap)
#   --header H      an extra request header, "Name: Value"; repeatable
#   --referer URL   the Referer header, and the page the browser clients visit
#                   before the request (default: the URL's own origin)
#   --retries N     attempts per client (default 2)
#   --timeout SEC   whole-call deadline of one attempt (default 300)
#   --connect SEC   connect deadline (default 20)
#   --no-cache      do not read or write the per-host preference
#   --require-tool NAME
#                   try NAME first, and refuse to run if it cannot, instead of
#                   letting another client answer
#   --list          print the available clients, one per line, and exit
#   --explain       print the URL, host, cached preference, order and each
#                   client's availability, and exit
#   --help          this text, and exit
#   --quiet         no per-attempt line on stderr
#
# Environment: FETCHER_CLIENTS (the order), FETCHER_CACHE (the cache root),
# FETCHER_SUMMARY (a TSV log of every attempt), GITHUB_ACTIONS (annotations).
#
# Exit status: 0 the body is in OUT, 4 the server says the URL is absent, 1
# every client failed or the body did not pass its check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

quiet="${FETCHER_QUIET:-0}"
clients="${FETCHER_CLIENTS:-}"
expect="any"
want_sha=""
retries="${FETCHER_RETRIES:-2}"
timeout_s="${FETCHER_MAX_TIME:-300}"
connect_s="${FETCHER_CONNECT_TIMEOUT:-20}"
max_bytes="${FETCHER_MAX_BYTES:-0}"
headers=()
referer=""
want_magic=""
sig_url=""
sig_of=""
keyrings=()
require=""
use_cache=1
explain=0
explain_url=""
list=0
positional=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --client)
      [ "$#" -ge 2 ] || fetcher_die "--client needs a value"
      clients="${clients:+$clients }$(printf '%s' "$2" | tr ',' ' ')"
      shift 2
      ;;
    --expect)
      [ "$#" -ge 2 ] || fetcher_die "--expect needs a value"
      expect="$2"
      shift 2
      ;;
    --sha256)
      [ "$#" -ge 2 ] || fetcher_die "--sha256 needs a value"
      want_sha="$2"
      shift 2
      ;;
    --magic)
      [ "$#" -ge 2 ] || fetcher_die "--magic needs a value"
      want_magic="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      # Any even number of hex digits up to what a magic check can use. The
      # body is read four bytes at a time, so a longer value is read to fit.
      case "$want_magic" in
        *[!0-9a-f]*) fetcher_die "--magic must be hex digits, not '$2'" ;;
      esac
      case ${#want_magic} in
        2 | 4 | 6 | 8) ;;
        *) fetcher_die "--magic must be 2, 4, 6 or 8 hex characters, not '$2'" ;;
      esac
      shift 2
      ;;
    --signature)
      [ "$#" -ge 2 ] || fetcher_die "--signature needs a value"
      # The body's own URL, with .sig appended. Deriving it here is what keeps
      # the signature and the body from being two different files.
      sig_url="${2%.sig}.sig"
      sig_of="$2"
      shift 2
      ;;
    --keyring)
      [ "$#" -ge 2 ] || fetcher_die "--keyring needs a value"
      keyrings+=("$2")
      shift 2
      ;;
    --require-tool)
      [ "$#" -ge 2 ] || fetcher_die "--require-tool needs a value"
      require="$2"
      shift 2
      ;;
    --max-bytes)
      [ "$#" -ge 2 ] || fetcher_die "--max-bytes needs a value"
      max_bytes="$2"
      shift 2
      ;;
    --header)
      [ "$#" -ge 2 ] || fetcher_die "--header needs a value"
      case "$2" in
        *:*) ;;
        *) fetcher_die "--header must be 'Name: Value', not '$2'" ;;
      esac
      headers+=("$2")
      shift 2
      ;;
    --referer)
      [ "$#" -ge 2 ] || fetcher_die "--referer needs a value"
      referer="$2"
      shift 2
      ;;
    --retries)
      [ "$#" -ge 2 ] || fetcher_die "--retries needs a value"
      retries="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || fetcher_die "--timeout needs a value"
      timeout_s="$2"
      shift 2
      ;;
    --connect)
      [ "$#" -ge 2 ] || fetcher_die "--connect needs a value"
      connect_s="$2"
      shift 2
      ;;
    --no-cache)
      use_cache=0
      FETCHER_NO_AVAILABLE_CACHE=1
      shift
      ;;
    --list)
      list=1
      shift
      ;;
    --explain)
      explain=1
      if [ "$#" -ge 2 ] && [ "${2#http}" != "$2" ]; then
        explain_url="$2"
        shift
      fi
      shift
      ;;
    --help | -h)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      fetcher_die "unknown option $1" "reproduce: fetchers/fetcher.sh --help"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
while [ "$#" -gt 0 ]; do
  positional+=("$1")
  shift
done
case "$expect" in
  any | db | tar | sig) ;;
  *) fetcher_die "--expect must be any, db, tar or sig, not '$expect'" ;;
esac
if [ -n "$want_sha" ] && ! [[ "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
  fetcher_die "--sha256 must be 64 lowercase hex characters, not '$want_sha'"
fi
for c in $clients; do
  client_known "$c" || fetcher_die "unknown client $c" "reproduce: fetchers/fetcher.sh --list"
done
case "$retries" in
  '' | *[!0-9]* | 0) fetcher_die "--retries must be a positive integer, not '$retries'" ;;
esac
case "$timeout_s" in
  '' | *[!0-9]* | 0) fetcher_die "--timeout must be a positive integer, not '$timeout_s'" ;;
esac
case "$connect_s" in
  '' | *[!0-9]* | 0) fetcher_die "--connect must be a positive integer, not '$connect_s'" ;;
esac
case "$max_bytes" in
  '' | *[!0-9]*) fetcher_die "--max-bytes must be a whole number of bytes, not '$max_bytes'" ;;
esac
if [ "$list" -eq 1 ]; then
  for c in $FETCHER_CLIENTS_DEFAULT; do
    if client_available "$c"; then printf '%s\n' "$c"; fi
  done
  exit 0
fi
if [ "$explain" -eq 1 ]; then
  [ "${#positional[@]}" -le 1 ] || fetcher_die "usage: fetchers/fetcher.sh --explain [URL]"
  url="${explain_url:-${positional[0]:-example.invalid}}"
  out=""
else
  [ "${#positional[@]}" -eq 2 ] || fetcher_die "usage: fetchers/fetcher.sh [OPTIONS] URL OUT" \
    "reproduce: fetchers/fetcher.sh --expect db https://repo.archlinuxpower.org/base/powerpc64le/base.db base.db"
  url="${positional[0]}"
  out="${positional[1]}"
  case "$url" in
    https://* | http://*) ;;
    *) fetcher_die "URL is http or https, not '$url'" ;;
  esac
fi

# host_of URL -> the host and port of URL, without any credential
host_of() {
  local h="${1#*://}"
  printf '%s\n' "${h%%/*}"
}

# order_for HOST: the client order for this call. The last client that passed
# for this host is first; the rest keep their default order after it.
order_for() {
  local host="$1" pref="" order="" c first=()
  if [ "$use_cache" -eq 1 ]; then
    # A preference file that does not read is no preference, and the default
    # order is the answer. So the status goes unused on purpose and pref stays
    # empty. A missing file is the common case, and it is not a failure.
    if [ -r "$FETCHER_CACHE/hosts/$host" ]; then
      pref="$(cat "$FETCHER_CACHE/hosts/$host")" || pref=""
    fi
  fi
  if [ -n "$clients" ]; then
    printf '%s\n' "$clients"
    return 0
  fi
  if [ -n "$pref" ] && client_known "$pref"; then
    first+=("$pref")
  fi
  for c in $FETCHER_CLIENTS_DEFAULT; do
    case " ${first[*]-} " in
      *" $c "*) ;;
      *) order="$order $c" ;;
    esac
  done
  printf '%s\n' "${first[*]-}$order" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# summary_line HOST CLIENT STATUS TRIES SECONDS DETAIL
summary_line() {
  [ -n "${FETCHER_SUMMARY:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$FETCHER_SUMMARY"
}

if [ "$explain" -eq 1 ]; then
  eurl="${explain_url:-$url}"
  ehost="$(host_of "$eurl")"
  printf 'url: %s\n' "$eurl"
  printf 'host: %s\n' "$ehost"
  # No preference file means none, and "none" is what the page says. A file
  # that cannot be read is no preference either.
  if [ -r "$FETCHER_CACHE/hosts/$ehost" ]; then
    cached="$(cat "$FETCHER_CACHE/hosts/$ehost")" || cached=""
  fi
  printf 'preferred: %s\n' "${cached:-none}"
  printf 'order: %s\n' "$(order_for "$ehost")"
  for c in $FETCHER_CLIENTS_DEFAULT; do
    if client_available "$c"; then
      printf '%s\tavailable\n' "$c"
    else
      printf '%s\tnot available\n' "$c"
    fi
  done
  exit 0
fi

if [ "${#headers[@]}" -gt 0 ]; then
  HEADERS=("${headers[@]}")
  FETCHER_HEADERS="$(printf '%s\n' "${headers[@]}")"
  export FETCHER_HEADERS
fi

host="$(host_of "$url")"
order="$(order_for "$host")"

# A signature to check with no keyring to check it against would report every
# signature as unsigned, which reads as a bad signature. Refuse it here.
if [ -n "$sig_url" ] && [ "${#keyrings[@]}" -eq 0 ]; then
  fetcher_die "--signature needs at least one --keyring" \
    "reproduce: fetchers/fetcher.sh --signature URL --keyring FILE URL OUT"
fi
if [ -n "$sig_url" ] && [ -z "$sig_of" ]; then
  # Only reachable if the option is parsed without a value, which the parser
  # already refuses. Named rather than left to a later empty fetch.
  fetcher_die "--signature names a body URL, and .sig is appended to it"
fi

# --require-tool puts one client first and refuses to run without it, so a
# caller that depends on a client says so instead of quietly reading through
# the others. The name is checked against the known clients first, so a typo is
# named rather than read as a client that does not exist.
if [ -n "$require" ]; then
  if ! client_known "$require"; then
    fetcher_die "--require-tool '$require' is not a client of this tree" \
      "known: $FETCHER_CLIENTS_DEFAULT"
  fi
  if ! client_available "$require"; then
    fetcher_die "--require-tool '$require' cannot run here" \
      "install it, or drop --require-tool to let another client answer" \
      "reproduce: fetchers/fetcher.sh --list"
  fi
  rest=""
  for c in $order; do
    [ "$c" = "$require" ] || rest="$rest $c"
  done
  order="$require$rest"
fi

[ -n "${order// /}" ] || fetcher_die "no client can run here" "reproduce: fetchers/fetcher.sh --list"

if [ "$quiet" != 1 ]; then
  fetcher_log "$url -> $out, expect=$expect, clients: $order"
fi

work="$(mktemp -d)"
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

attempted=0
absent=0
last_detail=""
for client in $order; do
  if ! client_available "$client"; then
    summary_line "$host" "$client" skipped 0 0 "not available"
    continue
  fi
  attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    attempt=$((attempt + 1))
    attempted=$((attempted + 1))
    body="$work/body"
    log="$work/log"
    rm -f "$body" "$log" "$log.code"
    started="$(date -u +%s)"
    rc=0
    FETCHER_MAX_TIME="$timeout_s" FETCHER_CONNECT_TIMEOUT="$connect_s" FETCHER_MAX_BYTES="$max_bytes" client_run "$client" "$url" "$body" "$log" "$referer" || rc=$?
    took=$(( $(date -u +%s) - started ))
    class=0
    status_class "$log" "$rc" || class=$?
    # The detail is the client's own last words, for the summary file only. A
    # log that cannot be read is no detail, and that is what it prints. The
    # client's own output is already in the log file, so nothing is lost.
    if [ -r "$log" ]; then
      detail="$(tail -c 200 "$log" | tr '\t\n' '  ' | sed 's/  *$//')" || detail=""
    fi
    if [ -s "$log.code" ]; then
      detail="HTTP $(cat "$log.code")${detail:+; $detail}"
    fi
    if [ "$class" -eq 4 ]; then
      summary_line "$host" "$client" absent "$attempt" "$took" "$detail"
      absent=1
      break
    fi
    if [ "$class" -ne 0 ]; then
      summary_line "$host" "$client" failed "$attempt" "$took" "$detail"
      last_detail="$client: $detail"
      if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
      continue
    fi
    if [ "$max_bytes" -gt 0 ]; then
      size="$(wc -c < "$body" | tr -d ' ')"
      if [ "$size" -gt "$max_bytes" ]; then
        summary_line "$host" "$client" bad-body "$attempt" "$took" "body of $size bytes, over --max-bytes $max_bytes"
        last_detail="$client: body of $size bytes, over --max-bytes $max_bytes"
        if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
        continue
      fi
    fi
    why="$(body_validate "$body" "$expect" 2>&1)" || {
      summary_line "$host" "$client" bad-body "$attempt" "$took" "$why"
      last_detail="$client: $why"
      if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
      continue
    }
    if [ -n "$want_magic" ]; then
      # An origin that answers 200 with a different file of the same shape
      # passes every other check, so the first bytes are checked when asked.
      # body_magic reads four bytes, so eight hex digits is the most that can
      # be compared. A shorter value is the first of those digits, so --magic
      # 28b5 is the first byte of a zstd frame and --magic 28b52ffd is all four.
      got_magic="$(body_magic "$body")"
      want_bad=0
      n=${#want_magic}
      if [ "$n" -gt "${#got_magic}" ]; then
        want_bad=1
      elif [ "${got_magic:0:$n}" != "$want_magic" ]; then
        want_bad=1
      fi
      if [ "$want_bad" = 1 ]; then
        summary_line "$host" "$client" bad-body "$attempt" "$took" "first bytes $got_magic, wanted $want_magic"
        last_detail="$client: first bytes $got_magic, wanted $want_magic"
        if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
        continue
      fi
    fi
    if [ -n "$want_sha" ]; then
      got_sha="$(body_sha256 "$body")"
      if [ "$got_sha" != "$want_sha" ]; then
        summary_line "$host" "$client" bad-body "$attempt" "$took" "sha256 $got_sha, wanted $want_sha"
        last_detail="$client: sha256 $got_sha, wanted $want_sha"
        if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
        continue
      fi
    fi
    # The signature is read only once the body itself has passed, and it is
    # checked before the body is moved into place: a caller that asked for a
    # verified file never has an unverified one written.
    #
    # The signature is fetched with the same client, so a host that needs a
    # browser TLS profile needs one for the signature too. A 404 for the
    # signature is a refusal of the whole request, not a pass.
    if [ -n "$sig_url" ]; then
      sig_body="$work/body.sig"
      sig_log="$work/log.sig"
      rm -f "$sig_body" "$sig_log" "$sig_log.code"
      sig_rc=0
      FETCHER_MAX_TIME="$timeout_s" FETCHER_CONNECT_TIMEOUT="$connect_s" \
        client_run "$client" "$sig_url" "$sig_body" "$sig_log" "$referer" || sig_rc=$?
      sig_class=0
      status_class "$sig_log" "$sig_rc" || sig_class=$?
      if [ "$sig_class" -ne 0 ]; then
        summary_line "$host" "$client" bad-body "$attempt" "$took" \
          "the signature at $sig_url was not read (class $sig_class)"
        last_detail="$client: the signature at $sig_url was not read"
        if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
        continue
      fi
      # The signature, then the body: gpgv takes them in that order.
      sig_why="$(sig_verify "$sig_body" "$body" "${keyrings[@]}" 2>&1)" || {
        summary_line "$host" "$client" bad-body "$attempt" "$took" \
          "the signature does not verify: $sig_why"
        last_detail="$client: the signature does not verify: $sig_why"
        if [ "$attempt" -lt "$retries" ]; then retry_sleep "$attempt"; fi
        continue
      }
      rm -f "$sig_body" "$sig_log" "$sig_log.code"
    fi
    summary_line "$host" "$client" ok "$attempt" "$took" "$detail"
    if [ "$use_cache" -eq 1 ]; then
      mkdir -p "$FETCHER_CACHE/hosts"
      # One writer wins: the value is moved into place, never written in place.
      printf '%s\n' "$client" > "$FETCHER_CACHE/hosts/.$host.$$"
      mv -f "$FETCHER_CACHE/hosts/.$host.$$" "$FETCHER_CACHE/hosts/$host"
    fi
    mv -f "$body" "$out"
    if [ "$quiet" != 1 ]; then
      fetcher_log "$client read $url (${took}s)"
    fi
    exit 0
  done
  if [ "$absent" -eq 1 ]; then
    exit 4
  fi
done

if [ "$absent" -eq 1 ]; then
  exit 4
fi
fetcher_warn "no client read $url ($attempted attempt(s))${last_detail:+; last: $last_detail}"
exit 1
