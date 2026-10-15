# playwright

`fetch.py` retrieves one URL with invisible_playwright: a
Firefox build with its fingerprint patches compiled into the engine, driven
through the ordinary Playwright API.

It is the only non-Chromium client in `fetchers/`, and that is the whole
reason it is here.

## Call it

```sh
python3 fetchers/playwright/fetch.py URL OUT [REFERER]
```

The third argument is a bare referer, not an option.

| variable | meaning |
| --- | --- |
| `FETCHER_HEADERS` | extra request headers, one `Name: Value` per line |
| `FETCHER_MAX_TIME` | whole-request deadline in seconds |

The engine is the patched Firefox build that `fetchers/playwright/install.sh`
fetched, and it brings its own seed with it. There is no proxy or seed
variable.

## What it needs

Two steps, and they are separate on purpose: the wrapper is a small package and
the engine is not.

```sh
pip install invisible-playwright
python -m invisible_playwright fetch
```

`fetch` downloads the engine, checks it against a seal shipped in the core
package, and caches it. Later runs use the cache with no network call, and
`fetch` re-checks the cached copy every time it runs, so re-running it is
itself the verification.

## Why a second engine is here

The other three clients are Chromium, and two of them share a TLS stack family.
A change that refuses all of them at once is therefore ambiguous: it could be
the browser build, and it could equally be the address the requests leave
from, and those need different answers. A Firefox engine has its own handshake,
its own cipher list, its own extension order and its own user agent, so it
partitions that space. One client that answers 200 while three answer 403 is
evidence about the engine. All four answering 403 is evidence about something
upstream of the client, and the fix is in the egress path, not in this
directory.

## The seed, and why it is logged

Every session's fingerprint comes from a seed: GPU, canvas hash, audio context,
fonts, screen, roughly 400 fields. The seed is readable on the object, so this
wrapper prints it on every run.

That is not decoration. A failure with an unknown seed cannot be replayed, so
it cannot be attributed: the next run draws a different identity and the
question of whether anything changed is unanswerable. With the seed logged, one
run is reproducible, and a comparison between two runs separates a change at
the origin from a change in the fingerprint.

`INVPW_SEED` pins it when a run has to be repeatable on purpose.

## The request is issued from the page

The body comes from `fetch()` called inside the page, for the same measured
reason as the Chromium clients: Playwright's own request client is a separate
Node-side HTTP stack, and an origin that distinguishes the two refuses it where
an in-page request is served. This client never uses `page.request`.

The engine's own documentation makes the same point from the other side, about
proxies: Playwright's request client does not use a browser-level proxy and
sends from the real address. The lesson is the same one whichever engine runs
it.