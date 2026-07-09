# Model Upgrade Table

Progressive Worker model upgrade on consecutive failure per US.
CB default: 6. Override: `--cb-threshold N`. Worker only — Verifier fixed at campaign start.

**US-001 (single-source ladder):** the tables below are a reference view of
the single shipped ladder file, `src/node/models.json`
(`{"upgrades": {"<model>": "<next-or-empty>"}}`, empty string = ceiling). Both
the zsh runner (`get_next_model()` in `lib_ralph_desk.zsh`) and the Node
runner (`loadModelLadder()` in `src/node/model-ladder.mjs`) read that same
file at runtime instead of hardcoding the ladder independently — this
document no longer drives behavior, it documents it.

To override the shipped ladder (e.g. to reorder an existing model family or
change a cadence), write a same-shaped JSON file to
`${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json}` (a path outside
the postinstall-managed, write-protected tree). Precedence is override →
shipped defaults → a 3-entry emergency inline ladder (haiku→sonnet→opus) used
only if both files are missing or malformed.

**Scope note:** this externalizes the upgrade *ladder* only. Model
*recognition* (engine detection — e.g. the `haiku|sonnet|opus` / codex
`spark` alias matching in `lib_ralph_desk.zsh`) remains code. Adding a
brand-new model family may still require a code change; the ladder file
removes the point-release pressure for reordering or extending
already-recognized families, not for recognizing novel ones.

## Rules
- Each row = 2-attempt window (same model for 2 consecutive fails)
- Ceiling reached → repeat same model until CB
- CB < table columns → BLOCKED at that column
- CB > 6 → repeat ceiling model beyond column 6

## GPT Pro (gpt-5.3-codex-spark — separate token limit)

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | gpt-5.3-codex-spark:low | gpt-5.3-codex-spark:medium | gpt-5.3-codex-spark:high | BLOCKED |
| MEDIUM | gpt-5.3-codex-spark:medium | gpt-5.3-codex-spark:high | gpt-5.3-codex-spark:xhigh | BLOCKED |
| HIGH | gpt-5.3-codex-spark:high | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | BLOCKED |
| CRITICAL | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | BLOCKED |

## Non-Pro (gpt-5.5)

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | gpt-5.5:low | gpt-5.5:medium | gpt-5.5:high | BLOCKED |
| MEDIUM | gpt-5.5:medium | gpt-5.5:high | gpt-5.5:xhigh | BLOCKED |
| HIGH | gpt-5.5:high | gpt-5.5:xhigh | gpt-5.5:xhigh | BLOCKED |
| CRITICAL | gpt-5.5:xhigh | gpt-5.5:xhigh | gpt-5.5:xhigh | BLOCKED |

## Claude-only

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | haiku | sonnet | opus | BLOCKED |
| MEDIUM | sonnet | opus | opus | BLOCKED |
| HIGH | sonnet | opus | opus | BLOCKED |
| CRITICAL | opus | opus | opus | BLOCKED |

## Complexity Evaluation (brainstorm determines this)

| Factor | LOW | MEDIUM | HIGH | CRITICAL |
|--------|-----|--------|------|----------|
| US count | 1-2 | 3-5 | 6-10 | 10+ |
| File scope | single | 2-5 | 6+ | cross-repo |
| Logic | simple CRUD | conditionals | algorithms | security/crypto |
| Dependencies | none | 1-2 | 3+ API/DB | distributed |
| Code impact | new only | modify existing | refactor | architecture change |

Overall complexity = highest factor level.
Campaign starting model = lowest US risk level (progressive upgrade handles harder US).
