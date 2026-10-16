# Tests

## The suites

| suite | files | needs |
| --- | --- | --- |
| `static` | `tests/static/*.sh`: shellcheck, actionlint, py_compile and the policy checks | `shellcheck`, `actionlint`, `jq`; `python3` when there is python to compile; `git` for the file modes |
| `unit` | `tests/unit/*.sh`: the wrapper and the scripts on fixed inputs, with no network outside the host | `curl`, `jq`; GNU tar for the database cases; `gpg` and `gpgv` for `70-plan.sh`; `python3` and `git` for parts of `60-status.sh`: `python3` runs its local listeners |
| `integration` | `tests/integration/*.sh`: a local registry and pacman in containers, oras on the host | docker or podman (`CONTAINER_RUNTIME`), curl, jq, tar, sha256sum, and network to pull the pinned images and oras |
| `worker` | `tests/worker/*.sh`: the Worker under `node --test` | node 22 or newer, and `sh` |

| file | checks |
| --- | --- |
| `static/10-shellcheck.sh` | every shell file outside `tests/fixtures/` passes shellcheck in the dialect of its first line |
| `static/20-actionlint.sh` | every workflow passes actionlint; only the message on the concurrency key `queue`, which actionlint 1.7.12 does not know, is ignored |
| `static/30-failures-stay-visible.sh` | no shipped script or workflow hides a failure; every curl call has a deadline, and so does every oras call in `scripts/` |
| `static/35-pipeline-traps.sh` | no pipeline in a shipped bash script ends in a reader that stops early; `client/pacman-oci` runs with no `pipefail` and is left out |
| `static/40-executable-bits.sh` | a shipped file with a `#!` line is 100755 in the git index; one without is 100644 |
| `static/50-workflow-policy.sh` | the shape of every workflow: permissions, timeouts, pins, no untrusted value in `run:`; artifact names that survive a re-run; each step that calls `gh workflow run`, run against a stub `gh`; the concurrency group of each kind of `ci.yml` run, evaluated; the concurrency queues |
| `static/55-issue-steps.sh` | the workflow steps that raise and clear issues run when they are needed: `stale-<target>` with `always()`, after a check step that stops before its job; `status.yml` job `worker` whatever `build` did, with the result of `build` through `env`; `check-status-site` with `always()`; `watch-schedules` in the jobs that watch the schedules, with `issues: write` |
| `static/60-targets.sh` | every target file parses and pins its images; one verify image; a plan slot for each target |
| `static/70-python.sh` | every python file compiles; every file in `client/` and `scripts/` is shell or python |
| `static/72-test-runner.sh` | `tests/run.sh` finds the files, runs one file, gates a live test, and fails a failed run |
| `static/75-renovate.sh` | Renovate can move every image pin, and merges only what CI can judge |
| `unit/10-tag-encoding.sh` | every package file maps to one tag, and no two files share one; no package tag is `latest`, a date, `staging`, `staging-<slug>`, `index` or `index-<slug>` |
| `unit/20-json-parser.sh` | the JSON parser reads every legal shape and refuses anything else |
| `unit/30-wrapper-urls.sh` | one manifest request per URL; a URL it cannot read is refused before the network |
| `unit/31-run-store.sh` | the run store: key, ownership, sweep, remover, host blacklist, the run's anonymous token |
| `unit/32-prefetch-plan.sh` | the argument rewrite, the print lines, the signatures written from `%g`, the size of a held `.part` |
| `unit/40-lib.sh` | the decisions of the sync on fixed inputs; also the tags of a ref (`staging_tag`, `index_tag`), the verify context, `registry_blob_probe` and `results_of_plan` |
| `unit/42-registry-faults.sh` | `stage`, `promote`, `mirror-file`, `verify-batch` and `index-write` against stand-ins for curl, oras and the container runtime: a registry or an image source that fails, refuses or limits them; the files stage verifies and its smallest canary; the files at fault of a failed batch; the rows, the verify credit and the writer guard of `index-write`; the re-run guard (`index_guard`); the registry sources of `mirror-file`, and `MIRROR_REPAIR` |
| `unit/45-dispatch-overdue.sh` | `scripts/dispatch-overdue` starts a workflow only when it is active and overdue; for `sync.yml` only a run of every target counts for the age, and a run of any kind that has not ended counts as busy |
| `unit/46-upstream-watch.sh` | `scripts/upstream-watch` against `tests/fixtures/status/fake-curl` (`F.code`, `F.headers`, a 302) and a stand-in for `gh`, with `scripts/dispatch-sync` as it is: a sync starts only when a URL answers other values than the state keeps, one run for the targets that change in one tick, the answer after the redirect counts; a change within `SYNC_MIN_INTERVAL`, a start that GitHub refuses, a run that waits and a dry run start nothing and keep the old state line, so the next tick sees the change again; a URL with no answer keeps its line; a host that failed is not asked again in the tick; no powerpc or disabled target is asked; lines that are not state lines are left out; `WATCH_BUDGET` |
| `unit/47-dispatch-sync.sh` | `scripts/dispatch-sync` against a stand-in for `gh`: one `sync.yml` run on `main` with every target in its `targets` input; nothing starts while a run waits (`queued`, `waiting`, `requested`, `pending`) or when `sync.yml` is not active, and exit 2 says so; a run in progress does not stop a start; a state or runs list that does not read, and a start that GitHub refuses, exit 1; a target name with a character outside `[a-z0-9_.-]` calls no `gh` |
| `unit/60-status.sh` | `status-collect`, `status-render` and `check-staleness` on fixtures, also with one registry read that fails and with no registry read at all; `check-staleness` within `STALENESS_BUDGET` and `status-collect` within `STATUS_BUDGET`, against a local `db_server` that never answers; both against a first `db_server` that is behind the second, and one that answers 200 with an HTML page; the Worker probe through to the signed URL (one that answers 403, a working host outside `githubusercontent.com`), and the database downloaded through the Worker; the synced badge, the times and the one script of the page, and the size table and badges |
| `unit/62-issues.sh` | the scripts that raise and clear issues, against a stand-in for `gh` (`tests/fixtures/issues/fake-gh`): `check-status-record`, `check-status-site`, `watch-schedules`, and `report` for `refused-<target>`; the count of promoted targets that `report` gives to `GITHUB_OUTPUT` |
| `unit/70-plan.sh` | `scripts/plan` on a signed repository: `<repo>.db.sig` and `<repo>.files.sig` are checked with `gpgv` against the keyring files (`PLAN_KEYRING_DIR`) before the database is used; a signature of a key the keyring does not hold, a signature of another file, and a database changed after it was signed each put the target in error |
| `unit/71-plan-index.sh` | `scripts/plan` with the index of a ref, against a curl stand-in and an oras stand-in: which files it mirrors, verifies and vouches for; the index states `absent`, `unread`, `invalid`, `ignored` and a private index; the withdrawal of index rows before their tags are written; the registry sources of a todo file; one upstream read per URL in a plan; `index_read` and `index_push` alone |
| `unit/80-fetchers.sh` | `fetchers/fetcher.sh` against a curl stand-in and faked curl-impersonate, node and venv-python clients: client selection, the per-host fallback order, the structural, `--sha256`, `--max-bytes`, `--header` and `--referer` checks, the HTML refusal, the retry backoff, the availability cache, the deadline, the dispatch of each client to its own program, `fetchers/self-check.sh`, `fetchers/install.sh --check`, the curl-impersonate asset choice, `fetchers/ci.sh` and `fetchers/drift.sh` |
| `integration/10-pipeline.sh` | the whole mirror against its own registry and upstream, each chain ending in `index-write` as the `summary` job does |
| `integration/20-client.sh` | the wrapper against its own registry, through faulty proxies |
| `worker/10-node.sh` | `node --test 'worker/test/*.test.js'` |
| `worker/live.sh` | a smoke test of the deployed Worker; only with `WORKER_LIVE=1` |

## Run the suites

Install the pinned tools first. Each one is a static binary for x86_64 or aarch64 Linux, checked by sha256.

```bash
scripts/install-test-tools /tmp/mirror-archlinux-tools
export PATH="/tmp/mirror-archlinux-tools:$PATH"
```

⚠ `install-test-tools` needs `curl`, `sha256sum` and `tar` on the host, `xz` to unpack shellcheck and curl, and `zstd` and `dd` to unpack bash.

Then run a suite, one file of a suite, or all four:

```bash
tests/run.sh static
tests/run.sh unit
CONTAINER_RUNTIME=podman tests/run.sh integration
tests/run.sh worker
tests/run.sh integration 20-client
tests/run.sh all
```

| form | does |
| --- | --- |
| `tests/run.sh` | the unit suite |
| `tests/run.sh SUITE` | every file of SUITE, in name order |
| `tests/run.sh SUITE FILE` | one file, by name (`20-client.sh` or `20-client`) or by path |
| `tests/run.sh all` | the four suites in turn; takes no FILE |
| `tests/run.sh --list SUITE` | prints the name of each file SUITE runs, one per line |

The exit status is 0 when every file passed, 1 when a file failed or no file ran, and 2 for usage. The summary names each failed file with the command that runs it again.

`ci.yml` makes its integration matrix from `tests/run.sh --list integration`. A new file gets its own job with no edit.

### Live tests

⚠ A file named `live.sh` talks to a deployed service. It runs only when `<SUITE>_LIVE=1`, also when the file is named. For `tests/worker/live.sh` the switch is `WORKER_LIVE=1`:

```bash
WORKER_LIVE=1 tests/run.sh worker live
```

### Tools that may be absent

A test that needs a tool can call `need_tool NAME DESC` (`tests/lib/harness.sh`). When the tool is absent, the test is skipped with a TAP `# SKIP` line. When `TESTS_REQUIRE_TOOLS` names the tool, the test fails instead.

