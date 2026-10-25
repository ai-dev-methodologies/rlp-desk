# Visual Verification Guide (Playwright + `visual`)

How to verify a `Type: visual` user story with screenshot comparison inside an rlp-desk campaign, and how to set up the environment so the comparison is trustworthy.

This is about **your project's** environment. It is not the CI setup of rlp-desk itself (see `ci-setup.md` for that).

## 1. What rlp-desk provides, and what it does not

rlp-desk does not render, install, or compare pixels. Comparison stays Playwright's own `expect(page).toHaveScreenshot()`. The `visual` subcommand wraps **your project's** `@playwright/test` and adds three things a bare `playwright test` cannot give a Verifier:

1. A normalized, deterministic JSON result (`rlp-desk.visual/1`).
2. A **baseline-integrity guard**: a Worker must not make a UI "match" by regenerating the baseline images.
3. Honest "cannot judge" outcomes: tool absent, browser missing, zero tests, timeout and unparseable output are exit `2`, never a pass.

```bash
node ~/.claude/ralph-desk/node/run.mjs visual detect --json
node ~/.claude/ralph-desk/node/run.mjs visual run --baseline-ref <campaign-start-sha> --json
```

It never installs anything, never uses `npx`, and needs no network. It runs `node_modules/.bin/playwright test --reporter=json` with `CI=1` from the project directory.

## 2. Install Playwright in your project (your step, not rlp-desk's)

```bash
npm i -D @playwright/test
npx playwright install --with-deps chromium     # downloads the browser; --with-deps also installs OS libraries on Linux
```

`visual detect` reports `present` only when both `node_modules/@playwright/test/package.json` and `node_modules/.bin/playwright` exist. If the browser binary is missing the run reports `reason: browser_missing` and prints the install command as a hint; rlp-desk never runs it for you.

Browsers are cached outside the project (`~/.cache/ms-playwright` on Linux, `~/Library/Caches/ms-playwright` on macOS). Cache that directory in CI, keyed on the `@playwright/test` version: each Playwright release expects a specific browser build, and a version bump without a re-install is the usual cause of `browser_missing`.

## 3. Make the comparison deterministic

A screenshot test that is flaky is worse than none: the Verifier cannot tell a real regression from noise.

- **Generate and verify baselines on the same OS and fonts.** macOS and Linux render text differently. Playwright encodes the platform in the baseline file name (for example `diff-darwin.png`), so a baseline made on a laptop does not exist on a Linux CI runner. Make baselines in the same environment that verifies them. The version-pinned official Playwright container (`mcr.microsoft.com/playwright:v<version>-jammy`) is the simplest way to get identical fonts everywhere.
- `workers: 1` (or `--workers=1` after `--`) for visual projects.
- In `playwright.config`: `expect: { toHaveScreenshot: { animations: 'disabled', maxDiffPixelRatio: 0.01 } }`. Keep the **threshold in the config file, not on the command line**, and commit the config before the campaign starts: `visual run --baseline-ref` diffs the config against the start commit (section 4), so a Worker that loosens the threshold is caught. A threshold passed on the command line, or a config edited mid-campaign, is not trustworthy evidence.
- Fix the viewport, `locale` and `timezoneId` in the config `use` block.
- No live network in visual tests: mock or serve fixtures locally. Dates, random ids, avatars and ads must be fixed or masked (`mask: [...]`).
- Wait for the page to be stable (web fonts loaded, images decoded) before the screenshot; Playwright waits for two identical consecutive screenshots, but not for your app's own async data.

## 4. How a campaign uses it

**Brainstorm (Leader):**

1. Run `visual detect`. A test-spec may name a visual command only when it reports `present`. If it reports `tool_absent`, tell the owner to install Playwright first (section 2); do not write a visual gate that can never run.
2. Record the campaign start commit in the test-spec (the Leader does this at brainstorm/seal time), for example under the verification commands:
   ```
   Visual baseline ref: <git rev-parse HEAD at brainstorm time>
   ```
