# Large-Campaign Self-Verification — Findings Log

Working log for the `taskcli` 12-US large-campaign repro (Track A) and the
methodology-hardening workflow. Confirmed, evidence-backed findings only.
Schema mirrors `docs/rlp-desk/failure-modes.md` (Symptom / Root cause /
Detection / Fix). Severity: CRITICAL (blocks completion on real repos) / HIGH /
MEDIUM / LOW. **No fixes committed yet — pending user approval.**

Repro asset: `tests/sv-large-campaign/{prd,test-spec}-taskcli.md` (12 dependency-
chained US, all auto-verifiable). Engine for first runs: claude sonnet×sonnet
(isolates rlp-desk coordination bugs from model-capability noise + avoids F-1).

---

## Headline — the loop WORKS; "never completes" is brittleness, not breakage

**A clean 12-US `taskcli` campaign reached COMPLETE** (sonnet×sonnet, isolated
tmux, pristine sandbox): 15 iterations, 86 min, a **genuine** product —
`python3 -m pytest` → **102 passed**, and independent test-spec spot-checks
(make_task / corrupt-store→[] / stats invariants / CLI add+list) all pass. No
circuit breakers, no model upgrades, 2 healthy fix-loops, 5 dead-pane/retry
events all auto-recovered. → rlp-desk's core **fresh-context + file-based loop is
FUNCTIONAL** when conditions are clean.

The owner's "never completes" is therefore **brittleness to real-world
conditions**, not a broken loop. The #1 cause is **F-6**: any untracked file in a
real repo → false BLOCK at iter 1. Proven by run 1 (BLOCKED *solely* on two
harness artifacts the worker never touched) vs run 2 (pristine → COMPLETE).
**Implication: harden the brittleness points; a concept redesign is likely NOT
required** (pending Track B ConceptReview confirmation).

---

## F-6 — Bug #8 dirty-tree gate false-BLOCKs on ANY untracked file  ⚠️ CRITICAL