```bash
TESTS_REQUIRE_TOOLS='shellcheck actionlint jq python3' tests/run.sh static
```

`50-workflow-policy.sh`, `70-python.sh`, `75-renovate.sh`, `45-dispatch-overdue.sh`, `46-upstream-watch.sh`, `47-dispatch-sync.sh`, `62-issues.sh` and `71-plan-index.sh` use `need_tool`. The static, unit and worker jobs of CI set `TESTS_REQUIRE_TOOLS`. The integration job does not.

⚠ Other tests handle an absent tool in their own way:

- `10-shellcheck.sh`, `20-actionlint.sh` and `worker/10-node.sh` fail when their tool is absent.
- Parts of `30-wrapper-urls.sh` and `31-run-store.sh` (dash), `40-lib.sh` and `60-status.sh` (GNU tar, git, python3) and `40-executable-bits.sh` (git) print a plain `ok` line that says they skipped. `TESTS_REQUIRE_TOOLS` does not turn these into failures.
- `71-plan-index.sh` skips as a whole, with one `# SKIP` line, when `tar` is not GNU tar.
- So the `bash-gawk` and `busybox` unit legs pass with parts of `60-status.sh` skipped.

### Integration options

| variable | effect |
| --- | --- |
| `CONTAINER_RUNTIME` | `docker` or `podman`; else `docker` when it is on PATH, then `podman` |
| `IT_ORAS_CACHE` | a directory that keeps the oras download between runs of `10-pipeline.sh` |
| `IT_KEEP` | `1` keeps the work directory, and prints its path |

Each run picks its ports at run time, and each container name carries the shell's pid and a random number. So several runs can share one host.

### In a container

The unit and static suites run in the pinned `archlinux:base`. Mount the tools last on PATH, so the image's own tools stay the ones under test:

```bash
image="$(sed -n 's/^verify_image = //p' targets/x86_64-core.conf)"
docker run --rm -v "$PWD:/work:ro" -v /tmp/mirror-archlinux-tools:/tools:ro -w /work "$image" \
  sh -c 'PATH="$PATH:/tools" exec bash tests/run.sh unit'
```

The image is the targets' verify image, so this command follows each Renovate update.

⚠ `40-executable-bits.sh` reads the git index. In a copy with no git index, it passes with one line that says it skipped.

## CI

| job | runs |
| --- | --- |
| `static` | `tests/static/72-test-runner.sh` with bash first, then `tests/run.sh static`; `TESTS_REQUIRE_TOOLS='shellcheck actionlint jq python3'` |
| `unit (dash-mawk)` | `tests/run.sh unit` on the runner, with dash and mawk; requires `jq curl python3` |
| `unit (bash-gawk)` | the same in the pinned `archlinux:base`; requires `jq curl` |
| `unit (busybox)` | the same in the pinned alpine image; requires `jq curl` |
| `integration` | one job per file of `tests/run.sh --list integration` |
| `worker` | `tests/run.sh worker` in the pinned `node:24-alpine` |
| `debloat` | `scripts/debloat-runner` on a real runner; a warning when it frees less than 1 GiB |
| `keyrings` | `scripts/keyring-files` against `targets/keyrings.sha256`: the keys that verify trusts from each `keyring_image` are the reviewed ones |

⛔ No CI job installs a package with a package manager. `scripts/install-test-tools` downloads pinned static binaries and checks each sha256. Its bash comes from Ubuntu's `bash-static` package, checked by sha256 and unpacked. Each unit leg checks that it runs the shell and the awk it is named for.

`72-test-runner.sh` runs first, on its own: a `run.sh` that hides failures would also hide this file's failure.

## Output

The output is TAP. Each file is one plan. A failed assertion prints what was measured and the command that reproduces it. A file with no assertion fails.

## Seen to fail

⛔ A test that never failed is not shown to test anything. So each test is seen to fail once:

1. Copy the repository.
2. Change one exact piece of text in one file of the copy.
3. Run the one test file, with `REPO_ROOT` set to the copy.
4. Record the assertion that failed.

The tree itself is never changed. An integration fault runs with its own registry and upstream ports.

### client/pacman-oci

