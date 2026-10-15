# fetchers

Read one URL through the client that can read it, with a fallback order and a
structural check of the body. `plan` and `mirror` read upstream; this directory
is what they use when a plain `curl` does not get an answer.

## The manager

```
fetchers/fetcher.sh [OPTIONS] URL OUT
```

It tries the clients in order and stops at the first body that passes the
check. Exit status: 0 the body is in `OUT`, 4 the server says the URL is
absent (404 or 410), 1 no client read it or the body failed its check.

| option | meaning |
| --- | --- |
| `--client LIST` | clients to try, in order (comma or space separated) |
| `--expect KIND` | `any` (default), `db`, `tar` or `sig` |
| `--sha256 HEX` | the sha256 the body must have, on top of `--expect` |
| `--magic HEX` | the first bytes the body must have, 2 to 8 lowercase hex digits, on top of `--expect` |
| `--signature URL` | read `URL.sig` with the same client and check it with `gpgv` against every `--keyring`; the body is written only once it verifies |
| `--keyring FILE` | a keyring for `--signature`; repeatable, and all of them go to the one `gpgv` call |
| `--require-tool NAME` | try `NAME` first, and refuse to run if it cannot, rather than letting another client answer |
| `--max-bytes N` | refuse a body larger than N bytes (default 0, no cap) |
| `--header H` | an extra request header, `Name: Value`; repeatable |
| `--referer URL` | the `Referer`, and the page the browser clients visit first |
| `--retries N` | attempts per client (default 2) |
| `--timeout SEC` | whole-call deadline of one attempt (default 300) |
| `--connect SEC` | connect deadline (default 20) |
| `--no-cache` | do not read or write the per-host preference |
| `--list` | print the clients that can run here, one per line |
| `--explain [URL]` | print the URL, host, cached preference, order and each client's availability, then exit |
| `--help` | the usage, and exit |
| `--quiet` | no per-attempt line on stderr |

Environment: `FETCHER_CLIENTS` (the order), `FETCHER_CACHE` (the cache root,
`~/.cache/mirror-archlinux/fetcher` by default), `FETCHER_AVAILABLE_TTL`
(seconds an availability answer is kept, default 300), `FETCHER_MAX_BYTES`,
`FETCHER_MAX_TIME`, `FETCHER_CONNECT_TIMEOUT`, `FETCHER_RETRIES`,
`FETCHER_SUMMARY` (a TSV log of every attempt), `FETCHER_QUIET` (`1` for
quiet).

The order is `curl-impersonate curl-impersonate-rv chromium chromium-rv`. Each of
the two browser-profile engines is tried twice: first against the origin, then as
its `-rv` variant through the `api.rv.pkgforge.dev` read-through proxy, which
dials the origin from its own network, so a runner the origin refuses still
reads. `curl-impersonate` is a curl with a browser's TLS and HTTP/2 profile;
`chromium` is a full browser for an origin that needs one. Plain curl is left
out: an origin behind Cloudflare refuses the runner's own address and
fingerprint, so a plain-curl call is a wasted round trip before the profile that
answers. The client that read a host last is kept in `FETCHER_CACHE/hosts/<host>`
and is tried first the next time, so a host that needs the proxy or the browser
pays for finding it once.

A `-rv` variant is not a separate program: it runs its engine (`curl-impersonate`
or `chromium`) unchanged against the rewritten URL `<FETCHER_RV_BASE>/<origin
url>`, so the engine's fingerprint, headers, deadlines and structural checks are
the same as the direct call. `FETCHER_RV_BASE` defaults to
`https://api.rv.pkgforge.dev`.

`--signature` uses `gpgv` and not `gpg`. `gpgv` verifies and does not import,
so a check here cannot change the trust store it verified against. The
signature is the first file on the `gpgv` command line and the body the second;
given the other way round `gpgv` reports "no valid OpenPGP data found" for
every signature. `--signature URL` derives `URL.sig` itself rather than taking
a second URL, so the signature and the body cannot be two different files.

`--magic` exists because every other check can pass on the wrong file: an
origin that answers 200 with a different archive of the same shape is a valid
body under `--expect db`. A zstd database starts `28b52ffd` and a gzip one
`1f8b0800`, so two hex digits already separate the compressions.

A 403 body is not a body: the client that got it is not an answer, and the next
client is tried. A 404 or 410 ends the call with status 4, because another
client would hear the same. `any` also refuses a body that is an HTML
document: an origin that answers 200 with a page has not served the file.

A failed attempt is retried after 2, 4, 8, 16, then 30 s, each with up to
0.9 s of jitter, so two callers that back off from one host do not retry in
lockstep.

An answer to "can this client run here?" is kept for
`FETCHER_AVAILABLE_TTL` seconds (default 300, `0` to ask every time), because a
browser probe starts node or python and costs more than the fetch it guards.
`--no-cache` asks again and ignores the per-host preference.

`--header` and `--referer` reach every client: curl and curl-impersonate get
them as command-line options, and the browser clients read them from
`FETCHER_HEADERS` (one `Name: Value` per line) and their third argument.

Every client is wrapped in a hard stop of `--timeout` + 5 s, and the browser
clients get the same value as a `page.goto` timeout and an abort on the in-page
`fetch()`, so a browser that hangs ends within the deadline curl has. The
browser clients close on `SIGTERM`, so a stopped call leaves no Chromium
behind.

A name that no build defines is refused before any request. The per-host
preference is moved into place, so two callers that read the same host at once
do not half-write it.

Each engine is one program; a `-rv` variant runs the same program against the
proxied URL:

