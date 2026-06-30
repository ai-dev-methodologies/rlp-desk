#!/usr/bin/env bash
# Real-LLM SV gate scenario: B3 lifecycle telemetry END-TO-END on the zsh leader.
#
# WHY THIS SCENARIO EXISTS
# ------------------------
# The B3 emit chain (_kill_pane_process → log_lifecycle_metric → LIFECYCLE_RECORDS →
# write_campaign_jsonl → campaign.jsonl.lifecycle_metrics) is proven deterministically
# by tests/test_b3_pane_reap_integration.sh. This scenario is its REAL-LLM counterpart:
# it confirms the metric actually lands in campaign.jsonl during a LIVE campaign on the
# production `--mode tmux` (zsh) leader.
#
# DESIGN (honors the SV suite's pre-seed philosophy — no dependency on an LLM worker
# following the full done-claim/iter-signal protocol):
#   We pre-seed the operator-recovery state (status.phase=verify + iter-signal +
#   done-claim + committed work + an OLD worker-prompt placeholder), exactly like
#   bug-10-relaunch, with us_id=ALL and a PRD that has NO `### US-NNN` heading (so
#   US_LIST is empty). On relaunch the leader's PR-A recovery (run_ralph_desk.zsh:3679)
#   SKIPs the worker, detects the pre-seeded iter-signal, and — because US_LIST is empty,
#   the ALL verify is routed to the SINGLE ALL verifier (run_ralph_desk.zsh:3991 guards
#   the per-US sequential split behind `-n US_LIST`; empty → single verifier) — LAUNCHES
#   one real verifier pane. The ONLY live LLM is that verifier, and its task is
#   trivial-and-explicit: write one fixed verdict JSON to one fixed path. The leader then:
#     - reaps the verifier pane (_kill_pane_process, run:4152) → fires
#       pane_eof_to_cleanup_ms (the lone zsh-wired B3 metric, lib:372), and
#     - reads verdict=pass and (signal_us_id==ALL) → run:4260 branch →
#       write_campaign_jsonl (run:4264) → exit 0.
#   That single verify phase produces a campaign.jsonl carrying the metric. (Empty
#   US_LIST is a deliberate simplification — single ALL verifier vs the per-US sequential
#   split — but it was NOT the cause of the earlier "campaign.jsonl absent" flakiness:
#   that was a harness bug where a bash `trap ... RETURN` fired on the `source` of the B3
#   lib and `rm -rf`'d the sandbox mid-assertion. The lib is now sourced before the trap.)
#
# Asserts: recovery fired; campaign completed; campaign.jsonl carries a NON-EMPTY
# lifecycle_metrics.pane_eof_to_cleanup_ms (B3-S1) within band (B3-S2).
#
# Cost: ~$1-2 (single verifier call; worker is skipped entirely).

# ════════════════════════════════════════════════════════════════════════
SCENARIO_ID="b3-lifecycle-e2e"
SCENARIO_DESCRIPTION="B3 lifecycle metric lands in campaign.jsonl on a live zsh-leader verify phase"
SCENARIO_BUG_CATEGORY="b-lifecycle-observability"
SCENARIO_HISTORICAL_BUG="PR-B3/B4 (v0.15.4) — zsh-leader lifecycle port"
SCENARIO_COST_BUDGET_USD="2"
SCENARIO_TIMEOUT_SECONDS="600"
SCENARIO_REQUIRES="claude_cli OR codex_cli; tmux; jq; node"
# ════════════════════════════════════════════════════════════════════════

