# Operations

This document tells what runs by itself, which issues the automation raises and clears, and what a person must do.

## Workflows and schedules

| workflow | triggers | does |
| --- | --- | --- |
| `sync.yml` | cron `17 */3 * * *`, dispatch, and `upstream-watch.yml` for the targets that changed | plan, one chain per pending target (`sync-target.yml`), report, keepalive |
| `sync-target.yml` | called by `sync.yml` | mirror, stage, verify, promote (on `main`), summary, for one target |
| `status.yml` | cron `47 * * * *`, dispatch, and `report` on `main` after a scheduled sync or a sync that promoted a target | measures the mirror and the Worker, renders the site, pushes branch `status`, deploys Pages, raises or clears `worker-down` |
| `upstream-watch.yml` | cron `*/15 * * * *`, dispatch | `scripts/upstream-watch`: a sync of each target whose upstream database changed (below) |
| `watchdog.yml` | cron `41 7 * * *`, dispatch | staleness and schedules |
| `ci.yml` | push to `main`, pull request (not to `status`), dispatch | the test suites |
| `worker.yml` | push to `main` that changes `worker/**` or the workflow, dispatch | tests the Worker; the maintainer deploys it by hand (`docs/worker.md`) |

### The jobs of the watchdog

| job | does |
| --- | --- |
| `staleness` | `scripts/check-staleness` within `STALENESS_BUDGET`, in a step of 15 minutes; then a step with `always()` raises or clears `stale-<target>` for each state the check wrote; then, also with `always()`, `scripts/check-status-site`: `status-down` and `pages-stale` |
| `schedules` | `scripts/watch-schedules`: `keep-schedules-enabled`, `check-schedules-fired`, and the issue `schedules-stopped`; then on `main` `dispatch-overdue` for sync and status |

### The jobs of the status workflow

| job | does |
| --- | --- |
| `kick` | on `main`: `dispatch-overdue sync.yml 240` and `dispatch-overdue watchdog.yml 1560` |
| `decide` | a bench on dispatch with `bench=true`; else a bench on the first run from 05:00 to 08:59 UTC with no bench of the day on branch `status` |
| `bench` | `scripts/bench-consumer`, when `decide` says yes |
| `build` | `scripts/status-collect`, then `scripts/status-render`; on `main` it pushes branch `status` and uploads the Pages artifact |
| `deploy` | on `main`, when `build` passed and Pages takes a workflow build: `actions/deploy-pages` |
| `worker` | on `main`, whatever `build` did: `scripts/check-status-record` reads `status.json` from branch `status`; raises or clears `status-down` and `worker-down` |

`build` runs when `decide` passed, also when `bench` was skipped or failed. `deploy` names the result of `build` in its `if`. An `if` with no status function gets an implicit `success()` over every job before it. `bench` is skipped in most runs, so that implicit check would skip `deploy` too.

⛔ `worker` runs whatever `build` did: its `if` is `!cancelled()` on `main`. A `build` that fails pushes no record. So `worker` raises `status-down` with the run and the result of `build`, and the status page that stops changing is an issue, not only a red run. `tests/static/55-issue-steps.sh` checks this `if`.

⛔ `scripts/status-collect` ends its upstream reads within `STATUS_BUDGET` seconds (default 900). The `build` job has 30 minutes, so time is left for the render and the push. Each target gets what is left of the budget, divided by the targets not yet read. `scripts/upstream-db` reads the `db_server` hosts within that share, as for the staleness check (below). A host that fails is asked last by each later target. A target whose reads do not fit is still in `status.json`: its `upstream.error` names `STATUS_BUDGET`. The read of the mirror's database gets `REG_BLOB_MAX_TIME` (120 s), and its token request `REG_TOKEN_MAX_TIME` (30 s).

The Pages artifact of `build` is named `github-pages-<run attempt>`. `deploy` reads that name from the outputs of `build`. A re-run that runs `build` again uploads a second artifact into the same run, and `deploy-pages` refuses a name that two artifacts share. Each `upload-artifact` step sets `overwrite: true` for the same reason. `tests/static/50-workflow-policy.sh` checks both.

The Worker check is a job of `status.yml`, not of `watchdog.yml`. An hourly cron in `watchdog.yml` would cancel a pending daily run, because both share one concurrency group.

### Concurrency

⚠ By default a concurrency group holds one running run and one pending run. A newer run cancels the pending one. `cancel-in-progress: false` keeps only the running run.

| workflow | group | queue | effect |
| --- | --- | --- | --- |
| `sync.yml` | `sync`, for every ref | `max` | up to 100 runs wait, each in its turn; a dispatch with `allow_older` is never replaced by the next scheduled run |
| `ci.yml` | `ci-pr-<number>` for a pull request, else `ci-<run id>` | default | a newer push to a pull request cancels its run in progress; every other run has a group of its own, so each push to `main` gets a verdict |
| `status.yml` | `status` | default | one run waits; a newer one replaces it, and each run measures everything again |
| `upstream-watch.yml` | `upstream-watch` | default | one tick waits; a newer one replaces it, and each tick reads every URL again |
| `watchdog.yml` | `watchdog` | default | one run waits |
| `worker.yml` | `worker-<ref>` | default | one run waits |

