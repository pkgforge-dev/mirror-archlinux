# Operations

This document tells what runs by itself, which issues the automation raises and clears, and what a person must do.

## Workflows and schedules

| workflow | triggers | does |
| --- | --- | --- |
| `sync.yml` | cron `17 */3 * * *`, dispatch | plan, one chain per pending target (`sync-target.yml`), report, keepalive |
| `sync-target.yml` | called by `sync.yml` | mirror, stage, verify, promote (on `main`), summary, for one target |
| `status.yml` | cron `47 * * * *`, dispatch, and `report` after each sync on `main` | measures the mirror and the Worker, renders the site, pushes branch `status`, deploys Pages, raises or clears `worker-down` |
| `watchdog.yml` | cron `41 7 * * *`, dispatch | staleness and schedules |
| `ci.yml` | push to `main`, pull request (not to `status`), dispatch | the test suites |
| `worker.yml` | push to `main` that changes `worker/**` or the workflow, dispatch | tests and deploys the Worker |

### The jobs of the watchdog

| job | does |
| --- | --- |
| `staleness` | `scripts/check-staleness`; raises or clears `stale-<target>` |
| `schedules` | `scripts/keep-schedules-enabled`, `scripts/check-schedules-fired`, and on `main` `dispatch-overdue` for sync and status |

### The jobs of the status workflow

| job | does |
| --- | --- |
| `kick` | on `main`: `dispatch-overdue sync.yml 240` and `dispatch-overdue watchdog.yml 1560` |
| `decide` | a bench on dispatch with `bench=true`; else a bench on the first run from 05:00 to 08:59 UTC with no bench of the day on branch `status` |
| `bench` | `scripts/bench-consumer`, when `decide` says yes |
| `build` | `scripts/status-collect`, then `scripts/status-render`; on `main` it pushes branch `status` and uploads the Pages artifact |
| `deploy` | on `main`, when `build` passed and Pages takes a workflow build: `actions/deploy-pages` |
| `worker` | on `main`, when `build` passed: reads `status.json` from branch `status`; raises or clears `worker-down` |

`build` runs when `decide` passed, also when `bench` was skipped or failed. `deploy` and `worker` name the result of `build` in their `if`. An `if` with no status function gets an implicit `success()` over every job before it. `bench` is skipped in most runs, so that implicit check would skip `deploy` and `worker` too.

The Pages artifact of `build` is named `github-pages-<run attempt>`. `deploy` reads that name from the outputs of `build`. A re-run that runs `build` again uploads a second artifact into the same run, and `deploy-pages` refuses a name that two artifacts share. Each `upload-artifact` step sets `overwrite: true` for the same reason. `tests/static/50-workflow-policy.sh` checks both.

The Worker check is a job of `status.yml`, not of `watchdog.yml`. An hourly cron in `watchdog.yml` would cancel a pending daily run, because both share one concurrency group.

### Concurrency

⚠ By default a concurrency group holds one running run and one pending run. A newer run cancels the pending one. `cancel-in-progress: false` keeps only the running run.

| workflow | group | queue | effect |
| --- | --- | --- | --- |
| `sync.yml` | `sync`, for every ref | `max` | up to 100 runs wait, each in its turn; a dispatch with `allow_older` is never replaced by the next scheduled run |
| `ci.yml` | `ci-pr-<number>` for a pull request, else `ci-<run id>` | default | a newer push to a pull request cancels its run in progress; every other run has a group of its own, so each push to `main` gets a verdict |
| `status.yml` | `status` | default | one run waits; a newer one replaces it, and each run measures everything again |
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

`dispatch-overdue` starts only a workflow whose state is `active`. GitHub refuses to start a disabled workflow. The script skips a workflow that a person disabled, or that GitHub disabled for inactivity. It prints a notice and exits 0. In `sync.yml` and `watchdog.yml`, `keep-schedules-enabled` runs first, and enables again a workflow that GitHub disabled for inactivity.

The job `report` of `sync.yml` starts `status.yml` after each sync on `main`, whether or not it is overdue. It follows the same rule: when `status.yml` is not `active`, it prints a notice and the sync stays green. When the state does not read, the step fails. `tests/static/50-workflow-policy.sh` runs each workflow step that calls `gh workflow run` against a stub `gh`, with the workflow active, disabled and unreadable.

