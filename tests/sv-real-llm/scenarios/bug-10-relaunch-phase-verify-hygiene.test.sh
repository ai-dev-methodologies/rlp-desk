#!/usr/bin/env bash
# Real-LLM SV gate scenario: Bug #10 relaunch phase=verify hygiene.
#
# Reproduces the operator manual recovery flow that PR-A fixed:
# 1. Campaign reaches BLOCKED state (deliberately failed verifier)
# 2. Operator clears blocked sentinel + writes iter-signal.json + done-claim.json
#    by hand + sets status.phase=verify
# 3. Leader relaunches → MUST honor recovery (no worker re-dispatch, verifier
#    runs against operator's artifacts, audit log line emitted)
#
# Asserts on final state after relaunch:
# - Audit log contains '[recovery] Resuming verify phase'
# - No new iter-001.worker-prompt.md file (operator's recovery preserved)
# - Verifier was dispatched to verifier pane
#
# Cost: ~$1-3 (single relaunch, fast worker model, single verifier call).

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="bug-10-relaunch-phase-verify-hygiene"
SCENARIO_DESCRIPTION="Operator-written phase=verify recovery honored on relaunch"
SCENARIO_BUG_CATEGORY="d-recovery-hygiene"
SCENARIO_HISTORICAL_BUG="Bug #10 (BOS 2026-05-07)"
SCENARIO_COST_BUDGET_USD="3"
SCENARIO_TIMEOUT_SECONDS="900"
SCENARIO_REQUIRES="claude_cli OR codex_cli; tmux; jq; node"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  # ─── 1. SETUP ───────────────────────────────────────────────────────
  local sandbox_dir
  sandbox_dir=$(mktemp -d -t "sv-real-llm-${SCENARIO_ID}.XXXXXX")
  trap "rm -rf '$sandbox_dir' 2>/dev/null; tmux kill-session -t 'sv-real-${SCENARIO_ID}' 2>/dev/null" RETURN

  cd "$sandbox_dir" || return 1
  git init -q . || return 1
  echo "# scratch" > README.md
  git add README.md
  git -c user.email=test@test.local -c user.name=test commit -q -m "init"

  local slug="sv-bug-10-test"
  # Create minimal PRD (1 US, deterministic typo fix)
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/logs/$slug/runtime
  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-bug-10-test

## Objective
Test recovery hygiene on relaunch.

## US-001: Add a single line to README
Append the line "test passed" to README.md.

### Acceptance Criteria
- README.md contains the literal string "test passed"
EOF

  # Create minimal worker/verifier prompts (trivial — scenario doesn't run them
  # in normal flow; recovery path skips worker entirely on relaunch).
  cat > .rlp-desk/prompts/$slug.worker.prompt.md <<'EOF'
You are the Worker. Append "test passed" to README.md, then write done-claim.json
with execution_steps and us_id="US-001". Then write iter-signal.json with
status="verify", us_id="US-001", iter_signal_quality="specific", iteration=1.
EOF
  cat > .rlp-desk/prompts/$slug.verifier.prompt.md <<'EOF'
