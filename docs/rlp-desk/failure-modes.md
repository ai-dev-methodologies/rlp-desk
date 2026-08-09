# rlp-desk Failure Modes Atlas

> Origin: 2026-05-08 (audit B-NEW-1, derived from omc-team's "Gotchas" pattern). Single canonical reference for known failure modes across the rlp-desk substrate. Each entry is FMEA-style: cause → symptom → detection → recovery.

This atlas consolidates Bug #5/6/7/8/10 + lifecycle race + sentinel contention failure patterns. New failure modes are added here once verified, with a back-link to the originating bug report or audit doc.

---

## §1 — Subprocess lifecycle (tmux + Worker/Verifier panes)

### F1.1 — Worker pane idle false-positive (Bug #6)
| Field | Value |
|---|---|
| Symptom | Leader marks worker as "no progress" while iter-signal.json was already written |
| Root cause | Worker TUI returns to idle prompt after writing sentinel; capture-pane shows stasis byte-equality without observing the FS write |
| Detection | `tests/test-bug6-worker-idle-false-positive.sh`; `_worker_pane_has_signal` short-circuit in `check_no_progress` |
| Recovery | Existing fix-M short-circuits BLOCKED escalation when iter-signal.json is present. No operator action required |
| Reference | `src/scripts/run_ralph_desk.zsh` `_worker_pane_has_signal` helper |

### F1.2 — Post-sentinel pane race (Bug #7)
| Field | Value |
|---|---|
| Symptom | Verify-verdict.json mtime drifts 30-120s after leader observes it; iter-N+1 worker dispatched while iter-N verifier's pane is still alive |
| Root cause | Without explicit teardown, claude/codex TUI continues self-reviewing after sentinel write |
| Detection | `tests/sv-real-llm/scenarios/bug-07-post-sentinel-race.test.sh` (real-LLM), `tests/node/test-sentinel-reaper-invariant.test.mjs` (unit) |
| Recovery | `_kill_pane_process` (Bug #7 Fix-Q) at zsh `lib_ralph_desk.zsh:257-272` and Node `pane-manager.mjs:91-116`. `_lock_sentinel` (Fix-R) freezes the file mtime |
| Reference | Bug #7 PR-A; v0.15.4 PR-B2-FIX extends to done-claim sentinel |

### F1.3 — done-claim race (v0.15.4 PR-B2-FIX target)
| Field | Value |
|---|---|
| Symptom | Worker writes done-claim.json then idles 30-120s before iter-signal.json. Worker may revise done-claim mid-flight; A4 fallback synthesizes signal from a stale done-claim |
| Root cause | Original Bug #7 Fix-Q only reaped at iter-signal observation. Done-claim was unguarded |
| Detection | `tests/node/test-sentinel-reaper-invariant.test.mjs` case 5 (done-claim ALIVE pane → kill) |
| Recovery | `_kill_pane_process` + `_lock_sentinel "$DONE_CLAIM_FILE"` at 4 substrate sites (3 zsh + 1 Node). See `docs/plans/v0.15-phase-b-plan-v3.md` §B2-FIX |
| Reference | v0.15.4 commit `2b5af6c`; audit `docs/plans/v0.15.4-pre-release-audit.md` §1 C2 |

### F1.4 — Worker dead on reuse (Bug #5)
| Field | Value |
|---|---|
| Symptom | At iter-N+1 entry, leader dispatches into a previously-killed worker pane; tmux returns "can't find pane" |
| Root cause | `_r12_check_lifecycle` not enforced strictly enough between iters |
| Detection | `tests/sv-real-llm/scenarios/bug-05-worker-dead-on-reuse.test.sh`; `[r12]` log markers |
| Recovery | R12 lifecycle monitor at iter-entry: detect dead pane within 5s budget → either replace pane OR write BLOCKED with infra_failure (no silent advance) |
| Reference | Bug #5 BOS 2026-05-05 |

### F1.5 — Worker incomplete with leader fallback (Bug #8)
| Field | Value |
|---|---|
| Symptom | Codex worker exits without writing iter-signal.json; leader synthesizes one from done-claim, but tree may be dirty |
| Root cause | Pre-Bug-#8: leader synthesized verify signal whenever done-claim existed, regardless of git state. Caused false PASSes when worker bailed mid-write |
| Detection | `_bug8_check_synth_allowed` 3-gate (done-claim present + git OK + tree clean); 4 BLOCK_TAGS variants |
| Recovery | Refuse synthesis on Gate 1/2/3 fail; write BLOCKED sentinel with appropriate failure_category (infra_failure / metric_failure) |
| Reference | Bug #8 PR-B; src/scripts/run_ralph_desk.zsh L644-695 |

### F1.6 — Operator-recovery artifact mismatch (Bug #10)
| Field | Value |
|---|---|
| Symptom | Operator manually clears BLOCKED sentinel + writes iter-signal/done-claim, but artifacts mismatch status.json or have stale mtime |
| Root cause | No validation pass when leader resumes from operator-cleared BLOCKED state |
| Detection | `_validate_operator_recovery_artifacts` 5-gate (file exists, parses, us_id matches, iteration matches, mtime > prompt mtime); `tests/node/test-blocked-recovery-hygiene.test.mjs` |
| Recovery | Pre-resume validator returns 0 only when all 5 gates pass; sets `RECOVERY_FAIL_REASON` for caller logging on failure |
| Reference | PR-A Bug #10; lib_ralph_desk.zsh L298-380 |

### F1.7 — done-claim commit false-claim (US-001)
| Field | Value |
|---|---|
| Symptom | done-claim asserts `commit exit_code 0`; `git log` shows no such commit; deliverables stay untracked/modified |
| Root cause | Bug #8 git gate runs only on the codex-exit fallback path; the normal verify path dispatches the verifier without checking the commit assertion against git |
| Detection | `tests/node/test-done-claim-commit-oracle.test.mjs` + `tests/test_commit_oracle.sh` (shared parity matrix); leader "COMMIT-INTEGRITY FAILURE" fix-contract line |
| Recovery | Leader-side oracle verifies HEAD advance since the per-iteration-start snapshot + tree consistency, on the shared post-done-claim-lock path (covers synth); on mismatch → fix loop with machine-generated fix-contract; circuit breaker escalates on repeat |
| Reference | v0.22.7 US-001; `_commit_oracle_check` (lib_ralph_desk.zsh) + `evaluateCommitOracle` (src/node/shared/commit-oracle.mjs); post-mortem `pa-live-audit-unblock` |

### F1.8 — non-exhaustion usage banner blocks TUI submission (request-g)
| Field | Value |
|---|---|
| Symptom | Trigger prompt is echoed into the codex pane's input box but sits unsubmitted; a non-exhaustion usage banner is visible on the pane ("• You have 1 usage limit reset available. Run /usage…", "increased plan usage", weekly-limit); a single Enter resolves it in 6-9s. Field-reproduced twice on the verifier leg (v0.22.15 pa-foundation resume) |
| Root cause | The banner steals the submit keystroke, so the dispatched Enter never submits the prompt. It is NOT quota exhaustion, so the strict `detect_quota_exhausted` correctly does not fast-fail it — but without an early nudge the prompt idles until the 90s submit window re-injects, adding up to 90s of latency per dispatch |
| Detection | `_pane_submit_blocked_by_banner` (lib_ralph_desk.zsh): trigger echoed + no `_pane_shows_progress` + matches `RLP_SUBMIT_BANNER_RE` (env-overridable) |
| Recovery | One early one-shot Enter re-inject at the first poll tick (~POLL_INTERVAL post-dispatch) on both leaders — codex-verifier poll loop (per-dispatch guard, reset on full re-dispatch) and generic `poll_for_signal` (per-poll-session guard). After the single shot the existing submit-anchored 90s path takes over unchanged; progress detection skips the nudge so normal immediate-submit cases get zero re-injects |
| Reference | request-g (`docs/incoming-requests/tire-plletdata-request-2026-07-21-g.md`), v0.22.16; `tests/test_banner_early_reinject.sh` |

### F1.9 — format-only done-claim defect burns an LLM cross-verify round (request-h)
| Field | Value |
|---|---|
| Symptom | A build-mode done-claim whose deliverables are all green on fresh verification still FAILs the LLM cross-verifier's Worker Process Audit purely on a per-AC TDD step-label/order defect (e.g. an `implement` step labeled `ac_id:"all"` instead of `AC3`). Field case US-002 pa-foundation: 2 codex rounds ≈ 65min (iter-002 627s+964s, iter-004 1059s+1269s) with every AC green — a defect a JSON field-order check resolves in milliseconds |
| Root cause | The pre-gate (Layer 1 static script, Layer 2 command replay) did not inspect the per-AC `write_test → verify_red → implement → verify_green` label/order of `execution_steps`, so a 100%-deterministic format fault flowed all the way to the 20-25min LLM cross-verification round before being caught |
| Detection | `run_pregate_doneclaim_lint` (zsh) / `lintDoneClaimTddSequence` (Node); `tests/test_doneclaim_lint.sh` + `tests/node/test-done-claim-lint.test.mjs` drive shared fixtures under `tests/fixtures/done-claim-lint/` |
| Recovery | Layer 1.5 done-claim TDD-sequence lint (governance §3a) runs before verifier dispatch on BOTH leaders; on fail it bounces the Worker with a `PRE-GATE FAILURE (done-claim format lint)` fix contract carrying per-AC `idx` coordinates (`-1` = phase missing, non-monotonic = out of order). Shared `PREGATE_FAIL_CAP`, never the circuit breaker; the canonical predicate is single-sourced with the worker-prompt format spec and the verifier's Worker Process Audit so a lint-PASS is not re-failed on format grounds. Opt out via `RLP_DONECLAIM_LINT=0` |
| Reference | request-h (`docs/incoming-requests/tire-plletdata-request-2026-07-21-h.md`), v0.22.17; governance §3a Layer 1.5 |

### F1.10 — model-capacity mid-execution stall (request-j ①)
| Field | Value |
|---|---|
| Symptom | A codex worker/verifier pane prints "⚠ Selected model is at capacity. Please try a different model." AFTER the prompt was submitted, then freezes with no progress spinner. The leader keeps polling to ITER_TIMEOUT (1800s) — the operator manually typed "계속 해." to resume instantly. Leader log accreted 349 repeated captures of the same stall = the poller SAW but did not INTERPRET it. Field case US-005 terra:high, pa-foundation 33차 |
| Root cause | Distinct from request-g's PRE-submission banner (F1.8) and from `detect_api_error`'s transient outage phrases: capacity is a POST-submission stall that no poll predicate matched, so the pane idled indefinitely with no auto-response |
| Detection | `_pane_capacity_stalled` (lib_ralph_desk.zsh): a capacity banner matches `RLP_CAPACITY_BANNER_RE` (env-overridable) AND `_pane_shows_progress` is false, on the single reused pane capture in `poll_for_signal` |
| Recovery | Inject `RLP_CAPACITY_RESUME_TEXT` (default "Continue.") via paste + Enter, bounded by `RLP_CAPACITY_REINJECT_COOLDOWN_S` (default 120s) between injections; each injection is a strike, and at `RLP_CAPACITY_MAX_STRIKES` (default 3) the leader writes `[infra_failure]` BLOCKED mentioning model capacity rather than stalling silently. `detect_quota_exhausted` WINS (a usage wall is terminal, never resume-injected). Strikes reset when progress resumes. Zero injection while a spinner/progress is present |
| Reference | request-j ① (`docs/incoming-requests/tire-plletdata-request-2026-07-21-j.md`), v0.22.18; `tests/test_capacity_banner_stall.sh` |

### F1.11 — campaign pane created outside the campaign session (request-j ②)
| Field | Value |
|---|---|
| Symptom | Leader started detached (outside tmux); a worker/verifier `split-window` landed in the unrelated ACTIVE session (another project's review-inbox). Operator hand-moved the pane (join-pane), breaking the leader's pane ledger → `[infra_failure] tmux session/pane dead during iter_start` killed the campaign (32차) |
| Root cause | `replace_worker_pane`'s LEADER_PANE fallback split with no empty/alive guard; an empty `-t` makes tmux silently fall back to the currently-active session (the contamination vector) |
| Detection | `_verify_split_target` (non-empty + live pane before splitting) and `_assert_pane_in_session` (created pane's `#{session_name}` == `$SESSION_NAME` after splitting) |
| Recovery | Every `split-window` (create_session both branches, replace_worker_pane fallbacks, consensus pane) verifies its target first — an empty/dead target is an explicit error (hard exit at startup / BLOCKED sentinel in-loop) instead of an ambient-session split. Any pane that escapes the campaign session is KILLED and reported |
| Reference | request-j ② (`docs/incoming-requests/tire-plletdata-request-2026-07-21-j.md`), v0.22.18; `tests/test_pane_session_pinning.sh` |
| **Companion (v0.22.19) — LEADER_PANE followed the active client** | **Symptom**: leader started in dedicated pane %2175 but adopted %2177 (the operator's ACTIVE pane, same session); with 6+ attached clients, splits once scattered to two unrelated sessions (%2277 j-pa-develop, %2278 pa). **Root cause**: `create_session` inside-tmux took BOTH `LEADER_PANE` and `SESSION_NAME` from `tmux display-message -p` which reports the attached CLIENT'S ACTIVE pane, not the invoking shell's tty pane. Because both came from the active client they were self-consistent-but-wrong, so the ② session-invariant (pane session == SESSION_NAME) did NOT flag the scatter. **Detection/Recovery**: `_leader_own_pane` prefers `$TMUX_PANE` (the invoking process's own pane, immune to active-pane/multi-client drift; `display-message` fallback only when unset), and `SESSION_NAME` is derived FROM `$LEADER_PANE` (`display-message -p -t "$LEADER_PANE"`), not the active client. Same fix applied to `check_existing_sessions`. **Reference**: `docs/incoming-requests/tire-plletdata-request-2026-07-21-k-regression.md` ②, v0.22.19 |

### F1.12 — restart path assembles empty model_reasoning_effort (request-j ③)
| Field | Value |
|---|---|
| Symptom | In-campaign worker re-dispatch built `codex -m gpt-5.6-terra -c model_reasoning_effort="" …` → codex aborts "reasoning_effort must not be empty" → trigger text leaks to the shell → "worker not active" ×3 → BLOCKED. First launch parsed fine; only the RE-launch path lost the effort. Field case 31차 iter-006, US-003 dispatch |
| Root cause | `check_model_upgrade` saved `_ORIGINAL_WORKER_CODEX_REASONING` in-memory only; `update_status` persisted `original_worker_model` but NOT the reasoning; the leader-relaunch restore rehydrated every upgrade field except the reasoning; restore-on-pass then assigned the empty string into `WORKER_CODEX_REASONING`, which the next dispatch interpolated as an empty flag |
| Detection | `_require_codex_effort` assembly guard fires when the effort is empty at ANY of the 8 codex `-c model_reasoning_effort=` sites |
| Recovery | Persist `original_worker_codex_reasoning` in `update_status`; restore it in the D-5b relaunch block; restore-on-pass keeps the current effort (never assigns empty) when the persisted original is missing; the assembly guard fail-fasts (BLOCKED `infra_failure`) rather than shipping an empty flag |
| Reference | request-j ③ (`docs/incoming-requests/tire-plletdata-request-2026-07-21-j.md`), v0.22.18; `tests/test_effort_persistence_restore.sh` |

### F1.13 — rc prompt swallows the launch command's first char (request-j ④)
| Field | Value |
|---|---|
| Symptom | An oh-my-zsh update prompt (`[Y/n]`) on the pane consumes the FIRST pasted char, turning "/opt/homebrew/bin/codex…" into "opt/homebrew/bin/codex…" (leading `/` gone) → CLI never starts. Field case 29차 |
| Root cause | The launch functions pasted then pressed Enter unconditionally; `safe_send_keys`'s substring check is not enough (a swallowed first char still substring-matches mid-command fragments) |
| Detection | `_paste_cmd_echo_verified` (run_ralph_desk.zsh): after paste, require the command's leading ~24-char prefix (which includes the vulnerable first char) to appear intact via a glob-safe `grep -F`, before Enter |
| Recovery | On mismatch: C-u (clear line), re-paste, up to 3 attempts; all exhausted → explicit launch failure (existing path). Wired into both `launch_worker_codex` and `launch_worker_claude` |
| Reference | request-j ④ (`docs/incoming-requests/tire-plletdata-request-2026-07-21-j.md`), v0.22.18; `tests/test_launch_echo_verify.sh` |
| **Regression (v0.22.18→fixed v0.22.19)** | **Symptom**: the v0.22.18 echo-verify captured with `capture-pane -p \| tail -10`. On a FRESHLY split pane the prompt renders at the TOP of the viewport with ~30 trailing BLANK rows, so `tail -10` saw only blanks → `$()` stripped them → `_tail=""` → the prefix grep never matched → 3 spurious re-pastes → false launch failure. 100% reproducible on cold panes (field: 4 consecutive restart deaths, 34–37차). **Root cause**: pane-content assertions must be viewport-position-independent; `tail -N` over a raw capture assumes the content is at the BOTTOM (used-shell layout), which is false for a fresh pane. **Detection**: `test_launch_echo_verify.sh` "echo-at-top + trailing blank rows" fixture. **Recovery**: strip blank lines before tail — `capture-pane -p \| grep -v '^[[:space:]]*$' \| tail -10` — position-independent, keeps -10 for wrapped lines; plus a bounded shell-ready wait (`_wait_pane_shell_ready`, `RLP_SHELL_READY_TIMEOUT_S` default 6s, fail-open) before the first paste so a paste can't race rc loading. **Reference**: `docs/incoming-requests/tire-plletdata-request-2026-07-21-k-regression.md`, v0.22.19 |

### F1.14 — codex CLI update dialog defeats the Skip handler, masks as a submission failure (v0.22.21)
| Field | Value |
|---|---|
| Symptom | codex-cli 0.145.0 shipped a **TWO**-option startup dialog (`✨ Update available! 0.144.6 -> 0.145.0 / 1. Update now / 2. Skip`; 0.140/0.141 had THREE options). The F-1 Skip handler dismissed it 3× but it kept reappearing (the key sequence no longer selected Skip on the new menu), so the verifier codex never reached ready → no execution-start signal → 2 re-dispatches burned → died `[infra_failure] Codex verifier-codex never started (… submission failure)` BLOCKED. The reason was **misleading**: the real cause was an undismissable update dialog, not a submission fault. Field case 2026-07-22 04:44 (`/tmp/pa-foundation-leader-43.log`) |
| Root cause | Three compounding gaps. (1) No launch-time suppression of codex's startup update check, so every CLI release that ships an update banner re-exposes the surface (whack-a-mole). (2) The codex verifier dispatch in `run_single_verifier` did **not** check `launch_verifier_codex`'s return (the claude branch did), so a launch that never reached ready fell through to verdict polling instead of aborting. (3) The four update-dialog handlers were inconsistent — two (launch functions) used the correct `Update available\|1\. Update now` regex with Down+Enter; two (`safe_send_keys`, `wait_for_pane_ready`) used a dead `new version\|update.*codex` regex that never matched the real banner — and the abort reason surfaced only the generic "never started" text |
| Detection | `tests/test_codex_update_dialog_hardening.sh` (main suite): asserts all 8 launch sites carry `-c check_for_update_on_startup=false`, the RLP_CODEX_UPDATE_CHECK=1 opt-out omits it, the abort reason names the dialog + remedy, the verifier dispatch return is guarded, and the 4 sites all use the one shared dismisser / canonical regex. `tests/sv-large-campaign/test-f1-codex-update-dismiss.zsh`: classification against the real 0.145.0 TWO-option banner + the shared dismisser's key strategy (attempts 1-2 Down+Enter, 3+ literal "2"+Enter) |
| Recovery | **ROOT** — inject `-c check_for_update_on_startup=false` at every codex launch (`_CODEX_NO_UPDATE_FLAG`, computed once near the knobs) so the dialog never renders; escape hatch `RLP_CODEX_UPDATE_CHECK=1` restores codex's default check. This is the config-injection defense against the CLI-release-recurrence pattern — a Skip handler alone is whack-a-mole across releases. **MASK** — guard the codex verifier-dispatch return like its adjacent claude branch at **every propagating site** (run_single_verifier initial → return 1; `_final_verify_one_us` initial + D-4 retry → return 2; consensus-parallel initial → return 1; inline verifier-relaunch initial → update_status + continue), and thread a durable reason (`_CODEX_LAUNCH_FAIL_REASON`, cf. `_GEO_FAIL_REASON`) so a still-stuck dialog is named as the true cause + `codex update` remedy in the persisted BLOCKED reason. The 3 remaining `launch_verifier_codex` calls are submit-anchored re-dispatches inside poll loops (codex-only, or a claude sibling of `|| true`) and are legitimately best-effort. **CONSOLIDATION** — one `_dismiss_codex_update_prompt <pane> <attempt>` with one canonical `_RLP_CODEX_UPDATE_RE`, replacing all four inline handlers (the two dead-regex sites die with it) |
| Reference | `docs/incoming-requests/tire-plletdata-incident-2026-07-22-codex-update-dialog.md`, v0.22.21; `tests/test_codex_update_dialog_hardening.sh`, `tests/sv-large-campaign/test-f1-codex-update-dismiss.zsh` |

### F1.15 — reused-pane redispatch pastes before the previous process returns to the shell (request-m ①)
| Field | Value |
|---|---|
| Symptom | A worker redispatch onto a REUSED pane pastes the launch command while the previous run's process is still exiting → the paste is lost → `launch paste echo mismatch (attempt 1/3→3/3)` burns all 3 retries within ~1 second → `Worker codex failed to start in pane after replace+retry` BLOCKED. Field case 46차 iter-3 (15:07:59–15:08:00) |
| Root cause | `_wait_pane_shell_ready`'s readiness predicate was content-based ("any visible NON-blank text"). Valid for a FRESH pane, but a reused pane is full of the previous run's output, so the non-blank test passes INSTANTLY — while the prior codex/node process still owns the pane's foreground. Compounded by a 0.15s retry interval that let all 3 retries complete inside 1s (before the shell could reclaim the pane), making the retries meaningless |
| Detection | `tests/test_launch_echo_verify.sh` reused-pane case: `#{pane_current_command}` stubbed to return `node` for N ticks then `zsh` while capture-pane is always non-blank → the wait must HOLD until the shell reclaims the pane (no premature ready) |
| Recovery | Readiness becomes PROCESS-based AND content-based: `#{pane_current_command}` matches the accept-set (parameterized; default `zsh\|bash`, override `RLP_SHELL_READY_CMDS`) AND at least one non-blank line (keeps the fresh-pane rc-loading case). **Codex launches pass `zsh` ONLY** — a reused codex pane's RUNNING trigger process is `bash` (check_dead_pane: bash=alive for codex), which the default `zsh\|bash` would misread as ready; on a bash-login-shell host codex therefore fail-opens after the timeout (echo-verify still guards). Timeout raised `RLP_SHELL_READY_TIMEOUT_S` 6→8s at the canonical knob block (D-19-validated; the earlier inline-only raise was dead code because the knob pinned 6). Retry interval 0.15→0.8s so the shell can settle between paste attempts |
| Reference | `docs/incoming-requests/tire-plletdata-request-2026-07-22-m.md` ①, v0.22.23; `tests/test_launch_echo_verify.sh` |

### F1.16 — run/re-execution clobbers same-numbered evidence artifacts (request-m ②)
| Field | Value |
|---|---|
| Symptom | Past pass-verdict receipts are unrecoverable after a restart or fresh re-execution. Field case: after a PRD revision (341 cohort), US-001/002/003's claude pass verdicts needed re-binding to the new PRD hash via `ledger-seed`, but the `iter-*.verify-verdict-*.json` files had been overwritten by later runs → re-seed impossible → final verification fell back to costly build-mode fresh E2E |
| Root cause | Two destruction paths. (1) A bare leader restart resets `ITERATION` to 1 (no cross-run counter), so a new run's `iter-1,2,3…` silently overwrite the prior run's same-numbered files. (2) `init --mode fresh\|improve` `rm`'d all `iter-*`, the runtime memos, AND `verified.jsonl` outright. The `verified.jsonl` ledger is the progress record; each verdict is its receipt — the receipt was the only artifact that was purely volatile |
| Detection | `tests/test_run_artifact_archive.sh`: pre-seed `iter-*` then drive the leader-startup archive (originals gone from the live dir, present under `runs/`, content intact); `init --mode fresh` archives instead of deletes (incl. `verified.jsonl`); `archive_iter_artifacts` now includes iter-signal; an archived verdict passes `ledger-seed --evidence <archived path>` end-to-end |
| Recovery | Evidence is RELOCATED, never deleted, into `logs/<slug>/runs/superseded-<ts>/` (`<ts>` = superseding run's startup timestamp). Leader startup moves a prior run's `iter-*` before writing (`archive_superseded_run_artifacts`, `lib_ralph_desk.zsh`); `init --mode fresh\|improve` moves `iter-*` + runtime memos + `verified.jsonl` into the same scheme (live paths still emptied — a fresh campaign cannot inherit stale credit). `ledger-seed --evidence` accepts the archived paths (contract unchanged) |
| Reference | `docs/incoming-requests/tire-plletdata-request-2026-07-22-m.md` ②, v0.22.23; governance.md §6 "Run-scoped evidence archive"; `tests/test_run_artifact_archive.sh` |

### F1.17 — verification-type iteration fabricates an empty commit (G3)
| Field | Value |
|---|---|
| Symptom | A verification/confirmation iteration that changed no files still produces a commit, and the done-claim asserts it with `exit_code: 0` + a real `commit_sha`. Every commit-integrity check passes (HEAD advanced, sha resolves, sha reachable, tree clean) because the commit is genuine — it is simply **empty**, so the campaign's evidence trail records work that never happened. Field case: 2026-08-08 dogfood, commit `787b663` |
| Root cause | Prompt pressure, not a leader bug. The generated worker prompt carried an UNCONDITIONAL bullet — "Commit all changes when the iteration is complete" — written once per campaign into `<desk>/prompts/<slug>.worker.prompt.md`. Because a campaign mixes US types, the bullet could not be made conditional at generation time, so a verification-type US (IL-2¾ §2, whose deliverable is confirmation and which expects NO commit) read it as an unconditional obligation and satisfied it with `git commit --allow-empty`. The oracle's no-op condition covered "no commit asserted" but had no inverse for "commit asserted that records nothing" |
| Detection | `tests/fixtures/commit-oracle/matrix.json` rows `confirmation-claim-empty-commit-reject`, `confirmation-claim-real-commit-accept`, `confirmation-claim-empty-root-commit-accept`, `no-write-test-but-build-work-empty-commit-reject` — driven against BOTH leaders by `tests/test_commit_oracle.sh` (real temp git repos) and `tests/node/test-done-claim-commit-oracle.test.mjs` (pure predicate + real-git wrapper). The Node suite additionally pins that `_defaultCheckCommitIntegrity` actually gathers the fact, which is what keeps the predicate from shipping as dead code |
| Recovery | Two-sided. (1) Prompt: the commit bullet is now conditional and names the empty-commit prohibition explicitly (`init_ralph_desk.zsh`). (2) Leader: a new independent predicate — done-claim carries no `write_test` step AND the claimed commit's tree equals its parent's ⇒ reason `empty_commit_on_confirmation_claim`, identical string on both leaders (`shared/commit-oracle.mjs` + `lib_ralph_desk.zsh` `_commit_oracle_check`). The fix contract branches: DROP the empty commit (`git reset --soft HEAD^`) and claim no commit step — never "create the commit", which would instruct a second fabrication. Boundary: a root commit or shallow-clone tip has no parent to diff, so the fact is `unknown` → ACCEPT (`_commit_oracle_empty_tree` rc 3 / Node `'unknown'`); genuine git errors still take the GIT-FC infra path (rc 2 / `infra: true`) rather than being swallowed |
| Reference | `.omc/plans/dogfood-gaps-g1-g4.md` §G3; governance.md §1f½ (empty-tree bullet) + IL-2¾ §2; `src/node/shared/done-claim-kind.mjs` (`isBuildClaim`, shared with the Layer 1.5 lint) |

---

## §2 — Sentinel file contention

### F2.1 — Concurrent write-during-read window
| Field | Value |
|---|---|
| Symptom | Leader's `jq` parse on iter-signal.json fails with "unexpected EOF" when polled mid-write |
| Root cause | Worker writes sentinel non-atomically; leader's poll catches a partial state |
| Detection | "JSON not yet valid — continue polling" log entry; `tests/node/test-sentinel-exclusive.mjs` |
| Recovery | `writeSentinelExclusive` uses O_EXCL; `_lock_sentinel` chmod 0o444 prevents post-observe rewrite; jq -e parse retried on next poll tick |
| Reference | v5.7 §4.24 file-guarantee contract; sv-gate-fast §4.24 checks |

### F2.2 — Locked sentinel blocks next iter's writer
| Field | Value |
|---|---|
| Symptom | Iter-N+1 worker EACCES on iter-signal.json write because iter-N lock (chmod 0o444) was never released |
| Root cause | `_unlock_sentinel` not invoked at iter-start |
| Detection | "Permission denied" in worker stderr; `lib_ralph_desk.zsh` lifecycle test |
| Recovery | `unlockSentinelFile(paths.signalFile)` + `unlockSentinelFile(paths.verdictFile)` called defensively at every iter start (campaign-main-loop.mjs L1552-1555) |
| Reference | v5.7 §4.25; campaign-main-loop.mjs unlockSentinelFile call sites |

### F2.3 — Locked file orphans across upgrades
| Field | Value |
|---|---|
| Symptom | npm install of new rlp-desk version EACCES on previously-locked installed files |
| Root cause | Installed files chmod 0o444 from prior version; postinstall.js attempts straight overwrite |
| Detection | "EACCES: permission denied" during `npm install` |
| Recovery | `scripts/postinstall.js:163-167` walks installed dir, chmod 0o644 BEFORE copy; user-facing fallback documented in S1 runbook (`npm uninstall -g` first) |
| Reference | scripts/postinstall.js unlock-walk; v0.15.4 S1 rollback runbook |

### F2.4 — Parallel consensus fixture interference (Feature 2)
| Field | Value |
|---|---|
| Symptom | With `--consensus-parallel`, one verifier false-FAILs on a "no residue" / clean-state check because the other verifier's concurrent DB-mutating or E2E rerun left in-flight fixture rows visible during the window |
| Root cause | Both consensus verifiers re-run evidence at the same time; DB-mutating / E2E reruns are not isolated across the two processes |
| Detection | `tests/test_consensus_parallel.sh` (evidence-lock interference case — lock held during a mutation window blocks the second acquire) |
| Recovery | Both parallel verifier prompts carry an evidence-isolation contract (single source: `_emit_evidence_lock_contract`) instructing them to acquire `.rlp-desk/logs/<slug>/runtime/evidence.lock` (mkdir-atomic, wait up to 120s) before any DB-mutating/E2E rerun and release after. Static/unit/file checks stay parallel. Off by default → no exposure unless opted in |
| Reference | `_evidence_lock` / `_emit_evidence_lock_contract` in `lib_ralph_desk.zsh`; `run_consensus_verification_parallel` in `run_ralph_desk.zsh`; governance §3b |

---

## §3 — Telemetry & observability (v0.15.4+)

### F3.1 — lifecycle_metrics field absent (B4 telemetry regression)
| Field | Value |
|---|---|
| Symptom | `campaign.jsonl.lifecycle_metrics` is null (telemetry is always on since v0.22.4, so null indicates this failure mode, not an opt-out) |
| Root cause | `LifecycleMetricsCollector.flush()` failed or its records were dropped before the analytics writer ran (since v0.22.4 there is no env gate — the collector cannot be disabled) |
| Detection | `tests/node/test-campaign-jsonl-shape.test.mjs` AC4.3 (flag-set populated case); B3 Stage 1 presence assertion |
| Recovery | Check debug.log `[LIFECYCLE]` lines and the campaign.jsonl append-failure warnings to locate where records were lost; fix the flush/append failure and re-run — the collector itself cannot be disabled, so no configuration change can repair this |
| Reference | v0.15.4 PR-B4 + audit fix C2 |

### F3.2 — Stage 2 false-PASS on absent metric
| Field | Value |
|---|---|
| Symptom | B3 Stage 2 assertion PASSes on band check even when telemetry never emitted |
| Root cause | jq query collapsed `null|empty` to `max=0`; band check `0 ≤ band` always true |
| Detection | `tests/node/test-b3-band-revalidation.test.mjs` percentile + bucket cases |
| Recovery | Pre-compute `entry_count` via flatten\|length; SKIP when 0; only run band check on non-empty data |
| Reference | v0.15.4 audit C1 fix; commit `21e12ed` |

### F3.4 — Synthetic baseline drift from production
| Field | Value |
|---|---|
| Symptom | B1 §4.2 synthetic numbers differ from B3 empirical p95 by >25% |
| Root cause | Synthetic anchored to zsh leader's POLL_INTERVAL=5s; production scenarios run via Node leader (100ms poll). Different leader, different floor |
| Detection | `tests/sv-real-llm/lib/b3-band-revalidation.mjs` runs 5-iter sandbox + compares |
| Recovery | Refit `B3_BAND_*_MS` constants in `tests/sv-real-llm/lib/b3-lifecycle-assertions.sh`. See revalidation findings doc |
| Reference | v0.15.4 audit H4; revalidation doc `docs/plans/v0.15-phase-b3-revalidation-findings.md` |

### F3.5 — unwaiveable pre-existing baseline gate (US-002)
| Field | Value |
|---|---|
| Symptom | Verifier gate fails on a finding predating the campaign; no in-loop N/A path; worker deadlocks; terminal BLOCKED, 0 US |
| Root cause | No first-class waiver channel honored by worker + verifier; PO free-text in memory.md un-parseable/un-honored |
| Detection | `tests/node/test-campaign-waivers.test.mjs` + `tests/test_campaign_waivers.sh` (shared fixture set); verdict citing waiver id |
| Recovery | Leader-validated `.rlp-desk/plans/waivers.json`, **fail-closed** — the ONLY honored path is an immutable baseline artifact (sha256-pinned) + finding-identity match, injected into both prompts; any finding not so proven (incl. campaign regressions) is never waivable; operator authorization is out-of-band via `--waivers-sha256`; every rejection surfaces a loud diagnostic (enum `artifact_missing/sha256_mismatch/finding_not_in_artifact/slug_mismatch/malformed_schema/unauthorized_hash_change`) |
| Reference | v0.22.7 US-002; `load_campaign_waivers` (lib_ralph_desk.zsh) + `validateWaivers` (src/node/shared/waivers.mjs); post-mortem `pa-live-audit-unblock` |

### F3.6 — zero-artifact campaign abandonment (US-004)
| Field | Value |
|---|---|
| Symptom | Campaign dies before iteration 1 with `--debug` off → empty logs dir, no status.json → post-mortem impossible |
| Root cause | status.json first written only inside the loop on both leaders; no t0 breadcrumb; tmux SIGHUP skips the EXIT-only trap |
| Detection | `tests/node/test-launch-breadcrumb.test.mjs` + `tests/test_launch_breadcrumb.sh` |
| Recovery | Synchronous t0 `launch-record.json` (durable) + best-effort outcome trap incl. HUP, both leaders |
| Reference | v0.22.7 US-004; post-mortem `authz-alignment` |

---

## §4 — Release / packaging

### F4.1 — A2 dry-run before version bump
| Field | Value |
|---|---|
| Symptom | `npm publish --dry-run` exits non-zero with EPUBLISHCONFLICT |
| Root cause | Plan v6 placed A2 in preflight before Step 2 (version bump). With package.json still at prior version, dry-run targets registry-existing version |
| Detection | First-time observed in 2026-05-07 release attempt; documented as plan defect |
| Recovery | Split into A2 (pre-bump: tolerate EPUBLISHCONFLICT exit; verify tarball assembled) + A2' (post-bump: strict exit-0 dry-run) |
| Reference | v0.15.4 audit C3; runbook §1 + §2 step 2.5 |

### F4.2 — Internal docs leak in npm tarball
| Field | Value |
|---|---|
| Symptom | npm-published tarball ships `docs/plans/*` (internal audit + planning) totaling ~280KB |
| Root cause | package.json `files` glob entry `"docs/"` was overly broad |
| Detection | `npm pack --dry-run \| grep "docs/plans"` (M5 verification command) |
| Recovery | Narrow glob to `"docs/rlp-desk/"`. postinstall.js syncs only from `docs/rlp-desk/`, so this is safe |
| Reference | v0.15.4 audit M5; commit `d26421e` |

---

## §5 — Add new entries

When a new failure mode is identified:
1. Pick the smallest existing §N category that fits (or §6 if none)
2. Use the same field schema (Symptom / Root cause / Detection / Recovery / Reference)
3. Cross-link to the originating bug doc, audit, or test
4. Optional: add a sv-gate-fast grep guard to enforce the recovery contract

When a failure mode is permanently retired:
1. Move to §7 "Retired" (do NOT delete — historical reference)
2. Note retirement reason (e.g., "design changed in v0.16; replaced by ...")

---

## §6 — Open issues (no recovery yet)

### F6.1 — us006 real-tmux boundary test flakiness
| Field | Value |
|---|---|
| Symptom | `tests/node/us006-campaign-main-loop.test.mjs` AC6.1 boundary case (real tmux session w/ 4 panes) intermittently fails 2-5 of 377 Node suite tests on first run; passes cleanly on retry |
| Root cause | Real tmux session creation + pane process spawn race: `tmux send-keys` may fire before pane's shell is fully ready, causing `can't find pane` warnings (which are non-fatal but timing-sensitive assertions occasionally trip) |
| Detection | Observed 2026-05-07 + 2026-05-08 in v0.15.4 release pipeline preflight; first-run fail-count varies 2-5 of 377 |
| Recovery | Runbook §2 S2 retry-once policy: re-run `npm run test:node`. Second run consistently 377/377 PASS |
| Reference | v0.15.4 release pipeline observation; runbook §7.5.3 Stage 2 INFO-band-exceeded path is unrelated but uses same retry-once mental model |

**Why "open"**: the flake is in the test, not in production code. Adding retry-once to npm test:node script would mask actual regressions. Better fix: redesign the AC6.1 boundary test to use `wait-for-pane-ready` synchronization before sending keys. Deferred to a future v0.15.x patch — not release-blocking.

---

## §7 — Retired

### F3.3 — sentinel_lock_to_unlock_ms unmeasurable for done-claim (RETIRED)
| Field | Value |
|---|---|
| Symptom | Metric never emitted for the done-claim sentinel even though lock IS applied |
| Root cause | Production happy-path never called `unlockSentinelFile(doneClaimFile)`; only signalFile + verdictFile were unlocked at iter start |
| Detection | Inspection: `lifecycle_metrics.sentinel_lock_to_unlock_ms` array contained iter-signal.json + verify-verdict.json entries but never done-claim.json |
| Recovery (historical) | Was documented in `lifecycle-metrics.mjs` markLockStart() as intentionally excluded (H2) |
| Reference | v0.15.4 audit H2; commit `feb1701` |
| **Retirement** | IMP-10 (2026-07-20): the metric now emits at done-claim's per-iteration close-out instead of a true unlock — zsh `archive_iter_artifacts` (`lib_ralph_desk.zsh:1177`, corrects the prior stale `:602` anchor) and the Node equivalent close-out sites in `campaign-main-loop.mjs`, tagged `ctx=archival` (NOTE leader difference: Node embeds `ctx` as a structured JSON field; the zsh leader carries it only in the debug-log detail text — machine consumers of a zsh-led campaign.jsonl must segregate the done-claim series by `sentinel_type`, not `ctx`). `_lifecycle_mark_lock_start`/`markLockStart` are now called at every done-claim lock site (the H2 exclusion is closed) so the pair actually records a duration. See `tests/test_lifecycle_doneclaim_archival.sh` and `test-campaign-jsonl-shape.test.mjs`. |

(no other entries as of 2026-07-20)