| test | fault | observed |
| --- | --- | --- |
| unit/10-tag-encoding | a literal `_` before `p`, `c`, `a` or `u` is no longer escaped | not ok: `tag of a_pb-1-1-any.pkg.tar.zst` |
| unit/10-tag-encoding | upper case kept in tags, which GHCR folds together | not ok: `a name outside the mapping hashes: lshw-B.02.20-3-x86_64.pkg.tar.zst` |
| unit/10-tag-encoding | the 128-character tag limit off by one | not ok: `a name of 129 characters is hashed` |
| unit/10-tag-encoding | the hash form `index-<hex>` in place of `fn-<hex>` | 10 not ok, among them `real: no package tag is a reserved database tag`. The test of before the index tags gives 9 not ok, and passes that one |
| unit/20-json-parser | an escaped newline or tab accepted in a JSON string | not ok: `refused: an escaped newline, which could forge an output line` |
| unit/20-json-parser | data after the JSON document ignored | not ok: `refused: trailing data` |
| unit/30-wrapper-urls | an uncompressed `.pkg.tar` read as a database | not ok: `an uncompressed package` |
| unit/30-wrapper-urls | a database signature read from the moving tag | not ok: `core.db.sig is read by the content of the core.db beside it` |
| unit/30-wrapper-urls | a failed attempt leaves its `.part` behind | not ok: `a failed attempt removes the .part it was given` |
| unit/31-run-store | a failed signature request marks its host down | 3 not ok, among them `a database signature: no host is marked down, so the next file is still asked for` |
| unit/31-run-store | the sweep ignores the age of `,open` | not ok: `the sweep keeps a run whose ,open is fresh, and removes one whose ,open is old` |
| unit/31-run-store | the remover never touches `,open` | not ok: `the remover touches ,open within 3 s while the run is live` |
| unit/32-prefetch-plan | the size of a held `.part` read with `wc -c` | 2 not ok, among them `a .part the wrapper cannot read is sized from its metadata` |
| integration/10-pipeline | the blob's sha256 no longer checked | not ok: `the wrapper refuses a blob whose sha256 is not its descriptor's` |
| integration/20-client | no host is marked down; no transfer resumes; the background remover removes nothing | 12 not ok, among them `dead: a registry that answers 503: the second file makes no request`, `resume: the cut package was resumed with a Range request` and `main-root: no store file is left once pacman has ended` |
| integration/20-client | the prefetch keeps a whole file with no size and sha256 check | 7 not ok, among them `flip: one byte changed in each first answer: the prefetch keeps neither database` |
| integration/20-client | the batch check reads the `sha256sum` output one column off | 16 not ok, among them `main-du: the serial pass makes no network request` |
| integration/20-client | a transfer cut by its time limit never goes on in the next pass | not ok: `stall: the prefetch cut the stopped transfer and resumed it from 64 KiB` |
| integration/20-client | the prefetch makes one pass only | not ok: `resume: every blob cut in half: the prefetch resumed it, the serial pass made no request` |
| integration/20-client | a refused range keeps the 30 s stop of the attempts | 3 not ok, among them `norange: a plain Server that ignores Range: pacman -S big succeeds after its range is refused past 30 s` |
| integration/20-client | the wrapper of before the run's token | 18 not ok, among them `token: the prefetch reads the three packages, again with the token after the refusal` (3 where 6 is expected) and `token: one token request per repository and pacman run, 4 for -Sy and -S of two repositories` (7) |
| unit/31-run-store | the wrapper of before the run's token | 4 not ok, among them `the next call of the run sends the kept token first: no 401, no token request` (4 requests: the refused manifest, the token, the manifest, the blob) and `a kept token that the registry refuses is replaced: the file is read, and the store holds the new token` |
| unit/32-prefetch-plan | the wrapper of before the run's token | not ok: `a print run with PACMAN_OCI_NO_DUMMY=1` (got `no print run`) |

### scripts

| test | fault | observed |
| --- | --- | --- |
| unit/40-lib | `decide_push` pushes over a tag that holds other bytes | not ok: `write-once: other bytes under this name are never overwritten` |
| integration/10-pipeline | `mirror-file` pushes over a tag that holds other bytes | not ok: `a file whose bytes changed under its own name holds the target` |
| unit/40-lib | older and newer swapped in the behind rule | not ok: `core of 10-03 is not behind 10-02` |
| integration/10-pipeline | plan takes a database behind the promoted one | not ok: `an older upstream database is refused as behind` |
| unit/40-lib | a `/` allowed in a filename from a database | not ok: `db field check refuses a / alone, after a valid prefix` |
| unit/40-lib | staleness waits ten times too long | not ok: `stale: different, fetched longer ago than the tolerance` |
| unit/40-lib | an earlier snapshot may be promoted over a later one | not ok: `a later snapshot may be promoted` |
| integration/10-pipeline | promote no longer refuses an older snapshot | not ok: `promoting an older run's snapshot again is refused` |
| unit/40-lib | an item that left no result counts as pushed | not ok: `an item that left no result is counted as failed` |
| unit/40-lib | an unknown key in a target file ignored | not ok: `refused: an unknown key` |
| integration/10-pipeline | a lagging db_server that only dropped a package wins | not ok: `a lagging db_server that only drops a package does not move latest` |
| integration/10-pipeline | with no `%PGPSIG%`, the detached `.sig` is never fetched | not ok: `a database without %PGPSIG% stages` |
| integration/10-pipeline | the signature layer is not the `%PGPSIG%` (the decode loses its last base64 group) | not ok: `alpha-1:1.0+r2-1-any.pkg.tar.zst signature layer is its %PGPSIG%, decoded` |
| unit/40-lib | the keyring name check accepts anything | not ok: `refused: a keyring name with a leading -`, `refused: a keyring name with a /`, `refused: a keyring name that is a glob` |
| unit/40-lib | `keyring_image` accepted with no `keyring_platform` | not ok: `refused: keyring_image with no keyring_platform` |
| unit/40-lib | `keyring_from` may name another arch | not ok: `refused: keyring_from naming a target of another arch` |
| unit/40-lib | `db_check` accepts an unreadable member that is not NUL bytes | not ok: `db_check refuses an unreadable member that holds other bytes than NUL, and names it` |
| unit/40-lib | `db_check` refuses every unreadable member | not ok: `db_check accepts package directories whose desc is NUL bytes or empty, and names them` |
| unit/40-lib | `db_check` no longer compares records and members | not ok: `db_check refuses a desc that holds two records` |
| unit/40-lib | `db_records` no longer reads tar's own status: the pipeline keeps `\|\| rc=$?` in a shell without pipefail | not ok: `db_records refuses a database tar cannot read, and writes no record` (`status 0, 0 records`), and `db_check names a database tar cannot read` |
| unit/40-lib | the `MAX_SHARDS` clamp removed | not ok: `shards: x86_64 extra's seed wants 216 by bytes and gets MAX_SHARDS` |
| unit/40-lib | batches do not grow to fit `VERIFY_MAX_BATCHES` | not ok: `batches: x86_64 extra's seed wants 54, both limits grow, and it gets 36 to 40` |
| unit/40-lib | the build date written with no `Z` | not ok: `a build date as ISO 8601 UTC` |
| unit/40-lib | the "required key missing from keyring" pattern removed | not ok: `refusal: a primary key that expired is a signature reason` |
| unit/40-lib | the checksum pattern removed | not ok: `refusal: a checksum is not a signature reason` |
| unit/40-lib | the `QQ==` read turned off | not ok: the three `registry:` assertions on the dummy token's 200 and 404 |
| unit/40-lib | `registry_token_file` returns nothing | not ok: `registry: a second process reads the token the first one cached`, and the two after it |
| unit/40-lib | a refused cached token is not asked for again | not ok: `registry: a cached token the registry refuses is asked for again, once`, `registry: the cache then holds the new token` |
| unit/40-lib | the `MIRROR_FETCHER` branch removed from `fetch_upstream` | not ok: the three `fetch_upstream: MIRROR_FETCHER ...` assertions |
| unit/80-fetchers | `client_run` groups cloak-browser with curl-impersonate and playwright with chromium | not ok: `cloak-browser runs fetch.mjs through node`, `playwright runs fetch.py through its venv python` |
| unit/80-fetchers | the hard stop removed, so a client that hangs runs to its own end | not ok: `a client that hangs is stopped within --timeout` (the call took over 15 s) |
| unit/80-fetchers | `--sha256` read but never compared | not ok: `a body with another sha256 is refused` |
| unit/80-fetchers | `--client` takes a name no build defines | not ok: `an unknown client is refused`, `the refusal makes no request` |
| unit/80-fetchers | `body_validate any` accepts an HTML document | not ok: `a 200 that is an HTML document is not a body` |
| unit/80-fetchers | `--max-bytes` read but never compared | not ok: `a body over --max-bytes is refused` |
| unit/80-fetchers | `retry_delay` never grows | not ok: `retry_delay grows 2, 4, 8 and stops at 30` |
| unit/80-fetchers | the availability answer is not cached, or `--no-cache` is ignored | not ok: `a client probe is cached for its ttl`, `--no-cache asks the probe again` |
| unit/80-fetchers | a cached host preference that names no client is used anyway | not ok: `an unknown cached client is ignored` |
| unit/80-fetchers | `self-check.sh` decides on the manager alone, not on each available client | not ok: `self-check reads the URL through every available client` |
| unit/80-fetchers | the `body_validate` desc pipeline reads with `grep -q`, so tar ends by SIGPIPE and `pipefail` reads the whole check as failed | not ok: `a database with an early desc member is read`, and the fetcher logged `bad-body: the archive holds no package desc member` |
| unit/80-fetchers | the host preference is not written after a client reads a host | not ok: `the client that read the host is remembered`, `the next call for that host starts at curl-impersonate` |
| unit/80-fetchers | a 403 body is taken as an answer | not ok: `a 403 from curl falls back to curl-impersonate` |
| unit/80-fetchers | `drift.sh` does not read `.tag_name` | not ok: `drift reads the newest release tag`, `drift serves the value from its cache` |
| unit/80-fetchers | `client_run` drops the headers, so the request carries none | not ok: `an extra header reaches curl` |
| unit/80-fetchers | `drift.sh` only loads the cached values when the cache is fresh, so a stale cache whose lookup fails moves backwards | not ok: `a lookup that fails keeps the cached value` (rc 1, no value) |
| unit/80-fetchers | the curl-impersonate asset is the first that matches the architecture, so a musl or libcurl archive can be chosen | not ok: `curl-impersonate picks the CLI gnu asset for this arch` |
| unit/70-plan | `scripts/plan` that checks a `.db.sig` exists but never that it verifies | not ok: `plan: a signature of a key the keyring does not hold refuses the target` (state `pending`), `plan: the refusal names the file whose signature failed` |
| unit/70-plan | `db_sig_ok` passed the files signature for the database | not ok: `plan: a signature of the files database does not pass for the database` (state `pending`) |
| unit/70-plan | the signature read against the bytes before they were last changed | not ok: `plan: a database changed after it was signed is refused` (state `pending`) |
| unit/60-status | `status-render` line_chart legend class `"l" + slot_class(slot)`, so a named arch's swatch is `ls1` and names no stroke rule | not ok: `every chart mark names a defined slot class (no ls1, s-1 or l-1)` (class `line ls1`) |
| integration/10-pipeline | the `MAX_SHARDS` clamp removed | not ok: `MAX_SHARDS caps a target's shards`, `the plan logs that the shard cap binds` |
| integration/10-pipeline | `shard_count` always 1 | not ok: each target gets shards of its own |
| integration/10-pipeline | the `dev.pkgforge.mirror.upstream` annotation added again | not ok: the package manifest names no upstream server; two writers push byte-identical manifests |
| integration/10-pipeline | `Architecture = auto` | not ok: `verify writes Architecture from the target`; the aarch64 batch fails in the x86_64 image |
| integration/10-pipeline | `db_check` refuses unreadable members | not ok: `a database with a NUL-only package directory is planned`, `the NUL-only package directory is named`, `the plan summary names it` |
| integration/10-pipeline | `upstream_refused` always says no | not ok: upstream-refused packages listed, verdict passed, promoted, in the report |
| integration/10-pipeline | the report's refused list turned off | not ok: the report lists the upstream-refused packages |
| integration/10-pipeline | the trust guard turned off | not ok: `a trust root that accepts nothing excuses nothing` |
| integration/10-pipeline | `keyring_repo` emptied after `keyring_from`'s `latest` is read | not ok: `verify installs the keyring package from keyring_from's repository` |
| integration/10-pipeline | plan's `%PGPSIG%` condition reverted | not ok: a file signed again with the same bytes is planned, its layer repaired, promoted |
| integration/10-pipeline | the signature comparison turned off | not ok: `a signature layer that is not the %PGPSIG% fails verify, and is named`, `a batch with a bad signature layer is never promoted` |
| unit/40-lib | `fetch_upstream` with `--max-time` and no `--retry-max-time` | not ok: a server at 16 KiB/s gets 3 requests in about 13 s, over a deadline of 3 s |
| integration/10-pipeline | no share of `PLAN_BUDGET` per target | not ok: assertions 62 to 64 (a stalled first db_server), and the run takes 944 s |
| integration/10-pipeline | a failed db_server ends the db_server loop | not ok: assertion 61 |
| integration/10-pipeline | `fetch_sig` reads the shard's rotated order | not ok: assertion 108 (the `.sig` of a plain mirror becomes the layer) |
| unit/40-lib | `down_last` ignores the down marks | not ok: assertion 95 |
| unit/40-lib | `down_last` drops the hosts with no mark | not ok: assertion 94 |
| integration/10-pipeline | no host is marked down | not ok: assertion 110 (a server that answers 503 gets more than 3 requests) |
| integration/10-pipeline | the first failed server ends the search | not ok: assertion 109 |
| integration/10-pipeline | the unsigned list is not written to the staged manifest | not ok: assertions 42, 44, 45, 46 |
| integration/10-pipeline | plan ignores the unsigned list of `latest` | not ok: assertions 44, 45, 46 (a signature published later never reaches the mirror) |
| integration/10-pipeline | plan's step 4b turned off | 8 not ok, among them `a .sig made again upstream, with the database the same, plans that file alone` (got `current`) and `more than SIGCHECK_ESCALATE of one sample changed: every file with a detached signature only is planned` |
| unit/40-lib | an anonymous read uses the cached token | not ok: assertions 91, 92 |
| unit/40-lib | the report reads every summary, of any plan | not ok: assertions 96, 97, 99, 100 |
| unit/40-lib | `collect` reads verdicts of another digest | not ok: assertion 101 |
| integration/10-pipeline | no plan id is written | not ok: assertions 76, 37, 38 (an earlier attempt's result is read) |
| integration/10-pipeline | plan refuses a files database that leaves a package out | not ok: assertions 47 to 50 |
| integration/10-pipeline | verify runs `-Fl` over every name of the batch | not ok: assertion 50 |
| integration/10-pipeline | plan refuses a files database that names a package the database does not | not ok: `a files database that names a package the database does not is planned`, `the plan names the package only the files database names` |
| integration/10-pipeline | the file-name drift bound used when `FILES_DRIFT_MAX` is not set | 3 not ok: `a files database that lags 12 rebuilt packages of 40 is planned` (got `error`), `the plan names the 12 packages the files database names at an earlier file name`, `the refusal names how many packages the files database names` |
| integration/10-pipeline | plan no longer compares the sha256 of a file both databases name | not ok: `a files database that names a file of the database with other bytes is refused`, `the refusal names the file` |
| integration/10-pipeline | every `sig-refused` package excused | not ok: with no `%PGPSIG%`, a layer that is not upstream's `.sig` is not excused |
| unit/40-lib | `db_records` reads the pipeline's last stage instead of tar's, so a database tar cannot read whole gives records and exit 0 | 6 not ok, among them `not ok: a truncated database gives a non-zero status, not a partial record set` (expected 1, got 0, on the 20 of 40 packages before the cut) and `not ok: a zstd database with no zstd program gives a non-zero status` |
| unit/40-lib | the gpgv check of a signed database removed, so db_signed = yes accepts any .sig that exists | 9 not ok, among them `not ok: a signature by a key the keyring does not hold is refused` and `not ok: a signature by the key the keyring holds verifies` |
| integration/10-pipeline | `build-repo` signs on every build | not ok: an update is planned as new files only; `latest` does not move backwards |
| unit/40-lib | `scripts/lib.sh` of before the anonymous token flow | 11 not ok, among them `registry, anonymous: GHCR refuses QQ== with 401, and the anonymous token reads the manifest` (got `1 1 0`), `registry blob, anonymous: GHCR refuses QQ==, and the anonymous token reads the blob` and `registry_blob: a blob that trickles is given up within REG_BLOB_MAX_TIME, with one request` (status 124 after 30 s) |
| unit/42-registry-faults | `scripts/lib.sh` and `scripts/stage` of before `REG_LAST_CODE` | not ok: `stage: an anonymous read that answers 503 is asked 5 times` (1 read), `stage: an anonymous read that answers 503 sets error, naming HTTP 503, not private` (state `private`) |
| unit/40-lib | `rate_limited` with the old pattern `toomanyrequests\|429 Too Many` | not ok: `rate limit: oras's words for a 429 with no body` |
| unit/42-registry-faults | `lib.sh`, `stage`, `promote` and `mirror-file` of before `throttle_pause` | 4 not ok: `stage: three 429s on the staging push: three pauses, four pushes, staged` (got `0 0 3 error`), `promote: three 429s on the first tag: three pauses, seven tag calls, promoted` (got `1 0 3`), `promote: 429s past PROMOTE_RATE_WAIT fail it, naming the pauses`, `mirror-file: three 429s in oras's words: three pauses, the shard's throttle file, pushed` (got `1 0 no failed`) |
| integration/10-pipeline | `scripts/verify-batch` with no `disable-dirmngr` | not ok: `verify's key lockdown, network default: a WKD lookup on archlinux.org fails within 5 s` (exit 0 after 2 s: the key came by WKD); the case with no network passes either way |
| integration/10-pipeline | `scripts/mirror-file` of before the plain-server rule | 3 not ok: `a plain server that does not answer: the file upstream signs nowhere is pushed unsigned, naming the host` (got `failed its .sig could not be read (1 server(s) failed, 2 answered 404)`), `a plain server that does not answer: the target stages, verify excuses the file as sig-missing, and it is promoted` (got `held`), and the `db_server` case, whose why named no host |
| integration/10-pipeline | the `sig-missing` loop of `scripts/verify-batch` of before the plain-server rule | not ok: `a plain server that does not answer: the target stages, verify excuses the file as sig-missing, and it is promoted` (got `staged failed`) |
| integration/10-pipeline | `scripts/verify-batch` of before `@@keyring-failed` | not ok: `a keyring package that does not install: the verdict names it and pacman's error line` (got `the container ended with status 1 before its last phase`) |
| unit/40-lib | `registry_token` of before the `QQ==` answer for a repository GHCR does not show | not ok: `registry_token, anonymous: GHCR refuses the repository (403): QQ==, which reads it as absent` (got `1`: status-collect would show a target with no push yet in error) |
| unit/40-lib | `scripts/lib.sh` that takes a 401 of the token endpoint for an absence, as its 403 | 2 not ok: `registry, anonymous: a token endpoint that answers 401 is an error, not an absence` (got `4 2 1 401`), `registry_token, anonymous: a token endpoint that answers 401 gives no token, not QQ==` (got `0 QQ==`) |
| unit/42-registry-faults, in the busybox leg | `timeout --kill-after=N` in `stage`, `promote`, `mirror-file` and `verify-batch` | 14 not ok of 14: busybox 1.37 `timeout` says `unrecognized option: kill-after=10` |
| unit/40-lib | `scripts/lib.sh` `fetch_upstream` of before the HTTP code is logged | 3 not ok: `fetch_upstream: a 403 with a Cloudflare challenge is status 1, with one line` (got `1 0`), `fetch_upstream: the line names the URL, HTTP 403 and the challenge`, `fetch_upstream: a 503 with no cf-mitigated header is named with its code alone` |
| unit/40-lib | `scripts/lib.sh` `registry_token_get` with `--max-time 60` and no whole-call deadline | 3 not ok: `registry_token: the token request gets REG_TOKEN_MAX_TIME, ...` (got `60 none`), `registry_token: a token endpoint that stalls is given up within REG_TOKEN_MAX_TIME, and gives no token` (after 60 s, the length of the fake's stall), and `... a REG_TOKEN_MAX_TIME that is not a number of seconds is refused` (accepted) |
| unit/42-registry-faults | `scripts/verify-batch` of before the image mirrors | 5 not ok, among them `verify-batch: Docker Hub's pull limit: the digest comes from the first mirror, and the container runs it` (exit 1, verdict `could not pull ... in two attempts of 300 s`) and `verify-batch: a pull limit is not asked again: one pull from Docker Hub, one from the mirror` (two pulls from Docker Hub) |
| static/60-targets | five edits in a copy: a `docker.io` keyring image, a removed `# tag: aarch64`, another verify digest, renamed plan slots, a `keyring_from` that does not exist | one not ok for each edit, among them `every target verifies in the one image, on linux/amd64` |
| unit/42-registry-faults | `mirror-file` does not ask the target's own repository on a repush | not ok: `mirror-file: a repush reads the package from the target's own repository, with no upstream request` (got `pushed from https://up.test/core/os/x86_64`, 1 upstream request) |
| unit/42-registry-faults | `mirror-file` reads `sources.tsv` beside the shard file, not one level up | 7 not ok, among them `mirror-file: the sibling plan names gives the package, with no upstream request; MIRROR_REPAIR=0 stops no push` |
| unit/42-registry-faults | `mirror-file` takes status 4 of `registry_blob_probe` for an error | not ok: `mirror-file: a sibling that answers 404 is a quiet miss: not marked down, no line names it, and upstream gives the package`, `mirror-file: a sibling that answers 404, and every server 404: absent` (got `failed`) |
| unit/42-registry-faults | no `throttle_pause` on status 5 | not ok: `mirror-file: a sibling that answers 429 pauses the shard, is not marked down, and the next sibling gives the package` (got no pause) |
| unit/42-registry-faults | the down mark of a repository is not read | not ok: `mirror-file: a sibling marked down is not asked again by the shard` (got 1 read) |
| unit/42-registry-faults | the down mark of a repository written under `down_mark`'s host key | 3 not ok, among them `mirror-file: a sibling marked down is not asked again by the shard` |
| unit/42-registry-faults | the absent rule ignores a registry source that failed | not ok: `mirror-file: a sibling that answers 503, and every server 404: failed, not absent, naming the sibling` (got `absent`) |
| unit/42-registry-faults | the `MIRROR_REPAIR` check removed | not ok: `mirror-file: MIRROR_REPAIR=0 refuses a repush: failed, with no push, no blob read and no upstream request` (got `pushed`) |
| unit/42-registry-faults | the check of `index-listed.txt` removed | not ok: `mirror-file, a re-run: a file the live index lists gets no tag, and nothing is read for it` |
| unit/42-registry-faults | the whole re-run guard of `mirror-file` removed | 2 not ok: the case above, and `mirror-file, a re-run: with the live index unread, no tag is written, and the result says why` |
| unit/42-registry-faults | upstream also read after a registry source gave the bytes | 5 not ok, among them `mirror-file: a repush reads the package from the target's own repository, with no upstream request` |
| unit/42-registry-faults | every file counts as listed when the list has a line | not ok: `mirror-file, a re-run: a file the live index does not list is pushed` (got `failed the index lists it`) |
| unit/42-registry-faults | the unread check placed before the decision | not ok: `mirror-file, a re-run: with the live index unread, a tag that holds its file is present` (got `failed`) |
| unit/42-registry-faults | `index_listed` lists every row, not the `m` rows | not ok: `index_guard: one read of the live index lists its m rows, sorted, and no a row` |
| unit/42-registry-faults | `index_guard` writes an empty list when the read fails | 6 not ok, among them `index_guard: a live index that answers 503 is asked 3 times, and is unread` and `mirror-file, a re-run: with the live index unread, no tag is written, and the result says why` |
| unit/42-registry-faults | an absent index tag taken for a read that failed | not ok: `index_guard: no index tag lists no file` |
| unit/42-registry-faults | the artifact type check of `index_listed` removed | not ok: `index_guard: a live tag that is not an index of format 1 is unread` |
| unit/42-registry-faults | the `INDEX_TAG` grammar check of `index_guard` removed | not ok: `index_guard: an INDEX_TAG that is not index or index-<slug> is unread, with no read` (got 3 reads, and a list) |
| unit/42-registry-faults | one manifest try in `index_listed`, not 3 | not ok: `index_guard: a live index that answers 503 is asked 3 times, and is unread` |
| unit/42-registry-faults | the `TARGET` check of `index_guard` removed | not ok: `index_guard: a TARGET that is not a target name is unread, with no read` (got no reason) |
| unit/71-plan-index | todo is `!P`, not `!(P or I)`: the index does not spare a mirror | 9 not ok, among them `matrix: todo is what is not promoted or indexed, absent upstream, or signed now` (3 files too many) |
| unit/71-plan-index | the withdrawal of step 6b turned off | 5 not ok, among them `matrix: the rows of the todo files are withdrawn: one push of the index` (got 0) and `withdrawal: a push that fails puts the target in error` (got `pending`) |
| unit/71-plan-index | an index that reads only with the token does not make the package private | 5 not ok, among them `private: the index reads only with the token: ok, and PRIVATE=1` and `private: nothing to mirror, one file to verify: pending with no shard` (got 3 files to mirror: step 4b read the tags with no token) |
| unit/71-plan-index | the fetch cache keeps nothing | 2 not ok: `fetch cache: base-any.files, its signature and the database's are read once for both targets` (got 2 reads of each), `fetch cache: the .sig of a package that both targets ask again is read once` |
| unit/71-plan-index | a disabled target counts as a sibling | not ok: `sources: a todo file whose bytes the latest or the index of a sibling holds names it; other bytes, state a and a disabled target do not` |
| unit/71-plan-index | V with no check of the verify context | not ok: `context: another verify context verifies every indexed file again` (2 files not verified) |
| unit/71-plan-index | `index_read` keeps both lines of a filename given twice | 2 not ok: `index_read: 2 of 201 lines dropped (a filename twice) is ok, with 199 rows and no b7` (got 201 rows), `index_read: 3 of 202 lines dropped is more than 1%: invalid` (got `ok`) |
| unit/40-lib | the slug of a branch not cut to 40 characters | not ok: `tags: a 60-character name stops at 40 characters, with no - at the end` |
| unit/40-lib | the comments of the target file counted in the verify context | not ok: `verify context: an edit of the comments and blank lines of the target file does not change it` |
| unit/40-lib | `registry_blob_probe` takes `BLOB_UNKNOWN` for an error | not ok: `registry_blob_probe: 404 BLOB_UNKNOWN is 4, with no line` (got 1, with a line) |
| unit/40-lib, unit/42-registry-faults | `results_of_plan` reads the results of every plan | 2 not ok in 40-lib, among them `results_of_plan: the results.tsv and the lines of this plan, and nothing of another plan`; 4 not ok in 42, among them `index-write: the rows: the vouched files, the files pushed or present, the files absent upstream; no other plan's result` (got the row of n6) |
| unit/42-registry-faults | stage verifies `todo.tsv`, not `new.tsv` | 2 not ok, among them `stage: the files to verify are new.tsv less the files absent upstream, and the canary` (got `a c`) |
| unit/42-registry-faults | the smallest canary taken with no read of its tag | 3 not ok, among them `stage: the smallest canary is the smallest file whose tag holds its bytes` (got `b`) |
| unit/42-registry-faults | the files at fault keep the upstream-refused file | not ok: `verify-batch: a failed batch names its files at fault: the @@sigbad file and the refused one, not the upstream-refused one` (got `c` too) |
| unit/42-registry-faults | `verdict` does not write `faults-TARGET-BATCH.txt` | 3 not ok, among them `verify-batch: the EXIT trap writes the files at fault so far` |
| unit/42-registry-faults | the writer guard of `index-write` without its rule a (the live index is the one plan read) | 5 not ok, among them `index-write: the live index is the one plan read: one push of the index` (got 0 pushes) |
| unit/42-registry-faults | the writer guard lets any live index through | 3 not ok: `index-write: a live index that is not the one plan read is kept, with a warning`, `index-write: a live tag that does not read is kept`, `index-write: plan found no index, and one is live now: kept` |
| unit/42-registry-faults | `index-write` keeps the rows of the files at fault | 3 not ok, among them `index-write: the rows: the vouched files, the files pushed or present, the files absent upstream; no other plan's result` (got the row of n4) |
| unit/42-registry-faults | `index-write` writes when plan did not read the index | not ok: `index-write: an index plan did not read is not read or written` |
| unit/42-registry-faults | `index-write` counts verdicts about another staged digest | 56 of 56 passed: no test held it. With the case added: not ok `index-write: verdicts about another staged digest give no verify credit and remove no file at fault` (n2 and n3 got verified 1, and the row of n4 went) |
| unit/42-registry-faults | `index-write` takes no unsigned flag from the result | 3 not ok, among them `index-write: verify credit: the files of a passed batch get verified 1; unsigned comes from the result` (got `n7 m 0 0`) |
| integration/10-pipeline | `index-write` writes no row for a file pushed or present | 14 not ok, among them `held by the mirror: the index names the 2 files the run pushed, not verified` (got no row) and `the next run mirrors only the file that held the target, verifies all 3, and promotes` (it mirrored all 3) |
| integration/10-pipeline | plan verifies its todo files only, not the indexed files that are not verified | 5 not ok, among them `the next run mirrors nothing, verifies the file of the failed batch, and has no shard` (new.tsv empty) and `it verifies that file and the canaries only, and promotes` (got the canary alone: beta_pc was promoted with no verify) |
| integration/10-pipeline | `mirror-file` writes the tag of a file that the live index lists | 2 not ok: `run A's shard, run again as attempt 2, does not write the tag of a file the index lists`, `alpha's tag keeps the signature run B wrote` (the tag moved) |
| integration/10-pipeline | `index-write` keeps the rows of the files at fault | 4 not ok, among them `index-write drops the row of the file at fault` and `alpha's signature layer is its %PGPSIG% again, with the same package blob, and the target is promoted` (the next run mirrored nothing; verify failed again, and nothing was promoted) |
| integration/10-pipeline | `mirror-file` does not ask the target's own repository on a repush | not ok: `the next run mirrors alpha alone, with the package blob from its own repository` (got `pushed from http://127.0.0.1:<port>/x86_64/test-tamper`) |
| integration/10-pipeline | the writer guard of `index-write` lets any live index through | 2 not ok: `run A's index-write ends 0, and keeps the index of run B` (the tag moved), `run A's index-write says that it keeps the live index` |
| integration/10-pipeline | `index_push` titles the database layer of the index `<repo>.db`, not `ref.db` | 13 not ok, among them `a Server line at :index: the wrapper gives no test.db` (exit 0: the wrapper served the layer) and `run A plans alpha, signed again, and first withdraws its row from the index` (the index read as invalid). ⚠ 7 of the 13 come from the first verify of x86_64-test, which ended before its verdict with 3 runs on one host; the fault does not reach that step |
| unit/45-dispatch-overdue | `dispatch-overdue` counts every run for the age, as before the watch (`select(true)`) | 3 not ok: `sync.yml: a recent sync of one target and a full run 300 min old: workflow started`, `sync.yml: only runs of some targets: workflow started`, `... the warning says no run of every target` |
| unit/45-dispatch-overdue | the runs list read with `per_page=10` | not ok: `the runs list is the newest 100 runs on main` |
| unit/46-upstream-watch | the state keeps the new answer of every URL that answered, also when no sync started | 9 not ok, among them `a change that waits: the URL keeps its old answer, the target its old time` (got the new answer), `GitHub refuses the start: the URL keeps its old line, ...` and `the next tick that may start: the change is seen again, and the sync starts` |
| unit/46-upstream-watch | the HEAD request with no `--location` | 4 not ok, among them `first tick: the answer after the 302 counts, not the 302's own ETag` (got no line) and `two targets change in one tick: one run for both` (got `x86_64-extra` alone) |
| unit/46-upstream-watch | the header fields not reset at each status line of the dump, so a field of the 302 stays | 3 not ok: `first tick: the answer after the 302 counts, not the 302's own ETag` (got `"redirect-1"`), `two targets change in one tick: each URL keeps its new answer`, `a new ETag on the 302 alone: no sync` (got a sync of `aarch64-core`). With `tests/fixtures/status/fake-curl` of before, which wrote the last answer only, this fault passes |
| unit/46-upstream-watch | `SYNC_MIN_INTERVAL` compared with 0 | 5 not ok, among them `a change 15 min after its last start: no sync` (got a sync of `x86_64-core`) and `a change that waits: the log says why` |
| unit/46-upstream-watch | the `powerpc*` case changed so it matches no target | 2 not ok: `first tick: a u line for each URL that answered, and no t line` (got 5 u lines), `first tick: one HEAD per URL of 7, ...; no powerpc or disabled target is asked` (got `7 1`) |
| unit/46-upstream-watch | the `WATCH_BUDGET` check turned off | 3 not ok: `WATCH_BUDGET=1 and a db_server that takes 2 s: the next URL is not read, no sync starts` (got a sync, the URL `changed`), `WATCH_BUDGET: the URL not read keeps its line`, `WATCH_BUDGET: the warning names the budget` |
| unit/46-upstream-watch | no `down_mark` after a URL that curl could not reach | 2 not ok: `first tick: one HEAD per URL of 7, none to a host that failed before; ...` (got 7 requests), `first tick: OUT/urls.tsv names the 503, the host that does not resolve, and its URL not asked again` (got `curl 6` twice) |
| unit/47-dispatch-sync | `pending` left out of the statuses that wait | 3 not ok: `a run that is pending: exit status` (got 0), `a run that is pending: gh workflow run is called: no`, `a run that waits: the notice says so` |
| unit/47-dispatch-sync | `-f targets="$1"`: the first target only | not ok: `two targets: one run, with both in its targets input, on main` |
| unit/47-dispatch-sync | the target name check accepts any name | 5 not ok, among them `a target name with a ;: gh is not called at all` and `a target name with a space: exit status` |

### status

| test | fault | observed |
| --- | --- | --- |
| unit/60-status | `cron-tolerance --minutes` leaves out the gap from the last firing to the first | not ok: `interval: only on 29 February is 1461 days, 2103840 minutes` |
| unit/60-status | coverage keyed by file name only | 17 not ok, among them `x86_64-extra: a file counts only with the same name and sha256: 3 of 5` and the badge texts |
| unit/60-status | `failed_runs` always 1 | not ok: `worker: two failed runs in a row, failing since the first` |
| unit/60-status | the Location check accepts `http://` | not ok: `worker: a 302 to http fails: the Location must be https` |
| unit/60-status | the history keeps every line | not ok: `history keeps the last 2000 lines`, `the oldest lines go first and the new one is last` |
| unit/60-status | a background `<rect>` left unclosed | 18 not ok, among them `site: all 34 SVG files parse as XML, each with a title and its own dark style` |
| unit/60-status | the badge message left empty | 30 not ok: each `<site>: badge <name> carries its text: <words>` |
| unit/60-status | the narrow `<source>` left out of the page | not ok: `index.html references every chart and badge`, in each of the three sites |
| unit/60-status | `bucket()` keeps `None` points with no bucketing | not ok: `status-render site3 exits 0` |
| unit/60-status | the grace limit 30 days, not the tolerance | not ok: `check-staleness: no latest, added 13 days ago, tolerance 3: stale`, with the exit status and the added date |
| unit/60-status | the shallow-clone check never true | not ok: `check-staleness: in a shallow clone the age is unknown, so stale, never new`, `check-staleness: says that the clone is shallow` |
| unit/60-status | `read_json` returns a stub status | not ok: `status-render with no status.json exits 1`, `and names the file it looked for` |
| unit/60-status | `status-render` of before the partial-measurement rule | 52 not ok, among them `site5: badge x86_64 carries its text: x86_64 \| 100% \| 4.0 h \| 1 of 3 measured` (it said `100% · 4.0 h`), `site6: badge x86_64 does not say not mirrored` and `site7: badge speed carries its text: ... 73 d ago` |
| unit/60-status | `status-collect` of before `measured`, `worker.down` and the carried history | 10 not ok, among them `summary: no registry read: 0 promoted, 5 not read, 0 measured, every sum unknown` (got `0 null null 0 0 0 0 null`) and `history: x86_64-extra keeps its last measured files, marked carried` |
| unit/60-status | `WORKER_DOWN_SECONDS=0` | not ok: `worker: two failed runs 7 minutes apart are not down; down needs 50 minutes` |
| unit/60-status | no history carried for a target that a run did not read | not ok: `history: x86_64-extra keeps its last measured files, marked carried`, `site5: index.html says: x86_64 2026-10-14 03:00 77.7% 77.7%` |
| unit/60-status | `BENCH_MAX_AGE` 100 days | 4 not ok, among them `site7: a bench older than 2 days gives the speed badge the warning colour` |
| unit/60-status | a group with no snapshot is `not mirrored` also when its registry did not answer | 6 not ok, among them `site6: badge all does not say not mirrored` |
| unit/60-status | `check-staleness` of before the enabled date | not ok: `check-staleness: no latest, added disabled 43 days ago, enabled 1 day ago: new` |
| unit/60-status | `SYNCED_GOOD` 4 h | not ok: `synced-5h: 5 h ago is green` |
| unit/60-status | `SYNCED_LATE` 48 h | not ok: `synced-30h: 30 h ago is 1 d ago, red` |
| unit/60-status | `fmt_ago` says `30 min`, with no `ago` | not ok: `synced-30m: 30 min ago is green` |
| unit/60-status | `fmt_ago` rounds hours to the nearest | not ok: `synced-12h: 12 h 59 min ago rounds down to 12 h, yellow`, `site5: badge synced carries its text: synced \| 3 h ago` |
| unit/60-status | `fmt_ago` divides days by 0 | not ok: `synced-30h: status-render exits 0`, `synced-30h: 30 h ago is 1 d ago, red` |
| unit/60-status | `status-render` reads `created` only, never `fetched` | 5 not ok, among them `synced-fetched: a status.json with no created time falls back to the newest fetched time, 3 h ago` |
| unit/60-status | `status-collect` takes `last_synced` from `created` only | not ok: `no latest names a created time: last_synced falls back to the newest fetched time` |
| unit/60-status | `check-staleness` of before `STALENESS_BUDGET`, against 8 targets whose first `db_server` never answers | 5 not ok, among them `check-staleness: a db_server that never answers: every target has a state` (got 0: `timeout 120` ended the check at its first target) and `... is asked once in the run, not once per target` (got 2) |
| unit/60-status | `status-collect` of before `STATUS_BUDGET`, against the same 8 targets | 7 not ok, among them `status-collect: a db_server that never answers: the collect ends by itself and exits 0` (got 124 from `timeout 120`, no `status.json`) and `status-collect: no time left for a read: each target is measured, with an upstream.error that names STATUS_BUDGET` |
| unit/60-status | `upstream-db`, `check-staleness` and `status-collect` that take the first `db_server` that answers 200 | 7 not ok, among them `check-staleness: a first db_server behind the second does not stand for upstream: stale, exit 3` (got `current`), `check-staleness: an HTML page that answers 200 is refused, ...` (got `stale`) and `status-collect: upstream is the second db_server when the first is behind it, ...` |
| unit/60-status | `status-collect` whose Worker probe does not follow the 302, and judges the Location host | 11 not ok, among them `worker: a signed URL that answers 403 to the runner fails the probe, whatever the 302 looks like` (got `ok` true, `worker.ok` true), `worker: a working blob host outside githubusercontent.com passes, marked location_unexpected` (got `ok` false) and `the smallest database of a target with latest, downloaded through the Worker, is the one latest names` (got no download) |
| unit/60-status | `worker.median_seconds` over every probe, the download too | not ok: `worker: the median answer time is of the 7 probes, 0.4 s; the 9 s download is left out` (got 0.45 and 450 ms) |
| unit/60-status | `status-render` with no signed URL, cache and unexpected host in the probe table | 5 not ok: `<site>: index.html says: pkg-containers.githubusercontent.com hit ok` in four sites, and `site: a probe whose redirect host is outside githubusercontent.com is shown as a warning that passes` |
| unit/60-status | `status-render` with no list of the `db_server` hosts not taken | 4 not ok: `<site>: index.html says: https://up.test/loong64/core 1 db_server(s) not taken https://down.test/loong64/core : curl 6` |
| unit/60-status | `status-collect` takes the oldest time for `last_synced` | 14 not ok, among them `summary: last_synced is the newest of each target's created time, or its fetched time` and `site: badge synced carries its text: synced \| 2 h ago` |
| unit/60-status | `status-collect` keeps the fraction of `created` | 19 not ok, among them `mirror.created is latest's org.opencontainers.image.created, the fraction cut; null when latest names none` |
| unit/60-status | `mirror.created` is `""` in place of `null` | 3 not ok, among them the `mirror.created` test and `summary: no registry read: last_synced is unknown` |
| unit/60-status | `last_synced` is `""` when no time is known | not ok: `summary: no registry read: last_synced is unknown` |
| unit/60-status | `last_synced` is a jq error when no manifest names a created time | 5 not ok, among them `no latest names a created time: the collect measures and exits 0` |
| unit/60-status | `<time>` text with no ` UTC` | 24 not ok, among them `<site>: every <time> has a datetime ending in Z and shows that time as UTC text` in each of the six sites |
| unit/60-status | a `datetime` with no `Z` | 6 not ok: `<site>: every <time> has a datetime ending in Z and shows that time as UTC text` |
| unit/60-status | the first history point as plain text | 6 not ok, among them `site: index.html shows no time outside a <time> element` |
| unit/60-status | a second `<script>` | 6 not ok: `<site>: index.html has one script, inline, and no other` |
| unit/60-status | the script with no `timeZoneName` | 6 not ok: `<site>: the script sets each <time> title to the local time, its time zone and its age, after load` |
| unit/60-status | `<body onload="0">` | 6 not ok: `<site>: index.html has no event handler attribute and no javascript: URL` |
| unit/60-status | rows of the size table with no `data-target` | 6 not ok: `<site>: the size table has a row per architecture, per repository and one total row` |
| unit/60-status | an architecture row that leaves out its last repository | 6 not ok: `<site>: size table: each architecture row is the sum of its targets` |
| unit/60-status | a total row that leaves out the first target | 6 not ok: `<site>: size table: the total row is the sum of every target` |
| unit/60-status | a files cell that shows the bytes | 6 not ok: `<site>: size table: each cell shows its value in GiB or in files` |
| unit/60-status | a target with no `latest` counts as not read, not as 0 | 21 not ok, among them `site: badge size does not say measured` and `site: size table: each repository row holds its target's mirror and upstream bytes and files` |
| unit/60-status | no size badge for the last architecture | 24 not ok, among them `site: a size badge for each architecture (aarch64 loong64 x86_64) parses as XML` |
| unit/60-status | the size badges of the architectures with no `</svg>` | 31 not ok, among them `site: a size badge for each architecture (aarch64 loong64 x86_64) parses as XML` |
| unit/60-status | the group labels of `charts/size.svg` with no sum | 5 not ok: `<site>: chart size shows ... x86_64 · 1.6 KiB of 2.4 KiB, 2 of 3 measured ...` |
| unit/60-status | an architecture outside `ARCH_ORDER` given a named architecture's slot, so two architectures share a swatch | not ok: `every named architecture has a swatch of its own, and none of them is the grey`, `no named architecture shares the grey swatch` |
| unit/60-status | two architectures outside `ARCH_ORDER` given the same grey swatch | 6 not ok, one per site: `<site>: two architectures outside ARCH_ORDER get two different swatches` |
| unit/60-status | the log scale of `charts/history-age.svg` guarded so a zero range cannot divide by zero | 448 of 448 pass with the guard, because no fixture has a sync interval under 8 minutes. Reached from a config change: `scripts/cron-tolerance` returns 5 for a `*/5 * * * *` cron, and with an empty history the scale's two ends are both 0.25 h |
| unit/60-status | the three PowerPC arches and the two PowerPC repositories left out of `ARCH_ORDER` and `REPO_ORDER` | not ok: `an architecture outside ARCH_ORDER is given a grey step of its own, not the plain grey`, with `powerpc64le` then outside the order |

### issues

| test | fault | observed |
| --- | --- | --- |
| unit/62-issues | no `scripts/check-status-record` and no `scripts/check-status-site` | 12 of 12 not ok |
| unit/62-issues | `check-status-record` takes every build for `success` | not ok: `a build that failed raises status-down; the fresh record still clears worker-down` (got `comment 12;close 12`, no `open status-down`), `the status-down body names the build result and the run` |
| static/55-issue-steps | `status.yml` of before the `status-down` check, and `watchdog.yml` with no `check-status-site` step | not ok: `job worker runs whatever build did, so a build that fails raises status-down` (its `if` names `needs.build.result == 'success'`), `job worker gives scripts/check-status-record the result of build, through env`, `job staleness checks the status record and its copy on Pages, with always()` |
| unit/62-issues | `watch-schedules` that runs the two checks of before it, and raises no issue | 6 not ok, among them `watch-schedules: the last scheduled runs are 10 days old: schedules-stopped is raised, and the run stays red (exit 3)` (got exit 3 and no issue call) and `... a workflow disabled by hand raises schedules-stopped, ...` |
| unit/62-issues | `report` of before `refused-<target>` | not ok: `report: 20 upstream-refused files of a promoted target raise refused-<target>; the run stays green` (got exit 0 and no issue call), `report: the refused-<target> body lists the files ...`, `report: a later promoted run with none clears refused-<target>` |
| static/55-issue-steps | `watchdog.yml` and `sync.yml` of before `watch-schedules` | not ok: `job schedules runs scripts/watch-schedules with issues: write, ...`, `job keepalive runs scripts/watch-schedules with issues: write, ...` |
| unit/62-issues | `report` with no `output_promoted` after the table | 2 not ok: `report: a promoted target gives promoted=1 to GITHUB_OUTPUT, for the status kick of sync.yml`, `report: a held target gives promoted=0 to GITHUB_OUTPUT, also when the run fails` (both got nothing) |

### worker

| test | fault | observed |
| --- | --- | --- |
| worker/test (cache) | cache keys on `https://cache.invalid` | not ok: `every cache key is on the request host, under /__cache/v1` |
| worker/test (cache) | 404 answers not stored under the `loc` key | not ok: `a repeat request is one cache lookup and no subrequest` |
| worker/test (cache) | no 600 s cap on the signed URL time to live | not ok: TTL 880 where 600 is expected |
| worker/test (cache) | a URL with no `se` stored for 600 s | not ok: `a signed URL with no se is not stored` |
| worker/test (cache) | no `x-mirror-cache` on a 302 | 2 not ok, among them `x-mirror-cache: miss when the answer is stored, hit when it comes from the loc entry` |
| worker/test (cache) | no log for a signed URL with no usable `se` | not ok: `a signed URL with no usable se: asked again each time, logged once, x-mirror-cache: nostore` |
| worker/test (cache) | a `loc` hit says `miss` | not ok: `x-mirror-cache: miss when the answer is stored, hit when it comes from the loc entry` |
| worker/test (cache) | `storeAnswer` says that it stored nothing | not ok: `x-mirror-cache: miss when the answer is stored, hit when it comes from the loc entry` |
| worker/test (cache) | the package-with-sig time to live 86400 | not ok: manifest TTLs |
| worker/test (cache) | the layer count check uses `>= 1` | not ok: `a package manifest with a second layer of the file name is not kept 6 h` |
| worker/test (cache) | the `loc` entry ignores the manifest entry | not ok: `a latest redirect never outlives the latest manifest entry, so a new latest shows within 30 s` |
| worker/test (cache) | no `ctx.waitUntil(prewarmSig)` | not ok: `a package answer fills the .sig entry: the .sig is then one lookup and no subrequest` |
| worker/test (cache) | the prewarm starts after the package answer | not ok: `a package request asks for the .sig blob at the same time as the package blob` |
| worker/test (cache) | `cache.match` exceptions not caught | not ok: `a cache that fails is logged, and the request still gets its answer from GHCR` |
| worker/test (ghcr) | no `signal` on fetch | not ok: `every subrequest has a 10 s deadline, the anonymous token and no redirect followed` |
| worker/test (ghcr) | a blob 200 returned as is | not ok: `a blob that GHCR answers with 200 gets 502: the Worker never sends the bytes` |
| worker/test (ghcr) | the Location https check removed | not ok: `a Location that is not https, or not a URL, gets 502 and is not stored` |
| worker/test (ghcr) | a Location host outside `*.githubusercontent.com` refused with 502 | not ok: `a Location on an https host outside *.githubusercontent.com is served, marked, and logged once` |
| worker/test (ghcr) | no `x-mirror-blob-host` header | not ok: `a Location on an https host outside *.githubusercontent.com is served, marked, and logged once` |
| worker/test (ghcr) | `logOnce` logs on every call | not ok: `a Location on an https host outside *.githubusercontent.com is served, marked, and logged once` |
| worker/test (ghcr) | the `@sha256` pin not compared | not ok: `an @sha256 pin whose manifest hashes to another value gets 502 and is not stored` |
| worker/test (ghcr) | `ghcr()` returns every refusal of `Bearer QQ==`: no token flow | 4 not ok, among them `GHCR refuses Bearer QQ==: one token request, then every file reads with that token` (502 where 302 is expected) |
| worker/test (ghcr) | the outermost `catch` throws again | not ok: `an unexpected error inside the Worker gets 502 with retry-after, not an error page` |
| worker/test (ghcr) | a refusal of the kept token returned as is | not ok: `a kept token that GHCR refuses is replaced once; with no new token the 502 names the kept token` |
| worker/test (ghcr) | the 502 names `Bearer QQ==` when the kept token was refused | not ok: `a kept token that GHCR refuses is replaced once; with no new token the 502 names the kept token` |
| worker/test (ghcr) | the 64 KiB byte cap removed | not ok: `a manifest over 64 KiB with no or a false content-length is cut at 64 KiB` |
| worker/test (paths) | `TAG_RE` accepts every tag | not ok: `any other tag gets 404 with no subrequest, staging and index included` |
| worker/test (paths) | `TAG_RE` accepts `index` | not ok: `any other tag gets 404 with no subrequest, staging and index included` |
| worker/test (paths) | `TAG_RE` accepts `index-` and letters | not ok: the same test, on `x86_64/core:index-wip` |
| worker/test (paths) | no `decodeURIComponent` | not ok: `a percent-encoded file name is decoded before its tag is made` |
| worker/test (paths) | HEAD answered with the GET body | not ok: `HEAD gets the same answer as GET, with no body` |
| worker/test (tags) | the `_u` escape only for `p`, `c`, `a` | not ok: `tagOf matches client/pacman-oci --tags for every name in tests/fixtures/filenames.txt` |
| worker/test (config) | `head_sampling_rate = 0.01` | not ok: `wrangler.toml sets the compatibility date, the flags, the CPU limit and the logs` |
| worker/10-node | a node shim that reports v20.18.0 | not ok: `node is 22 or newer` |
| worker/live | run against the deployed version 1 | 3 of 28 not ok: `:staging` gets 302, `%2B` gets 404 |

76 faults, each applied alone to a copy of `worker/`, were each caught. Every one of the 59 node tests was seen to fail at least once.

### policy and tools

| test | fault | observed |
| --- | --- | --- |
| static/10-shellcheck | an unquoted expansion in `scripts/plan` | not ok: `shellcheck -s bash scripts/plan` |
| static/10-shellcheck | `script_kind` returns `other` for bash | not ok: `the walk finds tests/run.sh` |
| static/20-actionlint | a job reads an output that does not exist | not ok: `actionlint .github/workflows/sync.yml` |
| static/30-failures-stay-visible | a failure swallowed with `\|\| true` | not ok: `scripts/stage hides no failure` |
| static/30-failures-stay-visible | a curl call with no deadline | not ok: `scripts/install-oras: every curl has a connect deadline and a transfer or stall deadline` |
| static/30-failures-stay-visible | an oras call with no deadline | not ok: `scripts/promote: every oras call has a deadline` |
| static/35-pipeline-traps | a pipeline that ends in a reader that stops early | not ok: `scripts/install-oras: no pipeline ends in a reader that stops early` |
| static/40-executable-bits | a script committed without its executable bit | not ok: `scripts/plan is mode 100755 in the index` |
| static/40-executable-bits | a `#!` line added to `scripts/lib.sh` | not ok: `scripts/lib.sh has no #! line, so it stays 100644` |
| static/55-issue-steps | `watchdog.yml` of before the step of its own for `stale-<target>` | not ok: `the step that raises or clears stale-<target> runs with always() ...`, `the check-staleness step stops before the job does` |
| static/50-workflow-policy | a job with no `timeout-minutes` | not ok: `.github/workflows/watchdog.yml: every job has timeout-minutes` |
| static/50-workflow-policy | a dispatch input expanded inside a `run:` block | not ok: `.github/workflows/sync.yml: no untrusted value is expanded inside a run: block` |
| static/50-workflow-policy | an action pinned by tag | not ok: `.github/workflows/ci.yml: every action is pinned by commit` |
| static/50-workflow-policy | a call to the packages DELETE API | not ok: `no script or workflow deletes a package or a version` |
| static/50-workflow-policy | `pages: write` in `ci.yml` job `static`; `contents: write` in `sync.yml` job `plan`; `id-token: write` in `watchdog.yml` job `staleness` | not ok: `pages, id-token and contents write only where the status site needs them`, once for each workflow |
| static/50-workflow-policy | `keep-schedules-enabled` skips `watchdog.yml` | not ok: `.github/workflows/watchdog.yml has a schedule, and keep-schedules-enabled enables it` |
| static/50-workflow-policy | `status.yml` of before the per-attempt Pages artifact; then the output of `build` renamed `pages-...` | not ok: `.github/workflows/status.yml: a re-run does not stop on an artifact of the same name`, each time |
| static/50-workflow-policy | `overwrite: true` removed from one `upload-artifact` of `sync-target.yml` | not ok: `.github/workflows/sync-target.yml: a re-run does not stop on an artifact of the same name` |
| static/50-workflow-policy | `sync.yml` of before the state check in `report` | not ok: `.github/workflows/sync.yml, the run: block at line 323: skips a workflow that is not active, and names its state` (exit 1 on the stub's HTTP 422) |
| static/50-workflow-policy | `exit 0` where the state does not read | not ok: `... fails when the workflow's state does not read` |
| static/50-workflow-policy | `ci.yml` of before the run-id group | not ok: `.github/workflows/ci.yml: two pushes to main and a dispatch get three concurrency groups, so none cancels another's pending run` (all three `ci-refs/heads/main`) |
| static/50-workflow-policy | `sync.yml` with no `queue: max`; then with `cancel-in-progress: true` | not ok: `.github/workflows/sync.yml: the group sync queues every pending run, so a dispatch waits its turn`; then also `every concurrency queue is single or max, and max never cancels in progress` |
| static/20-actionlint | the `queue` ignore removed | not ok: `actionlint .github/workflows/sync.yml` (`unexpected key "queue" for "concurrency" section`) |
| static/60-targets | a verify image pinned without a tag | not ok: `targets/x86_64-core.conf pins its verify_image as name:tag@sha256` |
| static/60-targets | the six PowerPC target files deleted, leaving six plan slots and nine keyring lines with no target | two not ok: `sync.yml has one plan slot per enabled target, and no slot without one` (21 slots for 15 targets) and `every keyring line in targets/keyrings.sha256 belongs to an enabled target's keyring_image` (no enabled target pins ppc ppc64 ppc64le). Before these two checks the deletion left both suites green |
| static/60-targets | `keyring_platform` of one architecture set to another architecture's platform, which still pulls and pulls the wrong keyring files | not ok: `targets/powerpc64le-base.conf: keyring_platform linux/ppc64 is the platform of the ppc64le image`, and the same for an aarch64 target set to `linux/aarch64`. Before the check this passed: the field was only tested for being present |
| static/70-python | a `#!python3` file with a syntax error | not ok: `python3 -I -m py_compile scripts/status-render` |
| static/70-python | a data file `scripts/notes.txt` | not ok: `scripts/notes.txt is a shell or a python script` |
| static/70-python | no python3, with `TESTS_REQUIRE_TOOLS=python3` | not ok: `python3 is on PATH, to compile the python in the tree`; without the variable, `# SKIP python3 is not on PATH` |
| static/72-test-runner | `gated()` true for every file | not ok: every `--list` and run assertion; the list is empty and nothing runs |
| static/72-test-runner | the live gate removed | not ok: `--list worker leaves out live.sh while WORKER_LIVE is not 1`, `worker does not run live.sh while WORKER_LIVE is not 1`, `a named live.sh does not run either` |
| static/72-test-runner | the failed-file count never grows | not ok: `a failing file fails the run` |
| static/75-renovate | the `# tag: base` line removed from a target | not ok: `targets/x86_64-core.conf: the regex manager matches each of its 1 pin(s)` |
| static/75-renovate | a `# tag: 3.21` marker over an `alpine:3.22` pin | not ok: `.github/workflows/ci.yml: each '# tag:' marker names the tag of its pin` |
| static/75-renovate | `tests/` removed from `managerFilePatterns` | not ok: `tests/integration/10-pipeline.sh: the regex manager reads it (3 pin(s))` |
| static/75-renovate | `major` added to the automerge rule | not ok: `no rule in .github/renovate.json automerges a major update` |
| static/75-renovate | `platformAutomerge: true` | not ok: `.github/renovate.json sets platformAutomerge to false` |
| static/75-renovate | `ignorePaths` removed | not ok: `.github/renovate.json sets ignorePaths, and no entry is a tests directory` |
| static/75-renovate | the keyring images set to automerge, with no `keyrings` job in ci.yml | not ok: `the keyring images merge on their own only behind ci.yml job keyrings` |
| ci.yml job `keyrings` | one sha256 in `targets/keyrings.sha256` changed | the job fails, prints the diff, and names the file to update |
| ci.yml job `keyrings` | one hex digit of the `ppc64 archpower.gpg` line changed, the other eight ppc lines as they are | the computed lines and the file differ, so the job fails. Measured 2026-10-15 against the three real `keyring_image`s, pulled with `oras` and their keyring layers extracted: the committed nine ppc lines are identical to what `scripts/keyring-files` computes (`diff` exit 0), and one changed digit is not equal |

## What the integration suite drives on every run

These are not code faults. They are hostile or broken inputs, built by `tests/fixtures/build-repo`, or served by a web server that stands in for a registry that lies. The suite fails when the mirror accepts any of them.

| input | must end as |
| --- | --- |
| more shards wanted than `MAX_SHARDS` | capped, and the plan says so |
| two writers of the same files | manifests of the same digests |
| a database with a NUL-only package directory | planned, with the directory named |
| a database with an unreadable member that is not NUL bytes | refused, with the member named |
| another arch | verified in the x86_64 image with `Architecture` from the target |
| a package that upstream signs nowhere, and one signed by an expired key | upstream-refused: listed, and the snapshot promoted |
| the same batch with no trust root | failed: nothing is excused |
| a WKD lookup of a packager's key in the verify container | fails within 5 s, with the network on and off |
| a keyring package name that the repository does not hold | failed; the verdict names the package and pacman's `target not found` line |
| a keyring package that only `keyring_from` holds | installed from that target's `latest`, pinned by digest |
| an upstream database older than the promoted one | `behind`; `latest` does not move |
| a file signed again with the same bytes | planned; its signature layer repaired under the same tag |
| a signature layer that is not the `%PGPSIG%` | verify fails and names the file; never promoted |
| a file whose bytes change under its own name | `replaced`; the tag does not move |
| a new file whose tag already holds other bytes | `replaced`; the tag does not move |
| two db_servers, each ahead of the other on one package | `held` |
| a files database that lags 12 rebuilt packages of 40 | planned; the 12 packages named |
| a files database that names none of the packages of the database | refused, with the count named |
| a package signed by a key nobody trusts | upstream-refused: listed, and the snapshot promoted |
| a file that upstream signs nowhere, with a plain server that refuses every connection | pushed unsigned, the closed host named; upstream-refused as `sig-missing`; promoted |
| the same with the closed host as a `db_server` | `held`, the closed host named |
| a database with no `%PGPSIG%` | each new signature layer is upstream's detached `.sig` |
| a db_server, listed first, that lags by one dropped package | `latest` does not move |
| with no `%PGPSIG%`, a signature layer that is not upstream's `.sig`, written after stage | verify fails: the mirror is at fault |
| with no `%PGPSIG%`, a `.sig` that upstream makes again, the database the same | planned alone; its layer repaired with the same package blob; promoted |
| more `.sig` files made again in one sample than `SIGCHECK_ESCALATE` | every file with a detached signature only is planned, with a warning |
| a run that a `db_server` with no answer holds for one file | the index names the files it pushed; the next run mirrors only that file, verifies all of them, and promotes |
| a batch that fails with no file at fault: its `VERIFY_BUDGET` ends before its container starts | the index keeps the verify credit of the batches that passed; the next run mirrors nothing, verifies the file of that batch and the canaries, and promotes |
| a signature layer changed on the registry after the stage, under a file the index names | verify names the file at fault, and its row goes; the next run repairs the layer with the package blob of its own repository, and promotes |
| the mirror job and `index-write` of an older run, run again after a newer run wrote the index | the re-run writes no tag that the index lists; the newer index is kept |
| a Server line at `:index` | the wrapper gives no database |
| a manifest whose bytes are not the pinned digest | refused by the wrapper |
| a manifest with two layers of one name | refused by the wrapper |
| a package manifest with no signature layer | refused by the wrapper, with a message |
| a blob whose size or sha256 is not its descriptor's | refused by the wrapper |
| a manifest over 64 KiB | given up within 20 s |
| a database signature whose snapshot moved on | not paired; the wrapper misses |

`20-client.sh` adds these. The first six go through proxies of its own:

| input | must end as |
| --- | --- |
| a registry that answers 503 | the second file misses in under 1 s, with no request; a `.sig` is still asked for |
| every blob cut in half | the install succeeds; the cut package resumes with a Range request |
| a blob that stops after 64 KiB for 40 s | the install takes less than 20 s; the transfer resumes from 64 KiB |
| one byte changed in the first answer for each blob | the prefetch keeps nothing; each file is read again alone; the install succeeds |
| a registry that refuses the dummy token, and gives an anonymous token | one token request per repository and run; the prefetch reads every file with it; the serial pass makes no request; the refusal is said once |
| the same with `PACMAN_OCI_NO_DUMMY=1` | the same, and no refusal is said |
| a plain Server of its own that ignores Range, and stops a large file for 35 s | the install succeeds; the refused range is followed by one fetch from zero |
| a provider other than the default | the prefetch takes the first provider; the chosen one is read alone |
| two repositories with no database signature, under the sandbox | both signatures answered with an empty file; `-Sy` takes less than 1.9 s |
| the same with no sandbox | both stay misses; `-Sy` takes 4 s or more |
