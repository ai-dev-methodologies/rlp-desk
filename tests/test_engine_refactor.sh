#!/usr/bin/env bash
# TDD test suite for engine path refactoring
# Each phase adds tests BEFORE implementation (RED → GREEN)
set -uo pipefail

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
LIB="${LIB:-src/scripts/lib_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

extract_fn() {
  local result
  result=$(awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" { p=1 } p { print } p && /^}/ { p=0 }' "$RUN")
  if [[ -z "$result" && -f "$LIB" ]]; then
    result=$(awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" { p=1 } p { print } p && /^}/ { p=0 }' "$LIB")
  fi
  echo "$result"
}

run_harness() {
  local script="$1"
  eval "$script" 2>&1
}

# =============================================================================
# Phase 1: check_dead_pane(pane_cmd, engine, role)
# =============================================================================
echo "=== Phase 1: check_dead_pane ==="

# T1-1: function exists
fn=$(extract_fn "check_dead_pane")
if [[ -n "$fn" ]]; then
  pass "T1-1: check_dead_pane function exists"
else
  fail "T1-1: check_dead_pane function NOT found"
fi

# T1-2: empty cmd = dead (claude worker)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane '' claude worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "0" ]]; then
    pass "T1-2: check_dead_pane '' claude worker → 0 (dead)"
  else
    fail "T1-2: check_dead_pane '' claude worker → expected 0, got $rc"
  fi
else
  fail "T1-2: skipped (function missing)"
fi

# T1-3: zsh = dead (claude worker)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane 'zsh' claude worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "0" ]]; then
    pass "T1-3: check_dead_pane 'zsh' claude worker → 0 (dead)"
  else
    fail "T1-3: expected 0, got $rc"
  fi
else
  fail "T1-3: skipped"
fi

# T1-4: bash = dead (claude worker)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane 'bash' claude worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "0" ]]; then
    pass "T1-4: check_dead_pane 'bash' claude worker → 0 (dead)"
  else
    fail "T1-4: expected 0, got $rc"
  fi
else
  fail "T1-4: skipped"
fi

# T1-5: bash = alive (codex worker — codex uses bash trigger)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane 'bash' codex worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "1" ]]; then
    pass "T1-5: check_dead_pane 'bash' codex worker → 1 (alive)"
  else
    fail "T1-5: expected 1, got $rc"
  fi
else
  fail "T1-5: skipped"
fi

# T1-6: node = alive (claude worker)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane 'node' claude worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "1" ]]; then
    pass "T1-6: check_dead_pane 'node' claude worker → 1 (alive)"
  else
    fail "T1-6: expected 1, got $rc"
  fi
else
  fail "T1-6: skipped"
fi

# T1-7: codex = alive (codex worker)
if [[ -n "$fn" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn}
check_dead_pane 'codex' codex worker
echo \$?")
  rc=$(echo "$result" | tail -1)
  if [[ "$rc" == "1" ]]; then
    pass "T1-7: check_dead_pane 'codex' codex worker → 1 (alive)"
  else
    fail "T1-7: expected 1, got $rc"
  fi
else
  fail "T1-7: skipped"
fi

# =============================================================================
# Phase 2: get_model_string(engine, model, reasoning)
# =============================================================================
echo ""
echo "=== Phase 2: get_model_string ==="

# T2-1: function exists
fn2=$(extract_fn "get_model_string")
if [[ -n "$fn2" ]]; then
  pass "T2-1: get_model_string function exists"
else
  fail "T2-1: get_model_string function NOT found"
fi

# T2-2: claude sonnet → "sonnet"
if [[ -n "$fn2" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn2}
get_model_string claude sonnet ''")
  if [[ "$result" == "sonnet" ]]; then
    pass "T2-2: get_model_string claude sonnet → 'sonnet'"
  else
    fail "T2-2: expected 'sonnet', got '$result'"
  fi
else
  fail "T2-2: skipped"
fi

# T2-3: codex gpt-5.5 medium → "gpt-5.5:medium"
if [[ -n "$fn2" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn2}
get_model_string codex gpt-5.5 medium")
  if [[ "$result" == "gpt-5.5:medium" ]]; then
    pass "T2-3: get_model_string codex gpt-5.5 medium → 'gpt-5.5:medium'"
  else
    fail "T2-3: expected 'gpt-5.5:medium', got '$result'"
  fi
else
  fail "T2-3: skipped"
fi

# T2-4: codex spark high → "gpt-5.3-codex-spark:high"
if [[ -n "$fn2" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn2}
get_model_string codex gpt-5.3-codex-spark high")
  if [[ "$result" == "gpt-5.3-codex-spark:high" ]]; then
    pass "T2-4: get_model_string codex spark high → 'gpt-5.3-codex-spark:high'"
  else
    fail "T2-4: expected 'gpt-5.3-codex-spark:high', got '$result'"
  fi
else
  fail "T2-4: skipped"
fi

# T2-5: claude opus → "opus"
if [[ -n "$fn2" ]]; then
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn2}
get_model_string claude opus ''")
  if [[ "$result" == "opus" ]]; then
    pass "T2-5: get_model_string claude opus → 'opus'"
  else
    fail "T2-5: expected 'opus', got '$result'"
  fi
else
  fail "T2-5: skipped"
fi

# T2-6: check_model_upgrade uses get_model_string
local c1 c2; c1=$(grep -c 'get_model_string' "$RUN" 2>/dev/null) || c1=0; c2=$(grep -c 'get_model_string' "$LIB" 2>/dev/null) || c2=0; count=$((c1 + c2))
if (( count >= 2 )); then
  pass "T2-6: get_model_string referenced $count times (>=2)"
else
  fail "T2-6: get_model_string referenced only $count times (need >=2)"
fi

# =============================================================================
# Phase 3: launch_worker_claude() + launch_worker_codex()
# =============================================================================
echo ""
echo "=== Phase 3: launch_worker_claude/codex ==="

# T3-1: launch_worker_claude exists
fn3c=$(extract_fn "launch_worker_claude")
if [[ -n "$fn3c" ]]; then
  pass "T3-1: launch_worker_claude function exists"
else
  fail "T3-1: launch_worker_claude function NOT found"
fi

# T3-2: launch_worker_codex exists
fn3x=$(extract_fn "launch_worker_codex")
if [[ -n "$fn3x" ]]; then
  pass "T3-2: launch_worker_codex function exists"
else
  fail "T3-2: launch_worker_codex function NOT found"
fi

# T3-3: launch_worker_claude has wait_for_pane_ready
if [[ -n "$fn3c" ]]; then
  if echo "$fn3c" | grep -q "wait_for_pane_ready"; then
    pass "T3-3: launch_worker_claude has wait_for_pane_ready"
  else
    fail "T3-3: launch_worker_claude missing wait_for_pane_ready"
  fi
else
  fail "T3-3: skipped"
fi

# T3-4: launch_worker_claude has instruction send
if [[ -n "$fn3c" ]]; then
  if echo "$fn3c" | grep -q "Read and execute"; then
    pass "T3-4: launch_worker_claude has instruction send"
  else
    fail "T3-4: launch_worker_claude missing instruction send"
  fi
else
  fail "T3-4: skipped"
fi

# T3-5: launch_worker_codex has codex TUI launch (paste_to_pane dispatch)
# Refactored: codex workers now use paste_to_pane (matching claude pattern) instead of
# bash trigger scripts. Assert the launch primitive is present.
if [[ -n "$fn3x" ]]; then
  if echo "$fn3x" | grep -q "paste_to_pane"; then
    pass "T3-5: launch_worker_codex dispatches via paste_to_pane"
  else
    fail "T3-5: launch_worker_codex missing paste_to_pane dispatch"
  fi
else
  fail "T3-5: skipped"
fi

# T3-6: launch_worker_codex does NOT have wait_for_pane_ready
if [[ -n "$fn3x" ]]; then
  count=$(echo "$fn3x" | grep -c "wait_for_pane_ready" 2>/dev/null) || count=0
  if (( count == 0 )); then
    pass "T3-6: launch_worker_codex has no wait_for_pane_ready (correct)"
  else
    fail "T3-6: launch_worker_codex should not have wait_for_pane_ready"
  fi
else
  fail "T3-6: skipped"
fi

# T3-7: main() calls launch_worker_claude or launch_worker_codex
count=$(grep -c "launch_worker_claude\|launch_worker_codex" "$RUN" 2>/dev/null) || count=0
if (( count >= 2 )); then
  pass "T3-7: main() dispatches to launch_worker functions ($count refs)"
else
  fail "T3-7: main() missing launch_worker dispatch ($count refs, need >=2)"
fi

# =============================================================================
# Phase 4: launch_verifier_claude() + launch_verifier_codex()
# =============================================================================
echo ""
echo "=== Phase 4: launch_verifier_claude/codex ==="

fn4c=$(extract_fn "launch_verifier_claude")
if [[ -n "$fn4c" ]]; then pass "T4-1: launch_verifier_claude exists"; else fail "T4-1: launch_verifier_claude NOT found"; fi

fn4x=$(extract_fn "launch_verifier_codex")
if [[ -n "$fn4x" ]]; then pass "T4-2: launch_verifier_codex exists"; else fail "T4-2: launch_verifier_codex NOT found"; fi

if [[ -n "$fn4c" ]]; then
  if echo "$fn4c" | grep -q "submit_attempts"; then pass "T4-3: launch_verifier_claude has submit loop"; else fail "T4-3: missing submit loop"; fi
else fail "T4-3: skipped"; fi

if [[ -n "$fn4x" ]]; then
  # launch_verifier_codex uses the same submit_attempts submit loop as launch_verifier_claude
  # for parity (visual tmux execution + adaptive retry). Assert the loop is present.
  if echo "$fn4x" | grep -q "submit_attempts"; then pass "T4-4: launch_verifier_codex has submit loop (parity with claude)"; else fail "T4-4: missing submit loop"; fi
else fail "T4-4: skipped"; fi

count=$(grep -c "launch_verifier_claude\|launch_verifier_codex" "$RUN" 2>/dev/null) || count=0
if (( count >= 2 )); then pass "T4-5: dispatch to launch_verifier functions ($count refs)"; else fail "T4-5: missing dispatch ($count refs)"; fi

# =============================================================================
# Phase 5: handle_worker_exit_codex() + handle_worker_exit_claude()
# =============================================================================
echo ""
echo "=== Phase 5: handle_worker_exit ==="

fn5x=$(extract_fn "handle_worker_exit_codex")
if [[ -n "$fn5x" ]]; then pass "T5-1: handle_worker_exit_codex exists"; else fail "T5-1: NOT found"; fi

fn5c=$(extract_fn "handle_worker_exit_claude")
if [[ -n "$fn5c" ]]; then pass "T5-2: handle_worker_exit_claude exists"; else fail "T5-2: NOT found"; fi

if [[ -n "$fn5x" ]]; then
  if echo "$fn5x" | grep -q "auto-generate\|signal_file"; then pass "T5-3: handle_worker_exit_codex generates signal"; else fail "T5-3: missing signal generation"; fi
else fail "T5-3: skipped"; fi

if [[ -n "$fn5x" ]]; then
  count=$(echo "$fn5x" | grep -c "restart_worker" 2>/dev/null) || count=0
  if (( count == 0 )); then pass "T5-4: handle_worker_exit_codex no restart (correct)"; else fail "T5-4: should not restart"; fi
else fail "T5-4: skipped"; fi

if [[ -n "$fn5c" ]]; then
  if echo "$fn5c" | grep -q "restart_worker"; then pass "T5-5: handle_worker_exit_claude calls restart"; else fail "T5-5: missing restart_worker"; fi
else fail "T5-5: skipped"; fi

if grep -q "handle_worker_exit_codex\|handle_worker_exit_claude" "$RUN" 2>/dev/null; then
  pass "T5-6: poll_for_signal dispatches to handle_worker_exit"
else
  fail "T5-6: missing dispatch in poll_for_signal"
fi

# =============================================================================
# Phase 6: restart_worker() codex guard
# =============================================================================
echo ""
echo "=== Phase 6: restart_worker codex guard ==="

fn6=$(extract_fn "restart_worker")
if [[ -n "$fn6" ]]; then
  if echo "$fn6" | grep -q 'WORKER_ENGINE.*codex'; then pass "T6-1: restart_worker has codex guard"; else fail "T6-1: missing codex guard"; fi
  if echo "$fn6" | head -10 | grep -q "return 1"; then pass "T6-2: codex guard returns 1"; else fail "T6-2: missing return 1 in guard"; fi
else
  fail "T6-1: restart_worker not found"
  fail "T6-2: skipped"
fi

# T6-3: existing claude restart path preserved (refactored to use build_claude_cmd helper
# instead of direct CLAUDE_BIN invocation).
if [[ -n "$fn6" ]]; then
  if echo "$fn6" | grep -q "build_claude_cmd"; then pass "T6-3: claude restart path preserved (build_claude_cmd)"; else fail "T6-3: claude path missing"; fi
else fail "T6-3: skipped"; fi

# =============================================================================
# Phase 7: run_single_verifier internal split
# =============================================================================
echo ""
echo "=== Phase 7: run_single_verifier split ==="

fn7=$(extract_fn "run_single_verifier")
if [[ -n "$fn7" ]]; then
  if echo "$fn7" | grep -q "_rsv_launch_codex\|launch_verifier_codex"; then pass "T7-1: codex launch helper in run_single_verifier"; else fail "T7-1: missing codex launch helper"; fi
  if echo "$fn7" | grep -q "_rsv_launch_claude\|launch_verifier_claude"; then pass "T7-2: claude launch helper in run_single_verifier"; else fail "T7-2: missing claude launch helper"; fi
  if echo "$fn7" | grep -q "POLL_INTERVAL\|poll_for_signal"; then pass "T7-3: poll logic present"; else fail "T7-3: missing poll logic"; fi
else
  fail "T7-1: run_single_verifier not found"
  fail "T7-2: skipped"
  fail "T7-3: skipped"
fi

# T7-4: regression — existing consensus tests reference (structural check)
if grep -q "run_single_verifier\|run_consensus_verification" "$RUN" 2>/dev/null; then
  pass "T7-4: consensus functions still present"
else
  fail "T7-4: consensus functions missing"
fi

# =============================================================================
# Results
# =============================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then exit 1; else exit 0; fi
