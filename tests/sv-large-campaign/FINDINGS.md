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

---

# Codex-review round (pre-main-merge gate)

A codex review of the full `origin/main…HEAD` source diff (before merging to main)
returned **9 issues (1 critical, 4 high)**. Triaged against the actual code: 1
pre-existing/non-issue (dismissed), 4 real defects fixed (F-18…F-21), the rest
lower/mitigated. The 4 fixes were re-verified deterministically AND through the
full real-LLM SV gate (below). All run in an ISOLATED tmux server (`tmux -L`) so
the caller's session is never touched.

## F-20 — recovery-mutex TOCTOU: empty owner treated as stale  ⚠️ HIGH (lock redesign)
| | |
|---|---|
| Symptom | `acquire_slug_lock` (lib_ralph_desk.zsh) reaped a recovery mutex whose `owner` file was EMPTY. An empty owner is the normal mid-creation state (the window between `mkdir "$rmutex"` and the `echo $$ > owner` write), so a second recoverer could `rm -rf` a LIVE just-created mutex → two recoverers both proceed → two leaders on one slug. |
| Fix | Only reap a present-but-DEAD owner immediately; for an EMPTY owner, `sleep 0.3` and re-read — if a PID appears it is a live mid-creation holder (back off via the failing `mkdir`), only if still empty (creator died in the gap) is it a genuine leak and reaped. `mkdir` atomicity serializes any double-reap of a leaked mutex. |
| Verification | `tests/test_zsh4_lock_redesign.sh` 9/9 — added case 6 (empty-owner filled mid-settle → busy, mutex preserved) + case 7 (empty-owner stays empty → reaped after settle). |

## F-21 — F-13 CB-counter restore nested under per-us  ⚠️ HIGH
| | |
|---|---|
| Symptom | The F-13 `consecutive_failures` restore sat INSIDE `if [[ "$VERIFY_MODE" = "per-us" ]]`, so a BATCH-mode relaunch never restored the circuit-breaker counter → CB resets to 0 every relaunch → breaker evadable in batch mode. (Broader than codex flagged: the whole ledger/status verified_us restore was also nested, but that is per-us-only by design; only the CB restore needed to be mode-agnostic.) |
| Fix | Moved the CB-counter restore OUT of the per-us block to function-body scope (a standalone `if [[ -f "$STATUS_FILE" ]]`), so it runs in every verify mode. verified_us restore stays per-us (batch has no per-US progress to rehydrate). |
| Verification | `test-f13-cb-counter-restore.zsh` 5/5 — added a structural guard asserting the CB restore's enclosing `STATUS_FILE` guard is at 2-space (function-body) indent, not nested. |