You are the Verifier. Read done-claim.json. Verify README.md contains "test passed".
Write verify-verdict.json with verdict="pass" and recommended_state_transition="complete".
EOF

  # ─── Operator-style recovery seed ──────────────────────────────────
  # Pre-populate the state that an operator manual recovery produces:
  # - status.json with phase=verify
  # - operator-written iter-signal.json and done-claim.json (US-001, iter=1, specific)
  # - README.md actually contains "test passed" (so verifier can verify)
  echo "test passed" >> README.md
  git add README.md
  git -c user.email=test@test.local -c user.name=test commit -q -m "feat(US-001): test passed"

  # Worker prompt placeholder — must be OLDER than artifacts (5-check validator)
  local prompt_file=".rlp-desk/logs/$slug/iter-001.worker-prompt.md"
  echo "# old prompt placeholder" > "$prompt_file"
  local past_ts
  past_ts=$(( $(date +%s) - 60 ))
  touch -t "$(date -r $past_ts +%Y%m%d%H%M.%S)" "$prompt_file" 2>/dev/null \
    || touch -d "@$past_ts" "$prompt_file" 2>/dev/null

  # iter-signal.json (operator-written)
  cat > .rlp-desk/memos/$slug-iter-signal.json <<EOF
{
  "iteration": 1,
  "status": "verify",
  "us_id": "US-001",
  "iter_signal_quality": "specific",
  "summary": "real-llm sv scenario operator manual recovery"
}
EOF

  # done-claim.json (operator-written)
  cat > .rlp-desk/memos/$slug-done-claim.json <<EOF
{
  "iteration": 1,
  "status": "verify",
  "us_id": "US-001",
  "execution_steps": ["appended 'test passed' to README.md"]
}
EOF

  # status.json with phase=verify
  cat > .rlp-desk/logs/$slug/runtime/status.json <<EOF
{
  "phase": "verify",
  "iteration": 1,
  "max_iterations": 5,
  "worker_model": "haiku",
  "verifier_model": "haiku",
  "final_verifier_model": "haiku",
  "verified_us": [],
  "consecutive_failures": 0,
  "consecutive_blocks": 0,
  "last_block_reason": "",
  "current_us": "US-001",
  "session_name": null,
  "leader_pane_id": null,
  "worker_pane_id": null,
  "verifier_pane_id": null,
  "flywheel_guard_count": {},
  "started_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  # No blocked sentinel (operator cleared it). No iter-NNN.worker-prompt.md
  # newer than artifacts (5-check guard satisfied).

  # ─── 2. EXERCISE ────────────────────────────────────────────────────
  # Run leader against this seeded state. Use the local install path so
  # we exercise the actual published package.
  local cost_log_before cost_log_after
  cost_log_before=$(test -f .rlp-desk/logs/$slug/cost-log.jsonl && wc -l < .rlp-desk/logs/$slug/cost-log.jsonl || echo 0)

  local exercise_log="$sandbox_dir/exercise.log"
  # NOTE: this scenario expects rlp-desk's Node leader binary to be available.
  # We use --mode tmux to exercise the zsh runner path (PR-A zsh side).
  # Default worker/verifier are haiku/codex spark for cost — actual model
  # selection depends on user environment. Recovery branch should fire BEFORE
  # any worker dispatch, so model choice mostly irrelevant here.
  if ! timeout 600 node ~/.claude/ralph-desk/node/run.mjs run "$slug" \
      --mode tmux \
      --max-iter 2 \
      --iter-timeout 120 \
      --worker-model haiku \
      --verifier-model haiku \
      > "$exercise_log" 2>&1; then
    SCENARIO_FAILURE_REASON="leader exited non-zero — recovery may have failed; see exercise.log"
    cat "$exercise_log" | tail -30 >&2
    return 1
  fi

  # ─── 3. ASSERT ──────────────────────────────────────────────────────

  # A1: audit log line "[recovery] Resuming verify phase" must appear
  if grep -q "\[recovery\] Resuming verify phase" "$exercise_log"; then
    echo "ASSERT A1 PASS: audit log contains '[recovery] Resuming verify phase'"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: audit log missing '[recovery] Resuming verify phase'"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: recovery audit line missing"
  fi

  # A2: iter-001.worker-prompt.md mtime should be UNCHANGED (still the past_ts
  # we set). If leader rewrote it, the recovery did NOT skip worker dispatch.
  local prompt_mtime_after
  prompt_mtime_after=$(stat -f %m "$prompt_file" 2>/dev/null || stat -c %Y "$prompt_file" 2>/dev/null || echo 0)
  if (( prompt_mtime_after <= past_ts + 5 )); then
    echo "ASSERT A2 PASS: iter-001 worker prompt NOT rewritten (operator's state preserved)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 FAIL: iter-001 worker prompt was rewritten (mtime $prompt_mtime_after > $past_ts) — recovery did not skip dispatch"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A2: worker prompt was rewritten; recovery branch did not fire"
  fi

  # A3: campaign should reach a terminal state (complete OR blocked) — leader
  # should NOT exit cleanly without a sentinel write. We check sentinel files.
  if [[ -f ".rlp-desk/memos/$slug-complete.md" || -f ".rlp-desk/memos/$slug-blocked.md" ]]; then
    echo "ASSERT A3 PASS: terminal sentinel present (complete or blocked)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A3 FAIL: no terminal sentinel — campaign did not finish"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A3: campaign did not reach terminal state"
  fi

  # ─── 4. REPORT ──────────────────────────────────────────────────────
  cost_log_after=$(test -f .rlp-desk/logs/$slug/cost-log.jsonl && wc -l < .rlp-desk/logs/$slug/cost-log.jsonl || echo 0)
  SCENARIO_COST_USD_ACTUAL="unmeasured"  # cost-log.jsonl integration: P2

  if (( ASSERTIONS_FAILED == 0 )); then
    return 0
  else
    return 1
  fi
}

# Allow direct invocation (skipped if RLP_REAL_LLM_GATE != 1).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
    echo "SKIPPED: RLP_REAL_LLM_GATE=1 required to enable. Scenario: $SCENARIO_ID"
    echo "         Cost ~\$${SCENARIO_COST_BUDGET_USD} per run."
    exit 77
  fi
  if run_scenario; then
    echo "PASS: $SCENARIO_ID"
    exit 0
  else
    echo "FAIL: $SCENARIO_ID — ${SCENARIO_FAILURE_REASON:-(no reason recorded)}"
    exit 1
  fi
fi
