# Measurements

Measured facts only. Each table gives its date and its source. A row that comes from documentation says so. Times are UTC unless a table says otherwise.

## pacman

Source: pacman v7.1.0 (commit 5683f847), read from source. Also pacman 7.1.0.r9.g54d9411-2, run in `archlinux:base` under podman with no network, with an `XferCommand` that logs each call. Date: 2026-10-14.

| behaviour | measured |
| --- | --- |
| downloads under an `XferCommand` | one file at a time, in order; 2 packages with `ParallelDownloads = 5` were fetched back to back |
| `ParallelDownloads`, server error limit | not used under an `XferCommand` |
| after a failed `XferCommand` call | `sleep(2)`, also for an optional `.sig`; 4 failing servers took 8.28 s |
| `SigLevel = Required DatabaseOptional`, no `.db.sig` on the server | 2.16 s for `-Sy` |
| `SigLevel = Required DatabaseNever` | no `.db.sig` request; 0.10 s for `-Sy` |
| `%o`, `%u` | replaced only when they are a whole argument |
| the `XferCommand` process | a direct child of the pacman main process; pacman waits only on its pid |
| the `XferCommand` under `DownloadUser` | uid switch and `NO_NEW_PRIVS` only; no Landlock, no seccomp; `CapEff` 0 |
| what it can write under `DownloadUser` | its `download-XXXXXX` directory (mode 0700) and `/tmp`; not the cache or sync directory |
| `download-XXXXXX` | one per operation: `-Syu` makes two |
| cleanup of `download-XXXXXX` | payload files and their `.sig` are moved out; other regular files are unlinked; a subdirectory makes the cleanup fail and the directory stays |
| a zero-byte `%o` under the sandbox | unlinked; the old file is kept; pacman exits 0 |
| a zero-byte `%o` with no sandbox | replaces the database; pacman exits 0 |
| `DownloadUser` with both sandbox parts off | the `XferCommand` runs as the download user in a root-owned directory: permission denied |
| `-Syy` with no `DownloadUser` | the database is deleted before the `XferCommand` runs |
| a database under an `XferCommand` | downloaded again on every `-Sy`: no If-Modified-Since |
| `pacman -Sp` | takes no lock and needs no root; `-Syp` needs root |
| `--print-format` | `%l` the first Server or `file://` when cached, `%h` sha256, `%s` download size (0 when cached), `%g` base64 `%PGPSIG%` |
| print mode | never prompts; takes the first provider |
| a cached package with required signatures and no cached `.sig` | the package and its `.sig` are downloaded again |
| native downloader, redirects | follows a 302 or 307 to another host; at most 10 redirects; `file://` refused |
| native downloader, 404 on an optional `.db.sig` | no error line and no pause (0.04 s) |
| native downloader, Range on resume | sent again to the redirect target; 206 completed the file |
| native `DownloadUser` sandbox in podman on WSL2, no `CAP_SYS_ADMIN` | fails: Landlock ruleset not applied |

| behaviour | date | source |
| --- | --- | --- |
| pacman on x86_64 with `Architecture = <arch>` downloads and checks another arch's packages | 2026-10-14 | `scripts/verify-batch` in `archlinux:base` |
| pacman 7.1 checks a package against `%PGPSIG%`, and still asks for its `.sig` and stores it unread | 2026-10-14 | pacman against the promoted x86_64 core |
| pacman 7.1 takes an expired primary key for a missing key: it asks a keyserver, then says "required key missing from keyring" | 2026-10-14 | the integration suite and loong64 extra |
| pacman 7.1 under an `XferCommand` names no file when a package's `.sig` cannot be served: only "failed to retrieve some files" | 2026-10-14 | the integration suite |

## GHCR

