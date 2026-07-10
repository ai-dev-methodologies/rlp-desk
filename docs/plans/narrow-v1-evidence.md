# narrow-v1 campaign evidence

Dev-meta record of per-US verification evidence for the narrow-v1 PRD
(`.omc/plans/narrow-v1-prd.md`). One section per US, appended as each lands.
Lives under `docs/plans/` (git-tracked, not in package.json's `files`
allowlist, so not npm-shipped and not synced by `scripts/postinstall.js`).
This file originally landed at `docs/rlp-desk/internal/narrow-v1-evidence.md`
and was force-added there in error — that directory is `.gitignore`d as
"local only, never publish" — then relocated here.

## US-001: Single-source the Worker model-upgrade ladder + user override

### AC7 — pre-land SV-trigger oracle check

Constraint: no edits to `src/commands/rlp-desk.md`, `src/governance.md`, or
`src/scripts/init_ralph_desk.zsh` for this PRD (Principle 4 — avoids the
3-scenario real-LLM gate this round). Verified via a direct diff against the
pre-campaign anchor commit.

```
ANCHOR=$(git log --oneline | grep -E "bump version to 0.18.8" | awk '{print $1}' | head -1)
# ANCHOR=a805d5e
git diff "$ANCHOR..HEAD" -- src/commands/rlp-desk.md src/governance.md src/scripts/init_ralph_desk.zsh
```

Output: empty diff (exit 0). Zero changes to the three SV-trigger files
across all US-001 commits.

### Gate results (at the commit this evidence file lands in)

- `npm run test:node`: 437/437 pass, 0 fail
- `npm run test:zsh`: exit 0 (every `tests/test_*.sh` file passes; the
  script does `... || exit 1` per file, so a 0 exit is authoritative for
  the whole suite)
- `npm run sv-gate:fast`: 85/85 pass, exit 0
- `npm run manifest:check`: in sync (20 entries — `models.json` and
  `model-ladder.mjs` now included after extending
  `scripts/build-node-manifest.js` to walk `.json` alongside `.mjs`)

### Codex review round 1 — ITERATE, 1 P1 + 3 P2, all fixed

