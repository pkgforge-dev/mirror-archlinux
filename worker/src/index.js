// ghcr-mirror-archlinux-pkgforge: an HTTPS front for the GHCR mirror.
//
//   Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
//
// pacman uses its own downloader with this Server: ParallelDownloads, resume
// and the server error limit apply, and no XferCommand is necessary.
//
// The Worker sends no package bytes. It finds the blob digest for the file,
// asks GHCR for that blob, and returns GHCR's redirect to the signed blob URL.
// pacman then reads the bytes from GitHub's blob host. pacman checks each
// file's sha256 against the database and each signature against the keyring,
// as for every mirror.
//
// Paths:
//   /ARCH/REPO/FILE              the database from tag latest
//   /ARCH/REPO:TAG/FILE          the database from a tag, e.g. :2026.10.14
//   /ARCH/REPO@sha256:HEX/FILE   the database from one manifest
// A package file and its .sig always come from the package's own tag.
//
// Cost control: the Cache API holds each manifest (immutable references for a
// day or a year, moving ones for 60 s) and each signed redirect until shortly
// before it expires. A cache hit costs no subrequest.

const REGISTRY = 'https://ghcr.io/v2/pkgforge-dev/mirror-archlinux';
const AUTH = 'Bearer QQ==';
const MANIFEST_TYPE = 'application/vnd.oci.image.manifest.v1+json';
const MANIFEST_MAX = 65536;
const CACHE_ORIGIN = 'https://cache.invalid';

const PATH_RE =
  /^\/([a-z0-9_]{1,32})\/([a-z0-9]+(?:-[a-z0-9]+)*)(?::([A-Za-z0-9_][A-Za-z0-9._-]{0,127})|@(sha256:[0-9a-f]{64}))?\/([!-.0-~]{1,255})$/;

const enc = new TextEncoder();

function text(status, body, extra = {}) {
  return new Response(body + '\n', {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', ...extra },
  });
}

async function sha256hex(s) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(s)));
  let h = '';
  for (const b of d) h += b.toString(16).padStart(2, '0');
  return h;
}

// The tag a package file is stored under. The same mapping as
// `client/pacman-oci --tag`; tests/unit/50-worker.sh compares the two.
export async function tagOf(name) {
  const t = name.replace(/_([pcau])/g, '_u$1').replace(/\+/g, '_p').replace(/:/g, '_c').replace(/@/g, '_a');
  if (/^[a-z0-9@._+:-]+$/.test(name) && /^[a-z0-9_][a-z0-9._-]*$/.test(t) && t.length <= 128) return t;
  return 'fn-' + (await sha256hex(name));
}

// A reference whose manifest never changes, or changes only to gain a
// repaired signature layer.
function ttlOf(ref, kind) {
  if (ref.startsWith('sha256:')) return 31536000;
  if (/^\d{4}\.\d{2}\.\d{2}$/.test(ref) || /^(db|files)-[0-9a-f]{64}$/.test(ref)) return 31536000;
  if (kind === 'pkg' || kind === 'pkgsig') return 86400;
  return 60;
}

function cacheKey(...parts) {
  return new Request(CACHE_ORIGIN + '/' + parts.map(encodeURIComponent).join('/'));
}

