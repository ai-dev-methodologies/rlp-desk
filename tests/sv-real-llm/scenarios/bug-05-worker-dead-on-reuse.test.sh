#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #5 worker dead on reuse.
#
# Reproduces the dead-pane recovery: at iter-N+1 entry, R12 lifecycle
# monitor (_r12_check_lifecycle) detects dead WORKER_PANE within 5s budget
# and either replaces the pane OR writes BLOCKED with infra_failure (no
# silent advance into a dead pane).
#
# Asserts: dead pane → either BLOCKED sentinel with infra_failure OR pane
# replaced + worker dispatched fresh.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-05-worker-dead-on-reuse"
SCENARIO_DESCRIPTION="Dead worker pane detected at iter entry (R12 lifecycle)"
SCENARIO_BUG_CATEGORY="a-tmux-process-lifecycle"
SCENARIO_HISTORICAL_BUG="Bug #5 (BOS 2026-05-05)"
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

  local slug="sv-bug05-dead-pane"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/logs/$slug/runtime

  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug05-dead-pane
## US-001: synthetic
- README.md exists
EOF
  echo "Append 'done' then write done-claim + iter-signal." > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "Verify, write verdict pass+complete." > .rlp-desk/prompts/$slug.verifier.prompt.md

  # Pre-seed status with stale pane IDs that don't exist (simulating dead pane).
  cat > .rlp-desk/logs/$slug/runtime/status.json <<EOF
{
  "phase": "worker",
  "iteration": 2,
  "max_iterations": 3,
  "worker_model": "haiku",
  "verifier_model": "haiku",
  "final_verifier_model": "haiku",
  "verified_us": [],
  "consecutive_failures": 0,
  "consecutive_blocks": 0,
  "last_block_reason": "",
  "current_us": "US-001",
  "session_name": "rlp-$slug-stale",
  "leader_pane_id": "%9999",
  "worker_pane_id": "%9998",
  "verifier_pane_id": "%9997",
  "flywheel_guard_count": {},
  "started_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  local exercise_log="$sandbox_dir/exercise.log"
  if ! timeout 300 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 60 \
      --worker-model haiku --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    :
  fi

  # A1: leader detected stale session and either created fresh OR BLOCKED.
  # Check for either of two acceptable outcomes:
  #   (a) Lifecycle monitor BLOCKED with infra_failure
  #   (b) Fresh session created (existing log shows session creation)
  if grep -qE "tmux session/pane dead|\[r12\]|infra_failure" "$exercise_log"; then
    echo "ASSERT A1 PASS: R12 lifecycle monitor detected dead state"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  elif grep -qE "Created session|create_session|new session" "$exercise_log"; then
    echo "ASSERT A1 PASS: leader created fresh session (stale pane IDs ignored)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: no lifecycle detection or fresh-session creation in log"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: dead-pane handling did not trigger"
  fi

  # A2: NO silent send-keys to a non-existent pane (would manifest as tmux
  # error in log)
  if grep -q "can't find pane" "$exercise_log"; then
    echo "ASSERT A2 FAIL: tmux 'can't find pane' error — worker dispatched to dead pane"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: silent dispatch into dead pane"
  else
    echo "ASSERT A2 PASS: no 'can't find pane' tmux errors"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
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
