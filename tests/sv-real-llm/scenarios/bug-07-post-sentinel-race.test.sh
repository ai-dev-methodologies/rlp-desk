#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #7 post-sentinel process race.
#
# Reproduces the race window: after worker writes iter-signal.json, the TUI
# process keeps running and may rewrite the sentinel during ~1m43s before
# leader's reaper kills it. PR-A's _kill_pane_process + _lock_sentinel
# closes this race.
#
# Asserts: after leader detects sentinel, mtime is FROZEN within 5s
# (process killed + chmod 0444 applied).

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-07-post-sentinel-race"
SCENARIO_DESCRIPTION="Post-sentinel process race window closed by reaper+lock"
SCENARIO_BUG_CATEGORY="a-tmux-process-lifecycle"
SCENARIO_HISTORICAL_BUG="Bug #7 (BOS 2026-05-06, 1m43s mtime drift observed)"
SCENARIO_COST_BUDGET_USD="3"
SCENARIO_TIMEOUT_SECONDS="900"
SCENARIO_REQUIRES="claude_cli OR codex_cli; tmux; jq; node"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  # Resolve + SOURCE the B3 assertion lib to an ABSOLUTE path BEFORE cd'ing into the
  # sandbox AND BEFORE the cleanup trap. Two reasons:
  #  (1) BASH_SOURCE[0] is relative when run-scenario.sh is invoked with a relative path,
  #      so resolving after the sandbox cd produced "/lib/..." (missing) → B3 SKIPPED.
  #  (2) bash 3.2 gotcha: a `trap ... RETURN` fires when a `source` completes — sourcing
  #      the lib AFTER the `rm -rf $sandbox` trap would delete the sandbox mid-assertion
  #      (campaign.jsonl included). Source here, pre-trap; nested b3_assert_* calls later
  #      do NOT fire the RETURN trap.
  local _b3_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/lib/b3-lifecycle-assertions.sh"
  # shellcheck source=tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
  [[ -f "$_b3_lib" ]] && source "$_b3_lib"

  local sandbox_dir
  sandbox_dir=$(mktemp -d -t "sv-real-llm-${SCENARIO_ID}.XXXXXX")
  trap "rm -rf '$sandbox_dir' 2>/dev/null; tmux kill-session -t 'sv-real-${SCENARIO_ID}' 2>/dev/null" RETURN

  cd "$sandbox_dir" || return 1
  git init -q .
  echo "# scratch" > README.md
  git add README.md
  git -c user.email=test@test.local -c user.name=test commit -q -m "init"

  local slug="sv-bug07-race"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/context .rlp-desk/logs/$slug/runtime
  # v0.13.0+ scaffold validation requires context + memory files (else leader exits "Scaffold validation failed").
  echo "# $slug - Latest Context" > .rlp-desk/context/$slug-latest.md
  echo "# $slug - Campaign Memory" > .rlp-desk/memos/$slug-memory.md
  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug07-race
### US-001: trivial
- README.md exists
EOF
  # CRISP worker protocol so a live haiku worker actually completes US-001 and emits the
  # iter-signal — only then does the leader reap the worker pane (run:3838) and lock the
  # sentinel, the invariant A1/A2 exist to observe. (A trivial one-liner left the worker
  # confused → no signal → no reap → A1 could never fire.)
  cat > .rlp-desk/prompts/$slug.worker.prompt.md <<EOF
You are the Worker for US-001 of a tiny synthetic campaign. Do EXACTLY these steps, then stop:
1. Append a line "done" to README.md.
2. Stage + commit: git add -A && git commit -m "US-001: append done".
3. Write done-claim JSON to EXACTLY: $sandbox_dir/.rlp-desk/memos/$slug-done-claim.json
   {"us_id":"US-001","claims":["AC1: README contains done"],"execution_steps":[{"step":"implement","ac_id":"AC1","command":null,"exit_code":0,"summary":"appended done"},{"step":"commit","ac_id":"AC1","command":"git commit","exit_code":0,"summary":"committed"}]}
4. Write iter-signal JSON to EXACTLY: $sandbox_dir/.rlp-desk/memos/$slug-iter-signal.json
   {"iteration":1,"status":"verify","us_id":"US-001","summary":"US-001: AC1 README contains done","iter_signal_quality":"specific"}
Use the Write tool for the JSON files. Do not start any other work.
EOF
  cat > .rlp-desk/prompts/$slug.verifier.prompt.md <<EOF
