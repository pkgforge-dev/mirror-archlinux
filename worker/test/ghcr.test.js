// GHCR subrequests: deadlines, failures, the never-stream rule, the Location
// check, pins, the manifest size cap, and bodies that are not read.
import test from 'node:test';
import assert from 'node:assert/strict';
import { inWorld, REGISTRY, MANIFEST_TYPE, PKG, D, digest, hex, manifestJson, sha256hex } from './world.js';

function assert502(res, w) {
  assert.equal(res.status, 502);
  assert.equal(res.headers.get('retry-after'), '30');
  assert.ok(w.errors.length > 0, 'a 502 is logged with console.error');
  for (const [e] of w.errors) assert.equal(typeof e, 'object');
}

const isManifest = (url) => url.includes('/manifests/');
const isBlob = (url) => url.includes('/blobs/');

test('every subrequest has a 10 s deadline, the anonymous token and no redirect followed', () =>
  inWorld(async (w) => {
    const res = await w.get('/x86_64/core/core.db');
    assert.equal(res.status, 302);
    assert.equal(w.requests.length, 2);
    for (const { url, init } of w.requests) {
      assert.ok(url.startsWith(`${REGISTRY}/x86_64/core/`), url);
      assert.ok(init.signal instanceof AbortSignal, `${url} has a signal`);
      assert.equal(init.redirect, 'manual');
      assert.equal(init.headers.authorization, 'Bearer QQ==');
    }
    assert.equal(w.requests[0].init.headers.accept, MANIFEST_TYPE);
    assert.deepEqual(w.timeouts, [10000, 10000]);
    assert.deepEqual(w.errors, []);
  }));

test('a network error on the manifest request gets 502 with retry-after 30', () =>
  inWorld(async (w) => {
    w.intercept = (url) => {
      if (isManifest(url)) throw new TypeError('fetch failed');
    };
    const res = await w.get('/x86_64/core/core.db');
    assert502(res, w);
    assert.match(await res.text(), /fetch failed/);
    assert.equal(w.cache.ofKind('man').length, 0);
  }));

test('a network error on the blob request gets 502 with retry-after 30', () =>
  inWorld(async (w) => {
    w.intercept = (url) => {
      if (isBlob(url)) throw new TypeError('fetch failed');
    };
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert502(res, w);
    assert.equal(w.cache.ofKind('loc').length, 0);
  }));

test('a GHCR request that runs past its deadline gets 502', () =>
  inWorld(async (w) => {
    // The runtime's own timeout timer does not keep node's event loop alive,
    // so a referenced timer stands in for it, 5 ms instead of 10 s.
    AbortSignal.timeout = (ms) => {
      w.timeouts.push(ms);
      const c = new AbortController();
      setTimeout(() => c.abort(new DOMException('The operation timed out.', 'TimeoutError')), 5);
      return c.signal;
    };
    w.intercept = (url, init) =>
      new Promise((resolve, reject) => {
        if (init.signal.aborted) reject(init.signal.reason);
        init.signal.addEventListener('abort', () => reject(init.signal.reason));
      });
    const t = performance.now();
    const res = await w.get('/x86_64/core/core.db');
    assert502(res, w);
    assert.ok(performance.now() - t < 5000, 'the stalled request ends at its deadline');
    assert.deepEqual(w.timeouts, [10000]);
  }));

test('a GHCR answer other than 200 or 404 for a manifest gets 502, and its body is cancelled', () =>
  inWorld(async (w) => {
    for (const status of [500, 502, 503, 429, 401, 403, 303, 307, 204]) {
      w.errors.length = 0;
      w.intercept = (url) => {
        if (isManifest(url)) {
          const body = status === 204 ? '' : `{"errors":[{"code":"E${status}"}]}`;
          return w.response(status, body, status === 303 || status === 307 ? { location: 'https://github.com/' } : {});
        }
      };
      const res = await w.get('/x86_64/core/core.db');
      assert502(res, w);
      assert.match(await res.text(), new RegExp(`GHCR answered ${status}`));
    }
    assert.equal(w.cache.ofKind('man').length, 0);
    assert.deepEqual(w.unusedBodies(), []);
  }));

test('a blob that GHCR answers with 200 gets 502: the Worker never sends the bytes', () =>
  inWorld(async (w) => {
    const bytes = new Uint8Array(1 << 20);
    w.intercept = (url) => {
      if (isBlob(url)) return w.response(200, bytes, { 'content-length': String(bytes.byteLength) }, { url });
    };
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert502(res, w);
    const blobBody = w.bodies.find((b) => isBlob(b.url));
    assert.equal(blobBody.read, false, 'the blob body is not read');
    assert.equal(blobBody.cancelled, true, 'the blob body is cancelled');
    assert.equal(w.cache.ofKind('loc').length, 0);
  }));

