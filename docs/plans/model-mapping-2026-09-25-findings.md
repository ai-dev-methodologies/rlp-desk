# Model mapping re-derivation — measured facts and adversarial result (2026-09-25)

Status: **ANALYSIS ONLY. No file under `src/` was changed.** The candidate strategy
this exercise produced was REJECTED by its own adversarial pass. What survives is the
measured base, one falsified principle, and a list of owner decisions.

Method: measured catalogs -> 4-angle design panel -> 3 judges -> 5 adversarial lenses
-> 3 independent refuters (majority rule). 15 subagents, 0 errors.

## 1. Measured model facts (not recalled — read from the CLIs' own catalogs)

### Claude — signed catalog `~/.claude/cache/model-catalog`, doc v994, issued 2026-09-22, expires 2026-09-29

| alias / id | resolves to | efforts | list price in/out | note |
|---|---|---|---|---|
| `haiku` | `claude-haiku-4-5-20251001` | **none** | $1 / $5 | empty effort array — confirms the repo's bare-key choice |
| `sonnet` | `claude-sonnet-5` | low..max | $2 / $10 | |
| `opus` | **`claude-opus-5`** | low..max | $5 / $25 | the alias does NOT point at 5.5 |
| *(explicit only)* `claude-opus-5-5` | Opus 5.5 | low..max, default **medium** | $4 / $20, cache read $0.20 | listed FIRST in `main`; `min_claude_code_version: 2.1.280` |
| `fable` | `claude-fable-5-1` | low..max | $10 / $50 | `min_claude_code_version: 2.1.251` |

- Live probe on this machine (claude-code 2.1.280): `claude -p --model claude-opus-5-5 --effort low` → OK. Same for `claude-opus-5`, `claude-fable-5-1`.
- Adding `claude-opus-5-5` needs **zero recognition code**: `lib_ralph_desk.zsh:402` and `run_ralph_desk.zsh:526` both carry `haiku|sonnet|opus|fable|claude|claude-*`; Node uses `startsWith('claude-')`. Effort vocabulary in `_validate_model_level` is `low|medium|high|max|xhigh`, matching the catalog.

### Codex — `~/.codex/models_cache.json`, fetched 2026-09-25T11:21:30Z, codex-cli 0.156.1

| slug | prio | visibility | efforts | default |
|---|---|---|---|---|
| `gpt-6-astra` | 1 | list | low..**ultra** | medium |
| `gpt-reserve` | 3 | **hide** | low..max | medium |
| `gpt-5.6-sol` | 4 | list | low..ultra | low |
| `gpt-5.6-terra` | 7 | list | low..ultra | medium |
| `gpt-5.6-luna` | 8 | list | low..max | medium |
| `gpt-daybreak-blue-latest` | 10 | list | low..ultra | low |
| `gpt-5.5` | 12 | list | low..xhigh | medium — **retires 2026-10-14T19:00:00Z** |

Deltas against the repo's record:
- The whole `gpt-5.6` family is now labelled **"Older"**; `gpt-6-astra` is priority-1 frontier. The repo's entire cost lane sits on the older generation.
- `gpt-6-astra` **does** enumerate `ultra` now. `src/model-upgrade-table.md`'s "accepted but not in the server enumeration" is stale.
- **No catalog model supports `minimal`.** The repo's astra-only rejection is narrower than the truth.
- Two models the repo does not know: `gpt-daybreak-blue-latest`, `gpt-reserve`.
- `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark` are gone from the catalog — increment ① was right.

## 2. The falsified principle (the main result)

The candidate strategy compressed the claude ladder 7 → 4 rungs, arguing that rung
count is the scarce resource on both leaders. **On the production (zsh) leader this is
arithmetically false, and the sign of the effect is inverted.**

- `run_ralph_desk.zsh:7056` — `if (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD ))` is the **only** terminator, and it never consults ladder length.
- `lib_ralph_desk.zsh:840-844` — at `already_max` the function returns **early without resetting** `_SAME_US_FAIL_COUNT`, so the ceiling rung **absorbs the remaining budget**.
- Closed form: `iterations at the ceiling rung = EFFECTIVE_CB_THRESHOLD − 2×(rungs−1)`, plus 2 more when that lands on exactly 0 (the DEFECT-2a deferral, `run_ralph_desk.zsh:7085`).