| fact | date | source |
| --- | --- | --- |
| `Authorization: Bearer QQ==` gives 200 on a public manifest and blob | 2026-10-13 | curl against ghcr.io |
| no Authorization header gives 401 with a Bearer challenge | 2026-10-14 | curl against ghcr.io |
| an unknown bearer gives 403 with no challenge | 2026-10-13 | curl against ghcr.io |
| `Bearer QQ==` for a repository that does not exist gives 404 `MANIFEST_UNKNOWN` | 2026-10-14 | curl against ghcr.io |
| a blob GET gives 307 to a signed URL on `pkg-containers.githubusercontent.com`; that URL needs no Authorization | 2026-10-13 | curl against ghcr.io |
| a Range request on a blob gives 206; a resumed download was byte-identical | 2026-10-14 | curl against ghcr.io, a 199 MiB blob |
| blobs are scoped per repository: another repository's blob gives 404 | 2026-10-13 | curl against ghcr.io |
| tags resolve with no regard to case: `latest`, `LATEST` and `Latest` name one manifest | 2026-10-13 | curl against ghcr.io |
| a reference of 129 characters gives 303 to an HTML page on github.com | 2026-10-14 | curl against ghcr.io |
| 30 manifest GETs at once all gave 200 | 2026-10-14 | curl `--parallel` against ghcr.io |
| a 200 carries no RateLimit or Retry-After header | 2026-10-14 | curl against ghcr.io |
| tag list: 100 per page by default; `n` is capped at 1000 | 2026-10-14 | curl against ghcr.io |
| a package that `GITHUB_TOKEN` creates from this public repository reads anonymously | 2026-10-14 | curl against ghcr.io |
| 299 of 299 pushes read back right on the first try | 2026-10-13 | the first sync of x86_64 core |
| 10 GB per layer and a 10-minute upload limit (documented); no rate limit documented | 2026-10-14 | GitHub docs, container registry |
| no REST endpoint changes a package's visibility (documented) | 2026-10-13 | GitHub REST API docs |
| oras 1.3.4 keeps the `created` annotation it is given: two writers pushed manifests of one digest, 3 of 3 | 2026-10-14 | the integration suite |
| pushes from runners got 429 `toomanyrequests` with "allowed: 2000/minute"; 4 targets x 3 shards x 6 pushes ran at once on one workflow token | 2026-10-14 | run 38570044665 |
| that limit bounds a seed to about 200 files a minute per token, whatever the parallelism | 2026-10-14 | run 38570044665 |

GHCR latency from one host. Host: Windows, Git Bash, curl 8.21.0 over HTTP/1.1, residential network in Nepal; GHCR answered from edge `centralindia`. Date: 2026-10-14.

| request | median |
| --- | --- |
| manifest GET, new connection (n=20) | 0.410 s |
| manifest GET, reused connection | 0.267 s |
| blob GET to the 307 only (n=10) | 0.392 s |
| blob GET, following the redirect (n=10) | 0.722 s |
| blob GET, reused connection | 0.569 s |
| 20 manifests with `--parallel` | 1.003 s in all |

## GitHub Actions and Pages

Source: GitHub docs, read from github/docs at commit d67ced72, and `gh api` reads of the organisation. Date: 2026-10-14.

| fact | value |
| --- | --- |
| organisation plan | Free; 619 public repositories |
| concurrent jobs, shared by every repository of the organisation | 20 |
| jobs per matrix | 256 |
| time per job on a GitHub-hosted runner | 6 hours |
| REST requests of `GITHUB_TOKEN` | 1000 per hour per repository |
| artifact retention in a public repository | 1 to 90 days; at most 500 artifacts per job |
| `ubuntu-24.04-arm` | free for public repositories: 4 vCPU, 16 GB RAM, 14 GB SSD |
| enabling Pages | needs an admin token; `GITHUB_TOKEN` has no administration permission |
| Pages limits | 1 GB per site, 10 minutes per deployment, 100 GB per month soft bandwidth |