test('the Location must be https and its host must end in .githubusercontent.com', () =>
  inWorld(async (w) => {
    const se = encodeURIComponent(new Date(w.clock.now + 400000).toISOString());
    const bad = [
      `http://pkg-containers.githubusercontent.com/b?se=${se}`,
      `https://evil.example/b?se=${se}`,
      `https://pkg-containers.githubusercontent.com.evil.example/b?se=${se}`,
      `https://githubusercontent.com/b?se=${se}`,
      `https://xgithubusercontent.com/b?se=${se}`,
      `ftp://pkg-containers.githubusercontent.com/b?se=${se}`,
      '/relative/b',
      'not a url',
      null,
    ];
    for (const location of bad) {
      w.errors.length = 0;
      w.intercept = (url) => {
        if (isBlob(url)) return w.response(307, '', location === null ? {} : { location }, { url });
      };
      const res = await w.get(`/x86_64/core/${PKG}`);
      assert502(res, w);
    }
    assert.equal(w.cache.ofKind('blob').length, 0);
    assert.equal(w.cache.ofKind('loc').length, 0);
    w.intercept = (url) => {
      if (isBlob(url)) return w.response(302, '', { location: `https://objects.githubusercontent.com/b?se=${se}` }, { url });
    };
    const ok = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(ok.status, 302);
    assert.equal(ok.headers.get('location'), `https://objects.githubusercontent.com/b?se=${se}`);
  }));

test('a blob answer that is not a redirect gets 502, even with a Location', () =>
  inWorld(async (w) => {
    for (const status of [201, 204, 401, 403, 429, 500, 503]) {
      w.errors.length = 0;
      w.intercept = (url) => {
        if (isBlob(url)) return w.response(status, status === 204 ? '' : 'x', { location: w.signedUrl(D.pkg) }, { url });
      };
      const res = await w.get(`/x86_64/core/${PKG}`);
      assert502(res, w);
      assert.match(await res.text(), new RegExp(`GHCR answered ${status} for the blob`));
    }
  }));

test('a blob GHCR does not hold gets 404, with no log', () =>
  inWorld(async (w) => {
    w.blobs.delete(`x86_64/core@${D.pkg}`);
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(res.status, 404);
    assert.match(await res.text(), /GHCR has no blob/);
    assert.deepEqual(w.errors, []);
  }));

test('an @sha256 pin is served when the manifest hashes to it', () =>
  inWorld(async (w) => {
    const body = manifestJson([
      ['core.db', D.db],
      ['core.files', D.files],
    ]);
    const pin = await sha256hex(body);
    w.manifests.set(`x86_64/core:sha256:${pin}`, body);
    const res = await w.get(`/x86_64/core@sha256:${pin}/core.db`);
    assert.equal(res.status, 302);
    assert.equal(new URL(res.headers.get('location')).pathname, `/ghcrblobs10/blobs/${D.db}`);
    assert.deepEqual(w.errors, []);
  }));

test('an @sha256 pin whose manifest hashes to another value gets 502 and is not stored', () =>
  inWorld(async (w) => {
    const body = manifestJson([['core.db', D.db]]);
    const pin = hex('7');
    w.manifests.set(`x86_64/core:sha256:${pin}`, body);
    const res = await w.get(`/x86_64/core@sha256:${pin}/core.db`);
    assert502(res, w);
    assert.match(await res.text(), new RegExp(`hashes to sha256:${await sha256hex(body)}`));
    assert.equal(w.cache.ofKind('man').length, 0);
    assert.equal(w.cache.ofKind('loc').length, 0);
    const again = await w.get(`/x86_64/core@sha256:${pin}/core.db`);
    assert.equal(again.status, 502);
    assert.equal(w.requests.filter((r) => isManifest(r.url)).length, 2, 'a refused pin is asked for again');
  }));

test('a manifest over 64 KiB by content-length gets 502, and its body is not read', () =>
  inWorld(async (w) => {
    w.intercept = (url) => {
      if (isManifest(url)) return w.response(200, manifestJson([['core.db', D.db]]), { 'content-length': '65537' }, { url });
    };
    const res = await w.get('/x86_64/core/core.db');
    assert502(res, w);
    assert.match(await res.text(), /over 65536 bytes/);
    const b = w.bodies.find((x) => isManifest(x.url));
    assert.equal(b.read, false);
    assert.equal(b.cancelled, true);
  }));

