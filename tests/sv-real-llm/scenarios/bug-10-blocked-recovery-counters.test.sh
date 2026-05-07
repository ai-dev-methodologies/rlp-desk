#!/usr/bin/env bash
# Real-LLM SV gate scenario: PR-E (Phase C1) operator-cleared BLOCKED recovery.
#
# Reproduces the recovery flow PR-E (#10 + #11) fixes:
# 1. Campaign reaches BLOCKED with consecutive_failures=3, consecutive_blocks=1
# 2. Sidecar `<slug>-blocked.json` shows recoverable=true (e.g. metric_failure)
# 3. Operator manually deletes <slug>-blocked.md
# 4. Leader relaunches → MUST detect operator-cleared recovery, reset counters
#    to 0, archive sidecar to .recovered-<iso>, audit log line emitted.
#
# Asserts on final state after relaunch (no real worker needed — counters
# reset happens at leader entry, before any dispatch).

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-10-blocked-recovery-counters"
SCENARIO_DESCRIPTION="Operator-cleared BLOCKED counters reset on relaunch (PR-E)"
SCENARIO_BUG_CATEGORY="d-recovery-hygiene"
SCENARIO_HISTORICAL_BUG="PR-E (Phase C1)"
SCENARIO_COST_BUDGET_USD="2"
SCENARIO_TIMEOUT_SECONDS="600"
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

  local slug="sv-bug10-blocked"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/logs/$slug/runtime

  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug10-blocked
## US-001: trivial pass
- README.md exists
EOF
  echo "noop" > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "noop" > .rlp-desk/prompts/$slug.verifier.prompt.md

  # Seed: phase=blocked, sentinel ABSENT (operator cleared), sidecar present
  # with recoverable=true, counters non-zero.
  cat > .rlp-desk/memos/$slug-blocked.json <<EOF
{
  "schema_version": "2.0",
  "slug": "$slug",
  "us_id": "US-001",
  "blocked_at_iter": 3,
  "blocked_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reason_category": "metric_failure",
  "reason_detail": "synthetic block for sv scenario",
  "failure_category": null,
  "recoverable": true,
  "suggested_action": "retry_after_fix",
  "meta": {"blocked_hygiene_violated": false}
}
EOF

  cat > .rlp-desk/logs/$slug/runtime/status.json <<EOF
{
  "phase": "blocked",
  "iteration": 3,
  "max_iterations": 5,
  "worker_model": "haiku",
  "verifier_model": "haiku",
  "final_verifier_model": "haiku",
  "verified_us": [],
  "consecutive_failures": 3,
  "consecutive_blocks": 1,
  "last_block_reason": "metric_failure",
  "current_us": "US-001",
  "session_name": null,
  "leader_pane_id": null,
  "worker_pane_id": null,
  "verifier_pane_id": null,
  "flywheel_guard_count": {},
  "started_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  local exercise_log="$sandbox_dir/exercise.log"
  if ! timeout 300 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 60 \
      --worker-model haiku --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    # Non-zero is acceptable; what matters is the recovery branch fired
    :
  fi

  # A1: audit log line "[recovery] Operator-cleared BLOCKED detected"
  if grep -q "\[recovery\] Operator-cleared BLOCKED detected" "$exercise_log"; then
    echo "ASSERT A1 PASS: PR-E recovery audit line emitted"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: PR-E recovery audit line missing in log"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: PR-E recovery branch did not fire"
  fi

  # A2: sidecar archived (renamed to .recovered-<iso>)
  local archived
  archived=$(ls -1 .rlp-desk/memos/$slug-blocked.json.recovered-* 2>/dev/null | head -1)
  if [[ -n "$archived" ]]; then
    echo "ASSERT A2 PASS: sidecar archived to $(basename "$archived")"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: sidecar not archived"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: sidecar audit archive missing"
  fi

  # A3: counters reset in status.json (read post-relaunch)
  local fails_after blocks_after
  fails_after=$(jq -r '.consecutive_failures' .rlp-desk/logs/$slug/runtime/status.json 2>/dev/null)
  blocks_after=$(jq -r '.consecutive_blocks' .rlp-desk/logs/$slug/runtime/status.json 2>/dev/null)
  if [[ "$fails_after" == "0" && "$blocks_after" == "0" ]]; then
    echo "ASSERT A3 PASS: counters reset (failures=$fails_after, blocks=$blocks_after)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 FAIL: counters not reset (failures=$fails_after, blocks=$blocks_after)"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A3: counters not reset post-recovery"
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