| fact | date | source |
| --- | --- | --- |
| a job that calls a reusable workflow takes no `timeout-minutes` | 2026-10-14 | actionlint 1.7.12 |
| a dispatch input reaches an expression as a string; `max-parallel` refused it: "Unexpected value '4'" | 2026-10-14 | run 38569214434 |
| `keyring_image` with `create` and `cp` only, for `linux/loong64` and `linux/arm64`, worked on an amd64 runner | 2026-10-14 | run 38570044665 |
| a public-repository `ubuntu-24.04` runner starts with about 87 GB free on `/`; GitHub guarantees 14 GB | 2026-10-13 | runner image documentation |
| `scripts/debloat-runner` removed 12 of 12 directories in 45 s: 85 GiB free became 120 GiB | 2026-10-13 | a CI run on a runner |

## Cloudflare Workers

Source: Cloudflare pricing page (updated 2026-10-02) and limits page (updated 2026-10-12), documented.

| fact | value |
| --- | --- |
| Workers Paid | $5 per month per account, 10 million requests included, then $0.30 per million |
| CPU | 30 million CPU-ms included, then $0.02 per million CPU-ms |
| subrequests, egress | not billed |
| Cache API | per data centre, not replicated; objects up to 512 MB |
| `limits.cpu_ms` | a cap per invocation, enforced on Cloudflare only |

The Worker run locally. Source: `npx wrangler@4.150.0 dev --local` (workerd) against live GHCR, from the host in Nepal. Date: 2026-10-14.

| request | measured |
| --- | --- |
| `core.db`, cold | 0.53 to 0.88 s |
| `core.db`, repeat (one cache lookup) | 4 to 6 ms |
| a package, cold | 0.29 to 0.79 s (manifest about 260 ms, blob about 250 to 310 ms) |
| a package, repeat | 3 to 5 ms |
| a `.sig` asked 2 s after its package | 3 to 4 ms |
| a `.sig` asked about 50 ms after its package | 0.25 to 0.29 s: the prewarm lost the race by about 5 ms |
| `wrangler deploy --dry-run` | 14.08 KiB, gzip 4.69 KiB, no warnings |

| fact | date | source |
| --- | --- | --- |
| the deployed version 1 answered `core.db` with 302 in 1.05 to 1.33 s | 2026-10-14 | curl from the host in Nepal |
| 16 of 16 Worker probes passed; median 0.41 s | 2026-10-14 | `scripts/status-collect`, live |
| the GHCR `latest` manifest, read anonymously: median 0.43 s | 2026-10-14 | `scripts/status-collect`, live |

## Upstream

Source: each database downloaded from a `db_server` and read with `scripts/lib.sh` `db_records` and `db_validate`. The x86_64 core row comes from `scripts/status-collect`, live. Date: 2026-10-14.

| target | packages | total `%CSIZE%` (bytes) | GiB | largest file (bytes) | `%PGPSIG%` |
| --- | --- | --- | --- | --- | --- |
| x86_64-core | 299 | 1981090710 | 1.85 | not measured | 299 of 299 |
| x86_64-extra | 15041 | 115541940123 | 107.61 | 3290190315 | 15041 of 15041 |
| x86_64-multilib | 182 | 371948848 | 0.35 | 121321827 | 182 of 182 |
| aarch64-core | 313 | 1576463280 | 1.47 | 172772972 | 313 of 313 |
| aarch64-extra | 12994 readable of 12995 | 56935118832 | 53.02 | 3405583252 | 12994 of 12994 |
| aarch64-alarm | 75 | 142390596 | 0.13 | 35327900 | 75 of 75 |
| aarch64-aur | 12 | 10992812 | 0.01 | 6974820 | 12 of 12 |
| armv7h-core | 326 | 1622069404 | 1.51 | 172776152 | 326 of 326 |
| armv7h-extra | 12555 | 45784791156 | 42.64 | 3405570792 | 12555 of 12555 |
| armv7h-alarm | 125 | 190947120 | 0.18 | 35377156 | 125 of 125 |
| armv7h-aur | 11 | 10670656 | 0.01 | 6563988 | 11 of 11 |
| loong64-core | 295 | 1904375301 | 1.77 | 208134504 | 263 of 295; the other 32 have a detached `.sig` |
| loong64-extra | 14184 | 78262056692 | 72.89 | 3064267589 | 12965 of 14184; 1218 have a detached `.sig`, 1 has none |
| riscv64-core | 294 | 2121172682 | 1.98 | 208134524 | 9 of 294; the other 285 have a detached `.sig` |
| riscv64-extra | 14716 readable of 14717 | 89248639018 | 83.12 | 3290190302 | 80 of 14716; the other 14636 have a detached `.sig` |