| | |
|---|---|
| Symptom | Campaign BLOCKs at iter 1 (`metric_failure: worker_incomplete_uncommitted: done-claim present but tree dirty`) even though the Worker correctly implemented AND committed its User Story. |
| Root cause | `_bug8_check_synth_allowed` Gate 3 (`src/scripts/run_ralph_desk.zsh:684`) runs `git -C "$ROOT" status --porcelain`, whose output **includes untracked (`??`) files**. Any untracked file in ROOT — OS cruft (`.DS_Store`), logs, editor swap files, local config, build/coverage output, pre-existing untracked files — makes the tree "dirty" and trips the gate. The check conflates "the worker failed to commit its work" with "there exists any untracked file anywhere in the repo." |
| Why it matters | Real user repos are never pristine. This gate is hit on the **synthesis-fallback path** (leader synthesizes `iter-signal.json` from `done-claim.json`), which the claude Worker routinely takes (see F-7). Result: a real campaign false-BLOCKs at iteration 1 → matches the owner's report that rlp-desk "never completes" on real internal projects. |
| Detection | Run 1 (`/tmp/rlp-taskcli-4232`) BLOCKED iter 1. `blocked.json` reason: `worker_incomplete_uncommitted ... (?? campaign-stdout.log)`. Worker's `done-claim.json` shows a successful `git commit dff7f86 (2 files, 88 insertions)` for US-001 — its own files WERE committed. The only "dirty" entries were two harness artifacts the test driver wrote into ROOT (`campaign-stdout.log`, `CAMPAIGN_DONE`), proving the gate blocks on files the worker never touched. |
| Proposed fix | (a) Minimal: Gate 3 should ignore untracked files — `git status --porcelain --untracked-files=no` (or filter `^??`), so only modified/staged-but-uncommitted **tracked** changes count as "worker incomplete." (b) Robust: verify the worker's *claimed commit landed* (HEAD advanced vs iter-start, or matches the `commit` execution_step hash in done-claim) instead of demanding a pristine tree. Recommend (a)+(b). |
| Status | **FIXED + verified (not committed — pending approval).** Fix at `run_ralph_desk.zsh:684` → `git status --porcelain --untracked-files=no`. Deterministic gate regression `tests/sv-large-campaign/test-f6-dirty-tree-gate.zsh` → **5/5 PASS** (old gate blocks on cruft; fixed gate ignores cruft but STILL blocks uncommitted TRACKED edits → Bug #8 intent preserved). End-to-end run on a deliberately-dirty repo (`?? local-notes.txt`) in progress to confirm a realistic repo now completes. |

## F-8 — recoverable Worker commit-slip hard-BLOCKs the campaign  ⚠️ CRITICAL (weak-model)

| | |
|---|---|
| Symptom | With the DEFAULT haiku Worker the campaign BLOCKs mid-way (`metric_failure: worker_incomplete_uncommitted … ( M <file>)`) even though the Worker did the work: its done-claim says "Committed …" but the `git commit` never landed, leaving the US work as an uncommitted TRACKED modification. |
| Root cause | Weak models frequently report a commit in their done-claim that did not actually execute. Gate 3 of `_bug8_check_synth_allowed` correctly detected the uncommitted TRACKED change but TERMINATED the campaign (BLOCKED, exit 1) instead of recovering — even though the sidecar marks the state `recoverable: true` and the completed work sat on disk, recoverable by a trivial commit. |
| Why it matters | The #1 "never completes" cause for the DEFAULT (haiku) Worker — exactly the owner's deployed config. Distinct from F-6: that was untracked cruft; this is the Worker's own uncommitted TRACKED work. Same root pattern: **the Bug #8 gate TERMINATES where it should RECOVER.** |
| Detection | haiku run `/tmp/rlp-taskcli-haiku`: BLOCKED iter 10/40 (US-006). `git diff` showed 55 legit insertions to `test_us006_delete_task.py` uncommitted; the done-claim's commit step summary read "Committed test additions for US-006" (claim ≠ reality). 9 US committed before the slip; product genuine so far (63 tests pass). |
| Fix | Gate 3 now AUTO-COMMITS the Worker's uncommitted TRACKED changes (`git add -u` — never untracked cruft) and proceeds. The Verifier (test-spec) remains the real correctness gate, so a genuine mid-write bail still FAILs verify → fix loop (Bug #8 "no false PASS" preserved). Only a failed auto-commit BLOCKs. (`src/scripts/run_ralph_desk.zsh` Gate 3.) |
| Status | **FIXED + unit-verified** (`tests/sv-large-campaign/test-f8-commit-slip-recovery.zsh` → 5/5 PASS). End-to-end haiku re-run in progress. NOT committed (pending approval). |

## F-9 — model-upgrade chain "did not engage"  · DISMISSED (not a defect)

The haiku run showed 0 Worker model upgrades despite struggle. On inspection this is NOT a bug: the campaign terminated on F-8 (commit-slip BLOCK) at iter 10, before consecutive failures reached the upgrade threshold (`CB_THRESHOLD=6`). With F-8 fixed, the upgrade chain is re-evaluated in the haiku re-run. Recorded for transparency.

## F-7 — claude Worker relies on leader synthesis (no direct iter-signal)  · investigating

| | |
|---|---|
| Symptom | After the claude Worker finishes, only `done-claim.json` exists (no `iter-signal.json`); the leader takes the A4 synthesis path, which runs the strict Bug #8 gate (F-6). |
| Open question | Is "worker writes done-claim, leader synthesizes iter-signal" the intended claude-path design, or a Worker-prompt gap (worker should also emit the signal)? If by-design, F-6's strict gate is the whole problem; if a gap, the worker prompt/contract needs the signal step. |
| Detection | Run 1: `memos/` had `taskcli-done-claim.json` but no `taskcli-iter-signal.json`; leader logged the Bug #8 synthesis gate. |
| Next | Confirm from the clean run's debug.log `[FLOW]`/`[GOV]` whether synthesis is the normal claude path. |

---

## F-1 — codex 0.140.0 auto-update prompt hijacks the Worker pane  · HIGH

| | |
|---|---|
| Symptom | A codex Worker never produces output; the campaign stalls/fails at the answer stage. |
| Root cause | codex 0.140.0 shows an interactive auto-update prompt on launch ("1. Update now (runs `npm install -g @openai/codex`) … Please restart Codex"), which captures the pane instead of the task. |
| Detection | N×M harness C1 (W=codex/V=codex) smoke: L1/L2 PASSED, but L4 FAILED — `worker_capture.txt` shows the update banner + "Updating Codex via npm install …". Anti-gaming L4 correctly refused PASS (`got='<none>'`). |
| Proposed fix | Disable codex auto-update before launch (config/env) OR detect+dismiss the update prompt in ready-detection OR pin the codex version. A "Codex Update Prompt" recovery note was added to the methodology doc. |
| Status | **FIX APPLIED, not live-verified.** Both `launch_worker_codex` + `launch_verifier_codex` now detect the update banner (`Update available` / `1. Update now`) and select "2. Skip" (Down→Enter) BEFORE the `›` ready check — guarded, so harmless in any normal pane state. NOT live-verified: the methodology workflow's own C1 smoke *ran* the update, bumping codex 0.140→**0.141**, so the prompt no longer appears until the next codex release; the Down→Enter sequence is inferred from the menu and pending live confirmation. Upside: codex 0.141 makes the codex engine path usable for N×M testing now. Detection + ordering are now fault-injection-verified (`test-f1-codex-update-dismiss.zsh` → 4/4: the real captured prompt is classified DISMISS and never mis-read as "ready" despite its embedded `›`); true live (Down→Enter against a real prompt) still awaits codex 0.142. |

## F-2 — `init_ralph_desk` help text contradicts ADR-001  · LOW (doc)

| | |
|---|---|
| Symptom | `init` prints `--mode agent|tmux (default: agent)`. |
| Root cause | Stale help text; ADR-001 / Wave D flipped the default to tmux and made `--mode agent` HARD-ERROR (exit 2). |
| Detection | `init_ralph_desk.zsh` run output. |
| Proposed fix | Update help to `--mode tmux` default and note `--mode agent` is removed (ADR-001). |
| Status | CONFIRMED. |

## F-3 — N×M harness `cell-result.json` emits all-null fields  · LOW (test tooling)

| | |
|---|---|
| Symptom | `tests/sv-nxm-matrix/results/*/cell-result.json` has `cell/worker/verifier/status/real_llm/evidence/reason = null` (only `ran:true`). |
| Root cause | The cell-result emitter does not populate fields from the cell run. |
| Detection | jq over the 5 result files from the methodology workflow. |
| Proposed fix | Populate the JSON from the cell's env + measured outcome so SV results are machine-readable. |
| Status | CONFIRMED. |

## F-4 — methodology doc debug tags drift from runner tags  · LOW (doc)

| | |
|---|---|
| Symptom | Doc greps `[PLAN]`/`[EXEC]` but the runner emits `[FLOW]`/`[OPTION]`/`[DECIDE]`/`[GOV]`/`[VALIDATE]`. |
| Root cause | Doc tag names predate the current runner taxonomy. |
| Detection | Live `debug.log` (analytics dir) contained `[FLOW]`/`[OPTION]`, never `[PLAN]`. |
| Proposed fix | Align the methodology doc's three-phase logging section to the actual tag set. |
| Status | CONFIRMED. |

## F-5 — Leader stdout repeats full pane captures (very noisy)  · LOW (observability hygiene)

| | |
|---|---|
| Symptom | `campaign-stdout.log` repeats entire `tmux capture-pane` dumps (`pane_check=…` ×4+, `pane_output_for_retry`, `check_capture`, `retry_capture`) per readiness/submit poll. |
| Root cause | Verbose pane captures are echoed to stdout unconditionally during ready/submit/retry polling. |
| Detection | Run 1 stdout. |
| Proposed fix | Gate raw pane-capture echo behind a higher verbosity level; keep concise status lines at default. |
| Status | CONFIRMED. |

---

## Track B (ConceptReview) — verdict + sibling findings (same terminate-vs-recover class)

**VERDICT: sound-with-fixes (harden, NOT redesign)** — converges with Track A. The clean 12-US completion refuted the "structurally fragile" lean; the real failure class is the leader's decision gates over-eagerly TERMINATING (not the F1/F2 sentinel/pane races). ConceptReview audited all 21 `write_blocked_sentinel` sites; Track A verified these siblings of F-6/F-8 in the code.

## F-10 — Verifier poll-failure hard-BLOCKs while Worker poll-failure retries (asymmetric)  ⚠️ HIGH
| | |
|---|---|
| Symptom | A single transient Verifier death/stall (API blip, pane race) terminates the whole campaign, where the identical Worker condition would have survived. |
| Root cause | Worker poll-fail uses a 3-strike `MONITOR_FAILURE_COUNT` CB + retry (`run_ralph_desk.zsh` ~3275-3294, hardened earlier by "Bug Report #5"). The Verifier poll-fail path (~3446-3455) still does the OLD unconditional `write_blocked_sentinel` + `return 1` — the exact behavior Bug Report #5 removed from the Worker. The verifier-pane `replace_worker_pane` helper already exists (~2533) but isn't used here. |
| Fix | Give the Verifier the same 3-strike + `replace_worker_pane` retry before BLOCK (more invasive: verify-dispatch retry loop, engine-aware re-dispatch). |
| Status | **FIXED + fault-injection-verified.** Added a 3-strike replace+re-dispatch loop at the verifier-poll site (mirrors the Worker's Bug-Report-#5 breaker). `tests/sv-large-campaign/test-f10-verifier-poll-retry.zsh` → 4/4 PASS (transient 2× → recovers; 3× → BLOCK; rc==2 → no-retry). **The fault-injection test caught a real latent bug** (F-10b): the original `if ! poll; then local rc=$?` captured the *if-statement* status (always 0), NOT poll's rc — so the `rc==2` ("hard-failed, do-not-retry, infra_failure already recorded") branch was DEAD and every poll failure double-wrote a sentinel. Fixed by capturing the rc directly. NOT committed. |

## F-11 — Worker/Verifier pane-start failure hard-BLOCKs instead of replace+retry  · MED-HIGH
| | |
|---|---|
| Symptom | If `launch_worker_*` fails to bring the pane up (the F6.1 "send-keys before shell ready" spawn race — transient), the campaign BLOCKs immediately. |
| Fix | `replace_worker_pane` + one retry before BLOCK. |
| Status | **FIXED + fault-injection-verified.** Confirmed at the Worker-dispatch site (both engines). Now replaces the pane + retries once before BLOCK. `tests/sv-large-campaign/test-f11-worker-start-retry.zsh` → 3/3 PASS (1 transient → recovers; 2 consecutive → BLOCK). NOT committed. |

## F-12 — `verify_partial_malformed` → mission_abort instead of fix loop  · MED
| | |
|---|---|
| Symptom | A fresh-context Worker formatting slip (empty `verified_acs` on a `verify_partial` signal) hard-aborts the campaign. |
| Root cause | `run_ralph_desk.zsh:3340` writes `write_blocked_sentinel … "mission_abort"` for empty `verified_acs`. |
| Fix | Treat as soft-fail → route to the fix loop (same as a `fail` verdict), don't abort. |
| Status | **FIXED + verified.** Malformed verify_partial now soft-fails to a Worker retry bounded by the consecutive-failure CB (repeated malforming still trips the breaker) instead of a terminal mission_abort. `tests/sv-large-campaign/test-f12-verify-partial-softfail.zsh` → 4/4 PASS. NOT committed. |

## F-13 — circuit-breaker counter not restored on relaunch (CB evasion)  · MED → FIXED
| | |
|---|---|
| Symptom | A crash-looping campaign resets `consecutive_failures` to 0 on every relaunch, evading the circuit breaker (a clean run never exercises this). |
| Root cause | status.json persists `consecutive_failures` (`lib_ralph_desk.zsh:677`) but the relaunch restore (`run_ralph_desk.zsh` ~3032-3053) only read back `verified_us`. |
| Fix | Restore `consecutive_failures` from status.json alongside `verified_us`. |
| Status | **FIXED + verified** (`tests/sv-large-campaign/test-f13-cb-counter-restore.zsh` → 4/4 PASS). NOT committed. |

## F-14 — VERIFIED_US restored via sed-parse of LLM prose (fresh-context drift risk)  · MED
| | |
|---|---|
| Symptom | Which US are "done" is recovered by sed-parsing the Worker's prose `## Completed Stories` in memory.md (`run_ralph_desk.zsh:3036`); a fresh-context formatting drift can mis-restore VERIFIED_US. |
| Fix | Make a durable append-only verdict ledger the source-of-truth for VERIFIED_US (a status.json fallback already exists at ~3044; promote it / add a structured ledger). |
| Status | **FIXED + verified.** Added a durable append-only JSONL ledger (`${SLUG}-verified.jsonl`) the leader writes on every verified-pass; restore reads it FIRST (drift-proof, structured), with the prose parse + status.json as fallbacks. Robust to a corrupt/partial trailing line (`jq -rR 'fromjson?'`). `tests/sv-large-campaign/test-f14-verified-ledger.zsh` → 8/8 PASS. **Item-4 promotion**: restore precedence reordered to ledger → status.json (structured leader serialization written every phase by `update_status`) → prose (drift-prone LLM, LAST resort), so the only drift-prone source is now the absolute fallback. |

## F-15 — N×M harness L4 broken for ALL engines (codex trust prompt + unreliable reversal task)  · FIXED
| | |
|---|---|
| Symptom | Full N×M re-run: **ALL 4 cells FAIL at L4:nonce_roundtrip** — C1 codex×codex, C2 codex×claude, C3 claude×codex, AND C4 claude×claude. Engine-AGNOSTIC (not codex-specific as first suspected). |
| Root cause | The harness's L4 nonce-round-trip drive is broken: the worker pane shows a bare SHELL (`kyjin@… %`) when the task instruction is sent, and the instruction lands in the shell (`/usr/bin/Read: … not a valid identifier`). The methodology workflow that built this harness only ever C1-smoke-tested it (the failure then masked by the codex update prompt), so the claude cells shipped "implemented-unverified" — and are in fact broken. |
| NOT a production bug | Production worker execution is proven by real campaigns: haiku-default + sonnet 12-US and f6mini E2E all COMPLETE with genuine products. The defect is in the test harness, NOT `run_ralph_desk.zsh`. |
| Codex path | Since the harness can't verify it, the codex PRODUCTION path is verified directly via a real f6mini campaign (`WORKER_MODEL=gpt-5.5` codex × claude verifier) on the proven runner — see the codex-E2E result. |
| Fix | TWO causes. (1) codex cells: the directory-trust prompt (= F-16, fixed in run_ralph_desk.zsh; the harness calls the REAL `launch_worker_codex`, so it inherits the fix). (2) claude cells: the L4 round-trip task was "REVERSE the nonce", which weak models (haiku) flub by one char → spurious strict-match FAILs (the worker ran fine — L1/L2/L3 passed — only the reversal was wrong). Replaced with copy+append a fixed `_SVOK` suffix (still echo-proof via exact-match on a string not verbatim in the prompt, but reliable for any LLM) in `tests/sv-nxm-matrix/_cell_body.zsh`. |
| Status | **FIXED + verified.** N×M matrix re-run: **ALL 4 cells PASS** — C1 codex×codex, C2 codex×claude, C3 claude×codex, C4 claude×claude (OVERALL PASS). |
| F-3 note | DISMISSED (false alarm): `cell-result.json` IS populated by `write_result()` with `cell_id/worker_engine/verifier_engine/outcome`; an earlier inspection queried wrong keys (`cell/worker/status`) → null. The matrix ledger was always correct. |

## F-16 — codex 0.141 worker blocks the production campaign ("worker not active")  · OPEN (codex path)
| | |
|---|---|
| Symptom | A real f6mini campaign with a codex worker (`WORKER_MODEL=gpt-5.5`, codex 0.141) × claude verifier BLOCKED at iter 1 / 44s: `[infra_failure] 3 consecutive monitor failures (worker not active)`. claude workers complete the same campaign. |
| Pinned | codex 0.141 launches FINE standalone — TUI box "OpenAI Codex (v0.141.0)", `›` prompt, `pane_current_command=node` — but takes ~14s to come up. In the production run the worker pane ended as a bare zsh shell (`worker_cmd=zsh`): codex EXITED after the instruction was sent. Launch flags are valid (`--disable plugins`, `--dangerously-bypass-approvals-and-sandbox`; an `exec` probe ran clean). |
| Root cause (PINNED) | Two things, both = codex worker NOT fresh-context: (1) codex 0.141 shows a **"Do you trust the contents of this directory? 1. Yes, continue / 2. No, quit"** startup prompt; the leader's `›` ready-detect mis-read it as ready and the worker instruction landed in the menu → "No, quit" → codex EXITED to a bare shell. (2) the codex launch never disabled MCP, so it loaded the user's 8 OMX MCP servers (claude uses `--mcp-config '{}'`; codex had no equivalent). Live traces: codex flips node→zsh ~2s after the instruction while the trust menu is active; with the trust prompt accepted it stays `node` and RUNS the task (validated a real DONE.txt round-trip). |
| Fix | (a) `-c mcp_servers='{}'` added to all 5 codex worker/verifier launch commands (fresh-context). (b) Trust-prompt handler in `launch_worker_codex`/`launch_verifier_codex` ready-loops: detect "Do you trust"/"1. Yes, continue" → Enter (accept default) before the `›` ready check, alongside the F-1 update handler. `tests/sv-large-campaign/test-f16-codex-trust-prompt.zsh` → 5/5. |
| Status | **FIXED — E2E-confirmed live.** The handler fires in a real codex-worker campaign ("Worker codex: directory-trust prompt — accepting (F-16)") and the campaign progresses past the former iter-1 block; codex-worker f6mini COMPLETE; N×M C1/C2 PASS. (Malformed `~/.codex/hooks.json` line-94 warning is non-fatal/unrelated.) |

## F-17 — codex verifier over-strict on the verifier prompt's meta-gates  · FIXED
| | |
|---|---|
| Symptom | A codex×codex f6mini campaign STOPPED at 7/6 iters (no COMPLETE) even though the codex WORKER produced a correct product (models.py, 9 tests pass) and there were 0 worker-not-active failures. The codex VERIFIER returned verdict=fail 4× (1 pass), never converging. |
| Root cause | The verifier prompt's "meta gates" (mandatory L1–L4 layer-coverage sections, per-AC red/green evidence, tracked deliverables) are interpreted PEDANTICALLY by codex (gpt-5.5): it refused a clean PASS citing "the test spec has no L1/L2/L3/L4 layer sections … the verdict cannot be a clean PASS under the prompt's own rules" and "deliverables still untracked / iter signal auto-generated by fallback" — process-meta concerns, not product defects. claude verifiers PASS the same work. |
| Scope | codex VERIFIER only. codex WORKER is fixed + proven (F-16; codex×claude COMPLETE; N×M C1/C2 PASS). claude verifier proven (12-US + f6mini campaigns). |
| Fix | Softened ONLY the format/process meta-gates, uniformly for claude AND codex, in both governance.md (IL-3) and the init verifier-prompt template: (1) layer completeness = ACTUAL coverage not section FORMAT (explicit `## L1/L2/L3` headers + N/A markers no longer mandatory); (2) aggregate (vs per-AC) RED evidence accepted; (3) a "process-meta is NOT a PASS-blocker when ACs are green" principle. The strict CORRECTNESS gates were left UNTOUCHED: Evidence Gate (run all commands + exit codes), IL-4 (≥3 tests + ≥2 categories/AC), IL-5 (skip detection), Anti-Gaming. `tests/sv-large-campaign/test-f17-verifier-gate-contract.zsh` → 10/10 locks "format soft, correctness strict". |
| Status | **FIXED + gate-verified, no weakening.** Formal 3-scenario Self-Verification Gate all COMPLETE with the codex verifier: LOW (f6mini codex×codex), MEDIUM (kvstore file I/O), CRITICAL (safe_path security; reproducibility N/A + IL-4 diversity). NO-WEAKENING empirically proven: the BROKEN control (mutually-unsatisfiable AC) got verdict=fail ×3 (real Evidence-Gate checks: `level()=='LOW'` exit 1), and CRITICAL-v1 (under-specified) correctly BLOCKed on IL-4 diversity + reproducibility — the verifier still rigorously fails work that misses the bar. Every passing scenario showed a fail→pass arc (real scrutiny, not rubber-stamp). |
