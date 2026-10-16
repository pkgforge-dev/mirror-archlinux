# The Worker

The Worker is an HTTPS front for the GHCR mirror on Cloudflare. Its name is `ghcr-mirror-archlinux-pkgforge`, and its custom domain is `ghcr.mirror.archlinux.pkgforge.dev`. The code is `worker/src/index.js`, and the configuration is `worker/wrangler.toml`.

```ini
[core]
Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

pacman uses its own downloader with this Server. `ParallelDownloads`, resume and the server error limit apply, and no `XferCommand` is necessary.

⭐ The Worker sends no package bytes. It finds the blob digest of the file in the manifest, and asks GHCR for that blob. It then answers 302 with the Location of GHCR's redirect, a signed blob URL. pacman checks the sha256 of each package against the database, and each signature against the keyring.

## Paths

| path | answers |
| --- | --- |
| `/` | 200: the usage text, with the Server line for the request host |
| `/ARCH/REPO/FILE` | FILE from tag `latest` |
| `/ARCH/REPO:latest/FILE` | the same |
| `/ARCH/REPO:YYYY.MM.DD/FILE` | the first promoted snapshot that was fetched on that UTC date |
| `/ARCH/REPO:db-HEX/FILE` | the snapshot whose `REPO.db` has sha256 HEX |
| `/ARCH/REPO:files-HEX/FILE` | the snapshot whose `REPO.files` has sha256 HEX |
| `/ARCH/REPO@sha256:HEX/FILE` | one manifest; its body must hash to HEX |

FILE is `REPO.db`, `REPO.files`, a package file, or one of these with `.sig`. FILE can be percent-encoded. The Worker decodes it, then checks its character set again. ARCH has at most 32 characters. The decoded FILE has at most 255. The query string is ignored.

A package file and its `.sig` always come from the package's own tag, whatever reference the URL names. Any other tag, `staging` and `index` included, gets 404 with no subrequest. A pin or a `db-` or `files-` tag with upper-case hex gets 404 too. Any other path gets 404 with no subrequest.

The Worker checks the format of a `YYYY.MM.DD`, `db-HEX` or `files-HEX` tag only. It does not check that the database of a `db-HEX` manifest has the sha256 HEX. It checks the hash of an `@sha256:` manifest.

## Answers

| status | when |
| --- | --- |
| 200 | `/` only, with `cache-control: max-age=3600` |
| 302 | the redirect to the signed blob URL, with `cache-control: no-store`, `x-mirror-cache` and no body |
| 404 | the mirror does not hold the file, or the path or tag is not served; with `x-mirror-cache` |
| 405 | a method other than GET and HEAD, with `allow: GET, HEAD` |
| 502 | GHCR failed, GHCR answered something not expected, or the Worker failed; with `retry-after: 30` |

A 404, 405 or 502 answer is plain text, with `cache-control: no-store`. HEAD gets the same answer as GET, with no body. HEAD makes the same subrequests as GET.

Every 302 and 404 says how it stands with its `loc` cache entry:

| `x-mirror-cache` | means |
| --- | --- |
| `hit` | the answer comes from its `loc` entry, with no subrequest |
| `miss` | the answer is new, and is stored in its `loc` entry now |
| `nostore` | the answer is not stored: a path or tag that is not served, a blob that GHCR does not hold, or a signed URL with no usable `se` |

The Worker answers 502 to these, among others:

- a refusal of `Bearer QQ==` with no Bearer challenge, a realm that is not https on `ghcr.io`, or a token request that fails (see [GHCR tokens](#ghcr-tokens))
- a blob answered with 200: the Worker never sends the bytes. The answer says `GHCR now answers blobs with 200; this Worker sends redirects only`.
- a blob status that is not 3xx and not 404, or a redirect with no valid Location
- a redirect whose Location is not https
- a manifest status that is not 200 and not 404
- a manifest over 64 KiB, by `content-length` and then by the bytes read
- a manifest that is not UTF-8 JSON, or has no `layers` array
- a layer whose digest is not `sha256:` and 64 hex digits
- an `@sha256:` manifest whose body hashes to another value
- a subrequest that runs past 10 s, or that fails on the network
- an exception in the Worker

A file with no layer or two layers of its name gets 404. A 502 answer and a blob 404 from GHCR are not stored in the cache.

### A blob host outside `*.githubusercontent.com`

GHCR redirects a blob to `pkg-containers.githubusercontent.com` ([measurements.md](measurements.md)). GitHub moves its download hosts. The host adds no integrity: the Location comes from GHCR over TLS, and pacman checks every sha256 and every signature. So the Worker also answers 302 to an https Location on another host. That answer, and each answer from its cache entries, has the header `x-mirror-blob-host: unexpected`. The Worker logs the host once per isolate.

## GHCR tokens

Every GHCR subrequest sends the dummy token `Bearer QQ==`, which GHCR accepts for every public package. It saves a token request for each file.

When GHCR answers 401 or 403 to the dummy token, the Worker uses the anonymous token flow of the registry:

1. It reads the Bearer challenge in the `www-authenticate` header of that answer. A 403 with no challenge is followed by one request with no authorization, which gets the challenge.
2. It accepts the realm only when it is https on `ghcr.io`.
3. It asks the realm for a pull token, with `service=ghcr.io` and `scope=repository:pkgforge-dev/mirror-archlinux/ARCH/REPO:pull`.
4. It sends the subrequest again, once, with that token.

The token is kept in the isolate and in the `token` cache entry of the repository. Once GHCR refused the dummy token in an isolate, each later subrequest of that isolate sends the kept token first. Another isolate sends the dummy token first, and takes the kept token from the cache when GHCR refuses it. So a repository needs one token request while its token lasts. When GHCR refuses a kept token, the Worker gets a new one from the realm.

The Worker logs `GHCR refused Bearer QQ==; the anonymous token flow is used` once per isolate. The flow needs no deploy: the Worker takes it on the first refusal.

## Caching

The Worker uses the Cache API. There is one cache per data centre, and entries do not replicate. Every key is on the request host under `/__cache/v1`. A change of entry format needs only a new version in that path.

| entry | key | holds | time to live |
| --- | --- | --- | --- |
| `loc` | repository, reference, file | the final answer; a hit is the whole request | a redirect: until the `blob` entry ends, never past its manifest entry; a 404: 60 s, never past its manifest entry |
| `man` | repository, reference | the layers of the manifest | see below |
| `blob` | repository, digest | the signed URL | until the signed URL's `se` minus 120 s, at most 600 s |
| `token` | repository | a pull token, only after GHCR refused `Bearer QQ==` | the token's `expires_in` minus 30 s, at most 300 s; 240 s with no `expires_in` |

A signed URL with no `se` is not stored. Neither is one with less than 30 s left before `se` minus 120 s. The redirect to such a URL is not stored either, and has `x-mirror-cache: nostore`. Each request for that file then asks GHCR again. The Worker logs `signed URL without a usable se; not cached` once per isolate. It does not guess a time to live from other parameters.

| manifest | time to live |
| --- | --- |
| `@sha256:` pin, `YYYY.MM.DD`, `db-HEX`, `files-HEX` | 1 year |
| package manifest with exactly one layer `FILE` and one layer `FILE.sig` | 6 hours |
| any other package manifest | 60 s |
| `latest` | 30 s |
| a 404 | 60 s |

A new `latest` shows within 30 s. A package manifest that is pushed again to repair its `.sig` shows within 6 hours, or within 60 s when its `.sig` layer was missing.

⚠ The 1-year time to live holds only while dated tags stay write-once and `db-`/`files-` tags stay content-addressed. Change `/__cache/v1` in the code to clear every entry with one deploy.

A package request that misses the `loc` cache also fills the `loc` entry of its `.sig`, with `ctx.waitUntil`. The `.sig` blob is asked for at the same time as the package blob. pacman asks for the `.sig` next, from the same Server. When the entry is ready first, that request is one cache lookup in the same data centre. ⚠ A `.sig` asked for very soon after its package can miss the entry (measured in [measurements.md](measurements.md#cloudflare-workers)).

## Logs

The Worker calls `console.error` on each 5xx answer and on each cache failure. It also logs a `.sig` entry that it could not fill, and a body that it could not cancel. Once per isolate, it logs that GHCR refused `Bearer QQ==`, a blob host outside `*.githubusercontent.com`, and a signed URL with no usable `se`. It logs nothing else. `wrangler.toml` sets `[observability] enabled = true`, `head_sampling_rate = 1` and `[observability.logs] invocation_logs = false`.

## Limits

| setting | value |
| --- | --- |
| `compatibility_date` | `2026-10-13` |
| `compatibility_flags` | `no_nodejs_compat`, `no_nodejs_compat_v2`: the Worker uses only Web APIs |
| `[limits] cpu_ms` | 50 |
| `workers_dev`, `preview_urls` | `false` |
| subrequest deadline | 10 s |
| manifest size | 64 KiB |

The answer to one request takes at most three cache lookups and two GHCR subrequests. A package request also fills the entry of its `.sig` in the same invocation: at most two more cache lookups and one more subrequest. When GHCR refuses `Bearer QQ==`, a subrequest can also take a token lookup, a token request and a second try, and one more request when a 403 has no challenge. The Worker hashes a manifest only for an `@sha256:` pin.

## Cost

Cloudflare bills Workers by request and by CPU time. Subrequests and egress are not billed. Each file pacman asks for is one billed request, and so is each `.db.sig` that answers 404. The prices are in [measurements.md](measurements.md#cloudflare-workers).

## Deploy

The maintainer deploys the Worker by hand, from the maintainer's own machine. CI holds no Cloudflare credential and deploys nothing.

`.github/workflows/worker.yml` runs on a push to `main` that changes `worker/**` or the workflow, and on dispatch:

| job | does |
| --- | --- |
| `test` | `node --test 'worker/test/*.test.js'` in the pinned `node:24-alpine` image |

To deploy:

1. Wait for `worker.yml` to pass on `main`.
2. Deploy with the wrangler login of the maintainer:

```bash
cd worker && npx wrangler@4.150.0 deploy
```

3. Check the deployed Worker:

```bash
WORKER_LIVE=1 REPO_ROOT=$PWD bash tests/worker/live.sh
```

⚠ A new version can take some seconds to reach every data centre. Run the live check again after 20 s before you roll back.

To roll back, deploy the previous version: `npx wrangler@4.150.0 rollback`, or deploy the earlier commit of `worker/`.

Check the configuration with no deploy:

```bash
cd worker && npx wrangler@4.150.0 deploy --dry-run --outdir "$(mktemp -d)"
```

## Tests

```bash
REPO_ROOT=$PWD bash tests/worker/10-node.sh
WORKER_LIVE=1 REPO_ROOT=$PWD bash tests/worker/live.sh
```

`tests/worker/10-node.sh` runs `worker/test/*.test.js` with node 22 or newer. The tests use a mock fetch that stands in for GHCR, and a Cache API stub with a clock. They need no network. One test compares `tagOf` with `client/pacman-oci --tags` for every name in `tests/fixtures/filenames.txt`.

⚠ Give `node --test` the quoted glob `'worker/test/*.test.js'`, not the directory. node 26 runs a directory argument as a file and fails.

`tests/worker/live.sh` checks the deployed Worker. It runs only when `WORKER_LIVE=1`. It reads from the Worker, from GHCR with the anonymous token, and from the blob host. It needs curl, tar with gzip, awk, sha256sum and the usual coreutils.

| variable | default |
| --- | --- |
| `WORKER_URL` | `https://ghcr.mirror.archlinux.pkgforge.dev` |
| `WORKER_ARCH` | `x86_64` |
| `WORKER_REPO` | `core` |

## Monitoring

`scripts/status-collect` probes the Worker in each status run, and `status.yml` raises `worker-down` after failed probes in 2 runs in a row over 50 minutes or more ([operations.md](operations.md)). `tests/worker/live.sh` runs only by hand. The probes run on each status run:

| probe | passes when |
| --- | --- |
| `db`, `package` | the Worker answers 302 to an https URL for a target with `latest`, and 404 for a target with none. No redirect is followed. |
| the signed URL of each 302 | a GET from the status runner, with no credential and `Range: bytes=0-0`, answers 206 or 200 |
| `download`, once per run | the smallest database of a target with `latest`, read through the Worker with redirects followed within 60 s, has the sha256 that `latest` names |

⛔ The Worker gets the signed URL from a Cloudflare address and hands it to another client. A signed URL bound to the asker, or one that the blob host refuses, fails every download through the Worker while the 302 looks right. So the probe follows it once, as a consumer does.

A redirect host outside `*.githubusercontent.com` whose signed URL works passes. `status.json` marks it `location_unexpected`, and the status page shows it as a warning. When the Worker sends `x-mirror-cache` or `x-mirror-blob-host`, the probe keeps the value (`cache`, `blob_host`).

## Trust

The Worker holds no secret. Only the maintainer's wrangler login can deploy it. The account id is in `worker/wrangler.toml`.

The databases of the mirror are unsigned. A consumer that reads through the Worker trusts the Worker for the database it gets. So the Worker's code, and every account that can deploy it, join the trust root of that consumer. pacman still checks each package's sha256 against the database and each signature against the keyring. A consumer that must not trust Cloudflare reads the registry directly with the wrapper.
