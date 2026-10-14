// The Cache API: keys, the one-lookup hot path, every TTL rule, the .sig
// pre-warm, negative entries and cache failures.
import test from 'node:test';
import assert from 'node:assert/strict';
import { inWorld, HOST, PKG, PKG_TAG, NOSIG, UPPER, D, digest, hex, manifestJson, sha256hex } from './world.js';
import { TTL } from '../src/index.js';

const ttlOf = (w, kind, match) => {
  const hits = w.cache.ofKind(kind).filter((p) => decodeURIComponent(p.url).includes(match));
  assert.ok(hits.length > 0, `a ${kind} entry for ${match} is stored; stored: ${w.cache.puts.map((p) => p.url)}`);
  return hits[hits.length - 1].ttl;
};

test('every cache key is on the request host, under /__cache/v1', () =>
  inWorld(async (w) => {
    for (const p of ['/x86_64/core/core.db', `/x86_64/core/${PKG}`, '/x86_64/core/core.db.sig', '/x86_64/extra/extra.db']) {
      await (await w.get(p)).text();
    }
    assert.ok(w.cache.puts.length >= 6, `entries stored: ${w.cache.puts.length}`);
    for (const { url } of w.cache.puts) {
      assert.ok(url.startsWith(`https://${HOST}/__cache/v1/`), url);
      assert.match(new URL(url).pathname, /^\/__cache\/v1\/(loc|man|blob)\//);
    }
  }));

test('a repeat request is one cache lookup and no subrequest', () =>
  inWorld(async (w) => {
    const paths = [
      '/x86_64/core:2026.10.14/core.db',
      `/x86_64/core/${PKG}`,
      `/x86_64/core/${UPPER}`,
      '/x86_64/core/core.db.sig',
      '/x86_64/extra/extra.db',
    ];
    w.manifest('x86_64/core:2026.10.14', [['core.db', D.db]]);
    const first = [];
    for (const p of paths) {
      const res = await w.get(p);
      first.push([res.status, res.headers.get('location')]);
    }
    for (const [i, p] of paths.entries()) {
      const matches = w.cache.matches;
      const requests = w.requests.length;
      const res = await w.get(p);
      assert.deepEqual([res.status, res.headers.get('location')], first[i], p);
      assert.equal(w.cache.matches - matches, 1, `${p}: one cache lookup`);
      assert.equal(w.requests.length - requests, 0, `${p}: no subrequest`);
    }
    assert.deepEqual(w.errors, []);
  }));

test('a redirect is stored until se minus 120 s, at most 600 s, and not with less than 30 s left', () =>
  inWorld(async (w) => {
    const cases = [
      [400, 280],
      [1000, 600],
      [720, 600],
      [150, 30],
      [149, null],
      [60, null],
    ];
    for (const [i, [seAfter, want]] of cases.entries()) {
      w.seAfter = seAfter;
      const name = `p${i}-1-1-any.pkg.tar.zst`;
      const d = digest('567804'[i]);
      w.manifest(`x86_64/core:${name}`, [
        [name, d],
        [`${name}.sig`, digest('9')],
      ]);
      w.blobs.set(`x86_64/core@${d}`, true);
      w.blobs.set(`x86_64/core@${digest('9')}`, true);
      const res = await w.get(`/x86_64/core/${name}`);
      assert.equal(res.status, 302);
      const loc = w.cache.ofKind('loc').filter((p) => p.url.endsWith(`/${encodeURIComponent(name)}`));
      const blob = w.cache.ofKind('blob').filter((p) => p.url.endsWith(encodeURIComponent(d)));
      if (want === null) {
        assert.equal(loc.length, 0, `se after ${seAfter} s: no loc entry`);
        assert.equal(blob.length, 0, `se after ${seAfter} s: no blob entry`);
      } else {
        assert.equal(loc[0].ttl, want, `se after ${seAfter} s: loc TTL`);
        assert.equal(blob[0].ttl, want, `se after ${seAfter} s: blob TTL`);
      }
    }
  }));

test('a signed URL with no se is not stored', () =>
  inWorld(async (w) => {
    w.blobs.set(`x86_64/core@${D.pkg}`, 'https://pkg-containers.githubusercontent.com/ghcrblobs10/blobs/x?sig=1');
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(res.status, 302);
    assert.equal(w.cache.ofKind('loc').filter((p) => p.url.endsWith(encodeURIComponent(PKG))).length, 0);
    assert.equal(w.cache.ofKind('blob').filter((p) => p.url.endsWith(encodeURIComponent(D.pkg))).length, 0);
  }));

test('manifest TTLs: pins and dated, db- and files- tags 1 year; packages 6 h or 60 s; latest 30 s; 404 60 s', () =>
  inWorld(async (w) => {
    const layers = [
      ['core.db', D.db],
      ['core.files', D.files],
    ];
    const body = manifestJson(layers);
    const pin = await sha256hex(body);
    w.manifests.set(`x86_64/core:sha256:${pin}`, body);
    for (const ref of ['2026.10.14', `db-${hex('a')}`, `files-${hex('b')}`]) w.manifest(`x86_64/core:${ref}`, layers);
    const cases = [
      ['/x86_64/core/core.db', 'man/x86_64/core/latest', TTL.latest, 30],
      [`/x86_64/core@sha256:${pin}/core.db`, `man/x86_64/core/sha256:${pin}`, TTL.immutable, 31536000],
      ['/x86_64/core:2026.10.14/core.db', 'man/x86_64/core/2026.10.14', TTL.immutable, 31536000],
      [`/x86_64/core:db-${hex('a')}/core.db`, `man/x86_64/core/db-${hex('a')}`, TTL.immutable, 31536000],
      [`/x86_64/core:files-${hex('b')}/core.files`, `man/x86_64/core/files-${hex('b')}`, TTL.immutable, 31536000],
      [`/x86_64/core/${PKG}.sig`, `man/x86_64/core/${PKG_TAG}`, TTL.packageWithSig, 21600],
      [`/x86_64/core/${NOSIG}`, `man/x86_64/core/${NOSIG}`, TTL.packageNoSig, 60],
      ['/x86_64/extra/extra.db', 'man/x86_64/extra/latest', TTL.missing, 60],
    ];
    for (const [p, key, constant, seconds] of cases) {
      await (await w.get(p)).text();
      assert.equal(constant, seconds, `the constant for ${key}`);
      assert.equal(ttlOf(w, 'man', key.slice(4)), seconds, `${p}: manifest TTL`);
    }
  }));

test('a package manifest with a second layer of the file name is not kept 6 h', () =>
  inWorld(async (w) => {
    const name = 'dup-1-1-any.pkg.tar.zst';
    w.manifest(`x86_64/core:${name}`, [
      [name, D.pkg],
      [`${name}.sig`, D.pkgSig],
      [`${name}.sig`, D.plusSig],
    ]);
    const res = await w.get(`/x86_64/core/${name}`);
    assert.equal(res.status, 302);
    assert.equal(ttlOf(w, 'man', name), 60);
  }));

test('a latest redirect never outlives the latest manifest entry, so a new latest shows within 30 s', () =>
  inWorld(async (w) => {
    const first = await w.get('/x86_64/core/core.db');
    assert.equal(new URL(first.headers.get('location')).pathname, `/ghcrblobs10/blobs/${D.db}`);
    assert.ok(ttlOf(w, 'loc', 'latest/core.db') <= 30, 'the loc entry of latest is at most 30 s');
    const next = digest('8');
    w.manifest('x86_64/core:latest', [
      ['core.db', next],
      ['core.files', D.files],
    ]);
    w.blobs.set(`x86_64/core@${next}`, true);
    w.advance(20);
    const cached = await w.get('/x86_64/core/core.db');
    assert.equal(new URL(cached.headers.get('location')).pathname, `/ghcrblobs10/blobs/${D.db}`);
    w.advance(11);
    const moved = await w.get('/x86_64/core/core.db');
    assert.equal(new URL(moved.headers.get('location')).pathname, `/ghcrblobs10/blobs/${next}`);
  }));

test('a latest redirect is a one-lookup hit while its manifest entry lasts, also when GHCR is slow', () =>
  inWorld(async (w) => {
    // Time moves on during each subrequest, as it does in the runtime.
    w.intercept = () => {
      w.advance(1);
    };
    const first = await w.get('/x86_64/core/core.db');
    assert.equal(first.status, 302);
    // The manifest arrives at T0+1 s and is kept 30 s; the blob answer comes at T0+2 s.
    assert.equal(ttlOf(w, 'loc', 'latest/core.db'), 29, 'the loc entry ends with the latest manifest entry');
    const matches = w.cache.matches;
    const requests = w.requests.length;
    w.advance(27);
    const again = await w.get('/x86_64/core/core.db');
    assert.equal(again.headers.get('location'), first.headers.get('location'));
    assert.equal(w.cache.matches - matches, 1);
    assert.equal(w.requests.length, requests);
  }));

test('a blob entry serves every reference that names the same digest', () =>
  inWorld(async (w) => {
    w.manifest('x86_64/core:2026.10.14', [['core.db', D.db]]);
    await w.get('/x86_64/core/core.db');
    const before = w.requests.length;
    const res = await w.get('/x86_64/core:2026.10.14/core.db');
    assert.equal(res.status, 302);
    assert.deepEqual(
      w.since(before).map((r) => r.url.replace(/^.*\/v2\/pkgforge-dev\/mirror-archlinux\//, '')),
      ['x86_64/core/manifests/2026.10.14'],
    );
  }));

test('a package answer fills the .sig entry: the .sig is then one lookup and no subrequest', () =>
  inWorld(async (w) => {
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(res.status, 302);
    assert.equal(w.requests.length, 3, 'the manifest, the package blob and the .sig blob');
    const matches = w.cache.matches;
    const sig = await w.get(`/x86_64/core/${PKG}.sig`);
    assert.equal(sig.status, 302);
    assert.equal(new URL(sig.headers.get('location')).pathname, `/ghcrblobs10/blobs/${D.pkgSig}`);
    assert.equal(w.cache.matches - matches, 1);
    assert.equal(w.requests.length, 3);
    assert.deepEqual(w.errors, []);
  }));

test('a package request asks for the .sig blob at the same time as the package blob', () =>
  inWorld(async (w) => {
    let sigAsked;
    const sigSeen = new Promise((resolve) => {
      sigAsked = resolve;
    });
    let parallel = null;
    w.intercept = async (url) => {
      if (url.endsWith(`/blobs/${D.pkgSig}`)) sigAsked();
      if (url.endsWith(`/blobs/${D.pkg}`)) {
        // The package blob answers only after the .sig blob is asked for, or
        // after 500 ms.
        parallel = await Promise.race([
          sigSeen.then(() => true),
          new Promise((resolve) => setTimeout(() => resolve(false), 500)),
        ]);
      }
      return undefined;
    };
    const res = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(res.status, 302);
    assert.equal(parallel, true, 'the .sig blob request starts before the package blob answers');
    assert.deepEqual(w.errors, []);
  }));

test('a .sig request does not fill anything more, and a database request fills no .sig', () =>
  inWorld(async (w) => {
    const locFiles = () => w.cache.ofKind('loc').map((p) => decodeURIComponent(p.url.slice(p.url.lastIndexOf('/') + 1)));
    await w.get(`/x86_64/core/${PKG}.sig`);
    assert.equal(w.requests.length, 2, 'the manifest and the .sig blob');
    assert.deepEqual(locFiles(), [`${PKG}.sig`]);
    await w.get('/x86_64/core/core.db');
    assert.equal(w.requests.length, 4, 'the latest manifest and the core.db blob');
    assert.deepEqual(locFiles(), [`${PKG}.sig`, 'core.db']);
  }));

test('a package with no .sig layer: its .sig gets 404 from the cache, kept at most 60 s', () =>
  inWorld(async (w) => {
    const res = await w.get(`/x86_64/core/${NOSIG}`);
    assert.equal(res.status, 302);
    const requests = w.requests.length;
    const matches = w.cache.matches;
    const sig = await w.get(`/x86_64/core/${NOSIG}.sig`);
    assert.equal(sig.status, 404);
    assert.match(await sig.text(), /has 0 layers named/);
    assert.equal(w.requests.length, requests);
    assert.equal(w.cache.matches - matches, 1);
    assert.ok(ttlOf(w, 'loc', `${NOSIG}.sig`) <= 60);
    assert.deepEqual(w.errors, []);
  }));

test('a manifest 404 is kept 60 s, then asked for again', () =>
  inWorld(async (w) => {
    const a = await w.get('/x86_64/extra/extra.db');
    assert.equal(a.status, 404);
    assert.match(await a.text(), /GHCR has no x86_64\/extra:latest/);
    assert.equal(w.requests.length, 1);
    w.advance(59);
    await (await w.get('/x86_64/extra/extra.files')).text();
    assert.equal(w.requests.length, 1, 'the 404 is still kept after 59 s');
    w.advance(2);
    await (await w.get('/x86_64/extra/extra.db')).text();
    assert.equal(w.requests.length, 2, 'the 404 is asked for again after 61 s');
  }));

test('a package manifest entry expires: 6 h with its .sig, 60 s without', () =>
  inWorld(async (w) => {
    await w.get(`/x86_64/core/${PKG}`);
    await w.get(`/x86_64/core/${NOSIG}`);
    w.advance(601);
    const before = w.requests.length;
    await w.get(`/x86_64/core/${PKG}`);
    await w.get(`/x86_64/core/${NOSIG}`);
    const urls = w.since(before).map((r) => r.url);
    assert.ok(!urls.some((u) => u.includes(`/manifests/${PKG_TAG}`)), 'the 6 h manifest is still kept');
    assert.ok(urls.some((u) => u.includes(`/manifests/${NOSIG}`)), 'the 60 s manifest is asked for again');
  }));

test('a cache that fails is logged, and the request still gets its answer from GHCR', () =>
  inWorld(async (w) => {
    w.cache.failMatch = true;
    const a = await w.get('/x86_64/core/core.db');
    assert.equal(a.status, 302);
    assert.ok(w.errors.some(([e]) => /cache match/.test(e.error)), 'the failed match is logged');
    w.cache.failMatch = false;
    w.cache.failPut = true;
    w.errors.length = 0;
    const b = await w.get(`/x86_64/core/${PKG}`);
    assert.equal(b.status, 302);
    assert.ok(w.errors.some(([e]) => /cache put/.test(e.error)), 'the failed put is logged');
  }));

test('an entry past its expires time is not used, whatever the cache returns', () =>
  inWorld(async (w) => {
    await w.get('/x86_64/core/core.db');
    // A cache that keeps entries longer than max-age, as eviction allows.
    for (const e of w.cache.entries.values()) e.until = Infinity;
    w.advance(3600);
    const before = w.requests.length;
    const res = await w.get('/x86_64/core/core.db');
    assert.equal(res.status, 302);
    assert.equal(w.since(before).length, 2, 'the manifest and the blob are asked for again');
  }));