GitHub refuses `queue: max` with `cancel-in-progress: true`. actionlint 1.7.12 does not know the key `queue`, so `tests/static/20-actionlint.sh` ignores that one message, and `tests/static/50-workflow-policy.sh` checks the value instead. When a long seed holds the group `sync`, the scheduled runs queue behind it and then run one after another.

## Each scheduled workflow starts the others

⛔ GitHub can delay or drop a scheduled run. A dropped run leaves nothing behind that could notice. So each scheduled workflow runs `scripts/dispatch-overdue WORKFLOW MAX_MINUTES` for the others.

| runs in | starts | when its newest run on `main` is older than |
| --- | --- | --- |
| `sync.yml` job `keepalive` | `status.yml` | 120 minutes |
| `status.yml` job `kick` | `sync.yml` | 240 minutes |
| `status.yml` job `kick` | `watchdog.yml` | 1560 minutes |
| `watchdog.yml` job `schedules` | `sync.yml` | 240 minutes |
| `watchdog.yml` job `schedules` | `status.yml` | 120 minutes |

A run that is queued or in progress counts as fresh, so nothing starts twice. A workflow with no run at all is started. Runs start on `main` only.

⛔ For `sync.yml`, only a run of every target counts for the age: a scheduled run, or a run titled `Sync all targets`. `upstream-watch.yml` starts runs of some targets only, and such a run must not hold back the full sync. A run of any kind that has not ended still counts as fresh. `dispatch-overdue` reads the newest 100 runs on `main`.

`dispatch-overdue` starts only a workflow whose state is `active`. GitHub refuses to start a disabled workflow. The script skips a workflow that a person disabled, or that GitHub disabled for inactivity. It prints a notice and exits 0. In `sync.yml` and `watchdog.yml`, `keep-schedules-enabled` runs first, and enables again a workflow that GitHub disabled for inactivity.

The job `report` of `sync.yml` starts `status.yml` on `main` after a scheduled sync, and after a sync that promoted a target, whether or not `status.yml` is overdue. `scripts/report` gives the count of promoted targets to `GITHUB_OUTPUT` (`promoted=N`), also in a run that it makes red. A sync from `upstream-watch.yml` that promotes nothing does not start `status.yml`: its hourly cron measures the mirror. The step follows the same rule as `dispatch-overdue`: when `status.yml` is not `active`, it prints a notice and the sync stays green. When the state does not read, the step fails. `tests/static/50-workflow-policy.sh` runs each workflow step that calls `gh workflow run` against a stub `gh`, with the workflow active, disabled and unreadable.

The restart steps in `sync.yml` and `watchdog.yml` run with `always()`. So a schedule check that fails earlier in the job does not stop the restart. A step with two `dispatch-overdue` calls runs both, then exits with the status of the last call that failed.

`scripts/keep-schedules-enabled` runs in `sync.yml` and in `watchdog.yml`. GitHub disables the schedules of a repository after 60 days with no activity. The script enables each workflow of the tree again. ⚠ A workflow that a person disabled stays disabled, and the script names it.

`scripts/check-schedules-fired` checks each scheduled workflow against its own cron. It fails when a schedule has not fired within its tolerance. It runs in `sync.yml` and in `watchdog.yml`, so each one sees the other stop.

⛔ A schedule that stops leaves no run behind to fail, and a red step reaches only the person who reads the run. So both jobs run `scripts/watch-schedules`. It runs `keep-schedules-enabled`, then `check-schedules-fired`, each to the end, and prints what each said. It raises `schedules-stopped` when a schedule has stopped, or when a person disabled a workflow. The body holds the line of each workflow and how to reproduce it. A schedule that stopped still makes the step red (exit 3). A workflow disabled by hand raises the issue and keeps the step green.

⚠ Neither check sees every schedule stop at once. Then no run is left to notice. Start `sync.yml` or `watchdog.yml` by hand to get the answer.

## The upstream watch

`upstream-watch.yml` runs `scripts/upstream-watch` every 15 minutes. It starts a sync of a target soon after the target's upstream database changes. ⭐ The 3-hour cron of `sync.yml` stays the backstop: it syncs every target, also when the watch stops or cannot read a host.

1. Each tick sends one HEAD request to each `<db_server>/<repo>.db` of each enabled target: 36 URLs for 15 targets. A powerpc target is not watched: its upstream needs a browser-profile client (below, The fetchers), and the watch uses `curl`.
2. The tick compares `ETag`, `Last-Modified` and `Content-Length` of the last answer, after the redirects, with the values that the last tick kept.
3. A target changed when one of its URLs answers other values. A URL with no answer changes nothing. A URL seen for the first time changes nothing.
4. The changed targets get one `sync.yml` run on `main` (`scripts/dispatch-sync`). The `targets` input of the run names them, and so does its title, for example `Sync x86_64-extra`.
5. The watch starts a sync of one target at most once in `SYNC_MIN_INTERVAL` minutes (60).

