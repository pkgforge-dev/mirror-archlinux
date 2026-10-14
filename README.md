# mirror-archlinux

Arch Linux and three of its ports, stored on GHCR and checked by pacman before each snapshot is published.

[![all](https://pkgforge-dev.github.io/mirror-archlinux/badges/all.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![x86_64](https://pkgforge-dev.github.io/mirror-archlinux/badges/x86_64.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![aarch64](https://pkgforge-dev.github.io/mirror-archlinux/badges/aarch64.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![armv7h](https://pkgforge-dev.github.io/mirror-archlinux/badges/armv7h.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![loong64](https://pkgforge-dev.github.io/mirror-archlinux/badges/loong64.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![riscv64](https://pkgforge-dev.github.io/mirror-archlinux/badges/riscv64.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)
[![speed](https://pkgforge-dev.github.io/mirror-archlinux/badges/speed.svg)](https://pkgforge-dev.github.io/mirror-archlinux/)

![Share of upstream files in the mirror, per target](https://pkgforge-dev.github.io/mirror-archlinux/charts/coverage.svg)

![Snapshot age per target, against the sync interval](https://pkgforge-dev.github.io/mirror-archlinux/charts/freshness.svg)

The dashboard is at <https://pkgforge-dev.github.io/mirror-archlinux/>. It shows every target, the history of the last 30 days and the daily speed measurement.

## Use the mirror

There are three ways to read the mirror. Each way reads the same snapshots. Pick one per machine.

### 1. The Worker, with pacman's own downloader

Add the Worker as the first Server of each repository in `/etc/pacman.conf`:

```ini
[core]
Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

The Worker sends no package bytes. It answers a request for a file with a redirect to GitHub's blob host. pacman uses its own downloader, so `ParallelDownloads` and resume work as for any mirror.

### 2. The registry, with the wrapper

Install the wrapper:

```bash
curl -fsSL --connect-timeout 10 --max-time 120 -o /usr/local/bin/pacman-oci \
  https://raw.githubusercontent.com/pkgforge-dev/mirror-archlinux/main/client/pacman-oci
chmod 0755 /usr/local/bin/pacman-oci
```

⚠ An `XferCommand` replaces pacman's own downloader for every Server of every repository. The wrapper then fetches every URL that is not `oci://` with curl.

Set the wrapper as the `XferCommand`, and add the registry as the first Server:

```ini
[options]
XferCommand = /usr/local/bin/pacman-oci %o %u

[core]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

The wrapper reads the registry directly. It asks pacman for the whole download list once per run and fetches it in parallel. [docs/client.md](docs/client.md) tells how.

### 3. Both, in fallback order

```ini
[options]
XferCommand = /usr/local/bin/pacman-oci %o %u

[core]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo
Server = https://ghcr.mirror.archlinux.pkgforge.dev/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

pacman tries each Server in turn when a file is not found. Keep `oci://` first: the prefetch reads only the first Server of each repository. The Worker reads the same GHCR repository, so it is a second path to the same snapshot, not a second copy.

### An absent database signature

⚠ Under an `XferCommand`, pacman pauses 2 s after each failed download, also for an optional `<repo>.db.sig`. No upstream of this mirror publishes a database signature.

With `DownloadUser` set (stock Arch) and pacman 7.0 or 7.1, the wrapper answers an absent database signature with an empty file. pacman removes that file and reads the signature as absent, with no pause. `PACMAN_OCI_EMPTY_SIG=0` turns this answer off.

With no `DownloadUser`, or with another pacman version, add this line to each `oci://` repository section:

```ini
SigLevel = Required DatabaseNever
```

pacman then asks for no database signature and still checks every package signature. `SigLevel` applies to every Server of the section, the mirrorlist too.

⚠ With `DownloadUser` set, do not turn off both parts of pacman's sandbox (`DisableSandbox`, or `DisableSandboxFilesystem` with `DisableSandboxSyscalls`). pacman then runs the `XferCommand` as the download user in a root-owned directory, and every download fails.

### Pin a snapshot

⚠ Pin by digest when a build must give the same result later. `latest` moves with upstream. The wrapper and the Worker check the hash of a digest. Nothing checks what a tag names.

| Server form | Snapshot | `oci://` (wrapper) | `https://` (Worker) |
| --- | --- | --- | --- |
| `.../$arch/$repo` | `latest`: follows upstream | yes | yes |
| `.../$arch/$repo:latest` | the same | yes | yes |
| `.../$arch/$repo:YYYY.MM.DD` | the first promoted snapshot that was fetched on that UTC date; it never moves | yes | yes |
| `.../$arch/$repo:db-HEX` | the snapshot whose `<repo>.db` has sha256 HEX | yes | yes |
| `.../$arch/$repo:files-HEX` | the snapshot whose `<repo>.files` has sha256 HEX | yes | yes |
| `.../$arch/$repo@sha256:HEX` | one manifest. ⭐ The wrapper and the Worker hash it and refuse a manifest that is not HEX | yes | yes |
| `.../$arch/$repo:staging` and any other tag | a snapshot that is not verified yet, or not a snapshot | yes | no: 404 |

A digest is the digest of one repository's manifest. Write a pinned Server line in each repository section, with that repository's digest:

```ini
[core]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo@sha256:<digest of the core manifest>
```

Read the digest that `latest` names now:

```bash
curl -sI --connect-timeout 10 --max-time 30 \
  -H 'Authorization: Bearer QQ==' -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/pkgforge-dev/mirror-archlinux/x86_64/core/manifests/latest | grep -i docker-content-digest
```

### What each way does and costs

| | 1. Worker | 2. Wrapper |
| --- | --- | --- |
| Downloader | pacman's own | `client/pacman-oci`, one call per file |
| Parallel downloads | `ParallelDownloads` | one package prefetch and one database prefetch per run: up to 32 transfers at once (`PACMAN_OCI_JOBS`), then one rename per file |
| Package signature | the registry's `.sig` layer, through a redirect | decoded from the database's `%PGPSIG%` with no request, else the registry's layer |
| Resume | pacman's own | `--continue-at -`, then a sha256 check |
| A host that fails | pacman's server error limit | skipped for the rest of the run, never for a `.sig` |
| Absent `<repo>.db.sig` | a 404 with no pause | an empty file under the sandbox (pacman 7.0, 7.1), else a 2 s pause |
| Sandbox, with `DownloadUser` | pacman's own (Landlock, seccomp) | uid switch and `NO_NEW_PRIVS` only |
| Programs on the host | none | `curl`, `awk`, `sed`, `grep`, `sha256sum`, `mktemp`, `base64` |
| Reads from | the Worker, then GitHub's blob host | GHCR, then GitHub's blob host |
| Trust root | GitHub, this repository, the Worker and its Cloudflare account | GitHub and this repository |

The measured times of each way are in [docs/measurements.md](docs/measurements.md). The Worker is described in [docs/worker.md](docs/worker.md).

## Targets

A target is one repository of one architecture. The table comes from `targets/*.conf`. The Server path goes after `oci://ghcr.io/pkgforge-dev/mirror-archlinux/` or after `https://ghcr.mirror.archlinux.pkgforge.dev/`.

| arch | repo | upstream distribution | keyring packages | Server path |
| --- | --- | --- | --- | --- |
| x86_64 | core | Arch Linux | archlinux-keyring | `x86_64/core` |
| x86_64 | extra | Arch Linux | archlinux-keyring | `x86_64/extra` |
| x86_64 | multilib | Arch Linux | archlinux-keyring | `x86_64/multilib` |
| aarch64 | core | Arch Linux ARM | archlinuxarm-keyring | `aarch64/core` |
| aarch64 | extra | Arch Linux ARM | archlinuxarm-keyring | `aarch64/extra` |
| aarch64 | alarm | Arch Linux ARM | archlinuxarm-keyring | `aarch64/alarm` |
| aarch64 | aur | Arch Linux ARM | archlinuxarm-keyring | `aarch64/aur` |
| armv7h | core | Arch Linux ARM | archlinuxarm-keyring | `armv7h/core` |
| armv7h | extra | Arch Linux ARM | archlinuxarm-keyring | `armv7h/extra` |
| armv7h | alarm | Arch Linux ARM | archlinuxarm-keyring | `armv7h/alarm` |
| armv7h | aur | Arch Linux ARM | archlinuxarm-keyring | `armv7h/aur` |
| loong64 | core | Arch Linux for Loong64 (LCPU) | archlinux-keyring, archlinux-lcpu-keyring | `loong64/core` |
| loong64 | extra | Arch Linux for Loong64 (LCPU) | archlinux-keyring, archlinux-lcpu-keyring | `loong64/extra` |
| riscv64 | core | Arch Linux RISC-V | archlinux-keyring | `riscv64/core` |
| riscv64 | extra | Arch Linux RISC-V | archlinux-keyring | `riscv64/extra` |

pacman checks each package against the keyring of its distribution. A consumer needs that keyring in its own pacman keyring. The badges show which targets have a promoted snapshot.

## How the mirror works

`.github/workflows/sync.yml` runs every 3 hours. Each target with work runs its own chain (`.github/workflows/sync-target.yml`), so one target never holds another.

1. **plan** (`scripts/plan`) reads each database from the distribution's own servers only. It refuses a database that is malformed or behind the promoted one, and puts the new files into shards per target.
2. **mirror** (`scripts/mirror-shard`, `scripts/mirror-file`) downloads each new file from any listed server. It checks size and sha256, then pushes the file with its signature under a tag of its own.
3. **stage** (`scripts/stage`) pushes the database under a staging tag once every file it names is on the registry. It reads the database back and splits the new files into verify batches.
4. **verify** (`scripts/verify-batch`) runs pacman in the x86_64 Arch image with the wrapper as its `XferCommand`. pacman downloads every new file and checks its sha256 and signature.
5. **promote** (`scripts/promote`, branch `main` only) tags the staged digest: the date tag once, `db-HEX`, `files-HEX`, then `latest`. `latest` never moves backwards.
6. **report** (`scripts/report`) writes one table for the run. On `main`, it keeps the `visibility-` and `replaced-` issues current, then starts the status workflow.
7. **status** (`scripts/status-collect`, `scripts/status-render`, every hour) measures each target against upstream and against the Worker. It publishes the dashboard, the badges and the charts.

[docs/design.md](docs/design.md) gives each rule and the failure it prevents.

## Trust and checks

⛔ A database reaches `latest` only after every file it names is on the registry. Every file new since the promoted database must also pass pacman's own checks through the wrapper.

- The database comes only from the `db_server` hosts of the target, which the distribution runs. These databases are unsigned. The source of a database chooses which validly signed packages get installed.
- The wrapper checks each file it reads from the registry before pacman sees it:
  1. A manifest asked for by digest must hash to that digest.
  2. Exactly one layer must carry the name pacman asked for.
  3. The blob's size and sha256 must equal that layer's descriptor, or the database's `%SHA256SUM%`.
- pacman then checks each package's sha256 against the database, and each signature against the keyring.
- Push access to this repository is the trust root of the registry: any workflow on any branch can ask for `packages: write`. Every workflow starts from `permissions: {}`. Only `main` promotes. Actions are pinned by commit.
- The Worker and its Cloudflare account join the trust root for the consumers of ways 1 and 3. Whoever can change the Worker can change the database a consumer gets.
- Renovate pushes its own branches, so it holds the same trust. Its small updates merge when CI is green. ⚠ The keyring images of the targets and every major update wait for a person.

## Add a target

1. Write `targets/<arch>-<repo>.conf`, where `<arch>` is pacman's `$arch`. Use `key = value` lines and `#` comments.
2. Run `tests/run.sh static 60-targets`.
3. Make sure `sync.yml` has a plan upload slot for each enabled target. There are 16 slots.
4. Start a run for the target: `gh workflow run sync.yml -f targets=<arch>-<repo>`.

| key | count | grammar | meaning |
| --- | --- | --- | --- |
| `arch` | 1, required | `[a-z0-9]+(_[a-z0-9]+)*` | pacman's `$arch`; the file name starts with it |
| `repo` | 1, required | `[a-z0-9]+([.-][a-z0-9]+)*` | the repository; the file name ends with it |
| `db_server` | 1 or more, required | an `https://` URL; `$arch` and `$repo` are expanded | the distribution's own servers, tried in order; the database comes only from these |
| `server` | 0 or more | an `https://` URL; `$arch` and `$repo` are expanded | more sources of package bytes, after the db_servers |
| `verify_image` | 1, required | `name:tag@sha256:<64 hex>` under a `# tag: <tag>` line | the image pacman verifies in: the one x86_64 Arch image of every target |
| `verify_platform` | 1, required | `linux/amd64` | the platform of `verify_image` |
| `keyring` | 0 or 1 | package names, space separated, each `[a-z0-9@_+][a-z0-9@._+-]*` | keyring packages that verify installs before it checks anything |
| `keyring_from` | 0 or 1 | `<arch>-<repo>`: an enabled target of the same arch, not this one | the target whose `latest` holds the keyring packages; needs `keyring` |
| `keyring_image` | 0 or 1 | `ghcr.io/pkgforge-dev/archlinux:tag@sha256:<64 hex>` under a `# tag: <tag>` line | an image whose `/usr/share/pacman/keyrings/*` adds to the trust root of verify |
| `keyring_platform` | 1 with `keyring_image` | `linux/<arch>` or `linux/<arch>/v<n>` | the platform to pull `keyring_image` for |
| `enabled` | 0 or 1 | `yes` or `no`; default `yes` | `no` leaves the target out of the scheduled sync, the status page and the watchdog |
| `db_signed` | 0 or 1 | `yes` or `no`; default `no` | `yes`: plan requires `<repo>.db.sig` and `<repo>.files.sig`, and verify uses `DatabaseRequired` |

An unknown key is an error. A key of count 0 or 1 may not repeat. `scripts/lib.sh` `target_check` and `tests/static/60-targets.sh` apply these rules. ⚠ Neither one checks the value of `enabled`. A value other than `yes` or `no` stops `plan`, `status-collect` and `check-staleness` when they read it.

The first push creates the GHCR package. If the package is private, the run opens `visibility-<target>` with the settings link. GitHub has no API to change the visibility, so a person makes it public.

## Tests

```bash
scripts/install-test-tools /tmp/mirror-archlinux-tools
PATH="/tmp/mirror-archlinux-tools:$PATH" tests/run.sh static
tests/run.sh unit
CONTAINER_RUNTIME=podman tests/run.sh integration
tests/run.sh worker
WORKER_LIVE=1 tests/run.sh worker live
```

`tests/run.sh all` runs the four suites in turn. [docs/tests.md](docs/tests.md) tells what each suite needs and lists the tests seen to fail.

## Maintenance

These run by themselves:

- Sync every 3 hours. Status, with the Worker check, every hour. The staleness and schedule checks every day.
- The scheduled workflows start each other when a newest run is overdue, and keep every schedule enabled.
- Renovate merges digest, pin, patch and minor updates when every check is green.
- `worker.yml` deploys the Worker after a push to `main` that changes `worker/`, when the `CLOUDFLARE_API_TOKEN` secret is set.

These issues open by themselves. Each one opens once, keeps its body current, and closes when the problem clears:

| issue | raised when | raised by |
| --- | --- | --- |
| `visibility-<target>` | the package reads only with the workflow's token | `scripts/report` |
| `replaced-<target>` | a package tag holds other bytes than the database names | `scripts/report` |
| `stale-<target>` | `latest` differs from upstream for longer than the tolerance, 3 days for the 3-hour cron | `watchdog.yml` (`scripts/check-staleness`) |
| `worker-down` | the Worker failed its probe in 2 status runs in a row | `status.yml` |

These need a person:

- Make a private package public, with the link in its `visibility-` issue.
- Decide each `replaced-` issue: wait for a new upstream filename, or accept the new bytes.
- Review and merge the keyring image updates and the major updates from Renovate.
- Enable Pages once: `gh api -X POST repos/pkgforge-dev/mirror-archlinux/pages -f build_type=workflow`.
- Set the `CLOUDFLARE_API_TOKEN` secret to deploy the Worker. Without it, nothing is deployed.
- Start a workflow by hand when every schedule stops at once. GitHub stops the schedules of a repository after 60 days with no activity.

[docs/operations.md](docs/operations.md) has the schedules, the issues and the settings in full.

## Documents

| document | contents |
| --- | --- |
| [docs/design.md](docs/design.md) | the invariant, the rules, the storage layout, the jobs, verify |
| [docs/client.md](docs/client.md) | the wrapper: run store, prefetch, single-file path, environment, exit codes |
| [docs/worker.md](docs/worker.md) | the Worker: paths, references, caching, cost, deploy, trust |
| [docs/operations.md](docs/operations.md) | workflows, schedules, issues, Renovate, secrets, Pages, the status branch |
| [docs/measurements.md](docs/measurements.md) | measured facts, each with its date and source |
| [docs/tests.md](docs/tests.md) | the suites, how to run them, the tests seen to fail |
| [docs/conventions.md](docs/conventions.md) | the code and text conventions |
