# Design

This document gives the invariant of the mirror, each rule with the failure it prevents, the storage layout, the index of a ref, the jobs and the verify step. The measurements behind the rules are in [measurements.md](measurements.md).

## The invariant

⛔ A database reaches `latest` only after every file it names is on the registry. Every file new since the promoted database must also pass pacman's own checks through the wrapper. It passes in this run, or in an earlier run of the same ref, for the same database record and the same verify context ([the index of a ref](#the-index-of-a-ref)). A tag that a row of the index vouches for is not written until plan withdraws the row.

Each rule below keeps this invariant true for one way it could fail.

## Rules, and the failure each one prevents

| rule | failure it prevents | where |
| --- | --- | --- |
| The database comes only from the target's `db_server` hosts, which the distribution runs. Package bytes can come from any `server`. | The databases are unsigned. The source of a database chooses which validly signed packages get installed, old ones too. | `scripts/plan` |
| Every field of a database is checked against its grammar first. A filename with `/`, a space, a leading `-` or `.`, a control character or a byte above 0x7e refuses the whole database. | A hostile name becomes a path, an option or a tag. | `scripts/lib.sh` `db_validate` |
| ⛔ A database that tar cannot read whole is refused. The status is tar's own, read from PIPESTATUS, and not the last stage's: `scripts/lib.sh` sets no `pipefail`, so `tar ... | tr | sed || rc=$?` captures sed. A cut database then gives records for every package before the cut, exit 0 and no message. A database compressed with zstd, which every ArchPOWER database is, is a second way in: GNU tar shells out for the program, and a host without it reads none of the archive. | A mirror stages a database naming part of what upstream published, and the registry holds a tag that no later run will move. | `scripts/lib.sh` `db_tar`, `db_records`, `db_members`, `db_check` |
| Each package directory gives exactly one record. A `desc` member of NUL bytes only, or empty, is counted and named; at most 16 are accepted. Any other unreadable member refuses the database. | A database that drops packages without a word. An upstream sparse member that holds a target for ever. | `scripts/lib.sh` `db_check` |
| A file name that `<repo>.files` and `<repo>.db` both name must have one sha256. A files database with another sha256 for a file is refused, and plan tries the next `db_server` that served the same database. Drift is counted by package name, accepted, and named: packages the files database leaves out, packages only the files database names, and packages both name at other file names (a files database that lags). A files database that names fewer than half of the packages of the database, and leaves out 16 or more, is refused: it is of another repository. `FILES_DRIFT_MAX`, when set, replaces that rule with a bound on the file names that only one of the two databases names. | Another sha256 means the two databases are of different snapshots. Drift holds no file a consumer downloads: the database alone decides what pacman installs, and upstream's own users get the same drift (`docs/measurements.md`). A bound on file names refuses every files database during a mass rebuild: each rebuilt package adds 2. | `scripts/plan` |
| Never behind: a candidate is dropped when one of its packages was built before the same package in the promoted database or in another candidate. `ALLOW_OLDER` lifts the first comparison. | A lagging server rolls consumers back to older builds. | `scripts/plan` |
| The watchdogs take upstream as plan does: every `db_server` is read, an answer that is not a whole database is refused, a database behind another is dropped, and the first one left counts. | A first `db_server` that lags hides a mirror that stopped. An error page that answers 200 makes a quiet repository stale. | `scripts/upstream-db`, for `scripts/check-staleness` and `scripts/status-collect` |
| A candidate with no package built later than in the promoted database waits while a `db_server` still serves the promoted database. A candidate that only adds or drops packages is one. `ALLOW_OLDER` lifts this wait too. | A server that lags by one dropped package moves `latest`. | `scripts/plan` |
| `latest` never moves backwards. Just before it tags, promote reads the `fetched` time of the snapshot `latest` names, and refuses a staged snapshot fetched earlier. | A re-run, or a second writer, rolls consumers back. | `scripts/promote` |
| ⛔ A package tag is written once. A tag that holds other bytes under a name is never written again. The target's state is `replaced`, and on `main` the `replaced-<target>` issue opens. | The promoted or an older snapshot names those bytes. pacman refuses a file whose sha256 it does not expect, and tries no other Server. | `scripts/lib.sh` `decide_push`, `scripts/mirror-file` |
| A signature layer that is missing or wrong beside the right package bytes is repaired: the file is pushed again with the same package blob. plan skips a file only when its sha256 and its `%PGPSIG%` equal the promoted record. With no `%PGPSIG%`, each run also compares `SIGCHECK_SAMPLE` (64) of the skipped files, from an offset that moves on each 3-hour run: upstream's `.sig` against the signature layer of the tag. A file whose `.sig` differs is planned again. When more than `SIGCHECK_ESCALATE` (8) of one sample differ, every such file is planned. | A file that upstream signs again keeps a stale signature layer for ever. With no `%PGPSIG%`, a new `.sig` does not change the database, so a key rotation or a repaired `.sig` is not seen. | `scripts/plan`, `scripts/mirror-file` |
| A package never lacks its signature when the database has one. The layer is the decoded `%PGPSIG%`. With no `%PGPSIG%`, it is the detached `.sig`, which must be one OpenPGP signature packet under 64 KiB. Any other answer is an error, not an absence. A file is pushed unsigned only when no server answers with a signature and every `db_server` answers 404 for its `.sig`. A plain `server` that gives no answer that decides (no answer, a status other than 200, 404 and 410, or bytes that are not a signature) does not hold the file: the result and a warning name it. A `db_server` that gives no such answer fails the file. | pacman asks for a `.sig` only from the server that served the package. A missing `.sig` ends the install. One plain mirror that is down holds every new unsigned file of the target, on every run. | `scripts/mirror-file` |
| With no `%PGPSIG%`, mirror-file reads the `.sig` from the target's servers in their own order, the `db_server` hosts first. verify compares with the same order. Only package files are read in an order rotated by shard. | A plain mirror that serves other `.sig` bytes gives the layer, verify refuses it, and the target fails on every run. | `scripts/mirror-file` |
| A file pushed unsigned is named in the staged manifest, in `dev.pkgforge.mirror.unsigned`. plan asks for its `.sig` again on each run. When a server answers, plan puts the file in todo, also when the database did not change, and mirror-file adds the layer. | A `.sig` that upstream publishes later never reaches the mirror. A detached-signature database does not change when a `.sig` is added. | `scripts/stage`, `scripts/plan` |
| Every upstream read has a stall deadline. A database or a signature read has a whole-call deadline that also bounds its retries: `--retry-max-time`, and `timeout` 5 s after it. A package download gets 120 s plus the time at 64 KiB/s. | curl gives each retry a new `--max-time`: a call took 3 x the deadline + 4 s. | `scripts/lib.sh` `fetch_upstream` |
| The upstream reads of plan end within `PLAN_BUDGET` (1200 s), below the job's 40 minutes. Each target gets what is left, divided by the targets not yet read. A `db_server` read gets 1/(n + 1) of the target's share, with n the `db_server` hosts not yet read. A target whose reads do not fit is in error for the run, and its why names `PLAN_BUDGET`. | One slow upstream server makes the plan job time out, and no target is mirrored or promoted. | `scripts/plan` |
| A server that fails for one file of a shard is asked last by every file of the shard after it: a timeout, a failed connection, or a status other than 200, 404 and 410. A `.sig` read ends within 30 s. | A server that stalls costs each file of the shard 184 s, also a file the registry holds. The shard never ends inside its step. | `scripts/mirror-file`, `scripts/lib.sh` `down_mark` |
| The token cache keeps only a token got with `REGISTRY_TOKEN`. A read with `REGISTRY_TOKEN` empty never uses the cache, and the anonymous token it gets is never kept. | stage's anonymous read sends the workflow's token. A private package reads as public and is promoted. | `scripts/lib.sh` `registry_token_file` |
| Every artifact that a chain makes carries the plan id (`scripts/plan`). stage and index-write read only the shard results of their plan (`scripts/lib.sh` `results_of_plan`). The report reads only the summaries of its plan, and only for a target the plan marks pending. collect and index-write read only the verdicts of the staged digest. | "Re-run all jobs" plans again, and a download by name or pattern still returns the earlier attempt's artifacts. A stale result holds a target, a stale summary raises an issue again, or a stale "pushed" gives a file a row in the index. | `scripts/stage`, `scripts/index-write`, `scripts/report`, `scripts/mirror-shard` |
| Verify compares every `.sig` pacman stored with the decoded `%PGPSIG%`. | pacman checks against `%PGPSIG%` and stores the served `.sig` unread. A wrong layer passes verify and breaks a later `pacman -U` from the cache. | `scripts/verify-batch` |
| Package manifests are the same bytes whoever pushes them. `org.opencontainers.image.created` is the package's `%BUILDDATE%`, and no annotation names the source server. | Two writers replace each other's tag with a manifest of another digest. | `scripts/mirror-file` |
| Absent means the registry says so: only a 404 with `NAME_UNKNOWN` or `MANIFEST_UNKNOWN`, and, for an anonymous read only, the 403 of the token endpoint (next row). On GHCR, with a token set, a read tries `Bearer QQ==` first, and only its 200 counts. Any other answer is read again with the real token. | GHCR answers `QQ==` with 404 for a repository it does not show. A private package reads as absent, and its tags are pushed over. | `scripts/lib.sh` `registry_manifest` |
| On GHCR with no token set, a read tries `Bearer QQ==` first. A 401 or a 403 to it is read again through the anonymous token flow, and a warning names the repository. The token endpoint answers 403 for a repository it does not show. For an anonymous read only, that 403 is absent, as the 404 of `QQ==` is. A 401 of the token endpoint is not measured, and is an error. A blob read does the same. `registry_token`, which `scripts/status-collect` calls, asks the anonymous token flow, and gives `QQ==` for such a repository, so a target with no push yet still reads as absent. | GHCR does not document `QQ==`. When GHCR refuses it, every anonymous read fails: stage calls every target private, verify fails every `keyring_from` batch, and the status page shows every mirror in error. | `scripts/lib.sh` `registry_manifest`, `registry_blob` |
| stage calls a target private only when the anonymous read gets 401, 403 or 404 (`REG_LAST_CODE`). Any other answer, or none, is read again, at most 5 times, and then the target is in error, with the HTTP code. | A 5xx or a timeout of one read raises a `visibility-<target>` issue for a public package. | `scripts/stage` |
| A blob read ends within `REG_BLOB_MAX_TIME` (600 s), its retries included: `--max-time`, `--retry-max-time`, and `timeout` 5 s after it. | A blob host that sends just above the stall floor holds plan or the status run for hours. | `scripts/lib.sh` `registry_blob` |
| A token request ends within `REG_TOKEN_MAX_TIME` (90 s), its retries included, in the same three ways. `scripts/status-collect` sets 30 s. | A token endpoint that stalls holds each call about 250 s. The status run asks once for each of 15 targets, so it can use all 30 minutes of the build job. | `scripts/lib.sh` `registry_token_get` |
| A file that upstream supersedes during a run holds the target for that run. A file that never succeeds holds its target until upstream drops or rebuilds it. | A database is staged that names a file the registry does not hold. | `scripts/stage` |
| Each target runs its own chain and reads only its own artifacts. Every artifact name carries the target. A chain reads its shard results and verdicts by the pattern `<kind>-<target>-[0-9]*`. So a target name that extends another target name with a letter never matches. ⚠ An extension that starts with `-` and a digit, as in `x86_64-core-2`, still matches. | One slow or failed target holds every other target. A chain reads the verdicts of another target. | `.github/workflows/sync-target.yml` |
| A push attempt gets 300 s plus the time at `MIRROR_MIN_RATE` (2 MiB/s), and never more than 600 s. | Attempts run past GHCR's 10-minute upload limit and are lost. | `scripts/mirror-file` |
| A 429 from the registry costs no attempt, in mirror-file, in stage's staging push and in promote's tags. A 429 is `toomanyrequests`, `429 Too Many` or oras's own `status code 429`. Each pause is 20 to 60 s. A push of a shard that gets one writes `$WORK/throttle`, the time its pause ends, and every push of the shard waits for that time first. The pauses add up to at most `MIRROR_RATE_WAIT` (1800 s) for one file, `STAGE_RATE_WAIT` (600 s) for the staging push, `PROMOTE_RATE_WAIT` (420 s) for the tags of one promotion, and `INDEX_RATE_WAIT` (120 s) for one push of the index. The second and third are below the 20 and 15 minutes of their jobs. After the cap, the step fails and names its pauses. | GHCR limits the requests of one token, and every push of every job shares the workflow token. Three attempts, 5 s and 20 s apart, all fall inside the limit: the file fails, stage is in error, or `latest` does not move. | `scripts/lib.sh` `rate_limited`, `throttle_pause`, `index_push`; `scripts/mirror-file`, `scripts/stage`, `scripts/promote` |
| Each item of a shard writes its result line the moment it ends. A work line with no result counts as failed. | A shard that runs out of time loses the results of the files it pushed. | `scripts/mirror-shard`, `scripts/mirror-file` |
| The verify budgets nest. The pulls and the container end inside `VERIFY_BUDGET` (4800 s). That ends inside the step's 85 minutes, which end inside the job's 95. The verdict is written by an EXIT trap. | The runner ends the job, and no verdict is left. | `scripts/verify-batch`, `sync-target.yml` |
| The verify container looks up no key on the network. Its `gpg.conf` has `disable-dirmngr`, so a WKD lookup and a keyserver lookup both fail at once. It also names the keyserver `hkp://127.0.0.1:9`, which refuses at once. | A missing or expired key makes pacman look it up by WKD on the domain of the key's user ID, then on a keyserver. The verdict then depends on a host outside the run, and verify waits on it. | `scripts/verify-batch` |
| No exit is silent. Each script that sources `scripts/lib.sh` has an ERR trap that names the command which ended it. No pipeline ends in a reader that stops early. | A step ends with status 141 (SIGPIPE) and no message. | `scripts/lib.sh`, `tests/static/35-pipeline-traps.sh` |
| plan does not mirror a file that the index of the ref names with state `m` and the same sha256 and `%PGPSIG%`. It verifies such a file again unless the index names it as verified under this run's verify context. | A run that fails, is held or is cancelled loses its work, and the next run starts from scratch. A file verified under other rules is promoted with no check. | `scripts/plan`, `scripts/lib.sh` `index_read`, `verify_context` |
| ⛔ A tag that a row of the index vouches for is not written until plan withdraws the row. Before any shard starts, plan pushes the index again without the rows of the files it plans, and reads it back. A push or a read back that fails puts the target in error. | A run writes a tag under a row that says verified, and the next run promotes bytes that no verify read. | `scripts/plan` |
| index-write reads the live tag with the workflow's token just before the push. It pushes only in four cases: the live tag is the one plan read; there is none, as plan found; plan did not read it (a reset); an earlier attempt of the same plan wrote it. | A re-run of an older run replaces the index of a newer run. | `scripts/index-write` |
| A re-run of a mirror job (`GITHUB_RUN_ATTEMPT` above 1) reads the live index once. It writes no tag that the index lists. When the index does not read, it writes no tag at all. | A re-run of an older run writes an older signature layer over one that a newer run verified, and the index still vouches for the tag. | `scripts/mirror-shard`, `scripts/mirror-file`, `scripts/lib.sh` `index_guard` |
| A run on a branch repairs no signature layer (`MIRROR_REPAIR=0`). It writes only new package tags, and its own `staging-<branch>` and `index-<branch>` tags. | A branch run changes a tag that the index of `main` vouches for. | `sync-target.yml`, `scripts/mirror-file` |
| A batch that fails removes from the index the rows of its files at fault (`faults-<target>-<batch>.txt`). A failed batch that names no file keeps its rows, not verified. | A tag at fault stays vouched for, and every later run skips it. | `scripts/verify-batch`, `scripts/index-write` |
| mirror-file reads the package bytes from the registry before upstream: on a repush from the target's own repository, then from each sibling that plan names. The read stops at the record's size and checks the sha256. A 404 is a quiet miss. Any other answer marks the repository down for the shard. | A repair downloads the package from upstream again. The three base-any targets download the same files three times. | `scripts/mirror-file`, `scripts/lib.sh` `registry_blob_probe` |
| A registry source that gave no answer that decides keeps a file that every server answers 404 for failed, not absent. | A file that the registry can hold is skipped as absent. | `scripts/mirror-file` |
| The registry reads of plan (the index, the latest database of `keyring_from`, the siblings) end within `REGISTRY_READ_BUDGET` (240 s) for the whole plan. Each blob and token read ends within 60 s, or within what is left. A read that is not made costs work, never safety. | A registry that stalls holds the plan job past its 40 minutes. | `scripts/plan` |
| plan keeps each upstream read of a `.files` database, a database signature and a package `.sig` that answers, for the rest of the plan. A `<repo>.db` is never kept. | The three base-any targets read `base-any.files`, its signatures and the `.sig` files of steps 4 and 4b three times in one plan. | `scripts/plan` `fetch_within` |

