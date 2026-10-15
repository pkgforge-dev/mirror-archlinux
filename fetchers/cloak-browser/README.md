# cloak-browser

`fetch.mjs` retrieves one URL with CloakBrowser: a Chromium build whose
fingerprint patches are compiled into the binary, driven through the Playwright
API.

It sits beside `fetchers/chromium/` rather than replacing it. Same engine
family, different patching strategy, and the difference is the point.

## Call it

```sh
node fetchers/cloak-browser/fetch.mjs URL OUT [REFERER]
```

The third argument is a bare referer, not an option, for the same reason as in
`fetchers/chromium/`: `fetcher.sh` passes it positionally.

| variable | meaning |
| --- | --- |
| `CLOAK_HEADLESS` | `0` runs with a display |
| `CHROME_WAIT` | seconds to wait for the page to settle, default 20 |
| `FETCHER_HEADERS` | extra request headers, one `Name: Value` per line |
| `FETCHER_MAX_TIME` | whole-request deadline in seconds |

`CLOAK_LICENSE_KEY` is not read by this program. The engine build it uses is
the one `fetchers/cloak-browser/install.sh` put in place, and that installer is
where a licence, if one is needed, is set.

## What it needs

```sh
npm install cloakbrowser playwright-core
```

No `playwright install chromium`: this project downloads its own engine, and
installing a second Chromium is 200 MB for nothing. The wrapper verifies the
download against a pinned signature over the published checksums before it
extracts it.

## Why this is a separate client

Three levels of patching exist, and only the third one is in this directory:

| level | how it patches | what it costs |
| --- | --- | --- |
| flags | launch options | the values disagree with what the engine does |
| injection | JavaScript into the page | the injected code must imitate a real browser, and it is itself the tell |
| engine | C++ source, compiled in | nothing injected, so nothing to find |

An origin that reads the user agent refuses a stock headless build outright.
After that, the usual next layer is a JavaScript-injection patch, and what
detects those is most often the patch: it has to stay coherent with a real
browser, every Chrome release moves the surface it imitates, and so it breaks
on update rather than on a change at the origin. A patch compiled into the
engine has no injected surface.

## The user agent is not set

`launchContext` is called without a user agent, and that is deliberate. The
engine's own user agent belongs with its own handshake; a Chrome string on a
fingerprint that is not Chrome's is a weaker signal than an honest one, because
the mismatch is the inconsistency. Setting one here would make every run a
statement about a string this file wrote.

## The request is issued from the page

The body comes from `fetch()` called inside the page. Playwright's request
context is a separate HTTP stack, and it is refused where an in-page request is
served. The engine's own documentation makes the same point from the proxy
side: Playwright's request client does not use a browser-level proxy and sends
from the real address. Same lesson, different side.

## What it does not do

It does not solve a challenge that issues a token to a script, and it does not
change the address a request leaves from. Both sit outside what a client can
change, and `docs/operations.md` says which layer each is for.