# Model Upgrade Table

Progressive Worker model upgrade on consecutive failure per US.
CB default: 4. Override: `--cb-threshold N`. Worker only — Verifier fixed at campaign start.

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
(haiku→sonnet→opus→claude-opus-5-5:high) used only if both files are missing
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

## Codex model catalog (codex-cli 0.162.1, snapshot 2026-10-11)

Source: `~/.codex/models_cache.json` as fetched by codex-cli 0.162.1 on
2026-10-11 (11 entries; the three not listed in the table, `gpt-reserve`,
`gpt-daybreak-blue-latest` and `codex-auto-review`, are not used by rlp-desk).
There is no GPT-6 Terra: `gpt-5.6-terra` is still the terra slot.

| Model | Position | Reasoning efforts | Catalog default |
|-------|----------|-------------------|-----------------|
| gpt-6.1-sol | Latest workhorse for coding and everyday work (priority 1) | low, medium, high, xhigh, max, ultra | low |
| gpt-6-astra | Frontier intelligence for the most demanding work (judge-only in rlp-desk) | low, medium, high, xhigh, max, ultra | medium |
| gpt-6-sol | Previous-generation workhorse | low, medium, high, xhigh, max, ultra | medium |
| gpt-6-luna | Fast and affordable, easier tasks | low, medium, high, xhigh, max | medium |
| gpt-5.6-sol | Older generation workhorse | low, medium, high, xhigh, max, ultra | low |
| gpt-5.6-terra | Older balanced model (no GPT-6 successor) | low, medium, high, xhigh, max, ultra | medium |
| gpt-5.6-luna | Older fast and efficient model | low, medium, high, xhigh, max | medium |
| gpt-5.5 | Legacy coding model (hidden in the list) | low, medium, high, xhigh | medium |

- Retired ids (`gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`,
  `spark`) remap on entry (see `RETIRED_MODEL_REMAP`). Dated note 2026-10-11:
  `gpt-5.4`, `gpt-5.4-mini` and `gpt-5.3-codex-spark` are not in the codex
  0.162.1 catalog (Pro-only models may be hidden from the list); the sections
  below keep describing them.
- `max` and `ultra` are effort tiers introduced with the GPT-5.6 family;
  `gpt-6-luna` and the older 5.6 luna list `max` but not `ultra` (the CLI accepted
  `luna:ultra` on 2026-10-11, but acceptance is not proof it is applied, and
  there is no `gpt-6-luna:ultra` ladder key). **Policy 2026-08-03
  (luna-first — partial reversal of the 2026-07-20 xhigh-ceiling policy,
  justified by the 2026-07-30 price cut):** within luna the ladder raises
  effort to `max` before jumping models (`luna:high → luna:max`, skipping
  xhigh in the default chain; `luna:xhigh → luna:max` for manual starts).
  `luna:max` then hops to the quota-first `terra:max` lane (GPT-5.6-generation estimate, not re-measured: terra:max quality sits between sol:high and sol:xhigh — sol:high would be lateral; since the 2026-10-11 price page terra is priced above gpt-6.1-sol per token, 0.55 vs 0.5 relative to gpt-5.6-sol = 1.0, and it stays the lane ceiling by owner decision), which is
  now the cost lane's own ceiling (2026-09-26 CB=4/3-rung wave — no further
  escalation into sol). Terra keeps its own `:xhigh` ladder ceiling before
  jumping model into sol on a manual terra start; sol's `:xhigh` is its own
  terminal ceiling again — `gpt-6-astra` is judge-only (see "GPT-6 — Astra"
  below) and is never reached by a worker escalation.
  `sol:max`/`sol:ultra`/`terra:ultra`/`gpt-6-astra:max`/`gpt-6-astra:ultra`
  remain valid manual starting points but are dead-end keys (no forward
  escalation).
- `gpt-6-sol` (previous-generation workhorse, $2/$10) has no ladder keys: an explicit `gpt-6-sol:*` start runs without escalation (a dead start, like `luna:ultra`); use `gpt-6.1-sol`.
- CLI aliases: `sol` → gpt-6.1-sol, `terra` → gpt-5.6-terra, `luna` →
  gpt-6-luna, `astra` → gpt-6-astra (same convention as the existing `spark`
  alias, itself retired). Retired remap targets follow the slot:
  `gpt-5.4-mini`/`gpt-5.3-codex-spark`/`spark` → gpt-6-luna, `gpt-5.5` →
  gpt-6.1-sol, `gpt-5.4` → gpt-5.6-terra. Explicit 5.6 sol and luna ids are
  never rewritten.
