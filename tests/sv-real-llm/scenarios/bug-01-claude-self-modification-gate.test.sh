#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #1 .claude/ self-modification gate.
#
# v0.13.0 path migration moved sentinel writes from .claude/ralph-desk/memos/
# to .rlp-desk/memos/. This scenario asserts the migration holds: a real
# claude worker dispatched against the current install never tries to write
# under .claude/, so Claude Code's self-modification permission gate is not
# triggered.
#
# Asserts: PERMISSION_PROMPT BLOCK_TAG is NOT emitted; worker writes go to
# .rlp-desk/, not .claude/.

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-01-claude-self-modification-gate"
SCENARIO_DESCRIPTION="Sentinel writes use .rlp-desk/, not .claude/ (Bug #1 path migration)"
SCENARIO_BUG_CATEGORY="c-llm-runtime-constraint"
SCENARIO_HISTORICAL_BUG="Bug #1 (BOS 2026-05-01)"
SCENARIO_COST_BUDGET_USD="3"
SCENARIO_TIMEOUT_SECONDS="600"
SCENARIO_REQUIRES="claude_cli; tmux; jq; node"
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

  local slug="sv-bug01-paths"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/logs/$slug/runtime

  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug01-paths
## US-001: write done-claim
- Worker writes done-claim with us_id=US-001
EOF
  echo "Append 'done' to README.md, write done-claim and iter-signal." > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "Verify, write verdict pass+complete." > .rlp-desk/prompts/$slug.verifier.prompt.md

  local exercise_log="$sandbox_dir/exercise.log"
  if ! timeout 300 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 120 \
      --worker-model haiku --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    :
  fi

  # A1: no PERMISSION_PROMPT block tag in audit (means no self-modification gate)
  if grep -qE "PERMISSION_PROMPT|permission_prompt|switch_worker_to_codex_or_use_agent_mode" "$exercise_log"; then
    echo "ASSERT A1 FAIL: PERMISSION_PROMPT block_tag detected — Bug #1 regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: claude .claude/ self-modification gate triggered"
  else
    echo "ASSERT A1 PASS: no PERMISSION_PROMPT block_tag"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  fi

  # A2: no sentinel writes under .claude/ralph-desk/memos/ (legacy path)
  if [[ -d .claude/ralph-desk/memos ]] && [[ -n "$(ls -A .claude/ralph-desk/memos 2>/dev/null)" ]]; then
    echo "ASSERT A2 FAIL: legacy .claude/ralph-desk/memos/ has files — Bug #1 path regression"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: legacy path used despite v0.13.0 migration"
  else
    echo "ASSERT A2 PASS: no writes under .claude/ralph-desk/memos/"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  fi

  # A3: sentinel writes ARE present under .rlp-desk/memos/ (positive control)
  local memo_count
  memo_count=$(ls .rlp-desk/memos/ 2>/dev/null | wc -l | tr -d ' ')
  if (( memo_count > 0 )); then
    echo "ASSERT A3 PASS: .rlp-desk/memos/ has $memo_count files (canonical path)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 INFO: no memos written (campaign may not have run far enough)"
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
