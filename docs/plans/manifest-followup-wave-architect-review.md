# Architect Review — `manifest-followup-wave.md`

**Reviewer:** ralplan-architect (RALPLAN consensus, step 3)
**Repo:** /Users/plletdata/dev/rlp-desk · **Branch:** fix/install-manifest-consumers (tip 251f766)
**PRD reviewed:** `.omc/plans/manifest-followup-wave.md`, sha256 `bd1bf77f94f9adfb2bb898a3e7e957b39d5cabc4ae02ae6d460e8899c7e840b2`, 325 lines, mtime 09:47:46
**Method:** read-only. Every line reference verified independently against the code; the planner's numbers were not taken on faith. Four were wrong.

---

## VERDICT: **AMEND** — 8 amendments

The plan is strong. Both self-corrections (Correction 1 on `OMX_STATE_ROOT`, Correction 2 on `_bug8_autocommit` scoping) are **verified correct**, and US-005 reproduces exactly with no changes needed. But two USs have acceptance criteria that cannot be satisfied as written, and one SV-gate claim is false in a way that changes sequencing.

### Amendment index

| # | US | Label | Summary |
|---|---|---|---|
| A1 | 001 | **[DESIGN-CHANGE]** | AC1 unsatisfiable — native leader has no `--disable plugins` to be "in addition to" |
| A2 | 001 | **[CITATION-FIX]** + minor [DESIGN-CHANGE] | Node literal is in a different file; that file is manifest-shipped |
| A3 | 001, 003 | **[DESIGN-CHANGE]** | Node leader hard-errors at entry — "both leaders" means zsh + native |
| A4 | 003 | **[DESIGN-CHANGE]** | `stop` is live in an SV-gated file — "US-001 only pays the gate" is false |
| A5 | 003 | **[CITATION-FIX]** + [DESIGN-CHANGE] | AC5 writer list: wrong file, and 2 of 4 sites missing |
| A6 | 002 | **[CITATION-FIX]** + [DESIGN-CHANGE] | AC3 needs an implementation constraint; 2 line ranges wrong |
| A7 | 002 | **[DESIGN-CHANGE]** | Threat model misidentified; deterministic Option D missing |
| A8 | 004 | **[DESIGN-CHANGE]** | AC set not total over the 3 terminal states; 2 further issues |

Pure-citation content is confined to the line numbers inside A2, A5, A6. Everything else changes the work.

---

## ⚠️ ARCHITECT SELF-CORRECTION — 2026-08-10

*Issued after the planner (ralplan-planner) challenged A4's framing during consensus. Their challenge was correct. The original A4 text below is left intact rather than rewritten; this section supersedes it on two points. **A4's action and its SV-gate consequence both stand** — only the stated mechanism and one sub-clause change.*

### C1 — A4's mechanism claim was WRONG (framing superseded)

A4 below asserts that `stop=` at `src/commands/rlp-desk.md:554-556` is a mis-named iter-signal key and *"is the generator of the recorded incident."* **That is incorrect.**

`stop=` there is a correctly-named reference to a real, separate channel — `## Stop Status` in memory.md. Verified:

- `src/scripts/init_ralph_desk.zsh:1191-1192` seeds `## Stop Status` with value `continue`
- Five consumers read it: `src/scripts/run_ralph_desk.zsh:2975`, `src/node/prompts/prompt-assembler.mjs:126`, `src/governance.md:852`, `src/node/init/campaign-initializer.mjs:236`, `src/commands/rlp-desk.md:496`
- `src/commands/rlp-desk.md:553` is literally *"**⑥ Read memory.md again**"* — the `stop=` bullets at `:554-556` sit inside that step's scope, and `:557` separately says *"Also read `iter-signal.json` for `us_id`"*