- `gpt-5.5-pro` and `gpt-5.4-nano` appear in some OpenAI surfaces but are NOT
  in the codex CLI catalog — not usable as rlp-desk worker/verifier models.
- `gpt-6-astra` (codex-cli 0.153.4+) is listed in the 0.162.1 catalog above
  (priority 2); see "GPT-6 — Astra" below for its empirically confirmed
  details.

## GPT-6 — Astra (newest frontier)

| Model | Position | Reasoning efforts | Catalog default |
|-------|----------|-------------------|-----------------|
| gpt-6-astra | Frontier agentic coding (newest) | low, medium, high, xhigh, max (confirmed) | medium (catalog 0.162.1) |

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

Update 2026-10-11 (codex-cli 0.162.1): `gpt-6-astra` is now listed in `~/.codex/models_cache.json` (priority 2, default `medium`).

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
assumption. This self-chain remains usable for an explicit manual
`--worker-model gpt-6-astra:<level>` start, and it is what `FINAL_VERIFIER_CODEX_MODEL`
/ `FINAL_CONSENSUS_MODEL` run at (`gpt-6-astra:high` / `gpt-6-astra:xhigh`
respectively).

**Owner decision history.** An earlier wave wired `gpt-5.6-sol:xhigh` to
escalate into `gpt-6-astra:high` (entering at `:high`, matching the
already-established "model step-up enters at `:high`, never a lower effort"
rule used for `terra:xhigh → sol:high`), making astra the real ceiling of the
whole worker ladder. **That decision was reopened and reversed on 2026-09-26**
(the CB=4/3-rung wave, `docs/plans/model-mapping-2026-09-25-findings.md` Part
2 §6): `gpt-6-astra` is judge-only, and `gpt-5.6-sol:xhigh` is its own
terminal `""` again — no worker walk reaches astra any more. See the updated
Sol/Terra/Luna tables below for the current per-complexity chains.

`minimal` is also rejected by `gpt-6.1-sol`, `gpt-6-sol` and `gpt-6-luna` (probed 2026-10-11, HTTP 400; the server enumerates `low|medium|high|xhigh|max` for `gpt-6.1-sol` and `none|low|medium|high|xhigh|max` for `gpt-6-sol` and `gpt-6-luna`); the validator rejects it at startup for these four slugs and their aliases (`astra`, `sol`, `luna`, and remapped `gpt-5.5`); the 5.6 family is unprobed and stays accepted.

CLI alias: `astra` → `gpt-6-astra` (same convention as `sol`/`terra`/`luna`).

## Cost Model (`cost_factors` in `src/node/models.json`)

**Architectural finding, not previously documented:** `cost_factors` is
consumed ONLY for codex-engine rows in both leaders —
`_resolveCostFactor`/summarizeCost gates on `record.worker_engine === 'codex'`
(`src/node/reporting/campaign-reporting.mjs`) and `_cost_factor_x100` (name kept;
an integer x1000 scale since 2026-10-11) is only called `if [[ "$row_worker_engine" == "codex" ]]` (`src/scripts/lib_ralph_desk.zsh`,
"Codex legs sol-equivalent" summary). Claude-engine rows are counted
(`claude_legs++` / a separate bucket) but **never priced** by this table
today — the "unknown family -> 1.0" fallback is real, but it currently only
ever fires for an unrecognized *codex* model, never for a claude one. A
claude `cost_factors` entry would be inert under the current code — useful
groundwork, not a live fix — until/unless a future change wires claude legs
into the same accounting.

**Codex factors (2026-10-11, derived from saved raw OpenAI rows).** The raw
Standard-tier rows are saved verbatim in
`.omc/artifacts/sv-sonnet-opus-5-5/evidence/openai-pricing-2026-10-11.md`
(fetched 2026-10-11; $ per MTok input / output, short context). The single-factor
rule: when the input and output ratios to the anchor are equal the factor is
that value, otherwise their mean (`estimated_tokens` carries no input/output
split, so the mean bounds the error at half the spread). The anchor stays
the 5.6 Sol price (4 / 20) = 1.0, so old numbers keep their meaning. Both leaders
use the same per-row scaled-integer calculation (each factor x1000, rounded;
sum of tokens x scaled factor; one floor division by 1000), so reports agree
to the token.

Factors relative to gpt-5.6-sol = 1.0 (OpenAI price page of 2026-10-11, short context; the 5.6 Sol price is promotional through at least 2026-11-21, re-derive after): gpt-6.1-sol 0.5; gpt-6-luna 0.025; gpt-5.6-terra 0.55 (was 0.4); gpt-5.6-luna 0.055 (was 0.04); one factor = the input/output ratio when equal, else their mean. gpt-6-astra would be 2.5 (judge-only, not applied).

