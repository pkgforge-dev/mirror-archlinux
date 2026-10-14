# Tests

## The suites

| suite | files | needs |
| --- | --- | --- |
| `static` | `tests/static/*.sh`: shellcheck, actionlint, py_compile and the policy checks | `shellcheck`, `actionlint`, `jq`; `python3` when there is python to compile; `git` for the file modes |
| `unit` | `tests/unit/*.sh`: the wrapper and the scripts on fixed inputs, with no network | `curl`, `jq`; GNU tar for the database cases; `python3` and `git` for parts of `60-status.sh` |
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
| `static/60-targets.sh` | every target file parses and pins its images; one verify image; a plan slot for each target |
| `static/70-python.sh` | every python file compiles; every file in `client/` and `scripts/` is shell or python |
| `static/72-test-runner.sh` | `tests/run.sh` finds the files, runs one file, gates a live test, and fails a failed run |
| `static/75-renovate.sh` | Renovate can move every image pin, and merges only what CI can judge |
| `unit/10-tag-encoding.sh` | every package file maps to one tag, and no two files share one |
| `unit/20-json-parser.sh` | the JSON parser reads every legal shape and refuses anything else |
| `unit/30-wrapper-urls.sh` | one manifest request per URL; a URL it cannot read is refused before the network |
| `unit/31-run-store.sh` | the run store: key, ownership, sweep, remover, host blacklist |
| `unit/32-prefetch-plan.sh` | the argument rewrite, the print lines, the signatures written from `%g`, the size of a held `.part` |
| `unit/40-lib.sh` | the decisions of the sync on fixed inputs |
| `unit/45-dispatch-overdue.sh` | `scripts/dispatch-overdue` starts a workflow only when it is active and overdue |
| `unit/60-status.sh` | `status-collect`, `status-render` and `check-staleness` on fixtures, also with one registry read that fails and with no registry read at all |
| `integration/10-pipeline.sh` | the whole mirror against its own registry and upstream |
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

`50-workflow-policy.sh`, `70-python.sh`, `75-renovate.sh` and `45-dispatch-overdue.sh` use `need_tool`. The static, unit and worker jobs of CI set `TESTS_REQUIRE_TOOLS`. The integration job does not.

⚠ Other tests handle an absent tool in their own way:

