// ghcr-mirror-archlinux-pkgforge, v2: an HTTPS front for the GHCR mirror.
//
//   Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
//
// pacman uses its own downloader with this Server: ParallelDownloads, resume
// and the server error limit apply, and no XferCommand is necessary.
//
// The Worker sends no package bytes. It finds the blob digest of the file in
// the manifest, asks GHCR for that blob, and returns GHCR's redirect to the
// signed blob URL. A GHCR answer that holds the bytes gets 502. pacman checks
// the sha256 of each file against the database and each signature against the
// keyring, as for every mirror.
//
// Paths:
//   /                            this usage text
//   /ARCH/REPO/FILE              FILE from tag latest
//   /ARCH/REPO:latest/FILE       the same
//   /ARCH/REPO:YYYY.MM.DD/FILE   the first snapshot of that UTC day
//   /ARCH/REPO:db-HEX/FILE       the snapshot whose REPO.db has sha256 HEX
//   /ARCH/REPO:files-HEX/FILE    the snapshot whose REPO.files has sha256 HEX
//   /ARCH/REPO@sha256:HEX/FILE   one manifest; its body must hash to HEX
// FILE is REPO.db, REPO.files, a package file, or one of these plus .sig.
// FILE can be percent-encoded. A package file and its .sig always come from
// the package's own tag. Any other tag (staging is one) and any other path
// gets 404 with no subrequest.
//
// Answers: 302 to the signed URL; 404 when the mirror does not hold the file;
// 502 with retry-after: 30 when GHCR fails or answers something unexpected.
// HEAD gets the same answer as GET, with no body.
//
// Cache: the Cache API, one cache per data centre. Every key is on the zone
// host under /__cache/v1, so a change of entry format only needs a new version.
//   loc   one key per (repository, reference, file): the final answer. A hit
//         is the whole request. TTL: until the signed URL's se minus 120 s, at
//         most 600 s, and never past the manifest entry it came from. A signed
//         URL with less than 30 s left before se minus 120 s is not stored.
//   man   one key per (repository, reference): the layers of the manifest.
//         TTL: pins, dated, db- and files- tags 1 year; a package manifest
//         with FILE and FILE.sig 6 h, without the .sig 60 s; latest 30 s;
//         a 404 60 s.
//   blob  one key per (repository, digest): the signed URL, TTL as for loc.
// A package request also fills the loc entry of its .sig (ctx.waitUntil).
//
// Logs: console.error on every 5xx path and on every cache failure. Nothing
// else is logged.
//
// Tests: tests/worker/10-node.sh runs worker/test/*.test.js. tests/worker/live.sh
// checks the deployed Worker when WORKER_LIVE=1.

const REGISTRY = 'https://ghcr.io/v2/pkgforge-dev/mirror-archlinux';
const AUTH = 'Bearer QQ==';
const MANIFEST_TYPE = 'application/vnd.oci.image.manifest.v1+json';
const TITLE = 'org.opencontainers.image.title';
const BLOB_HOST_SUFFIX = '.githubusercontent.com';
const CACHE_PATH = '/__cache/v1';

export const LIMITS = Object.freeze({
  manifestBytes: 65536,
  subrequestMs: 10000,
  retryAfter: '30',
});

// Seconds.
export const TTL = Object.freeze({
  immutable: 31536000,
  packageWithSig: 21600,
  packageNoSig: 60,
  latest: 30,
  missing: 60,
  urlMax: 600,
  urlMin: 30,
  urlMargin: 120,
});

// The URL before the file name is decoded. ARCH and REPO are the GHCR path
// names; a reference is a tag or a pin. FILE is printable ASCII with no /,
// which is all the URL parser leaves.
const PATH_RE =
  /^\/([a-z0-9][a-z0-9_]{0,31})\/([a-z0-9]+(?:-[a-z0-9]+)*)(?::([^/@:]{1,128})|@sha256:([0-9a-f]{64}))?\/([!-.0-~]{1,1024})$/;
