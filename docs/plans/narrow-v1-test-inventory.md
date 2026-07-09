# narrow-v1 US-002 test inventory — execution-trace classification

Dev-meta record for US-002 of the narrow-v1 PRD (`.omc/plans/narrow-v1-prd.md`).
Deviation from the PRD text: this doc lives at `docs/plans/` rather than
`docs/rlp-desk/internal/` — that directory is `.gitignore`d "local only,
never publish" (see `docs/plans/narrow-v1-evidence.md`'s note on the same
issue from US-001), so it cannot be the AC1 inventory target.

## Classifier

Every `tests/test_*.sh` file (69 total, pre-prune) was read in full and
classified with an EXECUTION-TRACE test, not by filename or grep count:

- **BEHAVIORAL**: at least one assertion consumes runtime output of
  `init_ralph_desk.zsh`, `run_ralph_desk.zsh`, `lib_ralph_desk.zsh`, or
  src/node code — runs one as a subprocess and checks output/exit code,
  extracts a function and executes it, or inspects files/state such a run
  generated. Mixed files (any behavioral assertion alongside structural
  ones) count as BEHAVIORAL and stay whole — never split.
- **STRUCTURAL-CONTRACT**: no runtime execution, but at least one assertion
  greps `src/commands/rlp-desk.md`, `src/governance.md`, or contract text
  (e.g. a prompt/template section) embedded in `src/scripts/init_ralph_desk.zsh`
  — **all three** are the SV-trigger files per PRD Principle 4, not just the
  two docs (this was a classification gap in the first pass, corrected below
  after Codex review) — or the A5 trigger-file diff oracle surface. These
  three files have no other enforcement mechanism for the specific text a
  test pins, so their grep tests stay in the run set per PRD Principle 2.
- **STRUCTURAL**: no assertion consumes output of the real product runtime
  (no subprocess run, no extract-and-execute, no inspection of state such a
  run generated), and no assertion pins contract text in any of the three
  SV-trigger files or the A5 oracle surface. These are the prune candidates.
  Note: "no runtime execution" does not mean "no execution at all" — a few
  of these files execute a hand-copied or hand-simulated reimplementation of
  the logic under test (shell pipeline copy-pasted as literal text, OS-level
  lock probes standing in for the real locking function) rather than the
  real product code. That is exactly why they are archived rather than kept
  as-is: a hand-copy can silently diverge from the real implementation it
  was meant to mirror, so it provides no durable guarantee about the real
  runtime's behavior. Each such file is flagged individually below.

Bias rule applied throughout: any file with a plausible behavioral or
contract-pinning read stayed in a run-set bucket; only files with zero
ambiguity on either axis were marked STRUCTURAL.

## Inventory table

