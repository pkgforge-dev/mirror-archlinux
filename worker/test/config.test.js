// worker/wrangler.toml and .github/workflows/worker.yml keep the settings
// the Worker depends on. A deploy reads them with no review of its own.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const read = (rel) => readFileSync(fileURLToPath(new URL(`../../${rel}`, import.meta.url)), 'utf8');

// The flat keys of a TOML file by section ('' is the top level). Enough for
// this file: one key per line, no multi-line values except the routes array.
function toml(text) {
  const out = { '': {} };
  let section = '';
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+#.*$/, '').trim();
    if (line === '' || line.startsWith('#')) continue;
    const s = /^\[([a-z_.]+)\]$/.exec(line);
    if (s) {
      section = s[1];
      out[section] = out[section] || {};
      continue;
    }
    const kv = /^([a-z_]+)\s*=\s*(.+)$/.exec(line);
    if (kv) out[section][kv[1]] = kv[2];
  }
  return out;
}

test('wrangler.toml names the Worker, its account, its domain and no workers.dev route', () => {
  const text = read('worker/wrangler.toml');
  const t = toml(text);
  assert.equal(t[''].name, '"ghcr-mirror-archlinux-pkgforge"');
  assert.equal(t[''].main, '"src/index.js"');
  assert.equal(t[''].account_id, '"2a97c8f21aff7a773bf976c61ace1381"');
  assert.equal(t[''].workers_dev, 'false');
  assert.equal(t[''].preview_urls, 'false');
  assert.match(text, /\{\s*pattern\s*=\s*"ghcr\.mirror\.archlinux\.pkgforge\.dev",\s*custom_domain\s*=\s*true\s*\}/);
});

test('wrangler.toml sets the compatibility date, the flags, the CPU limit and the logs', () => {
  const t = toml(read('worker/wrangler.toml'));
  assert.equal(t[''].compatibility_date, '"2026-10-13"');
  assert.equal(t[''].compatibility_flags, '["no_nodejs_compat", "no_nodejs_compat_v2"]');
  assert.equal(t.limits.cpu_ms, '50');
  assert.equal(t.observability.enabled, 'true');
  assert.equal(t.observability.head_sampling_rate, '1');
  assert.equal(t['observability.logs'].invocation_logs, 'false');
});

test('worker.yml tests in a pinned node image and deploys with a pinned wrangler-action', () => {
  const wf = read('.github/workflows/worker.yml');
  const image = /# tag: (\d+)-alpine\n\s*image=docker\.io\/library\/node:(\d+)-alpine@sha256:[0-9a-f]{64}\n/.exec(wf);
  assert.ok(image, 'the node image is pinned by digest under a # tag: marker');
  assert.equal(image[1], image[2], 'the marker names the tag of the image line');
  assert.ok(Number(image[2]) >= 22, `node ${image[2]} is 22 or newer`);
  assert.match(wf, /node --test 'worker\/test\/\*\.test\.js'/);
  assert.match(wf, /uses: cloudflare\/wrangler-action@953926a2e2182532811c01a25e53647d93bf07c0 # v4\.1\.3\n/);
  assert.match(wf, /wranglerVersion: "4\.150\.0"/);
  assert.match(wf, /workingDirectory: worker\n/);
  assert.match(wf, /apiToken: \$\{\{ secrets\.CLOUDFLARE_API_TOKEN \}\}/);
  assert.match(wf, /if: github\.ref == 'refs\/heads\/main'/);
  assert.doesNotMatch(wf, /if:.*secrets\./, 'the secret is checked through env, not in if:');
});
