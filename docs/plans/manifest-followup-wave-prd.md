# PRD — `fix/install-manifest-consumers` follow-up wave

**Repo:** /Users/plletdata/dev/rlp-desk · **Branch:** fix/install-manifest-consumers (tip 251f766)
**Status: COMPLETE.** Code was read before planning. Two of your five premises did not survive contact with the artifacts (US-1, US-2) — corrections below, they change the fix.

---

## RALPLAN-DR

### Guiding principles (5)
1. **Evidence over premise.** Two supplied premises failed verification. The plan follows the artifacts.
2. **Surgical + SV-gate-aware.** Prefer `run_ralph_desk.zsh` / `lib_ralph_desk.zsh` / `src/node/**` / `tests/**` (no gate) over `src/commands/rlp-desk.md` / `src/governance.md` / `src/scripts/init_ralph_desk.zsh` (3-scenario SV gate). Exactly one US cannot avoid it.
3. **Tests are the spec.** Failing test first for every code US. Text-level guards over the leader sources are legitimate specs here (leaders are shell/markdown; the repo already does this in `install-sh-manifest-parity.test.mjs`).
4. **Never mutate operator state.** No writes/deletes/repointing of `~/.codex/**` or the project's own `.omx/state/**`.
5. **Deterministic leader beats prompted LLM.** Where the leader can compute the correct scope itself, don't ask the model to be careful.

### Decision drivers (top 3)
| # | Driver | Why it dominates |
|---|---|---|
| D1 | Campaign liveness with codex engines | US-1 is a hard stop: every write tool blocked, 11 blocks then abort. Nothing else matters if campaigns can't run. |
| D2 | Git-history integrity under concurrency | US-2 wrote another campaign's work into this branch under a misleading message. Silent, hard to unwind. |
| D3 | Cost of the SV gate | 3 full Worker+Verifier scenarios per governance touch. Governance edits must be batched into one US and justified. |

Contested issues get ≥2 bounded options in US-1 §Options, US-2 §Options, US-4 §Options, US-5a §Options. US-3 and US-5b are uncontested.

---

## CORRECTION 1 — US-1 premise was wrong

`OMX_STATE_ROOT` isolation **worked**. Evidence:

- `.rlp-desk/logs/sv-oracle-nv/runtime/omx-state/.omx/state/session.json` → `session_id: 019fe75c-23c9-7ae3-8a91-4646c6959920`, which **matches the codex session id in the worker log** (`iter-001.worker-codex-aborted.log:9`). The hook read *fresh, campaign-scoped* state — not the operator's stale tree.
- The blocking file is `.../sessions/019fe75c-…/skill-active-state.json` and it names its own cause:
  `{ "skill": "deep-interview", "keyword": "Don't assume", "source": "keyword-detector" }`
- The oh-my-codex **UserPromptSubmit keyword detector** scanned our worker prompt, hit `Don't assume.` (`iter-001.worker-prompt.md:10`, seeded from `src/scripts/init_ralph_desk.zsh:691`), and auto-activated deep-interview. `oh-my-codex/dist/hooks/keyword-detector.js` even exempts that exact phrase from negative-prefix suppression (`isNegativePrefixExemptImplicitKeyword`: `"don't stop"`, `"don't assume"`).
- Env precedence in `oh-my-codex/dist/mcp/state-paths.js` `getBaseStateDirWithSource()` is `OMX_TEAM_STATE_ROOT` > `OMX_ROOT` > `OMX_STATE_ROOT` > cwd. Ours won. There was no stale-state leak to neutralize.

**Consequence:** clearing stale state or exporting more root vars fixes nothing. The campaign trips the hook **with its own prompt, inside its own isolated root**. The fix must disable the hook surface.

## CORRECTION 2 — US-2 premise was imprecise

Leader-recovery does **not** do a broad `git add`. `_bug8_autocommit` (`run_ralph_desk.zsh:1258-1275`) uses `git --literal-pathspecs add -- "${files[@]}"`, commented "never `-A`, never a broadened path". The list is already scoped at `run_ralph_desk.zsh:1413-1416` — `:1412` is the `local` declaration, not the subtraction:

```
_bug8_worker_files = (git diff --name-only <base>)  MINUS  CAMPAIGN_PREEXISTING_DIRTY
```

The real defect: **`CAMPAIGN_PREEXISTING_DIRTY` is snapshotted once, at leader process start** (`run_ralph_desk.zsh:5135` — my first draft said `:5116`, which is wrong; `:5129` is a comment). The foreign `install.sh` edit landed *after* that snapshot, so the subtraction classified it as Worker output and swept it into `dd0e6d9`. The code already documents the sibling relaunch caveat as D-25 (`run_ralph_desk.zsh:1402-1411`). **Not "a concurrent campaign"** — a per-`ROOT_HASH` exclusive runner lock already makes two zsh campaigns on one checkout impossible; see US-002's threat-model correction.

Also: `_bug8_dirty` is `git diff --name-only <base>` = **tracked only**. So `3f27b54` (318-line *untracked* `tests/node/uninstall-manifest.test.mjs`) did **not** come from F-8 — it came from the prompted carryover path (recorded at `run_ralph_desk.zsh:1283`, consumed at `:3000-3005`). The "must still commit our own untracked evidence" requirement therefore lives on the *prompt* path, which US-2 must leave working.

---

# US-001 — Campaign codex workers must not be captured by the omx deep-interview hook
**Risk: CRITICAL** · blocks everything with `engine=codex` · **⚠️ TRIGGERS THE 3-SCENARIO SV GATE (unavoidable)**

### Problem
`~/.codex/hooks.json` registers `oh-my-codex/dist/scripts/codex-native-hook.js` on all 8 lifecycle events, globally. `--disable plugins` does not cover native hooks. `UserPromptSubmit` keyword-activates deep-interview from prose in our own prompt; `PreToolUse` then blocks every write tool for the rest of the session (`readActiveDeepInterviewStateForPreToolUse`). Observed: 11 blocks, worker aborted.

### Options
| Option | Mechanism | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. `--disable hooks` on every campaign codex launch** | `hooks` is a **stable codex feature flag**. Verified live: `codex --disable hooks --disable plugins features list` → `hooks … false`, `plugins … false`, exit 0 (codex-cli 0.147.0). | One token per launch site; kills the whole hook surface, not one keyword; symmetric with existing `--disable plugins`; zero operator-state contact. **Nothing safety-bearing is lost** — the hook surface is `agents-overlay`, `codebase-map`, `deep-interview-config-instruction`, `explore-routing`, `keyword-detector`, `keyword-registry`, `prompt-guidance-contract`, `prompt-session-provenance`, `session`, `task-size-detector`, `triage-*`; zero safety enforcement. The only real loss is **session provenance/telemetry** for campaign codex runs. (Architect stress-tested "this kills safety the operator wants" and withdrew it.) | Unknown feature names hard-error (`codex --disable bogus` → `Error: Unknown feature flag`), so an older codex would break *every* launch. | **CHOSEN** (probe-gated) |
| B. Reword trigger phrases in seeded prompts | Change `Don't assume.` etc. | No CLI dependency. | Whack-a-mole over an undocumented versioned keyword list; **doesn't fix existing campaigns** — `init_ralph_desk.zsh:684` seeds the prompt only `if [[ ! -f "$F" ]]` (trigger phrase at `:691`); still an SV-gate file. | Rejected |
| C. Campaign-scoped `CODEX_HOME` | Confirmed: codex resolves `hooks.json` under `$CODEX_HOME`. | Kills hooks without a flag. | `CODEX_HOME` also anchors auth, sessions, skills, prompts, sqlite. Symlink mistake breaks auth. | Rejected |

**Compat sub-decision (2 options):** (i) unconditional flag, matching the already-unconditional `--disable plugins`; (ii) probe once at leader init and gate it, mirroring `_CODEX_NO_UPDATE_FLAG` (`run_ralph_desk.zsh:129-133`). **Choose (ii)** — one `codex features list` at startup converts a total-outage failure mode into a no-op on older CLIs. Escape hatch `RLP_CODEX_HOOKS=1`.

Keep `OMX_STATE_ROOT` — it still isolates the `omx` CLI a worker may invoke directly, and is defence in depth.

### 🚨 SV-GATE FLAG (loud)
The failing campaign ran in **`--mode native`**, where the leader *is* the slash command and the launch string is authored in prose. The fix **must** edit:
- `src/commands/rlp-desk.md` (348, 419, 546, 550, **554-556**, 605, 607, 614) — **SV GATE**
- `src/governance.md` (678, 680, 738, 743) — **SV GATE**
- `src/scripts/run_ralph_desk.zsh` (2901, 3096, 3268, 4008, 4266, 4650, 5499, 5997) — no gate. Independently re-verified: all 8 present, consensus IS covered (`:4650` parallel-consensus codex leg, `:4266` final verifier), no zsh site missed.
- **`src/node/cli/command-builder.mjs:95`** — the actual Node literal (`parts.push('--disable','plugins','--dangerously-bypass-approvals-and-sandbox')`). No gate, **but it is `src/node/MANIFEST.txt:1`, so it carries the local-sync obligation.**
- `src/node/runner/campaign-main-loop.mjs:493` `buildLaunchCommand` — **delegates to `buildCodexCmd`; editing it changes nothing.** (My earlier `~502` citation was the `omxPrefix` line, not the flag literal.)