**Correct framing (the planner's, adopted):** this is **unlabelled adjacency**, not a mis-named key. The memory.md-channel bullets sit directly above the iter-signal line with no channel marker, and the two channels share the value vocabulary `continue|verify|blocked`, so a reader can carry `stop=` across. That makes it a *plausible* generator of the `verification-history.md:94` incident, **not a proven one**. The planner's refusal to over-claim was right: asserting an unproven mechanism with confidence is precisely the failure US-001 exists to correct.

### C2 — WITHDRAWN: "add `verify_partial` to the `stop=` bullets"

The A4 amendment paragraph below instructs adding `verify_partial` to `:554-556`. **That instruction is withdrawn — implementing it would inject a bug.**

Once `stop=` is understood as a distinct channel, adding `verify_partial` to it asserts a value that channel has no evidence of accepting.

> **C2-bis (2026-08-10, correction to C2 itself — raised by ralplan-planner, verified):** C2 originally read *"nothing in the tree defines Stop Status's legal value set … `rlp-desk.md:554-556` is the de facto only enumeration."* **That was wrong.** `docs/rlp-desk/protocol-reference.md` defines it in **two** places: `:20` (*"Parse 'Stop Status' section → continue/verify/blocked"*, the leader parse step) and `:59-65` — a memory.md schema block introduced *"Written by the Worker at the end of each iteration. **Must contain:**"* with `## Stop Status` / `continue | verify | blocked`. That second one **is** the worker-side contract I claimed did not exist.
>
> This **hardens** the withdrawal rather than weakening it: three independent documents (`protocol-reference.md:20`, `protocol-reference.md:65`, `rlp-desk.md:554-556`) already agree on a three-value set, so adding `verify_partial` would have **contradicted all three**, not merely gone beyond an unwritten contract.
>
> It also **changes revised-scope item 3 below.** The value set does not need *minting* — it needs **cross-referencing**. Creating a fourth authority in `signal-protocol.md` would manufacture exactly the multi-document drift the two-channel documentation exists to end. Planner's amendment adopted: `signal-protocol.md` documents the two channels as distinct and cross-references `protocol-reference.md` for the Stop Status value set, with `protocol-reference.md` winning on any disagreement.

### C3 — REPLACEMENT finding (stronger, and it re-grounds A4)

`grep -n verify_partial src/commands/rlp-desk.md` → **zero hits.** The term appears nowhere in the native leader's instructions. It exists only in `src/governance.md:1110-1125`, which describes "the runner" — the zsh leader.

Meanwhile the **shared** worker prompt at `src/scripts/init_ralph_desk.zsh:782` authorizes workers on *either* leader to emit `"status": "continue|verify|verify_partial|blocked"`. So a native-mode worker can legitimately signal `verify_partial` into a leader whose step-⑥ branch table enumerates three states and has no branch for it — **an unenumerated state in the leader's own instruction set.**

That is a genuine native-leader gap, squarely in US-003's territory (the iter-signal status contract), and it lands in the same SV-gated file. **So A4's action and gate consequence survive on better evidence than the original text gave.**

### Revised `rlp-desk.md` scope inside the US-001 commit

Supersedes the A4 amendment paragraph's scope:

1. **Label the channel** at `:554-556` (planner's disambiguation — adopted unchanged).
2. **Add a `verify_partial` branch to step ⑥'s *iter-signal* handling** — *not* to the `stop=` bullets.
3. ~~**Pin Stop Status's legal value set** in `docs/rlp-desk/signal-protocol.md` … nothing currently defines that value set anywhere.~~ — **SUPERSEDED by C2-bis.** Corrected form: `signal-protocol.md` documents the two channels as **distinct** and **cross-references `docs/rlp-desk/protocol-reference.md`** for the Stop Status value set rather than restating it; `protocol-reference.md` is authoritative if they ever disagree. Do **not** mint a new value-set authority — three documents already agree on `continue|verify|blocked`, and a fourth would create the drift this item exists to prevent.

### C4 — Affirming one planner decision (not a correction)

Under A1 the planner **refused** to add `--dangerously-bypass-approvals-and-sandbox` to `src/commands/rlp-desk.md:546`/`:605`, flagging it as a sandbox-posture change requiring separate approval. **That refusal is correct**, with positive evidence: the sv-oracle-nv native campaign reached PreToolUse blocking (11 blocks), meaning codex exec was actively attempting tool calls *without* that flag. Native codex functions under default posture today; adding the flag would be a posture change, not a parity fix.

---

## Amendments in detail

### A1 — US-001 AC1 is unsatisfiable for the native leader — **[DESIGN-CHANGE]**

AC1: *"…contains `--disable hooks` (when supported) **in addition to** the existing `OMX_STATE_ROOT=…` prefix and `--disable plugins`."*

The native leader has no `--disable plugins`:

- `src/commands/rlp-desk.md:546` — `codex exec --model <m> --reasoning-effort <r> <prompt>` — no `--disable plugins`, and no `--dangerously-bypass-approvals-and-sandbox` either
- `src/commands/rlp-desk.md:605` — same shape (verifier)
- `src/governance.md:678` — `codex -m <m> -c model_reasoning_effort=<r> --dangerously-bypass-approvals-and-sandbox <prompt>` — no `--disable plugins`
- `src/governance.md:738` — same

Repo-wide, the literal lives only in `src/scripts/run_ralph_desk.zsh` (8 launch strings) and `src/node/cli/command-builder.mjs:95`. In `src/commands/rlp-desk.md` it appears **once**, at `:550`, inside the explanatory sentence *"`--disable plugins` does NOT cover hooks.json native hooks"* — not in any launch string. `src/governance.md`: **zero occurrences**.

**Amendment:** split AC1 per leader, and state explicitly that the native-leader edit *also adds* `--disable plugins` (bringing native to parity with zsh). That is unstated scope today — an implementer will either bounce on the AC or silently narrow it. Also reconcile the two governance docs' invocation forms while in there: `rlp-desk.md` uses `codex exec --model/--reasoning-effort`, `governance.md` uses TUI `codex -m/-c model_reasoning_effort`. Pre-existing drift, but US-001 edits both files anyway.

### A2 — Node literal is in a different file — **[CITATION-FIX]** + minor [DESIGN-CHANGE]

PRD: *"`src/node/runner/campaign-main-loop.mjs` `buildLaunchCommand` (~502)"*.

Verified: `buildLaunchCommand` is at `src/node/runner/campaign-main-loop.mjs:493` and it **delegates**. The literal is `src/node/cli/command-builder.mjs:95`:

```js
parts.push('--disable', 'plugins', '--dangerously-bypass-approvals-and-sandbox');
```

Editing campaign-main-loop.mjs alone changes nothing.

**Design piece:** add `src/node/cli/command-builder.mjs` to the files table. It is `src/node/MANIFEST.txt:1`, so it carries the CLAUDE.md local-sync obligation the PRD's table implicitly tracks. Also note `src/node/cli/command-builder.mjs:5` is `const CODEX_BIN = 'codex'` — a **bare name**, PATH-resolved inside the tmux pane — whereas zsh embeds the absolute path from `command -v codex` (`src/scripts/run_ralph_desk.zsh:1846`). A Node-side probe would be probing a potentially different binary than the pane executes.

### A3 — the Node leader is unreachable — **[DESIGN-CHANGE]**

`src/node/run.mjs:891` — `--mode agent` (the Node-leader direct-CLI alpha) **hard-errors** per ADR-001. `src/node/run.mjs:906`: *"The `src/node/**` engine modules are retained; only the direct-CLI `--mode agent` entry point was removed."* `--mode tmux` shells out to the zsh runner.

So `buildLaunchCommand` / `campaign-main-loop.mjs` is **not a production leader**. The two live leaders are **zsh** and **native (prose)**.

- US-001: the Node edit is dead-code parity maintenance. Cheap and worth doing to keep the manifest honest, but it cannot be one of AC1's "either leader", and AC5's E2E cannot exercise it.
- US-003: the PRD's *"both leaders already read `.status` (…`campaign-main-loop.mjs:2642`)"* cites a dead leader as evidence of live coverage.

**Amendment:** label the Node work parity-only in both USs, and re-scope "both leaders" to zsh + native everywhere it appears.

### A4 — `stop` is live in an SV-gated file; the gate claim is false — **[DESIGN-CHANGE]**

> **⚠️ PARTIALLY SUPERSEDED — see ARCHITECT SELF-CORRECTION (2026-08-10), items C1-C3, above.**
> The mechanism claim in this section ("`stop=` is a mis-named iter-signal key … the generator of the recorded incident") is **wrong** — `stop=` is a correctly-named reference to the separate memory.md `## Stop Status` channel. The `verify_partial` sub-clause in the Amendment paragraph is **withdrawn**. The amendment's *action* and *SV-gate consequence* stand, re-grounded on C3. Text preserved below as issued.

US-003 frames `stop` as a legacy key from precedent files. It is **currently documented in the native leader's own instructions** — `src/commands/rlp-desk.md:554-556`:

```
- `stop=continue` → go to ⑧
- `stop=verify`   → go to ⑦
- `stop=blocked`  → write BLOCKED sentinel, stop
```

Meanwhile the worker contract at `src/scripts/init_ralph_desk.zsh:782` tells workers to write `{"status": "continue|verify|verify_partial|blocked"}`. The native LLM leader is instructed in `stop=` vocabulary while its worker writes `status`. **That is the generator of the recorded incident** (`docs/rlp-desk/verification-history.md:94`, confirmed verbatim), not a stale artifact.

Fixing it edits `src/commands/rlp-desk.md` — an **SV-gated** file. So the PRD's table row *"⚠️ YES | rlp-desk.md, governance.md | **US-001 only**"* is **wrong**.

**Amendment:** fold the US-003 prose correction into the US-001 commit so the 3-scenario SV gate is paid once — precisely what decision-driver D3 intends. If US-003 lands separately it re-triggers the gate. Tolerant-read remains as the *secondary* fix (defence for in-flight precedent files), not the primary one. ~~(`rlp-desk.md:554-556` also omits `verify_partial`, the same defect as `docs/rlp-desk/protocol-reference.md:113`.)~~ — **WITHDRAWN, see C2.** Do not add `verify_partial` to the `stop=` bullets; use the revised 3-item scope in the SELF-CORRECTION section instead. (The `protocol-reference.md:113` half of that parenthetical is unaffected and still stands — it genuinely omits `verify_partial` from the iter-signal schema.)

### A5 — US-003 AC5's writer list is wrong file and incomplete — **[CITATION-FIX]** + [DESIGN-CHANGE]

PRD cites `lib_ralph_desk.zsh:1489` and `:3670`. Verified:

- `src/scripts/lib_ralph_desk.zsh:1489` is `_verify_pane_alive` — unrelated.
- `src/scripts/lib_ralph_desk.zsh:3670` is inside `write_blocked_sentinel`'s JSON, which has **no `status` key at all**.

Right line numbers, wrong file. All four iter-signal synthesizers are in `src/scripts/run_ralph_desk.zsh`:

| Line | Site |
|---|---|
| `:1489` | codex-exit synth |
| `:3670` | A4-fallback synth |
| **`:4235`** | sequential-final-verify signal replace — **missed by the PRD** |
| **`:5417`** | D-16 leader-finalize signal — **missed by the PRD** |

**Design piece:** AC5 says *"every leader-synthesized signal … writes `status`"*. Four sites, not two — the AC's scope grows.

### A6 — US-002 AC3 needs an implementation constraint; line ranges wrong — **[CITATION-FIX]** + [DESIGN-CHANGE]

Verified structure in `src/scripts/run_ralph_desk.zsh`:

| What | PRD says | Actual |
|---|---|---|
| `comm -23` subtraction | 1412-1416 | **1413** |
| `-z` no-op guard | — | **1417** |
| array build | — | **1428** |
| empty-array BLOCK | 1436-1440 | **1433** (`if`) / **1434** (`log_error`) / **1436** (`return 1`) |
| `CAMPAIGN_PREEXISTING_DIRTY` snapshot | 5116 | **5127** (`typeset`) / **5135** (assignment) |

**Design piece:** AC3 holds **iff** `ITER_PREEXISTING_DIRTY` is folded into the `comm -23` at `:1413`, producing `_bug8_worker_files` *before* the `-z` test at `:1417`. If an implementer instead filters `_bug8_add` after `:1428`, AC3 breaks — and worse than "hits the BLOCK": for an empty string, `"${(@f)_bug8_worker_files}"` yields **one empty element** in zsh, so `${#_bug8_add}` is `1`, not `0`. The empty-array BLOCK at `:1433` never fires and execution falls through to `git diff --quiet HEAD -- ''`. The existing D-20 comment (*"the upstream `[[ -z … ]]` guard already makes this unreachable"*) is load-bearing for AC3, and AC3 depends on it silently. Say it out loud in the AC.

### A7 — US-002's threat model is misidentified; add Option D — **[DESIGN-CHANGE]**

`src/scripts/run_ralph_desk.zsh:4911-4930`: the runner lock is `RUNNER_LOCKFILE_PATH="$DESK/logs/.rlp-desk-runner-$ROOT_HASH.lock"` (declared `:526`) — **per project root, exclusive**. A duplicate runner prints *"duplicate rlp-desk runner detected on this project root"* and `exit 1`s.

**So two zsh campaigns on one checkout are already impossible.** The US title ("a concurrent campaign's work") describes a case that cannot arise between two tmux leaders. The dd0e6d9 foreign editor was either a human or a **native-mode** campaign — and the native leader acquires **no runner lock at all** (no lock acquisition anywhere in `src/commands/rlp-desk.md` or `src/node/run.mjs`).

That asymmetry is the actual defect, and the PRD never names it.

**Option D (missing):** register the native leader in the same per-ROOT lock namespace (advisory registry, not exclusive), and have the zsh leader **downgrade F-8 from auto-commit to the existing `_bug8_record_carryover` path** (`src/scripts/run_ralph_desk.zsh:1283`, consumed at `:3000-3005`) whenever another live leader is registered on the same git toplevel. Deterministic, closes the cross-mode case **including the same-worker-window race**, costs no SV gate, and reuses an already-tested graceful continue. It does not help against a human editing concurrently, so it **complements** Option A rather than replacing it. Ship both, or record why not — it is also what would make the US title honest, which Option A alone does not.

### A8 — US-004: the AC set is not total, plus two more — **[DESIGN-CHANGE]**

**(i) Missing terminal state.** `src/scripts/run_ralph_desk.zsh:3396-3398` (`cleanup`) has **three**: COMPLETE / BLOCKED / **TIMEOUT** (neither sentinel — max iterations, or SIGINT/SIGTERM mid-loop). AC1 covers COMPLETE, AC2 covers BLOCKED, **nothing covers TIMEOUT**. Option B's prose ("`campaign-exit` otherwise") is total, but no AC tests it — an implementer reading only the ACs can plausibly emit `unknown` there, reintroducing the exact bucket this US exists to delete. Add the AC, and reuse `cleanup`'s existing three-way sentinel test rather than writing a second one, so the two cannot drift.

**(ii) AC1 tests one of two predicates.** It says *"reaches final verification **and** exits COMPLETE"*. Those are different things, and `-f COMPLETE_SENTINEL` only tests the second. There is a real subsystem to derive from (`run_sequential_final_verify` at `:4358`, `_final_verify_one_us` at `:4225`, `FINAL_VERIFY_MAX_ATTEMPTS` at `:442`). Option A was rejected for *"lying on a BLOCKED exit"*; the same lie is available to Option B in the COMPLETE-without-final-verify shape. Pick one predicate and make AC1 say it.

**(iii) Latent duplicate-iteration rows.** `write_cost_log` is called in-loop at `src/scripts/run_ralph_desk.zsh:6425` and again from the trap with the same `${ITERATION}`. On any exit path that passes `:6425` first — e.g. the stale-context BLOCK at `:6443` — two rows exist for one iteration, and the renderer sums `estimated_tokens` across all rows (`src/scripts/lib_ralph_desk.zsh:2140-2260`). Observed logs happen to be clean (`sv-oracle` 2/3/4/5, `g-dogfood` 2/3, all unique), so this is latent — but US-004 converts a duplicate `unknown` into a duplicate *named* bucket that reads as authoritative. AC6 ("exactly one exit row per campaign") does not catch it.

**Also:** phrase AC4 as "absent-or-`unknown`". `.rlp-desk/logs/v0230-polish/cost-log.jsonl` contains a row with the `us_id` key **absent entirely** (pre-field schema). `jq -r '.us_id // "unknown"'` at `src/scripts/lib_ralph_desk.zsh:2176` handles it, so AC4 is satisfiable — just untested as written.

### Additional residual amendments (not counted in the 8)

**Probe hardening, US-001.** Residual #1 is stated backwards. It says the probe *"degrades to today's behaviour if `hooks` disappears."* The dangerous direction is the opposite: the probe runs **once** at leader init; campaigns run for hours. `_CODEX_NO_UPDATE_FLAG` (`src/scripts/run_ralph_desk.zsh:129-133`) suppresses the update *dialog*, not an operator running `codex update`. A stale-true probe against a newly-installed binary that dropped the name means **every subsequent launch hard-errors** — mid-campaign total outage, not graceful degradation. Mitigation worth one AC: on codex launch failure, detect `Unknown feature flag` and retry once with the flag stripped, clearing `_CODEX_NO_HOOKS_FLAG` for the rest of the run.

**Pin the probe predicate.** AC2 says "does not advertise a `hooks` feature flag" — right in spirit, unpinned in practice. The predicate must be **name-presence in column 1 of `codex features list`, not state/value**: verified that `codex --disable apply_patch_freeform features list` **succeeds** even though that flag's state is `removed`. A `stable`/`true` parse would wrongly drop the flag on a future CLI where `hooks` goes `removed`-but-accepted.

---

## Steelman antithesis

### Strand (a) — *"`--disable hooks` kills safety the operator wants"* → **WITHDRAWN**

Checked the surface rather than assuming. `/opt/homebrew/lib/node_modules/oh-my-codex/dist/hooks/` contains exactly: `agents-overlay`, `codebase-map`, `deep-interview-config-instruction`, `explore-routing`, `keyword-detector`, `keyword-registry`, `prompt-guidance-contract`, `prompt-session-provenance`, `session`, `task-size-detector`, `triage-*`. **Zero safety or guard enforcement.** The `permissionDecision: "deny"` machinery in `dist/scripts/codex-native-hook.js` is generic relay plumbing, not a policy engine — the one decision that fired was deep-interview's. Nothing protective is lost. The objection fails; withdrawn.

One real cost the PRD should name instead of claiming "zero operator-state contact": `prompt-session-provenance.js` + `session.js` telemetry for campaign codex sessions (plausibly what feeds `~/.codex/delegation-attest/`). Small, but real.

### Strand (a′) — probe design → **SURVIVES; the probe is more load-bearing than stated**

Verified live on codex-cli 0.147.0:

- `codex --disable <unknown> features list` → `Error: Unknown feature flag: <unknown>`. An unprobed flag is a **total outage**, so the gate is required, not defensive padding. The PRD is right and understates its own case.
- `codex features list` costs **~40 ms**, no auth, no network. Safe at init.
- **`codex exec` does accept `--disable`** as a subcommand option (verified in `codex exec --help`), so AC5's command form is valid. Worth pinning in a test, because `--disable` is *also* a global option — `codex --disable hooks exec …` and `codex exec --disable hooks …` both work, but only by luck, and the two positions are trivially confusable.

### Strand (b) — US-002 per-iteration baseline → **SURVIVES on AC3's precondition; "closes dd0e6d9" is overstated**

Detail in A6/A7. Short form: F-8 fires at the **end** of the worker leg, so the surviving window is the entire worker leg of the current iteration — the single longest contiguous phase, and precisely when a human is most likely to be editing (campaign churning, owner spots something, fixes it). Per-iteration baselining removes iterations 1..N−1 and leaves the highest-probability window intact. The PRD's cons line concedes this; its Option-A framing and the US title do not.

### Strand (c) — US-004 phase derivation at trap time → **derivable; ordering safe; ACs incomplete**

The trap is `trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT INT TERM HUP` (`src/scripts/run_ralph_desk.zsh:4951`). `_emit_final_cost_log` (`:246-255`) runs **before** `cleanup`, and the sentinels are written by the loop — `cleanup:3396` only *reads* them. So `[[ -f "$COMPLETE_SENTINEL" ]]` / `[[ -f "$BLOCKED_SENTINEL" ]]` are both on disk and readable at emit time. **The mechanism is sound.** The gaps are in the AC set, not the design (A8).

---

## The tradeoff tension

**US-002 Option A buys a real narrowing at genuinely low cost — and pays for it in determinism, in the one place the PRD's own principles say not to.**

Guiding principle 5 is *"deterministic leader beats prompted LLM."* Driver D2 is *"git-history integrity under concurrency."* Option A leaves that integrity property — "never commit another actor's work" — enforced by a **shrinking but nonzero race window**, and the window that survives is the largest one. A probabilistic mitigation is being accepted for an integrity defect because the deterministic option (`--worktree`) costs UX and is tmux-only.

That is a defensible trade. But it should be recorded as **a deliberate acceptance of a residual integrity race**, not as a fix — and A7 shows a deterministic option exists that the PRD never weighed.

**Second tension, smaller:** US-001 accepts a hard dependency on a third-party feature-flag name in the launch path of every codex leg. `--disable plugins` already carries this exposure, so this doubles rather than introduces it — but it doubles it in a construct that is **fail-closed** (total outage), not fail-open. Right direction for safety, wrong direction for liveness, and liveness is driver D1. The probe plus the strip-and-retry mitigation is what keeps that trade acceptable.

---

## Synthesis — recommended sequencing

1. **US-001 + the US-003 `rlp-desk.md` prose correction as ONE commit.** Both land in SV-gated files; batching pays the 3-scenario gate once, exactly D3's intent. Apply A1, A2, A3, A4, plus the two probe-hardening residuals.
2. **US-003 remainder** (tolerant-read, `signal-protocol.md` contract section, `protocol-reference.md:113`) — no gate once the prose fix has shipped with US-001. Apply A5.
3. **US-002** with A6 (AC3 constraint + corrected lines) and A7 (evaluate Option D; ship alongside A or record why not).
4. **US-004** with A8.
5. **US-005 ships as written** — no amendments.

---

## Verified clean — no amendment needed

- **All 8 zsh launch sites** are exactly as listed (`2901, 3096, 3268, 4008, 4266, 4650, 5499, 5997`), all already carrying `--disable plugins`. **Consensus verifiers are covered** — `:4650` is the parallel-consensus codex leg, `:4266` the final verifier. `--disable hooks` affects them identically, and **no zsh launch site is missed**.
- **Correction 1's root-cause chain reproduces** — session id match, `skill-active-state.json` keyword provenance, `~/.codex/hooks.json` 8-event registration.
- **Correction 2 reproduces** — `_bug8_autocommit` (`run_ralph_desk.zsh:1258`) uses `git --literal-pathspecs add -- "${files[@]}"`, never `-A`; `_bug8_dirty` is tracked-only, so the untracked-evidence path is genuinely separate.
- **US-004's zsh-only scope claim is correct** — `src/node` has no cost-log emitter; `campaign-reporting.mjs` mentions `cost-log` only in comments (`:130`, `:169`, `:172`).
- **US-004's sv-oracle data reproduces exactly** — `{2,US-001} {3,US-001} {4,US-001} {5,unknown}`.
- **US-005 verified end to end** — blueprints 4 tracked / 4 fetched, plans 12 / 0, internal 0 / 0, all exact. `markdownDirectories()` at `scripts/install-manifest.js:78`, consumed as `dirPrefixes` at `tests/node/install-sh-manifest-parity.test.mjs:31`; the "escape hatch only" characterization is accurate. AC3/AC9's mutation-negativity requirement is the correct standard.
- **`src/scripts/init_ralph_desk.zsh` untouched — this claim HOLDS** across all five USs. `:782` already specifies `status` and `verify_partial` correctly; the drift is entirely in the docs, exactly as the PRD says.

**SV-gate exposure accuracy, summary:** the `init_ralph_desk.zsh` half of the claim is sustainable; the "US-001 only" half is not (A4).