run_scenario() {
  ASSERTIONS_PASSED=0
  ASSERTIONS_FAILED=0
  SCENARIO_FAILURE_REASON=""

  # Resolve + SOURCE the B3 assertion lib to an ABSOLUTE path BEFORE cd'ing into the
  # sandbox AND BEFORE installing the cleanup trap.
  # CRITICAL (bash 3.2 gotcha): a `trap ... RETURN` fires when a `source` completes —
  # not only when the function returns. If the b3 lib were sourced AFTER the
  # `rm -rf $sandbox` RETURN trap, that source would FIRE the trap and delete the sandbox
  # (campaign.jsonl included) MID-ASSERTION, making B3-S1 spuriously report "absent".
  # Sourcing here (pre-trap) avoids it; later NESTED calls to b3_assert_* do NOT fire the
  # RETURN trap (only `source` and the real function return do).
  local _b3_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/lib/b3-lifecycle-assertions.sh"
  # shellcheck source=tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
  [[ -f "$_b3_lib" ]] && source "$_b3_lib"

  # ─── 1. SETUP ───────────────────────────────────────────────────────
  local sandbox_dir
  sandbox_dir=$(mktemp -d -t "sv-real-llm-${SCENARIO_ID}.XXXXXX")
  # RLP_SV_KEEP_SANDBOX=1 preserves the sandbox for post-mortem (debug only).
  if [[ "${RLP_SV_KEEP_SANDBOX:-0}" == "1" ]]; then
    trap "echo '[keep-sandbox] $sandbox_dir' >&2; tmux kill-session -t 'sv-real-${SCENARIO_ID}' 2>/dev/null" RETURN
  else
    trap "rm -rf '$sandbox_dir' 2>/dev/null; tmux kill-session -t 'sv-real-${SCENARIO_ID}' 2>/dev/null" RETURN
  fi

  cd "$sandbox_dir" || return 1
  git init -q . || return 1
  local slug="sv-b3-e2e"
  mkdir -p .rlp-desk/plans .rlp-desk/prompts .rlp-desk/memos .rlp-desk/context .rlp-desk/logs/$slug/runtime
  echo "# $slug - Latest Context" > .rlp-desk/context/$slug-latest.md
  echo "# $slug - Campaign Memory" > .rlp-desk/memos/$slug-memory.md
  # IMPORTANT: NO `### US-NNN` heading. US_LIST is derived by grepping `^### US-[0-9]+`
  # (run_ralph_desk.zsh:3488); leaving it EMPTY routes the ALL verify AWAY from the
  # per-US sequential-final-verify split (run_ralph_desk.zsh:3991, which re-scopes the
  # verifier prompt via _final_verify_one_us and was the source of run-to-run flakiness)
  # and TO the single ALL verifier (:4100 launch → :4152 reap → :4260 write_campaign_jsonl).
  # That single verifier uses our crisp base prompt verbatim → deterministic.
  cat > .rlp-desk/plans/prd-$slug.md <<'EOF'
# PRD: sv-b3-e2e

## Objective
Confirm B3 lifecycle telemetry on a live verify phase.

## Acceptance
- README.md contains the literal string "b3-e2e-ok"
EOF

  # Committed work that satisfies US-001 (so a verifier COULD verify it; our verifier
  # is told to pass unconditionally — the point is the pane reap, not the grading).
  echo "b3-e2e-ok" >> README.md
  git add -A
  git -c user.email=test@test.local -c user.name=test commit -q -m "feat(US-001): add b3-e2e-ok marker"

  # Worker prompt placeholder — never executed (recovery skips the worker).
  echo "# placeholder — recovery skips the worker" > .rlp-desk/prompts/$slug.worker.prompt.md

  # CRISP verifier prompt: the leader appends US scope to this base, but the protocol
  # (exact verdict path + schema) must live here. Keep the task explicit so a haiku
  # verifier reliably writes ONE file the leader can poll.
  cat > .rlp-desk/prompts/$slug.verifier.prompt.md <<EOF
You are the Verifier for a tiny synthetic campaign. Your ONLY task is to write ONE
verdict FILE — do not run tests, do not echo to stdout (the leader polls the file).

Use the Write tool to create EXACTLY this file at EXACTLY this absolute path:
  $sandbox_dir/.rlp-desk/memos/$slug-verify-verdict.json

with EXACTLY this JSON content (fill verified_at_utc with the current UTC ISO-8601 time):
{
  "verdict": "pass",
  "us_id": "ALL",
  "verified_at_utc": "2026-01-01T00:00:00Z",
  "summary": "B3 e2e: README contains b3-e2e-ok; all acceptance criteria satisfied.",
  "recommended_state_transition": "complete",
  "issues": [],
  "evidence_paths": ["README.md"]
}

Write the file, then stop. Do nothing else.
EOF

  # ─── Operator-recovery seed (mirrors bug-10-relaunch; us_id=ALL so a single
  #     verify phase reaches write_campaign_jsonl at run:4260-4264) ──────────
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > .rlp-desk/memos/$slug-iter-signal.json <<EOF
{
  "iteration": 1,
  "status": "verify",
  "us_id": "ALL",
  "iter_signal_quality": "specific",
  "summary": "operator recovery: US-001 implemented (b3-e2e-ok), requesting final verify"
}
EOF
  cat > .rlp-desk/memos/$slug-done-claim.json <<EOF
{
  "iteration": 1,
  "status": "verify",
  "us_id": "ALL",
  "execution_steps": [
    {"step": "implement", "ac_id": "AC1", "command": null, "exit_code": 0, "summary": "appended b3-e2e-ok to README.md"},
    {"step": "commit", "ac_id": "AC1", "command": "git commit", "exit_code": 0, "summary": "committed marker"}
  ]
}
EOF
  cat > .rlp-desk/logs/$slug/runtime/status.json <<EOF
{
  "phase": "verify",
  "iteration": 1,
  "max_iterations": 2,
  "worker_model": "haiku",
  "verifier_model": "haiku",
  "final_verifier_model": "haiku",
  "verified_us": [],
  "consecutive_failures": 0,
  "consecutive_blocks": 0,
  "last_block_reason": "",
  "current_us": "ALL",
  "session_name": null,
  "leader_pane_id": null,
  "worker_pane_id": null,
  "verifier_pane_id": null,
  "flywheel_guard_count": {},
  "started_at_utc": "$now_iso"
}
EOF
  # iter-001.worker-prompt.md must be OLDER than the artifacts (PR-A 5-check validator).
  local prompt_file=".rlp-desk/logs/$slug/iter-001.worker-prompt.md"
  echo "# old prompt placeholder" > "$prompt_file"
  local past_ts=$(( $(date +%s) - 120 ))
  touch -t "$(date -r $past_ts +%Y%m%d%H%M.%S 2>/dev/null)" "$prompt_file" 2>/dev/null \
    || touch -d "@$past_ts" "$prompt_file" 2>/dev/null

  # ─── 2. EXERCISE ────────────────────────────────────────────────────
  local exercise_log="$sandbox_dir/exercise.log"
  # v0.15.4 audit C2: RLP_DESK_NODE_PATH override → source-tree leader (pre-merge);
  # defaults to the installed leader otherwise. RLP_LIFECYCLE_METRICS=1 turns on B4.
  local node_leader_path="${RLP_DESK_NODE_PATH:-$HOME/.claude/ralph-desk/node/run.mjs}"
  if [[ ! -f "$node_leader_path" ]]; then
    SCENARIO_FAILURE_REASON="setup: leader not found at $node_leader_path (set RLP_DESK_NODE_PATH or install rlp-desk)"
    return 1
  fi
  # signal_us_id=ALL routes the verify through FINAL_VERIFIER_MODEL (not VERIFIER_MODEL),
  # so --final-verifier-model haiku is REQUIRED — without it the only live verifier runs on
  # the default (opus), making the nightly slow/expensive (codex P2).
  RLP_LIFECYCLE_METRICS=1 timeout 300 node "$node_leader_path" run "$slug" \
      --mode tmux --max-iter 2 --iter-timeout 120 \
      --worker-model haiku --verifier-model haiku --final-verifier-model haiku \
      > "$exercise_log" 2>&1 || true

  # ─── 3. ASSERT ──────────────────────────────────────────────────────
  # A1: PR-A recovery fired (worker skipped, verify phase resumed).
  if grep -q "\[recovery\] Resuming verify phase" "$exercise_log"; then
    echo "ASSERT A1 PASS: recovery resumed the verify phase (worker skipped)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A1 FAIL: recovery audit line absent — leader did not enter the verify path"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="A1: recovery did not fire (see exercise.log)"
  fi

  # A2: campaign reached a terminal complete sentinel (the verify pass path ran).
  if [[ -f ".rlp-desk/memos/$slug-complete.md" ]]; then
    echo "ASSERT A2 PASS: complete sentinel written (verify pass → write_campaign_jsonl path)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  else
    echo "ASSERT A2 INFO: no complete sentinel (verifier may not have passed); B3 below is the real check"
  fi

  # ─── B3: the lifecycle metric must land in campaign.jsonl ───────────
  # This scenario is PURPOSE-BUILT to produce it, so B3-S1 is a hard assertion
  # (unlike bug-07, where a stale worker prompt can legitimately yield no campaign.jsonl).
  # The lib was already sourced at run_scenario top (before the cleanup trap — see the
  # bash-3.2 RETURN-trap note there); do NOT re-source here or it would fire the trap.
  if typeset -f b3_assert_lifecycle_metrics_present >/dev/null 2>&1; then
    # zsh leader writes campaign.jsonl to $DESK/analytics/${SLUG}--${md5(ROOT):0:8}/.
    local _jsonl
    _jsonl=$(ls "$sandbox_dir"/.rlp-desk/analytics/${slug}--*/campaign.jsonl 2>/dev/null | head -1)
    if [[ -z "$_jsonl" ]]; then
      _jsonl="$sandbox_dir/.rlp-desk/analytics/${slug}--<hash>/campaign.jsonl"
      # Diagnostics: campaign.jsonl absent despite a complete sentinel. Surface where the
      # leader actually wrote (or failed to write) so this is debuggable from the log alone.
      echo "  [diag] analytics tree:" >&2
      ls -la "$sandbox_dir"/.rlp-desk/analytics/ 2>&1 | sed 's/^/    /' >&2
      echo "  [diag] any campaign.jsonl* under sandbox:" >&2
      find "$sandbox_dir"/.rlp-desk -name 'campaign.jsonl*' 2>/dev/null | sed 's/^/    /' >&2
      echo "  [diag] exercise.log tail:" >&2
      tail -15 "$exercise_log" 2>/dev/null | sed 's/^/    /' >&2
    fi
    b3_assert_lifecycle_metrics_present "$_jsonl"
    b3_assert_lifecycle_metric_within_band "$_jsonl" "pane_eof_to_cleanup_ms" "$B3_BAND_PANE_EOF_CLEANUP_MS"
    # Hard pane_eof presence. This scenario is GUARANTEED to reap a pane, so pane_eof MUST
    # be recorded. B3-S1 only requires SOME non-empty metric and B3-S2 SKIPs a zero-entry
    # metric — so if the zsh leader ever wires a SECOND metric, B3-S1 could pass on it
    # while pane_eof silently vanished. Assert pane_eof entries directly (code-reviewer LOW).
    if [[ -f "$_jsonl" ]]; then
      local _pe_n
      _pe_n=$(jq -s '[.[] | (.lifecycle_metrics.pane_eof_to_cleanup_ms // [])[]] | length' "$_jsonl" 2>/dev/null || echo 0)
      if (( _pe_n >= 1 )); then
        echo "ASSERT B3-pane_eof PASS: $_pe_n pane_eof_to_cleanup_ms entr(ies) recorded"
        ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
      else
        echo "ASSERT B3-pane_eof FAIL: no pane_eof_to_cleanup_ms entries (the metric this scenario exists to validate)"
        ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
        SCENARIO_FAILURE_REASON="B3: pane_eof_to_cleanup_ms not recorded"
      fi
    fi
  else
    echo "ASSERT B3 FAIL: b3-lifecycle-assertions.sh missing at $_b3_lib"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="B3: assertion lib missing"
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