| # | File | Bucket | Deciding assertion |
|---|------|--------|---------------------|
| 1 | test_a14a15_init_improve.sh | BEHAVIORAL | `run_init()` (L72-79) runs `zsh "$INIT"` as a subprocess (called throughout, e.g. L97,111,163,166,197,216,220,261,267); assertions inspect generated plan/memo files. |
| 2 | test_a18_lockfile.sh | BEHAVIORAL | `run_runner()` (L85-100) runs `zsh "$RUN"` against a stubbed tmux; assertions inspect real generated `.lock` files and exit codes (L130-148, 200-226, 259-275). |
| 3 | test_a4_fallback_prompt_guard.sh | BEHAVIORAL | L17-19 `sed`-extract `_PROMPT_RE`/`_AFFORDANCE_RE` from `run_ralph_desk.zsh`, source them (L19), execute matching logic (L26-81) against real regex — sourced real data, not hardcoded duplicate. |
| 4 | test_auto_dismiss_prompts.sh | BEHAVIORAL | L16-18 `sed`-extract `auto_dismiss_prompts()` body from `run_ralph_desk.zsh`, source (L36), execute repeatedly (L47,63,205,253) against mocked tmux, check real function's `send-keys` output. |
| 5 | test_b2fix_sentinel_lock.sh | BEHAVIORAL (mixed) | Part B (L99-143) `awk`-extracts `_lock_sentinel`/`_unlock_sentinel`/`_kill_pane_process` from `lib_ralph_desk.zsh`, sources (L102), executes against real temp files, checks real `chmod` modes (L111-143). |
| 6 | test_b3_lifecycle_emit.sh | BEHAVIORAL | L22-35, 53-62, 66-75 run `zsh -c` subprocesses sourcing real `lib_ralph_desk.zsh`, call real `log_lifecycle_metric`/`write_campaign_jsonl`, inspect generated `campaign.jsonl` via `jq` (L40-130). |
| 7 | test_b3_pane_reap_integration.sh | BEHAVIORAL | L36 sources real `lib_ralph_desk.zsh`; L68 executes real `_kill_pane_process` against a live tmux pane; L75 executes real `write_campaign_jsonl`; assertions inspect the generated `campaign.jsonl` (L69-90). |
| 8 | test_batch_partial_progress.sh | BEHAVIORAL | Bulk is pure grep/awk (AC1-AC7, L40-189; `run_harness()` at L29-32 is never called), but L195 and L202 run `zsh -n "$RUN"` / `"$INIT"` as real subprocesses and check `$?` — thin but present. |
| 9 | test_cb_and_analytics.sh | STRUCTURAL-CONTRACT | T1-T10 (L22-169) are grep/awk against RUN/LIB source, but `test_t11_governance_cb_default` (L177-183) greps `src/governance.md` for CB-default-6 text — an SV-trigger doc. |
| 10 | test_codex_idle_no_progress.sh | BEHAVIORAL | L23-27 `sed`-extract `is_codex_idle_ui`, `_migrate_legacy_verdict`, `_verifier_pane_has_verdict` from `run_ralph_desk.zsh`, source (L34), execute (L54-164) against real temp verdict files, assert on generated migration side effects (L140-163). |
| 11 | test_consensus_metadata_mode.sh | BEHAVIORAL | Repeated `zsh "$RUN" --consensus ...` subprocess runs (L94,101,108,115,122,135,170,178,186,196); inspects generated `metadata.json`/`debug.log` via `jq`/`grep` (L52-85). |
| 12 | test_d28_heredoc_quoting.sh | BEHAVIORAL | L30 runs `zsh "$INIT" f6mini "$OBJ"` as a subprocess against a temp git repo; L36-59 inspect generated worker/verifier/test-spec prompt files for corruption. |
| 13 | test_engine_refactor.sh | BEHAVIORAL | `extract_fn`/`run_harness` (L13-25) pull a function body from RUN/LIB then `eval` a script pasting it in and calling it (e.g. L44 `check_dead_pane`), checking `$?`. |
| 14 | test_final_verify_sequential.sh | STRUCTURAL | L16-84 `awk '/^run_sequential_final_verify\(\)/,/^}/'` pulls the fn body from RUN, then only greps that extracted text for keywords (L28,38,49,60,70) — extraction without execution, no SV-trigger-file contract. No active equivalent coverage remains for this source-shape assertion; the archived check asserted source text, not behavior — accepted coverage stance under the NARROW plan. |
| 15 | test_imp01_stat_mtime_gnu.sh | BEHAVIORAL | L40-43: `zsh --no-rcs -c 'source "$LIB" ...; _file_mtime "$testfile"'` sources real `lib_ralph_desk.zsh` and executes `_file_mtime`, checks stdout against `$real_mtime` (L48, repeated L70-73). |
| 16 | test_imp07_api_sniff_context.sh | BEHAVIORAL | L19-25 `detect()`: `zsh --no-rcs -c 'source "$LIB" ...; detect_api_error "$1"'`, asserts exit code (L26-27, used L30-44). |
| 17 | test_imp08_slug_guard.sh | BEHAVIORAL | L27 runs `zsh "$RUN"` as a subprocess with a path-traversal `LOOP_NAME`; L29-30 check real exit code and that no traversal dir was created; L33,37 similarly subprocess-run RUN/INIT. |
| 18 | test_imp09_paste_no_tmpfile.sh | BEHAVIORAL | `_extract_fn` (L20-22) brace-extracts `paste_to_pane` from RUN; L42-46 splices it into a harness script executed via `zsh --no-rcs` (L46); L47-55 inspect resulting tmux-buffer capture and `/tmp` leak state. |
| 19 | test_monitor_counter.sh | STRUCTURAL | File header (L8-12) states it deliberately avoids dispatching the runner end-to-end; all 7 assertions (L39-62) are plain `grep -q` against `run_ralph_desk.zsh` — no execution anywhere, no SV-trigger-file contract. No active equivalent coverage remains for this source-shape assertion; the archived check asserted source text, not behavior — accepted coverage stance under the NARROW plan. |
| 20 | test_nightly_streak.sh | BEHAVIORAL | L18 `ev()`: `bash "$NIGHTLY" --eval-only` runs `tests/sv-real-llm/harness/nightly-run.sh` as a real subprocess and consumes its stdout (L23,26,29,31,35,39,44) plus a dry-run subprocess check (L47). Target is a test-harness script rather than one of the 4 named production files, but it is genuine subprocess execution + output consumption, not a grep — kept BEHAVIORAL per the bias rule. |
| 21 | test_no_progress_and_default_no.sh | BEHAVIORAL | L13 `sed -n` extracts a real chunk of `run_ralph_desk.zsh` into `$TMP_LIB`; L37 sources it; L50,63,76,89,97,109-116,130-133 call the extracted `auto_dismiss_prompts`/`check_no_progress` directly and assert on real return codes/vars. |
| 22 | test_operational_context.sh | BEHAVIORAL (mixed) | L135,151 run `zsh "$INIT" ...` as a subprocess; L137-185 inspect generated worker/verifier prompt files it produced. |
| 23 | test_option_cleanup.sh | STRUCTURAL-CONTRACT | DOC1-DOC8 (L246-300) grep `src/governance.md` and `src/commands/rlp-desk.md` — both SV-trigger docs — for contract text. The C3-C5 "runtime" blocks (L139-184) are a hand-authored reimplementation of `_should_use_consensus`, not extracted-and-executed real code, so they don't independently qualify BEHAVIORAL; the SV-doc greps keep the file in the run set. |
| 24 | test_post_sentinel_reap_lock.sh | BEHAVIORAL | L29 sources real `lib_ralph_desk.zsh`; L48,52 call real `_kill_pane_process`/`_lock_sentinel` against a live tmux pane; L53-71 inspect the resulting sentinel file's mode/mtime/content. |
| 25 | test_prompt_stall_escalation.sh | BEHAVIORAL | L13-14 `sed -n` extracts the §4.13/§4.16 helper region from `run_ralph_desk.zsh` into `TMP_LIB`; L41 sources it; L52,60,69,91,102,106 execute the extracted `auto_dismiss_prompts`/`check_prompt_stall` and assert on real side effects. |
| 26 | test_self_verification_0_11_1.sh | BEHAVIORAL | L40 sources `lib_ralph_desk.zsh` inside `zsh -c`; L60 executes `_r12_check_lifecycle` (calling real sourced helpers), asserts exit code/JSON sidecar/elapsed time (L62-76); R13 (L89-108) runs real `tmux new-session`/`has-session` subprocess calls. |
| 27 | test_self_verification_0_11_handoff.sh | BEHAVIORAL | Repeatedly sources `$LIB` inside `zsh -c` and executes real functions: `_emit_a4_fallback_audit` (L35), `_lint_test_density` (L70), `write_blocked_sentinel` (L120), `_canonical_block_reason` (L145-146), `_quarantine_stale_signal` (L173), `write_cost_log` (L198) — each asserted via generated files/JSON. |
| 28 | test_status_detail.sh | STRUCTURAL-CONTRACT | Every assertion is `grep -A20/-A30 '## \`status'` against `src/commands/rlp-desk.md` (L14-64) — no execution anywhere, pure SV-trigger-doc pin. |
| 29 | test_template_generation.sh | STRUCTURAL-CONTRACT | Pure `grep -qE` assertions (L13-31) against `init_ralph_desk.zsh`, `src/commands/rlp-desk.md` (L56-58,62), and `src/governance.md` (L51) — no execution; hits both SV-trigger docs. |
| 30 | test_us001_debug_refactor.sh | STRUCTURAL-CONTRACT | Static `grep_count`/`grep_exists` checks (L22-27) against CMD/RUN/GOV/INIT with no execution; pins `src/commands/rlp-desk.md` (L48) and `src/governance.md` (L116,215-217) directly. |
| 31 | test_us001_prd_splitting.sh | BEHAVIORAL | Repeatedly runs `zsh "$INIT" ...` as a real subprocess (L47,56,84,95,113,120,131,140,155,173,199,216,220,248,251-252,261,270,274), inspects generated split files and exit codes (L252). |
| 32 | test_us001_sv_report_e2e.sh | BEHAVIORAL | L22-48/375-388 `awk`-extract `generate_sv_report()`/`check_dependencies()` from `run_ralph_desk.zsh`; L105-124/281-299/445-460 splice + execute via `zsh -f` (L123 etc.), assert on generated report files across 9 scenarios (S1-S9). |
| 33 | test_us001_tmux_sv_report.sh | STRUCTURAL | L16-152 pure `grep_count`/`grep_exists` against `run_ralph_desk.zsh`/`lib_ralph_desk.zsh` (neither SV-trigger doc); L111-136 `awk`-extract `generate_sv_report()`'s body but only grep it — extraction without invocation. |
| 34 | test_us002_consensus_stability.sh | STRUCTURAL-CONTRACT | All assertions are `grep`/`sed`/`awk` static counts (`count_grep`, L24-34); L76-79/153-156 extract `check_stale_context()` text via `grep -A25` but only re-grep it; pins `src/commands/rlp-desk.md` (L90) and `src/governance.md` §7¾ (L132-142). |
| 35 | test_us002_governance_cb_table.sh | STRUCTURAL-CONTRACT (canonical PRD example) | L16 `section8()` awk-extracts `## 8. Circuit Breaker` from `src/governance.md`; L47-92 grep only that extracted text — no execution, pure `src/governance.md` contract pin. |
| 36 | test_us002_perus_inject.sh | BEHAVIORAL | L39-51 `_run_inject` `sed`-extracts `inject_per_us_prd()` from `run_ralph_desk.zsh`, appends a real invocation, executes via `zsh "$tmp_script"` (L51), captures stdout/stderr; L184,194 also run `zsh "$INIT"` subprocess. |
| 37 | test_us003_campaign_report.sh | STRUCTURAL-CONTRACT | Bulk of ACs (L49-90,129-204,242-247,274-284) grep `src/commands/rlp-desk.md`; L3-boundary (L299-304) greps `src/governance.md`. No execution anywhere. |
| 38 | test_us003_timeout_double_call.sh | BEHAVIORAL | L176-275 `_extract_gcrf_body()` awk-extracts `generate_campaign_report()`; `run_gcrf_harness()` (L242, `zsh -f "$dir/h.zsh"`) executes it twice, asserts on generated `campaign-report*.md` files. |
| 39 | test_us003_unified_model_format.sh | BEHAVIORAL | L29-51 `_run_parse()` sed-extracts `parse_model_flag()`, executes via `zsh "$tmp_script"` (L47), checks stdout/stderr/exit code; L216-238 run `zsh "$RUN" --worker-model ...` live subprocess. |
| 40 | test_us004_cost_log_timing.sh | BEHAVIORAL | L21-38 awk-extracts `write_cost_log()`; every AC builds a harness executed via `zsh -f` (L79) producing real `cost-log.jsonl`, asserted throughout the 546-line file. |
| 41 | test_us004_progressive_upgrade.sh | BEHAVIORAL | L18-56 `extract_fn()` sed-extracts functions (`check_model_upgrade`, `get_next_model`, etc.); `run_harness()` (L52, `zsh -f`) executes them, asserting on `$WORKER_MODEL`/exit codes (L116-124,234-257,397-408). |
| 42 | test_us004_self_verification.sh | BEHAVIORAL (mixed) | Mostly grep against INIT/CMD/GOV (L43-253), but L261-364 `_run_init()` runs `zsh "$INIT" ...` in a tmpdir and asserts exit code + generated `debug-v1.log`/PRD content. |
| 43 | test_us005_completed_stories_loader.sh | STRUCTURAL | AC1/AC2 (L40-65) grep-only against `run_ralph_desk.zsh` (a source file, not an SV-trigger file). L3 "E2E" section (L99-157) does execute code, but it is a hand-COPIED reimplementation of the sed/grep/tr pipeline typed as literal text in the test, run against a synthetic fixture — never the real `$RUN` source, never invoked or extracted from it. This does not satisfy BEHAVIORAL (which requires consuming output of the real product runtime) and is precisely the divergence risk that motivates archiving: the copy can silently drift from `run_ralph_desk.zsh`'s actual pipeline. No active equivalent coverage remains for this exact loader behavior; accepted coverage stance under the NARROW plan. |
| 44 | test_us005_final_consensus.sh | BEHAVIORAL | L27-67 `_run_should_use_consensus()` sed-extracts `_should_use_consensus()`, executes via `zsh "$tmp_script"` (L64); L145-146,211-213,253-254 also run `zsh "$RUN"` directly as a subprocess. |
| 45 | test_us005_suggested_next_actions.sh | BEHAVIORAL | L22-42 awk-extracts `generate_campaign_report()`; L226-283 `run_gcr_harness()` builds and executes (`zsh -f`, L281) a real harness per status, asserting on generated `campaign-report.md`. |
| 46 | test_us006_init_presets.sh | BEHAVIORAL | L17-65 awk-extracts `print_run_presets()`; `run_presets_with_codex/without_codex()` execute it via `zsh -f` (L49,62); L243,259 also run `zsh "$INIT" ...` directly. |
| 47 | test_us007_brainstorm_recommendation.sh | STRUCTURAL-CONTRACT | L21 awk-extracts the brainstorm section from `src/commands/rlp-desk.md`, only greps it (L34-186) — no execution anywhere, pure SV-trigger-doc pin. |
| 48 | test_us007_verifier_anti_rubber_stamp.sh | STRUCTURAL-CONTRACT (corrected — see Codex round 1 below) | `extract_verifier_prompt()` (L18-24) awk-extracts the `# --- Verifier Prompt ---` template section from `src/scripts/init_ralph_desk.zsh`, only greps it (L36-230) — no execution, but `init_ralph_desk.zsh` **is** the third SV-trigger file per PRD Principle 4 (not just the two docs), and this is the literal prompt text sent to the real LLM verifier in production, with no other test enforcing its content. Originally misclassified STRUCTURAL by narrowing "SV-trigger" to only `rlp-desk.md`/`governance.md`; restored to `tests/` on Codex review. |
| 49 | test_us008_self_verification_e2e.sh | BEHAVIORAL | L86 `zsh -f` harness executes an extracted `atomic_write`+session-config write block from `run_ralph_desk.zsh`, inspects produced JSON; L285 runs `zsh -f "$INIT" ...` as a real subprocess and checks resulting filesystem state. |
| 50 | test_us009_api_retry_guard.sh | BEHAVIORAL | L88 executes extracted `is_api_error`/`detect_api_error` (pulled from RUN/LIB) via a subprocess, checks exit code; L161 similarly executes extracted `poll_for_signal`. |
| 51 | test_us010_live_prd_update.sh | BEHAVIORAL (mixed) | L320 runs a harness built from extracted `compute_prd_hash`/`count_prd_us`/`check_prd_update` (from RUN), inspects generated `debug.log`. |
| 52 | test_us011_worker_model_upgrade.sh | BEHAVIORAL | L353 `zsh -f` harness executes extracted `get_next_model`; L719-724 `import()`s and runs real `src/node/model-ladder.mjs`, compares output to the zsh function's. |
| 53 | test_us012_sv_tmux_skip_traceability.sh | STRUCTURAL | L52-75 pure `grep -cE` against `run_ralph_desk.zsh`/`lib_ralph_desk.zsh` source text only (`assert_one`/`assert_zero` helpers) — no execution, no SV-trigger-file assertions. Independently re-read and confirmed; note it is one of the 13 files listed by name in `tests/sv-gate-fast.sh`'s "Critical zsh unit tests" array (L199-213), which required a path update on archival — see Gate updates below. No active equivalent coverage remains for this source-shape assertion; the archived check asserted source text, not behavior — accepted coverage stance under the NARROW plan. |
| 54 | test_us013_prd_cross_us_lint.sh | BEHAVIORAL | L84-87 awk-extract+execute `_detect_cross_us_refs` from INIT; L296-318 `node --input-type=module -e` imports and runs real `src/node/reporting/campaign-reporting.mjs`; L383-483 source LIB and call real `write_blocked_sentinel`/`generate_campaign_report`. |
| 55 | test_us014_next_mission_candidate.sh | STRUCTURAL-CONTRACT | L46-49 pin `src/governance.md` §7 contract text (`next_mission_candidate`, `multi-mission-orchestration.md`). AC5 (L65-74) is a standalone hand-written Node reimplementation of the `??` fallback, never extracted from or executed against `campaign-main-loop.mjs` — doesn't independently qualify BEHAVIORAL, so the GOV pin is what keeps the file in the run set. |
| 56 | test_us015_sentinel_json_taxonomy.sh | BEHAVIORAL | L82-89 source LIB, call real `write_blocked_sentinel`, inspect produced markdown+JSON sidecar; L181-189 `classify()` sources LIB and calls real `_classify_cross_us_or_metric`. |
| 57 | test_us016_lane_enforcement.sh | STRUCTURAL-CONTRACT | L63-72 pin `src/governance.md` §7e contract text (Lane Enforcement). AC7 (L111-126) is a standalone hand-written Node reimplementation of `_initLaneAuditLog`, never sourced/executed against `campaign-main-loop.mjs` — the GOV pin keeps the file in the run set. |
| 58 | test_us017_a4_fallback_audit.sh | BEHAVIORAL | L71-75 source LIB, invoke real `_emit_a4_fallback_audit`, check generated `a4-fallback-audit.jsonl` for real appended entries. |
| 59 | test_us018_test_density.sh | BEHAVIORAL | L87-92 source LIB, call real `_lint_test_density` against fixture files, check stdout/exit code (L107-112 repeat for strict mode). |
| 60 | test_us019_verify_partial.sh | STRUCTURAL-CONTRACT | L47-51 pin `src/governance.md` §7g contract text (Signal Vocabulary Extension, `verify_partial_malformed`). AC6 (L65-74) is a standalone hand-written Node `classify()` reimplementation, never extracted from/executed against `campaign-main-loop.mjs` — GOV pin keeps the file in the run set. |
| 61 | test_us020_blocked_hygiene.sh | BEHAVIORAL | L66-73 source LIB, execute `write_blocked_sentinel(...)`; L76-86 inspect the JSON sidecar it generated. |
| 62 | test_us021_consecutive_blocks.sh | BEHAVIORAL | L63-68 source LIB, execute `_canonical_block_reason(...)` three times, assert on real stdout (L69-83). |
| 63 | test_us022_cross_mission_us_leak.sh | BEHAVIORAL | L76-80 source LIB, execute `_quarantine_stale_signal(...)`, inspect filesystem state it produced (L83-87); L91-94 execute `_extract_prd_us_list(...)`. |
| 64 | test_us023_cost_log_nonempty.sh | BEHAVIORAL | L58-64 source LIB, execute `write_cost_log 1`, read generated `cost-log.jsonl` (L65-78). |
| 65 | test_us024_pane_lifecycle.sh | BEHAVIORAL | L57-61 source LIB, execute `_verify_pane_alive`/`_verify_session_alive`; L73-133 call real `write_blocked_sentinel`, inspect generated sidecar. |
| 66 | test_us025_session_disambiguation.sh | STRUCTURAL | L29-49 pure `assert_one`/grep against `$RUN` source text only — no source, no subprocess execution, no A5-oracle reference, no SV-trigger file opened. No active equivalent coverage remains for this source-shape assertion; the archived check asserted source text, not behavior — accepted coverage stance under the NARROW plan. |
| 67 | test_us026_runner_lockfile.sh | STRUCTURAL | AC1-4 (L31-54) grep only RUN/LIB (not SV-trigger files). AC5-7 (L56-114) do execute code — real OS primitives (`mkdir`, `kill -0`, `shasum`) — but never source `lib_ralph_desk.zsh` nor call the real `acquire_slug_lock`; they hand-SIMULATE lock semantics with a standalone reimplementation, so this does not satisfy BEHAVIORAL (which requires consuming output of the real product function) and is exactly the divergence risk archiving addresses: the simulation can silently drift from what `acquire_slug_lock` actually does. Mitigating factor: real `acquire_slug_lock` execution coverage of the same race conditions already exists in `test_zsh4_lock_redesign.sh` (BEHAVIORAL, retained) — archiving this file does not remove coverage of the real function, only of this file's separate hand-simulated model of it. |
| 68 | test_v052_improvements.sh | BEHAVIORAL (mixed) | `extract_fn()` (L19-27) sed-extracts a function body from LIB/RUN; `test_d4_runtime_tracking` (L84-109) feeds extracted `record_us_failure` into `run_harness()` (L30-39, `zsh -f`) and executes it, asserting on `US_FAIL_HISTORY` counts. |
| 69 | test_zsh4_lock_redesign.sh | BEHAVIORAL | L16 sources `lib_ralph_desk.zsh` directly; L28,33-34,39-40,44-46,51-52,61-62,69-71 call the real `acquire_slug_lock(...)` and assert on its return code and lock-file/mutex state. |