## Storage layout

```
ghcr.io/pkgforge-dev/mirror-archlinux/<arch>/<repo>
  :<escaped filename>        one package: the file and its signature
  :staging                   the candidate database of the run on main
  :staging-<branch>          the candidate database of a run from another branch
  :index                     the index of the runs on main: what they left on the registry
  :index-<branch>            the index of the runs of another branch
  :latest                    the promoted database
  :YYYY.MM.DD                the first promoted database fetched on that UTC date; never moves
  :db-<sha256 of <repo>.db>          the promoted database by its content
  :files-<sha256 of <repo>.files>    the same, by the files database
```

`<arch>` is pacman's `$arch`. One GHCR repository holds one target. Nothing is ever deleted: `tests/static/50-workflow-policy.sh` refuses every use of the packages DELETE API.

`<branch>` is the branch name in lower case. Each character other than `a-z` and `0-9` becomes `-`, a run of `-` becomes one, and a leading or trailing `-` is removed. Then the name is cut to 40 characters. An empty result is `branch`. `scripts/lib.sh` `staging_tag` and `index_tag` make both tags. `STAGING_TAG` and `INDEX_TAG`, when set, replace them.

## Tags

A package tag is the filename with this mapping:

- `+` becomes `_p`, `:` becomes `_c` and `@` becomes `_a`.
- A literal `_` becomes `_u` only when the next character is `p`, `c`, `a` or `u`. So `x86_64` stays `x86_64`, and the mapping is injective.

