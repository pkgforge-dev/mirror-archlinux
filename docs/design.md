# Design

This document gives the invariant of the mirror, each rule with the failure it prevents, the storage layout, the jobs and the verify step. The measurements behind the rules are in [measurements.md](measurements.md).

## The invariant

⛔ A database reaches `latest` only after every file it names is on the registry. Every file new since the promoted database must also pass pacman's own checks through the wrapper.

Each rule below keeps this invariant true for one way it could fail.

## Rules, and the failure each one prevents

| rule | failure it prevents | where |
| --- | --- | --- |
| The database comes only from the target's `db_server` hosts, which the distribution runs. Package bytes can come from any `server`. | The databases are unsigned. The source of a database chooses which validly signed packages get installed, old ones too. | `scripts/plan` |
| Every field of a database is checked against its grammar first. A filename with `/`, a space, a leading `-` or `.`, a control character or a byte above 0x7e refuses the whole database. | A hostile name becomes a path, an option or a tag. | `scripts/lib.sh` `db_validate` |
| Each package directory gives exactly one record. A `desc` member of NUL bytes only, or empty, is counted and named; at most 16 are accepted. Any other unreadable member refuses the database. | A database that drops packages without a word. An upstream sparse member that holds a target for ever. | `scripts/lib.sh` `db_check` |
| Each (file, sha256) pair of `<repo>.files` must be in `<repo>.db`. A files database that names another pair is refused, and plan tries the next `db_server` that served the same database. A files database that leaves packages out is accepted, and plan names them. | A files database that describes other packages makes `pacman -F` wrong. A refusal of a files database that only knows less holds the target for an upstream defect that upstream's own users also get. | `scripts/plan` |
| Never behind: a candidate is dropped when one of its packages was built before the same package in the promoted database or in another candidate. `ALLOW_OLDER` lifts the first comparison. | A lagging server rolls consumers back to older builds. | `scripts/plan` |
| A candidate with no package built later than in the promoted database waits while a `db_server` still serves the promoted database. A candidate that only adds or drops packages is one. `ALLOW_OLDER` lifts this wait too. | A server that lags by one dropped package moves `latest`. | `scripts/plan` |
| `latest` never moves backwards. Just before it tags, promote reads the `fetched` time of the snapshot `latest` names, and refuses a staged snapshot fetched earlier. | A re-run, or a second writer, rolls consumers back. | `scripts/promote` |
| ⛔ A package tag is written once. A tag that holds other bytes under a name is never written again. The target's state is `replaced`, and on `main` the `replaced-<target>` issue opens. | The promoted or an older snapshot names those bytes. pacman refuses a file whose sha256 it does not expect, and tries no other Server. | `scripts/lib.sh` `decide_push`, `scripts/mirror-file` |
| A signature layer that is missing or wrong beside the right package bytes is repaired: the file is pushed again with the same package blob. plan skips a file only when its sha256 and its `%PGPSIG%` equal the promoted record. | A file that upstream signs again keeps a stale signature layer for ever. | `scripts/plan`, `scripts/mirror-file` |
| A package never lacks its signature when the database has one. The layer is the decoded `%PGPSIG%`. With no `%PGPSIG%`, it is the detached `.sig`, which must be one OpenPGP signature packet under 64 KiB. Any other answer is an error, not an absence. A file is pushed unsigned only when every server answers 404 for its `.sig`. | pacman asks for a `.sig` only from the server that served the package. A missing `.sig` ends the install. | `scripts/mirror-file` |
| With no `%PGPSIG%`, mirror-file reads the `.sig` from the target's servers in their own order, the `db_server` hosts first. verify compares with the same order. Only package files are read in an order rotated by shard. | A plain mirror that serves other `.sig` bytes gives the layer, verify refuses it, and the target fails on every run. | `scripts/mirror-file` |
| A file pushed unsigned is named in the staged manifest, in `dev.pkgforge.mirror.unsigned`. plan asks for its `.sig` again on each run. When a server answers, plan puts the file in todo, also when the database did not change, and mirror-file adds the layer. | A `.sig` that upstream publishes later never reaches the mirror. A detached-signature database does not change when a `.sig` is added. | `scripts/stage`, `scripts/plan` |
| Every upstream read has a stall deadline. A database or a signature read has a whole-call deadline that also bounds its retries: `--retry-max-time`, and `timeout` 5 s after it. A package download gets 120 s plus the time at 64 KiB/s. | curl gives each retry a new `--max-time`: a call took 3 x the deadline + 4 s. | `scripts/lib.sh` `fetch_upstream` |
| The upstream reads of plan end within `PLAN_BUDGET` (1200 s), below the job's 30 minutes. Each target gets what is left, divided by the targets not yet read. A `db_server` read gets 1/(n + 1) of the target's share, with n the `db_server` hosts not yet read. A target whose reads do not fit is in error for the run, and its why names `PLAN_BUDGET`. | One slow upstream server makes the plan job time out, and no target is mirrored or promoted. | `scripts/plan` |
| A server that fails for one file of a shard is asked last by every file of the shard after it: a timeout, a failed connection, or a status other than 200, 404 and 410. A `.sig` read ends within 30 s. | A server that stalls costs each file of the shard 184 s, also a file the registry holds. The shard never ends inside its step. | `scripts/mirror-file`, `scripts/lib.sh` `down_mark` |
| The token cache keeps only a token got with `REGISTRY_TOKEN`. A read with `REGISTRY_TOKEN` empty never uses the cache. | On a registry other than GHCR, stage's anonymous read sends the workflow's token. A private package reads as public and is promoted. | `scripts/lib.sh` `registry_token_file` |
| Every artifact that a chain makes carries the plan id (`scripts/plan`). stage reads only the shard results of its plan. The report reads only the summaries of its plan, and only for a target the plan marks pending. collect reads only the verdicts and the promotion of the staged digest. | "Re-run all jobs" plans again, and a download by name or pattern still returns the earlier attempt's artifacts. A stale result holds a target, or a stale summary raises an issue again. | `scripts/stage`, `scripts/report`, `scripts/mirror-shard` |
| Verify compares every `.sig` pacman stored with the decoded `%PGPSIG%`. | pacman checks against `%PGPSIG%` and stores the served `.sig` unread. A wrong layer passes verify and breaks a later `pacman -U` from the cache. | `scripts/verify-batch` |
| Package manifests are the same bytes whoever pushes them. `org.opencontainers.image.created` is the package's `%BUILDDATE%`, and no annotation names the source server. | Two writers replace each other's tag with a manifest of another digest. | `scripts/mirror-file` |
| Absent means the registry says so: only a 404 with `NAME_UNKNOWN` or `MANIFEST_UNKNOWN`. On GHCR, with a token set, a read tries `Bearer QQ==` first, and only its 200 counts. Any other answer is read again with the real token. | GHCR answers `QQ==` with 404 for a repository it does not show. A private package reads as absent, and its tags are pushed over. | `scripts/lib.sh` `registry_manifest` |
| A file that upstream supersedes during a run holds the target for that run. A file that never succeeds holds its target until upstream drops or rebuilds it. | A database is staged that names a file the registry does not hold. | `scripts/stage` |
| Each target runs its own chain and reads only its own artifacts. Every artifact name carries the target. A chain reads its shard results and verdicts by the pattern `<kind>-<target>-[0-9]*`. So a target name that extends another target name with a letter never matches. ⚠ An extension that starts with `-` and a digit, as in `x86_64-core-2`, still matches. | One slow or failed target holds every other target. A chain reads the verdicts of another target. | `.github/workflows/sync-target.yml` |
| A push attempt gets 300 s plus the time at `MIRROR_MIN_RATE` (2 MiB/s), and never more than 600 s. | Attempts run past GHCR's 10-minute upload limit and are lost. | `scripts/mirror-file` |
| A 429 from the registry costs no attempt. Each push that gets one writes `$WORK/throttle`, the time its pause of 20 to 60 s ends. Every push of the shard waits for that time first. The pauses that one file takes after its own 429s add up to at most `MIRROR_RATE_WAIT` (1800 s). | GHCR limits the requests of one token, and every push of every job shares the workflow token. Three attempts, 5 s and 20 s apart, all fall inside the limit, and the file fails. | `scripts/mirror-file` |
| Each item of a shard writes its result line the moment it ends. A work line with no result counts as failed. | A shard that runs out of time loses the results of the files it pushed. | `scripts/mirror-shard`, `scripts/mirror-file` |
| The verify budgets nest. The pulls and the container end inside `VERIFY_BUDGET` (4800 s). That ends inside the step's 85 minutes, which end inside the job's 95. The verdict is written by an EXIT trap. | The runner ends the job, and no verdict is left. | `scripts/verify-batch`, `sync-target.yml` |
| The verify container asks no keyserver: its `gpg.conf` names `hkp://127.0.0.1:9`, which refuses at once. | A missing or expired key makes verify wait on a host outside the run. | `scripts/verify-batch` |
| No exit is silent. Each script that sources `scripts/lib.sh` has an ERR trap that names the command which ended it. No pipeline ends in a reader that stops early. | A step ends with status 141 (SIGPIPE) and no message. | `scripts/lib.sh`, `tests/static/35-pipeline-traps.sh` |

