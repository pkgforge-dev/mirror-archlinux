#!/usr/bin/env node
//
// Retrieve a URL with CloakBrowser (CloakHQ/CloakBrowser): a Chromium build
// whose client profile is set in the engine, driven through the playwright API.
//
//   node fetch.mjs URL OUT [REFERER]
//
// Environment:
//   CLOAK_HEADLESS  1 (default) or 0 to show the window (see the tool's notes
//                   on headed mode)
//   CHROME_WAIT     seconds to wait for the origin (default 20)
//
// Exit status: 0 read, 4 the server says the URL is absent, 1 anything else.
import { launch } from "cloakbrowser";
import fs from "node:fs";

const [, , url, out, referer] = process.argv;
if (!url || !out) {
  console.error("usage: fetch.mjs URL OUT [REFERER]");
  process.exit(2);
}
const origin = new URL(referer || url).origin;
const waitS = Number(process.env.CHROME_WAIT || 20);
const maxMs = Math.max(1000, Number(process.env.FETCHER_MAX_TIME || 300) * 1000);

// Extra request headers, one "Name: Value" per line.
const extra = {};
for (const line of (process.env.FETCHER_HEADERS || "").split("\n")) {
  const i = line.indexOf(":");
  if (i > 0) extra[line.slice(0, i).trim()] = line.slice(i + 1).trim();
}

const browser = await launch({
  headless: process.env.CLOAK_HEADLESS !== "0",
});
process.on("SIGTERM", async () => {
  try {
    await browser.close();
  } catch {
    // already closing
  }
  process.exit(1);
});
let code = 1;
try {
  const page = await browser.newPage();
  try {
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: Math.min(60000, maxMs) });
    const deadline = Date.now() + waitS * 1000;
    while (Date.now() < deadline) {
      const ready = await page.evaluate(() => document.readyState).catch(() => "");
      if (ready === "complete") break;
      await page.waitForTimeout(250);
    }
  } catch (e) {
    console.error(`cloak-browser: origin visit: ${e.message}`);
  }

  // The body is streamed out of the page in bounded pieces to OUT, so a
  // multi-GB file never builds a whole-body buffer or base64 string in the
  // page or in Node. See fetchers/chromium/fetch.mjs for the same shape.
  const maxBytes = Number(process.env.FETCHER_MAX_BYTES || 0);
  const fd = fs.openSync(out, "w");
  await page.exposeBinding("__sink", (_src, b64) => {
    fs.writeSync(fd, Buffer.from(b64, "base64"));
  });
  const r = await page.evaluate(async ({ u, ms, hdrs, cap }) => {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), ms);
    const b64 = (bytes) => {
      let s = "";
      for (let i = 0; i < bytes.length; i += 0x8000) {
        s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      }
      return btoa(s);
    };
    try {
      const resp = await fetch(u, { credentials: "include", cache: "no-store", signal: ac.signal, headers: hdrs });
      if (resp.status !== 200) return { status: resp.status };
      if (!resp.body) return { status: 200, nobody: true };
      const reader = resp.body.getReader();
      const PIECE = 0x100000; // 1 MiB
      let got = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        got += value.length;
        if (cap > 0 && got > cap) { ac.abort(); return { status: 200, tooBig: got }; }
        for (let i = 0; i < value.length; i += PIECE) {
          await window.__sink(b64(value.subarray(i, i + PIECE)));
        }
      }
      return { status: 200, size: got };
    } finally {
      clearTimeout(t);
    }
  }, { u: url, ms: maxMs, hdrs: extra, cap: maxBytes });
  fs.closeSync(fd);

  if (r.status === 404 || r.status === 410) {
    console.error(`cloak-browser: status ${r.status}`);
    fs.rmSync(out, { force: true });
    code = 4;
  } else if (r.status !== 200 || r.tooBig || r.nobody) {
    console.error(r.tooBig ? `cloak-browser: body over cap (${r.tooBig} bytes)` : `cloak-browser: status ${r.status}`);
    fs.rmSync(out, { force: true });
    code = 1;
  } else {
    code = 0;
  }
} finally {
  await browser.close();
}
process.exit(code);
