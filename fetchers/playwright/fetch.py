#!/usr/bin/env python3
"""Retrieve a URL with invisible_playwright (feder-cr/invisible_playwright).

    python fetch.py URL OUT [REFERER]

The request runs in the page, so it uses the patched engine's own network
stack and client profile. Exit status: 0 read, 4 the server says the URL is
absent, 1 anything else.
"""
import base64
import os
import sys
from urllib.parse import urlparse

from invisible_playwright import InvisiblePlaywright

FETCH = """async ({u, ms, hdrs}) => {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), ms);
  try {
    const resp = await fetch(u, { credentials: "include", cache: "no-store", signal: ac.signal, headers: hdrs });
    if (resp.status !== 200) return { status: resp.status };
    const buf = new Uint8Array(await resp.arrayBuffer());
    let s = "";
    for (let i = 0; i < buf.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    }
    return { status: 200, b64: btoa(s) };
  } finally {
    clearTimeout(t);
  }
}"""


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: fetch.py URL OUT [REFERER]\n")
        return 2
    url, out = sys.argv[1], sys.argv[2]
    origin = "{u.scheme}://{u.netloc}".format(u=urlparse(url))
    max_ms = max(1000, int(os.environ.get("FETCHER_MAX_TIME", "300")) * 1000)
    extra = {}
    for line in os.environ.get("FETCHER_HEADERS", "").split("\n"):
        if ":" in line:
            name, value = line.split(":", 1)
            extra[name.strip()] = value.strip()
    with InvisiblePlaywright() as browser:
        page = browser.new_page()
        try:
            page.goto(origin, wait_until="domcontentloaded", timeout=min(60000, max_ms))
        except Exception as exc:  # noqa: BLE001 - the origin visit is a warm-up
            sys.stderr.write("playwright: origin visit: %s\n" % exc)
        r = page.evaluate(FETCH, {"u": url, "ms": max_ms, "hdrs": extra})
    status = r.get("status")
    if status in (404, 410):
        sys.stderr.write("playwright: status %s\n" % status)
        return 4
    if status != 200 or not r.get("b64"):
        sys.stderr.write("playwright: status %s\n" % status)
        return 1
    with open(out, "wb") as fh:
        fh.write(base64.b64decode(r["b64"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