## Storage layout

```
ghcr.io/pkgforge-dev/mirror-archlinux/<arch>/<repo>
  :<escaped filename>        one package: the file and its signature
  :staging                   the candidate database of the run on main
  :staging-<branch>          the candidate database of a run from another branch
  :latest                    the promoted database
  :YYYY.MM.DD                the first promoted database fetched on that UTC date; never moves
  :db-<sha256 of <repo>.db>          the promoted database by its content
  :files-<sha256 of <repo>.files>    the same, by the files database
```

`<arch>` is pacman's `$arch`. One GHCR repository holds one target. Nothing is ever deleted: `tests/static/50-workflow-policy.sh` refuses every use of the packages DELETE API.

`<branch>` is the branch name in lower case. Each character other than `a-z` and `0-9` becomes `-`, a run of `-` becomes one, and a leading or trailing `-` is removed. Then the name is cut to 40 characters. An empty result is `branch`.

## Tags

A package tag is the filename with this mapping:

- `+` becomes `_p`, `:` becomes `_c` and `@` becomes `_a`.
- A literal `_` becomes `_u` only when the next character is `p`, `c`, `a` or `u`. So `x86_64` stays `x86_64`, and the mapping is injective.

GHCR resolves tags with no regard to case, so every tag is lower case. Some filenames are stored under `fn-` and the hex sha256 of the name. These are a name with upper case or another character outside `[a-z0-9@._+:-]`, and a name that the mapping cannot carry in 128 characters. That form has no dot. Every escaped package name has `.pkg.tar`. So the two forms never meet, and neither meets `latest`, `staging`, a date, `db-` or `files-`.

