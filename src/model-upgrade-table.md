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
shipped defaults → a 4-entry emergency inline ladder
(haiku→sonnet→opus→claude-fable-5-1:max) used only if both files are missing
or malformed.

**Scope note:** this externalizes the upgrade *ladder* only. Model
*recognition* (engine detection — e.g. the `haiku|sonnet|opus|fable` / codex
`spark`/`sol`/`terra`/`luna`/`astra` alias matching in `lib_ralph_desk.zsh`) remains code. Adding a
brand-new model family may still require a code change; the ladder file
removes the point-release pressure for reordering or extending
already-recognized families, not for recognizing novel ones. (The Fable 5.1
wave hit exactly this: `fable` needed a code change to be *recognized* as a
claude alias at all, even though the ladder value that reaches it —
`claude-fable-5-1:max` — is pure data.)

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
  sol:high would be lateral). Terra keeps its own `:xhigh` ladder ceiling
  before jumping model into sol; **sol's `:xhigh` is no longer a ceiling** —
  since the astra rewiring below, it escalates one tier further into
  `gpt-6-astra:high`, which is the real ceiling of the whole ladder now.
  `sol:max`/`sol:ultra`/`terra:ultra`/`gpt-6-astra:max`/`gpt-6-astra:ultra`
  remain valid manual starting points but are dead-end keys (no forward
  escalation).
- CLI aliases: `sol` → gpt-5.6-sol, `terra` → gpt-5.6-terra, `luna` →
  gpt-5.6-luna, `astra` → gpt-6-astra (same convention as the existing `spark`
  alias).
- `gpt-5.5-pro` and `gpt-5.4-nano` appear in some OpenAI surfaces but are NOT
  in the codex CLI catalog — not usable as rlp-desk worker/verifier models.
- `gpt-6-astra` (codex-cli 0.153.4+) is a newer frontier model not in this
  0.144.1-sourced table — see "GPT-6 — Astra" below for its (empirically
  confirmed) catalog details.

## GPT-6 — Astra (newest frontier)

| Model | Position | Reasoning efforts | Catalog default |
|-------|----------|-------------------|-----------------|
| gpt-6-astra | Frontier agentic coding (newest) | low, medium, high, xhigh, max (confirmed) | unknown (not in models_cache.json) |

**Verification (2026-09-07, codex-cli 0.153.4) — live probes, not a mirror.**
`~/.codex/models_cache.json` still doesn't list `gpt-6-astra` (stale relative
to 0.153.4), so instead of mirroring `gpt-5.6-sol`'s shape unverified, each
candidate reasoning level was probed for real with a one-token reply, in a
read-only sandbox:

```
codex exec -m gpt-6-astra -c model_reasoning_effort="<level>" --sandbox read-only "Reply with exactly: OK"
```

| Level | Outcome |
|-------|---------|
| minimal | **Rejected.** HTTP 400 `invalid_request_error`/`unsupported_value`: *"Unsupported value: 'minimal' is not supported with the 'gpt-6-astra' model. Supported values are: 'low', 'medium', 'high', 'xhigh', and 'max'."* — the server's own error enumerates the full supported set. |
| low | Accepted — real generation, replied `OK` (20,935 tokens incl. harness overhead). |
| medium | Accepted — real generation, replied `OK` (20,935 tokens). |
| high | Accepted — real generation, replied `OK` (27,975 tokens). |
| xhigh | Accepted — real generation, replied `OK` (20,935 tokens). |
| max | Accepted — real generation, replied `OK` (27,993 tokens). |
| ultra | **Inconclusive.** Accepted with no error — real generation, replied `OK` (20,982 tokens) — but the server's own `minimal`-rejection message explicitly enumerates the supported set as `low, medium, high, xhigh, max` and does **not** include `ultra`. The CLI's own catalog describes `ultra` as "maximum reasoning with automatic task delegation" (a client-side orchestration feature on other models, not a raw `reasoning.effort` API value), which would explain why it isn't rejected even though the server doesn't list it as a distinct supported value for this model — it may be silently reinterpreted (e.g. coerced to `max`) rather than genuinely honored as `ultra`. Treat "accepted" here as "does not error," not as "confirmed distinct reasoning level." |

**Conclusion:** `low`/`medium`/`high`/`xhigh`/`max` are authoritatively
confirmed (both by successful probe AND by the server's own explicit
enumeration). `minimal` is confirmed **unsupported** — never suggest it for
this model. `ultra` is left in the ladder below (it doesn't error, and codex
CLI's own vocabulary allows it as a manual-start key on other frontier
models), but its real distinctness from `max` on this specific model is
unconfirmed — flagged, not asserted as fact.

