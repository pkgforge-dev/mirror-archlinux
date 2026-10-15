// ghcr-mirror-archlinux-pkgforge, v2: an HTTPS front for the GHCR mirror.
//
//   Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
//
// pacman uses its own downloader with this Server: ParallelDownloads, resume
// and the server error limit apply, and no XferCommand is necessary.
//
// The Worker sends no package bytes. It finds the blob digest of the file in
// the manifest, asks GHCR for that blob, and returns GHCR's redirect to the
// signed blob URL. A GHCR answer that holds the bytes gets 502, and so does a
// redirect that is not https. A redirect to a host outside
// *.githubusercontent.com is sent with x-mirror-blob-host: unexpected. pacman
// checks the sha256 of each file against the database and each signature
// against the keyring, as for every mirror.
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
// HEAD gets the same answer as GET, with no body. Every 302 and 404 has
// x-mirror-cache: hit (from its loc entry), miss (stored now) or nostore.
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
//   token one key per repository: a pull token, used only after GHCR refused
//         Bearer QQ==. TTL: expires_in less 30 s, at most 300 s; 240 s with
//         no expires_in.
// A package request also fills the loc entry of its .sig (ctx.waitUntil).
//
// GHCR token: every subrequest sends the dummy token Bearer QQ==. When GHCR
// answers it with 401 or 403, the Worker reads the Bearer challenge, asks its
// realm (https on ghcr.io only) for a pull token, and sends the subrequest
// again with it. From then on the isolate sends the kept token first.
//
// Logs: console.error on every 5xx path and on every cache failure, and once
// per isolate when GHCR refuses Bearer QQ==, redirects a blob to a host
// outside *.githubusercontent.com, or signs a URL with no usable se. Nothing
// else is logged.
//
// Tests: tests/worker/10-node.sh runs worker/test/*.test.js. tests/worker/live.sh
// checks the deployed Worker when WORKER_LIVE=1.

const REGISTRY_HOST = 'ghcr.io';
const NAMESPACE = 'pkgforge-dev/mirror-archlinux';
const REGISTRY = `https://${REGISTRY_HOST}/v2/${NAMESPACE}`;
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
  tokenMax: 300,
  tokenMargin: 30,
  tokenDefault: 240,
});

// What one isolate keeps between its requests. The runtime starts and ends
// isolates as it likes, so each value is a shortcut and never the only copy.
//   dummyRefused  GHCR refused Bearer QQ== in this isolate
//   tokens        repository path -> { token, expires }, as in the cache
//   said          the keys of the messages logged once per isolate
const isolate = { dummyRefused: false, tokens: new Map(), said: new Set() };

// The state of a new isolate. The tests call it before each test.
export function resetIsolate() {
  isolate.dummyRefused = false;
  isolate.tokens.clear();
  isolate.said.clear();
}

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

// console.error once per isolate for each KEY.
function logOnce(job, key, status, error) {
  if (isolate.said.has(key)) return;
  isolate.said.add(key);
  logError(job, status, error);
}