## Summary counts

- **BEHAVIORAL: 49** — stay in `tests/`, unchanged.
- **STRUCTURAL-CONTRACT: 13** (was 12 in the first pass; corrected after
  Codex round 1 — see below) — stay in `tests/`, unchanged (all pin
  `src/commands/rlp-desk.md`, `src/governance.md`, and/or contract text
  embedded in `src/scripts/init_ralph_desk.zsh` — the three SV-trigger
  files — with no other enforcement): `test_cb_and_analytics.sh`,
  `test_option_cleanup.sh`, `test_status_detail.sh`,
  `test_template_generation.sh`, `test_us001_debug_refactor.sh`,
  `test_us002_consensus_stability.sh`, `test_us002_governance_cb_table.sh`,
  `test_us003_campaign_report.sh`, `test_us007_brainstorm_recommendation.sh`,
  `test_us007_verifier_anti_rubber_stamp.sh`,
  `test_us014_next_mission_candidate.sh`, `test_us016_lane_enforcement.sh`,
  `test_us019_verify_partial.sh`.
- **STRUCTURAL: 7** (was 8 in the first pass) — moved to
  `tests/structural-archive/`: `test_final_verify_sequential.sh`,
  `test_monitor_counter.sh`, `test_us001_tmux_sv_report.sh`,
  `test_us005_completed_stories_loader.sh`,
  `test_us012_sv_tmux_skip_traceability.sh`,
  `test_us025_session_disambiguation.sh`, `test_us026_runner_lockfile.sh`.