`scripts/dispatch-sync` starts nothing when `sync.yml` is not `active`, or when a run of `sync.yml` waits (`queued`, `waiting`, `requested` or `pending`). That run plans after the change. A run in progress does not stop a start, because it may have planned before the change.

⛔ A change that starts no sync is not lost. Its URL keeps the old values in the state, so the next tick sees the change again. This is true for a target that waits for `SYNC_MIN_INTERVAL`, a run that waits, a start that GitHub refuses, and a dry run.

| variable | default | meaning |
| --- | --- | --- |
| `SYNC_MIN_INTERVAL` | 60 | minutes from one sync that the watch starts for a target to the next |
| `WATCH_BUDGET` | 300 | seconds for all HEAD requests of a tick; each request gets 30 s at most |
| `WATCH_DRY_RUN` | 0 | 1: log the changed targets, and start nothing |

The job has 10 minutes. The HEAD requests end within `WATCH_BUDGET`, and `dispatch-sync` runs under `timeout -k 10 120`. A URL that is not read in time has no answer. A host that `curl` cannot reach is not asked again in that tick. A target with no URL that answered is named in a warning.

The state goes from one tick to the next in the Actions cache, under the key `upstream-watch-<run id>-<run attempt>`. Each tick restores the newest entry and saves a new one, also after a tick that fails. A tick that finds no entry starts no sync. It keeps the values it reads, and the next tick compares with them. ⚠ GitHub removes a cache entry that no run used for 7 days (documented). So after a stop of 7 days or more, the first tick starts no sync.

Only a run on `main` starts a sync. A run on another ref, or a dispatch with `dry_run`, logs the targets it would start:

```bash
gh workflow run upstream-watch.yml --ref main -f dry_run=true
```

### How many syncs the watch starts

The status history shows how often the upstream databases change ([measurements.md](measurements.md)). In 33 hours, the files or the bytes of an upstream database changed between two status runs 27 times for x86_64 extra and 25 times for riscv64 extra. They changed 19 times in all for the other 13 watched targets. That is about 52 changes a day.

- The watch starts a sync of x86_64 extra about 20 times a day, and of riscv64 extra about 18 times. It starts a sync of most other targets a few times a day or less.
- Targets that change in one tick share one run. So the watch starts at most one run per tick: 96 runs a day.
- `SYNC_MIN_INTERVAL` limits the syncs of one target to 24 a day.
- ⚠ The status count is a lower limit: two changes between two status runs count as one.
- ⚠ A `db_server` with more than one host behind its name can answer with the values of another host on each tick. Each such answer is a change, and `SYNC_MIN_INTERVAL` limits what it can start.

Each run that the watch starts plans only its targets. Its chains share the 20 jobs of the organisation with every other run.

### Stop the watch

Disable the workflow, and enable it again later:

```bash
gh workflow disable upstream-watch.yml
gh workflow enable upstream-watch.yml
```

The 3-hour cron of `sync.yml` still syncs every target while the watch is disabled. ⚠ `keep-schedules-enabled` leaves a workflow that a person disabled as it is, and `watch-schedules` raises `schedules-stopped` for it. The issue stays open while the watch is disabled. It is not a failure: the step stays green.

## Staleness

`scripts/check-staleness` reads the database that `latest` serves, through the wrapper's token flow (`PACMAN_OCI_NO_DUMMY=1`). So that path runs against GHCR on schedule too. It also reads upstream's current database from the target's `db_server` hosts.

⛔ Upstream is never only the first `db_server` that answers. `scripts/upstream-db` takes upstream the way `scripts/plan` does, for `check-staleness` and for `status-collect`:

1. It reads every `db_server`.
2. It refuses an answer that is not a whole, well-formed database (`lib.sh` `db_check`), for example an error page that answers 200.
3. It drops a database that is behind another: some package in it was built before the same package in the other (`lib.sh` `behind`).
4. It takes the first database left, in `db_server` order.

So a first `db_server` that lags or is stuck cannot hide a mirror that stopped, and an error page cannot make a quiet repository stale. When every database is behind another, the target is `unknown`. The issue body and `upstream.tried` in `status.json` name each `db_server` and its result. A result is `ok`, `behind by N package(s)`, `refused` and why, an HTTP code, or a curl status.

| verdict | when |
| --- | --- |
| `current` | the two databases are the same |
| `fresh` | they differ, and the promoted snapshot was fetched within the tolerance |
| `new` | there is no `latest`, and git added or enabled the target file within the tolerance |
| `stale` | they differ for longer than the tolerance, or there is no `latest` for longer |
| `unknown` | upstream could not be read, or a read did not fit the share of `STALENESS_BUDGET` (below) |

The tolerance comes from `scripts/cron-tolerance`: the largest gap in days of the cron, times 2, plus 1. The 3-hour cron of `sync.yml` gives a gap of 1 day and a tolerance of 3 days. ⚠ The tolerance is in days. A sub-daily cron gets the tolerance of a daily one, so a stop shows later than it could.

The date a target file was added is the date of the commit that brought it to the checked-out branch (`git log --first-parent`). A commit on the branch it came from does not count. The date it was enabled is the date of the last such commit that changed its `enabled` line. The later of the two dates counts. So a target file added with `enabled = no` gets its grace from the day that line goes or turns to `yes`.