No version of this fix reaches the native leader without a governance file. **Budget the 3-scenario SV gate (LOW/MEDIUM/CRITICAL) for this US, and batch any other governance edit into it so we pay once** — concretely, US-003 AC6's `rlp-desk.md:554-556` disambiguation rides in this commit (see AC8).

**Live-leader count — my "either leader" phrasing was wrong.** There are **two** live leaders, zsh and native. `run.mjs:891` hard-errors `--mode agent` (ADR-001, `return 2`; "only the direct-CLI `--mode agent` entry point was removed"), and `--mode tmux` shells out to zsh, so the Node leader's `run()` is CLI-unreachable. Node edits are **dead-code parity** — cheap, keep them — but they cannot satisfy AC1a's "leader" and cannot be exercised by AC5.

**Binary-identity caveat.** `command-builder.mjs:5` is `const CODEX_BIN = 'codex'` (bare, PATH-resolved in-pane); zsh resolves an absolute path via `command -v codex` (`run_ralph_desk.zsh:1846`). A Node-side probe would probe a *different binary* than the pane runs. Probe on the zsh side against the resolved absolute path; do not add a second Node probe.

### Acceptance criteria
- **AC1a (zsh leader + Node builder)** — Given a codex worker/verifier/consensus/final-verifier launch, when the command is built, then it contains `--disable hooks` (when supported) **in addition to the existing** `OMX_STATE_ROOT=…` prefix and `--disable plugins`. The `--disable plugins` literal lives at `run_ralph_desk.zsh` (9 occurrences, 8 launch sites + 1 comment) and `src/node/cli/command-builder.mjs:95` (`parts.push('--disable','plugins','--dangerously-bypass-approvals-and-sandbox')`) — **not** in `campaign-main-loop.mjs`, whose `buildLaunchCommand:493` delegates to `buildCodexCmd`.
- **AC1b (native leader)** — Given the native launch strings, when updated, then they gain **both** `--disable plugins` and `--disable hooks`. **Scope expansion, previously unstated:** the native leader has no `--disable plugins` today — `rlp-desk.md:546` and `:605` are `codex exec --model <m> --reasoning-effort <r> <prompt>` with neither flag; `governance.md:678`/`:738` are `codex -m/-c … --dangerously-bypass-approvals-and-sandbox` with no `--disable plugins`. Repo-wide the literal appears in `rlp-desk.md` exactly **once**, at `:550`, inside an explanatory sentence, and **zero** times in `governance.md`.
- **AC1c (form reconciliation)** — Given the two native docs disagree (`rlp-desk.md` uses `codex exec --model/--reasoning-effort`; `governance.md` uses TUI `codex -m/-c model_reasoning_effort=`), when either is edited, then the flag set is stated identically in both and the form divergence is either reconciled or explicitly annotated as intentional. See **NON-GOAL 1** below for the flag this US must not add.

### NON-GOALS (explicit — an implementer may not do these)

**NON-GOAL 1 — do NOT add `--dangerously-bypass-approvals-and-sandbox` to the native launch strings (`rlp-desk.md:546`, `:605`).**

This is a **sandbox-posture change**, not a parity fix, and it is out of scope for this US. It looks like parity because `governance.md:678`/`:738` and the zsh/Node builders all carry the flag while `rlp-desk.md:546`/`:605` do not — an implementer "harmonizing the flag set" under AC1c could add it without noticing what changed.

*Affirmed with positive evidence, not caution alone (architect-confirmed):* the sv-oracle-nv native campaign reached **PreToolUse blocking — 11 blocks**, which proves `codex exec` was actively attempting tool calls **without** that flag. Native codex therefore works today under default approval/sandbox posture. Adding the flag would widen that posture for every native campaign, silently, as a side effect of a hook-isolation fix.

If native posture should change, it is a **separate decision with its own review** — never a drive-by inside this commit. AC1c harmonizes `--disable plugins` / `--disable hooks` only.

