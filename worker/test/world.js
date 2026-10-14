// A test world for worker/src/index.js: a GHCR stand-in behind a mock fetch,
// a Cache API stub with a clock, a ctx that collects waitUntil promises, and
// a capture of console.error. No network.
//
//   const w = world();            // installs the globals
//   const res = await w.get('/x86_64/core/core.db');
//   w.close();                    // restores them
//
// Every response body that the stand-in returns is tracked. w.unusedBodies()
// lists the ones the Worker neither read nor cancelled.

import worker from '../src/index.js';

export const HOST = 'ghcr.mirror.example.test';
export const REGISTRY = 'https://ghcr.io/v2/pkgforge-dev/mirror-archlinux';
export const BLOB_HOST = 'https://pkg-containers.githubusercontent.com';
export const T0 = Date.parse('2026-10-14T03:00:00Z');
export const MANIFEST_TYPE = 'application/vnd.oci.image.manifest.v1+json';

export const hex = (c) => c.repeat(64);
export const digest = (c) => `sha256:${hex(c)}`;

export function manifestJson(layers, extra = {}) {
  return JSON.stringify({
    schemaVersion: 2,
    mediaType: MANIFEST_TYPE,
    config: { mediaType: 'application/vnd.oci.empty.v1+json', digest: digest('4'), size: 2 },
    layers: layers.map(([title, d, size = 100]) => ({
      mediaType: 'application/octet-stream',
      digest: d,
      size,
      annotations: { 'org.opencontainers.image.title': title },
    })),
    ...extra,
  });
}

export async function sha256hex(s) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

// A body that records whether it was read or cancelled. highWaterMark 0: the
// source is pulled only when a reader asks for data.
function trackedBody(bytes, track, chunk = 0) {
  let off = 0;
  return new ReadableStream(
    {
      pull(c) {
        track.read = true;
        if (off >= bytes.byteLength) {
          c.close();
          return;
        }
        const end = chunk > 0 ? Math.min(off + chunk, bytes.byteLength) : bytes.byteLength;
        c.enqueue(bytes.slice(off, end));
        off = end;
        if (off >= bytes.byteLength) c.close();
      },
      cancel() {
        track.cancelled = true;
      },
    },
    { highWaterMark: 0 },
  );
}

class CacheStub {
  constructor(clock) {
    this.clock = clock;
    this.entries = new Map();
    this.matches = 0;
    this.puts = [];
    this.failMatch = false;
    this.failPut = false;
  }

  async match(key) {
    this.matches += 1;
    if (this.failMatch) throw new Error('cache stub: match failed');
    const url = typeof key === 'string' ? key : key.url;
    const e = this.entries.get(url);
    if (!e) return undefined;
    if (e.until <= this.clock.now) {
      this.entries.delete(url);
      return undefined;
    }
    return new Response(e.body, { status: e.status, headers: e.headers });
  }

  async put(key, res) {
    if (this.failPut) throw new Error('cache stub: put failed');
    if (typeof key === 'string' || key.method !== 'GET') throw new TypeError('cache stub: the key must be a GET Request');
    if (res.status === 206) throw new TypeError('cache stub: 206 cannot be stored');
    const cc = res.headers.get('cache-control') || '';
    const m = /(?:^|,)\s*max-age=(\d+)/.exec(cc);
    if (!m || /no-store/.test(cc)) throw new TypeError(`cache stub: no max-age in "${cc}"`);
    const ttl = Number(m[1]);
    const body = await res.text();
    this.entries.set(key.url, { body, status: res.status, headers: [...res.headers], until: this.clock.now + ttl * 1000 });
    this.puts.push({ url: key.url, ttl, body: JSON.parse(body) });
  }

  // The stored entries whose key path starts with /__cache/v1/<kind>/.
  ofKind(kind) {
    return this.puts.filter((p) => new URL(p.url).pathname.startsWith(`/__cache/v1/${kind}/`));
  }
}