const TAG_RE = /^(?:latest|[0-9]{4}\.[0-9]{2}\.[0-9]{2}|(?:db|files)-[0-9a-f]{64})$/;
const IMMUTABLE_TAG_RE = /^(?:[0-9]{4}\.[0-9]{2}\.[0-9]{2}|(?:db|files)-[0-9a-f]{64})$/;
// The file name after decoding: the same character set, at most 255 bytes.
const FILE_RE = /^[!-.0-~]{1,255}$/;
// The same globs as client/pacman-oci: *.pkg.tar.sig | *.pkg.tar.*.sig, and
// *.pkg.tar | *.pkg.tar.*.
const PKGSIG_RE = /\.pkg\.tar(?:\..*)?\.sig$/;
const PKG_RE = /\.pkg\.tar(?:\..*)?$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;

const enc = new TextEncoder();

async function sha256hex(data) {
  const bytes = typeof data === 'string' ? enc.encode(data) : data;
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  let h = '';
  for (const b of d) h += b.toString(16).padStart(2, '0');
  return h;
}

// The tag a package file is stored under. The same mapping as
// `client/pacman-oci --tag`; worker/test/tags.test.js compares the two for
// every name in tests/fixtures/filenames.txt.
export async function tagOf(name) {
  const t = name.replace(/_([pcau])/g, '_u$1').replace(/\+/g, '_p').replace(/:/g, '_c').replace(/@/g, '_a');
  if (/^[a-z0-9@._+:-]+$/.test(name) && /^[a-z0-9_][a-z0-9._-]*$/.test(t) && t.length <= 128) return t;
  return 'fn-' + (await sha256hex(name));
}

function text(status, body, extra = {}) {
  return new Response(body + '\n', {
    status,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...extra,
    },
  });
}

function logError(job, status, error) {
  console.error({ status, path: job.path, error });
}

// Every failure of the Worker or of GHCR is 502 with retry-after, so pacman
// tries the next Server now and this one later.
function fail(job, error) {
  logError(job, 502, error);
  return text(502, error, { 'retry-after': LIMITS.retryAfter });
}

// A body this Worker does not read is cancelled, so that it frees memory.
async function discard(job, res) {
  if (!res || !res.body) return;
  try {
    await res.body.cancel();
  } catch (e) {
    logError(job, 500, `could not cancel an unused body: ${e}`);
  }
}

// At most MAX bytes of the body, or null when it is larger. The
// content-length header is read first, then the bytes themselves.
async function readCapped(job, res, max) {
  const len = res.headers.get('content-length');
  if (len !== null && Number(len) > max) {
    await discard(job, res);
    return null;
  }
  if (!res.body) return new Uint8Array(0);
  const reader = res.body.getReader();
  const chunks = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(n);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.byteLength;
  }
  return out;
}

// One GHCR subrequest: anonymous token, no redirect followed, 10 s deadline.
function ghcr(url, headers = {}) {
  return fetch(url, {
    headers: { authorization: AUTH, ...headers },
    redirect: 'manual',
    signal: AbortSignal.timeout(LIMITS.subrequestMs),
  });
}

//---------------------------------------------------------------------------//
// Cache entries are JSON with an `expires` time in ms. The Cache API also
// drops them at max-age; `expires` lets a derived entry end no later than
// the entry it came from.
//---------------------------------------------------------------------------//
function cacheKey(host, kind, parts) {
  return new Request(`https://${host}${CACHE_PATH}/${kind}/${parts.map(encodeURIComponent).join('/')}`);
}

async function cacheGet(job, key) {
  let res;
  try {
    res = await caches.default.match(key);
  } catch (e) {
    logError(job, 500, `cache match ${key.url} failed: ${e}`);
    return null;
  }
  if (!res) return null;
  let v;
  try {
    v = await res.json();
  } catch (e) {
    logError(job, 500, `cache entry ${key.url} is not JSON: ${e}`);
    return null;
  }
  if (!v || typeof v.expires !== 'number' || v.expires <= Date.now()) return null;
  return v;
}

