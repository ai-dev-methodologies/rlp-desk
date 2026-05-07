# PR-E: Phase C1 — Blocked Sentinel Recovery Hygiene (Planner v0)

> **Plan reference**: `docs/plans/v0.15-stabilization-plan.md` §5 Phase C
> **Continuation of**: PR-A (Bug #10 phase=verify recovery, commit `95c0d4e`)
> **Stop rule**: codex critic APPROVE (P0+P1=0) before merge
> **Critic instruction**: approve unless P0 or P1 found

---

## 1. Problem

After PR-A landed (`phase=verify` recovery honored), the next recovery surface is **operator-cleared BLOCKED**.

Today, when operator clears `<slug>-blocked.md` to recover (the documented manual recovery for some BLOCKED reasons), `status.json` retains:
- `phase: "blocked"` (stale)
- `consecutive_failures` and `consecutive_blocks` counters at their pre-BLOCKED values
- `last_block_reason` populated

On leader relaunch:
1. `readCurrentState` (`src/node/runner/campaign-main-loop.mjs:364`) preserves all of these
2. Main loop iterates, tries to dispatch worker
3. If worker fails for any reason, `consecutive_failures` increments from its stale base
4. Circuit breaker may trip immediately even though operator's intent was "fresh start"
5. Result: campaign re-BLOCKs on first failure, operator's recovery effort wasted

This is the same class as Bug #10 (PR-A): operator's recovery intent silently discarded because leader doesn't recognize the recovery surface.

---

## 2. Principles (3)

1. **Operator's recovery intent is the source of truth.** When BLOCKED sentinel is gone but status.json still says blocked + counters stale, the operator clearly meant to reset state. Leader must recognize and honor.
2. **Recovery validation must be strict (mirror PR-A).** Auto-honoring without checks risks accidental honor of crashed-mid-write states. PR-A's 5-check pattern applied to the blocked-recovery context.
3. **Defensive default — fall through, don't break.** If validation fails, log the reason and proceed with current behavior (no auto-reset). Recovery feature can never make existing flows worse.

## 3. Decision drivers (top 3)

| # | Driver | Why |
|---|---|---|
| D1 | **Operator recovery completeness** | PR-A covered phase=verify; phase=blocked is the most-common operator recovery (clear sentinel → relaunch). Closing this gap completes the pair. |
| D2 | **Mirror PR-A pattern** | Same shape (entry-time validate + flag + audit log) reduces cognitive load for future readers. Both Node + zsh same way. |
| D3 | **Counter reset honesty** | Operator clearing the sentinel implies intent to retry from clean state. Stale counters silently re-BLOCK = surprise. |

---

## 4. Viable options

### Option A — Entry-time blocked-recovery branch (mirror of PR-A) **[recommended]**

After `readCurrentState`, before main loop, add a second recovery branch:
- IF `state.phase === 'blocked'` AND blocked sentinel does NOT exist (operator cleared) AND counters are non-zero → **operator-cleared recovery detected**
- Validate (5 checks, see §7)
- On pass: reset phase to 'worker', reset counters to 0, log audit line
- On fail: fall through (current behavior — campaign continues with stale state, may immediately re-BLOCK)

Pros: surgical (single branch, ~30 LOC each side), pattern matches PR-A exactly, defensive default.
Cons: adds another entry-time check (small overhead).

### Option B — Reset on every relaunch unless explicit "preserve counters" flag

Always reset counters when relaunching with no BLOCKED sentinel. Add `--preserve-counters` flag for users who want stale-counter behavior.

Pros: simpler logic.
Cons: changes existing behavior for users who didn't experience this issue. Breaks back-compat for anyone relying on counter persistence across relaunches.

→ **Rejected**: violates principle 3 (defensive default).

### Option C — Document operator workaround instead of code change

Add cookbook entry: "after clearing blocked sentinel, also `jq` zero out counters in status.json".

Pros: zero code change.
Cons: pushes burden to operator. Same class of failure as Bug #10's pre-PR-A state — the leader should recognize recovery, not require operator jq pipelines.

→ **Rejected**: violates principle 1.

**Recommendation: A.**

---

## 5. Scope

### P0 — must land

1. **Node leader entry-time blocked-recovery branch** (`src/node/runner/campaign-main-loop.mjs`):
   - New helper `_validateBlockedRecovery({ paths, state })` — returns `{ ok: bool, reason: string }`. 5 checks (§7).
   - Branch after readCurrentState (around line 1392, where PR-A branch sits) — if `phase === 'blocked'` and validator passes, reset phase + counters + log.

2. **zsh runner mirror** (`src/scripts/run_ralph_desk.zsh`):
   - Mirror helper `_validate_blocked_recovery` in `lib_ralph_desk.zsh`
   - Mirror entry-time branch (similar location to PR-A's site at `:3047-3071` range)

### P1 — must land

3. **Tests**:
   - `tests/node/test-blocked-recovery-hygiene.test.mjs` (NEW, 5 ACs):
     - AC-BR1: phase=blocked + sentinel absent + counters non-zero + valid → reset + dispatch worker normally
     - AC-BR2: phase=blocked + sentinel PRESENT → don't auto-recover, throw "Run clean first" (existing behavior preserved)
     - AC-BR3: phase=blocked + sentinel absent + counters all zero → fall through (nothing to reset)
     - AC-BR4: phase=verify + sentinel absent → defer to PR-A's branch (no double-handling)
     - AC-BR5: phase=blocked + sentinel absent + last_block_reason indicates non-recoverable category (`mission_abort`) → fall through, log "non-recoverable category, manual review needed"
   - `tests/test-blocked-recovery-zsh.sh` (NEW, 5 helper-level scenarios mirroring AC-BR1..5)

### P2 — nice-to-have (deferred)

- Cookbook entry in `docs/rlp-desk/getting-started.md` documenting the recovery flow now that leader honors it
- Telemetry analytics — track how often operator-cleared recovery is detected (signal of campaign reliability)

---

## 6. Files to modify

| File | Change | Risk |
|---|---|---|
| `src/node/runner/campaign-main-loop.mjs` | `_validateBlockedRecovery` helper + entry-time branch | LOW (pattern proven by PR-A) |
| `src/scripts/lib_ralph_desk.zsh` | `_validate_blocked_recovery` helper | LOW |
| `src/scripts/run_ralph_desk.zsh` | Entry-time branch (near `:3047-3071` range) | LOW |
| `tests/node/test-blocked-recovery-hygiene.test.mjs` (NEW) | 5 ACs | LOW |
| `tests/test-blocked-recovery-zsh.sh` (NEW) | 5 zsh scenarios | LOW |

Total: 3 modified + 2 new = 5 files. Smaller surface than PR-A.

---

## 7. Validator: 4 checks (`_validateBlockedRecovery`) — Codex-revised v2

Codex critic P1-1 finding: v1's Check 4 depended on `last_block_reason` field but **no code path persists that field to status.json**. Both Node `_emitBlockedSentinel` and zsh `write_blocked_sentinel` skip it. So the v1 validator would never block auto-recovery for mission_abort/repeat_axis — exactly the safety case it was designed for.

**v2 fix**: detect non-recoverable categories from the **`<slug>-blocked.json` sidecar** (which `_emitBlockedSentinel` DOES write at L942-965, with `reason_category` + `recoverable` fields), not from status.json. The sidecar persists even when operator manually `rm <slug>-blocked.md` — they don't usually delete the sidecar.

Returns `{ ok: bool, reason: string }`:

1. `state.phase === 'blocked'` (precondition)
2. Blocked sentinel `<slug>-blocked.md` does NOT exist (operator cleared)
3. At least one of: `consecutive_failures > 0`, `consecutive_blocks > 0` (something to reset; if all counters zero, fall through — nothing to recover from)
4. **Sidecar safety check**: if `<slug>-blocked.json` exists AND parses AND has `recoverable: false` → fall through with audit log "non-recoverable category <reason_category> from sidecar". If sidecar absent (e.g. user ran full `clean`) OR sidecar `recoverable: true` → proceed with auto-recovery. Mirrors `_classifyBlock` `recoverable` invariant; no new status field needed.

(Check 5 from v0 — 30-day staleness — DROPPED. Architect-flagged as arbitrary.)

On pass: caller resets `state.phase = 'worker'`, `state.consecutive_failures = 0`, `state.consecutive_blocks = 0`. Sidecar (if exists) is RENAMED to `<slug>-blocked.json.recovered-<iso>` for audit trail rather than deleted, so operator can inspect what was recovered from. Then logs:

```
[recovery] Operator-cleared BLOCKED detected (was: <last_block_reason>). Resetting counters and resuming as worker. iter=N us_id=<current_us>
```

On fail: log `[recovery] phase=blocked ignored: <reason>` and fall through to existing behavior.

---

## 8. Pre-mortem (3 scenarios)

### S1 — Auto-recovery hides genuine problem
Campaign keeps BLOCKING because of a real architectural issue. Operator clears sentinel each time. Auto-recovery resets counters → CB never trips → infinite loop of fail+clear.

**Mitigation**: operator-cleared recovery is exactly that — operator chose to retry. If they keep clearing without fixing, the bug pattern is operator behavior, not leader's. Counters resetting is correct; CB still trips on the freshly-accumulated counters from current session. Leader doesn't enable infinite loops, operator does.

**Residual risk**: low. If operator wants CB to persist across relaunches, they can leave the sentinel and use `clean` workflow instead.

### S2 — Mid-write status.json read produces inconsistent state
A previous leader instance crashed mid-`writeStatus`. Relaunch reads partial JSON.

**Mitigation (corrected per Codex critic P2 backlog)**: `writeStatus` uses `writeJson` → `fs.writeFile` directly (NOT atomic rename). Partial writes are theoretically possible. If JSON is malformed, `readJsonIfExists` THROWS (not returns null) — leader fails fast at startup with parse error, surfacing the corruption to operator. Auto-recovery never proceeds because leader doesn't even reach the validator. This is acceptable: corrupted status.json is operator-visible immediately, not silently recovered. P2 backlog item: consider migrating writeStatus to atomic rename for crash safety, but that's a separate PR.

### S3 — Race: operator clears sentinel while leader is starting
Operator deletes blocked.md just as leader's `await exists(paths.blockedSentinel)` runs. Two outcomes:
- Sentinel exists during check → existing "Run clean first" error throws (existing behavior, unchanged)
- Sentinel missing during check → enters validator → if checks pass, recovery proceeds

**Mitigation**: this is a benign race. Both outcomes are valid (operator either succeeded in clearing or didn't). No corruption possible.

---

## 9. Test plan

### Unit (Node)

`tests/node/test-blocked-recovery-hygiene.test.mjs`:

Each AC sets up a fixture (status.json + memos/) per its scenario, runs the leader to first dispatch decision, asserts on dispatch behavior + log content.

- AC-BR1 happy: setup phase=blocked, sentinel absent, consecutive_failures=3 → assert leader dispatches worker (not throw), assert state.consecutive_failures === 0 in next status write, assert audit log line matches
- AC-BR2 sentinel present: setup phase=blocked, sentinel exists → assert leader throws "Run clean first" (existing behavior preserved)
- AC-BR3 nothing to reset: phase=blocked, sentinel absent, all counters zero, last_block_reason empty → assert fall-through (no log line, no reset, normal worker dispatch)
- AC-BR4 phase=verify defers: phase=verify, sentinel absent → assert PR-A logic runs (no blocked recovery handling)
- AC-BR5 non-recoverable category: phase=blocked, sentinel absent, last_block_reason='mission_abort' → assert fall-through with log "non-recoverable category"

### Integration (zsh)

`tests/test-blocked-recovery-zsh.sh` (helper-level, mirrors `test-bug10-zsh-relaunch-hygiene.sh`):

- Scenario BR-Z1: all 5 checks pass → `_validate_blocked_recovery` returns 0
- Scenarios BR-Z2..BR-Z5: each check fails → returns 1 with reason matching expected substring

### Regression

- Full Node suite: 334/334 must remain green
- Bug #10 PR-A tests (test-relaunch-phase-verify-hygiene.test.mjs) must remain green
- Bug #7 zsh regression must remain green

---

## 10. Verification end-to-end

1. `node --test tests/node/test-blocked-recovery-hygiene.test.mjs` → 5/5 PASS
2. `bash tests/test-blocked-recovery-zsh.sh` → 5/5 PASS
3. Full Node suite + Bug #7 regression unchanged green
4. **`zsh tests/sv-gate-fast.sh` PASS** (governance §1g pre-merge gate, Codex critic P1-2)
5. Manual sandbox: deliberately BLOCKED campaign → operator clears blocked.md → relaunch → leader logs `[recovery] Operator-cleared BLOCKED detected`, counters reset, worker dispatches, campaign continues. Repeat with `recoverable: false` sidecar → leader logs fall-through, no auto-recovery.
6. **AC-BR5 fixture must use real `_emitBlockedSentinel` flow** (Codex critic P1-1) — write a sentinel via the actual code path, then test recovery against it. Not hand-authored status.json.

**Release (NOT part of this PR's verification — per Codex critic P1-2 + CLAUDE.md absolute rules)**: any version bump, GitHub release, or npm publish is a SEPARATE user-approved action that follows merge. This PR's verification ends at items 1-6 above. Release decisions are not auto-flow.

---

## 11. ADR (preview)

- **Decision**: extend PR-A's recovery-hygiene pattern to `phase=blocked` operator-cleared scenario
- **Drivers**: D1 operator-recovery completeness, D2 mirror PR-A pattern, D3 counter reset honesty
- **Alternatives considered**: B (always reset, breaks back-compat), C (doc-only, pushes burden to operator)
- **Why chosen**: A surgical, pattern-proven, defensive default, completes Phase C1 without scope creep
- **Consequences**: operator-cleared BLOCKED relaunches now work as intended; no need for jq counter-reset cookbook; logs add `[recovery]` lines visible via `/rlp-desk logs`
- **Follow-ups**: Phase C2 (mid-iter crash recovery), Phase C3 (cross-mission queue recovery), Phase C4 (cookbook entry)

---

## 12. Round-by-round resolution log

| Round | Reviewer | Verdict | Findings |
|---|---|---|---|
| 0 | — | Planner v0 | initial draft |
| 1 | Architect (Claude inline) | ITERATE | 5 edits applied → v1: drop 30-day, add previous_block_reason, expand Check 4 prose, branch ordering, _skipNextWorkerDispatch comment |
| 2 | Codex Critic | ITERATE — 0 P0, 2 P1 | P1-1: Check 4 redesigned to use `<slug>-blocked.json` sidecar `recoverable` field (status.json never persists `last_block_reason`). P1-2: §10.5 release auto-flow removed; SV gate + user approval explicit. P2: S2 mitigation prose corrected (writeJson is not atomic rename; readJsonIfExists throws not returns null). All applied → v2 (current). |
| 3 | Codex Critic | **APPROVE** — 0 P0, 0 P1 | P1-1/P1-2 both closed. §7 sidecar-based gate validated. §10 sv-gate + user-approved release confirmed. **Loop terminated. Implementation can proceed.** |
