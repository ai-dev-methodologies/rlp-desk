# Luna-First Cost Routing — Design Spec

- Date: 2026-08-03
- Status: APPROVED by owner (this session), pending implementation plan
- Scope: rlp-desk model routing (worker ladder, verifier/consensus tiers, lane
  selection, effort-aware timeouts, campaign cost summary)
- Trigger: 2026-07-30 OpenAI price cut (Luna −80%, Terra −20%) + codex-5.6
  (GPT-5.6 sol/terra/luna) + `ai-dev-methodologies/adaptive-delegation`
  luna-first policy adoption.

## 1. Background & evidence basis

GPT-5.6 pricing after 2026-07-30 (per MTok in/out): Sol $5/$30, Terra $2/$12,
Luna $0.20/$1.20 → sol-equivalent cost factors **sol 1.0 / terra 0.4 /
luna 0.04**. Claude 5 pricing: fable-5 $10/$50, opus-5 $5/$25, sonnet-5 $3/$15
(intro $2/$10 through 2026-08-31).

Evidence that shaped the design (full sources in Appendix):

1. **Luna excels under precise instructions + strong oracle.** rlp-desk is
   exactly that environment (per-US acceptance criteria + independent Verifier
   + tests). Aggregate coding benchmarks show small tier gaps (SWE-Bench Pro
   62.7/63.4/64.6 luna/terra/sol).
2. **Terra's cost/speed merit is narrow.** Artificial Analysis: terra
   xhigh/max largely dominated by sol medium/high; CodeRabbit long-coding
   shows terra output-token bloat (55,594 vs sol 20,968) eroding its 0.4 price
   factor to near sol-parity. Terra medium/high keeps a legitimate niche as a
   fast mid-quality intermediate; terra xhigh/max is a **quota-first lane**
   (trade time for lower Sol usage), not a speed lane.
3. **Judging-type work has LARGE tier gaps**, unlike coding aggregates:
   Internal Research Debugging sol 68.3 / terra 67.8 / **luna 50.8**;
   CodeRabbit review actionable-pass sol 69.7% vs terra 52.5%. Therefore
   worker routing (luna-first) and verifier/consensus routing (tier-scaled)
   use different rules on purpose.
4. **opus-5:max ≈ fable-5:max** on AA Intelligence Index (61 vs 60,
   "effectively tied") at $2.03 vs $2.75/task. fable-5 at low/medium has no
   published evidence of beating opus-5:max on judgment tasks (inference
   confidence ~65-70%, no direct head-to-head exists). Hence CRITICAL per-US
   verifier = opus-5:max; fable-5:max stays only at the final gate.
5. **Environment/harness failures must not trigger model escalation**
   (5 Codex incident reports: terminal ownership, unattended search, empty
   final response near context ceiling, planning loops, headless harness —
   all model-independent).

## 2. Principles (governance doctrine changes)

1. **Luna-first**: start at the cheapest model:effort the complexity allows;
   escalation happens **only on observed failure** (never on assumption).
   Replaces the "choose a model that can succeed comfortably, not the minimum
   viable model" doctrine (governance.md:160) — the ladder provides the
   comfort margin, so a conservative start only pays the top-tier premium on
   every iteration. Rationale: a few early cheap failures cost less than
   permanent top-tier usage at luna=4% of sol.
2. **CRITICAL exception**: security / payment / auth / data-loss US never
   start below sol:high. No cost-lane question is asked for CRITICAL.
3. **Effort before model tier (luna only)**: within luna, escalate effort to
   max before jumping models. Terra/sol keep the v0.22.5 xhigh ceiling for
   ladder progression.
4. **Judging lanes never downshift below evidence**: verifier and consensus
   tiers are scaled by complexity using judgment-task benchmarks (§1 item 3),
   not by the worker's luna-first rule.
5. **Environment failures do not climb the ladder**: when failure_category is
   environment/tooling/capacity (including model-capacity stalls and
   **verifier safety-classifier refusals** — opus-5/fable-5 cyber safeguards
   can false-positive on benign security US), the leader retries with the
   SAME model after environment recovery. Refusal is never a verdict.
6. Imported from adaptive-delegation as *patterns only*: (a) cheap-tier-first
   with evidence-gated escalation, (b) effort-before-model (applied to luna),
   (c) terra:max as latency-insensitive quota-first lane. Objective Lock,
   fixed role bindings, and the attempts-ledger machinery are NOT imported
   (Codex-specific / overweight).

## 3. Lane decision (brainstorm-time, Step 7)

When the complexity evaluation finds any HIGH-or-above US, the leader asks
**one question** during brainstorming (logged as `[DECIDE] ... phase=lane`):

> This campaign contains HIGH-complexity US. Execution profile?
> - **Long-term / cost lane (recommended for unattended/overnight
>   campaigns)**: sol-grade quality is absorbed by terra:max; minimizes Sol
>   usage; iterations may be slower.
> - **Speed lane**: HIGH US go straight to sol; no terra hop.