⚠ When git cannot tell when a target file was added (no git, a shallow clone, an untracked file), the target is stale, never new. The `staleness` job checks out the whole history for this.

### The budget of the staleness check

⛔ `scripts/check-staleness` ends within `STALENESS_BUDGET` seconds (default 600). The job has 20 minutes, and the step that runs the check has 15.

- Each target gets a share: what is left of the budget, divided by the targets not yet read.
- `scripts/upstream-db` reads the `db_server` hosts within the share. Each read ends within 60 s, or sooner when the share is short. Then it gets 1/(n + 1) of what is left of the share, with n the hosts not yet asked.
- The two registry reads of the target run under `timeout` with what is left of the share: the `latest` manifest gets half, the wrapper the rest.
- A host that fails is asked last by each later target of the run, and only when no other `db_server` answers. So a host that stalls costs one deadline per run, not one per target.
- A target whose reads do not fit its share is `unknown`. Its issue body names `STALENESS_BUDGET` and the read that was cut short.

The check writes the state of each target as soon as it is decided. The step that raises and clears `stale-<target>` runs with `always()`. So a check that fails or is stopped still raises or clears the issue of each target it decided.

## Issues the automation raises and clears

`scripts/track-issue` keeps one issue per problem. `raise` opens the issue the first time and only rewrites its body after that. `clear` comments, closes, and does nothing when no issue is open. The key is in the body as an HTML comment. The script finds an issue by listing the open issues, never by search.

| issue | raised when | cleared when | by |
| --- | --- | --- | --- |
| `visibility-<target>` | the package reads with the workflow's token, and the registry refuses the read without one (401, 403 or 404) | a run reads the target anonymously | `scripts/report`, on `main` |
| `replaced-<target>` | a package tag holds other bytes than the database names | the target stages or is current again | `scripts/report`, on `main` |
| `refused-<target>` | the chain collected more upstream-refused files than `REFUSED_ISSUE_MIN` (16) | the target stages, is promoted or is current with 16 or fewer | `scripts/report`, on `main` |
| `stale-<target>` | `check-staleness` says `stale` or `unknown` | it says anything else | `watchdog.yml` job `staleness` |
| `worker-down` | the Worker failed its probe in 2 status runs in a row, over 50 minutes or more | a status run records a probe that passes | `status.yml` job `worker` |
| `status-down` | `build` of `status.yml` did not succeed, or the record on branch `status` is more than 3 hours old (`status.yml` job `worker`); the record is more than 6 hours old, or there is none (`watchdog.yml` job `staleness`) | a `build` succeeds and its record is at most 3 hours old | `scripts/check-status-record`, `scripts/check-status-site` |
| `pages-stale` | the copy of `status.json` on Pages does not answer with a record, or it trails the record on branch `status` by more than 3 hours | the copy answers and trails by 3 hours or less | `scripts/check-status-site`, in `watchdog.yml` job `staleness` |
| `schedules-stopped` | `check-schedules-fired` says a schedule has stopped, or `keep-schedules-enabled` names a workflow that a person disabled | both checks ran, every schedule fires, and no workflow is disabled by hand | `scripts/watch-schedules`, in `watchdog.yml` job `schedules` and `sync.yml` job `keepalive` |

A target that is held, behind or in error raises nothing in the report. A run that fails once is ordinary. `stale-<target>` opens when the mirror has stopped following upstream.

stage reads each staged snapshot again with no credential. Only a 401, a 403 or a 404 to that read raises `visibility-<target>`. Another answer, such as a 5xx or no answer in 5 tries, puts the target in error for the run, and its row names the HTTP code.

The `worker` job of `status.yml` reads the record that `build` pushed to branch `status` in the same run. When that record is more than 3 hours old, the job raises `status-down` and fails, and judges no Worker probe: an old record says nothing about now. A record of at most 3 hours still gives the `worker-down` decision, also after a `build` that failed.

The watchdog sees `status.yml` from outside. When `status.yml` stops running at all, no `worker` job runs to say so. So the `staleness` job reads `status.json` from branch `status` (`git fetch origin status`), and raises `status-down` when it is more than 6 hours old. Only the `worker` job of `status.yml` clears `status-down`, when it sees a `build` that succeeded with a fresh record. The same step reads `https://<owner>.github.io/<name>/status.json` and raises `pages-stale` when the deploy no longer reaches Pages. The README badges come from Pages, so they then show an old state.