| client | program |
| --- | --- |
| `curl` | `curl` (a known client, but not in the default order) |
| `curl-impersonate` | `curl-impersonate/fetch.sh` |
| `curl-impersonate-rv` | `curl-impersonate/fetch.sh`, URL through the proxy |
| `chromium` | `node chromium/fetch.mjs` |
| `chromium-rv` | `node chromium/fetch.mjs`, URL through the proxy |
| `cloak-browser` | `node cloak-browser/fetch.mjs` |
| `playwright` | `playwright/venv/bin/python playwright/fetch.py` |

## The clients

| client | what it is | install |
| --- | --- | --- |
| `curl-impersonate` | [lexiforest/curl-impersonate](https://github.com/lexiforest/curl-impersonate), a maintained curl that sends one browser's TLS and HTTP/2 profile; tried first | `fetchers/curl-impersonate/install.sh` |
| `curl-impersonate-rv` | the same engine through the `api.rv.pkgforge.dev` read-through proxy, which dials the origin from its own network, so a runner the origin refuses still reads | (comes with `curl-impersonate`) |
| `chromium` | the playwright package and its full Chrome-for-Testing build; the request is an in-page `fetch()`, so it uses Chromium's own network stack and cookies | `fetchers/chromium/install.sh` |
| `chromium-rv` | the Chromium engine through the same read-through proxy | (comes with `chromium`) |
| `cloak-browser` | [CloakHQ/CloakBrowser](https://github.com/CloakHQ/CloakBrowser), a Chromium build with its client profile set in the engine; known, but not in the default order | `fetchers/cloak-browser/install.sh` |
| `playwright` | [feder-cr/invisible_playwright](https://github.com/feder-cr/invisible_playwright); known, but not in the default order | `fetchers/playwright/install.sh` |
| `curl` | the system curl; a known client for `--client curl`, but left out of the default order | system |

`fetchers/install.sh [--check] [CLIENT...]` runs the installers. With no
argument it installs every client. `--check` installs nothing: it reports each
asked client's availability, with a fresh probe, and exits 0 only when every
one of them is available. The installers write into this tree, and
`fetchers/.gitignore` keeps their build products out of the repository.

A client is available when its `available` script exits 0. `available` for
`chromium`, `cloak-browser` and `playwright` also checks that node, the
package and the browser build are present, so `--list` reflects the host.

## Self-check

```
fetchers/self-check.sh [--strict] [URL]
```

On a runner or a workstation after `fetchers/install.sh`: it prints the host,
the client order and each client's availability, reads the URL through the
manager, and then through each available client on its own. `--strict` exits
non-zero if any available client did not read the URL; without it the
manager's answer decides. `URL` defaults to the ArchPOWER powerpc64le database
signature (119 bytes), and `--expect` follows the suffix.

## On a build runner

```
fetchers/ci.sh [--with-deps] [CLIENT...]
```

Installs the clients and then checks them: with no argument `curl-impersonate`
and `chromium`. Every client asked for must be available after its install, and
then `self-check.sh --strict` reads a small URL through each available client.
`--with-deps` passes `--with-deps` to the browser installer for the system
packages the browser needs. Set `FETCHER_SELFCHECK_URL` to check another URL.
It exits 0 only when all of that happened.

## Drift

```
fetchers/drift.sh [--json | --env] [--key NAME] [--ttl SECONDS] [--force]
```

Every version comes from the release the tool's own project publishes at the
time it is read; nothing is pinned by hand. Values are kept in
`FETCHER_CACHE/drift.json` for 24 h. A lookup that fails keeps the cached
value rather than moving backwards. The keys are `curl-impersonate`,
`cloak-browser`, `invisible-playwright` and `playwright`; the installers read
the tag they need from here.

## Use in a workflow

`scripts/lib.sh` reads every upstream URL through `fetch_upstream`. Set
`MIRROR_FETCHER` to `fetchers/fetcher.sh` and every read goes through the
manager instead of curl, with no other change:

```yaml
- run: |
    fetchers/ci.sh --with-deps curl-impersonate chromium   # install and check
    export MIRROR_FETCHER="$PWD/fetchers/fetcher.sh"
    scripts/plan "$RUNNER_TEMP/plan"
```

`ci.sh` fails the step if a client it was asked for did not install or cannot
read the check URL, so a runner that would fall back to curl alone tells you
before the long run. `fetchers/install.sh chromium` installs the browser on its
own when no check is wanted. Use `fetchers/install.sh --check` to ask what is
usable here without installing anything.

When the workflow already has the clients and only wants one URL, these are the
tools to call:

```sh
fetchers/install.sh --check                     # what is usable here
fetchers/fetcher.sh --expect db "$URL" "$OUT"   # read it with the fallback
fetchers/drift.sh --env                          # the tool versions, for a log
```

## Measured

- 2026-10-15, residential network: a direct request reads the files — `curl`
  reads `base.db` of all three ArchPOWER arches and of `base-any` with one call
  each and passes the `db` check, and the four `.db.sig` pass the `sig` check. So
  the files are known good; what a GitHub runner meets is not a bad file but the
  origin refusing the runner's own address, which the order answers with
  `curl-impersonate` against the origin and then through the `api.rv.pkgforge.dev`
  proxy.
- The unit tests (`tests/unit/80-fetchers.sh`) run the manager against a faked
  `curl-impersonate`, node and venv-python and a `curl` stand-in, so client
  selection, the fallback from an engine to its `-rv` proxy variant, the
  structural, sha256 and size checks, the deadline, the dispatch of each client
  to its own program, the `-rv` URL rewrite, the availability cache and the
  version resolver are covered without a network or a browser. A browser client
  itself is not started by the tests.