Measured, default config (CB=6, consensus off, one US that never passes):

| | today (7 rungs) | candidate (4 rungs) |
|---|---|---|
| claude from `haiku` | 6 iterations: haiku×2, sonnet:medium×2, opus:low×2 | **8** iterations: + `claude-fable-5-1:max`×2 |
| codex from `luna:high` | 6 iterations = **0.96** cost units | **8** iterations = **2.96** units = **3.08×** |

Shortening the ladder does not remove iterations. It **relocates them onto the most
expensive rung**. Three independent refuters reproduced this with their own simulators.

With `--consensus final-only` (the repo's own recommended posture) CB doubles to 12 and
the effect worsens: the worker sits on `claude-fable-5-1:max` for **6** consecutive
unattended iterations instead of 2.

**The real lever on zsh is `CB_THRESHOLD`, not rung count.** Rung count only decides
*where* a fixed budget is spent.

## 3. Corrections to my own earlier findings

- I reported the Node block point as 18 consecutive failures. **Wrong — it is 21** from the shipped `haiku` default. 18 is the figure for the codex `luna:high` default. Node blocks when the walk steps *past* the ceiling, not when the ceiling is assigned.
- I framed ladder length as the budget on both leaders. It is the budget on **Node only**. The two leaders have *opposite* relationships between ladder length and spend.
- `run.mjs:985` (`deps.runCampaign`) is **unreachable from the CLI**: default mode is `tmux`, and all three valid modes return earlier (`931` tmux, `940` native, `965` agent hard-error). Whether the Native Agent() slash-command path exercises `campaign-main-loop.mjs`'s ladder is **unresolved** — do not build a case on Node numbers without settling it.

## 4. Verified pre-existing defects (independent of any strategy choice)

1. **Dead starts.** `opus:max`, `sonnet:high`, `sonnet:low` are not keys in `models.json`. Validation passes, then the worker reports `already_max` from iteration 1 and never escalates. Docs advertise effort-qualified starts; only the 7 spine keys exist.
2. **Stale `minimal` validation.** `_validate_model_level` accepts `minimal` for every codex model except astra; the catalog supports it on none.
3. **astra is in the worker escalation path today** — `gpt-5.6-sol:xhigh → gpt-6-astra:high` — while the spec says astra is judge-only. The repo's record is genuinely contradictory (spec §11 vs governance §4 + the 2026-09-08 applied decision); it was never adjudicated.
4. **`tests/sv-large-campaign/*.zsh` runs in no npm gate**, and it holds the densest ladder contract in the repo (22 assertions on the real lib functions).
5. **Neither behavioural suite can turn CI red** — the only blocking job is `sv-gate-fast`; `test:node` and `test:zsh` are `continue-on-error: true`.
6. **`claude-opus-5-5` carries `min_claude_code_version: 2.1.280`.** Putting it on the shipped ladder imposes a claude-code floor the repo declares nowhere.

## 5. What is actually true about Opus 5.5 here

- **Claude spend is not per-token in this harness.** `lib_ralph_desk.zsh:2949` prints `"Claude legs: N iteration(s) (subscription pool — no factor conversion)"`, and `cost_factors` is consumed for codex rows only (`lib_ralph_desk.zsh:2907`, `campaign-reporting.mjs:276`). The $4/$20-vs-$5/$25 gap therefore does **not** convert into a dollar saving this tool can show.
- **Token efficiency is unmeasurable here.** The only token figure the repo records is a byte-count ÷ 4 of three files, model-invariant by construction, and the report header says so: `## Cost & Performance (ESTIMATED — tmux/zsh bytes÷4 basis)`. Any "Opus 5.5 is more efficient" claim can be neither confirmed nor falsified by this repo before or after a change.
- **The defensible reason to name `claude-opus-5-5` is not price — it is alias ambiguity.** `opus` resolves to `claude-opus-5`, so today's four `opus:*` rungs silently run the previous-generation model. Pinning the explicit id removes that ambiguity. That claim needs no cost evidence.

## 6. Owner decisions (none of these are mine to make)

1. **Reopen handoff §2 row 1?** The claude worker ladder is the one item marked 사용자 확정·재논의 금지, and it was shipped uncommitted→committed this session. Any re-derivation overwrites it.
2. **Is `gpt-6-astra` judge-only or the worker ceiling?** The repo contradicts itself. Everything downstream on the codex lane depends on this.
3. **`CB_THRESHOLD`.** If the goal is to burn less on a failing campaign, this is the lever — not the ladder. Lowering it changes the ceiling-dwell arithmetic directly.
4. **Codex generation shift.** The 5.6 family is "Older". Do we shift the cost lane to the gpt-6 generation, or stay?
5. **`VERIFIER_MODEL: sonnet → sonnet:high`?** This is handoff §0 decision 2, still unanswered. Note the raise has a cost the strategy missed: `_effective_iter_timeout` denies effort-aware timeout scaling to non-worker roles, and a verifier timeout is a hard BLOCKING infra_failure.
6. **Declare a claude-code version floor?** Required if `claude-opus-5-5` goes on the shipped ladder.

## 7. Change-set size, if any ladder change is approved

Measured blast radius: **9 test files / 61 assertions**, not the 2 files assumed.
All three Self-Verification Gate trigger files (`src/commands/rlp-desk.md`,
`src/governance.md`, `src/scripts/init_ralph_desk.zsh`) are in scope, so CLAUDE.md's
mandatory 3-scenario real-Worker+Verifier gate fires. Four sync-gated docs encode the
old ladder verbatim.

---

# Part 2 — Redesign with CB_THRESHOLD as the lever (2026-09-26)

Status: **DESIGN ONLY. No file under `src/` changed.** Every number below is produced by
a simulator built from the REAL `get_next_model` + `check_model_upgrade` + the real
circuit-breaker block (extracted by content from `run_ralph_desk.zsh`, the same technique
`tests/test_defect2_*.sh` uses). Validated against the shipped config first: it reproduces
`6 iterations / plain block / haiku,haiku,sonnet:medium,sonnet:medium,opus:low,opus:low`.

## 1. The budget model (measured, not derived on paper)

```
total iterations for one stuck US = EFFECTIVE_CB_THRESHOLD        (+2 when the deferral fires)
EFFECTIVE_CB_THRESHOLD           = CB_THRESHOLD, doubled when CONSENSUS_MODE != off
ceiling dwell                    = EFFECTIVE_CB - 2 * hops_from_start, floored at 0
                                   (when it is exactly 0, DEFECT-2a grants the ceiling 2)
```

Consequences, and they are the whole design:

- **`CB_THRESHOLD` is the ONLY control over how much a stuck US burns.** Ladder length does not appear in the terminator (`run_ralph_desk.zsh:7056`).
- **Ladder length and start depth control only the MIX** — how much of that fixed budget lands on the most expensive rung.
- **Minimum burn for a ladder that actually dispatches its ceiling = `2*hops + 2`.**

## 2. Why the shipped config is mismatched

`CB_THRESHOLD=6` against a 7-rung ladder (6 hops from `haiku`) needs `2*6 = 12` to reach
the top. It has 6. Measured result: **6 iterations, block kind `plain`, top model actually
dispatched = `opus:low`, and `opus:medium` is promoted on failure 6 and never runs.**
Rungs 5-7 (`opus:high`, `opus:xhigh`, `claude-fable-5-1:max`) are unreachable in a default
campaign. The ladder is more than twice as long as the budget can walk.

## 3. Recommendation

**`CB_THRESHOLD` 6 -> 4, and shorten both spines to 3 rungs (2 hops).**

```
claude:  haiku              -> sonnet:high        -> claude-opus-5-5:high   (ceiling)
codex :  gpt-5.6-luna:high  -> gpt-5.6-luna:max   -> gpt-5.6-terra:max      (ceiling)
```

Measured, both postures, both engines:

| posture | shipped today | proposed |
|---|---|---|
| claude, consensus **off** | 6 iters, block `plain`, top run = `opus:low`, 1 wasted promotion | 6 iters, block `arch`, top run = `claude-opus-5-5:high`, **0 waste** |
| claude, consensus **on** | **14** iters | **8** iters (−43%) |
| codex, consensus **off** | 6 iters, 0.96 cost units, `plain` | 6 iters, **0.96** units (identical dispatch), `arch` |
| codex, consensus **on** | 12 iters, **6.96** units | 8 iters, **1.76** units (**−75%**) |

`arch` = the ceiling model was actually dispatched, got its own 2-attempt window, and
failed — an honest "we tried our best" BLOCKED. `plain` = blocked mid-ladder with the
last promotion wasted.

### Why 4 and not lower
With 2 hops, `effCB=4` gives dwell 0, so the DEFECT-2a deferral grants the ceiling its
window and the campaign runs all three rungs in 6 iterations. `CB=3` -> 3 iterations,
`CB=2` -> 2, both `plain`: the ladder becomes decoration. **4 is the lowest value at
which every rung still runs.**

### Why 3 rungs and not 4
The pinned invariant (`tests/test_us011_*.sh`, `tests/node/models-ladder.test.mjs`)
requires the shipped default to keep >= 2 hops, so 3 rungs is the floor. Measured at
`CB=4`: a 4-rung spine blocks at rung 2 (`plain`, ceiling never runs); a 2-rung spine is
clean but breaks the invariant. **3 is the unique length where `CB=4` dispatches the
whole ladder.**

### What this also fixes for free
`gpt-6-astra` leaves the worker escalation path (today `gpt-5.6-sol:xhigh -> gpt-6-astra:high`
is live and contradicts "astra is judge-only"). Astra keeps its judge seats
(`FINAL_VERIFIER_CODEX_MODEL`, `FINAL_CONSENSUS_MODEL`) unchanged. The 75% codex saving
under consensus is mostly this: today's consensus-on walk spends 4 of its 12 iterations
on astra at the 1.0 unknown-family fallback.

## 4. The one structural tension, measured

A short spine leaves a high-complexity start with little or no headroom. Measured on the
proposed claude spine:

| start | hops | effCB=4 | effCB=8 |
|---|---|---|---|
| `haiku` (shipped default) | 2 | 6 iters, `arch` | 8 iters, `arch` |
| `sonnet:high` | 1 | 4 iters, `arch` | 8 iters, `arch` |
| `claude-opus-5-5:high` (= the ceiling) | 0 | 4 iters, **`plain`**, whole budget on one model | 8 iters, `plain` |

This does **not** break the pinned test — that test reads only the shipped
`WORKER_MODEL` default, not per-complexity starts. It does contradict the doc doctrine
"start below the ceiling so the ladder retains upgrade headroom".

Two ways out, owner's pick:
- **(a) Accept it.** A CRITICAL campaign starts on the best model by design; if it fails 4 times, that is a spec problem and BLOCKED is the correct outcome. Simplest, no new machinery.
- **(b) Per-complexity CB.** Brainstorm already emits per-complexity options; add `--cb-threshold` set to `2 * hops_from_that_start`. Keeps every complexity clean at a low CB, at the cost of one more generated flag.

A longer shared ladder is NOT a way out — it re-creates the mismatch in §2.

## 5. Unchanged by this design

`WORKER_MODEL=haiku`, `FINAL_VERIFIER_MODEL=claude-fable-5-1`, all codex role defaults,
`CONSENSUS_MODE=off`, `cost_factors`, every recognition/normalization table. Adding
`claude-opus-5-5` still needs zero recognition code.

## 6. Owner decisions this design forces

1. **`CB_THRESHOLD` 6 -> 4.** 6 is a recorded confirmed decision ("CB_THRESHOLD 기본값 6 확정, 모델 업그레이드 경로 정합성"). The measurement now explains what 6 actually buys — and it is not what that note assumed.
2. **`claude-fable-5-1:max` leaves the worker ceiling** (it stays Final Verifier). Reopens handoff §2 row 1.
3. **`gpt-6-astra` is judge-only.** This design ships that reading; the repo's record is contradictory and has never been adjudicated.
4. **High-complexity headroom:** §4 option (a) or (b).
5. **claude-code floor 2.1.280** must be declared if `claude-opus-5-5` ships on the default ladder.
6. Still open from before: `VERIFIER_MODEL: sonnet -> sonnet:high` (and its verifier-timeout cost).

## 7. Change-set size

Unchanged from Part 1 §7: ~9 test files / 61 assertions, all three Self-Verification Gate
trigger files, four sync-gated docs. `CB_THRESHOLD` adds `run_ralph_desk.zsh:723`,
`src/node/run.mjs:52`, and the tests that pin the default 6.