- CRITICAL rows and all judging lanes (verifier/consensus) are identical in
  both lanes.
- Non-interactive equivalent: `--worker-model` override (parser unchanged).
- Campaigns with only LOW/MEDIUM US: no question (lanes are identical there).

## 4. Model configuration (final)

### 4.1 Per-complexity table

| Complexity | Worker (cost lane) | Worker (speed lane) | Per-US Verifier (claude) | Per-US Consensus (codex) |
|---|---|---|---|---|
| LOW | luna:high | luna:high | sonnet-5:high | luna:max |
| MEDIUM | luna:xhigh | luna:xhigh | opus-5:low | terra:high |
| HIGH | luna:max | sol:medium | opus-5:high | sol:medium |
| CRITICAL | sol:high | sol:high | opus-5:max | sol:high |

### 4.2 Campaign-wide gates (lane/complexity independent)

| Role | Model | Note |
|---|---|---|
| Final Verifier | claude-fable-5:max | CRITICAL additionally requires human gate |
| Final Consensus | gpt-5.6-sol:xhigh | raised from sol:high (final verification = high reasoning; 1 call/campaign so cost/latency negligible; max rejected — unproven marginal utility over xhigh while wall-clock is real, and the fable-5:max claude gate runs in parallel) |

### 4.3 Per-cell rationale (abbreviated; sources in Appendix)

- **Worker LOW/MEDIUM luna:high/xhigh**: luna:high ties terra:medium (old
  MEDIUM default) on AA index 46 at 1/10 cost; xhigh gives MEDIUM one tier of
  differentiation (index 49 ≈ terra:high ≈ sol:low cluster).
- **Worker HIGH luna:max (cost lane)**: DeepSWE long-horizon luna:max 67±4 vs
  sol:max 73±3; failure auto-escalates. Speed lane starts sol:medium
  (pre-change behavior).
- **Verifier LOW sonnet-5:high**: clear-AC detection; sonnet-5 (AA 53) ample;
  60% of opus cost.
- **Verifier MEDIUM opus-5:low**: tier-up-effort-down; official Anthropic
  guidance: opus-5 code review "stays accurate at lower effort".
- **Verifier HIGH opus-5:high**: official minimum for intelligence-sensitive
  work.
- **Verifier CRITICAL opus-5:max**: AA tie with fable-5:max at half price;
  "max when correctness matters more than cost".
- **Consensus LOW luna:max**: LOW worker failures are self-evident; 4% cost;
  claude verifier remains primary oracle.
- **Consensus MEDIUM terra:high**: terra's strongest vendor signal is exactly
  bounded research/debugging (67.8 vs sol 68.3) at 0.4 cost.
- **Consensus HIGH sol:medium**: review-task tier gap (69.7 vs 52.5) rules
  out terra; medium suffices for a secondary cross-check and dominates
  terra:xhigh/max on AA.
- **Consensus CRITICAL sol:high**: money/auth judgment stays high-tier.

## 5. Escalation ladder (`src/node/models.json`)

Data-only change; both loaders (`get_next_model()` zsh /
`loadModelLadder()` Node) are schema-unchanged.

| Key | Old | New | Rationale |
|---|---|---|---|
| `gpt-5.6-luna:high` | → luna:xhigh | → **luna:max** | compressed default chain ("high, then max") — luna efforts cost the same, dense rungs only waste wall-clock |
| `gpt-5.6-luna:xhigh` | → terra:high | → **luna:max** | manual-start join point; effort-before-model |
| `gpt-5.6-luna:max` | → `""` | → **terra:max** | quota-first hop after luna ceiling (single terra hop — double-terra-failure cost warning respected) |
| `gpt-5.6-terra:max` | → `""` | → **sol:xhigh** | terra:max quality ≈ sol high~xhigh midpoint → escalating to sol:high would be lateral; go above |

Kept as-is: `luna:low→medium→high`, `terra:low→…→xhigh→sol:high`,
`sol:low→…→xhigh` (final ceiling), dead-ends `sol:max`, `sol:ultra`,
`terra:ultra` (manual starts without progression). Resulting chains:

```
Cost lane:  luna:high → luna:max → terra:max → sol:xhigh (ceiling)
            (MEDIUM joins at luna:xhigh → luna:max → …)
Speed lane: sol:medium → sol:high → sol:xhigh (ceiling)
```

Known accepted edge: a speed-lane LOW/MEDIUM US that fails twice reaches the
slow terra:max hop; documented, mitigations are `--lock-worker-model` or a
manual sol start. CHANGELOG must note this is a **partial reversal of
`32d181a`** (luna-only max reinstatement + terra:max lane), justified by the
2026-07-30 price cut which postdates the operational evidence behind 32d181a.

## 6. Effort-aware iteration timeout

Worker effort suffix scales the effective per-iteration timeout
(task budget, counted from first_progress_ts), in BOTH leaders:

