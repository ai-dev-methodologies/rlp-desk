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

### Codex round 3 — closes the class structurally (hook in atomic_write)

Codex found a THIRD batch of the same P2-2 class: `SIGNAL_FILE` replaced at
the `_final_verify_one_us` scoping write (round 2's evidence doc reached
this line but only reasoned about `VERDICT_FILE`) while a pending mark from
the worker-success lock could still be outstanding; the round-1/2
enumeration missed the `$signal_file`-alias writes and `_stamp_ack_field`
entirely; and the round-2 D-16 rationale ("safe because nothing was
pending") was factually wrong — it is safe, but for a different, more
fragile reason (see below). Three rounds of "found another site" is a
signal that per-site enumeration doesn't converge — it's fixing symptoms of
a design gap, not the gap itself.

**Design change**: moved the clear into the write primitive.
`atomic_write()` (lib_ralph_desk.zsh) now calls
`_lifecycle_clear_lock_mark "${target:t}"` after every SUCCESSFUL replace
(placed after the `mv`, not before the write — see rationale below). This
makes "does this write leave a stale mark behind" true **by construction**
for every current and future caller, instead of depending on someone
remembering to audit each new call site against the metrics map.

**Placement rationale (deviates from the literal "top of atomic_write"
suggestion, with justification)**: the clear fires only on the SUCCESS path,
after the `mv` — not unconditionally at the top of the function. On the F-26
failure paths (`cat > tmp` fails, or `mv` fails), the target file is left
untouched per `atomic_write`'s existing contract, so any pending lock-mark
for that basename is STILL VALID (nothing was actually replaced) — clearing
it there would incorrectly discard a still-accurate mark. Clearing
if-and-only-if the target was actually replaced is the strictly correct
invariant.

**Classification by MECHANISM** (the round-1/2 enumeration was a hand-audited
site list; codex's finding is that hand-audited lists don't scale — this
replaces it with a mechanism-level classification that is exhaustive by
construction):

| Mechanism | Sites | Safety |
|---|---|---|
| `atomic_write()`-mediated replacement | All `atomic_write "$VERDICT_FILE"` (3), `atomic_write "$SIGNAL_FILE"`/`"$signal_file"` (3: `_final_verify_one_us` scoping write, D-16 finalize, A4 fallback in `poll_for_signal`), plus `handle_worker_exit_codex`'s synthesis (newly converted, see below) | Safe via the hook, unconditionally, for every current and future caller |
| `rm -f` deletion | 4 sites (`run_single_verifier` top, `_final_verify_one_us` top + D-4 retry, main consensus loop pre-dispatch) | Safe via explicit `_lifecycle_clear_lock_mark` calls (round 1) — `rm` does not go through `atomic_write`, so it still needs its own clear |
| Loop-top `rm -f` (SIGNAL_FILE + DONE_CLAIM_FILE + VERDICT_FILE) | 1 site | Safe via the normal `_unlock_sentinel` + `_lifecycle_mark_unlock` pairing that immediately precedes it in the same block |
| `mv -f` outside `atomic_write` | `_migrate_legacy_verdict` (lib:1852) | Safe — checked: only ever fires strictly between a poll cycle's clear-before-dispatch and that SAME cycle's eventual accept+lock; no pending mark can exist at that point |
| In-place `jq`+`mv` outside `atomic_write` | `_stamp_ack_field` (lib:827, all 4 call sites: 2× `run_single_verifier`/`_final_verify_one_us`/main-loop VERDICT_FILE, 1× worker-success SIGNAL_FILE) | Safe — checked: every call site fires IMMEDIATELY after that same code path's own fresh `_lifecycle_mark_lock_start` + `_lock_sentinel` on the SAME file; it annotates the just-locked instance, never replaces a different one, and never touches `LIFECYCLE_LOCK_TIMES` itself |
| Raw `>` redirect outside `atomic_write` | `handle_worker_exit_codex`'s signal synthesis (was line 987) | **Was the one real gap** — converted to `atomic_write` (below) rather than given a parallel explicit-clear special case, so it gets both hook coverage and the existing F-26 truncated-write protection atomic_write already provides everything else |
| `cp` (archival) | `run_single_verifier` → `verdict_dest`, `_final_verify_one_us` → `final-verdict-*.json` | Not a write TO VERDICT_FILE — reads it, writes a *different* per-engine archive path. No mark interaction. |
| Worker-pane writes (iter-signal.json, done-claim.json written BY the worker process, not the leader) | N/A | Leader-side lock marks track the LEADER's own lock/unlock bookkeeping; worker-written content is read via `poll_for_signal`, not written by leader code that could hold a stale mark |

**The corrected D-16 rationale**: round 2's evidence doc claimed the D-16
finalize `atomic_write "$SIGNAL_FILE"` write (main loop, before the
worker-dispatch branch) was safe because "nothing was pending." That was
wrong. Full trace: the D-16 finalize block runs at loop-top and sets
`SKIP_NEXT_WORKER=1` BEFORE the `if (( ! SKIP_NEXT_WORKER ))` unlock block
below it — so that unlock block (which would normally clear the PREVIOUS
iteration's SIGNAL_FILE mark) is SKIPPED this pass. The previous iteration's
mark is therefore still pending when the D-16 write fires. It was safe only
because the very next event for that basename is the worker-success branch
a few lines later, which unconditionally re-locks (Map.set overwrite) before
any unlock could pair with the stale mark — a coincidence of code ordering,
not an absence of risk. The hook now makes this true regardless of that
ordering. Comment corrected in place at the D-16 site.

**`handle_worker_exit_codex` conversion** (run_ralph_desk.zsh, was line 987):
this was the ONE monitored-file write in the entire codebase using a raw `>`
redirect instead of `atomic_write` — found by grepping every
`> "$SIGNAL_FILE"` / `> "$VERDICT_FILE"` / `> "$signal_file"` /
`> "$verdict_file"` pattern (excluding `>>` append and the `atomic_write`
pipe form) across `run_ralph_desk.zsh`. Converted to
`| atomic_write "$signal_file"`: gets the clear-mark hook automatically, and
as a side benefit gets the same F-26 truncated-write protection every other
sentinel write already had (a raw `>` redirect can leave a half-written file
on a crash mid-write; `atomic_write`'s tmp+mv cannot). The function's return
contract is unchanged (it never checked the write's exit code before, and
still doesn't — this is a pure write-mechanism swap, not a behavior change).

**Simplification**: the 3 round-2 per-site `_lifecycle_clear_lock_mark`
calls immediately before `atomic_write "$VERDICT_FILE"` (pass-merge,
fail-merge, sequential-final-verify-failure synthesis) are now REMOVED —
redundant with the hook. The 4 round-1 rm-site calls STAY, since `rm` does
not go through `atomic_write`.

TDD: wrote the round-3 test cases FIRST, then verified genuine RED by
running them against the round-2 committed source (`git show
df0e674:src/scripts/{lib,run}_ralph_desk.zsh` copied into a throwaway
scratch tree) before touching the working tree — 4 failures: "atomic_write()
is missing the clear-mark hook" (structural), "expected 4
_lifecycle_clear_lock_mark call sites, got 7" (structural — the old code
still had all 7 per-site calls), "found 1 raw > redirect(s) onto monitored
files" (structural — line 987 not yet converted), and, most directly, "P3:
lock→atomic_write-replace→unlock (no relock) emits NOTHING" — this one
actually got 1 record against the round-2 code, proving the exact bug: a
lock left dangling across a plain atomic_write replace with no manual clear
DOES leak through and get falsely paired. Two of the new cases (the
write-then-lock invariant, and the lock→replace→re-lock→unlock cycle)
already passed against the round-2 code too — expected, since neither one
depends on the hook specifically (the first has nothing pending to clear;
the second is protected by the pre-existing overwrite-on-relock safety net)
— kept as regression guards distinguishing "hook required" from "hook
redundant but harmless" cases.

GREEN: `zsh tests/test_b3_lifecycle_emit.sh` → 39/39 PASS (35 pre-round-3 +
2 updated structural checks + 3 new behavioral/structural checks, net +4 new
cases replacing 2 obsolete ones). `npm run test:zsh` → exit 0, zero FAIL
markers. `npm run test:node` → 450/450 (Node side untouched — the class was
zsh-only, since Node's `LifecycleMetricsCollector.markLockStart` is a bare
`Map.set()` with no equivalent replace-without-relock code path in
`campaign-main-loop.mjs`). `npm run sv-gate:fast` → 98/98 (96 + 2 net:
replaced 2 round-1/2 checks with 4 round-3 checks, minus the 2 obsolete
ones removed). A5 oracle (`git diff b3d27da..HEAD` on the 3 protected files)
empty.

Commit: `fix(b4): clear lifecycle lock marks in atomic_write — closes the stale-mark class (codex round 3)`.

## sol-max P2 sweep — 9 findings on the v0.22.0 lifecycle-metrics work (2026-07-10)

A gpt-5.6-sol max-effort adversarial review (executable probes, not
inference-only) of the v0.22.0 full-wire lifecycle-metrics work (the 4
commits landing between `f0d3b3b` and `6cf3baa` above) surfaced 9 P2
findings, all fixed on branch `fix/b4-p2-sweep`. TDD throughout: a RED
commit (new/updated assertions failing against the pre-fix code) followed by
a GREEN commit (the fix, all assertions passing), with related findings
grouped into one commit pair where they touched the same lines.

### F1 — `pane_reap_latency_ms` "wrong window" (resolved as a DOC fix)

The finding: `_kill_pane_process` (lib_ralph_desk.zsh) records the same
`$_b4_delta` for both `pane_eof_to_cleanup_ms` and `pane_reap_latency_ms`,
where the advertised contract implied `pane_reap_latency_ms` measures a
distinct "sentinel-observed to shell-idle" window.

Node evidence checked before deciding direction: `reapProducer` in
`src/node/runner/campaign-main-loop.mjs:1455-1482` computes ONE `reapMs =
Date.now() - reapStart` (kill-start to `killPaneProcess` resolve) and calls
`lifecycleMetrics.record()` with that SAME value under BOTH metric names —
`pane_reap_latency_ms` only additionally carries `sentinel_type` context
when the reap followed a sentinel observation. Node's own implementation
never measured a "sentinel-observed to shell-idle" window either. The zsh
side was therefore already CORRECT and already mirrored Node exactly — the
bug was in the ADVERTISED contract text, not the code.

Fix direction: doc-only. Corrected README.md's metrics table and
lifecycle-metrics.mjs's header comment (both previously described
`pane_reap_latency_ms` as a distinct window); added an in-code note at the
zsh `_kill_pane_process` site; added a regression-lock assertion (case 15 in
`tests/test_b3_lifecycle_emit.sh`) that fails if the two metrics' `value_ms`
ever diverge, protecting the "same window by design" contract going forward.

Commit: `0bd9e1a` (docs+test, combined with F8's two vacuous-test fixes
below since all three touch the same test cases).

### F8 — vacuous lifecycle-emit assertions (test-only, no production bug)

Cases 11 and 17 in `tests/test_b3_lifecycle_emit.sh` asserted `!= null` as
proof that telemetry was emitted — an empty `{}` (flag on, zero records,
e.g. a silently broken accumulator) also satisfies `!= null`, so a real
regression in record accumulation would not have been caught. Tightened
both to require the `pane_eof_to_cleanup_ms` key present with `>= 1` record.
The third F8 target (the "fake-pane" test, case 15) is the same case F1's
regression lock landed in above — assertion form was "if F1 resolves to
doc-fix, assert the corrected contract," which is what case 15 now does.

Commit: `0bd9e1a` (same as F1).

### F2 — default-on instrumentation widened the post-sentinel race

Two sub-findings, fixed together since they touch `log_lifecycle_metric`'s
body and its 4 call sites:

**(a) Fork elimination in `log_lifecycle_metric`.** Record assembly forked
`date -u` (timestamp) and `jq -nc` (JSON build) per call, plus spawned a
background debug-log subshell unconditionally (even when `DEBUG=0`, the
production default). Replaced `date -u` with the zsh/datetime `strftime`
builtin — this build's `strftime` has no `-u` flag (confirmed empirically:
`zsh:strftime:1: bad option: -u` on zsh 5.9/arm64-darwin), so `TZ=UTC
strftime -s _ts ...` is used instead: a builtin env-prefix does not fork,
and `-s` writes directly into a variable, avoiding a `$(...)` capture fork
too. Replaced `jq -nc` with hand-built JSON, gated by field-charset checks
(`=~`, not `##` zsh-glob repetition — see the correctness note below) since
`value_ms` is already digit-validated, `metric` is a hardcoded call-site
literal, and `iter`/`us_id`/`sentinel_type` are leader-generated identifiers
(an integer, `"US-###"`, or a fixed sentinel-tag/file-basename vocabulary
like `"iter-signal"` or `"verdict.json"`) — never raw user/LLM text. The
debug-log subshell fork is now gated on `(( DEBUG ))` itself, not left to
`log_debug`'s own internal check.

Correctness note found during development: the first implementation used
`[[ "$metric" == [a-zA-Z0-9_]## ]]` (zsh's `##` "one or more" glob
repetition), which silently requires `setopt extendedglob` — NOT enabled
in this file. Every such check matched literal characters `##` instead of
repeating, so `[[ "$metric" == [a-zA-Z0-9_]## ]]` on `"pane_eof_to_cleanup_ms"`
returned false, and every record was silently dropped. Caught by running the
full test suite after the first implementation pass (22 of 45 assertions
FAILed with 0-record counts across previously-passing cases). Switched to
`=~` POSIX-ERE matching (`^[a-zA-Z0-9_]+$`), which is available in zsh's
`[[ ]]` without any `setopt`, and re-verified.

**(b) Capture-before-reap / emit-after-reap split at the 4 call sites.**
`_lifecycle_emit_write_to_read` (worker iter-signal path,
`run_single_verifier`, `_final_verify_one_us`, the inline single-engine
verify path) ran its full stat+timestamp+fork chain BEFORE
`_kill_pane_process`, delaying the moment the leader actually stops the
claude/codex TUI from self-reviewing — widening exactly the post-sentinel
race window B4 exists to close. Split into
`_lifecycle_capture_write_to_read` (cheap: one unavoidable `stat` fork via
`_file_mtime` + a fork-free `$EPOCHREALTIME` diff via `_epoch_ms`) called
BEFORE the reap, and `_lifecycle_emit_write_to_read` (the fork-bearing
`log_lifecycle_metric` call, now itself fork-free per (a)) called AFTER it,
at all 4 sites.

RED: `36c0131` (capture/reap/emit ordering + delta-freezing tests),
`b5b8ae5` (fork-free + DEBUG-gated structural tests, combined with F7's RED
below since both touch `log_lifecycle_metric`). GREEN: `dc7232c` (F2 fork
elimination + F7, combined — see F7) landed the `log_lifecycle_metric`
rewrite; the capture/emit split and 4 call-site rewiring landed in the same
commit.

### F7 — negative/malformed `value_ms` clamped to 0 → false B3 pass

`log_lifecycle_metric` clamped a negative or non-numeric `value_ms` to `0`
and kept the record — this let a corrupted measurement (EPOCHREALTIME
mis-scale near a second rollover, comma-decimal `LC_NUMERIC` corruption,
clock skew) silently satisfy B3-S2's `<= band` regression check as a FALSE
PASS. Fixed to DROP the record entirely (one DEBUG-gated warning logged)
instead of clamping, while keeping a genuine `0` (real sub-ms measurement):
`[[ "$value_ms" == <-> ]]` (zsh's always-available numeric-range glob, no
`extendedglob` needed) matches a plain non-negative digit sequence, so `"0"`
passes and `"-50"`/`"abc"`/`""` do not. This is a DELIBERATE divergence from
Node's `LifecycleMetricsCollector.record()`, which still clamps-and-keeps
(`Math.max(0, Math.round(valueMs))`) — documented directly in the
cross-leader parity test (case 10) so a future edit does not "fix" this back
to Node parity by mistake.

RED: `b5b8ae5`. GREEN: `dc7232c` (combined with F2's `log_lifecycle_metric`
rewrite, same lines).

### F3 — lock metrics emitted when no lock/unlock occurred

`_lock_sentinel`/`_unlock_sentinel` always returned 0 regardless of whether
`chmod` actually succeeded, via an explicit `chmod ... || true; return 0`.
A caller marking a `sentinel_lock_to_unlock_ms` lock-start before calling
`_lock_sentinel` had no way to detect a genuine `chmod` failure (permission
denied, FS error, ENOENT race) — the pending mark still got paired with a
later unlock as if the lock had really happened.

Checked existing callers before changing the return contract (per the
finding's explicit instruction): two existing tests —
`test_b2fix_sentinel_lock.sh` AC-B3 and `test-bug7-post-sentinel-race.sh`
Scenario B — pin "`_lock_sentinel` on a MISSING file returns 0 (fail-open,
idempotent)" as a named, intentional acceptance criterion. Preserved that
half exactly (missing file still returns 0); only a `chmod` that genuinely
FAILS on an EXISTING file now propagates as non-zero — a case those two
tests never exercised either way (both only cover the missing-file and
success/FS-ignores-chmod cases). No production caller relied on the
old always-0 contract for control flow (grepped every call site — all bare
statements, and this repo runs `set -uo pipefail`, explicitly NOT `-e`, so
no accidental early-exit risk either). Guarded the 4 VERDICT_FILE/SIGNAL_FILE
lock call sites (clear the just-set mark on lock failure) and both loop-top
unlock sites (mark_unlock only fires when the unlock succeeded); the 3
DONE_CLAIM_FILE-only lock sites (no adjacent mark — H2 exclusion) got an
explicit `|| true` per the finding's guidance.

Two pre-existing structural tests needed updating for the new line offsets
introduced by the guard blocks: `test_b2fix_sentinel_lock.sh`'s "Site 3"
window (10→20 lines, since the SIGNAL_FILE lock guard added lines between
the reap marker and the DONE_CLAIM_FILE lock) and the VERDICT_FILE
clear-mark-count pin in both `sv-gate-fast.sh` and
`test_b3_lifecycle_emit.sh` (4→7, since the 3 new F3 lock-failure guards
add 3 more `_lifecycle_clear_lock_mark "${VERDICT_FILE:t}"` sites alongside
the 4 existing F4 rm-site clears).

RED: `2805347`. GREEN: `a8772be`.

### F4 — rm sites clear marks before confirming deletion

The 4 rm-site lock-mark clears (`run_single_verifier`,
`_final_verify_one_us` top + retry, the inline single-engine verify path)
cleared the pending mark BEFORE confirming `rm -f "$VERDICT_FILE"` actually
succeeded — if `rm` failed (read-only directory, permission error), the
mark was dropped anyway even though the stale verdict file it was
protecting against was still on disk. Reordered all 4 to `rm -f ... &&
_lifecycle_clear_lock_mark ...`; `rm -f` on an already-absent file still
returns 0, so the common case is unaffected. The 5th VERDICT_FILE `rm`
(loop-top cleanup, combined with SIGNAL_FILE/DONE_CLAIM_FILE) is
untouched — already safe via its own unlock+mark_unlock pairing just above
it.

RED simulated a real `rm` failure via a `chmod 0555` read-only directory
(portable, no root needed) — confirmed `rm -f` genuinely fails (rc=1) in
that setup before writing the test.

RED: `c178352` (combined with F9's "failing rm keeps the mark" behavioral
case, per the finding's explicit pairing instruction). GREEN: `95ba8f4`.

### F5 — lock samples attributed to iter N+1, terminal samples lost

Two sub-findings:

**(a) Iter misattribution.** `_lifecycle_mark_lock_start` did not record
which iteration a lock started in; `_lifecycle_mark_unlock` tagged the
emitted record with whatever AMBIENT `$ITERATION` the caller happened to
pass at unlock time. Since the main loop is `for (( ITERATION = 1; ITERATION
<= MAX_ITER; ITERATION++ ))` (a zsh C-style `for`, which increments at the
END of each body — confirmed empirically, not assumed), a lock started
during iteration N's worker-success branch and unlocked at iteration N+1's
loop-top cleanup (normal flow) got its record wrongly tagged `iter=N+1`.
Fixed by adding a parallel `LIFECYCLE_LOCK_ITERS` map: `_lifecycle_mark_lock_start`
now stores the current iter at mark-time, and `_lifecycle_mark_unlock`
prefers that STORED iter, falling back to the ambient one only when nothing
was stamped (preserves the existing 1-arg test harness calls in cases
19-27, which pass the iter directly to `_lifecycle_mark_unlock` and expect
it verbatim).

**(b) Terminal samples lost.** A COMPLETE exit (leader-finalize
sequential-verify pass, full/ALL verify pass) `return`s straight out of the
campaign loop, skipping the loop-top unlock block that normally closes out
the last iteration's lock — there is no "next iteration" for it to run in —
silently dropping that sample from campaign.jsonl. Added
`_lifecycle_flush_pending_locks`: emits every still-pending lock/unlock pair
(each with its own stored iter) and is a no-op when nothing is pending.
Wired immediately before both COMPLETE-exit `write_campaign_jsonl` calls.
Scoped narrowly to the two COMPLETE (success) exits per the finding's
explicit wording ("Terminal paths ... and any COMPLETE exit") — not
generalized to every `return` in the campaign loop, which would have been a
broader behavior change than requested.

Debugging note: the first `_lifecycle_flush_pending_locks` implementation
used `for k in "${(k)LIFECYCLE_LOCK_TIMES}"` (no `[@]`), which zsh collapses
into ONE space-joined scalar when quoted for an associative array — the
loop ran once over `"b.json a.json"` as a single non-existent key instead of
twice. Fixed to `"${(k)LIFECYCLE_LOCK_TIMES[@]}"`; confirmed via a minimal
repro before touching the real fix.

RED: `6ed529a`. GREEN: `16083f7`.

### F6 — campaign.jsonl append failure masked

`write_campaign_jsonl` piped `jq -nc ...` straight into `>> "$CAMPAIGN_JSONL"`
with no error check on either the jq build or the append, and
unconditionally reset `LIFECYCLE_RECORDS` afterward regardless of outcome —
an append failure (disk full, permission error, missing parent directory)
silently dropped both the campaign.jsonl row and the pending lifecycle
metrics for that iteration, with no diagnostic and no retry. Fixed: the
complete line is now built into a variable first (jq's exit code AND
non-empty output are both checked), then appended in a single `print -r --`
write with its own rc check. On EITHER failure: `log_error` + `return 1`
WITHOUT resetting the accumulator, so pending records survive to be retried
on the next flush. Building the complete line before the single write also
avoids a partial-line write (jq streaming its own output directly into the
file could interleave a truncated line with a concurrent/subsequent write).
Success path is unchanged.

RED: `9f330fd`. GREEN: `1194d1b`.

### F9 — vacuous/failure-blind mutation tests

Two sub-findings:

**(a) Hook-placement check verified presence, not position.** Case 22 (the
structural check that `atomic_write()` contains the
`_lifecycle_clear_lock_mark` hook, from codex round 3 above) only checked
that the call appears SOMEWHERE inside `atomic_write()`'s body — a future
edit moving the clear call BEFORE the `mv` would reintroduce the exact
"cleared before confirming" bug class F4 fixed at the rm sites, but inside
`atomic_write()` itself, and this check would not catch it. Added a
line-position check (the clear call's line number inside the extracted
function body must exceed the `mv` line's).

**(b) Mutation-test harnesses (cases 25-27) were failure-blind.** The
reviewer proved that on a hardened/read-only host, a silent `mktemp`/
`atomic_write` setup failure inside these `zsh -c` scratch scripts would
leave `LIFECYCLE_RECORDS` at its expected count "by accident" (nothing got
marked/recorded on either success or failure path for these specific
assertions) — the test would print PASS without ever having exercised the
atomic_write-replace path it claims to prove. Added `set -e` to all 3
harnesses so a genuine setup failure aborts the script instead of letting
the assertion misread missing/empty output as a coincidental pass.

**(c) The required behavioral case** ("a failing rm (read-only dir) keeps
the mark, pairs with F4") was added as part of the F4 commit (case 38 in
`test_b3_lifecycle_emit.sh`) since it's the same finding pairing the task
explicitly called out — no duplicate added here.

Commit: `9d70231` (test-only — no production code change for F9; (c) landed
in F4's `c178352`/`95ba8f4` pair).

### Final gate results (full sweep, all 9 findings)

```
zsh -n src/scripts/run_ralph_desk.zsh   → clean
zsh -n src/scripts/lib_ralph_desk.zsh   → clean
zsh tests/test_b3_lifecycle_emit.sh     → 72/72 PASS (was 45/45 pre-sweep)
npm run test:zsh                        → exit 0, 0 FAIL/✗ across 1788 lines
npm run test:node                       → 450/450 PASS, 0 fail
npm run sv-gate:fast                    → 99/99 pass — OK
```

A5 oracle (v0.22.0 anchor `7038a14`, `git diff 7038a14..HEAD` on
`src/commands/rlp-desk.md`, `src/governance.md`,
`src/scripts/init_ralph_desk.zsh`): empty — none of the 3 protected trigger
files were touched by this sweep.

### Commit list (branch `fix/b4-p2-sweep`, oldest first)

```
0bd9e1a docs+test: correct pane_reap_latency_ms contract (F1) + tighten vacuous lifecycle assertions (F8)
b5b8ae5 test: RED — F7 drop negative/malformed value_ms, F2 fork-free log_lifecycle_metric
36c0131 test: RED — F2 capture-before-reap / emit-after-reap split at the 4 write_to_read call sites
dc7232c fix(b4): F7 drop negative/malformed value_ms + F2 fork-free metrics and capture-before-reap/emit-after-reap split
2805347 test: RED — F3 honest _lock_sentinel/_unlock_sentinel return codes + guarded lifecycle marks
a8772be fix(b4): F3 — _lock_sentinel/_unlock_sentinel return real success/failure, guard lifecycle marks on failure
c178352 test: RED — F4 rm-then-clear ordering + F9 failing-rm-keeps-mark
95ba8f4 fix(b4): F4 — clear lifecycle lock-mark only after a confirmed rm
6ed529a test: RED — F5 stamp lock-time iter + flush pending locks on COMPLETE exit
16083f7 fix(b4): F5 — stamp lock-time iter, flush pending locks before a COMPLETE exit
9f330fd test: RED — F6 campaign.jsonl append failure must not be masked
1194d1b fix(b4): F6 — campaign.jsonl append failure is no longer masked
9d70231 test: F9 — harden mutation-test harnesses (set -e) + positional hook-placement check
```
