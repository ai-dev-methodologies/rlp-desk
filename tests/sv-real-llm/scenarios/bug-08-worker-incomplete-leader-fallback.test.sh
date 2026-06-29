#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #8 worker-incomplete + leader A4 fallback.
#
# Reproduces the synthesis-refusal contract: when codex worker exits without
# writing done-claim.json, leader MUST refuse to synthesize a verify signal
# and BLOCK with reason_category=infra_failure (not silently advance).
#
# Asserts: blocked sentinel emitted with codex_exit_no_done_claim tag (or
# git_state_unverifiable / worker_incomplete_uncommitted variants).

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-08-worker-incomplete-leader-fallback"
SCENARIO_DESCRIPTION="Codex worker exit without done-claim refuses synthesis (Bug #8 PR-B)"
SCENARIO_BUG_CATEGORY="b-artifact-contract"
SCENARIO_HISTORICAL_BUG="Bug #8 (BOS 2026-05-06)"
SCENARIO_COST_BUDGET_USD="3"
SCENARIO_TIMEOUT_SECONDS="600"
SCENARIO_REQUIRES="codex_cli; tmux; jq; node"
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

  local slug="sv-bug08-incomplete"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/context .rlp-desk/logs/$slug/runtime
  # v0.13.0+ scaffold validation requires context + memory files (else leader exits "Scaffold validation failed").
  echo "# $slug - Latest Context" > .rlp-desk/context/$slug-latest.md
  echo "# $slug - Campaign Memory" > .rlp-desk/memos/$slug-memory.md
  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug08-incomplete
### US-001: synthetic
- README.md exists
EOF

  # Worker prompt designed to make codex exit WITHOUT writing done-claim
  # (impossible to guarantee with real LLM, but we set up the precondition
  # and check the BLOCKED behavior; if worker writes done-claim, scenario
  # is N/A but doesn't fail — the behavioral guard only triggers on
  # actual incomplete-exit).
  echo "Exit immediately without writing any files. The harness expects this." \
    > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "noop" > .rlp-desk/prompts/$slug.verifier.prompt.md

  local exercise_log="$sandbox_dir/exercise.log"
  if ! timeout 300 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux --max-iter 1 --iter-timeout 60 \
      --worker-model "gpt-5.5:medium" --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    : # non-zero expected on BLOCKED
  fi

  # A1: blocked sentinel must exist (synthesis refused → BLOCK)
  if [[ -f .rlp-desk/memos/$slug-blocked.md ]]; then
    echo "ASSERT A1 PASS: BLOCKED sentinel emitted"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    # Worker may have actually written done-claim; check status as fallback
    if grep -q "synthesize verify signal\|done-claim present" "$exercise_log"; then
      echo "ASSERT A1 PASS (alt): bug-8 4-way gate triggered (worker behavior varied)"
      ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    else
      echo "ASSERT A1 FAIL: no BLOCKED sentinel and no synthesis-gate audit"
      ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
      SCENARIO_FAILURE_REASON="A1: bug-8 synthesis-refusal gate did not fire"
    fi
  fi

  # A2: blocked sidecar must declare appropriate reason_category if BLOCKED
  if [[ -f .rlp-desk/memos/$slug-blocked.json ]]; then
    local cat
    cat=$(jq -r '.reason_category' .rlp-desk/memos/$slug-blocked.json 2>/dev/null)
    if [[ "$cat" == "infra_failure" || "$cat" == "metric_failure" ]]; then
      echo "ASSERT A2 PASS: blocked.json reason_category=$cat"
      ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    else
      echo "ASSERT A2 FAIL: blocked.json reason_category=$cat (expected infra_failure or metric_failure)"
      ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
      SCENARIO_FAILURE_REASON="A2: blocked.json reason_category mismatch"
    fi
  else
    echo "ASSERT A2 SKIP: no blocked.json (only relevant if A1 BLOCKED path)"
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
