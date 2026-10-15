# chromium

`fetch.mjs` retrieves one URL with a real Chromium build. It is the
client that matters most when an origin refuses a scripted one, because it is
the only stack here that carries all four browser signals at once: the TLS
ClientHello, the HTTP/2 settings and frame order, the header order, and the
cookie jar.

## Call it

```sh
node fetchers/chromium/fetch.mjs URL OUT [REFERER]
```

The body goes to `OUT`. The third argument is a bare referer, not an option:
`fetcher.sh` passes it positionally, so writing `--referer URL` would make
`--referer` the URL. Exit status 0 means the bytes are there; 1 means the
request did not succeed; 2 is a usage error.

| variable | meaning |
| --- | --- |
| `CHROME_WAIT` | seconds to wait for the origin to reach readyState complete, default 20 |
| `CHROME_UA` | a user agent to send. Unset derives one from the running build. |
| `FETCHER_HEADERS` | extra request headers, one `Name: Value` per line |
| `FETCHER_MAX_TIME` | whole-request deadline in seconds |

## What it needs

| need | how |
| --- | --- |
| `playwright` | `npm i playwright` in the directory you run it from |
| the full Chrome-for-Testing build | `npx playwright install chromium` |

`npx playwright install` is not enough on its own: it also installs the headless
shell, and the shell is the build that receives 403.

## Why the build and the user agent are chosen the way they are

Measured on one runner address, one URL, on 2026-10-13:

| build and user agent | status |
| --- | ---: |
| headless shell, its own user agent | 403 |
| full build, its own user agent | 403 |
| full build, a `Chrome/<version>` user agent | 200 |

So the TLS stack alone does not decide it, and neither does the user agent
alone: it takes the full build *and* a user agent that says Chrome.
`fetch.mjs` therefore passes `channel: "chromium"` and builds the user
agent from `browser.version()`, the running build's own version.

That pairing is the point. A `Chrome/...` user agent on a handshake that is not
Chrome's is a weaker signal than an honest one, because the mismatch is the
inconsistency, and an inconsistent identity is easier to separate from a real
browser than a plain one. Deriving the user agent from the build keeps the
client hints and the TLS stack in agreement with it as the build ages.

There is no user agent option. An overridden user agent is how you measure what
the origin does with a build's real identity, and overriding it by default would
make every measurement a statement about a string this file wrote.

## Why the request is issued from the page

The body comes from `fetch()` called inside the page. Playwright's request
context is a separate Node-side HTTP client, and it answers 403 for the same URL
after the page has loaded the origin. So this client never uses
`context.request`.

## Why the body is base64

A page `evaluate()` returns its value over the DevTools protocol as JSON, and a
large database or package is a poor fit for that. The body is moved as base64 in
32 KiB pieces inside the page, which is the one path with no size limit this
client has measured. `texlive-doc` in `base-any` is 3.35 GB upstream, so a
database or package can be large.

## What it does not do

It does not solve a challenge that needs a token from a script, and it does not
change the address the request leaves from. Both of those are outside what a
client controls; see `docs/operations.md` for the fetcher order and what each
layer is for.