async function cachePut(job, key, entry, ttl) {
  try {
    await caches.default.put(
      key,
      new Response(JSON.stringify(entry), {
        headers: { 'content-type': 'application/json', 'cache-control': `max-age=${ttl}` },
      }),
    );
  } catch (e) {
    logError(job, 500, `cache put ${key.url} failed: ${e}`);
  }
}

function store(job, key, entry, ttl) {
  job.defer(cachePut(job, key, entry, ttl));
}

function secondsLeft(expires) {
  return Math.floor((expires - Date.now()) / 1000);
}

//---------------------------------------------------------------------------//
// Requests
//---------------------------------------------------------------------------//

// The request the path names, or { refuse } for a 404 with no subrequest.
export async function parsePath(pathname) {
  const p = PATH_RE.exec(pathname);
  if (!p) return { refuse: 'not /ARCH/REPO/FILE, /ARCH/REPO:TAG/FILE or /ARCH/REPO@sha256:HEX/FILE' };
  const [, arch, repo, tag, pin, raw] = p;
  if (tag !== undefined && !TAG_RE.test(tag)) {
    return { refuse: `tag ${tag} is not served: only latest, YYYY.MM.DD, db-HEX, files-HEX and @sha256:HEX` };
  }
  let file;
  try {
    file = decodeURIComponent(raw);
  } catch {
    return { refuse: 'the file name is not valid percent-encoding' };
  }
  if (!FILE_RE.test(file) || file === '.' || file === '..') return { refuse: 'not a file name pacman asks for' };
  const r = { arch, repo, file, repoPath: `${arch}/${repo}`, pin: null, pkgFile: null };
  if (PKGSIG_RE.test(file)) {
    r.kind = 'pkgsig';
    r.pkgFile = file.slice(0, -4);
  } else if (PKG_RE.test(file)) {
    r.kind = 'pkg';
    r.pkgFile = file;
  } else if ([`${repo}.db`, `${repo}.files`, `${repo}.db.sig`, `${repo}.files.sig`].includes(file)) {
    r.kind = 'db';
  } else {
    return { refuse: `${file} is not ${repo}.db, ${repo}.files, a package file or the .sig of one` };
  }
  if (r.pkgFile !== null) {
    r.ref = await tagOf(r.pkgFile);
  } else if (pin !== undefined) {
    r.ref = `sha256:${pin}`;
    r.pin = pin;
  } else {
    r.ref = tag || 'latest';
  }
  r.repoRef = r.ref.startsWith('sha256:') ? `${r.repoPath}@${r.ref}` : `${r.repoPath}:${r.ref}`;
  return r;
}

function manifestTtl(r, layers) {
  if (r.ref.startsWith('sha256:') || IMMUTABLE_TAG_RE.test(r.ref)) return TTL.immutable;
  if (r.pkgFile !== null) {
    const n = (title) => layers.filter(([t]) => t === title).length;
    return n(r.pkgFile) === 1 && n(`${r.pkgFile}.sig`) === 1 ? TTL.packageWithSig : TTL.packageNoSig;
  }
  return TTL.latest;
}