The restart steps in `sync.yml` and `watchdog.yml` run with `always()`. So a schedule check that fails earlier in the job does not stop the restart. A step with two `dispatch-overdue` calls runs both, then exits with the status of the last call that failed.

`scripts/keep-schedules-enabled` runs in `sync.yml` and in `watchdog.yml`. GitHub disables the schedules of a repository after 60 days with no activity. The script enables each workflow of the tree again. ⚠ A workflow that a person disabled stays disabled, and the script names it.

`scripts/check-schedules-fired` checks each scheduled workflow against its own cron. It fails when a schedule has not fired within its tolerance. It runs in `sync.yml` and in `watchdog.yml`, so each one sees the other stop.

⚠ Neither check sees every schedule stop at once. Then no run is left to notice. Start `sync.yml` or `watchdog.yml` by hand to get the answer.

## Staleness

`scripts/check-staleness` reads the database that `latest` serves, through the wrapper's token flow (`PACMAN_OCI_NO_DUMMY=1`). So that path runs against GHCR on schedule too. It also reads upstream's current database from the target's `db_server` hosts.

| verdict | when |
| --- | --- |
| `current` | the two databases are the same |
| `fresh` | they differ, and the promoted snapshot was fetched within the tolerance |
| `new` | there is no `latest`, and git added or enabled the target file within the tolerance |
| `stale` | they differ for longer than the tolerance, or there is no `latest` for longer |
| `unknown` | upstream could not be read |

The tolerance comes from `scripts/cron-tolerance`: the largest gap in days of the cron, times 2, plus 1. The 3-hour cron of `sync.yml` gives a gap of 1 day and a tolerance of 3 days. ⚠ The tolerance is in days. A sub-daily cron gets the tolerance of a daily one, so a stop shows later than it could.

The date a target file was added is the date of the commit that brought it to the checked-out branch (`git log --first-parent`). A commit on the branch it came from does not count. The date it was enabled is the date of the last such commit that changed its `enabled` line. The later of the two dates counts. So a target file added with `enabled = no` gets its grace from the day that line goes or turns to `yes`.

⚠ When git cannot tell when a target file was added (no git, a shallow clone, an untracked file), the target is stale, never new. The `staleness` job checks out the whole history for this.

## Issues the automation raises and clears

`scripts/track-issue` keeps one issue per problem. `raise` opens the issue the first time and only rewrites its body after that. `clear` comments, closes, and does nothing when no issue is open. The key is in the body as an HTML comment. The script finds an issue by listing the open issues, never by search.

| issue | raised when | cleared when | by |
| --- | --- | --- | --- |
| `visibility-<target>` | the package reads with the workflow's token and not without one | a run reads the target anonymously | `scripts/report`, on `main` |
| `replaced-<target>` | a package tag holds other bytes than the database names | the target stages or is current again | `scripts/report`, on `main` |
| `stale-<target>` | `check-staleness` says `stale` or `unknown` | it says anything else | `watchdog.yml` job `staleness` |
| `worker-down` | the Worker failed its probe in 2 status runs in a row, over 50 minutes or more | a status run records a probe that passes | `status.yml` job `worker` |

A target that is held, behind or in error raises nothing in the report. A run that fails once is ordinary. `stale-<target>` opens when the mirror has stopped following upstream.

The `worker` job of `status.yml` reads the record that `build` pushed to branch `status` in the same run. The job fails when that record is more than 3 hours old.

Status runs are not an hour apart. The cron runs `status.yml` at minute 47 of each hour, and `sync.yml` starts it after each sync, so two runs can be minutes apart. So `scripts/status-collect` sets `worker.down` in `status.json` only when two conditions are true. The probes failed in 2 runs in a row. The first of these failures is 3000 s (50 minutes) or more before this run. The `worker` job raises `worker-down` on `worker.down`. A Worker or GHCR fault of a few minutes opens no issue.

## What needs a person