3. Put the command in the visual story's L3 command block:
   ```
   node ~/.claude/ralph-desk/node/run.mjs visual run --baseline-ref <that sha> --json
   ```

**Baselines must exist and be committed before the campaign starts.** A campaign does not create the reference images it is judged against. For a new component, create and review the baselines first (outside the campaign, or in an earlier campaign), commit them, then record that commit as the start sha.

**Verifier:** runs the command itself and reads the JSON:

| Result | Meaning | Verdict |
|---|---|---|
| exit `0`, `baseline.added` empty | all screenshots match the committed baselines | evidence: `stats` + `baseline` |
| exit `0`, `baseline.added` non-empty | new baseline images appeared | open each new image and judge it against the AC |
| exit `1`, `screenshot_failures[]` | a screenshot differs | FAIL, cite `expected` / `actual` / `diff` paths |
| exit `1`, `baseline.modified` or `baseline.deleted` | baselines were changed after the start sha | FAIL unless the PRD AC explicitly authorizes re-baselining |
| exit `2` | cannot judge (see `reason`) | FAIL "gate unmet: `<reason>`"; never a silent downgrade |

`flaky` tests are reported in `stats` and `warnings` but do not change the exit code.

### Why `--update-snapshots` is forbidden inside a campaign

`playwright test --update-snapshots` overwrites the reference images with whatever the UI currently renders, so every comparison "passes"; `--ignore-snapshots` skips the screenshot assertions altogether. `visual run` therefore rejects both in every spelling Playwright's parser accepts, including compact short clusters such as `-uall` and `-xu` (exit `64`, `violations: ["update_snapshots_flag"]` or `["ignore_snapshots_flag"]`, Playwright is not started). The `--baseline-ref` guard covers the other routes: it compares the start commit's tree with the bytes on disk **after** the run, for committed, staged, unstaged, untracked **and git-ignored** files (ignore rules do not remove a file from the comparison), and checks the effective configuration Playwright reports. It does not trust the git index, `git diff` or content filters: git calls ignore `git replace` objects, and a guarded path with skip-worktree / assume-unchanged flags or a git content filter (clean/smudge, including Git LFS) is exit `2` (`index_flags_unverifiable` / `filter_unverifiable`), because git could not be believed about it. Files are compared as raw bytes, so a repository that rewrites line endings on commit can report a false `baseline_modified` (the safe direction).