// The manifest entry { found, layers, expires }, or a 502 Response.
async function manifestOf(job, r) {
  const key = cacheKey(job.host, 'man', [r.arch, r.repo, r.ref]);
  const hit = await cacheGet(job, key);
  if (hit) return hit;
  let up;
  try {
    up = await ghcr(`${REGISTRY}/${r.repoPath}/manifests/${r.ref}`, { accept: MANIFEST_TYPE });
  } catch (e) {
    return fail(job, `the GHCR request for the manifest ${r.repoRef} failed: ${e}`);
  }
  if (up.status === 404) {
    await discard(job, up);
    const entry = { found: false, expires: Date.now() + TTL.missing * 1000 };
    store(job, key, entry, TTL.missing);
    return entry;
  }
  if (up.status !== 200) {
    await discard(job, up);
    return fail(job, `GHCR answered ${up.status} for the manifest ${r.repoRef}`);
  }
  let bytes;
  try {
    bytes = await readCapped(job, up, LIMITS.manifestBytes);
  } catch (e) {
    return fail(job, `reading the manifest ${r.repoRef} failed: ${e}`);
  }
  if (bytes === null) return fail(job, `the manifest ${r.repoRef} is over ${LIMITS.manifestBytes} bytes`);
  if (r.pin !== null) {
    const got = await sha256hex(bytes);
    if (got !== r.pin) return fail(job, `the manifest ${r.repoRef} hashes to sha256:${got}`);
  }
  let m;
  try {
    m = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (e) {
    return fail(job, `the manifest ${r.repoRef} is not JSON: ${e}`);
  }
  if (!m || typeof m !== 'object' || !Array.isArray(m.layers)) {
    return fail(job, `the manifest ${r.repoRef} has no layers array`);
  }
  const layers = [];
  for (const l of m.layers) {
    const title = l?.annotations?.[TITLE];
    if (typeof title === 'string') layers.push([title, typeof l.digest === 'string' ? l.digest : null]);
  }
  const ttl = manifestTtl(r, layers);
  const entry = { found: true, layers, expires: Date.now() + ttl * 1000 };
  store(job, key, entry, ttl);
  return entry;
}

// The blob entry { location, expires }, or a 404 or 502 Response. GHCR
// answers a blob request with 307 to a signed URL that ends at `se`.
async function blobOf(job, r, digest) {
  const key = cacheKey(job.host, 'blob', [r.arch, r.repo, digest]);
  const hit = await cacheGet(job, key);
  if (hit) return hit;
  let up;
  try {
    up = await ghcr(`${REGISTRY}/${r.repoPath}/blobs/${digest}`);
  } catch (e) {
    return fail(job, `the GHCR request for the blob ${digest} of ${r.repoPath} failed: ${e}`);
  }
  // The Worker never reads a blob body: it sends redirects only.
  await discard(job, up);
  if (up.status === 404) return text(404, `GHCR has no blob ${digest} in ${r.repoPath}`);
  if (up.status === 200) return fail(job, `GHCR answered 200 with the bytes of ${digest}; this Worker sends redirects only`);
  if (up.status < 300 || up.status > 399) return fail(job, `GHCR answered ${up.status} for the blob ${digest}`);
  const location = up.headers.get('location');
  let u;
  try {
    u = new URL(location);
  } catch {
    return fail(job, `GHCR answered ${up.status} for the blob ${digest} with no valid Location`);
  }
  if (u.protocol !== 'https:' || !u.hostname.endsWith(BLOB_HOST_SUFFIX)) {
    return fail(job, `GHCR redirected the blob ${digest} to ${u.protocol}//${u.hostname}, not https on *${BLOB_HOST_SUFFIX}`);
  }
  const now = Date.now();
  const se = Date.parse(u.searchParams.get('se') || '');
  const expires = Number.isFinite(se) ? Math.min(se - TTL.urlMargin * 1000, now + TTL.urlMax * 1000) : now;
  const entry = { location, expires };
  const ttl = secondsLeft(expires);
  if (ttl >= TTL.urlMin) store(job, key, entry, ttl);
  return entry;
}

function respond(answer) {
  if (answer.status === 302) {
    return new Response(null, { status: 302, headers: { location: answer.location, 'cache-control': 'no-store' } });
  }
  return text(404, answer.message);
}

// Stores the final answer under the loc key until answer.expires. A redirect
// is not stored when its signed URL has less than 30 s left before se minus
// 120 s (urlExpires).
function storeAnswer(job, key, answer, urlExpires) {
  const ttl = secondsLeft(answer.expires);
  if (ttl < 1) return;
  if (answer.status === 302 && secondsLeft(urlExpires) < TTL.urlMin) return;
  store(job, key, answer, ttl);
}

// The answer for FILE from the manifest entry MAN.
async function answerFrom(job, r, man, file) {
  const key = cacheKey(job.host, 'loc', [r.arch, r.repo, r.ref, file]);
  const missing = (message) => {
    const answer = { status: 404, message, expires: Math.min(man.expires, Date.now() + TTL.missing * 1000) };
    storeAnswer(job, key, answer);
    return respond(answer);
  };
  if (!man.found) return missing(`GHCR has no ${r.repoRef}`);
  const hits = man.layers.filter(([t]) => t === file);
  if (hits.length !== 1) return missing(`${r.repoRef} has ${hits.length} layers named ${file}`);
  const digest = hits[0][1];
  if (digest === null || !DIGEST_RE.test(digest)) {
    return fail(job, `the layer ${file} of ${r.repoRef} has no sha256 digest`);
  }
  const blob = await blobOf(job, r, digest);
  if (blob instanceof Response) return blob;
  const answer = { status: 302, location: blob.location, expires: Math.min(blob.expires, man.expires) };
  storeAnswer(job, key, answer, blob.expires);
  return respond(answer);
}

// Fills the loc entry of a package's .sig while the package answer is made
// and sent. pacman asks for the .sig next, from the same Server.
async function prewarmSig(parent, r, man) {
  const pending = [];
  const job = { host: parent.host, path: `${parent.path}.sig`, defer: (p) => pending.push(p) };
  try {
    const file = `${r.file}.sig`;
    const hit = await cacheGet(job, cacheKey(job.host, 'loc', [r.arch, r.repo, r.ref, file]));
    if (!hit) {
      const res = await answerFrom(job, r, man, file);
      await discard(job, res);
    }
  } catch (e) {
    logError(job, 502, `filling the .sig entry failed: ${e && e.stack ? e.stack : e}`);
  }
  await Promise.all(pending);
}

async function route(job, request, ctx) {
  const url = new URL(request.url);
  if (url.pathname === '/') {
    return text(200, usage(url.host), { 'cache-control': 'max-age=3600' });
  }
  const r = await parsePath(url.pathname);
  if (r.refuse) return text(404, r.refuse);
  const hot = await cacheGet(job, cacheKey(job.host, 'loc', [r.arch, r.repo, r.ref, r.file]));
  if (hot) return respond(hot);
  const man = await manifestOf(job, r);
  if (man instanceof Response) return man;
  // The .sig blob is asked for at the same time as the package blob.
  if (r.kind === 'pkg' && man.found) ctx.waitUntil(prewarmSig(job, r, man));
  return answerFrom(job, r, man, r.file);
}

function usage(host) {
  return [
    `Server = https://${host}/$arch/$repo`,
    '',
    'Paths:',
    '  /ARCH/REPO/FILE              FILE from tag latest',
    '  /ARCH/REPO:YYYY.MM.DD/FILE   the first snapshot of that UTC day',
    '  /ARCH/REPO:db-HEX/FILE       the snapshot whose REPO.db has sha256 HEX',
    '  /ARCH/REPO:files-HEX/FILE    the snapshot whose REPO.files has sha256 HEX',
    '  /ARCH/REPO@sha256:HEX/FILE   one manifest, checked against HEX',
    'A package file and its .sig always come from the package\'s own tag.',
    'The answer is a redirect to GitHub\'s blob host. pacman checks every file.',
    '',
    'https://github.com/pkgforge-dev/mirror-archlinux',
  ].join('\n');
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const job = { host: url.host, path: url.pathname, defer: (p) => ctx.waitUntil(p) };
    let res;
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      await discard(job, request);
      res = text(405, 'GET or HEAD only', { allow: 'GET, HEAD' });
    } else {
      try {
        res = await route(job, request, ctx);
      } catch (e) {
        res = fail(job, `internal error: ${e && e.stack ? e.stack : e}`);
      }
    }
    if (request.method === 'HEAD') {
      await discard(job, res);
      return new Response(null, { status: res.status, headers: res.headers });
    }
    return res;
  },
};
