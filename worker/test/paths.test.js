// Paths, references, file names, methods and HEAD.
import test from 'node:test';
import assert from 'node:assert/strict';
import { inWorld, HOST, REGISTRY, PKG, PKG_TAG, PLUS, PLUS_TAG, D, hex, sha256hex } from './world.js';

const manifestUrls = (w) => w.requests.map((r) => r.url).filter((u) => u.includes('/manifests/'));

test('GET / shows the usage text with the Server line and makes no subrequest', () =>
  inWorld(async (w) => {
    const res = await w.get('/');
    assert.equal(res.status, 200);
    const body = await res.text();
    assert.match(body, new RegExp(`^Server = https://${HOST.replace(/\./g, '\\.')}/\\$arch/\\$repo$`, 'm'));
    assert.match(body, /\/ARCH\/REPO@sha256:HEX\/FILE/);
    assert.equal(res.headers.get('cache-control'), 'max-age=3600');
    assert.equal(w.requests.length, 0);
    assert.equal(w.cache.matches, 0);
  }));

test('an unknown path gets 404 with no subrequest and no cache lookup', () =>
  inWorld(async (w) => {
    const paths = [
      '/foo',
      '/favicon.ico',
      '/x86_64',
      '/x86_64/core',
      '/x86_64/core/',
      '/x86_64/core/README',
      '/x86_64/core/extra.db',
      '/x86_64/core/core.db.tar.gz',
      '/x86_64/core/core.dbx',
      '/x86_64/core/sub/core.db',
      '//x86_64/core/core.db',
      '/X86_64/core/core.db',
      '/x86_64/Core/core.db',
      '/_x86_64/core/core.db',
      '/__cache/v1/loc/x86_64/core/latest/core.db',
      `/x86_64/core@sha256:${'A'.repeat(64)}/core.db`,
      '/x86_64/core@sha256:abc/core.db',
      `/x86_64/core@sha512:${hex('a')}/core.db`,
      `/x86_64/core/${'a'.repeat(250)}.pkg.tar.zst`,
    ];
    for (const p of paths) {
      const res = await w.get(p);
      assert.equal(res.status, 404, p);
      await res.text();
    }
    assert.deepEqual(w.requests, []);
    assert.equal(w.cache.matches, 0);
    assert.deepEqual(w.errors, []);
  }));

test('latest, YYYY.MM.DD, db-HEX, files-HEX and @sha256 pins are served', () =>
  inWorld(async (w) => {
    const layers = [
      ['core.db', D.db],
      ['core.files', D.files],
    ];
    const pinBody = w.manifest('x86_64/core:pin-placeholder', layers, { annotations: { a: 'pin' } });
    const pin = await sha256hex(pinBody);
    w.manifests.set(`x86_64/core:sha256:${pin}`, pinBody);
    for (const ref of ['2026.10.14', `db-${hex('a')}`, `files-${hex('b')}`]) w.manifest(`x86_64/core:${ref}`, layers);
    const cases = [
      ['/x86_64/core/core.db', 'latest'],
      ['/x86_64/core:latest/core.files', 'latest'],
      ['/x86_64/core:2026.10.14/core.db', '2026.10.14'],
      [`/x86_64/core:db-${hex('a')}/core.db`, `db-${hex('a')}`],
      [`/x86_64/core:files-${hex('b')}/core.files`, `files-${hex('b')}`],
      [`/x86_64/core@sha256:${pin}/core.db`, `sha256:${pin}`],
    ];
    for (const [p, ref] of cases) {
      const before = w.requests.length;
      const res = await w.get(p);
      assert.equal(res.status, 302, p);
      const urls = w.since(before).map((r) => r.url);
      if (urls.some((u) => u.includes('/manifests/'))) {
        assert.ok(urls.includes(`${REGISTRY}/x86_64/core/manifests/${ref}`), `${p} asks GHCR for ${ref}: ${urls}`);
      }
    }
    assert.deepEqual(w.errors, []);
  }));

test('any other tag gets 404 with no subrequest, staging included', () =>
  inWorld(async (w) => {
    const tags = [
      'staging',
      'staging-wip',
      'LATEST',
      'Latest',
      '2026.10',
      '2026-10-14',
      '20261014',
      'db-abc',
      `db-${'A'.repeat(64)}`,
      `files-${hex('b')}0`,
      `sha256-${hex('a')}`,
      PKG_TAG,
      'v1',
    ];
    for (const t of tags) {
      for (const f of ['core.db', PKG]) {
        const res = await w.get(`/x86_64/core:${t}/${f}`);
        assert.equal(res.status, 404, `${t} ${f}`);
        assert.match(await res.text(), /is not served/);
      }
    }
    assert.deepEqual(w.requests, []);
    assert.equal(w.cache.matches, 0);
  }));

