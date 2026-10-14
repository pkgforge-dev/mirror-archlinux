# Conventions

Keep these conventions in every change. The static suite enforces most of them.

## Commits

- Make one squashed commit per piece of work on `main`.
- Commit with the maintainer's own identity. Add no co-author line and no "generated with" line.

## Scripts

- A script has no extension. Its header says what it does, how to call it, and what its exit codes mean.
- A bash script starts with `set -euo pipefail`. `client/pacman-oci` is the one POSIX sh file. It must run under bash, dash and busybox sh.
- A python script (`scripts/status-render`) uses the standard library only. It runs as `python3 -I`. Its first line names python3.
- A script with a `#!` line is mode 100755 in the git index: `git update-index --chmod=+x FILE`. `scripts/lib.sh` is sourced, has no `#!` line, and stays 100644. `tests/static/40-executable-bits.sh` checks this.
- Every file under `client/` and `scripts/` is shell or python. `tests/static/70-python.sh` checks this.
- A script reads its inputs as data. A target file is parsed, never sourced. Each field of a database is checked against its grammar before it reaches a path, a command line or a tag.

## Failures stay visible

⛔ Never hide a failure.

- Do not write `|| true`, `set +e` or `continue-on-error`.
- Do not send the output of anything that matters to `/dev/null` (`2>/dev/null`, `>/dev/null 2>&1`).
- Capture an exit status as `rc=0; cmd || rc=$?`, then act on it.
- Give every curl call `--connect-timeout`, and `--max-time` or `--speed-time`, on its own command line.
- Run every oras call under `timeout`.

`tests/static/30-failures-stay-visible.sh` checks these rules in the shipped scripts and the workflows. It checks the oras rule in `scripts/` only. It does not check the `rc=0` form.

⛔ Do not end a pipeline in a reader that stops early. Examples are `head -n1`, `awk '... exit'`, and `grep -q` on a producer that keeps writing. Under `pipefail`, SIGPIPE (status 141) then ends the script. Read everything and decide at the end. `tests/static/35-pipeline-traps.sh` checks this rule.

- Each failure message says what was measured and how to reproduce it. `scripts/lib.sh` `die` prints one item per line. In Actions, its first line is also an error annotation.
- A script that sources `scripts/lib.sh` has an ERR trap. It names the command that ended the script under `set -e`, so no exit is silent.

## Workflows

`tests/static/50-workflow-policy.sh` checks each rule:

- `permissions: {}` at the top. Each job asks for what it needs.
- `pages: write` and `id-token: write` only in job `deploy` of `status.yml`. `contents: write` only in job `build` of `status.yml`.
- `shell: bash` by default, so each `run:` block has `-eo pipefail`.
- `timeout-minutes` on every job. A job that calls a reusable workflow cannot have one; the jobs of the called workflow have their own.
- Actions pinned by commit, with the version in a comment. The test checks the pin, not the comment. A local path (`./.github/workflows/x.yml`) is the same commit, so it counts as pinned.
- `persist-credentials: false` on every checkout.
- No `${{ inputs.* }}`, `${{ matrix.* }}`, `${{ needs.* }}` or event value inside a `run:` block. Pass the value through `env:`.
- No `pull_request_target` or `workflow_run` trigger.
- No use of the packages DELETE API. Nothing is ever deleted.
- No unquoted `if: !...`, which YAML reads as a tag.
- Every workflow with a `schedule:` is one that `scripts/keep-schedules-enabled` enables.

## Images

- Pin each image as `name:tag@sha256:<64 hex>`.
- Write a `# tag: <tag>` line at most 3 lines before the pin, with the pin's own tag. Renovate reads that line. `tests/static/75-renovate.sh` checks each pin and its line.
- In a target file, write the `# tag:` line directly before the `verify_image` or `keyring_image` line. `tests/static/60-targets.sh` checks it.

## Tests

- ⛔ See each new test fail once. Break the code in a copy, watch the test fail, and keep the tree as it was. Record the test, the fault and what was observed in [tests.md](tests.md).
- In a test that needs a tool which may be absent, call `need_tool`.
- An integration test picks free ports at run time and gives each container a unique name. Several runs can then share one host.
- A failed assertion prints what was measured and the command that reproduces it.

## Measurements

- Every number in the documents comes from the code or from a measurement. [measurements.md](measurements.md) gives the date and the source of each measurement.
- ⚠ Do not take timings in Git Bash on Windows. A process start costs about 165 ms there (20 runs of `/usr/bin/true` took 3297 ms).

## Text

Comments, messages, documents and test names use ASD-STE100 Simplified Technical English.

- Write one idea per sentence.
- Keep a procedural sentence to 20 words or fewer, and a descriptive sentence to 25 words or fewer.
- Use the active voice. Use the imperative for an instruction. Use simple tenses.
- Use simple, approved words: use, do, make, start, stop, show. Do not use utilize, leverage, ensure, robust, seamless or comprehensive.
- Use one name for one thing: "target", "snapshot", "the wrapper", "the Worker".
- Put a warning before the step it applies to.
- State the fact, the rule and the measurement. Write no narrative history: no "we found", no "the previous session". Dates of events go in [measurements.md](measurements.md) only.
- Do not use em dashes or marketing adjectives.

Use only these three markers:

| marker | means |
| --- | --- |
| ⛔ | a rule that must not be broken |
| ⭐ | a property the design depends on |
| ⚠ | a caution or a known limit |
