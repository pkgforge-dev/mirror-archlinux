// tagOf and `client/pacman-oci --tag` give the same tag for every name.
//
// A difference sends the Worker to another manifest than the wrapper, so one
// of the two serves a 404 for a file the mirror holds. The client runs under
// sh (busybox in the node alpine image, bash or dash elsewhere).
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { tagOf } from '../src/index.js';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const CLIENT = fileURLToPath(new URL('../../client/pacman-oci', import.meta.url));
const FIXTURE = fileURLToPath(new URL('../../tests/fixtures/filenames.txt', import.meta.url));

function client(args, input) {
  const r = spawnSync('sh', [CLIENT, ...args], { cwd: ROOT, input, encoding: 'utf8', timeout: 120000 });
  if (r.error) throw new Error(`sh ${CLIENT} ${args.join(' ')} did not start: ${r.error.message}`);
  assert.equal(r.status, 0, `sh client/pacman-oci ${args.join(' ')} exited ${r.status}: ${r.stderr}`);
  return r.stdout;
}

const hashed = (name) => `fn-${createHash('sha256').update(name, 'utf8').digest('hex')}`;

const at128 = `${'a'.repeat(108)}-1-1-any.pkg.tar.zst`;
const at129 = `${'a'.repeat(109)}-1-1-any.pkg.tar.zst`;

// The cases of tests/unit/10-tag-encoding.sh, plus edges of the mapping.
const HAND = [
  ['zlib-1:1.3.2-3-x86_64.pkg.tar.zst', 'zlib-1_c1.3.2-3-x86_64.pkg.tar.zst'],
  ['gcc-libs-15.2.1+r22+gc4e96a094636-1-x86_64.pkg.tar.zst', 'gcc-libs-15.2.1_pr22_pgc4e96a094636-1-x86_64.pkg.tar.zst'],
  ['python-typing_extensions-4.15.0-1-any.pkg.tar.zst', 'python-typing_extensions-4.15.0-1-any.pkg.tar.zst'],
  ['a_pb-1-1-any.pkg.tar.zst', 'a_upb-1-1-any.pkg.tar.zst'],
  ['a_+b-1-1-any.pkg.tar.zst', 'a__pb-1-1-any.pkg.tar.zst'],
  ['a__p-1-1-any.pkg.tar.zst', 'a__up-1-1-any.pkg.tar.zst'],
  ['a_uu-1-1-any.pkg.tar.zst', 'a_uuu-1-1-any.pkg.tar.zst'],
  ['@x-1-1-any.pkg.tar.zst', '_ax-1-1-any.pkg.tar.zst'],
  ['+x-1-1-any.pkg.tar.zst', '_px-1-1-any.pkg.tar.zst'],
  ['x86_64-1-1-any.pkg.tar.zst', 'x86_64-1-1-any.pkg.tar.zst'],
  ['lshw-B.02.20-3-x86_64.pkg.tar.zst', hashed('lshw-B.02.20-3-x86_64.pkg.tar.zst')],
  ['.hidden-1-1-any.pkg.tar.zst', hashed('.hidden-1-1-any.pkg.tar.zst')],
  ['-dash-1-1-any.pkg.tar.zst', hashed('-dash-1-1-any.pkg.tar.zst')],
  ['caf%C3%A9-1-1-any.pkg.tar.zst', hashed('caf%C3%A9-1-1-any.pkg.tar.zst')],
  ['a!b-1-1-any.pkg.tar.zst', hashed('a!b-1-1-any.pkg.tar.zst')],
  [at128, at128],
  [at129, hashed(at129)],
];

test('tagOf gives the hand-checked tags', async () => {
  assert.equal(at128.length, 128);
  for (const [name, want] of HAND) assert.equal(await tagOf(name), want, name);
});

test('tagOf matches client/pacman-oci --tags for every name in tests/fixtures/filenames.txt', async () => {
  const names = readFileSync(FIXTURE, 'utf8').split('\n').filter((l) => l !== '');
  assert.ok(names.length >= 2000, `the fixture has ${names.length} names`);
  const all = [...names, ...HAND.map(([n]) => n)];
  const lines = client(['--tags'], `${all.join('\n')}\n`).split('\n').filter((l) => l !== '');
  assert.equal(lines.length, all.length, 'one line out per name in');
  const diffs = [];
  for (const [i, line] of lines.entries()) {
    const [name, tag] = line.split('\t');
    assert.equal(name, all[i], `line ${i + 1} names the input`);
    const got = await tagOf(name);
    if (got !== tag) diffs.push(`${name}: client ${tag}, worker ${got}`);
  }
  assert.deepEqual(diffs, [], `${diffs.length} of ${all.length} names differ`);
});

test('tagOf matches client/pacman-oci --tag one name at a time', async () => {
  const sample = [
    ...HAND.map(([n]) => n),
    ...readFileSync(FIXTURE, 'utf8')
      .split('\n')
      .filter((l) => /[+:@_]|[A-Z]/.test(l))
      .slice(0, 12),
  ];
  for (const name of sample) {
    const want = client(['--tag', name]).replace(/\n$/, '');
    assert.equal(await tagOf(name), want, name);
  }
});