- **Total: 69** files inventoried. Retained run-set: 62 (49 + 13).

### Codex round 1 correction (P2-a)

The first pass defined "SV-trigger docs" as only `src/commands/rlp-desk.md`
and `src/governance.md`, omitting `src/scripts/init_ralph_desk.zsh` — even
though PRD Principle 4 names all three as the SV-trigger set. Re-examining
the 5 files Codex flagged (`test_us007_verifier_anti_rubber_stamp.sh`,
`test_final_verify_sequential.sh`, `test_monitor_counter.sh`,
`test_us005_completed_stories_loader.sh`,
`test_us025_session_disambiguation.sh`) against the corrected three-file
definition:
- `test_us007_verifier_anti_rubber_stamp.sh` greps the Verifier Prompt
  template embedded in `init_ralph_desk.zsh` itself (the actual text sent to
  the real LLM verifier) — this **is** an SV-trigger contract with no other
  enforcement. **Restored to `tests/` as STRUCTURAL-CONTRACT** (`git mv`
  back; no path-variable fix needed, its `INIT` path is CWD-relative, not
  `$0`-relative).
- The other 4 grep only `run_ralph_desk.zsh`/`lib_ralph_desk.zsh` (never an
  SV-trigger file) and stay archived — see their updated table rows above
  for the specific honesty language on what coverage is and isn't preserved.