`gpt-6-astra` ($10/$50) is recorded but **not applied**: it is judge-only and
`cost_factors` only prices worker codex rows. Retired `gpt-5.5`, `gpt-5.4` and
`spark` remap on entry and carry no factor of their own. The saved page says
"GPT-5.6 Sol's promotional pricing is available at least through November 21,
2026": the anchor price is promotional, so every factor expires then and must
be re-derived after that date (follow-up F-B). Old cost logs re-reported later
show different terra/luna sol-equivalents than the numbers printed at the time.

**Claude family — real evidence available, not applied (see the
architectural finding above for why):** the Anthropic pricing evidence
(`claude-api` skill table cached 2026-09-25, re-read 2026-09-30; Haiku 5.5 from
the platform models overview fetched 2026-10-11) gives Sonnet 5.5 $2/$10, Opus
5.5 $4/$20, Fable 5.1 $10/$50 and Haiku 5.5 from $0.10/$0.50 (input/output per
MTok; Opus 5 was $5/$25; Haiku 4.5 was $1/$5 and stays here as the legacy
reference). That is a 100:40:20:1 ratio (fable:opus:sonnet:haiku-5.5) on BOTH
input and output pricing. Anchoring to the generation's top tier at `1.0`
(the same convention `sol` already uses on the codex side) gives:

| Model | Ratio to fable | Evidence |
|-------|----------------|----------|
| claude-fable-5-1 | 1.0 | $10/$50 per MTok (anchor) |
| claude-opus-5-5 | 0.4 | $4/$20 per MTok = 2/5 of fable |
| claude-sonnet-5-5 | 0.2 | $2/$10 per MTok = exactly 1/5 of fable |
| claude-haiku-5-5 | 0.01 | $0.10/$0.50 per MTok (<=100K prompt) = 1/100 of fable on both legs |

This ratio is well-evidenced (first-party pricing, not a guess) but **was
NOT added to `cost_factors`**, because the code prices codex rows only and
claude legs are subscription-pool, not dollar-metered. **Owner decisions:** (a)
the cross-engine reconciliation now exists in the saved evidence, so the claude
values CAN be placed on the same 1.0-anchored scale:
Cross-engine reconciliation from the same saved rows, relative to gpt-5.6-sol = 1.0 (promo price): claude-fable-5-1 2.5, claude-opus-5-5 1.0, claude-sonnet-5-5 0.5, claude-haiku-5-5 0.025 on both legs; NOT applied (claude legs are subscription-pool and the code prices codex rows only).
(b) should claude get its own independently-scaled `1.0` anchor with an
explicit note that summing it against codex factors is not a dollar-equivalent
comparison, or (c) should claude legs stay unpriced (status quo) until the
codex-only architectural gate is revisited on its own. (b) and (c) stay open
to the owner; the ratios above are ready to apply under whichever answer is
chosen — they do not need re-deriving (apart from the promo-price caveat).