// The layer digest for FILE in REPO:REF, or a Response that ends the request.
async function layerDigest(ctx, repoPath, ref, kind, file) {
  const cache = caches.default;
  const key = cacheKey('m', repoPath, ref);
  let res = await cache.match(key);
  if (!res) {
    const up = await fetch(`${REGISTRY}/${repoPath}/manifests/${ref}`, {
      headers: { authorization: AUTH, accept: MANIFEST_TYPE },
      redirect: 'manual',
    });
    const ttl = ttlOf(ref, kind);
    if (up.status === 404) {
      res = new Response('', { status: 404, headers: { 'cache-control': 'max-age=60' } });
      ctx.waitUntil(cache.put(key, res.clone()));
    } else if (up.status !== 200) {
      up.body?.cancel();
      return text(502, `registry answered ${up.status} for ${repoPath}:${ref}`, { 'retry-after': '30' });
    } else {
      const body = await up.text();
      if (body.length > MANIFEST_MAX) return text(502, `manifest for ${repoPath}:${ref} is over 64 KiB`);
      res = new Response(body, { status: 200, headers: { 'cache-control': `max-age=${ttl}` } });
      ctx.waitUntil(cache.put(key, res.clone()));
    }
  }
  if (res.status === 404) return text(404, `no ${repoPath}:${ref}`);
  let m;
  try {
    m = JSON.parse(await res.text());
  } catch {
    return text(502, `manifest for ${repoPath}:${ref} is not JSON`);
  }
  const hits = (m.layers || []).filter((l) => l?.annotations?.['org.opencontainers.image.title'] === file);
  if (hits.length !== 1) return text(404, `${repoPath}:${ref} has ${hits.length} layer(s) named ${file}`);
  const digest = hits[0].digest;
  if (typeof digest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(digest)) {
    return text(502, `layer ${file} has no sha256 digest`);
  }
  return digest;
}

// GHCR answers a blob request with 307 to a signed URL that expires at `se`.
async function blobRedirect(ctx, repoPath, digest) {
  const cache = caches.default;
  const key = cacheKey('b', repoPath, digest);
  const hit = await cache.match(key);
  if (hit) return new Response(null, { status: 302, headers: { location: await hit.text(), 'cache-control': 'no-store' } });
  const up = await fetch(`${REGISTRY}/${repoPath}/blobs/${digest}`, {
    headers: { authorization: AUTH },
    redirect: 'manual',
  });
  if (up.status === 404) return text(404, `no blob ${digest}`);
  if (up.status === 200) return up; // a registry that serves the blob itself
  up.body?.cancel();
  const loc = up.headers.get('location');
  if (up.status < 300 || up.status > 399 || !loc || !loc.startsWith('https://')) {
    return text(502, `registry answered ${up.status} for blob ${digest}`, { 'retry-after': '30' });
  }
  const se = Date.parse(new URL(loc).searchParams.get('se') || '');
  const ttl = Math.floor((se - Date.now()) / 1000) - 120;
  if (ttl >= 30) {
    ctx.waitUntil(cache.put(key, new Response(loc, { headers: { 'cache-control': `max-age=${Math.min(ttl, 600)}` } })));
  }
  return new Response(null, { status: 302, headers: { location: loc, 'cache-control': 'no-store' } });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'GET' && request.method !== 'HEAD') return text(405, 'GET or HEAD only', { allow: 'GET, HEAD' });
    const url = new URL(request.url);
    if (url.pathname === '/') {
      return text(200, 'Server = https://' + url.host + '/$arch/$repo\nhttps://github.com/pkgforge-dev/mirror-archlinux', {
        'cache-control': 'max-age=3600',
      });
    }
    const p = PATH_RE.exec(url.pathname);
    if (!p) return text(404, 'not /ARCH/REPO/FILE');
    const [, arch, repo, tag, pin, file] = p;
    if (file === '.' || file === '..') return text(404, 'not a file name');
    const repoPath = `${arch}/${repo}`;
    let kind, ref, layer;
    if (/\.pkg\.tar(\.[^/]+)?\.sig$/.test(file)) {
      kind = 'pkgsig';
      ref = await tagOf(file.slice(0, -4));
    } else if (/\.pkg\.tar(\.[^/]+)?$/.test(file)) {
      kind = 'pkg';
      ref = await tagOf(file);
    } else {
      kind = 'db';
      ref = pin || tag || 'latest';
    }
    layer = file;
    const digest = await layerDigest(ctx, repoPath, ref, kind, layer);
    if (digest instanceof Response) return digest;
    return blobRedirect(ctx, repoPath, digest);
  },
};