| fact | date | source |
| --- | --- | --- |
| 15 targets: 71,422 upstream files, 395,704,667,230 bytes (368.5 GiB) | 2026-10-14 | `scripts/status-collect`, live |
| no target publishes `<repo>.db.sig` or `<repo>.files.sig`: 404 on every server tried | 2026-10-14 | curl on each `db_server` |
| 98 of 98 `db_server` and `server` URLs answered 200 for `<repo>.db` | 2026-10-14 | curl on each URL |
| aarch64 extra `findnewest-0.3-4/desc`: a GNU sparse member of 1271 NUL bytes; pacman lists it with every field None and cannot download it | 2026-10-14 | the database on every mirror; pacman 7.1 in the aarch64 image |
| riscv64 extra `ntk-1.3.1001-4/desc`: a GNU sparse member of 576 NUL bytes, on every current mirror | 2026-10-14 | the database on each mirror |
| Arch Linux ARM aarch64 `aur.files` leaves out `localepurge-0.7.3.4-1`, which `aur.db` names | 2026-10-14 | `scripts/plan` on the upstream databases |
| loong64 extra: pacman refuses `compiler-rt18-18.1.8-1`, `x11-ssh-askpass-1.2.4.1-8` and `yt6801-dkms-1.0.28-3` (keys expired) and `python-xarray-2026.07.0-1` (no signature anywhere) | 2026-10-14 | pacman 7.1 in `archlinux:base`, `Architecture = loong64` |
| loong64 extra: 16 packages are signed by a subkey that expires on 2026-12-31 | 2026-10-14 | the signature issuers |
| Arch Linux ARM: one key, `68B3537F39A313B3E574D06777193F152BDBE6A6`, made every signature of the 8 targets | 2026-10-14 | the signature issuers |
| Arch Linux RISC-V: every signature is by `B5971F2C5C10A9A08C60030F786C63F330D7CB92`, which is in `archlinux.gpg` | 2026-10-14 | the signature issuers |
| about 44000 filenames across nine databases, all `[A-Za-z0-9@._+:-]`; the longest is 92 characters | 2026-10-13 | the databases |
| x86_64 extra: 12 filenames have upper case and map to `fn-` tags; 15041 unique tags; the longest tag is 91 characters | 2026-10-14 | `client/pacman-oci --tags` |
| `%PGPSIG%`, base64 decoded, is byte-identical to the detached `.sig` | 2026-10-13 | the x86_64 core database |
| the newest `%BUILDDATE%` of a database is not monotonic: archived core of 10-02 and 10-03 share it, and so do 10-10 and 10-11 | 2026-10-13 | the Arch Linux archive |
| over eleven pairs of consecutive days (10-01 to 10-12), the newer core never had an older package | 2026-10-13 | the Arch Linux archive |
| a superseded file is gone from every Arch mirror within a day, in `os/` and `pool/` | 2026-10-13 | the mirrors |

## The pipeline