## GPT-6.1 — Sol (workhorse; `sol:xhigh` is its own terminal ceiling — astra left the worker escalation path)

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | gpt-6.1-sol:low | gpt-6.1-sol:medium | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) |
| MEDIUM | gpt-6.1-sol:medium | gpt-6.1-sol:high | gpt-6.1-sol:xhigh | at CB 4: — (not reached: BLOCKED at failure #6) |
| HIGH | gpt-6.1-sol:medium | gpt-6.1-sol:high | gpt-6.1-sol:xhigh | at CB 4: — (not reached: BLOCKED at failure #6) |
| CRITICAL | gpt-6.1-sol:high | gpt-6.1-sol:xhigh | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) |

`gpt-5.6-sol:*` and `gpt-5.6-luna:*` (older generation) remain ladder keys and escalate inside their own family; the shared `gpt-5.6-terra:xhigh` hop lands on `gpt-6.1-sol:high`.

**Reachability** (tmux leader only. Walked 2026-10-11 against the real `check_model_upgrade()` + circuit-breaker code; `CB_THRESHOLD=4`, consensus off (consensus doubles the threshold), one US, every failure ladder-eligible). A column is only dispatched if the campaign survives to its first attempt:

| Start | Attempt → model | BLOCKED at failure # | Block |
|-------|-----------------|----------------------|-------|
| LOW | #1-2 gpt-6.1-sol:low, #3-4 gpt-6.1-sol:medium | 4 | plain "4 consecutive verification failures" (the next rung is only just assigned at #4 and never dispatched) |
| MEDIUM | #1-2 gpt-6.1-sol:medium, #3-4 gpt-6.1-sol:high, #5-6 gpt-6.1-sol:xhigh | 6 | architecture escalation (DEFECT-2a: the ceiling gets its own 2-attempt window) |
| HIGH | #1-2 gpt-6.1-sol:medium, #3-4 gpt-6.1-sol:high, #5-6 gpt-6.1-sol:xhigh | 6 | architecture escalation (same) |
| CRITICAL | #1-2 gpt-6.1-sol:high, #3-4 gpt-6.1-sol:xhigh | 4 | architecture escalation (the promotion lands at #2, so the ceiling has had both attempts by #4) |

(2026-09-26 CB=4/3-rung wave, owner decision: `gpt-6-astra` is judge-only —
the Final Verifier and Final Consensus seats — and left the worker
escalation path entirely. `sol:xhigh` has no next step; it is the
real ceiling of the sol family now. CRITICAL starts at `sol:high`, one hop
below the ceiling — with `CB_THRESHOLD` default 4 a CRITICAL campaign may
start at, or one hop below, the ceiling; if it fails `CB_THRESHOLD` times,
BLOCKED is the correct outcome, a spec problem rather than a headroom gap
(see "High-complexity headroom" decision in
`docs/plans/model-mapping-2026-09-25-findings.md` Part 2 §4). Verified via a
direct walk of the shipped `src/node/models.json` ladder, not hand-derived —
see `tests/node/models-ladder.test.mjs` "gpt-5.6-sol:xhigh terminates at its
own ceiling" (the legacy 5.6 key) and the gpt-6.1-sol ladder test there.
The `7+` column applies only when `--cb-threshold` is raised above the
default; consensus doubles the effective threshold.)

## GPT-5.6 — Terra (xhigh → Sol:high jump; terra:max is the cost lane's own ceiling)

| Complexity | 1-2 | 3-4 | 5-6 | 7-8 | 9-10 | 11-12 |
|------------|-----|-----|-----|-----|------|-------|
| LOW | gpt-5.6-terra:low | gpt-5.6-terra:medium | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) |
| MEDIUM | gpt-5.6-terra:medium | gpt-5.6-terra:high | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) |
| HIGH | gpt-5.6-terra:high | gpt-5.6-terra:xhigh | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) | at CB 4: — (not reached: BLOCKED at failure #4) |
| CRITICAL | gpt-5.6-terra:xhigh | gpt-6.1-sol:high | gpt-6.1-sol:xhigh | at CB 4: — (not reached: BLOCKED at failure #6) | at CB 4: — (not reached: BLOCKED at failure #6) | at CB 4: — (not reached: BLOCKED at failure #6) |

**Reachability** (tmux leader only. Walked 2026-10-11 against the real `check_model_upgrade()` + circuit-breaker code; `CB_THRESHOLD=4`, consensus off (consensus doubles the threshold), one US, every failure ladder-eligible):

| Start | Attempt → model | BLOCKED at failure # | Block |
|-------|-----------------|----------------------|-------|
| LOW | #1-2 gpt-5.6-terra:low, #3-4 gpt-5.6-terra:medium | 4 | plain "4 consecutive verification failures" (the next rung is only just assigned at #4 and never dispatched) |
| MEDIUM | #1-2 gpt-5.6-terra:medium, #3-4 gpt-5.6-terra:high | 4 | plain "4 consecutive verification failures" (same) |
| HIGH | #1-2 gpt-5.6-terra:high, #3-4 gpt-5.6-terra:xhigh | 4 | plain "4 consecutive verification failures" (same) |
| CRITICAL | #1-2 gpt-5.6-terra:xhigh, #3-4 gpt-6.1-sol:high, #5-6 gpt-6.1-sol:xhigh | 6 | architecture escalation (DEFECT-2a: the ceiling gets its own 2-attempt window) |

(After `terra:xhigh` the ladder jumps to `gpt-6.1-sol:high` — model step-up
enters at `:high`, never a lower effort (the shared terra node follows the
slot rule: terra has no GPT-6 successor, so its escalation lands in the
current workhorse). `sol:xhigh` has no next step; it is the real ceiling of
the sol family now (2026-09-26 CB=4/3-rung wave — `gpt-6-astra` is judge-only
and left the worker escalation path). This table is illustrative of the full
manual-start shape, not default behavior — the brainstorm default cost-lane
walk is the 3-rung `luna:high → luna:max → terra:max` spine below. A
`terra:low`/`terra:medium`/`terra:high` start has 3+ rungs below
`sol:xhigh` and blocks at failure #4 with the next rung only just assigned
and never dispatched; a `terra:xhigh` start (2 rungs below `sol:xhigh`) has
the promotion to `sol:xhigh` land exactly on failure #4, so DEFECT-2a defers
the breaker until failure #6. Any further column applies only when
`--cb-threshold` is raised above the default.)

(`terra:max` is the quota-first lane hop reached from `luna:max`, or a manual
`--worker-model gpt-5.6-terra:max` start; it has no next step — it is the
cost lane's own ceiling now, not a hop into `sol:xhigh`.)

## GPT-6 — Luna (effort to max first, then terra:max quota-first ceiling)

| Complexity | 1-2 | 3-4 | 5-6+ |
|------------|-----|-----|------|
| LOW | gpt-6-luna:high | gpt-6-luna:max | gpt-5.6-terra:max |
| MEDIUM | gpt-6-luna:xhigh | gpt-6-luna:max | gpt-5.6-terra:max |
| HIGH | gpt-6-luna:max | gpt-5.6-terra:max | at CB 4: — (not reached: BLOCKED at failure #4) |
| CRITICAL | gpt-6.1-sol:high | gpt-6.1-sol:xhigh | at CB 4: — (not reached: BLOCKED at failure #4) |

`gpt-5.6-sol:*` and `gpt-5.6-luna:*` (older generation) remain ladder keys and escalate inside their own family; the shared `gpt-5.6-terra:xhigh` hop lands on `gpt-6.1-sol:high`.

**Reachability** (tmux leader only. Walked 2026-10-11 against the real `check_model_upgrade()` + circuit-breaker code; `CB_THRESHOLD=4`, consensus off (consensus doubles the threshold), one US, every failure ladder-eligible):

| Start | Attempt → model | BLOCKED at failure # | Block |
|-------|-----------------|----------------------|-------|
| LOW | #1-2 gpt-6-luna:high, #3-4 gpt-6-luna:max, #5-6 gpt-5.6-terra:max | 6 | architecture escalation (DEFECT-2a: the ceiling gets its own 2-attempt window) |
| MEDIUM | #1-2 gpt-6-luna:xhigh, #3-4 gpt-6-luna:max, #5-6 gpt-5.6-terra:max | 6 | architecture escalation (same) |
| HIGH | #1-2 gpt-6-luna:max, #3-4 gpt-5.6-terra:max | 4 | architecture escalation (the promotion lands at #2, so the ceiling has had both attempts by #4) |
| CRITICAL | #1-2 gpt-6.1-sol:high, #3-4 gpt-6.1-sol:xhigh | 4 | architecture escalation (same) |

(Row = brainstorm start per complexity (cost lane); columns =
consecutive-failure milestones. Full chain (2026-09-26 CB=4/3-rung wave):
`luna:high → luna:max → terra:max` (ceiling) — the old
`terra:max → sol:xhigh → astra` escape hatch is gone; manual
`luna:low/medium` starts climb `low → medium → high` first; manual
`luna:xhigh` joins at `luna:max`. CRITICAL rows start at `gpt-6.1-sol:high`
regardless of lane, on sol's own 2-rung chain to its `sol:xhigh` ceiling —
lane-independent and outside the luna-first cost lane. Speed lane HIGH starts
`sol:medium → sol:high → sol:xhigh` (ceiling).)

**Known accepted edge (spec §5).** The lane choice applies only to HIGH rows —
LOW and MEDIUM start on luna in *both* lanes. So a LOW/MEDIUM US that keeps
failing on a speed-lane campaign still walks the cost-lane chain and reaches
the quota-first `terra:max` hop, which is slower than sol: the operator picked
"speed" but a repeatedly-failing cheap US lands on the slow rung anyway. This
is accepted — escalation is evidence-gated, and by the time a LOW US has failed
this many times its complexity was misjudged. Two mitigations if the latency
matters: `--lock-worker-model` (pin the start model; the CB then owns the
terminal outcome instead of the ladder) or a manual `--worker-model
gpt-6.1-sol:medium` start for that campaign.

## GPT-5.4 / GPT-5.4-mini (low → medium → high → xhigh)

Dated note 2026-10-11: retired ids remap on entry (see the catalog section above); `gpt-5.4` and `gpt-5.4-mini` are not in the codex 0.162.1 catalog (Pro-only models may be hidden from the list).

Same 4-tier shape as gpt-5.5 below; substitute `gpt-5.4` or `gpt-5.4-mini`.

## GPT Pro (gpt-5.3-codex-spark — separate token limit)

Dated note 2026-10-11: retired ids remap on entry (see the catalog section above); `gpt-5.3-codex-spark` is not in the codex 0.162.1 catalog (Pro-only models may be hidden from the list).

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | gpt-5.3-codex-spark:low | gpt-5.3-codex-spark:medium | gpt-5.3-codex-spark:high | BLOCKED |
| MEDIUM | gpt-5.3-codex-spark:medium | gpt-5.3-codex-spark:high | gpt-5.3-codex-spark:xhigh | BLOCKED |
| HIGH | gpt-5.3-codex-spark:high | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | BLOCKED |
| CRITICAL | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | gpt-5.3-codex-spark:xhigh | BLOCKED |

## Non-Pro (gpt-5.5)

Dated note 2026-10-11: retired ids remap on entry (see the catalog section above); `gpt-5.5` is listed in the codex 0.162.1 catalog as hidden (legacy coding model).

| Complexity | 1-2 | 3-4 | 5-6 | 7+ |
|------------|-----|-----|-----|-----|
| LOW | gpt-5.5:low | gpt-5.5:medium | gpt-5.5:high | BLOCKED |
| MEDIUM | gpt-5.5:medium | gpt-5.5:high | gpt-5.5:xhigh | BLOCKED |
| HIGH | gpt-5.5:high | gpt-5.5:xhigh | gpt-5.5:xhigh | BLOCKED |
| CRITICAL | gpt-5.5:xhigh | gpt-5.5:xhigh | gpt-5.5:xhigh | BLOCKED |

## Claude-only (2026-09-26 CB=4/3-rung wave: claude-opus-5-5:high is the ceiling — claude-fable-5-1:max left the worker spine for Final Verifier only)

| Complexity | 1-2 | 3-4 | 5-6+ |
|------------|-----|-----|------|
| LOW | claude-haiku-5-5:medium | claude-sonnet-5-5:high | claude-opus-5-5:high (repeat until CB) |
| MEDIUM | claude-sonnet-5-5:medium | claude-sonnet-5-5:high | claude-opus-5-5:high (repeat until CB) |
| HIGH | claude-sonnet-5-5:high | claude-opus-5-5:high (repeat until CB) | at CB 4: — (not reached: BLOCKED at failure #4) |
| CRITICAL | claude-opus-5-5:high (repeat until CB) | claude-opus-5-5:high (repeat until CB) | at CB 4: — (not reached: BLOCKED at failure #4) |

**Reachability** (tmux leader only; native promotion and stopping are not guaranteed to match, a known gap. Walked 2026-10-07 against the real `check_model_upgrade()` + circuit-breaker code; `CB_THRESHOLD=4`, consensus off, one US, every failure ladder-eligible). A column is only dispatched if the campaign survives to its first attempt:

| Start | Attempt → model | BLOCKED at failure # | Block |
|-------|-----------------|----------------------|-------|
| LOW | #1-2 claude-haiku-5-5:medium, #3-4 claude-sonnet-5-5:high, #5-6 claude-opus-5-5:high | 6 | architecture escalation (DEFECT-2a: the ceiling gets its own 2-attempt window) |
| MEDIUM | #1-2 claude-sonnet-5-5:medium, #3-4 claude-sonnet-5-5:high, #5-6 claude-opus-5-5:high | 6 | architecture escalation (same) |
| HIGH | #1-2 claude-sonnet-5-5:high, #3-4 claude-opus-5-5:high | 4 | architecture escalation (the promotion lands at #2, so the ceiling has had both attempts by #4) |
| CRITICAL | #1-4 claude-opus-5-5:high | 4 | plain "4 consecutive verification failures" (starts AT the ceiling, never upgraded, so no deferral) |

The `5-6+` column of HIGH and CRITICAL is reached only when the breaker threshold is above 4 (`--cb-threshold N`, N >= 5, or consensus, which doubles it): at `CB_THRESHOLD=6` a HIGH start runs `claude-opus-5-5:high` through failure #6. This table and these stop points describe the tmux leader's coded ladder and circuit breaker (`--mode tmux`). `--mode native` runs the ladder and the breaker as LLM-executed prose (steps ③ and ⑦c and the Circuit Breaker section of `rlp-desk.md`), which is not guaranteed to match them (a known gap).

(The claude spine shortened from 7 rungs to 3 (2 hops from `haiku`) so
`CB_THRESHOLD=4` dispatches every rung instead of stranding the budget on a
mid-ladder rung — see
`docs/plans/model-mapping-2026-09-25-findings.md` Part 2 §3. This holds for
consecutive ladder-eligible (spec/implementation/integration) failures on the
same US; a ladder-ineligible failure mixed into that window (environment/flaky
verdicts, an F-22 soft-fail, or a malformed `verify_partial`) still increments
`CONSECUTIVE_FAILURES` without advancing the ladder, so it can trip the
breaker before a later rung ever dispatches.
`claude-opus-5-5:high` has no further upgrade — that is the real claude
ceiling now; `claude-fable-5-1:max` stays a valid terminal key for an
explicit manual start but is unreachable from the spine (Final Verifier
only). CRITICAL starts AT the ceiling per owner decision (Part 2 §4 option
a): if it fails `CB_THRESHOLD` times, BLOCKED is the correct outcome — a
spec problem, not a model-ladder gap. Verified via a direct walk of the
shipped `src/node/models.json` ladder — see `tests/node/models-ladder.test.mjs`
"claude worker ceiling is claude-opus-5-5:high, not fable".)

The MEDIUM spine is
`claude-sonnet-5-5:medium` → `claude-sonnet-5-5:high` → `claude-opus-5-5:high`: an effort-only first hop on the same model id, then the same two-hop shape as the haiku spine, so `CB_THRESHOLD=4` still dispatches every rung. Why MEDIUM starts at `medium`: Anthropic's effort guidance says "For agentic coding and multistep tool use, start with `medium` for well-specified tasks and move to `high` for harder or longer ones" (https://platform.claude.com/docs/en/build-with-claude/effort); the ladder spends `high` only after two failed attempts. `:medium` is a start only, nothing escalates into it, and the emergency inline ladder (used only when `models.json` is missing) has no key for it.

Legacy `sonnet:high` / `sonnet:medium` remain ladder keys (persisted
status.json, older copied flags) and escalate straight to
`claude-opus-5-5:high`. An override file (`${RLP_DESK_MODELS_FILE:-~/.claude/rlp-desk-models.json}`) REPLACES the whole shipped ladder (`get_next_model()` in `lib_ralph_desk.zsh`) and is read entry by entry, so two cases differ: an override written before the pinned spine has no `claude-sonnet-5-5:high` key and keeps the floating `sonnet` middle rung, so a start on `claude-sonnet-5-5:high` or on its `:medium` sibling is a dead start under it; an override copied from the pinned shipped ladder before the `:medium` key was added still has the `claude-sonnet-5-5:high` key and lacks only `:medium`, so only a `:medium` start is dead under it. Either way, regenerate the override from the shipped file. Legacy `haiku` is the same rung (floating alias; it resolves to `claude-haiku-5-5` in the CLI as of 2026-10-11) and stays a ladder key.

An override written before the 2026-10-11 generation refresh that contains only `gpt-5.6-*` keys will not match `luna:`/`sol:` (now `gpt-6-luna`/`gpt-6.1-sol`): add the new keys or delete the override.

Dead starts (accepted, dispatched with their effort, but not ladder keys, so the worker never escalates and the circuit breaker blocks at failure #4): `haiku:<effort>` (any effort on the floating alias), `claude-haiku-5-5:low` and `claude-haiku-5-5:high` (only `claude-haiku-5-5:medium` is a rung), and `claude-sonnet-5-5:low`. Start on a rung instead.

**Verification (2026-09-14, claude CLI) — live probes, matching the
`gpt-6-astra` treatment below.** The claude effort vocabulary
(`low|medium|high|max|xhigh`, enforced by `_validate_model_level`) predates
Fable 5.1, so the wave that made `claude-fable-5-1:max` the (then-)worker
ladder ceiling had not established that this model accepts `max` — the same
assumption that turned out to be wrong for `gpt-6-astra:minimal`. `claude-fable-5-1:max`
has since left the worker spine (2026-09-26 CB=4/3-rung wave — it is Final
Verifier only now), but the probe evidence below stays valid: it is exactly
the model+effort combination `FINAL_VERIFIER_MODEL` runs at. Each level was
probed for real:

```
claude --model claude-fable-5-1 --effort <level> --mcp-config '{"mcpServers":{}}' \
  --strict-mcp-config -p "Reply with exactly: OK" --output-format text
```

| Level | Outcome |
|-------|---------|
| low / medium / high / max / xhigh | Accepted — real generation, replied `OK` |
| minimal / ultra / bogus | **Warning, then ignored**: *"Unknown --effort value 'X' — ignoring it and using the default effort. Valid values: low, medium, high, xhigh, max."* Still exits 0 and still generates. |

**Conclusion:** all five shipped effort levels are confirmed on
`claude-fable-5-1`, so `claude-fable-5-1:max` is a valid ceiling key (Final
Verifier, and any explicit manual worker start), and the repo's claude
vocabulary matches the CLI's own enumeration exactly — no missing level, no
extra one.

**Asymmetry worth knowing:** codex **fails closed** on an unsupported reasoning
level (HTTP 400, campaign stops), while claude **fails open** — it warns, drops
the flag, and runs at the default effort with exit 0. So on the claude side a
bad effort would silently downgrade a campaign rather than stop it, and
`_validate_model_level()` is the only thing that catches it before launch. That
makes the shared validator load-bearing on claude in a way it is not on codex;
do not weaken it on the assumption the CLI will reject bad input.

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

**Worker effort dimension (new for claude, Fable 5.1 wave):** before that
wave, the claude worker ladder never touched effort — only codex rows carried
a `:reasoning` suffix. The terminal rung became effort-qualified
(`claude-fable-5-1:max` at the time, now `claude-opus-5-5:high` since the
2026-09-26 CB=4/3-rung wave — every ceiling rung is effort-qualified, never
bare, mirroring codex), which required `check_model_upgrade` to split
`model:effort` for the claude branch the same way it already did for codex —
see `_ORIGINAL_WORKER_EFFORT` in `lib_ralph_desk.zsh`/`run_ralph_desk.zsh`
(saved on first upgrade, restored on pass verdict, mirroring
`_ORIGINAL_WORKER_CODEX_REASONING`). **Crash-relaunch persistence (fixed in
the Fable 5.1 wave):** the crash-relaunch restore path (D-5b,
`run_ralph_desk.zsh`) persists and restores `worker_effort`/
`original_worker_effort` in `status.json`, mirroring `worker_codex_reasoning`/
`original_worker_codex_reasoning` exactly — both `update_status()` (the
per-iteration status writer) and the session-config writer at
campaign-creation time set `worker_effort`, and the D-5b restore block reads
`worker_effort`/`original_worker_effort` back alongside the codex
equivalents. If the leader crashes while a claude worker is upgraded to the
ceiling (`claude-opus-5-5:high`), relaunch restores both `WORKER_MODEL` AND
`WORKER_EFFORT` — it does not silently drop back to no explicit effort. This
gap predated the Fable 5.1 wave (a manual `--worker-model opus:high` start had
the same exposure) but was previously inert for auto-upgrade (the ladder
never produced a claude effort); the ladder's first effort-qualified ceiling
made it live, so it was closed alongside it. See
`test_d5b_worker_effort_crash_restart` and
`test_d5b_worker_effort_missing_field_backward_compat` in
`tests/test_us011_worker_model_upgrade.sh` for the crash-restart and
missing-field-backward-compat coverage.

**Same-US streak across a relaunch (F6):** `update_status()` also persists
`last_failed_us` (the US that `same_us_fail_count` belongs to), and the relaunch
restores both for ANY relaunch of a live campaign, promoted or not (the model,
effort and ceiling bookkeeping restore of D-5b stays gated on `model_upgraded`
being 1). So a crash after one same-US failure keeps the streak and the next
same-US failure promotes on time. A missing field restores as 0 / empty. A
`status.json` whose `phase` is `complete` (a finished run's leftover) or
`blocked` is not restored. For `blocked`, PR-E resets the other counters only
when `_validate_blocked_recovery` passes (in `lib_ralph_desk.zsh`: the
sentinel is cleared, a failure or block counter is non-zero, no sidecar says
`recoverable=false`); if that validation fails the failure counter is still
restored while the streak starts at 0, and the ceiling-deferral counter of a
blocked leftover is still restored by D-5b. A fresh campaign has no file
(`init --mode fresh|improve` deletes it) and the file is per project root and
slug. When no PRD exists yet, the missing-PRD fallback of `init --mode
fresh|improve` clears only the four runtime files (`status.json`, the legacy
`status.json`, `baseline.log`, `cost-log.jsonl`) and does NOT archive memos,
iterations or the verified-US ledger, which the PRD-present lifecycle archives.
The streak is per US and is restored as persisted: if the operator
relaunches with a different `--worker-model`, a not-yet-promoted campaign applies
the restored count to the NEW start model (the first same-US failure may promote
one failure earlier than a cold start), while a promoted campaign keeps its
persisted model; use `init --mode fresh|improve` for a clean restart. Pinned by
`tests/test_relaunch_same_us_streak.sh`.

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