GHCR resolves tags with no regard to case, so every tag is lower case. Some filenames are stored under `fn-` and the hex sha256 of the name. These are a name with upper case or another character outside `[a-z0-9@._+:-]`, and a name that the mapping cannot carry in 128 characters. That form has no dot. Every escaped package name has `.pkg.tar`. So the two forms never meet, and neither meets `latest`, `staging`, `staging-<branch>`, `index`, `index-<branch>`, a date, `db-` or `files-`. `tests/unit/10-tag-encoding.sh` checks the database tags and the index tags.

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

An index manifest ([the index of a ref](#the-index-of-a-ref)):

- artifact type `application/vnd.pkgforge.archlinux.index.v1`
- two layers, by title: `ref.db` (`application/vnd.pkgforge.archlinux.db.v1`), the upstream database the rows describe; `index.tsv` (`application/vnd.pkgforge.archlinux.index.v1+tsv`), the rows
- annotations: `dev.pkgforge.mirror.index-format` (`1`), `.plan-id`, `.fetched` (the plan's), `.db-sha256` (of `ref.db`), `.verify-context`, `.run`, and the OCI `source`

## The index of a ref

The index holds what the runs of one ref left on the registry. A run that fails, is held or is cancelled leaves its work to the next run, so no run starts from scratch. Each target repository has one index for `main` (`:index`) and one for each other branch (`:index-<branch>`).

⛔ The index is not a database. The Worker takes no tag in a URL but `latest`, a date, `db-` and `files-` (`worker/test/paths.test.js`). The tag holds no layer named `<repo>.db` or `<repo>.files`, so the wrapper gets no database from a Server line at `:index` (`tests/integration/10-pipeline.sh`).

### The rows

`index.tsv` holds one line per file, sorted by filename: `filename state verified unsigned`, tab separated.

| state | means |
| --- | --- |
| `m` | the tag holds exactly the package bytes of the `ref.db` record, and the signature layer mirror-file makes for it |
| `a` | every server answered 404: the file is absent upstream |

`verified` is 1 when a batch that held the file passed verify. `unsigned` is 1 when the tag holds no signature, because upstream publishes none. For state `a`, both are 0.

### Who writes it

1. `scripts/plan` withdraws rows (step 6b). Before any shard starts, it pushes the index again without the `m` rows of the files it plans. The same `ref.db` and annotations stay, so oras uploads only the new `index.tsv`. Then it reads the tag back. A push or a read back that fails puts the target in error. Only this step needs oras in plan, and `packages: write`.
2. `scripts/index-write` writes the rows of the run, in the `summary` job of `sync-target.yml`. That job runs also after a failure or a cancel.
3. Nothing else writes it. stage writes no index.

index-write writes these rows:

- each line of `PLAN/<target>/vouched.tsv`: the rows of the index that plan read, for the files it did not plan
- each file of the run with the result `pushed` or `present`: state `m`, verified 0
- each file of the run with the result `absent`: state `a`
- a file with any other result gets no row

Then it gives verify credit, only when the stage is `staged` and of this plan. Each verdict about the staged digest counts. A batch that passed gives its files verified 1. A batch that failed removes the rows of its files at fault (`faults-<target>-<batch>.txt`, `scripts/verify-batch`). A failed batch that names no file at fault keeps its rows, with verified 0. The next run verifies them again.

The rows pass their own check before the push: four fields, each in its grammar, a filename of the plan's records, and no filename twice.

### What plan reads

plan reads the index after it chooses the database (step 3b), as it reads `latest`: anonymously, then with the workflow's token. When only the read with the token is valid, the package is private. `INDEX_READ=0`, the `ignore_index` input of `sync.yml`, does not read it.

| `INDEX_STATE` | when | then |
| --- | --- | --- |
| `ok` | the index reads and is valid | its rows count |
| `absent` | the registry has no such tag | the run plans as with no index, and writes the first one |
| `invalid` | another artifact type, a layer missing, another format, a `ref.db` that does not read, or more than 1 % of its lines bad | the rows do not count; the run writes a new index |
| `unread` | no answer that decides: a transport error, an HTTP error, a blob that is not its digest, or `REGISTRY_READ_BUDGET` spent | a warning; the run plans as with no index, and index-write writes none |
| `ignored` | `INDEX_READ=0` | the run plans as with no index, and its index replaces any |

A line that fails its grammar, or names a file that `ref.db` does not, is dropped. Both lines of a filename given twice are dropped. A `ref.db` whose digest is the digest of a database plan holds already is copied, not read.

A file counts as indexed when the index has a row `m` for it, and the `ref.db` record has the same sha256 and `%PGPSIG%` as the chosen record. For each record, with P promoted, I indexed, A indexed as absent, V indexed and verified under this run's verify context, and again planned by step 4 or 4b:

| set | files |
| --- | --- |
| todo, the files this run mirrors | not (P or I), or again, or A |
| new, the files this run verifies | (not P and not V), or again, or A; so every todo file is verified |
| vouched, the rows index-write keeps | I and not again |

A target with no todo file and files to verify is pending with no shard (`pending.json`). It stages and verifies. Its why says `0 file(s) to mirror, N to verify`.

### The verify context

A verdict holds for the inputs it ran with. `scripts/lib.sh` `verify_context` is one sha256 over:

- the line `index-format=1`
- the `key = value` lines of the target file; a comment or a blank line does not count
- the bytes of `scripts/verify-batch`, `client/pacman-oci` and `scripts/lib.sh`
- the filename, sha256 and `%PGPSIG%` of each keyring package that verify installs: from the target's own records, or from the `latest` of `keyring_from`, or `none` when that target has no `latest`

A row verified under another context is verified again. When the context is not known, because the `latest` of `keyring_from` did not read, no row counts as verified, and each row keeps its flag for the next run.

### The guards

⛔ The writer guard. Just before the push, index-write reads the live tag with the workflow's token. It pushes only when one of these is true:

- the live manifest is the one plan read, or the one its withdrawal pushed (`INDEX_DIGEST`)
- there is no live tag, and plan found none
- plan did not read the index (`ignored`): the new index replaces any
- the live index names this plan: an earlier attempt of this run wrote it. Its rows marked verified keep verified 1.

Anything else keeps the live tag, with a warning. A live read that fails keeps it too. The `sync` concurrency group lets no two runs write at once. So only a re-run of an older run can come between plan and index-write.

⛔ The re-run guard. A re-run of a mirror job mirrors from an older plan, and a newer run can have written the index since. So a shard with `GITHUB_RUN_ATTEMPT` above 1 reads the live index once, before its first file (`scripts/lib.sh` `index_guard`). mirror-file writes no tag of a file that the index lists, and its result is `failed`, `the index lists it`. When the index does not read, mirror-file writes no tag in that shard. A tag that holds its file already still counts as `present`. Attempt 1 reads nothing: plan withdrew the rows of every file it gave the shards.

⛔ A run on a branch repairs no signature layer. `sync-target.yml` sets `MIRROR_REPAIR=1` on `main` only. With 0, a file whose tag holds the right package bytes and another signature layer is `failed`, `a signature repair is left to main`.

### Registry sources

mirror-file reads a file's package bytes from the registry before it asks upstream:

1. on a repush, the target's own repository: its tag holds the package blob
2. each sibling repository that plan names for the file in `PLAN/<target>/sources.tsv`, in that order
3. the upstream servers, as before

A sibling is an enabled target of `TARGETS_DIR` with a `db_server` of the same URL. It holds a file when its `latest` database or its index names the same filename and sha256. Today only the three `*-base-any` PowerPC targets share a `db_server`. plan reads the `latest` database of each sibling once per layer digest.

`scripts/lib.sh` `registry_blob_probe` reads at most the record's size, within the deadline of an upstream package read, and checks the sha256.

| answer | then |
| --- | --- |
| the bytes | they are pushed; the result says `from <registry>/<repository>` |
| 404 (`BLOB_UNKNOWN`, `NAME_UNKNOWN`), or no anonymous token for the repository | the next source, with no warning |
| 429 | the shard pauses (`throttle_pause`), then the next source |
| anything else, other bytes too | the repository is marked down for the shard (`$WORK/down/r-<repository, each / a _>`), and no file of the shard asks it again |

This saves the package bytes and the upstream request of each file that the registry holds. That is every signature repair on every target, and each file of a base-any target that a sibling holds, on a seed or after a hold. The `.sig` handling does not change. ⚠ The bytes are pushed again: there is no cross-repository mount.

### One read per URL per plan

plan keeps each upstream read that answers in `OUT/.fetch-cache`, for the rest of the plan, and removes it at the end. A `<repo>.files`, a `<repo>.db.sig` and a `<repo>.files.sig` are kept by URL and the sha256 of the chosen database. A package `.sig` of steps 4 and 4b is kept by URL. A `<repo>.db` is never kept. A read that is kept costs no request and no time of the share. So the three base-any targets read `base-any.files`, its signatures and the `.sig` files of steps 4 and 4b once per plan, not three times.

### Budgets

| bound | value | where |
| --- | --- | --- |
| `REGISTRY_READ_BUDGET` | 240 s for the registry reads of the whole plan: the index, the `latest` database of `keyring_from`, the siblings; each blob or token read 60 s, or what is left | `scripts/plan` |
| `INDEX_RATE_WAIT` | 120 s of 429 pauses for one push of the index; at most 2 attempts, each within 120 s | `scripts/lib.sh` `index_push` |
| the withdrawal's read back | 5 tries, 2 to 8 s apart | `scripts/plan` |
| the re-run guard's read | 3 tries of the manifest, 3 tries of `index.tsv` within 60 s each | `scripts/lib.sh` `index_listed` |
| index-write | `timeout 780`, in a step of 15 minutes, in the `summary` job of 25 minutes | `sync-target.yml` |

### ⚠ Not done

- A cross-repository blob mount for a sibling source.
- Verify credit for the files of a failed batch that are not at fault. They are verified again in the next run.
- A shard of a re-run that starts from the results of its earlier attempt.

## Jobs

`.github/workflows/sync.yml` runs on the cron `17 */3 * * *` and on dispatch.

| job | permissions | timeout (min) | does |
| --- | --- | --- | --- |
| `plan` | contents read, packages write | 40 | `scripts/plan` for every enabled target, or for the targets of the `targets` input, within `PLAN_BUDGET` (1200 s) of upstream reads and `REGISTRY_READ_BUDGET` (240 s) of registry reads; withdraws index rows (packages write); uploads `plan-<target>` for each pending target |
| `target` | contents read, packages write | (each called job has its own) | one call of `sync-target.yml` per pending target, at most `max_targets` (4) at once |
| `report` | actions write, contents read, issues write | 10 | `scripts/report`; on `main` it starts `status.yml` |
| `keepalive` | actions write, contents read, issues write | 10 | `scripts/watch-schedules` (`keep-schedules-enabled`, `check-schedules-fired`, the issue `schedules-stopped`), and `dispatch-overdue status.yml 120` on `main` |

`.github/workflows/sync-target.yml` is the chain of one target:

| job | permissions | timeout (min) | does |
| --- | --- | --- | --- |
| `mirror` | contents read, packages write | 250 (step 240) | `scripts/mirror-shard` per shard, at most `max_shards` (3) at once |
| `stage` | contents read, packages write | 20 | `scripts/stage` for the target |
| `verify` | contents read | 95 (step 85) | `scripts/verify-batch` per batch, at most `max_batches` (3) at once |
| `promote` | contents read, packages write | 15 | `scripts/promote`, on `main` only |
| `summary` | contents read, packages write | 25 (index step 15) | `scripts/report collect`: a small `summary-<target>` artifact for the report; then `scripts/index-write`: the index of the target. It runs also after a failure or a cancel. An index that is not written is a warning. |

All runs share one concurrency group, `sync`, on every ref. Two runs never write the same tags at once.

The dispatch inputs are `targets`, `max_targets` (4), `max_shards` (3), `max_batches` (3), `parallel` (6 files at once in a shard), `debloat` (`auto`, `always`, `never`), `allow_older` and `ignore_index` (do not read the index; [operations.md](operations.md#the-index-of-a-ref)).

A dispatch input reaches an expression as a string. `max-parallel` and a number input of a called workflow refuse a string. So `sync.yml` passes each number input through `fromJSON(format('{0}', x))`, which gives a number from a string or a number. `sync-target.yml` passes its two `max-parallel` values the same way.

### Shards

plan gives each target shards of its own. The count is k = the larger of ceil(bytes / `SHARD_BYTES`) and ceil(files / `SHARD_FILES`). k is at least 1, at most `MAX_SHARDS`, and at most the file count. Files go largest first onto the lightest shard. plan logs when `MAX_SHARDS` binds, with the GiB and files per shard. Each shard reads package files from the servers in an order that starts at its own index, so the shards spread across the mirrors. A `.sig` comes from the servers in the target's order. In both orders, a server that failed earlier in the shard comes last.

| variable | default |
| --- | --- |
| `SHARD_BYTES` | 536870912 (512 MiB) |
| `SHARD_FILES` | 400 |
| `MAX_SHARDS` | 32, per target |

⚠ GHCR allows one token 2000 requests a minute, and every push of every job shares the workflow token. That limit, not the parallelism, bounds a seed: about 200 files a minute ([measurements.md](measurements.md#ghcr)).

plan writes `OUT/targets.json` for the pending targets with files to mirror, and `OUT/pending.json` for pending targets with no file to mirror. A database that only drops packages is such a target. So is a database whose new files the index names. It still stages and verifies.

### Batches

stage splits the files of `PLAN/<target>/new.tsv` into verify batches, less the files absent upstream. These are the files new since the promoted database that the index does not name as verified under this run's verify context. The count is the larger of ceil(bytes / `VERIFY_BATCH_BYTES`) and ceil(files / `VERIFY_BATCH_FILES`). When that is more than `VERIFY_MAX_BATCHES`, both limits grow until it is not, and the log says so.

| variable | default |
| --- | --- |
| `VERIFY_BATCH_BYTES` | 2147483648 (2 GiB) |
| `VERIFY_BATCH_FILES` | 400 |
| `VERIFY_MAX_BATCHES` | 40, per target |

Batch 0 also holds the canaries: the smallest package whose tag holds its bytes (of the 10 smallest), and each keyring package that the target's own database holds. So a run with nothing new still proves the path a consumer takes.

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

The image has a second and a third source. When Docker Hub does not give it in two attempts, verify pulls the same digest from each prefix of `VERIFY_IMAGE_MIRRORS` in turn, one attempt each: `mirror.gcr.io/library/archlinux@sha256:<digest>`, then `public.ecr.aws/docker/library/archlinux@sha256:<digest>`. Each one served the pinned digest ([measurements.md](measurements.md#tools-and-images)). The digest pins the bytes, so the trust root does not change. The container runs the reference that was pulled, and the log names it. A `toomanyrequests` answer from Docker Hub goes to the mirrors at once, with a log line of its own. When every source fails, the verdict names the mirrors, and `toomanyrequests` when a source said it. Only a `docker.io/library` image pinned by digest has mirrors; `keyring_image` has none.

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

⚠ The Worker serves `<repo>.db` and `<repo>.db.sig` from `latest` at the time of each request. Across a promotion the two can come from two snapshots, and pacman with `DatabaseRequired` then fails one `-Sy`, until the next `-Sy` reads both from the promoted snapshot. A consumer that must not see that uses the pin form, `Server = .../$arch/$repo@sha256:<digest>`, which names one manifest for both files.

### The trust root

1. `pacman-key --init`.
2. When the target names `keyring_image`, verify pulls it for `keyring_platform`. It runs `create` and `cp` only: nothing in the image runs, so no emulation is needed. It accepts only plain keyring files. It adds each one to `/usr/share/pacman/keyrings/`, never over a file the verify image has.
3. `pacman-key --populate`.
4. verify installs each `keyring` package with `pacman -Sdd`. The packages come from the staged repository, or from the second section of `keyring_from`. The files copied in step 2 are removed first, because the packages own them. When the install fails, for example because upstream renamed or split a keyring package, or signed it only with a new key, the verdict names the packages, the repository and pacman's first `error:` line. There is no fallback to `keyring_image` alone: the trust root stays strict.
5. `pacman-key --populate` again, so a key added upstream is signed locally before any package is checked.

`keyring_from` names another target of the same arch. Its `latest` is read when verify starts, and its section is pinned by that digest. When it has no `latest` yet, verify logs a warning and skips steps 4 and 5. The trust root of steps 1 to 3 still applies, and pacman still checks every signature. Any other answer from the registry fails the batch: no answer is not an absence.

### A function that reads a status under `set -e` and `pipefail`

⛔ A script that runs `set -e` and `set -o pipefail` must not call a function
bare if the function has a pipeline that can fail before its own check. Under
both, a failing stage makes the pipeline's status non-zero, so `errexit` ends
the shell inside the pipeline. The function never reaches its own status
handling, its cleanup, or the status it documents, and the shell ends with the
failing stage's status instead. `db_records` is the case: called bare from
`scripts/plan` (`set -euo pipefail`), a database that does not read is tar's 2,
not the function's 1, and the temporary directory leaks. The `if !` form
suspends `errexit` for the call, so the function runs to its own check.

The form is `if ! db_records ...` or `db_records ... || rc=$?`. Both exempt the
call from `errexit`, and both leave the caller's `errexit` on, which a bare
call does not. Bash will not let the function fix this itself: `return 1` is
itself a failing command, so a `set -e` inside the function is undone by its
own return. So the rule lives at the call site, and each function that reads a
status says so where a reader of the function will meet it.

### The PowerPC targets

The six PowerPC targets are two repositories per architecture, and neither is named like the Arch ones.

| target | `db_server` | holds |
| --- | --- | --- |
| `<arch>-base` | `https://repo.archlinuxpower.org/$repo/$arch` | the packages of that architecture |
| `<arch>-base-any` | `https://repo.archlinuxpower.org/base/any` | the architecture-independent packages, one database shared by all three architectures |

So `base-any` is at `base/any` and not at `$repo/$arch`, which is why its `db_server` is written out in full. The `*-base` target takes `keyring_from = <arch>-base-any`, because the keyring package lives in `base-any` and not in `base`. The `*-base-any` target names `archpower-keyring` as its `keyring` and takes no indirection: the package is in its own repository.

All six set `db_signed = yes`. ArchPOWER publishes a detached signature for every database, and the `gpgv` check in `plan` (`scripts/lib.sh` `db_sig_ok`) refuses one that does not verify against the keyring the target's image holds. That is the first target group where a database signature is part of the trust root rather than absent: for every other target upstream publishes no `<repo>.db.sig` at all, and `db_signed` stays off.

### Phases

Each phase is logged with its UTC time.

| phase | does |
| --- | --- |
| `pull` | the verify image, and `keyring_image` when named: two attempts of 300 s each; then the verify image's digest from each mirror, one attempt of 300 s each |
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
- its signature layer is the decoded `%PGPSIG%`; or, with no `%PGPSIG%`, the `.sig` that upstream serves now, the first signature in the target's order of servers; or upstream has no signature, the tag has none, every `db_server` answers 404 for the `.sig`, and every other server answers 404 or gives no answer that decides

A server that gives no answer that decides is passed over, as in mirror-file. With no signature anywhere, it must be a plain `server`: a `db_server` must answer 404.

`scripts/lib.sh` `refusal_reason` reads pacman's output and the wrapper's exit status:

| class | means |
| --- | --- |
| `sig-missing` | no signature could be read |
| `sig-refused` | pacman read a signature and refused it: an expired or unknown key, a trust it does not accept, a signature not valid for the bytes |
| `other` | anything else; an `other` line wins over any signature line |

Only `sig-missing` and `sig-refused` can be upstream-refused. They go to `OUT/refused-<target>-<batch>.tsv`. The batch passes when every failure is upstream-refused, with the count in the verdict. promote accepts it, and the report lists the files.

⚠ One key made every signature of the 8 Arch Linux ARM targets, and one key every signature of riscv64 ([measurements.md](measurements.md)). A key that upstream revokes or rotates makes most new files upstream-refused. The snapshot is still promoted: it is upstream's exact bytes. So on `main` the report raises `refused-<target>` when one run collects more than `REFUSED_ISSUE_MIN` (16) of them, and a person checks the key.

### The trust guard

⛔ Upstream-refused is believed only when the trust root is seen to work. That means verify installed a keyring package, or pacman accepted a package of the batch. A trust root that accepts nothing refuses every package. With no keyring package installed and every package refused, verify fails the batch and excuses nothing.

### NUL-only members

Two upstream databases hold a `desc` member that is all NUL bytes: a GNU sparse member with no data. pacman lists such a package with every field `None` and cannot download it. plan accepts these members, at most 16 per database, and names them in `OUT/<target>/nul.txt`, in `why` and in the summary. Any other unreadable member refuses the database.

### The verdict

`OUT/verify-<target>-<batch>.tsv` holds `target batch result detail digest`. The result is `passed` or `failed`. The digest is the staged manifest the verdict is about. promote counts a batch with no verdict, or a verdict about another digest, as failed. The EXIT trap writes the verdict and the packages at fault so far, also when the step is killed. When the container ends with status 124 or 137, the verdict says that the script's own budget ran out.

With each failed verdict, verify writes `OUT/faults-<target>-<batch>.txt`: the files at fault, one per line, sorted. These are the file of each `@@sigbad` line and of each package of a `@@refused` line, less the upstream-refused files. A failure that names no file gives an empty list. index-write removes the index rows of these files.

## Running outside GitHub Actions

The scripts take the registry from `MIRROR_REGISTRY`, `MIRROR_NAMESPACE`, `REGISTRY_USER` and `REGISTRY_TOKEN`, and the targets from `TARGETS_DIR`. So another host can ingest a source that runners cannot read.

- `sync.yml` must create each GHCR repository first, with the workflow token. That links the package to this repository. A package first pushed from outside is not linked, and the workflow token can never write to it.
- ⚠ An outside host must not use a maintainer's token. GHCR accepts only classic tokens, which can write every package of their owner. Use a dedicated account with write access to these packages only.
- Each script that pushes (`plan` for a withdrawal, `mirror-shard`, `stage`, `promote`, `index-write`) logs in with `--password-stdin`. The registry configuration is in its own temporary directory, which the script removes on exit.
- ⚠ `scripts/debloat-runner` runs only on a GitHub-hosted Linux runner, and fails elsewhere. Set `DEBLOAT=never` on another host. `PARALLEL` is 4 there by default, not 6.
- A push must stay inside GHCR's 10-minute upload limit. The largest file of a target sets the lowest upload rate it can use.