- `10-shellcheck.sh`, `20-actionlint.sh` and `worker/10-node.sh` fail when their tool is absent.
- Parts of `30-wrapper-urls.sh` and `31-run-store.sh` (dash), `40-lib.sh` and `60-status.sh` (GNU tar, git, python3) and `40-executable-bits.sh` (git) print a plain `ok` line that says they skipped. `TESTS_REQUIRE_TOOLS` does not turn these into failures.
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
| unit/40-lib | the `MAX_SHARDS` clamp removed | not ok: `shards: x86_64 extra's seed wants 216 by bytes and gets MAX_SHARDS` |
| unit/40-lib | batches do not grow to fit `VERIFY_MAX_BATCHES` | not ok: `batches: x86_64 extra's seed wants 54, both limits grow, and it gets 36 to 40` |
| unit/40-lib | the build date written with no `Z` | not ok: `a build date as ISO 8601 UTC` |
| unit/40-lib | the "required key missing from keyring" pattern removed | not ok: `refusal: a primary key that expired is a signature reason` |
| unit/40-lib | the checksum pattern removed | not ok: `refusal: a checksum is not a signature reason` |
| unit/40-lib | the `QQ==` read turned off | not ok: the three `registry:` assertions on the dummy token's 200 and 404 |
| unit/40-lib | `registry_token_file` returns nothing | not ok: `registry: a second process reads the token the first one cached`, and the two after it |
| unit/40-lib | a refused cached token is not asked for again | not ok: `registry: a cached token the registry refuses is asked for again, once`, `registry: the cache then holds the new token` |
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
| unit/40-lib | an anonymous read uses the cached token | not ok: assertions 91, 92 |
| unit/40-lib | the report reads every summary, of any plan | not ok: assertions 96, 97, 99, 100 |
| unit/40-lib | `collect` reads verdicts of another digest | not ok: assertion 101 |
| integration/10-pipeline | no plan id is written | not ok: assertions 76, 37, 38 (an earlier attempt's result is read) |
| integration/10-pipeline | plan refuses a files database that leaves a package out | not ok: assertions 47 to 50 |
| integration/10-pipeline | verify runs `-Fl` over every name of the batch | not ok: assertion 50 |
| integration/10-pipeline | plan accepts a files database with an extra package | not ok: assertion 51 |
| integration/10-pipeline | every `sig-refused` package excused | not ok: with no `%PGPSIG%`, a layer that is not upstream's `.sig` is not excused |
| integration/10-pipeline | `build-repo` signs on every build | not ok: an update is planned as new files only; `latest` does not move backwards |
| static/60-targets | five edits in a copy: a `docker.io` keyring image, a removed `# tag: aarch64`, another verify digest, renamed plan slots, a `keyring_from` that does not exist | one not ok for each edit, among them `every target verifies in the one image, on linux/amd64` |

### status

| test | fault | observed |
| --- | --- | --- |
| unit/60-status | `cron-tolerance --minutes` leaves out the gap from the last firing to the first | not ok: `interval: only on 29 February is 1461 days, 2103840 minutes` |
| unit/60-status | coverage keyed by file name only | 17 not ok, among them `x86_64-extra: a file counts only with the same name and sha256: 3 of 5` and the badge texts |
| unit/60-status | `failed_runs` always 1 | not ok: `worker: two failed runs in a row, failing since the first` |
| unit/60-status | the Location check accepts `http://` | not ok: `worker: a 302 to http is not a redirect to https://*.githubusercontent.com` |
| unit/60-status | the history keeps every line | not ok: `history keeps the last 2000 lines`, `the oldest lines go first and the new one is last` |
| unit/60-status | a background `<rect>` left unclosed | 18 not ok, among them `site: all 22 SVG files parse as XML, each with a title and its own dark style` |
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

### worker

| test | fault | observed |
| --- | --- | --- |
| worker/test (cache) | cache keys on `https://cache.invalid` | not ok: `every cache key is on the request host, under /__cache/v1` |
| worker/test (cache) | 404 answers not stored under the `loc` key | not ok: `a repeat request is one cache lookup and no subrequest` |
| worker/test (cache) | no 600 s cap on the signed URL time to live | not ok: TTL 880 where 600 is expected |
| worker/test (cache) | a URL with no `se` stored for 600 s | not ok: `a signed URL with no se is not stored` |
| worker/test (cache) | the package-with-sig time to live 86400 | not ok: manifest TTLs |
| worker/test (cache) | the layer count check uses `>= 1` | not ok: `a package manifest with a second layer of the file name is not kept 6 h` |
| worker/test (cache) | the `loc` entry ignores the manifest entry | not ok: `a latest redirect never outlives the latest manifest entry, so a new latest shows within 30 s` |
| worker/test (cache) | no `ctx.waitUntil(prewarmSig)` | not ok: `a package answer fills the .sig entry: the .sig is then one lookup and no subrequest` |
| worker/test (cache) | the prewarm starts after the package answer | not ok: `a package request asks for the .sig blob at the same time as the package blob` |
| worker/test (cache) | `cache.match` exceptions not caught | not ok: `a cache that fails is logged, and the request still gets its answer from GHCR` |
| worker/test (ghcr) | no `signal` on fetch | not ok: `every subrequest has a 10 s deadline, the anonymous token and no redirect followed` |
| worker/test (ghcr) | a blob 200 returned as is | not ok: `a blob that GHCR answers with 200 gets 502: the Worker never sends the bytes` |
| worker/test (ghcr) | the Location host check removed | not ok: `the Location must be https and its host must end in .githubusercontent.com` |
| worker/test (ghcr) | the `@sha256` pin not compared | not ok: `an @sha256 pin whose manifest hashes to another value gets 502 and is not stored` |
| worker/test (ghcr) | the 64 KiB byte cap removed | not ok: `a manifest over 64 KiB with no or a false content-length is cut at 64 KiB` |
| worker/test (paths) | `TAG_RE` accepts every tag | not ok: `any other tag gets 404 with no subrequest, staging included` |
| worker/test (paths) | no `decodeURIComponent` | not ok: `a percent-encoded file name is decoded before its tag is made` |
| worker/test (paths) | HEAD answered with the GET body | not ok: `HEAD gets the same answer as GET, with no body` |
| worker/test (tags) | the `_u` escape only for `p`, `c`, `a` | not ok: `tagOf matches client/pacman-oci --tags for every name in tests/fixtures/filenames.txt` |
| worker/test (config) | `head_sampling_rate = 0.01` | not ok: `wrangler.toml sets the compatibility date, the flags, the CPU limit and the logs` |
| worker/10-node | a node shim that reports v20.18.0 | not ok: `node is 22 or newer` |
| worker/live | run against the deployed version 1 | 3 of 28 not ok: `:staging` gets 302, `%2B` gets 404 |

63 faults, each applied alone to a copy of `worker/`, were each caught. Every one of the 51 node tests was seen to fail at least once.

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
| static/75-renovate | the keyring images set to automerge | not ok: `the keyring images (ghcr.io/pkgforge-dev/archlinux) never merge on their own` |

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
| a keyring package that only `keyring_from` holds | installed from that target's `latest`, pinned by digest |
| an upstream database older than the promoted one | `behind`; `latest` does not move |
| a file signed again with the same bytes | planned; its signature layer repaired under the same tag |
| a signature layer that is not the `%PGPSIG%` | verify fails and names the file; never promoted |
| a file whose bytes change under its own name | `replaced`; the tag does not move |
| a new file whose tag already holds other bytes | `replaced`; the tag does not move |
| two db_servers, each ahead of the other on one package | `held` |
| a package signed by a key nobody trusts | upstream-refused: listed, and the snapshot promoted |
| a database with no `%PGPSIG%` | each new signature layer is upstream's detached `.sig` |
| a db_server, listed first, that lags by one dropped package | `latest` does not move |
| with no `%PGPSIG%`, a signature layer that is not upstream's `.sig` | verify fails: the mirror is at fault |
| a manifest whose bytes are not the pinned digest | refused by the wrapper |
| a manifest with two layers of one name | refused by the wrapper |
| a package manifest with no signature layer | refused by the wrapper, with a message |
| a blob whose size or sha256 is not its descriptor's | refused by the wrapper |
| a manifest over 64 KiB | given up within 20 s |
| a database signature whose snapshot moved on | not paired; the wrapper misses |

`20-client.sh` adds these. The first four go through proxies of its own:

| input | must end as |
| --- | --- |
| a registry that answers 503 | the second file misses in under 1 s, with no request; a `.sig` is still asked for |
| every blob cut in half | the install succeeds; the cut package resumes with a Range request |
| a blob that stops after 64 KiB for 40 s | the install takes less than 20 s; the transfer resumes from 64 KiB |
| one byte changed in the first answer for each blob | the prefetch keeps nothing; each file is read again alone; the install succeeds |
| a plain Server of its own that ignores Range, and stops a large file for 35 s | the install succeeds; the refused range is followed by one fetch from zero |
| a provider other than the default | the prefetch takes the first provider; the chosen one is read alone |
| two repositories with no database signature, under the sandbox | both signatures answered with an empty file; `-Sy` takes less than 1.9 s |
| the same with no sandbox | both stay misses; `-Sy` takes 4 s or more |