| fact | date | source |
| --- | --- | --- |
| first sync of x86_64 core: plan 25 s; 4 shards of 74 to 75 files, 53 s to 3 min 10 s; stage 35 s; verify 6.5 min | 2026-10-13 | the first run, on a branch |
| a single push ran at up to 34 MB/s | 2026-10-13 | the first run |
| the four upstream servers gave 75, 75, 75 and 74 files | 2026-10-13 | the first run |
| a sync with nothing new: every file present; shards took 12 to 17 s | 2026-10-13 | the second run |
| Sync run 38490975315: 8 min 40 s in all; plan script 2.7 s; mirror shards 6.56 to 12.80 s; stage 3.25 s; verify 426.3 s for 299 packages and 1888.10 MiB; promote 6.0 s | 2026-10-14 | the run's logs |
| the same verify step took 333 s and 443 s in two other runs | 2026-10-14 | runs 38435488665 and 38440550631 |
| a wrapper call in verify cost at most 0.56 s: 333 s for 598 calls, the image pull included | 2026-10-14 | run 38435488665 |
| verify jobs: loong64-core 82 s for 295 packages and 1.8 GB, its `batch` phase 24 s through the wrapper's prefetch; aarch64-aur 36 s; riscv64-core 67 s; x86_64-multilib 39 s | 2026-10-14 | run 38570044665, on GitHub runners |
| mirror time per file, first seed: 3.19 s plus 0.0328 s per MiB (n=299, `PARALLEL=4`) | 2026-10-14 | the first seed's results |
| `batch_count` on the x86_64 extra seed (15041 files, 115541940123 bytes): it wants 54 batches and grows the limits to 572 files and 3057647619 bytes, for 38 batches | 2026-10-14 | `scripts/lib.sh` `batch_count` |
| the plan artifact of x86_64 core: 2,451,850 bytes; a simulated x86_64 extra seed: 122.4 MB | 2026-10-14 | run 38490975315 and a simulation |
| `history.jsonl`: 1261 bytes per line for 15 targets, about 2.5 MB at 2000 lines | 2026-10-14 | `scripts/status-collect`, live |

## The wrapper

| fact | date | source |
| --- | --- | --- |
| 40 small packages through pacman, median of 8 runs, from Nepal: 3.8 s with 8 jobs, 7.8 s with 16, 3.0 s with 24, 2.7 s with 32 | 2026-10-14 | the comment above `PACMAN_OCI_JOBS` in `client/pacman-oci` |
| a connection to the blob host can stall: 150 small blobs on one HTTP/2 connection took 425 s and 440 s, and 4 to 6 s on a new connection | 2026-10-14 | a WSL2 VM in Nepal; the comment above `deadline` in `client/pacman-oci` |
| one 208 MB blob ran at 330 KB/s for 625 s | 2026-10-14 | the same |
| about 1 run in 4 of 40 small blobs sent at a few KB/s for 10 s or more; a normal run takes 1 to 2 s | 2026-10-14 | the same |
| a 3 s transfer limit, not 10 s, took a run of 40 small packages with a stall from 11 to 17 s down to 6.5 to 9 s | 2026-10-14 | the comment above `slice` in `client/pacman-oci` |
| one limit of 3 s plus 1 MiB/s for the whole file: 3 large packages (540 MB) took 238 s, where the official mirror took 40 s | 2026-10-14 | the same |
| version 1, 40 files driven directly: 75.1 s with 1 job, 20.1 s with 4, 17.1 s with 8, 13.8 s with 16 | 2026-10-14 | the Windows host in Nepal |
| the decoded `%PGPSIG%` equalled the served `.sig` for 20 of 20 packages | 2026-10-14 | x86_64 core |
| version 1 against a registry that does not answer: a file failed after 35.35 s (three 10 s connect timeouts) | 2026-10-14 | a blackholed address |
| version 1 with `PACMAN_OCI_NO_DUMMY=1`: 4 requests per file (manifest 401, token, manifest 200, blob), 3.0 s | 2026-10-14 | the Windows host in Nepal |
| version 1, the first promoted core as the only Server, from a residential network: `pacman -Sy` 4.0 s, `pacman -S nano` 5.1 s | 2026-10-14 | a stock Arch pacman |

