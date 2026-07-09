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