A Worker probe fails in each of these cases. [worker.md](worker.md#monitoring) has each probe.

- The Worker gives a wrong answer.
- The signed URL of its 302 does not answer the status runner with 206 or 200 for one byte.
- The smallest database, downloaded through the Worker once per run, is not the one `latest` names.

Status runs are not an hour apart. The cron runs `status.yml` at minute 47 of each hour, and `sync.yml` starts it after each sync, so two runs can be minutes apart. So `scripts/status-collect` sets `worker.down` in `status.json` only when two conditions are true. The probes failed in 2 runs in a row. The first of these failures is 3000 s (50 minutes) or more before this run. The `worker` job raises `worker-down` on `worker.down`. A Worker or GHCR fault of a few minutes opens no issue.

## What needs a person

- **A private package.** GitHub may create a package private, and has no API to change that. Open the settings link in `visibility-<target>`, and make the package public.
- **A replaced file.** Arch does not publish a filename again with new bytes. So `replaced-<target>` means something unusual upstream or on the registry. The issue names the file and both digests. Wait for upstream to publish a new filename, or accept the new bytes under a new tag.
- **Many upstream-refused files.** The mirror serves upstream's bytes and promotes them, so the target is not held. But pacman refuses them from upstream too, and one key signs every package of an Arch Linux ARM target or of riscv64. `refused-<target>` names the first 50 files and reasons. Check whether upstream revoked or rotated its key, and whether the target's keyring package or `keyring_image` needs an update.
- **A keyring package that does not install.** The verdict names the package and pacman's error line. Fix the `keyring` line of the target file (below).
- **Renovate.** Merge the major updates, and the keyring image updates that fail CI job `keyrings`. For new keys, check the change, run `scripts/keyring-files OUT`, and write its lines into `targets/keyrings.sha256`.
- **Pages.** Enable Pages once (below).
- **The Worker.** Deploy a change to `worker/` by hand, after `worker.yml` passes (`docs/worker.md`).
- **A disabled workflow.** Enable a workflow that a person disabled, when that decision no longer holds.

Start a sync by hand:

```bash
gh workflow run sync.yml --ref main
gh workflow run sync.yml --ref main -f targets='x86_64-core x86_64-extra' -f max_targets=2
```

### Re-run a sync

A sync run can be run again from its page. The two choices do not do the same thing.

| choice | does |
| --- | --- |
| Re-run failed jobs | keeps the plan and every artifact of the jobs that passed. The failed jobs run again with the same plan id. Use this when a job failed for a reason outside the mirror, for example a runner that stopped. |
| Re-run all jobs | plans again, under a new plan id. A download by name or pattern still returns the earlier attempt's artifact for each name that this attempt does not upload again. So stage reads only the shard results of the new plan, and the report reads only the summaries of the new plan. A target whose chain left nothing of the new plan shows `failed`, and its row names the plan. |

⚠ A new run reads upstream again and leaves nothing of an earlier run behind. Prefer `gh workflow run sync.yml --ref main` to "Re-run all jobs".

### The plan's budget

The plan job reads every target's databases from upstream, one target after another, in one job of 30 minutes. `scripts/plan` ends its upstream reads within `PLAN_BUDGET` seconds (1200). Each target gets what is left of the budget, divided by the targets not yet read. A target whose upstream does not answer in time is in error for that run, and its row in the run's table names `PLAN_BUDGET`. The next run reads it again. A target that stays in error raises `stale-<target>` after the tolerance.

### An upstream that blocks

Each upstream read that gets an answer other than 200, 404 and 410 logs one line: `<url> answered HTTP <code>`. When the answer has Cloudflare's `cf-mitigated` header, the line ends with it, for example `(cf-mitigated: challenge)`. A block or a challenge then shows as what it is, not as a server that did not answer.

⚠ Both loong64 targets have one `db_server`, `loongarchlinux.lcpu.dev`, and Cloudflare is in front of it. When it blocks the runners, the plan log shows that line for `core.db` and `extra.db`, and both targets are in error. After the tolerance, `stale-loong64-core` and `stale-loong64-extra` open.

### A keyring package that does not install

A verdict that says `the keyring package(s) ... did not install` holds the target on every run. The cause is a keyring package that upstream renamed, split, or signed with a new key. Read pacman's line in the verdict, then fix the `keyring` line of the target file.

### The verify image

⚠ Docker Hub limits anonymous pulls per address, and runners share addresses. When it refuses the verify image, verify pulls the same digest from `mirror.gcr.io`, then from `public.ecr.aws`, and the log of the batch names the source it used. Nothing waits on a person. When every source fails, the verdict of each batch names the sources and `toomanyrequests`, the target is not promoted for that run, and the next run tries again. Set `VERIFY_IMAGE_MIRRORS` to change the list of mirrors, for example on another host.

### GHCR and the dummy token

⚠ GHCR does not document `Bearer QQ==`. When GHCR refuses it, each anonymous read logs the warning `GHCR refused Bearer QQ== for <repository> (HTTP <code>); the anonymous token flow was used`, and goes on with that flow. Each read then costs three requests in place of one. The mirror keeps working, and the warning tells a person that GHCR changed. The Worker and the wrapper use the same flow ([worker.md](worker.md#ghcr-tokens), [client.md](client.md#tokens)).

### Detached signatures that upstream makes again

A file with no `%PGPSIG%` in its database has its signature only in the detached `.sig` (riscv64 extra: 14636 of 14716 files, [measurements.md](measurements.md)). A new `.sig` does not change the database. So each run of `scripts/plan` compares `SIGCHECK_SAMPLE` (64) of these files: the `.sig` that upstream serves, against the signature layer of the file's tag. The sample starts at another file on each 3-hour run. For riscv64 extra, every file is compared once in 229 runs, about 29 days.

- A file whose `.sig` differs is planned again. mirror-file pushes it again with the same package blob, and verify checks it. The plan log names the file, and the target's why says `K detached signature(s) changed upstream`.
- When more than `SIGCHECK_ESCALATE` (8) files of one sample differ, the plan warns `upstream signed N of M sampled files again; every detached signature is checked this run`. It plans every file with a detached signature only. mirror-file pushes again only the files whose `.sig` differs.
- ⚠ Verify then reads every planned file: a run after a new signing key downloads the whole target.
- These reads count in the target's share of `PLAN_BUDGET`, and stop when half of what was left is used. A server that fails is not asked again in that sample. A file whose tag or `.sig` does not read waits for a later run.

The same check repairs a signature layer that was changed on the registry: the next sample that holds the file plans it again.

### A files database that lags

plan compares `<repo>.files` with `<repo>.db` by package name. A package that both name at other file names shows that the files database lags, for example during a mass rebuild. plan names these packages in a warning, as it names the packages that only one of the two names, and goes on. A lagging files database never holds a target.

plan refuses a files database that names fewer than half of the packages of the database, and leaves out 16 or more: it is the files database of another repository. It also refuses one that names a file of the database with another sha256. After a refusal, plan reads `<repo>.files` from the next `db_server` that served the same database. When none serves a matching one, the target is in error, and its why says so.

`FILES_DRIFT_MAX`, when set, replaces the package-name rule: plan refuses a files database when more file names than `FILES_DRIFT_MAX` are named by only one of the two databases.
### Which client reads upstream

`fetchers/fetcher.sh URL OUT` reads one URL and writes the body. The chooser
runs its clients in a fixed order and takes the first body that passes every
check asked for:

```
curl  curl-impersonate  chromium  cloak-browser  playwright
```

curl is first on purpose. Every origin in this repository that answers curl
answers it in tens of milliseconds and starts no browser, and a mirror run
makes thousands of reads. The browser clients are what an origin that refuses
curl falls back to, not what every read pays for.

| variable | meaning |
| --- | --- |
| `FETCHER_CLIENTS` | the order, space separated. The default is the list above. |
| `FETCHER_AVAILABLE_TTL` | seconds an availability answer is kept, default 300 |
| `FETCHER_CACHE` | where the per-host preference and the probes are kept |
| `--client LIST` | try these clients, in this order, and no other |
| `--require-tool NAME` | try `NAME` first, and refuse to run if it cannot |

A client that is not available is skipped and the summary says `not available`.
It is never skipped silently, because a run that fails for a missing tool and a
run that fails for a real fault need different answers. The answer for a client
is its `available` script, and that answer is cached for
`FETCHER_AVAILABLE_TTL` because a browser probe starts node or python and costs
more than the fetch it guards.

A body that fails `--expect`, `--sha256`, `--magic` or the `--signature` check
does not count as fetched. That client is marked unusable for this URL and the
next one is tried, because a client that answered 200 with the wrong bytes has
told you something worth knowing. A 403 is such a body: it is not the file that
was asked for.

`--signature URL` checks the signature with `gpgv` and not `gpg`, so the check
cannot change the trust store it verified against, and it derives `URL.sig`
itself so the signature and the body cannot be two different files. The body is
written only after the signature verifies.

### When a target cannot be read at all

Two different faults look the same from a run: a target whose `db_server`
cannot be fetched, and a target whose `db_server` answers but whose files the
origin will not serve. `scripts/plan` puts the target in error for the run and
names it, and the next run reads it again. Nothing is deleted and no tag is
written.

A target whose `db_server` needs a browser-profile client reads it through
`fetchers/fetcher.sh` (below).

## Renovate

`.github/renovate.json` sets the update policy.

- Actions are pinned by commit, with the version in a comment. Images are pinned by digest, under a `# tag: <tag>` line.
- Actions move once a week (`* 0-5 * * 1`), in one pull request, only to a release at least 3 days old.
- Digest, pin, pinDigest, patch and minor updates of actions and images merge on their own, as a squash, when every check is green.
- `platformAutomerge` is `false`. `main` has no required checks, so GitHub's own auto-merge would merge a pull request with red checks. Renovate reads the checks itself.
- ⚠ A major update waits for a person.
- ⚠ The keyring images (`ghcr.io/pkgforge-dev/archlinux`) are the trust root of every target outside x86_64: aarch64, armv7h, loong64, riscv64, powerpc64le, powerpc64 and powerpc. They merge on their own only when CI job `keyrings` passes: the keyring files that verify takes from them equal `targets/keyrings.sha256`. Other keys fail the job, and a person reviews them.
- The 21 `verify_image` lines and the Arch image of the tests move in one pull request. So CI runs pacman in the image the targets will verify with, before it merges.
- The node image of `worker.yml` and `ci.yml` moves in one pull request.
- `ignorePaths` is `["**/node_modules/**"]`. It replaces the preset's list, which ignores `**/tests/**`, so the test images are updated too.

`tests/static/75-renovate.sh` checks these rules and checks that the regex manager matches every image pin.

## Repository settings

| setting | value |
| --- | --- |
| default workflow permissions | read |
| Actions can approve pull requests | no |
| `sha_pinning_required` | `true`: only actions pinned by commit run |

`tests/static/50-workflow-policy.sh` checks the shape of every workflow. It checks `permissions: {}` at the top, the permissions of each job, and `timeout-minutes` on every job. It also checks that each action is pinned by commit, and that no untrusted value is inside a `run:` block. It also checks the artifact names against re-runs, the steps that start another workflow, and the concurrency groups (above).

## Secrets

The repository has no secret. Every job uses the workflow's own `GITHUB_TOKEN`. The Worker is deployed by hand with the maintainer's wrangler login.

## The fetchers

`plan` and `mirror` read upstream through `scripts/lib.sh` `fetch_upstream`.
When `MIRROR_FETCHER` names `fetchers/fetcher.sh`, every upstream read goes
through the manager, which tries `curl` first and falls back to a client that
presents a browser's TLS and HTTP profile: `curl-impersonate`, then `chromium`.

The powerpc upstream, `repo.archlinuxpower.org`, needs such a client.
`curl-impersonate` (patched curl, one browser's TLS and HTTP/2 profile) reads it
cheaply; `chromium` (a full browser) is the fallback when a host needs a real
engine. The workflows install both and set `MIRROR_FETCHER` for the powerpc
targets only. `curl-impersonate` is installed best-effort so a client-install
hiccup never blocks the run; its installer verifies the release asset against
GitHub's per-asset sha256 digest (or a checksum file when the release has one).

- `sync.yml` job `plan` installs the clients when a powerpc target is in scope.
  This job plans every target at once, so a chromium install that does not land
  leaves `MIRROR_FETCHER` unset: the powerpc targets go to error and the other
  targets plan as before.
- `sync-target.yml` jobs `mirror` and `verify` install the clients for a
  powerpc target. chromium is required there: a job that cannot install it
  fails, and it runs one target only, so no other target is held.

`fetchers/README.md` has the interface, the client table and the drift
resolver. The clients update themselves through `fetchers/drift.sh`, which
resolves each tool's newest release at install time, with no pinned version.

The manager keeps the client that read each host in `FETCHER_CACHE/hosts/` and
tries it first next time. `4` means the server says the URL is absent, as for
curl. A client is available when its `available` script exits 0, so a host
without a browser skips it and `--list` says what can run.

To read the powerpc upstream by hand, outside the workflows, install the
clients and set `MIRROR_FETCHER`:

```yaml
- run: |
    fetchers/install.sh curl-impersonate chromium
    export MIRROR_FETCHER="$PWD/fetchers/fetcher.sh"
    scripts/plan "$RUNNER_TEMP/plan"
```

The versions are not pinned: `fetchers/drift.sh` reads each tool's newest
release and the installers take that tag, so an update is a run, not a commit.
`fetchers/self-check.sh [URL]` reads a URL through the manager and each
available client. ⚠ Its `--strict` form requires every available client to read
the URL, so use it only for a host every client can read, not for one that
answers `curl` with a challenge: there `curl` is available and cannot read it,
and `--strict` would fail although the manager read it with a browser client.
`tests/unit/80-fetchers.sh` covers client selection, the fallback order, the
structural, size, sha256, header and referer checks and the resolver with a
curl stand-in; a browser client is not started by the tests.

## Pages

The site is published with a workflow build: `actions/upload-pages-artifact` in job `build`, then `actions/deploy-pages` in job `deploy`. Only `deploy` has `pages: write` and `id-token: write`.

⚠ A person must enable Pages once, with an admin token. `GITHUB_TOKEN` cannot do it:

```bash
gh api -X POST repos/pkgforge-dev/mirror-archlinux/pages -f build_type=workflow
```

Until then, `deploy` shows a notice and deploys nothing. ⚠ The notice does not make the run red. So the watchdog raises `pages-stale` when the copy on Pages trails the record on branch `status` by more than 3 hours. This also shows a change of the Pages source by a person.

The site at <https://pkgforge-dev.github.io/mirror-archlinux/> holds:

| path | contents |
| --- | --- |
| `index.html` | the dashboard: one static page, light and dark, with one inline script for local times (below) |
| `badges/<target>.svg` | coverage and snapshot age of one target |
| `badges/<arch>.svg` | the same over the targets of one architecture |
| `badges/all.svg` | the same over every target |
| `badges/synced.svg` | the time since the mirror last changed (below) |
| `badges/size.svg` | the bytes that the databases of the latest snapshots name, over every target, for example `369 GiB` or `1.2 TiB` |
| `badges/size-<arch>.svg` | the same over the targets of one architecture |
| `badges/speed.svg` | pacman's time through the wrapper and through the official mirror, from the bench; a bench older than 2 days shows its age, in the warning colour |
| `charts/coverage.svg` | share of upstream files in the mirror, per target |
| `charts/freshness.svg` | snapshot age per target, against the sync interval |
| `charts/size.svg` | GiB per target, in the mirror and upstream, grouped by architecture; each group label holds the sum of its architecture |
| `charts/history-coverage.svg` | coverage per architecture, last 30 days |
| `charts/history-age.svg` | oldest snapshot age per architecture, last 30 days |
| `charts/speed.svg` | the bench: seconds per path and operation |
| `charts/narrow/<chart>.svg` | each chart at 420 px, for a phone |
| `status.json`, `history.json`, `bench.json` | the data behind the page |

⚠ Four badge names are reserved, and an architecture may not take one: `all`,
`synced`, `size` and `speed` are written for the whole site. An architecture
called `size` would have its group badge overwritten by the site's own. The
tree has no such target, and the target-file grammar does not stop one, so a
new architecture picks a name outside those four.

`status.json` has schema 1. The header of `scripts/status-collect` describes each field. The table of repositories on `index.html` names, under the upstream server, each `db_server` not taken and its result.

A target has a coverage only when a run reads both upstream and the registry. A sum over the targets counts only those, and the page says so:

| where | every target read | some targets not read |
| --- | --- | --- |
| `badges/<arch>.svg` | `77.7% · 3.0 h` | `77.7% · 3.0 h · 2 of 3 measured` |
| `badges/all.svg` | `53.8% · 2/5 repos` | `53.8% · 2/5 repos · 4 of 5 measured` |
| the headline | over 5 repositories | over the 4 of 5 repositories measured in this run |
| the tiles `Files` and `Size in the mirror` | of the upstream total | of the upstream total, in 4 of 5 repositories |
| the tile `Repositories with a snapshot` | `2 of 5` | `1 of 4 read`, and how many the registry did not answer |

A group badge with no snapshot says `unknown` when its registry did not answer. It says `not mirrored` only when the registry says there is no `latest`. When no target is read on both sides, the headline and the file and size tiles say `unknown`.

In `status.json`, `summary.measured` counts the targets read on both sides, and `summary.mirror_unread` the targets whose registry did not answer. The file and byte sums are `null` when no target was read.

### The synced badge

`badges/synced.svg` says how long ago the mirror last changed: `just now`, `N min ago`, `N h ago` or `N d ago`, rounded down.

| age | colour |
| --- | --- |
| under 6 h | green |
| 6 h to under 24 h | yellow |
| 24 h or more | red |
| no time known | grey, `unknown` |

The time is `summary.last_synced` in `status.json`. It is the newest `org.opencontainers.image.created` of the `latest` manifests, which `scripts/status-collect` records per target as `mirror.created`. oras sets that annotation when `stage` pushes a snapshot. A manifest with no such annotation counts with its `dev.pkgforge.mirror.fetched` time. The table of repositories shows the same age per target, in the column `synced`.

⚠ The age counts to the status run that wrote the badge, not to the moment a reader looks. A status run comes each hour and after each sync. A README shows a badge through GitHub's image proxy, which can serve an older copy.

### Size per architecture and repository

`badges/size.svg`, `badges/size-<arch>.svg` and the table "Size by architecture" of `index.html` count the files that the database of each `latest` names (`mirror.files`, `mirror.bytes`). A target with no `latest` holds 0. A target whose registry did not answer is left out. A size badge then says how many targets it counts, for example `110 GiB · 2 of 3 measured`. The upstream columns of the table count upstream's database in the same run. Each architecture row holds the sum of its repositories, and the last row holds the sum of all targets.

⚠ `charts/size.svg` and the tile `Size in the mirror` count only the upstream files that the mirror holds (`coverage.bytes`). When a target is behind upstream, the two numbers differ.

### Times on the page

Each time on `index.html` is UTC text in a `<time>` element, for example `<time datetime="2026-10-15T00:08:04Z">2026-10-15 00:08 UTC</time>`. One inline script runs after the page loads. It gives each `<time>` a title: the viewer's local time with its time zone, and the age of that time, for example `Oct 15, 2026, 05:53 AM GMT+5:45, 1 h ago`. Hold the pointer on a time to see the title. The page has no other script and loads no script file. With no JavaScript, the page reads the same, in UTC.

⚠ A badge or a chart is an image, and an image runs no script. So a badge or a chart shows a time in UTC, or an age counted to the status run.

## The status branch

On `main`, job `build` pushes branch `status` as one orphan commit, with force, on each run. The branch holds the site, plus:

| file | contents |
| --- | --- |
| `history.jsonl` | one line per status run; the last 2000 lines are kept. A target that a run could not read keeps the files and bytes of its last measured line, marked `"k": 1`. So a read that fails does not move the coverage history |
| `worker.md` | the body of the `worker-down` issue: every probe, and how to reproduce the first failure |
| `bench.json` | the newest bench |
| `bench/<date>.json` | each daily bench |

The next status run reads `history.jsonl` and the bench from the branch. The `worker` job of `status.yml` reads `status.json` and `worker.md` from it. The `staleness` job of `watchdog.yml` reads `status.json` from it. ⚠ The branch is the only copy of the history. A run that fails to push leaves the previous branch in place, so no history is lost.

The pushes to `status` start no CI run: the push trigger of `ci.yml` covers `main` only, and its pull request trigger leaves out `status`.