**NON-GOAL 2 — do NOT add `verify_partial` to the `stop=` bullets at `rlp-desk.md:554-556`.** That channel is memory.md Stop Status, whose value set is `continue|verify|blocked`; adding a fourth value there invents protocol. The `verify_partial` branch belongs to step ⑥'s **iter-signal** handling (US-003 AC6b). See the withdrawal recorded in US-003.
- **AC2 (probe + scoped byte-identity)** — **Critic #1: as first written this contradicted AC1b.** AC1b *adds* `--disable plugins` to the native launches, so a native launch can never be byte-identical to today's regardless of hooks support. Byte-identity is therefore defined **only over the hooks delta**:

  *Given* the local codex does not advertise a `hooks` feature flag, *when* a leader builds a launch command, *then* the emitted string equals **that leader's post-AC1 baseline** with the `--disable hooks` token absent — i.e. zsh/Node are byte-identical to today, and native equals today **plus `--disable plugins`** (the AC1b change, which is unconditional and independent of hooks support). No AC may require an unchanged native string.

  **Probe seam, per leader (Critic #1 "specify how the native leader probes"):**
  - **zsh** — one probe at leader init, mirroring `_CODEX_NO_UPDATE_FLAG` (`run_ralph_desk.zsh:129-133`), against the **`command -v codex` absolute path** (`:1846`), setting `_CODEX_NO_HOOKS_FLAG` to `" --disable hooks"` or `""`.
  - **native** — the native leader is a Claude Code session with Bash, so it probes the same way, once, **before its first codex dispatch**, and reuses the result for the whole campaign. The instruction lands in `rlp-desk.md` (already SV-gated by AC1b, no extra gate cost). It must be written as "probe once, reuse" — a per-dispatch probe would add ~40ms × every worker/verifier/consensus leg for no benefit.
  - **Node** — no probe. `command-builder.mjs:5` is bare `CODEX_BIN = 'codex'` (PATH-resolved in-pane) while zsh resolves an absolute path, so a Node probe would interrogate a *different binary* than the pane runs. Node emits the flag unconditionally as dead-code parity; it is CLI-unreachable (`run.mjs:891`), so nothing ships from it.

  Probe cost measured **~40ms**, no auth, no network. **Predicate = name presence in column 1, NOT state/value** — verified: `codex --disable apply_patch_freeform features list` exits 0 even though that flag is `removed false`, so a `stable`/`true` parse would wrongly drop the flag on a future CLI.
- **AC3** — Given `RLP_CODEX_HOOKS=1`, when the leader initializes, then the flag is suppressed, documented next to `RLP_CODEX_UPDATE_CHECK`.
- **AC4** — Given the native-leader instructions in `rlp-desk.md` / `governance.md`, when they describe a codex launch, then they show the `--disable hooks` form and state *why* (keyword-detector auto-activation, NOT stale state), with a failure-modes reference.
- **AC5 (real E2E)** — Given a scratch repo and a prompt containing `Don't assume.`, when codex runs **with** `--disable hooks`, then the probe file is written and exit 0; when run **without**, the write is blocked. Both legs recorded.
- **AC6** — `docs/rlp-desk/failure-modes.md` gains F1.19 with the corrected root cause; existing F1.18 amended so it no longer implies stale operator state is the mechanism.
- **AC7 (probe staleness, runtime fallback)** — Given the probe ran true at init but the binary changed mid-campaign (operator ran `codex update`; hours-long campaigns make this reachable), when a launch fails with `Unknown feature flag`, then the leader retries **exactly once** with the flag stripped and clears `_CODEX_NO_HOOKS_FLAG` **for the remainder of the run**. Without this, a stale-true probe is a **mid-campaign total outage on every launch**, not graceful degradation. (`_CODEX_NO_UPDATE_FLAG` suppresses the update *dialog*, not an operator updating out-of-band.)

  **Critic #2 — implementation seam (this was prose only).** The retry cannot live at each of the 8 zsh call sites; it needs one chokepoint:
  - **Seam** — a single wrapper, `_codex_launch_with_hook_fallback <launch-string>`, in `lib_ralph_desk.zsh`. All 8 `run_ralph_desk.zsh` launch sites route their command string through it. It inspects the launch's captured stderr for `Unknown feature flag`; on match it strips the `--disable hooks` token, sets `_CODEX_NO_HOOKS_FLAG=""` **globally** (`typeset -g`, so the clearing persists past the current function — the pattern `_LC_FLUSH_ATTEMPTED` already uses), and re-runs once. A second failure propagates unchanged: the fallback must never mask an unrelated launch error.
  - **Coverage statement (Critic #2 explicitly requires one).** **zsh: in scope**, all 8 sites via the wrapper. **native: in scope but different mechanism** — the native leader cannot wrap a shell function, so `rlp-desk.md` states the rule in prose ("if a codex dispatch fails with `Unknown feature flag`, retry once without `--disable hooks` and omit it for the rest of the campaign"), riding the AC1b/AC2 gate already paid. **Node: out of scope** — CLI-unreachable, no probe, nothing to invalidate. Stating this explicitly so "AC7 is done" cannot be claimed from zsh alone.
  - **Test (Critic #2 requires simulating a stale-true probe)** — `tests/test_codex_hook_fallback.sh`: stub `codex` on `PATH` with a script that exits non-zero printing `Unknown feature flag: hooks` **only when `--disable hooks` is present**, and succeeds otherwise. Force `_CODEX_NO_HOOKS_FLAG=" --disable hooks"` (simulating a probe that was true before the binary changed). Assert: (a) the stub was invoked **exactly twice** — one failure, one retry, no loop; (b) the second invocation's argv contains **no** `--disable hooks`; (c) `_CODEX_NO_HOOKS_FLAG` is empty afterwards; (d) a **subsequent** launch in the same run emits no `--disable hooks` — proving the clearing is persistent, not per-call; (e) with a stub that fails for an unrelated reason, there is **exactly one** invocation and the error propagates.
- **AC8 (SV-gate batching — see A4/US-003)** — US-003's **AC6a** (channel label at `:554-556`) and **AC6b** (native `verify_partial` branch in step ⑥'s iter-signal handling) land **in this same commit**, so the 3-scenario gate is paid once (driver D3). AC6b is the substituted item: the withdrawn instruction — adding `verify_partial` to the `stop=` bullets — must **not** be implemented.

### Verification commands
Every line below is runnable (Critic #7). `set -euo pipefail` throughout, and no assertion is a bare `grep | echo PASS` (Critic #8).

```bash
set -euo pipefail

# AC1a-AC3 + AC2 probe/byte-identity seam
node --test tests/node/codex-launch-hook-isolation.test.mjs

# AC7 — stale-true probe, retry-once, persistent clearing
zsh tests/test_codex_hook_fallback.sh

# AC4 + AC6a/AC6b + AC8 — doc/instruction content assertions (Critic #7: these had no commands)
grep -q -- '--disable hooks' src/commands/rlp-desk.md
grep -q -- '--disable hooks' src/governance.md
grep -q -- '--disable plugins' src/commands/rlp-desk.md       # AC1b: native gains it
grep -qi 'keyword-detector\|keyword detector' src/commands/rlp-desk.md   # AC4: correct cause stated
test "$(grep -c 'verify_partial' src/commands/rlp-desk.md)" -ge 1        # AC6b: native branch exists
grep -q 'Stop Status' src/commands/rlp-desk.md                # AC6a: channel labelled
# AC6/F1.19 — failure-modes atlas entry, and F1.18 no longer blames stale state
grep -q 'F1.19' docs/rlp-desk/failure-modes.md
grep -A5 'F1.18' docs/rlp-desk/failure-modes.md | grep -qi 'keyword' 

# AC5 — real E2E. POSITIVE leg.
d=$(mktemp -d); git -C "$d" init -q
P="Don't assume. Don't hide confusion. Create probe.txt containing OK, then stop."
( cd "$d" && OMX_STATE_ROOT="$d/omx-state" codex exec -m gpt-5.6-luna \
    --disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox "$P" )
test -f "$d/probe.txt"                       # positive: file MUST exist
grep -q OK "$d/probe.txt"

# AC5 — NEGATIVE control. Critic #8: the old form was vacuous — it grepped a log
# line and, under `set -e` with a pipeline, could report PASS on an early failure
# while never proving the write was actually prevented. The load-bearing assertion
# is FILE ABSENCE; the log match is corroboration only.
rm -f "$d/probe.txt"
neg_log="$d/neg.log"; neg_rc=0
( cd "$d" && OMX_STATE_ROOT="$d/omx-state2" codex exec -m gpt-5.6-luna \
    --disable plugins --dangerously-bypass-approvals-and-sandbox "$P" ) \
    >"$neg_log" 2>&1 || neg_rc=$?      # non-zero tolerated; do NOT let set -e abort
test ! -f "$d/probe.txt" || { echo "AC5-negative FAIL: hook did not block the write"; exit 1; }
grep -q "Deep-interview is active" "$neg_log" \
  || { echo "AC5-negative FAIL: blocked, but not by the deep-interview hook (rc=$neg_rc)"; exit 1; }
echo "AC5 PASS (positive: file written; negative: file ABSENT + hook message present)"

# Repo gates
npm run test:fast && npm run test:zsh && npm run sv-gate:fast
npm run verify:sync && npm run verify:sync -- --strict-chmod && npm run manifest:check

# SV gate — governance files touched (Critic #7: this was a comment, not a command)
zsh tests/sv-gate-full.sh          # the 3-scenario LOW/MEDIUM/CRITICAL harness
# Local sync (Tier-1, CLAUDE.md §4.5) — also a command now, not a comment.
# [TEAM-LEAD FIX 2026-08-10] The draft resurrected the hand-rolled banner-strip
# recipe that main just abolished (251f766/3e17506): `grep -v` emits nothing for
# NUL-carrying files, and `diff -rq | grep -v 'DO NOT EDIT' || true` is an
# always-red check masked into a no-op by `|| true`. CLAUDE.md §4.5 now mandates
# the byte-exact oracle:
npm install
npm run verify:sync -- --strict-chmod
```
**Note on `sv-gate-full.sh`:** if that harness does not in fact drive the 3 CLAUDE.md scenarios end-to-end, the implementer must say so and run them explicitly rather than treating the script's exit 0 as gate satisfaction. The gate is the three Worker+Verifier scenarios, not whichever script is nearest.

**Dependencies:** none. Do this first.

---

# US-002 — Leader-recovery must not commit a foreign editor's work
**Risk: HIGH** · **Option A: no SV gate · Option D: SV-gated, OWN SEPARATE gated commit (TEAM-LEAD DECISION 2026-08-10 — does NOT ride US-001)** · Option A fully independent
*(Retitled per A7 — "concurrent campaign" was not honest; see threat model below. Gate status corrected per Critic #4 — the earlier flat "no SV gate" was false once Option D was adopted. Gate SPLIT decided by team-lead: coupling the CRITICAL liveness fix to a LOW-priority runtime mechanism inverts driver D1 — if Option D's instruction fails its scenario, US-001 must not be blocked by it. Two SV gates / 6 scenarios accepted on record as a deliberate D1-over-D3 trade.)*

### Problem
See Correction 2. `CAMPAIGN_PREEXISTING_DIRTY` is a process-start snapshot; anything dirtied later reads as Worker output.

**Threat-model correction (A7) — verified.** `run_ralph_desk.zsh:4911-4930` acquires `RUNNER_LOCKFILE_PATH="$DESK/logs/.rlp-desk-runner-$ROOT_HASH.lock"` — **per project root, exclusive**. A duplicate zsh runner prints "duplicate rlp-desk runner detected on this project root" and `exit 1`s. **Two zsh campaigns on one checkout are already impossible.** The **native leader registers no lock at all** (confirmed: no lock acquisition anywhere in `rlp-desk.md` or `run.mjs`). So the `dd0e6d9` foreign editor was a human or a *native* campaign — the **cross-mode asymmetry is the real defect**, not zsh-vs-zsh concurrency.

**Exact line map (corrected).** `comm -23` **:1413** · `-z` guard **:1417** · array build **:1428** · empty-list BLOCK **:1433/:1434/:1436** (my earlier "1436-1440" was wrong) · snapshot **:5135** (my earlier "5116" was wrong; `:5129` is a comment) · carryover record **:1283**, consumed **:3000-3005**.

### Options
| Option | Mechanism | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. Per-iteration dirty baseline** | Capture `ITER_PREEXISTING_DIRTY` at each iteration's worker dispatch; scope becomes `dirty MINUS (CAMPAIGN_PREEXISTING_DIRTY ∪ ITER_PREEXISTING_DIRTY)`. | Reuses the proven `comm -23` idiom; narrows the window from whole-campaign to one iteration; touches only `run_ralph_desk.zsh` + `lib_ralph_desk.zsh` (**no SV gate**); untracked evidence path untouched so the iter-005 need still works. | Doesn't help if the other campaign edits *during* the same worker window. Residual, stated. | **CHOSEN** |
| B. Allowlist from done-claim `execution_steps` / PRD Verification Commands | Intent-driven. | **Not buildable from today's schema** — real done-claims carry only `["claims","commit_note","execution_steps","scope_note","us_id"]`, and `execution_steps[].command` holds shell strings, not paths. Adding a `files` field edits `init_ralph_desk.zsh` → **SV gate**, and makes an integrity check depend on model-supplied data. Worst of both. | Rejected |
| C. Default campaigns to `--worktree` | True isolation. | **`--worktree` is tmux-only** — `run.mjs:612` forwards `RLP_CAMPAIGN_WORKTREE=1`, only `run_ralph_desk.zsh:501` consumes it. Native mode gets nothing, and native is where the operator most often runs. Also relocates `.rlp-desk/`, `.omc/`, installed deps (`lib_ralph_desk.zsh:3980` already warns the operator must re-run their package install). Default-flip is a UX break, not a bug fix. | Rejected as default; **kept as documented recommendation** |

| **D. Cross-mode leader awareness (A7, ADOPTED alongside A)** | Register the native leader in the same per-`ROOT_HASH` namespace (**advisory**, not exclusive — native must not start hard-failing), and have zsh **downgrade F-8 to the existing `_bug8_record_carryover` path** (`:1283`, consumed `:3000-3005`) when another live leader is on the same toplevel. | Deterministic; closes the cross-mode case **including the same-worker-window race** that Option A cannot; reuses a tested graceful-continue path rather than inventing one. | **Costs an SV gate (Critic #4 — my "no SV gate" claim was false):** the native registration step is an instruction to the native leader, so it lands in `rlp-desk.md`. Per the TEAM-LEAD gate-split decision (2026-08-10) it pays its OWN 3-scenario gate as a separate commit — it does NOT ride US-001's. **Plus new lifecycle surface:** a registry has liveness, stale-entry, and cleanup semantics that F-8 previously had none of — a dead native entry downgrades F-8 forever (fail-closed, but wrong). Does not cover a *human* editing the tree — complements A, does not replace it. **Gate: its OWN gated commit 2** (team-lead split 2026-08-10) — a second full 3-scenario gate, not a ride on US-001. | **ADOPTED** |

**Ship A + D; document C.** A narrows the window; D closes the cross-mode case A leaves open. Neither covers a human editor — that residual stands.

### Acceptance criteria
- **AC1** — Given a tracked file clean at campaign start but dirty before iteration N's worker dispatch, when F-8 runs in iteration N, then it is excluded from `_bug8_worker_files` and never staged.
- **AC2** — Given a tracked file the Worker itself modified during iteration N, when F-8 runs, then it IS included and committed (no regression of recovery's purpose).
- **AC3** — Given every dirty tracked file is excluded by the union, when F-8 evaluates, then it logs the existing `preexisting_only_no_commit` no-op branch — it does NOT fall through to the empty-list BLOCK at **`run_ralph_desk.zsh:1433-1436`**. **AC3 holds IFF the union is folded into the `comm -23` at `:1413`, before the `-z` test at `:1417`.** Filtering `_bug8_add` after the array build at `:1428` fails *worse* than hitting the BLOCK: for an empty string, `("${(@f)_bug8_worker_files}")` yields **one empty element**, so `${#_bug8_add}` is **1, not 0** — verified (`zsh -c 'x=""; a=("${(@f)x}"); echo ${#a}'` → `1`). The `:1433` BLOCK never fires and execution falls into `git diff --quiet HEAD -- ''`. The D-20 comment at `:1428-1432` is load-bearing for this AC; state that dependency explicitly in the test.
- **AC4** — Given untracked campaign evidence (the iter-005 case), when the prompted carryover path at **`run_ralph_desk.zsh:3000-3005`** runs, then behaviour is byte-unchanged; guard it with a test so a future refactor can't widen F-8 into untracked territory.
- **AC5** — Given a leader relaunch, when the per-iteration baseline is captured, then D-25's documented behaviour is unchanged (the new baseline only ever narrows the staged set, never widens it).
- **AC6** — Residual (human editor; same-worker-window edit not covered by A alone) and the `--worktree` recommendation, including its tmux-only limitation, documented in `docs/rlp-desk/failure-modes.md`.

### Option D — leader registry spec (Critic #3)

> Authored by `ralplan-architect`, applied verbatim 2026-08-10 from `.omc/plans/optiond-ac7-insert.md` (sha256 `748c931b83c76ac1ca8d5259ff8f2398c8b35565ec0f329ad62b62e3da711f58`). Supersedes the earlier interim defaults block wholesale.

### Registry path
`$DESK/logs/.rlp-desk-leaders-$ROOT_HASH.d/<pid>.json`

Confirmed safe: `.rlp-desk/` is gitignored (`.gitignore:33`, verified via `git check-ignore -v`), so registry entries never become dirty files. That matters more than it sounds — an anti-dirty-file mechanism that creates dirty files would be self-defeating.

**One condition you must add.** `DESK="$ROOT/${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"` (`run_ralph_desk.zsh:513`) is **operator-overridable**. If the two leaders resolve `RLP_DESK_RUNTIME_DIR` differently they write to different registries and never see each other — Option D silently no-ops. That is fail-*open* (status quo auto-commit), so it is acceptable, but it must be documented, and if the operator sets that variable they must set it for both leaders. Keying the directory on `$ROOT_HASH` (`:525`) is right and should stay — it prevents collision if a shared DESK is ever pointed at two roots.

### Schema
```json
{"schema_version":"1.0","pid":12345,"mode":"native"|"tmux","slug":"…","root":"/abs/path","started_at":"…Z"}
```
Add `schema_version`. This repo already versions its JSON (`write_blocked_sentinel` emits `schema_version: "2.0"`), and a registry read by two independently-evolving leaders is exactly where you want a version field before you need it. `root` earns its place as a sanity check against a stale entry from a relocated checkout. Nothing else needed — the downgrade decision only requires "a foreign live entry exists"; `mode` and `slug` are for the log line, which is worth having so an operator can see *which* leader caused a carryover.

### Atomicity — `atomic_write`, NOT `set -C`

`acquire_slug_lock`'s entire apparatus (stale reap, recovery mutex, TOCTOU settle window, re-read under mutex) exists to arbitrate **contention on one shared filename**. A per-PID registry has no contention — each PID owns a unique name — so all of that is dead weight, and worse, it would make registration *fail* on races it should not even have.

What you actually need is the property `set -C` does **not** give you: truncation safety. `atomic_write` (`lib_ralph_desk.zsh:531`) checks both the write and the rename, so a half-written entry (ENOSPC, SIGPIPE) never lands. That matters because under the §Liveness fail-closed rule an unparseable entry downgrades F-8 — so a torn write would cause spurious carryovers.

Also: a pre-existing file at our own `<pid>.json` is **by definition stale** (we are alive holding that PID, so the previous owner is dead). Plain overwrite is correct; `set -C` would only make us refuse to register.

### Multi-native ownership — advisory; predicate is "≥1 foreign live entry"
Two additions:
- **Both leaders register**, not just native. Cheap, makes the registry describe reality, future-proofs if the exclusive runner lock is ever relaxed, and makes the test more realistic.
- Therefore **self-exclusion by PID is mandatory** — the reader skips `$$`. Without it, a registering zsh leader downgrades its own F-8 forever, which would be a spectacular self-own.

### Liveness & pruning — `kill -0` at read time, both sides prune, reader-side is load-bearing
- **Authority: `kill -0` at read time.** Matches `acquire_slug_lock:590` and the codebase's documented invariant that staleness is "PID-based (never age-based, so a slow-but-alive recoverer is never falsely reaped)". Do not add a TTL.
- **Registrant removes its own entry on exit** — in `cleanup()`, right where the runner lock is released (`run_ralph_desk.zsh:3335-3344`). Best-effort.
- **Reader sweeps dead entries** during the same pass it reads them.

**Why reader-side sweep is load-bearing and not belt-and-braces:** the native leader is an LLM. It can hit a context limit, be interrupted, or simply skip an instruction — it is the *least* reliable party at running its own cleanup step, and it is precisely the party this feature exists to detect. Never rely on the native leader to unregister. A dead native entry would otherwise downgrade F-8 forever; reader-side `kill -0` + unlink is the fix, and it is required, not optional.

### Race semantics — no lock
- The failure mode of losing the race is **reverting to today's behavior** (auto-commit) for one iteration. Strictly no worse than status quo, so the race cannot regress anything.
- A lock could not close it anyway — the native leader is not holding any lock while it edits files, so there is nothing to serialize against.
- **Free improvement:** put the registry read immediately before `_bug8_autocommit` (~`:1457`), not at Gate-3 entry (~`:1408`). Same code, window shrinks from "the whole comm/log sequence" to microseconds. Zero cost.

### Fail-closed on read error
If the registry directory cannot be read (permissions, IO error), **downgrade to carryover**. This mirrors the GIT-FC/IMP-09 idiom already in Gate 3, where a git error must not read as "clean". A registry read error must not read as "no foreign leaders". Carryover is graceful, so fail-closed costs nothing.

### Option D — acceptance criteria (AC7a–AC7h)

**AC7a (registry contract).** Given any leader starts a campaign, when it initializes, then it writes `$DESK/logs/.rlp-desk-leaders-$ROOT_HASH.d/<pid>.json` via `atomic_write` containing `{schema_version:"1.0", pid, mode:"native"|"tmux", slug, root, started_at}`. The registry is advisory: registration never fails a campaign, and a write error is logged and ignored. It MUST NOT reuse `RUNNER_LOCKFILE_PATH` — that lock is exclusive and would make registration hard-fail on a busy root.

**AC7b (both leaders register).** Given a `--mode tmux` campaign, when the zsh leader initializes, then it registers. Given a `--mode native` campaign, when the native leader starts, then its instructions direct it to register with the identical path and schema. *(This AC is the SV-gated portion — it edits `src/commands/rlp-desk.md`.)*

**AC7c (unregistration).** Given a leader reaches `cleanup()`, when it releases the runner lock, then it removes its own `<pid>.json` (best-effort; failure logged, never fatal).

**AC7d (liveness + reader-side prune).** Given the registry is read, when an entry's `pid` fails `kill -0`, then that entry is treated as absent AND unlinked in the same pass. Staleness is PID-based only — no TTL, no age heuristic. A leader killed with SIGKILL, or a native leader that never unregisters, MUST NOT downgrade F-8 indefinitely.

**AC7e (downgrade predicate).** Given F-8 is about to auto-commit, when the registry contains ≥1 live entry whose `pid != $$`, then the leader logs which foreign leader (mode + slug + pid) was detected, routes the worker files to `_bug8_record_carryover`, and does NOT stage or commit. Given zero live foreign entries, then F-8 auto-commits exactly as today (byte-identical behavior — no regression of recovery's purpose).

**AC7f (self-exclusion).** Given a leader has registered its own entry, when it reads the registry, then its own `$$` is excluded and its own F-8 is never downgraded by its own registration.

**AC7g (fail-closed read).** Given the registry directory exists but cannot be read, when F-8 evaluates, then the leader downgrades to carryover rather than treating the error as "no foreign leaders" — mirroring the GIT-FC fail-closed idiom in Gate 3.

**AC7h (path-agreement caveat, documented).** `docs/rlp-desk/failure-modes.md` records that `RLP_DESK_RUNTIME_DIR` is operator-overridable and that a mismatch between leaders makes Option D a silent no-op (fail-open to status quo); if the operator sets it, both leaders must use the same value.

### Option D — test (4 cases)

The planner's original single-case sketch was **vacuous**: asserting only that the downgrade fires cannot distinguish a correct implementation from a hardcoded `return`. The backgrounded-`sleep` live-PID approach is right and needs no second campaign, but it needs four cases.

1. **Positive control** — live foreign entry + dirty tracked file → `_bug8_record_carryover` fired, `git log` gained no `leader-recovery` commit.
2. **Negative control** *(the one that proves non-vacuity)* — *no* registry entry, same dirty file → F-8 **does** auto-commit, `git log` gained exactly one `leader-recovery` commit. Without this the suite passes if someone disables F-8 entirely.
3. **Stale entry** — entry whose PID is dead (`kill` the `sleep`, keep the file) → F-8 auto-commits **and** the stale file is unlinked. This is AC7d.
4. **Self-exclusion** — entry whose pid is the test leader's own `$$` → F-8 auto-commits. This is AC7f, and it is the one that would otherwise ship a leader that permanently downgrades itself.

Optionally **5**: unreadable registry dir (`chmod 000`) → carryover (AC7g). Skip if awkward in CI, but note the skip.

### Runnable verification commands

```bash
set -euo pipefail

# AC7a-AC7g — cases 1-4 (+ optional 5)
zsh tests/test_bug8_leader_registry.zsh

# Case 2's invariant is also this existing test's invariant — if it goes red you have
# BROKEN recovery, not scoped it.
zsh tests/sv-large-campaign/test-f8-commit-slip-recovery.zsh

# AC7h — documented caveat
grep -q 'RLP_DESK_RUNTIME_DIR' docs/rlp-desk/failure-modes.md
grep -qi 'no-op\|no op' docs/rlp-desk/failure-modes.md

# AC7b is SV-gated (edits src/commands/rlp-desk.md) — this is gated commit 2's own gate,
# NOT covered by US-001's passing gate.
zsh tests/sv-gate-full.sh
```


### Verification commands
Critic #4: the manual human-edit repro is replaced by a runnable native↔zsh test. Critic #7: AC6/AC7 now have commands.

```bash
set -euo pipefail

# AC1-AC5 — per-iteration baseline scenarios
zsh tests/test_bug8_autocommit_robust.sh
zsh tests/sv-large-campaign/test-f8-commit-slip-recovery.zsh    # regression, must stay green

# AC7a-AC7g (Option D) — 4-case registry test; contract in the Option D test section above.
zsh tests/test_bug8_leader_registry.zsh

# AC7 — docs assertions (Critic #7: previously no command)
grep -q 'worktree' docs/rlp-desk/failure-modes.md
grep -qi 'tmux-only\|tmux only' docs/rlp-desk/failure-modes.md
grep -qiE 'human (editor|editing)' docs/rlp-desk/failure-modes.md

npm run test:zsh && npm run test:fast && npm run sv-gate:fast
npm run verify:sync && npm run verify:sync -- --strict-chmod && npm run manifest:check
# Option D touches rlp-desk.md -> its OWN 3-scenario gate (gated commit 2, team-lead
# decision 2026-08-10). Run the full gate again for this commit; do NOT fold it into
# US-001's commit, and do NOT treat US-001's passing gate as covering it.
zsh tests/sv-gate-full.sh          # commit 2's own LOW/MEDIUM/CRITICAL scenarios
```
**Dependencies:** **Option A — none**, gate-free (pure `run_ralph_desk.zsh`/`lib_ralph_desk.zsh`); ships right after US-001 per the team-lead sequencing. **Option D — its own gated commit 2**, sequenced after commit 1 so a failure in D's SV scenario cannot block the CRITICAL codex-liveness fix. Option A ships without Option D; Option D depends on commit 1 for ordering only, not for its gate.

---

# US-003 — Pin the canonical iter-signal status key; tolerant-read legacy `stop`
**Risk: MEDIUM** (tiny change, but the failure mode is a blocked campaign) · no SV gate

### Problem
`docs/rlp-desk/verification-history.md:94`: *"iter-signal precedent files used a `stop` key but the zsh leader parses `.status` (worker discovery; precedent corrected in-campaign)."* A worker following a `stop`-keyed precedent yields `jq -r '.status'` → null → `run_ralph_desk.zsh:6409` `Unknown signal status` → `_bump_consecutive_failure` → circuit breaker → **BLOCKED campaign on a key-name mismatch**.

### Decision (uncontested)
**Canonical = `status`.** The zsh leader reads it at `run_ralph_desk.zsh:2731` and `:5668`; docs specify it (`protocol-reference.md:104-127`, `init_ralph_desk.zsh:782`). Nothing is renamed. Work = tolerant-read `stop`, canonical-write `status`, pin the contract in `signal-protocol.md` (which today documents the four sentinel invariants but **never states the iter-signal field schema at all**).

**Correction (A3):** my earlier "both leaders already read `.status` … `campaign-main-loop.mjs:2642`" cited a **dead** leader as live coverage. `--mode agent` hard-errors at `run.mjs:891`, so that read is unreachable. Keep the Node change as parity, but the live read coverage is zsh + native only.

**Root-cause correction (A4), stated precisely.** The generator is not a stale precedent file. `src/commands/rlp-desk.md:554-556` instructs the **native leader** in `stop=` vocabulary:
```
- `stop=continue` → go to ⑧
- `stop=verify`   → go to ⑦
- `stop=blocked`  → write BLOCKED sentinel, stop
```
while `init_ralph_desk.zsh:782` tells workers to write `status`. **Precision the architect's framing needs:** `stop=` at `:554-556` denotes the **memory.md Stop Status** channel (`rlp-desk.md:496` "Read memory.md → Stop Status"; `init_ralph_desk.zsh:1191` `## Stop Status`), which is genuinely a *different* channel from `iter-signal.json`. The defect is therefore **unlabelled adjacency**, not a mis-named key: `:554-556` (memory.md channel) sits directly above `:557` ("Also read `iter-signal.json` for `us_id`") with no channel marker, so a reader can reasonably carry `stop=` across into the signal file. That is a *plausible* generator, not a proven one — and encoding it as proven would repeat exactly the false-root-cause failure this PRD corrected in US-001. **Fix = disambiguate and name the channel at `:554-556`, not rename anything.** It edits `rlp-desk.md` ⇒ **SV GATE** ⇒ folds into the US-001 commit (US-001 AC8), so my "SV gate: US-001 only" claim is *preserved by batching*, not by being true as originally written. Tolerant-read stays, as the **secondary** fix.

**⚠️ WITHDRAWN (architect's own retraction, accepted): do NOT add `verify_partial` to the `stop=` bullets at `:554-556`.** Once `stop=` is established as a *distinct* channel, adding a fourth value to it asserts something that channel has no evidence of accepting — that would be inventing protocol, and it is exactly the bug-injection this correction exists to prevent. Verified: Stop Status is seeded as `continue` (`init_ralph_desk.zsh:1191-1192`), read by five consumers (`run_ralph_desk.zsh:2975`, `prompt-assembler.mjs:126`, `governance.md:852`, `campaign-initializer.mjs:236`, `rlp-desk.md:496`), and **`rlp-desk.md:553` is literally "⑥ Read memory.md again"** — the `stop=` bullets sit inside that step. One refinement to the architect's "no enumeration exists anywhere": there *is* one — **`docs/rlp-desk/protocol-reference.md:20`, "Parse 'Stop Status' section → continue/verify/blocked"**. That *strengthens* the withdrawal: two independent docs already agree on a three-value set for this channel, so adding a fourth would contradict both.

**Substituted, stronger finding — the native leader cannot handle `verify_partial` at all.** Verified: `grep -c verify_partial src/commands/rlp-desk.md` → **0**. The token exists in `governance.md:1110/1115/1125` (describing "the runner" = zsh), `init_ralph_desk.zsh:782/786/978` (the **shared** worker prompt), `run_ralph_desk.zsh` (×10, zsh leader), and `campaign-main-loop.mjs:2639-2653` (dead Node leader) — **every consumer except the native leader**. So a native-mode worker is authorized by the shared prompt to emit `"status":"verify_partial"` into a leader whose step-⑥ branch table enumerates three states and has no branch for it: an unenumerated state in the leader's own instruction set. Real native-leader gap, squarely US-003's territory, same SV-gated file.

Doc drift found while checking: `protocol-reference.md:111` (JSON example) and `:121` (field table, "One of: `continue`, `verify`, `blocked`") say `continue|verify|blocked` while the actual worker contract (`init_ralph_desk.zsh:782`) says `continue|verify|verify_partial|blocked`. Fix the doc, not the prompt.

### Acceptance criteria
- **AC1 (scope reconciled — Critic #5)** — `{"status":"verify"}` → behaviour byte-identical to today. **"Both leaders" was wrong and the proof did not match the claim.** Corrected, per-consumer:
  - **zsh leader — in scope, live, provable.** Reads `.status` at `run_ralph_desk.zsh:2731` and `:5668`. Tolerant-read lands here; proof is `tests/test_iter_signal_key_tolerance.sh` against the real parse path.
  - **Node leader — in scope as parity, NOT as proof.** `campaign-main-loop.mjs:2642` is CLI-unreachable (`run.mjs:891` hard-errors `--mode agent`). A Node unit test may assert the tolerant-read, but **it must not be cited as coverage of a shipping path**; it is a dead-code mirror.
  - **native leader — NOT in scope for tolerant-read, because it does not consume iter-signal `status` as US-003 first described.** Verified: `rlp-desk.md:557` has the native leader read `iter-signal.json` for **`us_id` only**; its control flow branches on the **memory.md Stop Status** channel at `:554-556`. So there is no native `status` read to make tolerant. The native leader's iter-signal work in this PRD is exactly AC6b (adding a `verify_partial` branch), nothing more.

  Net: the tolerant-read is a **zsh-leader change with a Node parity mirror**, and no AC may claim native coverage for it.
- **AC2** — Legacy `{"stop":"verify"}` with no `status` → resolves to `verify`, logs a one-line deprecation naming the file.
- **AC3** — Both keys present with different values → `status` wins; divergence logged.
- **AC4** — Neither key → existing `Unknown signal status` soft-fail fires unchanged (no new silent-accept hole).
- **AC5** — Every leader-synthesized signal writes `status`, never `stop`. **Corrected writer list (A5) — right line numbers, wrong file in my earlier draft; all four are in `run_ralph_desk.zsh`, not `lib_ralph_desk.zsh`** (`lib_ralph_desk.zsh:1489` is the `_verify_pane_alive` comment header; `:3670` is `us_id: $us_id,`):
  - `run_ralph_desk.zsh:1489` — codex-exit synthesis
  - `run_ralph_desk.zsh:3670` — A4 fallback
  - **`run_ralph_desk.zsh:4235`** — sequential-final-verify replace (`echo "{\"status\":\"verify\",…}"`) — **missed in my draft**
  - **`run_ralph_desk.zsh:5417`** — D-16 leader-finalize (`printf '{"iteration": %d, "status": "verify", …}'`) — **missed in my draft**
  My original grep used `'"status":"'`, which cannot match the escaped (`\"status\":\"`) and spaced (`"status": "`) forms at `:4235`/`:5417`. Any AC5 test must enumerate all four, and its own detector must tolerate all three quoting forms.
- **AC6** — `signal-protocol.md` gains an "Iteration-signal field contract" section: canonical `status`, values `continue|verify|verify_partial|blocked`, `stop` accepted-on-read/never-written, deprecated 2026-08-10. `protocol-reference.md:111` **and** `:121` corrected to include `verify_partial` — both sites, since they are independent statements of the vocabulary (`:113` is the summary line and is not a vocabulary site).
- **AC6a (SV-gated, rides the US-001 commit)** — `rlp-desk.md:554-556` gains an explicit **channel label** distinguishing the memory.md Stop Status channel from the iter-signal `status` channel. **No value is added to the `stop=` bullets** — see the withdrawal above.
- **AC6b (SV-gated, rides the US-001 commit) — new** — Step ⑥'s **iter-signal** handling in `rlp-desk.md` gains a `verify_partial` branch, so the native leader has a defined response to a state its own shared worker prompt authorizes. *Given* a native-mode worker writes `"status":"verify_partial"`, *when* the native leader reaches step ⑥, *then* it takes a defined branch rather than falling through an unenumerated state.
- **AC6c (new)** — `signal-protocol.md` **pins BOTH contracts** and documents them as **distinct channels** — the durable fix for the adjacency defect:
  1. **Iter-signal field contract** — canonical key `status`; values `continue|verify|verify_partial|blocked`; legacy `stop` accepted-on-read, never written; deprecated 2026-08-10.
  2. **Stop Status value set** — the memory.md channel; values `continue|verify|blocked` (**no `verify_partial`** — see the withdrawal above).

  *Given* `signal-protocol.md` after this change, *when* a reader looks up either channel, *then* both value sets are stated, each is labelled with its channel and file, and neither is presented as interchangeable with the other.

  **Premise correction (carried from the amendment round).** The instruction's "Stop Status value set is currently undefined anywhere; only `continue` is seeded" is *nearly* right but not exact: `init_ralph_desk.zsh:1191-1192` seeds only `continue`, **but a value enumeration does already exist** — `docs/rlp-desk/protocol-reference.md:20`, "Parse 'Stop Status' section → continue/verify/blocked". So this AC creates the **normative** pin where none existed, rather than inventing a value set from nothing. Because the pre-existing enumeration agrees exactly (`continue/verify/blocked`), pinning is safe — no protocol is invented. **AC6c must also reconcile the two so there is one value set, not two authorities:** `signal-protocol.md` becomes normative and `protocol-reference.md:20` is annotated to point at it. A pin that silently leaves a second, unlinked enumeration in another file re-creates the exact drift this AC exists to end.

### Verification commands
Critic #7: AC6's full doc contract had no commands — every clause is now asserted.

```bash
set -euo pipefail

# AC1-AC4 — tolerant read. zsh is the LIVE proof; the Node run is parity only (AC1 scope note).
zsh tests/test_iter_signal_key_tolerance.sh                 # AC1-AC5, live zsh leader
node --test tests/node/iter-signal-key-tolerance.test.mjs   # parity mirror, NOT shipping-path proof

# AC5 — all four synthesizers write `status`, none writes `stop`.
# Detector must tolerate all three quoting forms ("status":" / \"status\":\" / "status": ").
test "$(grep -cE '\\?"status\\?"[[:space:]]*:' src/scripts/run_ralph_desk.zsh)" -ge 4
! grep -qE '\\?"stop\\?"[[:space:]]*:' src/scripts/run_ralph_desk.zsh
for ln in 1489 3670 4235 5417; do
  sed -n "${ln}p" src/scripts/run_ralph_desk.zsh | grep -qE 'status' \
    || { echo "AC5 FAIL: synthesizer at :$ln no longer writes status"; exit 1; }
done

# AC6 — iter-signal field contract pinned in signal-protocol.md
grep -q 'Iteration-signal field contract' docs/rlp-desk/signal-protocol.md
grep -q 'verify_partial' docs/rlp-desk/signal-protocol.md
grep -qi 'accepted-on-read\|accepted on read' docs/rlp-desk/signal-protocol.md   # legacy `stop`
grep -q '2026-08-10' docs/rlp-desk/signal-protocol.md                            # deprecation date
# AC6 — BOTH protocol-reference vocabulary sites corrected (:111 JSON, :121 field table)
sed -n '111p' docs/rlp-desk/protocol-reference.md | grep -q 'verify_partial'
sed -n '121p' docs/rlp-desk/protocol-reference.md | grep -q 'verify_partial'
# AC6c — two channels documented as distinct, Stop Status pinned, :20 reconciled
grep -q 'Stop Status' docs/rlp-desk/signal-protocol.md
sed -n '20p' docs/rlp-desk/protocol-reference.md | grep -qi 'signal-protocol'     # points at the normative pin
# AC6c guard: Stop Status must NOT have gained verify_partial (NON-GOAL 2)
! grep -A3 'Stop Status' docs/rlp-desk/signal-protocol.md | grep -q 'verify_partial'

npm run test:fast && npm run test:zsh && npm run sv-gate:fast
```
**Dependencies:** AC1-AC5 + AC6/AC6c — none. **AC6a/AC6b are commit-coupled to US-001** (they edit the SV-gated `rlp-desk.md`); their verification runs inside the US-001 block, not here.

---

# US-004 — Attribute the campaign-exit cost-log row to a real bucket, not `unknown`
**Risk: LOW** (reporting fidelity) · no SV gate · **zsh-only**

### Problem
`write_cost_log` (`lib_ralph_desk.zsh:1810`) has `local cost_us_id="${signal_us_id:-unknown}"` (line 1837). `signal_us_id` is a caller's local visible only via zsh dynamic scoping (documented at 1826-1832). The in-loop call site (`run_ralph_desk.zsh:6425`) is inside that scope. The **exit-trap** site (`_emit_final_cost_log`, `run_ralph_desk.zsh:246-255`) runs at top level after the function returned → local gone → `unknown`.

Confirmed in `.rlp-desk/logs/sv-oracle/cost-log.jsonl`:
```
{"iteration":2,"us_id":"US-001",...} {"iteration":3,"us_id":"US-001",...}
{"iteration":4,"us_id":"US-001",...} {"iteration":5,"us_id":"unknown",...}
```
Iteration 5 is the final-verify pass (report: 5 iterations, done-claims only 2-4). Renders as `Final model per US: US-001 = sonnet:high, unknown = sonnet:high` (`lib_ralph_desk.zsh:2202-2254`).

**Scope note:** cost-log.jsonl is zsh-only. `src/node` has no cost-log emitter; `campaign-reporting.mjs summarizeCost` reads campaign.jsonl and has no us_id bucket. **No Node change required.** The other `'unknown'` hits at `campaign-reporting.mjs:423/438` are done-claim/verdict us_ids — a different axis. Do not touch them.

### Options
| Option | Mechanism | Pros | Cons | Verdict |
|---|---|---|---|---|
| A. Fixed `final-verify` label | Hard-code it in `_emit_final_cost_log`. | One line. | **Lies on a BLOCKED exit** — the trap also fires when the campaign aborts before any final verification. Mislabelled data is worse than `unknown`. | Rejected |
| **B. Phase-derived bucket** | Optional 2nd arg `us_id_override` on `write_cost_log`; `_emit_final_cost_log` derives the bucket from **one authoritative flag**, `FINAL_VERIFY_RAN` (see below). | Always truthful; one optional param; in-loop site unchanged. | ~10 lines instead of 1. | **CHOSEN** |

Backward compat: existing on-disk rows keep `us_id:"unknown"` and must keep rendering as `unknown` — never rewrite history, never drop the row.

### Acceptance criteria
**Terminal states are THREE, not two (A8-i).** `cleanup` at `run_ralph_desk.zsh:3395-3398`: `COMPLETE` (sentinel) / `BLOCKED` (sentinel) / **`TIMEOUT`** (no sentinel — max-iter or SIGINT/TERM). My AC1+AC2 covered two; Option B's "otherwise" is total but untested, so an implementer could legally emit `unknown` on the third.

**ONE authoritative phase flag (Critic #6).** Option B's prose said "final-verify **when final verification / COMPLETE was reached**" while AC1 requires *actual final-verify invocation* — two different predicates, and an implementer could satisfy either. Resolved by defining a single source of truth that both the option text and every AC below reference:

> **`FINAL_VERIFY_RAN`** — `typeset -g FINAL_VERIFY_RAN=0` at leader init; set to `1` as the **first statement inside `run_sequential_final_verify`** (`run_ralph_desk.zsh:4358`), before any work that could fail. It records *invocation*, not outcome — a final verify that ran and failed still ran.

Bucket derivation is then total and unambiguous, and **must not consult sentinels for the `final-verify` decision**:
`FINAL_VERIFY_RAN == 1` → `final-verify`; otherwise → `campaign-exit`. The COMPLETE/BLOCKED/TIMEOUT three-way from `cleanup` is used **only** for AC2b's assertion that no terminal path can leak `unknown` — it never selects the bucket. This kills the COMPLETE-implies-final-verify inference that made Option A a lie.

- **AC1** — Campaign **reached final verification** (predicate: `run_sequential_final_verify` at `:4358` ran) → exit-trap row has `us_id == "final-verify"`. **A8-ii:** my original "reaches final verification **and** exits COMPLETE" was two predicates with one test — COMPLETE-without-final-verify is reachable, and it re-opens the exact lie I rejected Option A for. Test the final-verify predicate; do not conjoin COMPLETE.
- **AC2** — Campaign exits BLOCKED before final verification → `us_id == "campaign-exit"` (never `final-verify`, never `unknown`).
- **AC2b (new, A8-i)** — Campaign exits **TIMEOUT** (max-iter or signal, no sentinel) → `us_id == "campaign-exit"`, never `unknown`. The bucket derivation must **reuse `cleanup`'s existing three-way sentinel test** rather than re-deriving it, so the two cannot drift.
- **AC3** — In-loop call at `run_ralph_desk.zsh:6425` emits a byte-identical row to today (per-US attribution via `signal_us_id` preserved).
- **AC4** — Existing rows render unchanged where `us_id` is **absent-or-`"unknown"`**. **A8 refinement:** `.rlp-desk/logs/v0230-polish/cost-log.jsonl` contains a row with the `us_id` key **absent entirely** (pre-field schema) — verified, `jq 'has("us_id")'` → `false`. The renderer's `jq -r '.us_id // "unknown"'` at `lib_ralph_desk.zsh:2176` already handles it, so the AC is satisfiable; it was just untested as originally worded.
- **AC4b (new, A8-iii — latent duplicate rows)** — Exactly one cost-log row per iteration number. Today `write_cost_log "$ITERATION"` runs in-loop at `:6425` **and again** from the cleanup trap with the same `${ITERATION}` on paths that pass `:6425` first — e.g. the stale-context BLOCK at `:6439-6444`, which `return 1`s straight into cleanup. The renderer sums `estimated_tokens` across all rows, so that iteration is double-counted. Observed logs are clean ⇒ **latent** — but US-004 upgrades a duplicate `unknown` into a duplicate *named* bucket that reads as authoritative, which is worse. AC6 does not catch it: `COST_LOG_FINAL_WRITTEN` prevents a second *trap* write, not trap-after-in-loop.
- **AC5** — Logs with `final-verify` / `campaign-exit` rows render those bucket names in first-seen order (`final_model_us_order`).
- **AC6** — `COST_LOG_FINAL_WRITTEN` idempotence unchanged; exactly one exit row per campaign.

### Verification commands
```bash
set -euo pipefail

# AC1/AC2/AC2b/AC3/AC4/AC4b/AC5/AC6
zsh tests/test_cost_log_us_id_bucket.sh
#   Harness contract (assert ALL):
#     AC1  FINAL_VERIFY_RAN=1  -> exit row us_id == "final-verify"
#     AC2  BLOCKED before final verify -> "campaign-exit"
#     AC2b TIMEOUT (no sentinel) -> "campaign-exit", never "unknown"
#     AC3  in-loop row at :6425 byte-identical to today
#     AC4b exactly ONE row per iteration number across the
#          stale-context path (:6439-6444) that writes at :6425 then traps
#     AC6  exactly one exit row per campaign (COST_LOG_FINAL_WRITTEN)

# ONE authoritative flag — no second derivation may exist (Critic #6)
test "$(grep -c 'FINAL_VERIFY_RAN' src/scripts/run_ralph_desk.zsh)" -ge 2
# the bucket decision must NOT branch on sentinels
! grep -A6 '_emit_final_cost_log' src/scripts/run_ralph_desk.zsh | grep -q 'COMPLETE_SENTINEL'

# AC4 — backward compat against REAL historical logs: absent-or-"unknown" both render.
jq -e 'has("us_id")|not' .rlp-desk/logs/v0230-polish/cost-log.jsonl >/dev/null   # key-absent row exists
jq -e 'select(.us_id=="unknown")' .rlp-desk/logs/sv-oracle/cost-log.jsonl >/dev/null

npm run test:zsh && npm run test:fast && npm run sv-gate:fast
```
**Dependencies:** none.

---

# US-005 — Parity-guard completeness (two independent MINORs)
**Risk: LOW** · test-only, no runtime code · no SV gate
File: `tests/node/install-sh-manifest-parity.test.mjs` (354 lines, 19 tests green)

## US-005a — Pin the markdown-directory shipping decision

**Evidence gathered:**
| Directory | Tracked files | Fetched by install.sh | In `markdownDirectories()` |
|---|---|---|---|
| `docs/rlp-desk/blueprints` | 4 | **4** (install.sh:125-128) | yes |
| `docs/rlp-desk/plans` | 12 | **0** | yes |
| `docs/rlp-desk/internal` | 0 (gitignored) | 0 (removed in 251f766) | yes |

Today `markdownDirectories()` is consumed by `reverseCoverage` **only as an escape hatch** — nothing asserts the forward direction, so plans/ shipping 0 of 12 is invisible. That is an accident, not a decision.

### Options
| Option | Rule | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. curl = user-facing minimum** — blueprints fully shipped; plans + internal explicitly excluded and pinned | Matches the code evidence exactly (4/4 vs 0/12 vs 0/0), matches the npm-vs-curl split already in CLAUDE.md (npm ships plans via postinstall; curl doesn't), matches 251f766's intent. | Zero behaviour change; converts an accident into a pinned decision. | Needs a maintained, commented exclusion set. | **CHOSEN** — this is the recommendation you asked for, and code evidence supports it |
| B. Full parity — curl fetches all 12 plans | Channels identical. | +12 round-trips per curl install for maintainer-facing docs; and `internal/` is gitignored so full parity is *impossible* there — it would re-introduce the exact 404-abort break 251f766 just fixed. | Rejected |

### Acceptance criteria
- **AC1** — Every directory in `markdownDirectories()` is classified as **shipped-in-full** or **explicitly-excluded** via a named commented constant (`MARKDOWN_DIR_CURL_EXCLUSIONS`). A directory in neither set FAILS by name.
- **AC2** — For shipped-in-full dirs (blueprints), every **git-tracked** file must have a literal `fetch` line; a tracked-but-unfetched file is reported by path. *(Tracked, not readdir — the dir holds untracked local scratch in normal use.)*
- **AC3 (mutation/negative)** — A synthetic extra tracked file injected into the blueprints list is reported missing by name — proves non-vacuity.
- **AC4** — plans + internal in the exclusion set: their absence from install.sh is accepted, **and** the presence of *any* fetch line under an excluded dir FAILS (exclusion is bidirectional — no half-shipping).
- **AC5** — A new directory added to `markdownDirectories()` without a decision FAILS with a message naming it and telling the maintainer to classify it.
- **AC6** — The exclusion constant carries an inline comment with the decision, date, and rationale ("curl channel = user-facing minimum; npm/postinstall ships plans, curl does not; internal/ is gitignored — fetching it 404s and `curl -f` aborts the whole install, the 2026-08-10 break").

## US-005b — Broaden the no-exec property check

**Problem:** the AC4-boundary test (~line 340) only defends against `execFileSync('bash', …)`:
```js
const forbiddenExec = /execFileSync\(\s*['"]bash['"]\s*,\s*\[\s*(?!['"]-n['"])/;
```
`spawnSync`, `exec`, `execSync`, `execFile`, `fork`, or `execFileSync(installShPath)` all slip through — any of which would *run* the installer.

### Acceptance criteria
- **AC7** — Every `node:child_process` API (`exec`, `execSync`, `execFile`, `execFileSync`, `spawn`, `spawnSync`, `fork`) is enumerated; the only permitted occurrence is the sanctioned `execFileSync('bash', ['-n', installShPath])`.
- **AC8** — The sole `node:child_process` import binding is `execFileSync` — a future `spawnSync` import fails at the import site, before any call-site regex is needed.
- **AC9 (negative, self-testing)** — Synthetic sources containing `spawnSync('bash', [installSh])`, `execSync('bash install.sh')`, and `execFileSync(installShPath)` are each rejected by name — proves AC7 non-vacuous. *(Requires extracting the inline regex into a named exported-for-test predicate; existing checks must be re-expressed through it, not duplicated.)*
- **AC10** — The current file PASSES (no false positive on the sanctioned `bash -n` line), and the "self-source scan must not false-positive on its own forbidden-API list" trap — already handled for network modules at ~line 330 — is handled the same way here.

### Verification commands
```bash
node --test tests/node/install-sh-manifest-parity.test.mjs      # must stay green, now >19 tests
git ls-files docs/rlp-desk/blueprints | wc -l                    # 4
grep -c 'fetch "\$REPO_URL/docs/rlp-desk/blueprints/' install.sh # 4
git ls-files docs/rlp-desk/plans | wc -l                         # 12
grep -c 'fetch "\$REPO_URL/docs/rlp-desk/plans/'  install.sh     # 0
npm run test:fast && npm run manifest:check
npm run verify:sync && npm run verify:sync -- --strict-chmod
```
**Dependencies:** none. 5a and 5b touch the same file — land in one commit to avoid conflict; logically independent.

---

## Execution order & dependency graph
```
US-001 (CRITICAL, SV gate)  ─┐
US-002 (HIGH)               ─┤  independent EXCEPT the commit-coupling below
US-003 (MEDIUM)             ─┤
US-004 (LOW)                ─┤
US-005a+b (LOW, same file)  ─┘
```
**Commit-coupling — GATE SPLIT (TEAM-LEAD DECISION 2026-08-10, supersedes the one-gate batching):**
```
Gated commit 1 (US-001)   ==  AC1a/AC1b/AC1c + AC2 + AC4-AC7
                           +  US-003 AC6a  (channel label at rlp-desk.md:554-556)
                           +  US-003 AC6b  (native verify_partial branch)
Gated commit 2 (Option D) ==  US-002 Option D registration instruction + downgrade
                           +  the architect's 4-case test (incl. negative control,
                              stale-PID, self-exclusion) as one verifiable unit
```
AC6a/AC6b stay on commit 1: they are zero-runtime prose edits to the same branch
table US-001 already rewrites. Option D is a NEW runtime action the native leader
performs every campaign — different risk class, own gate. Rationale: D1 over D3 —
if Option D's instruction fails its SV scenario, the CRITICAL codex-liveness fix
must not be blocked behind it. Cost: two 3-scenario gates (6 total), accepted.

**Sequencing:** ① US-001 gated commit 1 (unblocks all codex dogfooding) →
② US-002 **Option A** immediately, gate-free (pure zsh files) →
③ Option D as gated commit 2 → ④ US-003 remainder (AC1-AC5, AC6c), US-004,
US-005 in any order. Everything outside the two gated commits is independent.

## Files touched, by SV-gate exposure
| SV gate | Files | US |
|---|---|---|
| **⚠️ YES — gated commit 1** | `src/commands/rlp-desk.md`, `src/governance.md` | US-001 (AC1a-AC8) **+ two prose riders**: US-003 AC6a, AC6b. Corrected per Critic #4 — the earlier "US-001 only" was false. |
| **⚠️ YES — gated commit 2 (separate)** | `src/commands/rlp-desk.md` (native registration instruction only) | US-002 Option D. **Team-lead gate split 2026-08-10**: a new per-campaign runtime action is a different risk class from prose edits and must not gate the CRITICAL fix. |
| No | `src/scripts/run_ralph_desk.zsh` | 001, 002 (A **and** D's zsh-side read/sweep/downgrade), 004 |
| No | `src/scripts/lib_ralph_desk.zsh` | 001 (`_codex_launch_with_hook_fallback` seam), 002, 004 |
| No (**but `src/node/MANIFEST.txt:1` ⇒ local-sync obligation**) | `src/node/cli/command-builder.mjs` | 001 |
| No | `src/node/runner/campaign-main-loop.mjs` (parity only — dead leader, see A3) | 001, 003 |
| No | `docs/rlp-desk/{failure-modes,signal-protocol,protocol-reference}.md` | 001, 002, 003 |
| No | `tests/**` | all |

`src/scripts/init_ralph_desk.zsh` is **not** touched by any US as planned — Option B in both US-001 and US-002 was rejected partly on that basis.

## Repo-wide gate, once before merge
```bash
npm run test:fast && npm run test:zsh && npm run sv-gate:fast \
  && npm run verify:sync && npm run verify:sync -- --strict-chmod \
  && npm run manifest:check
# plus (US-001 touches governance): the 3 CLAUDE.md SV scenarios LOW/MEDIUM/CRITICAL — all PASS
# then: local sync via `npm install` + banner-aware §4.5 verification (Tier-1)
```

## Known residual risks (stated, not hidden)
1. **US-001** depends on a third-party CLI feature flag we don't own. **Residual #1 as originally written was backwards** (architect, accepted): the probe runs once at init while campaigns run for hours, so the dangerous case is not "flag absent at init" — it is a **stale-true probe against a binary replaced mid-campaign**, which is a total outage on every subsequent launch, not graceful degradation. AC7 (retry-once on `Unknown feature flag`, then strip) is the mitigation; AC2's column-1 name-presence predicate stops a `removed`-state flag from being wrongly dropped. AC5's negative control remains the live canary — keep it in the suite.
2. **US-002 Options A+D** still do not cover a **human** editing the tree. A narrows the window to one iteration; D closes the cross-mode (native↔zsh) case including the same-worker-window race. zsh↔zsh was never possible (per-`ROOT_HASH` exclusive runner lock). `--worktree` would cover the human case too, but is tmux-only. Documented, not fixed.
3. **US-003** adds tolerance for a key absent from the current source tree — justified by a real recorded field incident (`verification-history.md:94`), but it is defensive code by definition.

## Key file references (absolute)
- `/Users/plletdata/dev/rlp-desk/.rlp-desk/logs/sv-oracle-nv/runtime/omx-state/.omx/state/sessions/019fe75c-23c9-7ae3-8a91-4646c6959920/skill-active-state.json` — the `"keyword": "Don't assume"` / `"source": "keyword-detector"` proof for US-001
- `/opt/homebrew/lib/node_modules/oh-my-codex/dist/mcp/state-paths.js` — `getBaseStateDirWithSource()`, the env precedence chain
- `/opt/homebrew/lib/node_modules/oh-my-codex/dist/hooks/keyword-detector.js` — `isNegativePrefixExemptImplicitKeyword`
- `/Users/plletdata/dev/rlp-desk/src/scripts/run_ralph_desk.zsh:1413` — the `comm -23` subtraction at the heart of US-002
- `/Users/plletdata/dev/rlp-desk/src/scripts/run_ralph_desk.zsh:246` — `_emit_final_cost_log`, the US-004 emit site
- `/Users/plletdata/dev/rlp-desk/src/scripts/lib_ralph_desk.zsh:1837` — `cost_us_id="${signal_us_id:-unknown}"`
- `/Users/plletdata/dev/rlp-desk/tests/node/install-sh-manifest-parity.test.mjs` — US-005 target

**Nothing remains outstanding on this PRD.**