test('a manifest over 64 KiB with no or a false content-length is cut at 64 KiB', () =>
  inWorld(async (w) => {
    for (const headers of [{}, { 'content-length': '100' }]) {
      w.errors.length = 0;
      const big = new Uint8Array(200000).fill(0x20);
      w.intercept = (url) => {
        if (isManifest(url)) return w.response(200, big, headers, { url, chunk: 16384 });
      };
      const res = await w.get('/x86_64/core/core.db');
      assert502(res, w);
      assert.match(await res.text(), /over 65536 bytes/);
    }
    for (const b of w.bodies) assert.equal(b.cancelled, true, 'the reader is cancelled at the cap');
  }));

test('a manifest of exactly 64 KiB is accepted', () =>
  inWorld(async (w) => {
    const json = manifestJson([['core.db', D.db]]);
    const padded = json + ' '.repeat(65536 - json.length);
    assert.equal(new TextEncoder().encode(padded).byteLength, 65536);
    w.intercept = (url) => {
      if (isManifest(url)) return w.response(200, padded, {}, { url, chunk: 4096 });
    };
    const res = await w.get('/x86_64/core/core.db');
    assert.equal(res.status, 302);
    assert.deepEqual(w.errors, []);
  }));

test('a manifest that is not JSON, or has no layers array, gets 502 and is not stored', () =>
  inWorld(async (w) => {
    for (const body of ['', 'not json', '{"layers": 3}', '[]', 'null', '\xff\xfe']) {
      w.errors.length = 0;
      w.intercept = (url) => {
        if (isManifest(url)) {
          const bytes = body === '\xff\xfe' ? new Uint8Array([0xff, 0xfe, 0x7b, 0x7d]) : body;
          return w.response(200, bytes, { 'content-type': MANIFEST_TYPE }, { url });
        }
      };
      const res = await w.get('/x86_64/core/core.db');
      assert502(res, w);
    }
    assert.equal(w.cache.ofKind('man').length, 0);
  }));

test('a file with two layers of its name gets 404; a layer with no sha256 digest gets 502', () =>
  inWorld(async (w) => {
    w.manifest('x86_64/core:latest', [
      ['core.db', D.db],
      ['core.db', D.files],
      ['core.files', 'md5:abc'],
    ]);
    const two = await w.get('/x86_64/core/core.db');
    assert.equal(two.status, 404);
    assert.match(await two.text(), /has 2 layers named core\.db/);
    assert.deepEqual(w.errors, []);
    const bad = await w.get('/x86_64/core/core.files');
    assert502(bad, w);
    assert.match(await bad.text(), /no sha256 digest/);
    w.manifest('x86_64/core:2026.10.14', [['core.db', digest('a').toUpperCase()]]);
    const upper = await w.get('/x86_64/core:2026.10.14/core.db');
    assert.equal(upper.status, 502);
  }));

test('console.error is called on 5xx answers only', () =>
  inWorld(async (w) => {
    const ok = [
      '/',
      '/x86_64/core/core.db',
      '/x86_64/core/core.files',
      '/x86_64/core/core.db.sig',
      `/x86_64/core/${PKG}`,
      `/x86_64/core/${PKG}.sig`,
      '/x86_64/core/nosig-1-1-any.pkg.tar.zst.sig',
      '/x86_64/extra/extra.db',
      '/x86_64/core:2026.10.13/core.db',
      '/x86_64/core:staging/core.db',
      '/foo',
    ];
    for (const p of ok) {
      const res = await w.get(p);
      assert.ok(res.status < 500, `${p}: ${res.status}`);
      await res.text();
    }
    assert.deepEqual(w.errors, []);
    w.intercept = () => {
      throw new TypeError('fetch failed');
    };
    const res = await w.get('/x86_64/core/other-1-1-any.pkg.tar.zst');
    assert.equal(res.status, 502);
    assert.equal(w.errors.length, 1);
    assert.equal(w.errors[0][0].status, 502);
    assert.equal(w.errors[0][0].path, '/x86_64/core/other-1-1-any.pkg.tar.zst');
  }));

test('an unexpected error inside the Worker gets 502 with retry-after, not an error page', () =>
  inWorld(async (w) => {
    w.intercept = () => ({
      get status() {
        throw new Error('broken status');
      },
      headers: new Headers(),
      body: null,
    });
    const res = await w.get('/x86_64/core/core.db');
    assert502(res, w);
    assert.match(await res.text(), /^internal error: Error: broken status/);
  }));