## Bench

Source: `scripts/bench-consumer`, with `client/pacman-oci` version 2. Host: "Ajam (Linux x86_64), in archlinux:base through podman". pacman 7.1.0.r9.g54d9411-2. Date: 2026-10-14T12:38:28Z.

Each case uses `ParallelDownloads = 5` and `SigLevel = Required DatabaseNever`. `sy` is `pacman -Sy` into an empty database path. `sw-small` is `pacman -Swdd` of the 40 smallest core packages, and `sw-large` of the 3 largest. The file counts include the signatures. Seconds is the median of 3 rounds.

| path | op | seconds | rounds | files | bytes | ok |
| --- | --- | --- | --- | --- | --- | --- |
| official | sy | 0.727 | 0.539, 0.743, 0.727 | 1 | 130359 | yes |
| official | sw-small | 4.853 | 6.442, 2.639, 4.853 | 80 | 665107 | yes |
| official | sw-large | 55.077 | 55.077, 42.611, 63.287 | 6 | 539912381 | yes |
| worker | sy | 2.238 | 3.502, 1.484, 2.238 | 1 | 130359 | yes |
| worker | sw-small | 10.552 | 14.476, 8.622, 10.552 | 80 | 665107 | yes |
| worker | sw-large | 49.173 | 261.048, 49.173, 35.617 | 6 | 539912381 | no |
| oci | sy | 1.615 | 2.016, 1.615, 1.596 | 1 | 130359 | yes |
| oci | sw-small | 2.735 | 2.735, 6.756, 2.592 | 80 | 665107 | yes |
| oci | sw-large | 72.612 | 72.612, 77.378, 38.745 | 6 | 539912381 | yes |
| oci-serial | sy | 1.574 | 2.056, 1.153, 1.574 | 1 | 130359 | yes |
| oci-serial | sw-small | 126.064 | 142.665, 121.073, 126.064 | 80 | 665107 | yes |
| oci-serial | sw-large | 348.617 | 71.521, 860.701, 348.617 | 6 | 539912381 | yes |

`official` is `geo.mirror.pkgbuild.com` with pacman's downloader. `worker` is the Worker with pacman's downloader. `oci` is the wrapper with its prefetch, and `oci-serial` the wrapper with `PACMAN_OCI_PREFETCH=0`. `ok` is no when a round failed or downloaded another number of files.

## Tools and images

| fact | date | source |
| --- | --- | --- |
| oras 1.3.4: the sha256 of each archive, from the release's `checksums.txt` | 2026-10-13 | `scripts/install-oras` |
| ShellCheck 0.11.0, actionlint 1.7.12, jq 1.8.2: release checksum lists and GitHub asset digests agreed | 2026-10-13 | `scripts/install-test-tools` |
| curl 8.22.0 (stunnel/static-curl), musl static: the GitHub asset digest, the release notes and `SHA256SUMS` agreed | 2026-10-14 | `scripts/install-test-tools` |
| bash 5.2.21-2ubuntu4 (Ubuntu noble `bash-static`, release pocket): the Packages index and Launchpad agreed | 2026-10-14 | `scripts/install-test-tools` |
| `docker.io/library/node:24-alpine` is `lts-alpine`, digest `sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1`, node v24.21.0 | 2026-10-14 | Docker Hub |
| `node --test worker/test/` fails on node 26.7.0; the quoted glob works on node 22, 24 and 26 | 2026-10-14 | node in containers |
| the integration suite `10-pipeline.sh`: 98 of 98 in 314 to 490 s, in a 10-vCPU WSL VM with podman | 2026-10-14 | `tests/run.sh integration` |
| the static suite: about 40 s in a container | 2026-10-14 | `tests/run.sh static` |