## Borderline calls worth flagging

- `test_a4_fallback_prompt_guard.sh` and `test_batch_partial_progress.sh`:
  thin execution surface (regex-constant sourcing; a single `zsh -n` syntax
  check) — resolved BEHAVIORAL per the bias rule rather than treated as
  effectively-structural.
- `test_nightly_streak.sh`: subprocess-executes `tests/sv-real-llm/harness/nightly-run.sh`,
  a test-harness script, not one of the four named production targets
  (init/run/lib/src-node) — still genuine subprocess execution + output
  consumption, kept BEHAVIORAL.
- `test_us014_next_mission_candidate.sh`, `test_us016_lane_enforcement.sh`,
  `test_us019_verify_partial.sh`: each contains a hand-written standalone
  Node "functional probe" that mimics the described logic without ever
  importing or executing the real `campaign-main-loop.mjs` source — this
  fails the strict BEHAVIORAL bar, but each file also greps `src/governance.md`
  for a dedicated contract section, so STRUCTURAL-CONTRACT is the correct
  bucket regardless.
- `test_us012_sv_tmux_skip_traceability.sh`: labeled a "Critical zsh unit
  test" inside `tests/sv-gate-fast.sh`, which raised suspicion during
  review; independently re-read in full and confirmed to be pure
  `grep -cE` against source text with zero execution and zero SV-trigger-doc
  contract. The "critical" label reflects gate curation history, not
  execution behavior — exactly the drift this PRD is pruning. Archived.