`gpt-6-astra` has its own `low → medium → high → xhigh` chain (ceiling at
`xhigh`; `max`/`ultra` are manual-start-only dead ends) — the same shape
`gpt-5.6-sol` uses, now backed by the measurements above rather than an
assumption. **Owner decision (applied):** `gpt-5.6-sol:xhigh` now escalates
into `gpt-6-astra:high` — astra is the real ceiling of the whole ladder.
Entry point is `gpt-6-astra:high`, not `gpt-6-astra:low`: this matches the
already-established "model step-up enters at `:high`, never a lower effort"
rule (the same rule that sends `terra:xhigh` into `sol:high`, one rung below
sol's own ceiling — see the GPT-5.6 — Terra section below). Since `astra`'s
own auto-ladder ceiling is `xhigh` (same relative position as sol's), the
`sol → astra` jump lands one rung below astra's ceiling too, consistent with
the terra → sol jump. `gpt-6-astra:xhigh` is the new terminal `""` — the full
ladder is now `sol:xhigh → astra:high → astra:xhigh → BLOCKED`. This changes
default escalation behavior and cost for any campaign whose worker reaches
`sol:xhigh` (previously the ceiling, now one tier from it) — see the updated
Sol/Terra/Luna tables below for the full per-complexity chains.

CLI alias: `astra` → `gpt-6-astra` (same convention as `sol`/`terra`/`luna`).

## Cost Model (`cost_factors` in `src/node/models.json`)

**Architectural finding, not previously documented:** `cost_factors` is
consumed ONLY for codex-engine rows in both leaders —
`_resolveCostFactor`/summarizeCost gates on `record.worker_engine === 'codex'`
(`src/node/reporting/campaign-reporting.mjs`) and `_cost_factor_x100` is only
called `if [[ "$row_worker_engine" == "codex" ]]` (`src/scripts/lib_ralph_desk.zsh`,
"Codex legs sol-equivalent" summary). Claude-engine rows are counted
(`claude_legs++` / a separate bucket) but **never priced** by this table
today — the "unknown family -> 1.0" fallback is real, but it currently only
ever fires for an unrecognized *codex* model, never for a claude one. A
claude `cost_factors` entry would be inert under the current code — useful
groundwork, not a live fix — until/unless a future change wires claude legs
into the same accounting.

**gpt-6-astra, gpt-5.5, gpt-5.4, spark:** no local evidence of real API
pricing for any of these codex models is available in this session (no
pricing skill/table for OpenAI/codex was loaded, unlike the Claude side —
see below). `cost_factors` is unchanged; all four keep the existing
unknown-family fallback of `1.0` (parity with `sol`, the current most
expensive family in the table) — the conservative, non-downgrading value a
guessed entry would also have to be. **Needs an owner number**: real
per-token pricing for `gpt-6-astra` relative to `gpt-5.6-sol`, if it differs
from 1.0.

**Claude family — real evidence available, not applied (see the
architectural finding above for why):** the `claude-api` skill's cached
first-party Anthropic pricing table (2026-06-24) gives Haiku 4.5 $1/$5,
Sonnet 5 $2/$10, Opus 5 $5/$25, and Fable 5.1 $10/$50 (input/output per
MTok) — a clean, consistent 1:2:5:10 ratio across all four models on BOTH
input and output pricing. Anchoring to the generation's top tier at `1.0`
(the same convention `sol` already uses on the codex side) gives:

| Model | Ratio to fable | Evidence |
|-------|----------------|----------|
| claude-fable-5-1 | 1.0 | $10/$50 per MTok (anchor) |
| opus | 0.5 | $5/$25 per MTok = exactly half of fable |
| sonnet | 0.2 | $2/$10 per MTok = exactly 1/5 of fable |
| haiku | 0.1 | $1/$5 per MTok = exactly 1/10 of fable |

This ratio is well-evidenced (first-party pricing, not a guess) but **was
NOT added to `cost_factors`**, because doing so would implicitly assert
`claude-fable-5-1` costs the same per token as `gpt-5.6-sol` (both at `1.0`
in the same flat table) — a cross-engine equivalence with no local evidence
either way, since no codex/OpenAI pricing was loaded this session to compare
against. **Needs an owner decision**: (a) is a cross-engine dollar
reconciliation between sol and fable available, so these four claude values
can be placed on the same 1.0-anchored scale as sol/terra/luna/astra, or (b)
should claude get its own independently-scaled `1.0` anchor with an explicit
note that summing it against codex factors is not a dollar-equivalent
comparison, or (c) should claude legs stay unpriced (status quo) until the
codex-only architectural gate is revisited on its own. The 1:2:5:10 ratio
above is ready to apply under whichever answer is chosen — it does not need
re-deriving.

## GPT-5.6 — Sol (frontier; `sol:xhigh` escalates one tier further into astra — see below, no longer the final ceiling)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9-10 | 11-12 | 13+ |
|------------|-----|-----|-----|-----|------|-------|-----|
| LOW | gpt-5.6-sol:low | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-6-astra:high | gpt-6-astra:xhigh | BLOCKED |
| MEDIUM | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-6-astra:high | gpt-6-astra:xhigh | gpt-6-astra:xhigh | BLOCKED |
| HIGH | gpt-5.6-sol:medium | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-6-astra:high | gpt-6-astra:xhigh | gpt-6-astra:xhigh | BLOCKED |
| CRITICAL | gpt-5.6-sol:high | gpt-5.6-sol:xhigh | gpt-6-astra:high | gpt-6-astra:xhigh | gpt-6-astra:xhigh | gpt-6-astra:xhigh | BLOCKED |

(`gpt-5.6-sol:xhigh` now escalates into `gpt-6-astra:high` — see "Owner
decision (applied)" above for why `:high` and not `:low`. `gpt-6-astra:xhigh`
has no next step — that is the real ceiling now; repeat until CB. HIGH starts
at `sol:medium` and CRITICAL at `sol:high`, never at the ceiling itself, so
the ladder retains upgrade headroom. Verified via a direct walk of the
shipped `src/node/models.json` ladder, not hand-derived — see
`tests/node/models-ladder.test.mjs` "gpt-5.6-sol:xhigh escalates into
gpt-6-astra".)

## GPT-5.6 — Terra (xhigh → Sol:high jump; terra:max → sol:xhigh quota lane; sol:xhigh continues into astra)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9-10 | 11-12 | 13-14 | 15-16 | 17+ |
|------------|-----|-----|-----|-----|------|-------|-------|-------|-----|
| LOW | terra:low | terra:medium | terra:high | terra:xhigh | sol:high | sol:xhigh | astra:high | astra:xhigh | BLOCKED |
| MEDIUM | terra:medium | terra:high | terra:xhigh | sol:high | sol:xhigh | astra:high | astra:xhigh | astra:xhigh | BLOCKED |
| HIGH | terra:high | terra:xhigh | sol:high | sol:xhigh | astra:high | astra:xhigh | astra:xhigh | astra:xhigh | BLOCKED |
| CRITICAL | terra:xhigh | sol:high | sol:xhigh | astra:high | astra:xhigh | astra:xhigh | astra:xhigh | astra:xhigh | BLOCKED |

(Cells abbreviate `gpt-5.6-terra` / `gpt-5.6-sol` / `gpt-6-astra`. After
`terra:xhigh` the ladder jumps to `gpt-5.6-sol:high` — model step-up enters
at `:high`, never a lower effort; the same rule applies to the `sol → astra`
jump. Default CB of 6 reaches column 5-6, well before any row reaches astra —
this table is illustrative of the full shape, not default behavior.)

(`terra:max` is the quota-first lane hop reached from `luna:max`, or a manual
`--worker-model gpt-5.6-terra:max` start; on failure it escalates to
`gpt-5.6-sol:xhigh`, which — as of the astra rewiring — continues into
`gpt-6-astra:high` on the next failure rather than staying at the ceiling.)

## GPT-5.6 — Luna (effort to max first, then terra:max quota lane; sol:xhigh continues into astra)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9-10 | 11-12 | 13+ |
|------------|-----|-----|-----|-----|------|-------|-----|
| LOW | luna:high | luna:max | terra:max | sol:xhigh | astra:high | astra:xhigh | BLOCKED |
| MEDIUM | luna:xhigh | luna:max | terra:max | sol:xhigh | astra:high | astra:xhigh | BLOCKED |
| HIGH | luna:max | terra:max | sol:xhigh | astra:high | astra:xhigh | astra:xhigh | BLOCKED |
| CRITICAL | sol:high | sol:xhigh | astra:high | astra:xhigh | astra:xhigh | astra:xhigh | BLOCKED |

(Cells abbreviate `gpt-5.6-luna` / `gpt-5.6-terra` / `gpt-5.6-sol` /
`gpt-6-astra`. Row = brainstorm start per complexity (cost lane); columns =
consecutive-failure milestones. Full chain: `luna:high → luna:max →
terra:max → sol:xhigh → astra:high → astra:xhigh` (ceiling); manual
`luna:low/medium` starts climb `low → medium → high` first; manual
`luna:xhigh` joins at `luna:max`. CRITICAL rows start at `sol:high` regardless
of lane. Speed lane HIGH starts `sol:medium → sol:high → sol:xhigh →
astra:high → astra:xhigh`.)

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

## Claude-only (Fable 5.1 wave: opus is no longer the ceiling — claude-fable-5-1:max is)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9+ |
|------------|-----|-----|-----|-----|-----|
| LOW | haiku | sonnet | opus | claude-fable-5-1:max | BLOCKED |
| MEDIUM | sonnet | opus | claude-fable-5-1:max | claude-fable-5-1:max | BLOCKED |
| HIGH | sonnet | opus | claude-fable-5-1:max | claude-fable-5-1:max | BLOCKED |
| CRITICAL | opus | claude-fable-5-1:max | claude-fable-5-1:max | claude-fable-5-1:max | BLOCKED |

(`opus` → `claude-fable-5-1:max` — a bug found and fixed in the Fable 5.1
wave: the claude ladder previously terminated at `opus`, one rung below the
model every "final verifier" / "top model" recommendation in this repo
already pointed to. `claude-fable-5-1` has no further upgrade — that is the
real claude ceiling now. Verified via a direct walk of the shipped
`src/node/models.json` ladder — see `tests/node/models-ladder.test.mjs`
"claude ladder reaches fable".)

**Bare `fable` alias (engine detection, not the ladder):** `claude --help`
documents `fable` as a short alias for the latest model, alongside
`opus`/`sonnet`. It was missing from the claude-engine-detection alias set in
all four implementations (`_auto_detect_engine`, `parse_model_flag`,
`CLAUDE_MODELS`, `isClaudeFamily`) until this wave — `--worker-model fable`
was silently misclassified as codex. Fixed in all four; see
`tests/node/us008-cli-entrypoint.test.mjs` "claude bare-alias set... agrees
across..." for the cross-implementation parity check. The ladder itself uses
the version-pinned `claude-fable-5-1` id (not the floating `fable` alias) —
matching every other fable reference in this repo, which is always
version-pinned to avoid silent drift when the alias remaps.

**Worker effort dimension (new for claude):** before this wave, the claude
worker ladder never touched effort — only codex rows carried a `:reasoning`
suffix. The new terminal rung is effort-qualified (`claude-fable-5-1:max`,
mirroring how every codex ceiling rung is always effort-qualified, never
bare), which required `check_model_upgrade` to split `model:effort` for the
claude branch the same way it already did for codex — see
`_ORIGINAL_WORKER_EFFORT` in `lib_ralph_desk.zsh`/`run_ralph_desk.zsh` (saved
on first upgrade, restored on pass verdict, mirroring
`_ORIGINAL_WORKER_CODEX_REASONING`). **Crash-relaunch persistence (fixed in
this wave):** the crash-relaunch restore path (D-5b, `run_ralph_desk.zsh`)
now persists and restores `worker_effort`/`original_worker_effort` in
`status.json`, mirroring `worker_codex_reasoning`/
`original_worker_codex_reasoning` exactly — both `update_status()` (the
per-iteration status writer) and the session-config writer at
campaign-creation time set `worker_effort`, and the D-5b restore block reads
`worker_effort`/`original_worker_effort` back alongside the codex
equivalents. If the leader crashes while a claude worker is upgraded to
`claude-fable-5-1:max`, relaunch now restores both `WORKER_MODEL` AND
`WORKER_EFFORT` — it no longer silently drops back to no explicit effort.
This gap predated this wave (a manual `--worker-model opus:high` start had
the same exposure) but was previously inert for auto-upgrade (the ladder
never produced a claude effort); the ladder extension to
`claude-fable-5-1:max` made it live, so it was closed alongside it. See
`test_d5b_worker_effort_crash_restart` and
`test_d5b_worker_effort_missing_field_backward_compat` in
`tests/test_us011_worker_model_upgrade.sh` for the crash-restart and
missing-field-backward-compat coverage.

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