- P1: schema validation gap — a syntactically-valid override like
  `{"upgrades":{"haiku":123}}` was accepted; non-string values flowed
  through into resolved output instead of being treated as malformed.
  Fixed in both loaders (`src/node/model-ladder.mjs`
  `normalizeUpgrades()`; `src/scripts/lib_ralph_desk.zsh`
  `get_next_model()`'s `ladder_filter` jq expression) — every `upgrades`
  value must now be a string (empty string still allowed = ceiling); any
  other type makes the whole layer malformed → warn → fall through.
  Covered by 6 new Node cases (number/boolean/null/object/array +
  empty-string-still-valid) and a 5-case zsh loop
  (`US001-schema: <type> upgrades value rejected`).
- P2-1: test hermeticity — several new tests could be polluted by a real
  `~/.claude/rlp-desk-models.json` on the machine running them (Node's
  `campaign-main-loop.mjs` captures its `MODEL_UPGRADES` constant from the
  ambient env at import time). Fixed: `tests/node/models-ladder.test.mjs`
  now sets `process.env.RLP_DESK_MODELS_FILE` to a guaranteed-nonexistent
  path BEFORE a dynamic `import()` of `campaign-main-loop.mjs`; the zsh
  test files (`test_us011_worker_model_upgrade.sh`,
  `test_us004_progressive_upgrade.sh`,
  `tests/sv-large-campaign/test-model-upgrade-ladder.zsh`) now force
  `RLP_DESK_MODELS_FILE` to a nonexistent path in every harness that
  doesn't already set its own override explicitly.
- P2-2: this CHANGELOG entry — added under `## [Unreleased]` → `### Changed`
  in `CHANGELOG.md`, documenting the Node native-mode `:low → :medium`
  alignment (deliberate behavior change) and the `models.json`
  externalization.
- P2-3: this evidence file — originally landed at
  `docs/rlp-desk/internal/narrow-v1-evidence.md` (force-added against that
  directory's `.gitignore` "never publish" rule), then relocated to
  `docs/plans/narrow-v1-evidence.md`.

Post-fix re-verification: `tests/node/models-ladder.test.mjs` (16/16),
`tests/test_us011_worker_model_upgrade.sh` (30/30),
`tests/test_us004_progressive_upgrade.sh` (23/23),
`tests/sv-large-campaign/test-model-upgrade-ladder.zsh` (18/18),
`npm run test:node` (437/437), `npm run test:zsh` (exit 0),
`npm run sv-gate:fast` (85/85).

## US-002: Prune structural grep-tests from the shell harness

### Classification (AC1)

All 69 `tests/test_*.sh` files were read in full and classified by the
execution-trace criterion (runs/extracts-and-executes real runtime code vs.
pins an SV-trigger doc contract vs. pure structural grep with neither).
Full per-file table and rationale: `docs/plans/narrow-v1-test-inventory.md`
(deviation from PRD text: lands at `docs/plans/`, not
`docs/rlp-desk/internal/`, which is `.gitignore`d never-publish — same
reason as the US-001 evidence-file relocation above).

- BEHAVIORAL: 49
- STRUCTURAL-CONTRACT (pins `src/commands/rlp-desk.md` and/or
  `src/governance.md`, kept per Principle 2): 12
- STRUCTURAL (prune candidates, moved to `tests/structural-archive/`): 8
  — `test_final_verify_sequential.sh`, `test_monitor_counter.sh`,
  `test_us001_tmux_sv_report.sh`, `test_us005_completed_stories_loader.sh`,
  `test_us007_verifier_anti_rubber_stamp.sh`,
  `test_us012_sv_tmux_skip_traceability.sh`,
  `test_us025_session_disambiguation.sh`, `test_us026_runner_lockfile.sh`.

### Move + gate updates (AC2, AC3)

`git mv` into `tests/structural-archive/` (new dir, `README.md` explainer
added). `npm run test:zsh` globs `tests/test_*.sh` only, so the 8 files stop
running automatically with no harness code change.

Two defects surfaced during the move, both fixed before commit:
1. 5 of the 8 archived files resolve their own repo root via a
   `dirname "$0"` chain (`ROOT="$(cd "$(dirname "$0")/.." && pwd)"` or the
   zsh `${0:A:h}`/`${SCRIPT_DIR:h}` equivalent) that assumed one level of
   nesting under `tests/`. Moving them one directory deeper broke source-file
   lookup (confirmed by running each moved file directly — `test_us012_sv_tmux_skip_traceability.sh`
   dropped from 5/5 to 2 pass/3 fail with the exact symptom: `WITH_SELF_VERIFICATION_REQUESTED`
   assertions failing because `$RUN` resolved to a nonexistent path one level
   too shallow). Fixed by adding one more `..`/`:h` hop in each of the 5
   affected files (`test_us001_tmux_sv_report.sh`,
   `test_us005_completed_stories_loader.sh`,
   `test_us012_sv_tmux_skip_traceability.sh`,
   `test_us025_session_disambiguation.sh`, `test_us026_runner_lockfile.sh`).
   Re-verified all 8 archived files pass standalone after the fix.
2. `tests/sv-gate-fast.sh` names 13 `tests/test_*.sh` files individually in
   its "Critical zsh unit tests" array; one,
   `test_us012_sv_tmux_skip_traceability.sh`, was in the archived set. Its
   path in that array was updated to
   `tests/structural-archive/test_us012_sv_tmux_skip_traceability.sh` (entry
   kept, not deleted). `tests/sv-gate-full.sh` references no
   `tests/test_*.sh` file by path (verified via grep) — no update needed
   there.

### Gate results (AC3, AC4)

- `npm run test:zsh`: exit 0. 61 files executed (`grep -a '^=== tests/'` on
  the run log), matching BEHAVIORAL(49) + STRUCTURAL-CONTRACT(12) exactly.
- `npm run test:node`: 437/437 pass, 0 fail (unchanged from US-001 baseline
  — this US touched no Node source).
- `npm run sv-gate:fast`: 85/85 pass (was 84/85 before the path-resolution
  fix — the `test_us012_sv_tmux_skip_traceability.sh` gate entry failed
  post-move until both fixes above landed).
- Inventory doc (AC4) states the archive-exclusion rationale and
  re-inclusion criterion (a structural test becomes contract-load-bearing —
  e.g. a new SV-trigger doc, or a new section in an existing one that an
  archived file already happens to check).

### AC7-equivalent SV-trigger check (Principle 4 constraint, all US)

```
git diff --stat HEAD -- src/commands/rlp-desk.md src/governance.md src/scripts/init_ralph_desk.zsh
```

Output: empty diff (exit 0). Zero changes to the three SV-trigger files in
the US-002 commit.

### Commit

`746a57c` — `refactor(tests): US-002 — archive structural grep-tests,
execution-trace inventory` (12 files changed: inventory doc, CHANGELOG
entry, `tests/structural-archive/README.md`, 8 `git mv` renames + their
path fixes, `tests/sv-gate-fast.sh` path update).

### Codex ITERATE round 1 — 2 P2, both fixed (0 P1)

Codex critic on the US-002 diff: no P1 ("your 8 archived files are
genuinely non-runtime; good"). Two P2s:

- **P2-a (classification correction)**: the first pass defined
  "SV-trigger files" as only `src/commands/rlp-desk.md` and
  `src/governance.md`, omitting `src/scripts/init_ralph_desk.zsh` — even
  though PRD Principle 4 names all three. Re-examined the 5 files Codex
  flagged:
  - `test_us007_verifier_anti_rubber_stamp.sh` (Codex's highest-risk pick):
    its `extract_verifier_prompt()` pins the `# --- Verifier Prompt ---`
    template embedded in `init_ralph_desk.zsh` — the literal text sent to
    the real LLM verifier in production, with no other test enforcing it.
    **Restored** `tests/structural-archive/` → `tests/` (`git mv`) as
    STRUCTURAL-CONTRACT. No path-variable fix needed (its `INIT` var is
    CWD-relative, not `$0`-relative) — verified standalone (`bash
    tests/test_us007_verifier_anti_rubber_stamp.sh`: 12/12 pass).
  - `test_final_verify_sequential.sh`, `test_monitor_counter.sh`,
    `test_us005_completed_stories_loader.sh`,
    `test_us025_session_disambiguation.sh`: each greps only
    `run_ralph_desk.zsh`/`lib_ralph_desk.zsh` (verified via full-file
    grep for `governance.md`/`rlp-desk.md`/`init_ralph_desk` — zero hits
    in all 4). Not an SV-trigger file → stay archived.
- **P2-b (precision)**: CHANGELOG and inventory taxonomy said archived
  files were "string-presence-only, zero runtime execution" — overstated.
  `test_us005_completed_stories_loader.sh`'s L3 section executes a
  hand-COPIED reimplementation of the sed/grep/tr pipeline (literal text,
  not the real `$RUN` source) against a synthetic fixture;
  `test_us026_runner_lockfile.sh`'s AC5-7 execute real OS primitives
  (`mkdir`, `kill -0`, `shasum`) simulating lock semantics, never the real
  `acquire_slug_lock`. Reworded CHANGELOG, the inventory's classifier
  section, the archive policy paragraph, `tests/structural-archive/README.md`,
  and both files' table rows to state precisely: no assertion consumes
  output of the *real* product runtime, and the hand-copy/simulation
  pattern in those two files is itself the reason they're archived
  (silent-divergence risk from the real implementation).

Gate results after the fix: `npm run test:zsh` exit 0, 62 files executed
(`grep -a '^=== tests/'` on the run log) — matches the corrected
BEHAVIORAL(49) + STRUCTURAL-CONTRACT(13) = 62 exactly (up from 61: +1 for
the restored `test_us007`). `npm run sv-gate:fast`: 85/85 pass (unaffected
— `test_us007` was never referenced there). SV-trigger diff check
(`git diff --stat HEAD -- src/commands/rlp-desk.md src/governance.md
src/scripts/init_ralph_desk.zsh`): empty, exit 0.

Updated counts: BEHAVIORAL 49 (unchanged) / STRUCTURAL-CONTRACT 12→13 /
STRUCTURAL 8→7 / retained run-set 61→62.

Commit: `1b24ea3` — `fix(us-002): restore contract-pinning tests + precise
taxonomy wording (codex round 1)` (4 files changed: CHANGELOG.md,
`docs/plans/narrow-v1-test-inventory.md`, `tests/structural-archive/README.md`,
`git mv` of `test_us007_verifier_anti_rubber_stamp.sh` back to `tests/`).

## US-003: Declare the support matrix (docs-only)

AC1: added a `## Supported Platforms` section to `README.md` naming macOS
(primary dev) and Ubuntu Linux (CI/server) as supported, everything else
best-effort/unsupported. AC2: no code changes — confirmed the IMP-01
GNU-first `stat` dual-path (`src/scripts/lib_ralph_desk.zsh:39`,
`src/scripts/run_ralph_desk.zsh:847-848`) is untouched and still serves
both platforms (`stat -c %Y` GNU/Linux first, `stat -f %m` BSD/macOS
fallback).

Gate results: `npm run sv-gate:fast` 85/85 pass.

Commit: `6c1b48f` — `docs: US-003 — declare supported platform matrix`.

## US-004: Two-tier release process (docs-only)

AC1: restructured CLAUDE.md's `### Release Workflow` section into
`#### Tier-1 (default, dogfood)` (commit → FF merge to `main` → `git tag
vX.Y.Z` → local sync via `npm install` → retained §4.5 sync verification;
no `npm publish`, no A1-A2/P5 registry ceremony) and `#### Tier-2
(registry release, on-demand: external users / quarterly)` (the existing
numbered runbook body, kept intact — steps 0/1-7/7a unchanged in content,
only re-indented under the new heading). AC2: added a 3-line scope
preamble to `docs/plans/v0.15.4-release-runbook.md` stating it applies to
Tier-2 releases only, pointing to CLAUDE.md for Tier-1. AC3: the `Local
File Sync (ABSOLUTE — no exceptions)` section's existing text is
unchanged; appended one sentence noting it applies to both tiers. AC4
(shipping this campaign as Tier-1 with `git tag v0.19.0`) is executed at
campaign end, not per-US.

Gate results: `npm run sv-gate:fast` 85/85 pass;
`bash tests/test_us002_governance_cb_table.sh` 10/10 pass (unaffected —
targets `governance.md` §7¾/§8, not CLAUDE.md);
`bash tests/test_us007_verifier_anti_rubber_stamp.sh` 12/12 pass
(unaffected — targets `src/scripts/init_ralph_desk.zsh`'s verifier
template, not CLAUDE.md).

Commit: `b356e61` — `docs: US-004 — two-tier release process (Tier-1
dogfood / Tier-2 registry)`.

## US-005: Reposition README (docs-only)

AC1: rewrote the README's opening tagline and first section (previously
"Fresh-context iterative loops... brings Ralph Loop philosophy...") to
lead with three pillars: durable file-based campaign state (atomic
status writes, append-only verified ledger, write-locked done-claim/
verify-verdict handoff sentinels — resumable and `jq`-inspectable), independent verifier governance (Iron Laws, Evidence
Gate IDENTIFY→RUN→READ→VERIFY→claim, anti-rubber-stamp guidance), and
cross-family consensus (claude × codex, both-must-pass mode) —
terminology cross-checked against the existing "Verification Policy"
and "Verification Strategy" sections further down the same README so the
pitch doesn't introduce new vocabulary. The fresh-context loop is now
introduced as the mechanism those three ride on, in the paragraph after
the pillar list, with the ASCII Leader/Worker/Verifier diagram retained
immediately below it. Ralph Loop / OpenAI Codex / design-desk attribution
was dropped from the opening paragraph (no longer needed there) but
remains intact in the existing `### Lineage` table further down — no
attribution was removed from the document, only de-duplicated. AC2: no
new feature claims — grepped the full diff and file for "cross-machine";
zero hits before and after.

Also added the required CHANGELOG `[Unreleased]` → `### Docs` entry
covering all three US (support matrix, two-tier release, README
repositioning).

Gate results: `npm run sv-gate:fast` 85/85 pass;
`bash tests/test_us002_governance_cb_table.sh` 10/10 pass;
`bash tests/test_us007_verifier_anti_rubber_stamp.sh` 12/12 pass (both
unaffected — neither targets README.md or CHANGELOG.md).

Commit: `ac6910e` — `docs: US-005 — reposition README around durable state
+ verification moat`.

### Codex round 1 (ITERATE — 3 wording fixes)

Codex critic verdict: ITERATE. US-003/US-004 clean; US-005 flagged 3
precision issues in the new README opening/tables:

- **P2** — the durable-state bullet claimed `status.json` itself was
  "sentinel-locked", conflating two different mechanisms. Verified against
  the actual code: `STATUS_FILE` writes go through `atomic_write` only
  (`lib_ralph_desk.zsh:787`) — atomic, not chmod-locked. The chmod-0444
  write-lock (`_lock_sentinel`, `lib_ralph_desk.zsh:429-434`) is applied
  only to `DONE_CLAIM_FILE`, `VERDICT_FILE`, and `SIGNAL_FILE`
  (`run_ralph_desk.zsh:987,2631,2999,3103,3883,3888,4197`) — the
  Worker→Verifier handoff files, not campaign status. Reworded the bullet
  to separate the two: status is "written atomically... as resumable,
  jq-inspectable status/ledger files", handoff files (done-claims,
  verify-verdicts) are "write-locked handoff sentinels... that a finished
  pane cannot revise". No more "sentinel-locked status".
- **P3-1** — the `### Run Options` table (under `## Commands`, which
  documents `/rlp-desk run <slug> [--opts]` slash syntax) listed `--mode`
  default as `tmux`, but the README's own Execution Modes section
  (line ~294, pre-existing/unedited) states native is "the slash-command
  **default**". Confirmed via `src/node/run.mjs:598-605`: the Node CLI's
  `--mode native` hard-errors and redirects to the slash command — so CLI
  default (tmux) and slash-command default (native) are genuinely
  different surfaces, not a typo. Added a 2-line clarifying note above the
  table stating both defaults explicitly and linking to Execution Modes.
- **P3-2** — the Leader/Worker/Verifier ASCII diagram sits directly under
  the new moat pitch with generic `Agent()` labels, which could read as
  the only/production dispatch path when tmux (zsh leader, separate panes)
  is actually canonical per ADR-001. Added a one-line qualifier above the
  diagram: it depicts native-mode `Agent()` dispatch; tmux mode (production
  default) runs Worker/Verifier as tmux panes instead, with a link to
  Execution Modes.

Gate results after fix: `npm run sv-gate:fast` 85/85 pass;
`bash tests/test_us002_governance_cb_table.sh` 10/10 pass;
`bash tests/test_us007_verifier_anti_rubber_stamp.sh` 12/12 pass (both
unaffected — only README.md changed).

Commit: `docs(us-005): precise state/mode wording (codex round 1)`.

## NARROW decision test T1 — native-harness dogfood (2026-07-10)

Design: ported the governance Iron Laws (IL-1 Evidence Gate, IL-3 independence
/ anti-rubber-stamp, IL-4 test diversity, IL-5 skip detection) and the
worker/verifier file protocol (PRD, memory, done-claim.json, verify-verdict.json)
into a NATIVE agent-dispatch loop (no tmux, no zsh leader): interactive session
as leader, fresh-context haiku workers, fresh-context sonnet verifiers, all
state on disk in rlp-desk conventions. Representative toy campaign: t1kv
(JSON-backed kv CLI, 2 US: core ops + TTL expiry, node:test).

Result: COMPLETED start-to-finish. US-001 11/11 tests, verifier PASS with 10
independently executed checks (incl. manual cross-process persistence repro);
US-002 20/20 (9 new TTL tests), final verifier PASS with 16 checks (manual
expiry-boundary repro via injectable clock, --ttl 0 rejection, US-001
regression sweep). IL-4 counted per US; IL-5 clear; verifier flagged one
non-blocking coverage gap unprompted (thin negative-category coverage) —
evidence of real scrutiny, not rubber-stamping. Cost: 4 campaign dispatches
(2 haiku workers + 2 sonnet verifiers), minutes-scale (a 5th sonnet dispatch
reviewed this evidence document itself, outside the campaign).

Interpretation (honest bounds):
- The native path CAN run a small campaign with verifier rigor intact — the
  completion criterion of T1 fired. Cost was small in absolute terms
  (4 dispatches, minutes), but no tmux baseline of the same campaign was run,
  so no direct cost comparison is claimed.
- BUT it fired only WITH the durable file-based state ported in: BOTH workers
  finished without delivering a report (silent-idle; the verifiers did
  report), and the leader recovered purely by polling done-claim/verdict
  files. The durable-state moat is what made the native loop viable — it
  transfers, it is not obsolete.
- NOT demonstrated: unattended long-horizon operation (leader was a live
  interactive session; 2-US toy, minutes not hours) and cross-session-death
  resilience. ADR-001's constraint is narrowed, not void.

Verdict: NARROW stands, sharpened — the tmux leader's remaining niche is
unattended long-horizon campaigns + session-death recovery; small/interactive
campaigns are viable natively today by carrying the file-state conventions.
Next falsifier: an hours-scale multi-US native campaign surviving a leader
session restart.

## Lifecycle metrics full wiring (2026-07-10)

Wired the 4 lifecycle metrics that were previously Node-only
(`iter_signal_write_to_read_ms`, `verdict_write_to_read_ms`,
`pane_reap_latency_ms`, `sentinel_lock_to_unlock_ms`) into the zsh production
leader (`src/scripts/run_ralph_desk.zsh` / `lib_ralph_desk.zsh`), so all 5
lifecycle metrics now emit identically on both the Node (slash-command `--mode native`) and
zsh (`--mode tmux`) leaders, and flipped `RLP_LIFECYCLE_METRICS` to default ON
(opt out with `=0`).

**RED** (`tests/test_b3_lifecycle_emit.sh`, commit `57046b6`): 6 assertions
failed against pre-change code — locale-robustness site count (2 vs expected
3), default-ON behavior, `log_lifecycle_metric` iter/us_id/sentinel_type
context embedding (×2), and `_kill_pane_process`'s new `sentinel_type` 3rd arg
(×2, both the "emits 2 records" and "both metric names present" cases). One
case ("without sentinel_type: no regression") passed immediately since it
required no new code.

**Emit-site locations** (zsh leader):
- `iter_signal_write_to_read_ms`: `run_ralph_desk.zsh` worker-signal-detected
  branch (`_lifecycle_emit_write_to_read`, called immediately after
  `poll_for_signal "$SIGNAL_FILE" ...` returns success, before the worker pane
  reap).
- `verdict_write_to_read_ms`: 3 call sites — `run_single_verifier` (consensus
  per-engine verify), `_final_verify_one_us` (sequential final-verify), and
  the main per-iteration consensus verify loop — each immediately after its
  `poll_for_signal "$VERDICT_FILE" ...` success, before the verifier pane reap.
- `pane_reap_latency_ms`: `_kill_pane_process` (`lib_ralph_desk.zsh`) gained an
  optional 3rd arg `sentinel_type`; the 4 call sites above (worker + 3
  verifier reaps) now pass `"iter-signal"` / `"verify-verdict"`. Mirrors
  Node's `reapProducer(paneId, sentinelFile, sentinelType)` — `pane_eof_to_
  cleanup_ms` always fires, `pane_reap_latency_ms` fires only when the reap
  followed a sentinel observation. The A4-fallback kill (`worker-a4`) and the
  transient poll-retry kills deliberately do NOT pass a sentinel_type (they
  are not a "fresh signal/verdict observed" event) — a documented scoping
  choice, not a 1:1 mirror of every Node reap call.
- `sentinel_lock_to_unlock_ms`: new `_lifecycle_mark_lock_start` /
  `_lifecycle_mark_unlock` pair (keyed by sentinel basename, mirrors Node's
  `_sentinelLockTimes` Map). `markLockStart` called immediately before each
  `_lock_sentinel "$SIGNAL_FILE"` / `_lock_sentinel "$VERDICT_FILE"` call (3
  verdict-lock sites + 1 signal-lock site); `markUnlock` called immediately
  after the loop-top `_unlock_sentinel "$SIGNAL_FILE"` / `_unlock_sentinel
  "$VERDICT_FILE"` pair. DONE_CLAIM_FILE is intentionally excluded (never
  unlocked in the happy path — same H2 exclusion Node already documented).

**GREEN**: `zsh tests/test_b3_lifecycle_emit.sh` → 25/25 PASS.
`zsh tests/test_b3_pane_reap_integration.sh` → 7/7 PASS (no regression).
`npm run test:zsh` → exit 0, all `tests/test_*.sh` files pass (zero `FAIL`
markers across the full log). `npm run test:node` → 450/450 pass, 0 fail
(after re-pointing 2 additional Node tests discovered mid-GREEN —
`test-campaign-jsonl-shape.test.mjs` AC4.3/4.7 and `test-lifecycle-metrics.
test.mjs`'s debugLog-zero-overhead case — both had constructed a
`LifecycleMetricsCollector({ env: {} })` to simulate "flag unset = disabled",
which the default-ON flip inverted; re-pointed to explicit
`RLP_LIFECYCLE_METRICS: '0'`). `npm run sv-gate:fast` → 92/92 pass (85
existing + 7 new checks for the full-wire helpers/call-sites/default).

**A5 oracle** (`git diff b3d27da..HEAD -- src/commands/rlp-desk.md
src/governance.md src/scripts/init_ralph_desk.zsh`): empty — the 3 protected
files were never touched.

**Re-pointed tests** (all honest re-points of "unset means off" assumptions
invalidated by the default flip, not weakenings):
- `tests/test_b3_lifecycle_emit.sh` case 1 + the `emit_row` harness: `flag=0`
  now means explicit `export RLP_LIFECYCLE_METRICS=0` instead of `unset`.
- `tests/test_b3_lifecycle_emit.sh` case 9 (locale-robustness site count):
  2 → 3 (the new `_epoch_ms()` helper is a 3rd, deliberately separate,
  EPOCHREALTIME-strip site — `_kill_pane_process`'s own tested t0/t1 pair was
  left untouched rather than refactored to share it).
- `tests/node/test-lifecycle-metrics.test.mjs`: AC4.2 "unset" case rewritten
  to assert default-ON; the boolean-semantics table rewritten for the new
  truth table (only `'0'` disables); the debugLog-zero-overhead case switched
  from `env: {}` to `env: { RLP_LIFECYCLE_METRICS: '0' }`.
- `tests/node/test-campaign-jsonl-shape.test.mjs`: the "flag unset → null"
  test and its `disabledCollector` construction switched to explicit `'0'`;
  file-header comment updated for the new truth table.
- `tests/node/us007-analytics-reporting.test.mjs`: added an explicit
  `env: { RLP_LIFECYCLE_METRICS: '0' }` to the `run()` call whose assertion
  depends on `lifecycle_metrics` being `null`.
- `tests/sv-gate-fast.sh`: the "zsh helper gated on RLP_LIFECYCLE_METRICS"
  check re-pointed from `RLP_LIFECYCLE_METRICS:-0` to `:-1`; 7 new checks
  added for the full-wire helpers, call-site tagging, and the Node default.
- `tests/sv-real-llm/lib/b3-lifecycle-assertions.sh`: the comment claiming
  3 metrics are "NOT emitted by the zsh leader (Node-only)" updated — they
  now are, reusing the existing Node-derived synthetic bands as a first-pass
  approximation pending a zsh-sample refit (same pattern already used for
  `pane_eof_to_cleanup_ms` before its 2026-06-30 refit).

**Semantics that could NOT be mirrored exactly** (stated plainly, not glossed
over):
- `_file_mtime()` (used by `_lifecycle_emit_write_to_read` for
  `iter_signal_write_to_read_ms` / `verdict_write_to_read_ms`) is WHOLE-SECOND
  precision (GNU `stat -c %Y` / BSD `stat -f %m`), unlike Node's
  `fsSync.statSync().mtimeMs` (sub-millisecond). The zsh-emitted value_ms for
  these two metrics is accurate to within ~1000ms on the file-write anchor,
  not true milliseconds. `_file_mtime` was explicitly out of scope to rewrite
  (per the task brief) — documented as a caveat in the helper's docstring
  rather than worked around.
- The zsh `LIFECYCLE_RECORDS` JSON records now carry `iter` / `us_id` /
  `sentinel_type` context fields when the caller passes them (extended
  `log_lifecycle_metric` with 3 new optional positional args), matching
  Node's ctx object for the fields cheap enough to carry without generic
  key=value plumbing. `pane_id` remains debug.log-text-only on the zsh side
  (Node embeds it in JSON too) — a deliberately capped scope, not a full
  generic-context port.
- B3-S2 tolerance bands for the 3 newly-wired-on-zsh metrics
  (`B3_BAND_ITER_SIGNAL_MS`, `B3_BAND_VERDICT_MS`,
  `B3_BAND_PANE_REAP_LATENCY_MS`) still hold their original Node-sample
  values; they have not been refit against a real zsh-leader sample the way
  `pane_eof_to_cleanup_ms` was. B3-S2 is non-blocking by default
  (`B3_STAGE2_BLOCKING` unset), so this is a soft gap, not a false-pass risk.

Commits: `57046b6` (RED), plus the implementation commit that follows this
evidence entry.

### Codex round 1 (P2-1, P2-2, P3) — flag-semantics unification + verdict lock-pair hygiene

Codex critic found 2 P2s + 1 P3 on the full-wire branch. Fixed all three
TDD-first (new/failing cases in `tests/test_b3_lifecycle_emit.sh` confirmed
against the pre-fix code, then implemented).

**P2-1 — flag semantics diverged between leaders.** zsh gated every lifecycle
check on `"${RLP_LIFECYCLE_METRICS:-1}" == "1"` while Node's
`lifecycleMetricsEnabled` is `env[FLAG] !== '0'`. Consequence:
`RLP_LIFECYCLE_METRICS=true` would DISABLE telemetry on the zsh (`--mode
tmux`) leader while ENABLING it on the Node (slash-command `--mode native`) leader — a real
cross-leader divergence, not just a docs nit. Fix: all 7 zsh gate checks (the
6 pre-existing ones from the first full-wire commit plus the new
`_lifecycle_clear_lock_mark` added below) now use
`"${RLP_LIFECYCLE_METRICS:-1}" != "0"`, matching Node's contract exactly —
unset or any non-`"0"` value enables, `"0"` is the sole opt-out. Verified
Node's empty-string/whitespace handling already matches zsh's `:-` fallback
behavior (both collapse unset/empty to the enabled default), so no Node-side
change was needed.

**P2-2 — stale verdict lock-pair could false-pair across instances.**
`_lock_sentinel "$VERDICT_FILE"` is called from 3 different code paths
(`run_single_verifier`, `_final_verify_one_us`, the main consensus verify
loop), each preceded by `_lifecycle_mark_lock_start "${VERDICT_FILE:t}"`
(basename-keyed, since VERDICT_FILE's path is constant across the whole
campaign). 4 of the 5 `rm -f "$VERDICT_FILE" ...` sites in the codebase
delete/replace the file to prepare a fresh dispatch or retry WITHOUT going
through the normal `_unlock_sentinel` + `_lifecycle_mark_unlock` pairing (rm
does not require the target file's own chmod bits, so it succeeds on a
0o444-locked file without an explicit unlock). If such an attempt then fails
before reaching its OWN `_lock_sentinel` call (e.g. a poll hard-fail, an
early `return`), the PRIOR successful lock's mark is left dangling in
`LIFECYCLE_LOCK_TIMES`. A later, unrelated `_lifecycle_mark_unlock` call
(e.g. the next loop-top iteration's defensive unlock) would then pair with
that stale mark, emitting a bogus `sentinel_lock_to_unlock_ms` duration
spanning an unrelated delete+recreate cycle.

**Chosen semantics** (checked against Node's actual behavior first, per the
task brief): Node's `markLockStart` is a bare `Map.set()`, so a fresh lock
BEFORE the next unlock already overwrites cleanly — re-locking without
unlocking is safe on both leaders and required no fix (confirmed by test
case 19: lock→unlock→re-lock→unlock emits two independent, correctly-scoped
pairs). The unsafe gap Node doesn't have an equivalent for is specifically
delete-without-relock. Fix: new `_lifecycle_clear_lock_mark(sentinel_key)`
helper (`lib_ralph_desk.zsh`) that drops the pending mark WITHOUT emitting —
called immediately before all 4 non-loop-top `rm -f "$VERDICT_FILE" ...`
sites (`run_single_verifier` top, `_final_verify_one_us` top + D-4 retry, the
main consensus loop's pre-dispatch clear). The 5th `rm` site (loop-top
cleanup) was left untouched — it already fires immediately after a proper
`_unlock_sentinel` + `_lifecycle_mark_unlock` pair in the same block, so the
mark is already cleared via normal pairing before that rm runs.

**P3 — test gap closed.** Added behavioral cases (not just structural greps)
to `tests/test_b3_lifecycle_emit.sh`: `_lifecycle_mark_lock_start` /
`_lifecycle_mark_unlock` exercised directly across a reuse cycle (2 sane
pairs, distinct iter context, no cross-pairing) and across a
lock→delete→re-lock→unlock cycle (exactly 1 pair, measuring the fresh lock's
~50ms rather than the abandoned lock's ~300ms — proving the stale mark did
NOT leak through) and a lock→delete(clear)→unlock-with-no-relock cycle
(silent no-op, matching Node's markUnlock-without-markLockStart no-op).

RED (against pre-fix code): 4 failures — `RLP_LIFECYCLE_METRICS=true`
incorrectly disabled telemetry; 0 of 6 gates used the unified form (`grep`
structural check); the no-relock case emitted 1 bogus record instead of 0;
0 of 4 expected `_lifecycle_clear_lock_mark` call sites existed. (2 of the 6
new cases — the basic reuse-pair case and the delete→re-lock→unlock case —
already passed pre-fix, since Node's overwrite-on-relock safety net already
covered those; kept as regression guards.)

GREEN: `zsh tests/test_b3_lifecycle_emit.sh` → 33/33 PASS. `npm run
test:zsh` → exit 0, zero FAIL markers. `npm run test:node` → 450/450 (Node
side untouched this round, no regression). `npm run sv-gate:fast` → 95/95
(92 + 3 new checks for the unified gate form and the 4 clear-mark call
sites). A5 oracle (`git diff b3d27da..HEAD` on the 3 protected files) empty.

Commit: `fix(b4): unify flag semantics + verdict lock-pair hygiene (codex round 1)`.

### Codex round 2 — atomic verdict replacement sites (same P2-2 class)

Codex confirmed round 1's 4 rm-site fixes and the loop-top analysis were
correct, and found ONE remaining P2 of the same class: `atomic_write
"$VERDICT_FILE"` replaces the file via tmp+`mv` without clearing/refreshing
the pending lock mark, at 3 sites round 1 missed (rm and atomic_write are
different call shapes, so the round-1 grep for `rm -f.*VERDICT_FILE` didn't
catch these).

**Full enumeration of every VERDICT_FILE/SIGNAL_FILE write-or-delete site**,
so round 3 doesn't find a third batch:

| # | Site | Kind | Mark handling |
|---|---|---|---|
| 1 | `run_single_verifier` top (~2907) | `rm -f VERDICT_FILE` | clear (round 1) |
| 2 | `_final_verify_one_us` top (~3077) | `rm -f VERDICT_FILE` | clear (round 1) |
| 3 | `_final_verify_one_us` D-4 retry (~3113) | `rm -f VERDICT_FILE` | clear (round 1) |
| 4 | main consensus loop pre-dispatch (~4189) | `rm -f VERDICT_FILE` | clear (round 1) |
| 5 | loop-top cleanup (~3828) | `rm -f SIGNAL_FILE DONE_CLAIM_FILE VERDICT_FILE` | already safe — immediately preceded by `_unlock_sentinel` + `_lifecycle_mark_unlock` in the same block (normal pairing clears it) |
| 6 | `run_consensus_verification` pass-merge (~3367) | `atomic_write VERDICT_FILE` | **clear (round 2, new)** |
| 7 | `run_consensus_verification` fail-merge (~3426) | `atomic_write VERDICT_FILE` | **clear (round 2, new)** |
| 8 | main loop sequential-final-verify-failure synthesis (~4122) | `atomic_write VERDICT_FILE` | **clear (round 2, new)** |
| 9 | `_migrate_legacy_verdict` (lib:1852) | `mv -f LEGACY_VERDICT_FILE VERDICT_FILE` | **checked, no fix needed** — see below |
| 10 | `run_single_verifier` (~3015), `_final_verify_one_us` (~3205) | `cp VERDICT_FILE → verdict_dest` | not a write TO VERDICT_FILE (reads it, writes a *different* per-engine archive path) — no mark interaction |
| 11 | `_final_verify_one_us` (~3051) | `atomic_write SIGNAL_FILE` | checked — SIGNAL_FILE's only lock/unlock pair is the worker-success site + loop-top; this scoped-signal write happens during the VERIFY phase, after SIGNAL_FILE was already unlocked+re-locked-N/A for this iteration's worker pass, and before the next loop-top unlock — same "no lock is currently pending across a legitimate content change" shape as `_migrate_legacy_verdict`, confirmed no dangling-mark path |
| 12 | leader D-16 finalize signal (~3809) | `atomic_write SIGNAL_FILE` | writes BEFORE the normal worker-poll-success lock cycle even starts (SKIP_NEXT_WORKER path) — the subsequent `poll_for_signal` + lock at the worker-success branch is the FIRST lock this iteration, nothing pending to clear |

Row 9 (`_migrate_legacy_verdict`) reasoning in full: its `mv -f` only ever
fires from `_verifier_pane_has_verdict()` (called by `check_no_progress`,
itself called from *inside* `poll_for_signal`'s own polling loop for
`$VERDICT_FILE`) or from `run_single_verifier`'s codex branch guarded by
`[[ -f "$VERDICT_FILE" ]] || _migrate_legacy_verdict` (only fires when
canonical is ALREADY absent). Both call sites are strictly *between* that
poll cycle's clear-before-dispatch (round 1 fix, already run before the
verifier was even launched) and that SAME cycle's eventual accept+lock — so
no pending mark can exist at the moment this mv fires. Documented inline at
the function definition (run_ralph_desk.zsh:1845-1851) and pinned by the
"got 7" (not 10) structural test — deliberately NOT wired with a clear call,
since there is nothing to clear.

**Chosen semantics for the 3 new atomic_write sites: clear, not refresh** —
checked against what happens immediately after each write:
- Sites 6/7 (`run_consensus_verification`): after either merge write, the
  function just `return`s; the caller (main loop, ~4106) falls through to a
  SHARED verdict-reading block (`jq -r '.verdict' "$VERDICT_FILE"`, ~4271)
  that does NOT call `_lock_sentinel` again. `atomic_write`'s tmp+`mv` also
  does not preserve the replaced file's chmod bits (confirmed by reading
  `atomic_write`'s implementation, lib:302-320 — `cat > tmp; mv tmp target`),
  so the merged file is factually UNLOCKED on disk after this write. A clear
  (not refresh) correctly reflects that: the eventual loop-top
  `_lifecycle_mark_unlock` finds no mark and silently no-ops (matches Node's
  markUnlock-without-markLockStart no-op) — no false metric, which is honest
  since this merged verdict was never locked via `_lock_sentinel` in the
  first place.
- Site 8 (sequential-final-verify-failure synthesis): the write is
  immediately followed by falling through to the SAME consensus/single-engine
  dispatch every other verify path goes through (~4132 `_should_use_consensus`
  check) — which either re-enters `run_consensus_verification` (sites 6/7,
  its own clear+write) or the single-engine inline path (round-1-fixed
  rm+clear+relock at ~4189). Either branch naturally re-establishes its own
  fresh mark on success, so clearing here (rather than refreshing) is correct
  and consistent with sites 6/7 — it never depends on which branch runs next.

TDD: RED confirmed against pre-fix code — 2 new structural cases failed (7
non-loop-top clear-mark sites, expected got 4; 3 atomic_write sites
immediately preceded by clear-mark, expected got 0). The behavioral case
(lock→clear→real `atomic_write()`→re-lock→unlock, exercising the actual
`atomic_write` helper from lib_ralph_desk.zsh, not just the isolated
lock-mark helpers) already passed pre-fix since it doesn't depend on the
production call-site wiring — kept as a regression guard. One structural
test needed a follow-up fix mid-round: the initial "immediately preceded"
check used a 3-line lookback window, which missed 2 of the 3 sites because
the clear call sits above a multi-line `{ echo ...} | atomic_write` JSON
block (14 lines for the pass-merge site); widened to 15 lines (still
site-local — the 3 sites are 59+ lines apart, so no cross-site
false-positive risk).

GREEN: `zsh tests/test_b3_lifecycle_emit.sh` → 36/36 PASS. `npm run
test:zsh` → exit 0, zero FAIL markers. `npm run test:node` → 450/450 (Node
side untouched this round). `npm run sv-gate:fast` → 96/96 (95 + 1 new net
check — replaced the round-1 "4 sites" check with a "7 sites" check and
added a "3 atomic_write sites exist" pin). A5 oracle (`git diff
b3d27da..HEAD` on the 3 protected files) empty.

Commit: `fix(b4): clear lock marks on atomic verdict replacement (codex round 2)`.