// One subrequest: AUTHORIZATION (none when null), no redirect followed, 10 s
// deadline.
function send(url, authorization, headers = {}) {
  const h = { ...headers };
  if (authorization !== null) h.authorization = authorization;
  return fetch(url, {
    headers: h,
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
// GHCR subrequests. Every public package accepts the dummy token Bearer QQ==,
// which saves the token request. When GHCR refuses it (401 or 403), the
// Worker uses the registry's own anonymous flow: the Bearer challenge names a
// realm, which must be https on ghcr.io, and the realm gives a pull token for
// the repository. The token is kept in this isolate and in the cache, for
// expires_in less 30 s, at most 300 s (240 s with no expires_in), and each
// later subrequest for the repository sends it first. A subrequest makes at
// most one token request.
//---------------------------------------------------------------------------//

// The realm of a Bearer challenge, or null.
function bearerRealm(www) {
  if (typeof www !== 'string' || !/^\s*bearer\s/i.test(www)) return null;
  const m = /\brealm="([^"]*)"/i.exec(www);
  return m ? m[1] : null;
}

// A pull token for REPOPATH that this isolate or the cache holds, or null.
async function tokenKept(job, repoPath) {
  const mem = isolate.tokens.get(repoPath);
  if (mem && mem.expires > Date.now()) return mem.token;
  const hit = await cacheGet(job, cacheKey(job.host, 'token', [repoPath]));
  if (!hit || typeof hit.token !== 'string' || hit.token === '') return null;
  isolate.tokens.set(repoPath, hit);
  return hit.token;
}

// A new pull token for REPOPATH from the realm of GHCR's Bearer challenge.
// REFUSED is the status of the answer that refused USED (the dummy token or
// the kept token), and WWW its www-authenticate header. Throws with the
// reason when there is no token.
async function tokenNew(job, repoPath, url, what, used, refused, www) {
  const why = `GHCR answered ${refused} for ${what} to ${used}`;
  let realm = bearerRealm(www);
  if (realm === null && refused === 403) {
    // GHCR answers 403 with no challenge; a request with no authorization
    // gets 401 with one.
    const bare = await send(url, null);
    realm = bearerRealm(bare.headers.get('www-authenticate'));
    await discard(job, bare);
  }
  if (realm === null) throw new Error(`${why}, and sent no Bearer challenge`);
  let u;
  try {
    u = new URL(realm);
  } catch {
    throw new Error(`${why}, and its Bearer challenge names the realm ${realm}, which is not a URL`);
  }
  if (u.protocol !== 'https:' || u.hostname !== REGISTRY_HOST) {
    throw new Error(`${why}, and its Bearer challenge names the realm ${realm}, not https on ${REGISTRY_HOST}`);
  }
  u.searchParams.set('service', REGISTRY_HOST);
  u.searchParams.set('scope', `repository:${NAMESPACE}/${repoPath}:pull`);
  const res = await send(u.href, null);
  if (res.status !== 200) {
    await discard(job, res);
    throw new Error(`${why}, and the token request to ${u.origin}${u.pathname} answered ${res.status}`);
  }
  const bytes = await readCapped(job, res, LIMITS.manifestBytes);
  if (bytes === null) throw new Error(`${why}, and the token answer is over ${LIMITS.manifestBytes} bytes`);
  let body;
  try {
    body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (e) {
    throw new Error(`${why}, and the token answer is not JSON: ${e}`);
  }
  const token = [body?.token, body?.access_token].find((t) => typeof t === 'string' && t !== '');
  if (token === undefined) throw new Error(`${why}, and the token answer holds no token`);
  const ttl = Number.isFinite(body.expires_in) ? Math.min(body.expires_in - TTL.tokenMargin, TTL.tokenMax) : TTL.tokenDefault;
  if (ttl >= 1) {
    const entry = { token, expires: Date.now() + ttl * 1000 };
    isolate.tokens.set(repoPath, entry);
    store(job, cacheKey(job.host, 'token', [repoPath]), entry, ttl);
  }
  return token;
}

// One GHCR subrequest for REPOPATH, with the kept token once GHCR refused the
// dummy token in this isolate, else with the dummy token. A 401 or 403 is
// asked again once with a pull token: the kept one, else a new one. WHAT
// names the object in messages. Throws when no token can be had.
async function ghcr(job, repoPath, url, what, headers = {}) {
  const kept = isolate.dummyRefused ? await tokenKept(job, repoPath) : null;
  const first = await send(url, kept === null ? AUTH : `Bearer ${kept}`, headers);
  const refused = first.status;
  if (refused !== 401 && refused !== 403) return first;
  const www = first.headers.get('www-authenticate');
  await discard(job, first);
  let token = null;
  if (kept === null) {
    isolate.dummyRefused = true;
    logOnce(job, 'dummy', refused, `GHCR refused ${AUTH}; the anonymous token flow is used`);
    token = await tokenKept(job, repoPath);
  } else {
    // GHCR refused the kept token: it is not used again.
    isolate.tokens.delete(repoPath);
  }
  if (token === null) {
    token = await tokenNew(job, repoPath, url, what, kept === null ? AUTH : 'the kept token', refused, www);
  }
  return send(url, `Bearer ${token}`, headers);
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
    up = await ghcr(job, r.repoPath, `${REGISTRY}/${r.repoPath}/manifests/${r.ref}`, `the manifest ${r.repoRef}`, {
      accept: MANIFEST_TYPE,
    });
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
    up = await ghcr(job, r.repoPath, `${REGISTRY}/${r.repoPath}/blobs/${digest}`, `the blob ${digest}`);
  } catch (e) {
    return fail(job, `the GHCR request for the blob ${digest} of ${r.repoPath} failed: ${e}`);
  }
  // The Worker never reads a blob body: it sends redirects only.
  await discard(job, up);
  if (up.status === 404) return text(404, `GHCR has no blob ${digest} in ${r.repoPath}`, { 'x-mirror-cache': 'nostore' });
  if (up.status === 200) {
    return fail(job, `GHCR now answers blobs with 200; this Worker sends redirects only (${digest} of ${r.repoPath})`);
  }
  if (up.status < 300 || up.status > 399) return fail(job, `GHCR answered ${up.status} for the blob ${digest}`);
  const location = up.headers.get('location');
  let u;
  try {
    u = new URL(location);
  } catch {
    return fail(job, `GHCR answered ${up.status} for the blob ${digest} with no valid Location`);
  }
  if (u.protocol !== 'https:') {
    return fail(job, `GHCR redirected the blob ${digest} to ${u.protocol}//${u.hostname}, not https`);
  }
  // GitHub moves its download hosts. pacman checks every sha256 and every
  // signature, and the Location comes from GHCR over TLS, so a host outside
  // *.githubusercontent.com is still served, marked and logged.
  const unexpected = !u.hostname.endsWith(BLOB_HOST_SUFFIX);
  if (unexpected) {
    logOnce(job, 'blob-host', 302, `GHCR redirected the blob ${digest} to ${u.hostname}, not to a host on *${BLOB_HOST_SUFFIX}; it is served with x-mirror-blob-host: unexpected`);
  }
  const now = Date.now();
  const se = Date.parse(u.searchParams.get('se') || '');
  const expires = Number.isFinite(se) ? Math.min(se - TTL.urlMargin * 1000, now + TTL.urlMax * 1000) : now;
  const entry = { location, expires, unexpected };
  const ttl = secondsLeft(expires);
  if (ttl >= TTL.urlMin) {
    store(job, key, entry, ttl);
  } else {
    // Each request for this file then asks GHCR again. The Worker does not
    // guess a time to live from other parameters.
    logOnce(job, 'no-se', 302, `signed URL without a usable se; not cached (the blob ${digest} of ${r.repoPath}, se ${u.searchParams.get('se') ?? 'absent'})`);
  }
  return entry;
}

// The answer as a Response. CACHE says where it stands with its loc entry:
// hit (read from it), miss (stored now) or nostore (not stored).
function respond(answer, cache) {
  if (answer.status === 302) {
    const headers = { location: answer.location, 'cache-control': 'no-store', 'x-mirror-cache': cache };
    if (answer.unexpected === true) headers['x-mirror-blob-host'] = 'unexpected';
    return new Response(null, { status: 302, headers });
  }
  return text(404, answer.message, { 'x-mirror-cache': cache });
}

// Stores the final answer under the loc key until answer.expires, and says
// whether it did. A redirect is not stored when its signed URL has less than
// 30 s left before se minus 120 s (urlExpires).
function storeAnswer(job, key, answer, urlExpires) {
  const ttl = secondsLeft(answer.expires);
  if (ttl < 1) return false;
  if (answer.status === 302 && secondsLeft(urlExpires) < TTL.urlMin) return false;
  store(job, key, answer, ttl);
  return true;
}

// The answer for FILE from the manifest entry MAN.
async function answerFrom(job, r, man, file) {
  const key = cacheKey(job.host, 'loc', [r.arch, r.repo, r.ref, file]);
  const missing = (message) => {
    const answer = { status: 404, message, expires: Math.min(man.expires, Date.now() + TTL.missing * 1000) };
    return respond(answer, storeAnswer(job, key, answer) ? 'miss' : 'nostore');
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
  const answer = { status: 302, location: blob.location, expires: Math.min(blob.expires, man.expires), unexpected: blob.unexpected === true };
  return respond(answer, storeAnswer(job, key, answer, blob.expires) ? 'miss' : 'nostore');
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
  if (r.refuse) return text(404, r.refuse, { 'x-mirror-cache': 'nostore' });
  const hot = await cacheGet(job, cacheKey(job.host, 'loc', [r.arch, r.repo, r.ref, r.file]));
  if (hot) return respond(hot, 'hit');
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
