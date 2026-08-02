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
`spark`/`sol`/`terra`/`luna` alias matching in `lib_ralph_desk.zsh`) remains code. Adding a
brand-new model family may still require a code change; the ladder file
removes the point-release pressure for reordering or extending
already-recognized families, not for recognizing novel ones.

## Rules
- Each row = 2-attempt window (same model for 2 consecutive fails)
- Ceiling reached → repeat same model until CB
- CB < table columns → BLOCKED at that column
- CB > 6 → repeat ceiling model beyond column 6

## Codex model catalog (codex-cli 0.144 / GPT-5.6 generation)

Source: the codex CLI's own model catalog (embedded catalog of codex-cli
0.144.1, cross-checked against `~/.codex/models_cache.json`).

| Model | Position | Reasoning efforts | Catalog default |
|-------|----------|-------------------|-----------------|
| gpt-5.6-sol | Frontier agentic coding (top) | low, medium, high, xhigh, max, ultra | low |
| gpt-5.6-terra | Balanced, everyday work | low, medium, high, xhigh, max, ultra | medium |
| gpt-5.6-luna | Fast and affordable (small) | low, medium, high, xhigh, max | medium |
| gpt-5.5 | Previous-gen frontier | low, medium, high, xhigh | medium |
| gpt-5.4 | Everyday coding (prev gen) | low, medium, high, xhigh | medium |
| gpt-5.4-mini | Small/cost-efficient (prev gen) | low, medium, high, xhigh | medium |
| gpt-5.3-codex-spark | Ultra-fast coding, 100k context | low, medium, high, xhigh | high |

- `max` and `ultra` are effort tiers introduced with the GPT-5.6 family;
  `gpt-5.6-luna` supports `max` but not `ultra`. **Policy 2026-08-03
  (luna-first — partial reversal of the 2026-07-20 xhigh-ceiling policy,
  justified by the 2026-07-30 price cut):** within luna the ladder raises
  effort to `max` before jumping models (`luna:high → luna:max`, skipping
  xhigh in the default chain; `luna:xhigh → luna:max` for manual starts).
  `luna:max` then hops to the quota-first `terra:max` lane, which escalates
  to `sol:xhigh` (terra:max quality sits between sol:high and sol:xhigh —
  sol:high would be lateral). Terra and sol keep the `:xhigh` ladder ceiling;
  `sol:max`/`sol:ultra`/`terra:ultra` remain valid manual starting points but
  are dead-end keys.
- CLI aliases: `sol` → gpt-5.6-sol, `terra` → gpt-5.6-terra, `luna` →
  gpt-5.6-luna (same convention as the existing `spark` alias).
- `gpt-5.5-pro` and `gpt-5.4-nano` appear in some OpenAI surfaces but are NOT
  in the codex CLI catalog — not usable as rlp-desk worker/verifier models.

## GPT-5.6 — Sol (frontier; `sol:xhigh` = final ceiling of the whole ladder)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9+ |
|------------|-----|-----|-----|-----|-----|
| LOW | gpt-5.6-sol:low | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | BLOCKED |
| MEDIUM | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-5.6-sol:xhigh | BLOCKED |
| HIGH | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-5.6-sol:xhigh | BLOCKED |
| CRITICAL | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-5.6-sol:xhigh | gpt-5.6-sol:xhigh | BLOCKED |

(`gpt-5.6-sol:xhigh` has no next step — ceiling reached → repeat until CB.
HIGH starts at `sol:medium` and CRITICAL at `sol:high`, never at the ceiling
itself, so the ladder retains upgrade headroom.)

## GPT-5.6 — Terra (xhigh → Sol:high jump; terra:max → sol:xhigh quota lane)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9-10 | 11+ |
|------------|-----|-----|-----|-----|------|-----|
| LOW | terra:low | terra:medium | terra:high | terra:xhigh | sol:high | BLOCKED |
| MEDIUM | terra:medium | terra:high | terra:xhigh | sol:high | sol:xhigh | BLOCKED |
| HIGH | terra:high | terra:xhigh | sol:high | sol:xhigh | sol:xhigh | BLOCKED |
| CRITICAL | terra:xhigh | sol:high | sol:xhigh | sol:xhigh | sol:xhigh | BLOCKED |

(Cells abbreviate `gpt-5.6-terra` / `gpt-5.6-sol`. After `terra:xhigh` the
ladder jumps to `gpt-5.6-sol:high` — model step-up enters at `:high`, never a
lower effort. Default CB of 6 reaches column 5-6.)

(`terra:max` is the quota-first lane hop reached from `luna:max`, or a manual
`--worker-model gpt-5.6-terra:max` start; on failure it escalates to
`gpt-5.6-sol:xhigh`.)

## GPT-5.6 — Luna (effort to max first, then terra:max quota lane)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9+ |
|------------|-----|-----|-----|-----|-----|
| LOW | luna:high | luna:max | terra:max | sol:xhigh | BLOCKED |
| MEDIUM | luna:xhigh | luna:max | terra:max | sol:xhigh | BLOCKED |
| HIGH | luna:max | terra:max | sol:xhigh | sol:xhigh | BLOCKED |
| CRITICAL | sol:high | sol:xhigh | sol:xhigh | sol:xhigh | BLOCKED |

(Cells abbreviate `gpt-5.6-luna` / `gpt-5.6-terra` / `gpt-5.6-sol`. Row =
brainstorm start per complexity (cost lane); columns = consecutive-failure
milestones. Full chain: `luna:high → luna:max → terra:max → sol:xhigh`
(ceiling); manual `luna:low/medium` starts climb `low → medium → high` first;
manual `luna:xhigh` joins at `luna:max`. CRITICAL rows start at `sol:high`
regardless of lane. Speed lane HIGH starts `sol:medium → sol:high →
sol:xhigh`.)

**Known accepted edge (spec §5).** The lane choice applies only to HIGH rows —
LOW and MEDIUM start on luna in *both* lanes. So a LOW/MEDIUM US that keeps
failing on a speed-lane campaign still walks the cost-lane chain and reaches
the quota-first `terra:max` hop, which is slower than sol: the operator picked
"speed" but a repeatedly-failing cheap US lands on the slow rung anyway. This
is accepted — escalation is evidence-gated, and by the time a LOW US has failed
this many times its complexity was misjudged. Two mitigations if the latency
matters: `--lock-worker-model` (pin the start model; the CB then owns the
terminal outcome instead of the ladder) or a manual `--worker-model
gpt-5.6-sol:medium` start for that campaign.

## GPT-5.4 / GPT-5.4-mini (low → medium → high → xhigh)

Same 4-tier shape as gpt-5.5 below; substitute `gpt-5.4` or `gpt-5.4-mini`.

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
