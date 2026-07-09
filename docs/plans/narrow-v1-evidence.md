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