The mapping has one implementation: `client/pacman-oci --tag` and `--tags`. The scripts call it. The Worker has a copy, `tagOf`. `worker/test/tags.test.js` compares the two for every name in `tests/fixtures/filenames.txt`.

## Manifests

A package manifest:

- artifact type `application/vnd.pkgforge.archlinux.package.v1`
- layer 0: the package, `application/vnd.pkgforge.archlinux.pkg.v1`, titled with its filename
- layer 1: its signature, `application/pgp-signature`, titled `<filename>.sig`, when the file has one
- annotations: `org.opencontainers.image.created` (the `%BUILDDATE%`), `org.opencontainers.image.source`, `org.opencontainers.image.title`, and `dev.pkgforge.mirror.arch`, `.repo`, `.pkgname`, `.sha256`

A database manifest:

- artifact type `application/vnd.pkgforge.archlinux.db.v1`
- layers `<repo>.db` (`application/vnd.pkgforge.archlinux.db.v1`) and `<repo>.files` (`application/vnd.pkgforge.archlinux.files.v1`), byte for byte as upstream serves them
- a `<repo>.db.sig` and a `<repo>.files.sig` layer, only when upstream publishes them
- annotations: `dev.pkgforge.mirror.arch`, `.repo`, `.upstream` (the server), `.db-sha256`, `.files-sha256`, `.packages`, `.bytes`, `.newest-builddate`, `.fetched` (ISO 8601 UTC), `.run`, and the OCI `source`, `title` and `revision`
- `dev.pkgforge.mirror.unsigned`, only when a file has no signature because upstream publishes none: the filenames, space separated, at most 16 KiB

## Jobs

`.github/workflows/sync.yml` runs on the cron `17 */3 * * *` and on dispatch.

| job | permissions | timeout (min) | does |
| --- | --- | --- | --- |
| `plan` | contents read, packages read | 30 | `scripts/plan` for every enabled target, or for the targets of the `targets` input, within `PLAN_BUDGET` (1200 s) of upstream reads; uploads `plan-<target>` for each pending target |
| `target` | contents read, packages write | (each called job has its own) | one call of `sync-target.yml` per pending target, at most `max_targets` (4) at once |
| `report` | actions write, contents read, issues write | 10 | `scripts/report`; on `main` it starts `status.yml` |
| `keepalive` | actions write, contents read | 10 | `keep-schedules-enabled`, `check-schedules-fired`, and `dispatch-overdue status.yml 120` on `main` |

`.github/workflows/sync-target.yml` is the chain of one target:

| job | permissions | timeout (min) | does |
| --- | --- | --- | --- |
| `mirror` | contents read, packages write | 120 (step 110) | `scripts/mirror-shard` per shard, at most `max_shards` (3) at once |
| `stage` | contents read, packages write | 20 | `scripts/stage` for the target |
| `verify` | contents read | 95 (step 85) | `scripts/verify-batch` per batch, at most `max_batches` (3) at once |
| `promote` | contents read, packages write | 15 | `scripts/promote`, on `main` only |
| `summary` | contents read | 10 | `scripts/report collect`: a small `summary-<target>` artifact for the report |

