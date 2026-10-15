# curl-impersonate

`fetch.sh` retrieves one URL with curl-impersonate: a curl
patched to present the TLS ClientHello, cipher list, extension order and
HTTP/2 settings of a named browser build.

It is the client to reach for first when plain curl is refused, because it costs
one process and a few milliseconds, and it keeps curl's whole option set. Every
deadline in the wrapper is a deadline this repository already uses in
`scripts/lib.sh`, so there is one set of numbers to reason about.

## Call it

```sh
fetchers/curl-impersonate/fetch.sh URL OUT [HEADER...]
```

Each extra argument is one request header, `Name: Value`. There is no
`--referer` option: a referer is a header, so it is passed as one.
`fetcher.sh --referer URL` turns its own option into exactly that.

The body goes to `OUT`. Exit 0 means the bytes are there, 1 that the request did
not succeed, 2 that the call was wrong. curl's own exit status is passed
through when curl ran, so the caller keeps the distinction between a refusal, a
timeout and a bad handshake.

## Where the build comes from

This is a wrapper, not a copy of the upstream tree, and that is a decision.
Vendoring the build means carrying a patch series against a BoringSSL snapshot
and a curl snapshot, and re-doing both on every upstream bump. The upstream
project publishes the built wrappers per release, so the wrapper takes a
directory and uses what is in it:

| variable | meaning |
| --- | --- |
| `CURL_IMPERSONATE_DIR` | the directory holding the `curl_chrome*` wrappers |
| `CURL_IMPERSONATE_BIN` | one wrapper by path, overriding the profile search |
| `FETCHER_CONNECT_TIMEOUT` | connect deadline in seconds |
| `FETCHER_MAX_TIME` | whole-request deadline in seconds |

Those four are what the program reads. The profile is the newest `curl_chrome*`
in the directory and the user agent is the one that wrapper carries, so there is
nothing to set for either.

## How the profile is chosen, and why nothing is pinned

The newest `curl_chrome*` in the install wins, by the number in its name. A
profile is `curl_chrome136` or `curl_chrome136-bin`, so the build is the digits
after the letters; sorting on the digits is what puts 136 ahead of 99, which a
string sort does not.

That is a deliberate choice against a checksum file. A recorded digest of a
built binary goes stale on every upstream release, and a stale digest is either
noise (a job that fails for no reason) or worse, a value that gets updated to
whatever the last fetch returned, which is not a check at all. The profile's
identity here is its name and the build number in it, both readable, and
`IMPR_RESOLVE=0` is the switch for a deployment that wants a fixed profile
instead.

## The user agent, and the one case that matters

With `IMPR_UA` unset the wrapper sends **no** user agent and lets
curl-impersonate present the one belonging to the profile it is impersonating.
That is deliberate. The user agent and the handshake have to agree: a Chrome
user agent on a ClientHello that is not Chrome's is a weaker signal than an
honest one, because the mismatch itself is the inconsistency. Setting `IMPR_UA`
is therefore a measured experiment, and the wrapper says on stderr that it
happened, so a run that set it is never mistaken for one that did not.