export function world() {
  const clock = { now: T0 };
  const cache = new CacheStub(clock);
  const saved = {
    fetch: globalThis.fetch,
    caches: Object.getOwnPropertyDescriptor(globalThis, 'caches'),
    now: Date.now,
    error: console.error,
    timeout: AbortSignal.timeout,
  };
  const w = {
    clock,
    cache,
    requests: [],
    errors: [],
    bodies: [],
    timeouts: [],
    // GHCR state: manifests by "arch/repo:ref", blobs by "arch/repo@digest".
    manifests: new Map(),
    blobs: new Map(),
    // A function (url, init) => Response | Promise, tried before the maps.
    intercept: null,
    // Seconds from the request time to the signed URL's se.
    seAfter: 400,
  };

  w.response = (status, body = '', headers = {}, opts = {}) => {
    const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : body;
    const track = { status, read: false, cancelled: false, url: opts.url || '' };
    w.bodies.push(track);
    if ([101, 204, 205, 304].includes(status)) {
      // A null body status: there is nothing to read or cancel.
      track.read = true;
      return new Response(null, { status, headers });
    }
    return new Response(trackedBody(bytes, track, opts.chunk || 0), { status, headers });
  };

  w.manifest = (repoRef, layers, extra) => {
    const body = manifestJson(layers, extra);
    w.manifests.set(repoRef, body);
    return body;
  };

  w.signedUrl = (d) => {
    const se = new Date(clock.now + w.seAfter * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    return `${BLOB_HOST}/ghcrblobs10/blobs/${d}?se=${encodeURIComponent(se)}&sig=abc%2Bdef%3D&sp=r`;
  };

  globalThis.fetch = async (url, init = {}) => {
    w.requests.push({ url: String(url), init });
    if (w.intercept) {
      const r = await w.intercept(String(url), init);
      if (r !== undefined) return r;
    }
    const u = new URL(String(url));
    if (!u.href.startsWith(`${REGISTRY}/`)) throw new Error(`test world: unexpected fetch ${url}`);
    const rest = u.pathname.slice(new URL(REGISTRY).pathname.length + 1);
    let m = /^(.+)\/manifests\/(.+)$/.exec(rest);
    if (m) {
      const body = w.manifests.get(`${m[1]}:${decodeURIComponent(m[2])}`);
      if (body === undefined) {
        return w.response(404, '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}', {
          'content-type': 'application/json',
        }, { url });
      }
      return w.response(200, body, { 'content-type': MANIFEST_TYPE, 'content-length': String(new TextEncoder().encode(body).byteLength) }, { url });
    }
    m = /^(.+)\/blobs\/(sha256:[0-9a-f]{64})$/.exec(rest);
    if (m) {
      const b = w.blobs.get(`${m[1]}@${m[2]}`);
      if (b === undefined) return w.response(404, '{"errors":[{"code":"BLOB_UNKNOWN"}]}', {}, { url });
      if (typeof b === 'function') return b(url, init);
      return w.response(307, '', { location: b === true ? w.signedUrl(m[2]) : b, 'content-length': '0' }, { url });
    }
    throw new Error(`test world: unexpected GHCR path ${rest}`);
  };
  Object.defineProperty(globalThis, 'caches', { value: { default: cache }, configurable: true, writable: true });
  Date.now = () => clock.now;
  console.error = (...args) => {
    w.errors.push(args);
  };
  AbortSignal.timeout = (ms) => {
    w.timeouts.push(ms);
    return saved.timeout.call(AbortSignal, ms);
  };

  // GET (or METHOD) PATH; waits for every waitUntil promise before it returns.
  w.request = async (path, method = 'GET', headers = {}) => {
    const pending = [];
    const ctx = {
      waitUntil: (p) => pending.push(p),
      passThroughOnException: () => {
        throw new Error('test world: passThroughOnException is not used');
      },
    };
    const req = new Request(`https://${HOST}${path}`, { method, headers });
    const res = await worker.fetch(req, {}, ctx);
    while (pending.length > 0) await Promise.all(pending.splice(0));
    return res;
  };
  w.get = (path) => w.request(path, 'GET');
  w.head = (path) => w.request(path, 'HEAD');

  // The requests the Worker made from index FROM on.
  w.since = (from) => w.requests.slice(from);

  w.unusedBodies = () => w.bodies.filter((b) => !b.read && !b.cancelled);

  w.advance = (seconds) => {
    clock.now += seconds * 1000;
  };

  w.close = () => {
    globalThis.fetch = saved.fetch;
    if (saved.caches) Object.defineProperty(globalThis, 'caches', saved.caches);
    else delete globalThis.caches;
    Date.now = saved.now;
    console.error = saved.error;
    AbortSignal.timeout = saved.timeout;
  };
  return w;
}

// A world with x86_64/core: latest with core.db and core.files, three
// packages with their .sig layers, one package with no .sig layer, and a
// signed URL for every blob.
export const PKG = 'zlib-1:1.3.2-3-x86_64.pkg.tar.zst';
export const PKG_TAG = 'zlib-1_c1.3.2-3-x86_64.pkg.tar.zst';
export const PLUS = 'gcc-libs-15.2.1+r22+gc4e96a094636-1-x86_64.pkg.tar.zst';
export const PLUS_TAG = 'gcc-libs-15.2.1_pr22_pgc4e96a094636-1-x86_64.pkg.tar.zst';
export const NOSIG = 'nosig-1-1-any.pkg.tar.zst';
export const UPPER = 'lshw-B.02.20-3-x86_64.pkg.tar.zst';

export const D = {
  db: digest('a'),
  files: digest('b'),
  pkg: digest('c'),
  pkgSig: digest('d'),
  plus: digest('e'),
  plusSig: digest('f'),
  nosig: digest('1'),
  upper: digest('2'),
  upperSig: digest('3'),
};

export async function seeded() {
  const w = world();
  const db = [
    ['core.db', D.db],
    ['core.files', D.files],
  ];
  w.manifest('x86_64/core:latest', db);
  w.manifest(`x86_64/core:${PKG_TAG}`, [
    [PKG, D.pkg],
    [`${PKG}.sig`, D.pkgSig],
  ]);
  w.manifest(`x86_64/core:${PLUS_TAG}`, [
    [PLUS, D.plus],
    [`${PLUS}.sig`, D.plusSig],
  ]);
  w.manifest('x86_64/core:nosig-1-1-any.pkg.tar.zst', [[NOSIG, D.nosig]]);
  w.manifest(`x86_64/core:fn-${await sha256hex(UPPER)}`, [
    [UPPER, D.upper],
    [`${UPPER}.sig`, D.upperSig],
  ]);
  for (const d of Object.values(D)) w.blobs.set(`x86_64/core@${d}`, true);
  return w;
}

// Runs FN in a seeded world and restores the globals after it. Every test
// also checks that no GHCR body was left unread and uncancelled.
export async function inWorld(fn) {
  const w = await seeded();
  try {
    await fn(w);
    const unused = w.unusedBodies();
    if (unused.length > 0) {
      throw new Error(`GHCR bodies neither read nor cancelled: ${JSON.stringify(unused)}`);
    }
  } finally {
    w.close();
  }
}