All runs share one concurrency group, `sync`, on every ref. Two runs never write the same tags at once.

The dispatch inputs are `targets`, `max_targets` (4), `max_shards` (3), `max_batches` (3), `parallel` (6 files at once in a shard), `debloat` (`auto`, `always`, `never`) and `allow_older`.

A dispatch input reaches an expression as a string. `max-parallel` and a number input of a called workflow refuse a string. So `sync.yml` passes each number input through `fromJSON(format('{0}', x))`, which gives a number from a string or a number. `sync-target.yml` passes its two `max-parallel` values the same way.

### Shards

plan gives each target shards of its own. The count is k = the larger of ceil(bytes / `SHARD_BYTES`) and ceil(files / `SHARD_FILES`). k is at least 1, at most `MAX_SHARDS`, and at most the file count. Files go largest first onto the lightest shard. plan logs when `MAX_SHARDS` binds, with the GiB and files per shard. Each shard reads package files from the servers in an order that starts at its own index, so the shards spread across the mirrors. A `.sig` comes from the servers in the target's order. In both orders, a server that failed earlier in the shard comes last.

| variable | default |
| --- | --- |
| `SHARD_BYTES` | 536870912 (512 MiB) |
| `SHARD_FILES` | 400 |
| `MAX_SHARDS` | 32, per target |