test('a package and its .sig come from the package tag, whatever reference the URL names', () =>
  inWorld(async (w) => {
    for (const p of [
      `/x86_64/core/${PKG}`,
      `/x86_64/core:2026.10.14/${PKG}`,
      `/x86_64/core@sha256:${hex('9')}/${PKG}.sig`,
    ]) {
      const res = await w.get(p);
      assert.equal(res.status, 302, p);
    }
    // One manifest request for all three, by the package's own tag. The pin
    // in the third URL is not checked: it names a database, not a package.
    assert.deepEqual(manifestUrls(w), [`${REGISTRY}/x86_64/core/manifests/${PKG_TAG}`]);
    assert.deepEqual(w.errors, []);
  }));

test('a percent-encoded file name is decoded before its tag is made', () =>
  inWorld(async (w) => {
    const plain = await w.get(`/x86_64/core/${PLUS}`);
    assert.equal(plain.status, 302);
    const encoded = await w.get(`/x86_64/core/${PLUS.replace(/\+/g, '%2B')}`);
    assert.equal(encoded.status, 302);
    assert.equal(encoded.headers.get('location'), plain.headers.get('location'));
    const lower = await w.get(`/x86_64/core/${PLUS.replace(/\+/g, '%2b')}.sig`);
    assert.equal(lower.status, 302);
    const colon = await w.get(`/x86_64/core/${PKG.replace(':', '%3A')}`);
    assert.equal(colon.status, 302);
    const dot = await w.get('/x86_64/core/core%2Edb');
    assert.equal(dot.status, 302);
    assert.deepEqual(manifestUrls(w), [
      `${REGISTRY}/x86_64/core/manifests/${PLUS_TAG}`,
      `${REGISTRY}/x86_64/core/manifests/${PKG_TAG}`,
      `${REGISTRY}/x86_64/core/manifests/latest`,
    ]);
    assert.deepEqual(w.errors, []);
  }));

test('a decoded file name outside the character set gets 404 with no subrequest', () =>
  inWorld(async (w) => {
    const names = [
      'a%2Fb-1-1-any.pkg.tar.zst',
      'a%20b-1-1-any.pkg.tar.zst',
      'a%0Ab-1-1-any.pkg.tar.zst',
      'a%00b-1-1-any.pkg.tar.zst',
      'caf%C3%A9-1-1-any.pkg.tar.zst',
      'a%7Fb-1-1-any.pkg.tar.zst',
      'bad%E0%A4%A-1-1-any.pkg.tar.zst',
      'bad%ZZ-1-1-any.pkg.tar.zst',
      '%2E',
      `${'a'.repeat(240)}%2B%2B%2B%2B%2B%2B.pkg.tar.zst`,
    ];
    for (const n of names) {
      const res = await w.get(`/x86_64/core/${n}`);
      assert.equal(res.status, 404, n);
      await res.text();
    }
    assert.deepEqual(w.requests, []);
    assert.deepEqual(w.errors, []);
  }));

test('a method other than GET and HEAD gets 405', () =>
  inWorld(async (w) => {
    for (const m of ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
      const res = await w.request('/x86_64/core/core.db', m);
      assert.equal(res.status, 405, m);
      assert.equal(res.headers.get('allow'), 'GET, HEAD');
      await res.text();
    }
    assert.deepEqual(w.requests, []);
  }));

test('HEAD gets the same answer as GET, with no body', () =>
  inWorld(async (w) => {
    const head = await w.head('/x86_64/core/core.db');
    assert.equal(head.status, 302);
    assert.equal(head.body, null);
    const get = await w.get('/x86_64/core/core.db');
    assert.equal(get.status, 302);
    assert.equal(head.headers.get('location'), get.headers.get('location'));
    assert.match(head.headers.get('location'), /^https:\/\/pkg-containers\.githubusercontent\.com\//);
    const root = await w.head('/');
    assert.equal(root.status, 200);
    assert.equal(root.body, null);
    const missing = await w.head('/x86_64/core/core.db.sig');
    assert.equal(missing.status, 404);
    assert.equal(missing.body, null);
    const unknown = await w.head('/foo');
    assert.equal(unknown.status, 404);
    assert.equal(unknown.body, null);
  }));

test('a 302 has no body and cache-control no-store', () =>
  inWorld(async (w) => {
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(res.status, 302);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(res.body, null);
    assert.equal(new URL(res.headers.get('location')).pathname, `/ghcrblobs10/blobs/${D.pkg}`);
  }));