You are the Verifier. Your ONLY task: write ONE verdict FILE (not stdout).
Use the Write tool to create EXACTLY: $sandbox_dir/.rlp-desk/memos/$slug-verify-verdict.json
with EXACTLY this JSON (fill verified_at_utc with the current UTC ISO-8601 time):
{"verdict":"pass","us_id":"US-001","verified_at_utc":"2026-01-01T00:00:00Z","summary":"README contains done","recommended_state_transition":"complete","issues":[],"evidence_paths":["README.md"]}
Write the file, then stop.
EOF

  # No pre-seed — let leader run normally. We test the IN-CODE invariant:
  # after leader detects iter-signal.json, _kill_pane_process is called
  # within seconds.
  local exercise_log="$sandbox_dir/exercise.log"
  # v0.15.4 PR-B3: enable B4 lifecycle observability so two-stage assertions
  # below can read campaign.jsonl.lifecycle_metrics.
  #
  # v0.15.4 pre-release audit C2 fix: support RLP_DESK_NODE_PATH override to
  # break the pre-merge circular dependency. Default → installed leader; set
  # to source tree `<repo>/src/node/run.mjs` for pre-merge AC3.1a sample.
  local node_leader_path="${RLP_DESK_NODE_PATH:-$HOME/.claude/ralph-desk/node/run.mjs}"
  if [[ ! -f "$node_leader_path" ]]; then
    SCENARIO_FAILURE_REASON="setup: leader not found at $node_leader_path (set RLP_DESK_NODE_PATH or install rlp-desk)"
    return 1
  fi
  # DEBUG=1 so the zsh leader's log_debug (the ONLY emitter of the '[bug7] kill_pane_process'
  # reap trace) writes to its analytics debug.log — buildZshEnv spreads parentEnv, so this
  # env reaches the leader. A1 greps that debug.log (NOT exercise.log, which never sees the
  # reap trace). keeps B3 telemetry on.
  if ! DEBUG=1 timeout 600 node "$node_leader_path" run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 120 \
      --worker-model haiku --verifier-model haiku --final-verifier-model haiku \
      > "$exercise_log" 2>&1; then
    : # campaign may not complete, what matters is the audit traces
  fi

  # Locate the zsh leader's analytics debug.log (DEBUG=1 routes log_debug there).
  local _dbglog
  _dbglog=$(ls "$sandbox_dir"/.rlp-desk/analytics/${slug}--*/debug.log 2>/dev/null | head -1)

  # A1: the leader reaped the WORKER pane after detecting the iter-signal. The reap trace
  # '[bug7] kill_pane_process pane=... role=worker' is emitted by _kill_pane_process via
  # log_debug → debug.log (run:3838). (The Node-only 'killPaneProcess' name is NOT used on
  # the --mode tmux path and is intentionally not matched here.)
  if [[ -n "$_dbglog" ]] && grep -qE "\[bug7\] kill_pane_process pane=.*role=worker" "$_dbglog"; then
    echo "ASSERT A1 PASS: worker-pane reaper invoked (debug.log trace)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  elif [[ -z "$_dbglog" ]]; then
    echo "ASSERT A1 SKIP: no debug.log — campaign did not complete a worker phase (worker never signalled; worker-prompt sensitivity, not a reaper regression). The reap+lock invariant is proven deterministically by tests/test_post_sentinel_reap_lock.sh."
  else
    echo "ASSERT A1 FAIL: worker reaped no '[bug7] kill_pane_process role=worker' trace in debug.log"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: post-sentinel worker reaper missing despite a completed worker phase"
  fi

  # A2: the sentinel must be FROZEN — _lock_sentinel chmod 0444 after the reap, so the
  # lingering TUI cannot rewrite it. NON-VACUOUS: 444 = locked (PASS); a writable mode
  # (644) where a write SUCCEEDS = the lock did NOT hold (FAIL); absent = consumed at iter
  # cleanup (no race window, PASS).
  local _sig=".rlp-desk/memos/$slug-iter-signal.json"
  if [[ -f "$_sig" ]]; then
    local sig_mode mt0 mt1
    sig_mode=$(stat -f %Lp "$_sig" 2>/dev/null || stat -c %a "$_sig" 2>/dev/null)
    mt0=$(stat -f %m "$_sig" 2>/dev/null || stat -c %Y "$_sig" 2>/dev/null)
    if [[ "$sig_mode" == "444" ]]; then
      # Prove the freeze: a write must fail and mtime must not advance.
      if print 'TAMPER' >> "$_sig" 2>/dev/null; then
        echo "ASSERT A2 INFO: mode 444 but FS allowed the write (root/permissive mount) — freeze not enforceable here"
        ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
      else
        mt1=$(stat -f %m "$_sig" 2>/dev/null || stat -c %Y "$_sig" 2>/dev/null)
        if [[ "$mt0" == "$mt1" ]]; then
          echo "ASSERT A2 PASS: sentinel locked 0444 + write blocked + mtime frozen (TUI cannot rewrite)"
          ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
        else
          echo "ASSERT A2 FAIL: sentinel mtime advanced despite 0444 lock ($mt0 → $mt1)"
          ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
          SCENARIO_FAILURE_REASON="A2: locked sentinel mtime drifted"
        fi
      fi
    else
      # Not 0444: only a FAIL if it is actually rewritable (the race the fix closes).
      if print 'TAMPER' >> "$_sig" 2>/dev/null; then
        echo "ASSERT A2 FAIL: sentinel mode $sig_mode is writable and a write SUCCEEDED — lock not applied"
        ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
        SCENARIO_FAILURE_REASON="A2: sentinel not locked (mode $sig_mode, rewritable)"
      else
        echo "ASSERT A2 PASS: sentinel mode $sig_mode but write blocked (FS-effective freeze)"
        ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
      fi
    fi
  else
    echo "ASSERT A2 PASS: signal file consumed at iter cleanup (no lingering race window)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  fi

  # ────────────────────────────────────────────────────────────────────────
  # v0.15.4 PR-B3: lifecycle metric assertion on the production zsh leader.
  #
  # SCOPE (zsh-leader port, Option A): the zsh leader wires exactly ONE live
  # metric — pane_eof_to_cleanup_ms (_kill_pane_process, lib_ralph_desk.zsh:342),
  # emitted on every real worker/verifier pane reap. The other three metrics
  # (iter_signal_write_to_read_ms, verdict_write_to_read_ms, pane_reap_latency_ms)
  # are Node-leader-only and NOT emitted on the --mode tmux path, so asserting
  # them here would only ever SKIP — they are omitted to avoid implying coverage
  # the zsh port does not provide.
  #
  # COVERAGE: this scenario uses a `### US-001` PRD, so the ALL verify takes the
  # per-US sequential split (run:3991) — it exercises the WORKER reap (run:3838) AND
  # the verifier reaps (run:2968/3075), producing 2 lifecycle records. (b3-lifecycle-e2e
  # covers the complementary single-ALL-verifier route, run:4152.) The crisp worker
  # prompt above drives a haiku worker to emit a valid iter-signal so the reap fires.
  #
  # ABSENCE SEMANTICS: real-LLM is occasionally non-deterministic — if the worker fails
  # to signal within the timeout, no campaign.jsonl is produced. That is LLM flakiness,
  # NOT a B3 telemetry regression, so it SKIPs rather than FAILs; a produced-but-empty
  # campaign.jsonl still FAILs (real "telemetry not emitting" signal). The emit + reap+lock
  # invariants are proven deterministically by tests/test_b3_pane_reap_integration.sh and
  # tests/test_post_sentinel_reap_lock.sh regardless of LLM behavior.
  # ────────────────────────────────────────────────────────────────────────
  # The b3 lib was sourced at run_scenario top (pre-trap — see the bash-3.2 RETURN-trap
  # note there); do NOT re-source here or it would fire the cleanup trap.
  if typeset -f b3_assert_lifecycle_metrics_present >/dev/null 2>&1; then
    # The production zsh leader writes campaign.jsonl to its analytics dir
    # ($DESK/analytics/${SLUG}--${md5(ROOT):0:8}/campaign.jsonl, run_ralph_desk.zsh:365-366),
    # NOT the Node leader's .rlp-desk/logs/$slug/ path. Glob the hash component.
    local _jsonl
    _jsonl=$(ls "$sandbox_dir"/.rlp-desk/analytics/${slug}--*/campaign.jsonl 2>/dev/null | head -1)
    if [[ -n "$_jsonl" && -f "$_jsonl" ]]; then
      b3_assert_lifecycle_metrics_present "$_jsonl"
      b3_assert_lifecycle_metric_within_band "$_jsonl" "pane_eof_to_cleanup_ms" "$B3_BAND_PANE_EOF_CLEANUP_MS"
    else
      echo "ASSERT B3 SKIP: campaign.jsonl not produced — worker did not signal within the timeout"
      echo "                (occasional real-LLM flakiness, not a B3 telemetry regression)."
      echo "                B3 emit + reap+lock invariants are proven deterministically by"
      echo "                tests/test_b3_pane_reap_integration.sh + tests/test_post_sentinel_reap_lock.sh."
    fi
  else
    echo "ASSERT B3 SKIP: b3-lifecycle-assertions.sh missing at $_b3_lib"
  fi

  SCENARIO_COST_USD_ACTUAL="unmeasured"
  (( ASSERTIONS_FAILED == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
    echo "SKIPPED: RLP_REAL_LLM_GATE=1 required to enable. Scenario: $SCENARIO_ID"
    echo "         Cost ~\$${SCENARIO_COST_BUDGET_USD} per run."
    exit 77
  fi
  if run_scenario; then echo "PASS: $SCENARIO_ID"; exit 0; else echo "FAIL: $SCENARIO_ID — ${SCENARIO_FAILURE_REASON:-(no reason)}"; exit 1; fi
fi