⚠ GHCR allows one token 2000 requests a minute, and every push of every job shares the workflow token. That limit, not the parallelism, bounds a seed: about 200 files a minute ([measurements.md](measurements.md#ghcr)).

plan writes `OUT/targets.json` for the pending targets with files to mirror, and `OUT/pending.json` for pending targets with no file to mirror. A database that only drops packages is such a target. It still stages and verifies.

### Batches

stage splits the files new since the promoted database into verify batches. The count is the larger of ceil(bytes / `VERIFY_BATCH_BYTES`) and ceil(files / `VERIFY_BATCH_FILES`). When that is more than `VERIFY_MAX_BATCHES`, both limits grow until it is not, and the log says so.

| variable | default |
| --- | --- |
| `VERIFY_BATCH_BYTES` | 2147483648 (2 GiB) |
| `VERIFY_BATCH_FILES` | 400 |
| `VERIFY_MAX_BATCHES` | 40, per target |

Batch 0 also holds the canaries: the smallest package, and each keyring package that the target's own database holds. So a run with nothing new still proves the path a consumer takes.

### Disk

A shard works in the directory with the most free space among `$RUNNER_TEMP`, `/mnt` and `/tmp`, each filesystem counted once. Each file is deleted once it is pushed. So a shard needs room only for its `PARALLEL` largest files, plus 5 % and 1 GiB.

| `DEBLOAT` | `scripts/debloat-runner` |
| --- | --- |
| `auto` (the default) | runs only when the files do not fit |
| `always` | runs on each shard |
| `never` | does not run |

If the files still do not fit, `PARALLEL` comes down. A shard fails when its largest file does not fit. The `debloat` job of `ci.yml` runs `debloat-runner` in each CI run, so it is seen to work.

## Verify

`scripts/verify-batch STAGE TARGET BATCH OUT` checks one batch the way a consumer reads it.

### One image, no emulation

Every target verifies in one image: `docker.io/library/archlinux:base`, pinned by digest, on `linux/amd64`. pacman.conf sets `Architecture` to the target's arch. pacman on x86_64 then downloads and checks the packages of another arch. No target needs QEMU. `tests/static/60-targets.sh` checks that every target names the same image and platform.

verify writes its own pacman.conf:

```ini
[options]
Architecture = <target arch>
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
DownloadUser = alpm
XferCommand = /usr/local/bin/pacman-oci %o %u

[<repo>]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/<arch>/<repo>@<staged digest>
```

With `db_signed = yes`, the SigLevel is `Required DatabaseRequired`. With `keyring_from`, and when that target has a `latest`, a second section follows (below).

### The trust root

1. `pacman-key --init`.
2. When the target names `keyring_image`, verify pulls it for `keyring_platform`. It runs `create` and `cp` only: nothing in the image runs, so no emulation is needed. It accepts only plain keyring files. It adds each one to `/usr/share/pacman/keyrings/`, never over a file the verify image has.
3. `pacman-key --populate`.
4. verify installs each `keyring` package with `pacman -Sdd`. The packages come from the staged repository, or from the second section of `keyring_from`. The files copied in step 2 are removed first, because the packages own them.
5. `pacman-key --populate` again, so a key added upstream is signed locally before any package is checked.

`keyring_from` names another target of the same arch. Its `latest` is read when verify starts, and its section is pinned by that digest. When it has no `latest` yet, verify logs a warning and skips steps 4 and 5. The trust root of steps 1 to 3 still applies, and pacman still checks every signature. Any other answer from the registry fails the batch: no answer is not an absence.

### Phases

Each phase is logged with its UTC time.

| phase | does |
| --- | --- |
| `pull` | the verify image, and `keyring_image` when named: two attempts of 300 s each |
| `keyring` | the trust root, above |
| `canaries` | batch 0 only: the canaries through the wrapper's single-file path (`PACMAN_OCI_PREFETCH=0`), into a cache of their own |
| `batch` | every package through the wrapper's default path, with `PACMAN_OCI_SIG=registry`, so the stored signatures are the registry's layers |
| `refusals` | after a download that failed: each package alone, to name the ones at fault |
| `sig check` | each stored `.sig` must be the decoded `%PGPSIG%` |
| `files db` | `pacman -Fy`: the synced `<repo>.files` must have the staged sha256. `pacman -Fl` reads each name of the batch that the files database holds. The log names the other names of the batch. |

The canaries and the batch run both paths of the wrapper on every sync.

### Upstream-refused

pacman refuses some files from upstream too. Examples are a package signed by a key that expired, and a package with no signature anywhere. These are not the mirror's fault when the mirror serves exactly upstream's file.

A package that pacman refuses alone, for a reason in its signature, is upstream-refused when all of these are true:

- its tag holds the database's sha256 and size
- its signature layer is the decoded `%PGPSIG%`; or, with no `%PGPSIG%`, the `.sig` that upstream serves now; or upstream has no signature, the tag has none, and every server answers 404 for the `.sig`

`scripts/lib.sh` `refusal_reason` reads pacman's output and the wrapper's exit status:

| class | means |
| --- | --- |
| `sig-missing` | no signature could be read |
| `sig-refused` | pacman read a signature and refused it: an expired or unknown key, a trust it does not accept, a signature not valid for the bytes |
| `other` | anything else; an `other` line wins over any signature line |

Only `sig-missing` and `sig-refused` can be upstream-refused. They go to `OUT/refused-<target>-<batch>.tsv`. The batch passes when every failure is upstream-refused, with the count in the verdict. promote accepts it, and the report lists the files.

### The trust guard

⛔ Upstream-refused is believed only when the trust root is seen to work. That means verify installed a keyring package, or pacman accepted a package of the batch. A trust root that accepts nothing refuses every package. With no keyring package installed and every package refused, verify fails the batch and excuses nothing.

### NUL-only members

Two upstream databases hold a `desc` member that is all NUL bytes: a GNU sparse member with no data. pacman lists such a package with every field `None` and cannot download it. plan accepts these members, at most 16 per database, and names them in `OUT/<target>/nul.txt`, in `why` and in the summary. Any other unreadable member refuses the database.

### The verdict

`OUT/verify-<target>-<batch>.tsv` holds `target batch result detail digest`. The result is `passed` or `failed`. The digest is the staged manifest the verdict is about. promote counts a batch with no verdict, or a verdict about another digest, as failed. The EXIT trap writes the verdict and the packages at fault so far, also when the step is killed. When the container ends with status 124 or 137, the verdict says that the script's own budget ran out.

## Running outside GitHub Actions

The scripts take the registry from `MIRROR_REGISTRY`, `MIRROR_NAMESPACE`, `REGISTRY_USER` and `REGISTRY_TOKEN`, and the targets from `TARGETS_DIR`. So another host can ingest a source that runners cannot read.

- `sync.yml` must create each GHCR repository first, with the workflow token. That links the package to this repository. A package first pushed from outside is not linked, and the workflow token can never write to it.
- ⚠ An outside host must not use a maintainer's token. GHCR accepts only classic tokens, which can write every package of their owner. Use a dedicated account with write access to these packages only.
- Each script that pushes (`mirror-shard`, `stage`, `promote`) logs in with `--password-stdin`. The registry configuration is in its own temporary directory, which the script removes on exit.
- ⚠ `scripts/debloat-runner` runs only on a GitHub-hosted Linux runner, and fails elsewhere. Set `DEBLOAT=never` on another host. `PARALLEL` is 4 there by default, not 6.
- A push must stay inside GHCR's 10-minute upload limit. The largest file of a target sets the lowest upload rate it can use.