| Worker effort | Multiplier | Default 600s → |
|---|---|---|
| `:xhigh` | ×1.5 | 900s |
| `:max` | ×2.0 | 1200s |
| otherwise | ×1.0 | 600s |

- Applies to the user-supplied `ITER_TIMEOUT` value as well (documented).
- Recomputed each iteration from the current (possibly escalated) worker
  model string.
- Heartbeat/prompt-stall mechanisms are wall-clock background loops —
  verified unaffected; no changes there.
- Implementation sites: zsh leader task-budget computation
  (`lib_ralph_desk.zsh` / `run_ralph_desk.zsh` ITER_TIMEOUT consumers) and
  the Node leader equivalent (`campaign-main-loop.mjs`).

## 7. Campaign cost summary (lightweight — no new infrastructure)

The leader appends to the final campaign report, computed at report time from
existing per-iteration Tokens data (status.json / campaign.jsonl):

- **Sol-equivalent cost total** = Σ(iteration tokens × model factor
  {sol 1.0, terra 0.4, luna 0.04}), codex legs only (claude pool is a
  separate subscription; claude iterations listed by count, not converted).
- **Escalation count** (ladder moves) and final model reached per US.

Purpose: per-campaign evidence of whether luna-first actually saves —
mirrors adaptive-delegation's "evidence-seeking" stance without importing
its ledger machinery.

## 8. Files touched (implementation inventory)

| File | Change |
|---|---|
| `src/node/models.json` | 4 ladder entries (§5) |
| `src/commands/rlp-desk.md` | Step 7 mapping tables → §4.1; lane question (§3); worker-selection rationale rewrite; flag reference (terra:max quota lane, timeout multiplier); verifier model names updated to Claude 5 family (sonnet-5/opus-5; replaces opus-4-8 references) |
| `src/governance.md` | §4 doctrine rewrite (§2 items 1-5); consensus model table (lines ~940-957) → luna:max/terra:high/sol:medium/sol:high + final sol:xhigh; environment-failure & verifier-refusal non-escalation |
| `src/model-upgrade-table.md` | rewrite: new chains, lane concept, per-cell rationale digest, v0.22.5-policy paragraph update |
| `src/scripts/lib_ralph_desk.zsh`, `src/scripts/run_ralph_desk.zsh` | effort-aware timeout multiplier (zsh leader) |
| `src/node/runner/campaign-main-loop.mjs` (+ util if needed) | effort-aware timeout multiplier (Node leader) |
| tests (`tests/**`) | ladder determinism tests updated for §5 transitions (both loaders); timeout multiplier unit tests; per governance §1 every case-statement branch and engine/model combination tested |
| `CHANGELOG.md` | feature entry + explicit partial-reversal note for 32d181a |

Reminder (project CLAUDE.md): changes to `src/commands/rlp-desk.md` /
`src/governance.md` require the 3-scenario Self-Verification Gate before
commit; runtime-file changes require full local sync (banner-aware §4.5
verification) after commit.

## 9. Out of scope

- adaptive-delegation Objective Lock / role bindings / attempts ledger.
- Automatic lane switching mid-campaign (lane is fixed at brainstorm; manual
  override via flags only).
- Dollar-denominated billing integration; claude-pool cost conversion.
- Any change to CB thresholds, consensus enable/disable logic, or claude-only
  (haiku/sonnet/opus) ladder — already cheapest-first.

## Appendix — evidence sources

- OpenAI 2026-07-30 price update (Sol $5/$30, Terra $2/$12, Luna $0.20/$1.20):
  openai.com/index/advancing-the-price-performance-frontier-with-gpt-5-6/
- adaptive-delegation dossier: `docs/research/MODEL_ROUTING_EVIDENCE.md`
  (captured 2026-08-02) — AA index clusters (luna:high≈terra:medium=46;
  luna:xhigh≈terra:high≈sol:low=49; terra xhigh/max dominated by sol
  medium/high), DeepSWE v1.1, CodeRabbit sol/terra benchmark, Internal
  Research Debugging, Terminal-Bench 2.1, DCInside practitioner survey,
  Codex incident issues 33816/32162/32389/32406/33267.
- Artificial Analysis: Opus 5 (max) 61 ≈ Fable 5 (max) 60, $2.03 vs
  $2.75/task (artificialanalysis.ai/articles/opus-5, 2026-07-24); Sonnet 5
  (max) 53 (AA X posts, 2026-07). No published fable-low/medium vs opus-max
  head-to-head exists — CRITICAL verifier choice is adjacent-data inference
  (~65-70% confidence), revisit if such a benchmark appears.
- Anthropic official (claude-api skill, cached 2026-06-24): Claude 5 pricing;
  opus-5 review "stays accurate at lower effort"; "max when correctness
  matters more than cost"; fable-5 low often exceeds *prior-generation* max;
  opus-5/fable-5 cyber-safeguard refusal semantics.
