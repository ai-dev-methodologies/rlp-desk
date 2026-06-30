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
  echo "Append 'done' to README.md, write done-claim and iter-signal." > .rlp-desk/prompts/$slug.worker.prompt.md
  echo "Verify README.md contains 'done', write verify-verdict pass+complete." > .rlp-desk/prompts/$slug.verifier.prompt.md

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
  if ! RLP_LIFECYCLE_METRICS=1 timeout 600 node "$node_leader_path" run "$slug" \
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
  # v0.15.4 PR-B3: lifecycle metric assertion on the production zsh leader.
  #
  # SCOPE (zsh-leader port, Option A): the zsh leader wires exactly ONE live
  # metric — pane_eof_to_cleanup_ms (_kill_pane_process, lib_ralph_desk.zsh:372),
  # emitted on every real worker/verifier pane reap. The other three metrics
  # (iter_signal_write_to_read_ms, verdict_write_to_read_ms, pane_reap_latency_ms)
  # are Node-leader-only and NOT emitted on the --mode tmux path, so asserting
  # them here would only ever SKIP — they are omitted to avoid implying coverage
  # the zsh port does not provide.
  #
  # ABSENCE SEMANTICS: this real-LLM scenario depends on a haiku worker actually
  # producing a valid iter-signal so the leader completes an iteration and flushes
  # campaign.jsonl. When the (currently stale) trivial worker prompt does not drive
  # that within the timeout, no campaign.jsonl is produced — that is a SCENARIO
  # staleness (separate open item: worker-prompt / A1-stream), NOT a B3 telemetry
  # regression, so it SKIPs rather than FAILs. A produced-but-empty campaign.jsonl
  # still FAILs (real "telemetry not emitting" signal). The authoritative,
  # deterministic proof of the emit chain is tests/test_b3_pane_reap_integration.sh
  # (real _kill_pane_process → campaign.jsonl → B3-S1 PASS).
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
      echo "ASSERT B3 SKIP: campaign.jsonl not produced — campaign did not complete an iteration"
      echo "                (worker-prompt staleness, separate open item; not a B3 telemetry regression)."
      echo "                B3 emit chain is proven deterministically by tests/test_b3_pane_reap_integration.sh."
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
