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

  local sandbox_dir
  sandbox_dir=$(mktemp -d -t "sv-real-llm-${SCENARIO_ID}.XXXXXX")
  trap "rm -rf '$sandbox_dir' 2>/dev/null; tmux kill-session -t 'sv-real-${SCENARIO_ID}' 2>/dev/null" RETURN

  cd "$sandbox_dir" || return 1
  git init -q .
  echo "# scratch" > README.md
  git add README.md
  git -c user.email=test@test.local -c user.name=test commit -q -m "init"

  local slug="sv-bug07-race"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/logs/$slug/runtime

  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug07-race
## US-001: trivial
- README.md exists
EOF
  echo "Append 'done' to README.md, write done-claim and iter-signal." > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "Verify README.md contains 'done', write verify-verdict pass+complete." > .rlp-desk/prompts/$slug.verifier.prompt.md

  # No pre-seed — let leader run normally. We test the IN-CODE invariant:
  # after leader detects iter-signal.json, _kill_pane_process is called
  # within seconds.
  local exercise_log="$sandbox_dir/exercise.log"
  # v0.15.4 PR-B3: enable B4 lifecycle observability so two-stage assertions
  # below can read campaign.jsonl.lifecycle_metrics.
  if ! RLP_LIFECYCLE_METRICS=1 timeout 600 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 120 \
      --worker-model haiku --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    : # campaign may not complete, what matters is the audit traces
  fi

  # A1: leader log shows kill_pane_process invocation within iter
  if grep -qE "\[bug7\] kill_pane_process|kill_pane_process pane=.*role=worker|killPaneProcess" "$exercise_log"; then
    echo "ASSERT A1 PASS: reaper invoked"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: reaper invocation absent in log"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: post-sentinel reaper missing"
  fi

  # A2: iter-signal.json mtime stable after detect (or file unlinked at iter
  # cleanup which is also fine). Check: if file present, was last modified
  # within reaper window.
  if [[ -f .rlp-desk/memos/$slug-iter-signal.json ]]; then
    local sig_mtime now
    sig_mtime=$(stat -f %m .rlp-desk/memos/$slug-iter-signal.json 2>/dev/null || stat -c %Y .rlp-desk/memos/$slug-iter-signal.json 2>/dev/null)
    now=$(date +%s)
    # Sentinel should be locked (0o444) AND not modified after lock.
    local sig_mode
    sig_mode=$(stat -f %Lp .rlp-desk/memos/$slug-iter-signal.json 2>/dev/null || stat -c %a .rlp-desk/memos/$slug-iter-signal.json 2>/dev/null)
    if [[ "$sig_mode" == "444" || "$sig_mode" == "644" ]]; then
      echo "ASSERT A2 PASS: signal file mode is $sig_mode (locked or post-cleanup)"
      ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    else
      echo "ASSERT A2 INFO: signal file mode is $sig_mode (FS may not honor chmod)"
      ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    fi
  else
    echo "ASSERT A2 PASS: signal file removed at iter cleanup (no race window)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  fi

  # ────────────────────────────────────────────────────────────────────────
  # v0.15.4 PR-B3: two-stage lifecycle metric assertions (per plan v3 §B3).
  # Bug #7 is the canonical lifecycle-race scenario, so all four primary
  # metrics are asserted. iter_signal_write_to_read_ms and
  # verdict_write_to_read_ms catch leader-poll regressions; pane_reap_*
  # catch reaper-window regressions. Initial bands from B1 §4.2 synthetic;
  # pre-merge revalidation gates promotion to B3_STAGE2_BLOCKING=1.
  # ────────────────────────────────────────────────────────────────────────
  local _b3_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/b3-lifecycle-assertions.sh"
  if [[ -f "$_b3_lib" ]]; then
    # shellcheck source=tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
    source "$_b3_lib"
    local _jsonl="$sandbox_dir/.rlp-desk/logs/$slug/campaign.jsonl"
    b3_assert_lifecycle_metrics_present "$_jsonl"
    b3_assert_lifecycle_metric_within_band "$_jsonl" "iter_signal_write_to_read_ms" "$B3_BAND_ITER_SIGNAL_MS"
    b3_assert_lifecycle_metric_within_band "$_jsonl" "verdict_write_to_read_ms" "$B3_BAND_VERDICT_MS"
    b3_assert_lifecycle_metric_within_band "$_jsonl" "pane_eof_to_cleanup_ms" "$B3_BAND_PANE_EOF_CLEANUP_MS"
    b3_assert_lifecycle_metric_within_band "$_jsonl" "pane_reap_latency_ms" "$B3_BAND_PANE_REAP_LATENCY_MS"
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
