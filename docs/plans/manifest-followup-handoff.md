# Handoff — manifest-followup wave (2026-08-10)

Branch: `fix/install-manifest-consumers` (off main @ 7c595e3 → 251f766 → this wave).
**Status: 5/6 US complete and committed; US-004 deferred. NOT merged to main —
merge is an explicit owner gate.** This doc + the three sibling `manifest-followup-*`
files are the complete cross-machine continuation kit; nothing needed from the
original machine's `.omc/` state.

## Wave commits (all on this branch, all gates green at each)

| Commit | Story | Content |
|---|---|---|
| 3e17506 (merged to main) | pre-wave | install-sync oracle: byte-exact `verify:sync`, bans hand-rolled banner-strip |
| 251f766 (merged? NO — branch base) | pre-wave | curl channel fix (gitignored internal/ fetch 404-abort) + parity guard 19 tests |
| c59ae4c | **US-001** (SV-gated commit 1) | codex `--disable hooks` probe-gated: zsh probe + chokepoint (13 sites) + strip-and-retry; native leader parity (`--disable plugins --disable hooks`); AC6a Stop-Status channel label + AC6b native `verify_partial` branch; F1.19; failure-modes.md now SHIPS (manifest+install.sh); SV fixture flags; sv-gate-real-e2e hardcoded-path repair |
| e9c10b2 | **US-005** | parity guard 19→33: markdown-dir shipping pin (blueprints full / plans+internal excluded) + no-exec broadening (7 child_process APIs, self-scan boundary) |
| a97704a | **US-002A** | F-8 per-iteration dirty baseline (`ITER_PREEXISTING_DIRTY` union in the comm -23, before the -z guard — `(@f)` hazard pinned); F1.20 |
| 09a4248 | **US-002B** (SV-gated commit 2) | cross-mode leader registry (advisory, per-PID, atomic_write) + F-8 downgrade-to-carryover; native registers `$PPID` (empirically load-bearing); ROOT_HASH canonicalized `pwd -P` (SV A1 — symlink hash divergence silently no-op'd the feature); 4-case + mutation-verified test (53 asserts) |
| 143dcb2 | **US-003** | iter-signal tolerant-read (`stop` legacy accepted, status canonical, 4 synth sites pinned) + signal-protocol.md dual-channel contract + protocol-reference verify_partial |

## TO DO on the next machine

### 1. US-004 — cost-log exit-row bucket (LOW, no SV gate, zsh-only)
Full spec: `manifest-followup-wave-prd.md` §US-004 (amended AC set — includes the
TIMEOUT terminal state, the `FINAL_VERIFY_RAN` single-predicate rule, and the
absent-key backward-compat case). Key implementation constraints (from the
consensus loop — do NOT rediscover):
- One authoritative flag `FINAL_VERIFY_RAN`, set as the FIRST statement inside
  `run_sequential_final_verify` (`run_ralph_desk.zsh` ~:4358 pre-wave numbering);
  bucket derivation must NOT consult sentinels (COMPLETE-without-final-verify
  would lie).
- `write_cost_log` (lib ~:1810) gains an optional `us_id_override` 2nd arg;
  in-loop call site (~:6425) stays byte-identical; exit-trap site
  (`_emit_final_cost_log`, run ~:246) passes `final-verify` when the flag is set,
  else `campaign-exit` — covers COMPLETE/BLOCKED/TIMEOUT, never `unknown`.
- Renderer (lib ~:2140-2260): rows with `us_id:"unknown"` AND rows with the key
  ABSENT entirely (pre-field schema, exists in real logs) keep rendering as
  `unknown`; new buckets render in first-seen order. Never rewrite old logs.
- Architect A8-iii: `write_cost_log` can emit twice for one iteration on exit
  paths that pass :6425 first — add dedup or document acceptance (AC6).
- Test: `tests/test_cost_log_us_id_bucket.sh` (TDD-first; TIMEOUT case included).

### 2. Deferred follow-ups (none blocking)
- `tests/test_bug8_autocommit_robust.sh` emits `command not found:
  _leader_registry_foreign_live` x2 (harness doesn't extract the new helper;
  fails OPEN to auto-commit = status quo). Extract the helper into that harness
  to silence. Zero production impact.
- Release-note line for symlinked-path operators: runner-lock filename changes
  once after the ROOT_HASH canonicalization (old lock = inert clutter).
- sv-gate:full campaign-E2E (sumchk) does not converge on this box at HEAD
  either (haiku Process-Audit flake, pre-existing) — attribution evidence in
  the US-001 commit message. Harness portability was partially fixed
  (sv-gate-real-e2e.sh); the campaign-E2E leg needs its own look someday.
- v0.24.1 F1.18 note: OMX_STATE_ROOT is still correct defence-in-depth; F1.19
  (keyword-detector) was the real mechanism — docs already amended.

### 3. Ship decision (owner)
Merge `fix/install-manifest-consumers` → main (FF), Tier-1 (tag + `npm install`
sync + `verify:sync --strict-chmod`) or Tier-2 per CLAUDE.md. The branch never
pushed/published. After merge, delete this wave's `.omc/plans/*` copies if
desired — `docs/plans/manifest-followup-*` are the durable record.

## Context for whoever picks this up
- The consensus PRD (`manifest-followup-wave-prd.md`) went through
  Planner→Architect(8 amendments, 2 self-corrections)→codex Critic(ITERATE 8
  blockers, all resolved)→gate-split team-lead decision. Read its CORRECTION 1/2
  first — two intuitive root-cause theories were WRONG (stale state; broad git
  add) and the fixes target the proven mechanisms instead.
- SV-gate discipline used here: 3 scenario walkthroughs (worker) + independent
  opus verifier with mutation controls, per gated commit. Two gates were paid
  (deliberate D1-over-D3 split, rationale in the PRD sequencing section).
- Verification style that caught real bugs: mutation controls everywhere
  (re-inject the defect → tests must fail), independent harnesses (no fixture
  reuse), and empirical probes over prose claims ($$/PPID, symlink hashes,
  removed-state feature flags).