## F-18 — F-17 softening exceeded format-only (substance exempted)  · MEDIUM (policy-critical)
| | |
|---|---|
| Symptom | The F-17 exemption list included "a leader-synthesized iter signal" and "transiently-untracked deliverables" — these are substantive completeness/process conditions, not FORMAT. Exempting untracked deliverables weakens the completeness check (work that isn't committed could PASS), exceeding the "FORMAT-only, do-not-weaken-verification" mandate. |
| Fix | Narrowed governance.md IL-3 + the init verifier-prompt 10¾ to FORMAT-only (section headers, N/A markers, aggregate-vs-per-AC RED granularity). EXPLICITLY states deliverable COMPLETENESS is NOT exempt ("absent, uncommitted/untracked, or never actually exercised = FAIL"). iter-signal author reframed as out-of-scope (verify the work, not the signal's author) — a scope clarification, not a substance exemption. |
| Verification | `test-f17-verifier-gate-contract.zsh` 13/13 — added F-18 checks: governance says completeness NOT exempt, verifier prompt says uncommitted/untracked = FAIL, and "transiently-untracked deliverables" no longer appears as an exemption. |

## F-19 — F-8 auto-commit was repo-wide (swept operator edits)  ⚠️ HIGH
| | |
|---|---|
| Symptom | F-8 Gate 3 recovery ran `git add -u` repo-wide, committing ALL tracked modifications under a Worker-recovery message — including an operator's pre-existing unrelated tracked edits present when the campaign started. |
| Fix | Snapshot `CAMPAIGN_PREEXISTING_DIRTY` (tracked files dirty at campaign start, `git diff --name-only HEAD`) once before the loop; in Gate 3 commit only worker files = `comm -23 (current dirty) (preexisting)` via a zsh array `git add -- "${(@f)...}"`. If only pre-existing edits are dirty, commit nothing and allow synthesis (Worker already committed its own work). |
| Verification | `test-f8-commit-slip-recovery.zsh` 10/10 — added case B (operator pre-existing edit NOT swept, stays uncommitted) + case C (only pre-existing dirty → no commit, synthesis allowed). |

## Dismissed / unchanged
- **CRITICAL "codex launch shell interpolation"** — PRE-EXISTING on origin/main (`-m $WORKER_CODEX_MODEL …` at 5 sites); this branch only added `-c mcp_servers='{}'`. Operator-supplied values, cmd already runs `--dangerously-bypass-approvals-and-sandbox` (operator-trusted). Not a NEW merge-blocker; backlog: validate/quote model values.
- **verified-ledger raw us_id (F-14)** — the READ side filters via `jq 'fromjson?'` + `grep '^US-[0-9]+$'`, dropping malformed lines; us_id is always `US-NNN`. Low risk, defensive nice-to-have.

## SV gate re-verification (real-LLM, codex verifier + NARROWED prompt, isolated tmux)
Worker→Verifier campaigns run via the SRC init (bakes the F-18-narrowed verifier
prompt) + SRC leader, each inside a separate `tmux -L` server. The caller's tmux
server was verified intact (9 sessions, attached session alive) before/after all
five campaigns — the SV-kills-the-main-session failure mode did NOT recur.

| Scenario | Worker × Verifier | Result |
|---|---|---|
| LOW (f6mini) | sonnet × codex gpt-5.5:high | **COMPLETE** (verdict=pass) |
| MEDIUM (kvstore, file I/O) | sonnet × codex gpt-5.5:high | **COMPLETE** (verdict=pass) |
| CRITICAL (safe_path, security) | opus × codex gpt-5.5:high | **COMPLETE** (verdict=pass; safe_path.py committed iter 1) |
| BROKEN (mutually-exclusive AC) | sonnet × codex gpt-5.5:high | **BLOCKED**, verdict=fail ×4, never COMPLETE |

- **No false-fail**: the narrowed prompt lets the codex verifier PASS correct,
  committed, tested work across all three risk tiers.
- **No weakening**: BROKEN failed every iteration → BLOCKED (4 consecutive
  fails); never falsely passed.
- A first CRITICAL run with a **sonnet** worker BLOCKed (stale) — root-caused to
  WORKER non-compliance (done-claim had no `write_test`/`verify_red` steps; the
  unchanged Worker-Process-Audit correctness gate correctly failed it), NOT a
  narrowing regression. Re-run with an opus worker COMPLETEd cleanly, isolating
  worker quality from the verifier change. (The F-18 untracked-strictness was
  exercised transiently at iter 2 and self-resolved when the worker committed —
  no deadlock; safe_path.py ended TRACKED+committed.)

---

# Exhaustive audit round (5-agent fan-out)

A 5-agent parallel audit derived EVERY termination site, race/TOCTOU point,
state-persistence path, poll/timeout/liveness mechanism, and verdict/dispatch
edge case in the leader. Agent line numbers were NOT trusted — every finding
below was re-verified against the actual code before action (several agent line
refs were wrong, e.g. `check_no_progress` cited as lib:1705 but is run:1705).
Cross-agent dedup + verification yielded the fixes (F-22..F-26) and a documented
backlog (real, but each needs careful design / carries false-fail or dispatch
regression risk — deliberately NOT rushed, per "don't introduce new bugs").

## FIXED (verified + tested; all run/lib only — formal SV-gate not triggered)

### F-22 — consecutive-blocks CB was DEAD CODE; a single "blocked" killed the campaign  ⚠️ HIGH
| | |
|---|---|
| Symptom | `_check_consecutive_blocks` (run:137) was DEFINED but NEVER called (0 call sites). So governance §8's consecutive-blocks breaker never ran in zsh, AND a single transient `blocked` verdict (run:3772) or worker `status=blocked` signal (run:3785) wrote a terminal sentinel + `return 1` on the FIRST occurrence — a fresh-context LLM mis-emitting "blocked" (format slip, confusion) ended the whole campaign. Separately, `request_info`, unknown verdict, and unknown signal status fell through with NO `CONSECUTIVE_FAILURES++` → a looping verifier/worker spun silently to MAX_ITER with no diagnostic BLOCK. |
| Fix | Added `_bump_consecutive_failure` + `_block_with_grace` (run:~167). Both block paths now route through `_block_with_grace`: a recoverable first/transient block is ABSORBED as a soft-fail (worker retries); terminal only on a genuine `infra_failure`, the same canonical reason repeated >= BLOCK_CB_THRESHOLD (the now-LIVE consecutive-blocks CB), or the consecutive-failures CB. `request_info` / unknown verdict / unknown signal now `_bump_consecutive_failure` so the CB fires instead of spinning to MAX_ITER. |
| Verification | `test-f22-block-grace-cb.zsh` 12/12 — behavioral (absorb first, terminate on infra/repeat/CB-ceiling) + structural (the dead function now has a call site; both block paths + 3 soft-fail paths wired). |

### F-23 — verifier phrasing variant stranded a complete campaign at MAX_ITER  ⚠️ HIGH
| | |
|---|---|
| Symptom | Completion + final-verify hinged on exact byte matches: `recommended == "complete"` (run:3667) and `signal_us_id == "ALL"` (run:2793, 3487, 3667). A verifier returning `"completed"`/`"done"` or a worker emitting `us_id:"all"` (lowercase) → never matched → "passed but did not recommend complete. Continuing." forever until MAX_ITER timeout despite genuine completion. |
| Fix | Normalize at read: `recommended="${recommended:l}"` + accept `(complete\|completed\|done)`; `signal_us_id="${signal_us_id:u}"` (no-op for well-formed `US-001`). |
| Verification | `test-f22-block-grace-cb.zsh` structural cases. |

### F-24 — runner-lock stale-recovery ABA race → two leaders on one ROOT  · DEFERRED → D-9
| | |
|---|---|
| Symptom | The per-ROOT runner lock (run:2958) recovers a stale lock with naive `rm -rf "$RUNNER_LOCKDIR"; mkdir` — the SAME empty-owner/ABA race `acquire_slug_lock` was hardened against in F-20, but never ported to the runner-level lock. A second relauncher could `rm -rf` the dir the first just won → two leaders on one ROOT (the runner lock is the only guard for same-ROOT-different-slug). |
| Status | **NOT fixed this round — REVERTED to original, deferred to D-9.** A first attempt added settle+re-read+post-write-confirm, but the codex re-review correctly noted it only REDUCES the race probabilistically, not closes it (a delayed recoverer can still delete a winner's dir; the timing-based confirm is no hard guarantee). A half-fix gives false confidence → reverted (original restored; pre-existing rare race, no regression). The CORRECT fix delegates the runner lock to the proven race-safe `acquire_slug_lock` (file-based, F-20-hardened, 9/9 tested) + a metadata sidecar — tracked as D-9. |

### F-25 — `$?`-in-`if !`-body in run_single_verifier (latent, F-10 sibling)  · MEDIUM
| | |
|---|---|
| Symptom | `if ! poll_for_signal …; then local verifier_poll_rc=$?` (run:2668) captured the if-statement status, not poll's rc — the rc==2 branch was dead (currently benign: both arms `return 1`). The exact pattern F-10 fixed at the main verifier poll site, missed here. |
| Fix | Capture rc directly after a bare call; keep the rc==2 "sentinel already written" branch live. |

### F-26 — `atomic_write` swallowed cat/mv failures (truncated sentinels)  · MEDIUM
| | |
|---|---|
| Symptom | `atomic_write` (lib:240) did `cat > tmp; mv tmp target` with no error checks. A truncated tmp (ENOSPC/SIGPIPE/full disk) was atomically renamed into the canonical path; a half-written complete/blocked/status sentinel passes existence checks and mis-drives or falsely terminates the campaign. Used by every sentinel/status writer. |
| Fix | Check both stages; on failure drop the tmp, leave the target untouched, return 1. Success behaviour unchanged. |

## DEFERRED backlog (real, verified, NOT rushed — each needs design / carries regression risk)

| ID | Sev | Finding | Why deferred / recommended fix |
|----|-----|---------|--------------------------------|
| D-1 | HIGH | `FINAL_VERIFIER_MODEL`/`ENGINE`/`EFFORT` + `CONSENSUS_MODEL`/`FINAL_CONSENSUS_MODEL` are declared, CLI-parsed, logged, but **never used in dispatch** — every verify (per-US AND final) runs at `$VERIFIER_MODEL`. The "final = stricter" contract (user's verification philosophy) is unmet by the model knob (consensus still works). | Wire `FINAL_*` into the ALL/final-verify dispatch (single-verify when `signal_us_id==ALL`, `run_sequential_final_verify`, consensus final round). Touches dispatch → needs careful per-path change + a real-LLM final-verify test. Default likely == per-US so real-world impact is low until set; correctness gap is real. |
| D-2 | HIGH | A4/codex-exit synth (`_bug8_check_synth_allowed`) never validates done-claim `.iteration`/`.us_id` freshness; a stale/wrong-US done-claim → leader synthesizes a signal with the wrong us_id → wrong US credited to the durable ledger. The operator-recovery validator already has these checks (lib `_validate_operator_recovery_artifacts`). | Port the iteration-match + mtime-newer-than-worker-prompt checks into the autonomous synth gate. Needs care: workers don't always write `.iteration` reliably → risk of false-reject; requires a stub-LLM test of the A4 path. |
| D-3 | MED-HIGH | Leader-side verdict validation: `verdict=pass` is accepted with no check of `.verified_acs` (empty-array passes) and the verdict's own `.us_id` is never cross-checked against the signal us_id (a wrong-US-graded verifier credits the wrong US). | Add a soft guard: on a present-and-mismatched verdict `.us_id`, treat as fail + log. Making empty `verified_acs` a hard fail is risky (a correct verifier that doesn't populate the array would false-fail — observed: the LOW SV campaign passed with `verified_acs:0`). Needs the verifier prompt to GUARANTEE the field first, then a leader hard-gate. |
| D-4 | MED | `run_sequential_final_verify` has no 3-strike retry (F-10 asymmetry); a single transient poll failure at the most expensive end-of-campaign moment charges a false fail / can route an rc==2 (sentinel already written) into the fix loop. | Wrap its poll in the same `replace_worker_pane`+re-dispatch 3-strike used at the main verifier site; distinguish rc==2 as terminal. |
| D-5 | MED | State not restored on relaunch: model-upgrade state (`WORKER_MODEL`/`_MODEL_UPGRADED`/`_SAME_US_FAIL_COUNT`) resets to default; `CONSECUTIVE_BLOCKS`/`LAST_BLOCK_REASON` are in-memory only (so the now-live F-22 block CB resets across relaunch, and operator-recovery reads `.consecutive_blocks` as always-0). | Persist these in `update_status` JSON + restore in the F-13 block. Mechanical but touches the status schema; test for upgrade-survives-relaunch + block-CB-survives-relaunch. |
| D-6 | MED | `check_no_progress` (run:1705) gives byte-stasis grace only to codex idle UI; a claude worker whose pane is byte-static for 600s while genuinely working (tool output not streamed to the TUI) would BLOCK. | LOW empirical likelihood (claude TUI animates a timer/spinner → pane changes → resets). Changing it risks MASKING a real freeze. Being observed via the live dogfood rather than speculatively changed. If dogfood shows a false no-progress block on a healthy worker, add an `_ACTIVE_TASK_RE` grace mirroring the codex idle grace. |
| D-7 | MED | Heartbeat safety net (`check_heartbeat`/stale-CB) is inert in the primary TUI launch path (the trigger `.sh` that writes the heartbeat isn't executed; liveness rests on dead-pane + no-progress + prompt-stall). | Either emit a leader-side heartbeat from the poll loop, or remove the dead heartbeat code + document. Lower priority (the active detectors cover liveness). |
| D-8 | MED | Consensus path: verdict-file lock discarded between rounds + codex null-verdict has no retry (claude does); `paste_to_pane` uses a tmux-server-global buffer name (cross-leader ABA when two leaders share one server); `cleanup` not re-entrancy-guarded (EXIT+INT/TERM double-fire). | Consensus is opt-in/off-by-default; paste-ABA + cleanup-double-fire are rare. Each is a contained fix; batch in a consensus/cleanup hardening pass. |

Decision: F-22..F-26 are the high-value, low-regression, "leader stops terminating where it should recover" core + a safety-write fix — shipped with tests. D-1..D-8 are real and verified; deferred to avoid rushing dispatch rewiring / verification-rigor changes that could weaken or over-strict verification without a dedicated real-LLM gate.

## Codex re-review of F-22..F-26 (resolution)

A codex review of the F-22..F-26 diff returned 4 issues; each verified against the
code and resolved:
- **F-22a (codex HIGH) — DISMISSED.** codex noted `_classify_cross_us_or_metric`
  never returns `infra_failure`, so `_block_with_grace`'s infra-immediate-terminate
  branch is unreachable for the two block callers. Not a bug: a Worker/Verifier
  self-reported `blocked` is by nature a SEMANTIC block (infra failures are handled
  upstream in `poll_for_signal`, which writes its own infra_failure sentinels), so
  grace is the correct behavior for these callers; the infra branch is harmless
  defensive code (correct if any future caller passes infra). Kept.
- **F-22b (codex HIGH) — FIXED.** `CONSECUTIVE_BLOCKS`/`LAST_BLOCK_REASON` were not
  reset on a pass/partial-progress, so the now-live block CB counted blocks with an
  intervening success as "consecutive." Now reset in the `pass` + partial-progress
  branches. (`test-f22` case 5b + structural.)
- **F-24 (codex HIGH) — REVERTED → D-9.** The partial fix only reduces the race;
  reverted to avoid a false-confidence half-fix. Proper fix (acquire_slug_lock
  delegation) tracked as D-9.
- **F-26 (codex MEDIUM) — FIXED.** `write_complete_sentinel` + `write_blocked_sentinel`
  now check `${pipestatus[-1]}` and `log_error` + `return 1` on a failed
  `atomic_write` instead of logging false success.
- **F-25 (codex) — CONFIRMED CORRECT.**

| ID | Sev | Finding | Recommended fix |
|----|-----|---------|-----------------|
| D-9 | HIGH | Runner-lock (per-ROOT) stale-recovery ABA race (was F-24, reverted). | Delegate the runner lock to `acquire_slug_lock` (file-based, F-20-hardened) + write JSON metadata to a `${RUNNER_LOCKFILE_PATH}.meta` sidecar; update `cleanup` to remove the file+sidecar instead of the dir. Reuses the proven race-safe primitive; needs a duplicate-runner contract test. |

Net shipped this round: **F-22 (+F-22b), F-23, F-25, F-26** — all verified, deterministic tests green (`test-f22-block-grace-cb.zsh` 14/14, full fault-injection + lock + sv-gate:fast 71/71 + npm test:node 387/387). F-24→D-9 deferred.

## D-backlog batch shipped (D-3/D-4/D-5/D-8) — codex re-review R2: 0 issues

Continuing "improve until 0". The inline-verifiable D-items are fixed + codex-clean:
- **D-3 FIXED** — verdict `pass` branch cross-checks the verdict's own us_id vs the
  scoped US; a wrong-US "pass" is a CB-bounded soft-fail (not credited). The CB is
  snapshotted before the pass-success reset so consecutive mismatches accumulate.
- **D-4 FIXED** — `run_sequential_final_verify` distinguishes rc==2 (terminal) from
  rc==1 (one replace+re-dispatch retry); F-10 parity for the final-verify path.
- **D-5 FIXED** — persist + ATOMICALLY restore consecutive_blocks/last_block_reason
  (+ model-upgrade state persisted) so the F-22 block CB survives a relaunch.
- **D-8 FIXED (cleanup part)** — cleanup() re-entrancy guard (CLEANUP_DONE) so the
  EXIT+INT/TERM trap double-fire runs the body once (no double lockfile-release ABA).
- Tests: `test-dbacklog.zsh` 11/11 + the two codex-found refinements (D-3 CB-accum,
  D-5 atomic restore) locked as structural guards.

Still open (each needs a DEDICATED test cycle — not inline-verifiable, so not rushed):
- **D-1** FINAL_VERIFIER_MODEL/ENGINE/EFFORT wiring (final-verify dispatch rewiring;
  the codex sub-vars also aren't auto-detected at the `_auto_detect_engine FINAL_*`
  call). HIGH value (user's "final 엄격" philosophy) but needs a real-LLM final-verify
  test proving the final uses FINAL_* not VERIFIER_*. Don't rewire the just-verified
  final-verify path blind.
- **D-2** A4/codex-exit synth done-claim iteration/us_id freshness. Needs a stub-LLM
  A4-path test (false-reject risk if workers don't write .iteration reliably).
- **D-9** runner-lock via acquire_slug_lock delegation. High blast radius (startup +
  cleanup for EVERY campaign); needs an isolated duplicate-runner contract test.
- **D-6** no-progress claude grace — empirically fine (the 12-US haiku dogfood never
  false-blocked); observe further before changing the freeze detector.
- **D-7** heartbeat dead in the TUI launch path; **D-8 rest** (paste-buffer ABA,
  consensus null-retry) — lower priority / off-by-default paths.

## D-2 shipped — A4 done-claim freshness gate (codex review: 0 issues)

**D-2 FIXED.** `_bug8_check_synth_allowed` Gate 1b refuses to synthesize a verify
signal from a done-claim older than THIS iteration's worker-prompt (a lingering
prior-run claim would credit a stale/wrong US). mtime-based (done-claim has no
reliable `.iteration` — workers omit it). codex caught a cross-platform stat bug
(GNU `stat -f %m` = mount-point) → corrected to GNU-first `stat -c %Y || stat -f
%m` + a `<->` numeric guard (non-numeric → 0 → safe no-op). test-dbacklog.zsh
16/16; F-6/F-8 (same gate) pass. Remaining: D-1 (design decision), D-9 (dedicated
contract-test refactor), D-6/D-7/D-8-rest.

## D-1 + D-9 shipped (codex: D-9 resolved 0, D-1 correct)

**D-1 FIXED (user-confirmed).** FINAL_VERIFIER_MODEL/ENGINE/EFFORT were dead (final
verify ran at per-US VERIFIER_* strength). Now the codex sub-vars are auto-detected
and the final/ALL verify dispatches FINAL_VERIFIER_* — in run_sequential_final_verify
(default per-us final path) + the single-engine ALL path (per-US verifies unchanged
via _v_* aliases). The "final 엄격" knob (default opus), distinct from the removed
per-iteration verifier auto-upgrade. (Consensus-final still uses VERIFIER_* → D-1b,
opt-in, deferred.)

**D-9 FIXED via delegation.** The dir-based runner lock (mkdir dir + separate pid
file) had a fundamental acquire/pid-write gap that a recovery mutex couldn't close
(two codex rounds proved an inline-mutex insufficient). Replaced with delegation to
acquire_slug_lock — the F-20-proven primitive where the PID *is* the lock (set -C
atomic create), so no gap. Metadata → .meta sidecar; cleanup gates on exact pid
match and removes lockfile + .meta + .recovery.d. The runner lock now reuses the
9/9-tested acquire_slug_lock; test-dbacklog adds a real exclusivity test.

Backlog now: D-1b (consensus-final FINAL_VERIFIER, opt-in), D-6 (no-progress claude
grace — empirically fine in dogfood), D-7 (heartbeat dead in TUI path), D-8-rest
(paste-buffer ABA, consensus null-retry — off-by-default). The HIGH/MED "never
completes" + correctness + durability items are all shipped.

## D-10 + D-11 shipped (fresh convergence audit; codex: D-10 resolved 0, D-11 correct)

A fresh adversarial convergence audit of the post-hardening leader surfaced a NEW
HIGH the incremental reviews had missed:
- **D-10 FIXED (HIGH).** poll_for_signal's dead-pane check passed `$WORKER_ENGINE`
  for BOTH worker and verifier polls. In a mixed-engine campaign (claude worker +
  codex verifier — the user's config) a healthy codex verifier pane showing `bash`
  (codex's trigger shell) was judged DEAD by the claude rule → false dead-pane →
  3-strike → spurious BLOCK (intermittent). Fix: derive the engine from the poll
  role (*codex*→codex, *claude*→claude, *inal*→FINAL_VERIFIER_ENGINE, *erifier*→
  VERIFIER_ENGINE, else WORKER_ENGINE). The single-engine ALL verify polls with
  role "Verifier-final" so the derivation matches the FINAL_VERIFIER_ENGINE it
  launches (codex R2 closed a residual on that branch).
- **D-11 FIXED (MED, observability).** CURRENT_US was never assigned → lifecycle
  sentinels (no-progress/stall/R12) tagged BLOCKED sidecars with us_id=ALL. Now
  published at worker dispatch (next_us) + verify (signal_us_id).
- test-dbacklog.zsh 33/33; codex re-review D-10 RESOLVED 0 / D-11 CORRECT.
- The convergence audit found NO new CRITICAL. Remaining LOW/edge: D-1b
  (consensus-final FINAL_VERIFIER, opt-in), D-6 (no-progress claude grace —
  empirically fine), D-7 (heartbeat dead in TUI path), D-8-rest (paste-buffer ABA,
  consensus null-retry), + a harmless redundant EXIT trap.

## D-12 + CONVERGENCE (2nd fresh audit: NO NEW HIGH/CRITICAL)

A 2nd independent adversarial convergence audit (different angle: verdict/US
accounting, model-upgrade chain, jq/JSON gate decisions, consensus correctness)
found **NO new HIGH or CRITICAL** — the leader hardening has CONVERGED at the
HIGH/CRITICAL bar. One cheap correctness item shipped:
- **D-12 FIXED.** The verify `pass` branch appended signal_us_id to VERIFIED_US
  unconditionally; a fresh-context Worker re-submitting an already-verified US
  (memory drift) produced "US-001,US-001" (coverage-count inflation + ledger
  double-write — cosmetic, the next-US picker already skipped dups). Added the
  dedup guard the fail/partial path already had. test-dbacklog 36/36.

Accepted LOW / by-design (NOT fixed, with rationale):
- **MED-2 / model-upgrade on a D-3 us_id mismatch**: a verifier grading the wrong
  US doesn't escalate the WORKER model — by design: the mismatch is a VERIFIER-side
  problem (a stronger worker wouldn't help), and it is already CB-bounded.
- **LOW-1 (D-5b) model-upgrade state restore**: persisted in status.json but not
  restored on relaunch (only consecutive_failures/blocks are). Ambiguity: a user
  may change --worker-model on relaunch, so blindly restoring the upgraded model
  could override their choice. Deferred (needs a design decision).
- **LOW-2 consensus merged verdict has no us_id** → the D-3 cross-check is skipped
  for consensus (absent us_id = trust scope, per D-3's own contract). Low risk (both
  consensus verifiers see the same scoped prompt). Consensus is opt-in.
- D-1b (consensus-final FINAL_VERIFIER), D-6 (no-progress claude grace — empirically
  fine), D-7 (heartbeat dead in TUI path), D-8-rest (paste-buffer ABA, consensus
  null-retry), redundant EXIT trap — all LOW/edge/off-by-default.

CONVERGENCE: F-1..F-26 + D-1..D-12 shipped + codex-clean + tested + dogfood-proven
(haiku 12-US COMPLETE). Two independent fresh adversarial audits find 0 remaining
HIGH/CRITICAL. The "never completes" failure class is resolved at the leader level.

## D-5b/D-13/D-14/D-15 shipped — LOW backlog cleanup

Clearing the actionable LOW backlog (codex-reviewed; the 2 codex findings on the
batch — D-13 redundant delete-buffer, D-15 us_id not JSON-escaped — fixed in place):
- **D-5b FIXED (user-chosen restore-priority).** Relaunch restores the
  auto-upgraded Worker model (+ engine triple + _ORIGINAL_WORKER_MODEL +
  _SAME_US_FAIL_COUNT) when status.json model_upgraded==1 — GATED so a fresh
  campaign that never upgraded keeps its CLI/env model (no surprise override).
- **D-13 FIXED.** paste_to_pane uses a per-leader+pane buffer name (was global
  "rlp-paste") → no cross-leader ABA on a shared tmux server. (delete-buffer
  redundant with paste -d → removed.)
- **D-14 FIXED.** consensus codex null-verdict retry (symmetry with claude).
- **D-15 FIXED.** consensus merged verdict carries us_id (caller-passed), sanitized
  to ALL|US-NNN (JSON-safe), so the D-3 cross-check applies to consensus too.
- test-dbacklog.zsh 45/45.

### D-1c — FIXED (was deferred; user chose "wire" over "remove")  · LOW (opt-in path)
| | |
|---|---|
| Symptom | `CONSENSUS_MODEL`/`FINAL_CONSENSUS_MODEL` were declared, CLI-parsed, logged, and DOCUMENTED (governance table + command docs) as the consensus codex (cross) verifier models — but `run_consensus_verification` always used `VERIFIER_CODEX_MODEL`/`VERIFIER_CODEX_REASONING` for every round, leaving the knobs dead. The consensus claude side also always used `VERIFIER_MODEL` even for final-ALL (final ≠ stricter). Same documented-but-unwired class as D-1, on the opt-in consensus path. Mis-framed as "vestigial/remove" initially; on inspection it is a documented interface → wired (not removed), confirmed by the user. |
| Fix | `run_consensus_verification` selects model+effort pairs by scope — final(ALL): claude=`FINAL_VERIFIER_MODEL`, codex=`FINAL_CONSENSUS_MODEL`, effort=`FINAL_VERIFIER_EFFORT`; per-US: claude=`VERIFIER_MODEL`, codex=`CONSENSUS_MODEL`, effort=`VERIFIER_EFFORT`. `run_single_verifier` codex branch parses the passed `model:reasoning` arg with validation (non-empty model, single colon, reasoning ∈ minimal\|low\|medium\|high\|xhigh; else WARN + fall back to globals); gained an optional 6th `effort` arg via `${6-$VERIFIER_EFFORT}` (single-dash so an explicit empty is preserved). Strengthens final consensus claude sonnet→opus, consistent with D-1. |
| Verification | test-dbacklog.zsh 53/53 (+8 D-1c incl. the two codex-fix rounds: MED final-claude-effort, LOW malformed-spec/`${6-}`/xhigh). 3 codex rounds (round 1: 2 issues → fixed; round 2: 2 new → fixed; fresh round: **0 issues**). sv-gate:fast 71/71, node 387/387, F-22 14/14, lock 9/9. Commit 3e673df (main + branch). |

FINAL accepted/deferred (LOW, with rationale — NOT silently skipped):
- **D-7** heartbeat block inert in the TUI launch path (trigger .sh not executed) —
  liveness is covered by dead-pane + no-progress + prompt-stall; removing the
  intertwined poll-path block risks more than the harmless skip. Documented.
- redundant EXIT trap (CLEANUP_DONE-guarded) — harmless.

### D-16 — last per-US pass finalizes directly (no fragile worker round-trip)  · MED (resilience)
| | |
|---|---|
| Symptom | Empirically derived from the v0.18.0 release SV trio (CRITICAL attempt 1). In per-us mode, after the LAST US passes its per-US verify, the leader credited VERIFIED_US and looped to dispatch ANOTHER worker iteration whose only job was to emit a `us_id="ALL"` signal — the trigger for `run_sequential_final_verify`. That worker round-trip is a fragile extra LLM iteration: in SV CRITICAL att.1 the opus worker hit an Anthropic API rate-limit at exactly that step, froze, and the frozen-pane guard BLOCKED a campaign whose work (12 tests green, all ACs) was already done. The transition to final-verify depended on either the verifier emitting `recommended=complete` OR the worker emitting an ALL signal — both fragile. |
| Fix | When the last per-US pass completes coverage (`_all_us_verified`: every US in `US_LIST` is in `VERIFIED_US`), arm a new global `_FINALIZE_PENDING` (needed because `SKIP_NEXT_WORKER` is loop-`local`). The next loop top synthesizes the ALL verify signal itself (`atomic_write` to `SIGNAL_FILE`) + sets `SKIP_NEXT_WORKER=1`, reusing the proven PR-A operator-recovery skip path. Downstream (`signal_us_id=ALL` → `run_sequential_final_verify` → complete OR fix-loop) is UNCHANGED — only HOW the ALL signal is produced changes. Operator-recovery takes precedence (`&& SKIP_NEXT_WORKER==0`); a crash mid-finalize loses the in-memory flag and safely falls back to the worker round-trip. |
| Verification | test-dbacklog 59/59 (+6 D-16: flag/helper/arm/synth/downstream-unchanged/coverage-logic). codex review 0 issues (4 invariants cleared: global scope, locked-0o444-signal overwrite [mv/rename succeeds — empirically confirmed], no done-claim gate on the verify route, fix-loop fall-through identical). sv-gate:fast 71/71, node 387/387, F-22 14/14, lock 9/9. **Real-LLM SV E2E (single-US):** leader logged "arming leader finalize" → "synthesizing ALL verify signal, skipping worker round-trip" → "Sequential final verify: ALL PASSED" → COMPLETE, arm→final-verify in 2s (no worker round-trip). Commit 71c378f (main; post-0.18.0, UNRELEASED). |

FINAL STATE: F-1..F-26 + D-1..D-16 + D-1c. v0.18.0 SHIPPED (F-1..F-26 + D-1..D-15
+ D-1c). D-16 committed post-release (main 71c378f), UNRELEASED — candidate for the
next patch/minor. codex-clean, deterministically tested (test-dbacklog 59/59 + full
fault-injection + lock 9/9 + sv-gate 71/71 + node 387/387), dogfood-proven (haiku
12-US COMPLETE) + fresh release SV trio (LOW/MED/CRIT COMPLETE, BROKEN BLOCKED).
The "never completes" failure class is resolved; remaining items are LOW/by-design
(D-7 + redundant trap; D-17 rate-limit-grace = speculative, deferred).