- **A private package.** GitHub may create a package private, and has no API to change that. Open the settings link in `visibility-<target>`, and make the package public.
- **A replaced file.** Arch does not publish a filename again with new bytes. So `replaced-<target>` means something unusual upstream or on the registry. The issue names the file and both digests. Wait for upstream to publish a new filename, or accept the new bytes under a new tag.
- **Renovate.** Merge the keyring image updates and the major updates.
- **Pages.** Enable Pages once (below).
- **The Worker.** Set `CLOUDFLARE_API_TOKEN` to deploy it.
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

## Renovate

`.github/renovate.json` sets the update policy.

- Actions are pinned by commit, with the version in a comment. Images are pinned by digest, under a `# tag: <tag>` line.
- Actions move once a week (`* 0-5 * * 1`), in one pull request, only to a release at least 3 days old.
- Digest, pin, pinDigest, patch and minor updates of actions and images merge on their own, as a squash, when every check is green.
- `platformAutomerge` is `false`. `main` has no required checks, so GitHub's own auto-merge would merge a pull request with red checks. Renovate reads the checks itself.
- ⚠ A major update waits for a person.
- ⚠ The keyring images (`ghcr.io/pkgforge-dev/archlinux`) wait for a person. They are the trust root of the aarch64, armv7h, loong64 and riscv64 targets, and no CI job runs them.
- The 15 `verify_image` lines and the Arch image of the tests move in one pull request. So CI runs pacman in the image the targets will verify with, before it merges.
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

| secret | needed by | without it |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | `worker.yml` job `deploy` | the job shows a notice and ends with success, with no deploy |

Every other job uses the workflow's own `GITHUB_TOKEN`.

## Pages

The site is published with a workflow build: `actions/upload-pages-artifact` in job `build`, then `actions/deploy-pages` in job `deploy`. Only `deploy` has `pages: write` and `id-token: write`.

⚠ A person must enable Pages once, with an admin token. `GITHUB_TOKEN` cannot do it:

```bash
gh api -X POST repos/pkgforge-dev/mirror-archlinux/pages -f build_type=workflow
```

Until then, `deploy` shows a notice and deploys nothing.

The site at <https://pkgforge-dev.github.io/mirror-archlinux/> holds:

| path | contents |
| --- | --- |
| `index.html` | the dashboard: one static page, no JavaScript, light and dark |
| `badges/<target>.svg` | coverage and snapshot age of one target |
| `badges/<arch>.svg` | the same over the targets of one architecture |
| `badges/all.svg` | the same over every target |
| `badges/speed.svg` | pacman's time through the wrapper and through the official mirror, from the bench; a bench older than 2 days shows its age, in the warning colour |
| `charts/coverage.svg` | share of upstream files in the mirror, per target |
| `charts/freshness.svg` | snapshot age per target, against the sync interval |
| `charts/size.svg` | GiB per target, in the mirror and upstream |
| `charts/history-coverage.svg` | coverage per architecture, last 30 days |
| `charts/history-age.svg` | oldest snapshot age per architecture, last 30 days |
| `charts/speed.svg` | the bench: seconds per path and operation |
| `charts/narrow/<chart>.svg` | each chart at 420 px, for a phone |
| `status.json`, `history.json`, `bench.json` | the data behind the page |

`status.json` has schema 1. The header of `scripts/status-collect` describes each field.

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

## The status branch

On `main`, job `build` pushes branch `status` as one orphan commit, with force, on each run. The branch holds the site, plus:

| file | contents |
| --- | --- |
| `history.jsonl` | one line per status run; the last 2000 lines are kept. A target that a run could not read keeps the files and bytes of its last measured line, marked `"k": 1`. So a read that fails does not move the coverage history |
| `worker.md` | the body of the `worker-down` issue: every probe, and how to reproduce the first failure |
| `bench.json` | the newest bench |
| `bench/<date>.json` | each daily bench |

The next status run reads `history.jsonl` and the bench from the branch. The `worker` job of `status.yml` reads `status.json` and `worker.md` from it. ⚠ The branch is the only copy of the history. A run that fails to push leaves the previous branch in place, so no history is lost.

The pushes to `status` start no CI run: the push trigger of `ci.yml` covers `main` only, and its pull request trigger leaves out `status`.