| Route | Caught as |
|---|---|
| hand-copied or regenerated baseline image, deleted baseline | `baseline_modified` / `baseline_deleted` (new images: `baseline.added`) |
| edit to the Playwright config (threshold such as `maxDiffPixelRatio`, `snapshotPathTemplate`, `updateSnapshots`, `ignoreSnapshots`) | `config_modified`, listed in `baseline.config_changed` |
| effective `updateSnapshots` of `all` or `changed` (CLI or config) | `update_snapshots_enabled` (read from the report) |
| effective `ignoreSnapshots: true` (CLI or config) | `ignore_snapshots_enabled` (read from the report) |
| a skipped test (for example `test.skip` in a spec) | `tests_skipped` (a skipped screenshot test verified nothing) |
| an expected-failure annotation (`test.fail()`: a red test is reported as `expected`) | `expected_failure` (the report's `expectedStatus` is not `passed`) |
| a report that lacks the effective snapshot controls, whose counted tests lack results, `expectedStatus` or a valid result `status`, or whose `stats` or final attempts (expected => final result matches `expectedStatus`; flaky => an earlier failed attempt; unexpected => final does not match) disagree with its suites | exit 2 `report_incomplete` / `report_inconsistent` |
| a snapshot directory replaced by a symlink, or an untracked/ignored symlinked or nested-repository directory holding images | its files are listed (`baseline.added`, or `baseline.modified` for tracked images now behind a symlink). Only directories whose own path can lead to a guarded path are entered (for `**/*-snapshots/**`: a directory named `*-snapshots`; for `helpers/*.js`: `helpers`); unrelated nested repositories, linked worktrees and build-tree symlinks are never walked. A tracked symlink whose link text is unchanged is compared at its real paths with the ref (unchanged files are not "added"; a regenerated image is `baseline_modified`); a retargeted tracked link is `baseline_modified`. One budget of 20000 files covers all walks: beyond it, exit 2 `snapshot_dir_unverifiable` |

Guarded config files: **every** `playwright.config.{ts,js,mjs,cjs,mts,cts}` name in the project directory (Playwright takes the first that exists, in the order `.ts .js .mts .mjs .cts .cjs`, so a newly added higher-precedence file must count), the file given with `--config`, the effective config named in the report, and any `--protect '<glob>'` (repeatable) you add for files the config imports (shared helpers, a base config) or for spec files that are fixed by the contract. Each exact path is compared with the start commit **without git's ignore rules**: existence and raw bytes at the ref versus the file on disk. The path is resolved component by component and every symlink on the way, file or directory (`configs -> active -> strict`), is compared with the ref before continuing from its target; every directory above the path is compared by type, so retargeting a link or swapping a parent directory for a symlink to another committed file is a change. A config edit is a FAIL unless the PRD AC explicitly authorizes it.

A guarded path outside the git repository (an absolute `--config` elsewhere, a link pointing out of the repo) cannot be compared with the ref: the result is exit `2`, `reason: config_unverifiable`, never a pass. Keep the config inside the repository.

**Trust boundary**: the visual/mutation wrappers and the `--out` guard detect common gate-gaming shortcuts (regenerated baselines, loosened config, hidden/ignored files, symlink swaps, skip-worktree, clean filters, `git replace`, scope-narrowing flags, pre-planted report paths) and exit 2 on anything they cannot verify; cheap static checks are implemented, unclosable same-user races are documented ceilings.
  They are NOT a security boundary against deliberate same-user tampering (git internals, `node_modules`, tool binaries, raced files): Worker and Verifier share one user and one checkout by design (§1f, "not a Byzantine boundary").
  A wrapper exit code is evidence the Verifier weighs under the Evidence Gate and Anti-Gaming audits, never a verdict: it waives no Iron Law or Suppression check, and exit 2 or any `*_unverifiable` reason is FAIL "gate unmet".
  The Verifier re-runs the gate in a fresh CLONE of the repository (`git clone`, never `git worktree add`: a linked worktree shares `refs/replace` and `.git/info/attributes`) at the campaign start sha with the Worker's done-claim commit checked out, after `npm ci`, or in CI; that run's output is the evidence.
  This re-run is REQUIRED for every CRITICAL-risk US, waived only by the owner writing `Fresh-clone re-run: not required (owner)` in the global test-spec `test-spec-<slug>.md`, in its header above the first `## US-` heading; for other risk levels it is required only if the owner writes `Fresh-clone re-run: required (owner)` there. The Verifier prompt lists only that global file under Required reads; the per-US `test-spec-<slug>-US-*.md` copies are Worker-only, so the line is not copied into them.
  The owner writes that line during brainstorm (rlp-desk.md step 5.8); the Worker may not add or edit it (the test-spec is lane-protected, §7e) and the Leader cannot waive it. Any unexplained `config_changed`, `*_unverifiable` or `ignored > 0` also calls for the re-run.

**What the guard cannot see (ceiling):**

- `node_modules` is Worker-writable and is the comparator itself (Playwright's own code, plus anything the config imports from packages). Run the Verifier from a clean install (`npm ci`) or accept this limit explicitly.
- Per-call thresholds in spec files (`toHaveScreenshot(..., { maxDiffPixelRatio: 1 })`) and `test.skip` edits live in spec files, which a Worker legitimately writes in a TDD campaign, so specs are **not** guarded by default (guarding them would fail every Worker-authored test). `test.skip` is still caught through `tests_skipped`. When the visual specs are fixed by the contract (pre-existing, listed in the test-spec), add `--protect '<spec glob>'` to the command so any change to them is `config_modified`.

The guard looks at paths matching `**/*-snapshots/**` (Playwright's default snapshot directory). If your config sets `snapshotPathTemplate` or `snapshotDir`, pass `--snapshot-glob '<your glob>'` so the guard watches the right files. With no `--baseline-ref` the result has `baseline: null` and a warning: the integrity of the baselines was **not** checked.

## 5. Pre-gate replay and timeouts

The tmux leader replays Worker-recorded steps named `verify*` as a pre-gate, with a per-command soft timeout of 120 s (`--pre-gate-cmd-timeout`, default 120). `node` and `playwright` are on the replay allowlist, so a `visual run` step is replayable. A browser run that can exceed 120 s should be recorded under a step name that does **not** start with `verify` (for example `visual`), or the timeout raised. `visual run` has its own `--timeout <seconds>` (default 600); on expiry it kills Playwright's process group and exits `2` with `reason: timeout`.

## 6. Environment notes by mode

- **`--mode tmux`:** the Worker and Verifier panes run in your login environment. The pane needs the Playwright browser binaries and, on Linux, the OS libraries from `--with-deps`. Run headless only (the default); there is no display in a pane.
- **`--mode native` (slash command):** the same commands, run by the Leader's own shell tool. Nothing else differs.
- **CI for your project:** run the same `visual run` command. Use the pinned Playwright container for baselines and verification, cache the browser directory, and upload `test-results/` (the `expected` / `actual` / `diff` images) as artifacts on failure.

## 7. Reviewing a baseline change

A changed baseline image is a change to the **definition of correct**, so review it like code:

- The pull request that adds or changes baselines should contain only that change plus the code it belongs to.
- Review the images (the `diff` image helps), not just the file names.
- Regenerate baselines with `npx playwright test --update-snapshots` yourself, outside the campaign, in the environment from section 3, and commit them. Then start a new campaign from that commit.

## 8. Result reference (`rlp-desk.visual/1`)

```json
{
  "baseline": {"added": [], "config_changed": [], "deleted": [], "modified": [], "ref": "abc1234", "resolved": "<full sha>"},
  "exit_code": 1,
  "failed_tests": [{"file": "visual.spec.js", "message": "Error: expect(page).toHaveScreenshot(expected) failed", "title": "screenshot differs"}],
  "hint": null,
  "playwright_version": "1.64.1",
  "reason": null,
  "schema": "rlp-desk.visual/1",
  "screenshot_failures": [{"actual": "...", "diff": "...", "diff_pixels": 78860, "diff_ratio": 0.99, "expected": "...", "file": "visual.spec.js", "snapshot": "diff", "title": "screenshot differs"}],
  "stats": {"expected": 2, "flaky": 0, "skipped": 0, "unexpected": 1},
  "status": "fail",
  "violations": [],
  "warnings": []
}
```

`status` is `pass`, `fail`, `tool_absent` or `error`. For `error`, `reason` is one of `browser_missing`, `no_tests`, `runner_error`, `runner_exit_<code>`, `timeout`, `unparseable`, `spawn_failed`, `baseline_unverifiable`, `config_unverifiable`, `snapshot_dir_unverifiable`, `index_flags_unverifiable`, `filter_unverifiable`, `report_incomplete`, `report_inconsistent`, `internal_error`. Output has sorted keys and no timestamps, so two identical runs print identical bytes.

Exit codes: `0` pass, `1` fail or baseline modified/deleted, `2` cannot judge, `64` usage error (including a rejected update-snapshots flag).

The field layout was checked against real `@playwright/test` 1.64.1 output (`tests/fixtures/visual/`). A different Playwright major version may change the JSON report; an unrecognized report is `unparseable` (exit `2`), never a pass.