- `test_us026_runner_lockfile.sh`: AC5-7 exercise real OS lock semantics
  (`mkdir`, `kill -0`, PID staleness) but against a hand-rolled
  reimplementation of the locking algorithm, never the real
  `acquire_slug_lock` function — so it does not clear the BEHAVIORAL bar.
  Real-function coverage of the same surface already exists in
  `test_zsh4_lock_redesign.sh` (retained, BEHAVIORAL), so archiving this
  file does not remove coverage of `acquire_slug_lock` itself.

## Archive policy

`tests/structural-archive/` is excluded from the shell test harness: `npm run test:zsh`
globs `tests/test_*.sh` only (see `package.json`'s `test:zsh` script), and
that glob does not descend into subdirectories, so files moved into
`tests/structural-archive/` stop running automatically without any harness
code change. They remain git-tracked (not deleted) rather than removed,
because a structural grep test can become contract-load-bearing later —
concretely, if a new SV-trigger file is introduced, if `src/governance.md`,
`src/commands/rlp-desk.md`, or a prompt/template section of
`src/scripts/init_ralph_desk.zsh` gains a new contract that an archived file
already happens to check, or if a maintainer decides a source-text contract
needs enforcement without full execution coverage. The re-inclusion
criterion is: **a structural test becomes contract-load-bearing** (its
greps pin a contract of one of the three SV-trigger files, or the A5 oracle
surface, that has no other enforcement) — at that point `git mv` it back
into `tests/` and update this inventory. (`test_us007_verifier_anti_rubber_stamp.sh`
is the concrete example of this exact scenario — see Codex round 1 above.)

## Gate updates

`tests/sv-gate-fast.sh` names 13 `tests/test_*.sh` files individually in its
"Critical zsh unit tests" array (L199-213 pre-edit). One of the 13,
`test_us012_sv_tmux_skip_traceability.sh`, is in the STRUCTURAL/archived set;
its path in that array was updated to
`tests/structural-archive/test_us012_sv_tmux_skip_traceability.sh` so the
gate still finds and runs it (the entry itself was kept, not deleted, per
Principle 2 — grep coverage of `run_ralph_desk.zsh`/`lib_ralph_desk.zsh`
this test provides is preserved even though it no longer lives in the
default `tests/` run set). The other 12 named files are all BEHAVIORAL and
were not moved. `tests/sv-gate-full.sh` does not reference any
`tests/test_*.sh` file by path (verified via grep), so it needed no update.
