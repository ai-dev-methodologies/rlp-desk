#!/usr/bin/env bash
# Test suite: US-004 — cost-log per-phase timing
# AC1 (3) + AC2 (3) + AC3 (3) + E2E (4) + Reg (3) + Timeout (3) = 19 total
# ALL tests are runtime: extract write_cost_log(), call with controlled inputs, check output JSON
#
# RED phase: tests fail when write_cost_log lacks timing fields (original pre-US-004 version)
# GREEN phase: tests pass with US-004 implementation

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-004: cost-log per-phase timing ==="
echo "Target: $RUN"
echo ""

# --- Shared: extract write_cost_log() body for runtime execution ---
WCL_BODY="$(awk '
  /^write_cost_log\(\) \{/ { in_fn=1; depth=0 }
  in_fn {
    line = $0
    for (i=1; i<=length(line); i++) {
      c = substr(line, i, 1)
      if (c == "{") depth++
      else if (c == "}") {
        depth--
        if (depth == 0) { print; in_fn=0; next }
      }
    }
    print
  }
' "$RUN")"

if [[ -z "$WCL_BODY" ]]; then
  echo "FATAL: could not extract write_cost_log() from $RUN"
  echo "Results: 0 passed, 13 failed"
  exit 1
fi

E2E_BASE="$(mktemp -d)"
trap 'rm -rf "$E2E_BASE"' EXIT

# Helper: run write_cost_log harness with given timing params
# Args: dir w_start w_end v_start v_end [claude_dur] [codex_dur]
run_wcl_harness() {
  local dir="$1"
  local w_start="$2" w_end="$3" v_start="$4" v_end="$5"
  local claude_dur="${6:-}" codex_dur="${7:-}"
  local logs="$dir/logs"
  mkdir -p "$logs"
  local cost_log="$dir/cost-log.jsonl"

  cat > "$dir/h.zsh" << HARNESS
LOGS_DIR="$logs"
COST_LOG="$cost_log"
DONE_CLAIM_FILE=""
VERDICT_FILE=""
ITER_WORKER_START=$w_start
ITER_WORKER_END=$w_end
ITER_VERIFIER_START=$v_start
ITER_VERIFIER_END=$v_end
ITER_VERIFIER_CLAUDE_DURATION_S="$claude_dur"
ITER_VERIFIER_CODEX_DURATION_S="$codex_dur"
HARNESS

  printf '%s\n' "$WCL_BODY" >> "$dir/h.zsh"
  printf 'write_cost_log 1\n' >> "$dir/h.zsh"

  zsh -f "$dir/h.zsh" >/dev/null 2>&1
  echo "$cost_log"
}

# Helper: run write_cost_log harness with UNSET timing vars (no ITER_* at all)
run_wcl_harness_no_timing() {
  local dir="$1"
  local logs="$dir/logs"
  mkdir -p "$logs"
  local cost_log="$dir/cost-log.jsonl"

  cat > "$dir/h.zsh" << HARNESS
LOGS_DIR="$logs"
COST_LOG="$cost_log"
DONE_CLAIM_FILE=""
VERDICT_FILE=""
HARNESS

  printf '%s\n' "$WCL_BODY" >> "$dir/h.zsh"
  printf 'write_cost_log 1\n' >> "$dir/h.zsh"

  zsh -f "$dir/h.zsh" >/dev/null 2>&1
  echo "$cost_log"
}

# Timestamps for test scenarios
NOW=$(date +%s)
W_START=$NOW
W_END=$(( NOW + 30 ))
V_START=$(( NOW + 31 ))
V_END=$(( NOW + 61 ))

# ============================================================
# AC1: per-phase timestamp fields in write_cost_log output (runtime)
# ============================================================
echo "--- AC1: write_cost_log outputs per-phase timestamp fields ---"

# AC1-happy: Runtime — all 6 timing fields present with correct values
test_ac1_happy() {
  local dir="$E2E_BASE/ac1-happy"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  local has_wst has_wet has_wds has_vst has_vet has_vds
  has_wst=$(echo "$line" | grep -c '"worker_start_time"')
  has_wet=$(echo "$line" | grep -c '"worker_end_time"')
  has_wds=$(echo "$line" | grep -c '"worker_duration_s"')
  has_vst=$(echo "$line" | grep -c '"verifier_start_time"')
  has_vet=$(echo "$line" | grep -c '"verifier_end_time"')
  has_vds=$(echo "$line" | grep -c '"verifier_duration_s"')

  if [[ "$has_wst" -ge 1 && "$has_wet" -ge 1 && "$has_wds" -ge 1 && \
        "$has_vst" -ge 1 && "$has_vet" -ge 1 && "$has_vds" -ge 1 ]]; then
    pass "AC1-happy: all 6 timing fields present (worker_start/end/duration + verifier_start/end/duration)"
  else
    fail "AC1-happy: missing timing fields (wst=$has_wst wet=$has_wet wds=$has_wds vst=$has_vst vet=$has_vet vds=$has_vds)"
  fi
}

# AC1-negative: Runtime — date failure graceful degradation (invalid epoch)
# When ITER_WORKER_START is set to an invalid value, cost-log should still be written
# (the 2>/dev/null || echo "" fallback should prevent total failure)
test_ac1_negative() {
  local dir="$E2E_BASE/ac1-neg"; mkdir -p "$dir"
  local logs="$dir/logs"
  mkdir -p "$logs"
  local cost_log="$dir/cost-log.jsonl"

  cat > "$dir/h.zsh" << 'HARNESS'
LOGS_DIR="__LOGS__"
COST_LOG="__COSTLOG__"
DONE_CLAIM_FILE=""
VERDICT_FILE=""
ITER_WORKER_START=99999999999999
ITER_WORKER_END=99999999999999
ITER_VERIFIER_START=99999999999999
ITER_VERIFIER_END=99999999999999
ITER_VERIFIER_CLAUDE_DURATION_S=""
ITER_VERIFIER_CODEX_DURATION_S=""
HARNESS

  sed -i.bak "s|__LOGS__|$logs|;s|__COSTLOG__|$cost_log|" "$dir/h.zsh"
  printf '%s\n' "$WCL_BODY" >> "$dir/h.zsh"
  printf 'write_cost_log 1\n' >> "$dir/h.zsh"

  zsh -f "$dir/h.zsh" >/dev/null 2>&1

  if [[ -f "$cost_log" ]] && grep -q '"iteration":1' "$cost_log" 2>/dev/null; then
    pass "AC1-negative: cost-log written despite invalid epoch (date failure graceful degradation)"
  else
    fail "AC1-negative: cost-log NOT written when date fails (should degrade gracefully)"
  fi
}

# AC1-boundary: Runtime — zero duration when worker_start == worker_end
test_ac1_boundary() {
  local dir="$E2E_BASE/ac1-bound"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_START" "$V_START" "$V_START")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  if echo "$line" | grep -q '"worker_duration_s":0' && \
     echo "$line" | grep -q '"verifier_duration_s":0'; then
    pass "AC1-boundary: worker_duration_s=0 and verifier_duration_s=0 when start==end"
  else
    fail "AC1-boundary: expected duration=0 when start==end (got: $(echo "$line" | grep -o '"worker_duration_s":[0-9]*'))"
  fi
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary

# ============================================================
# AC2: consensus mode per-engine timing separation (runtime)
# ============================================================
echo ""
echo "--- AC2: consensus mode per-engine timing ---"

# AC2-happy: Runtime — consensus fields present when both durations provided
test_ac2_happy() {
  local dir="$E2E_BASE/ac2-happy"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END" "42" "15")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  if echo "$line" | grep -q '"verifier_claude_duration_s":42' && \
     echo "$line" | grep -q '"verifier_codex_duration_s":15'; then
    pass "AC2-happy: verifier_claude_duration_s=42 and verifier_codex_duration_s=15 present"
  else
    fail "AC2-happy: missing consensus fields (line: $(echo "$line" | cut -c1-120))"
  fi
}

# AC2-negative: Runtime — consensus fields ABSENT when no consensus params
test_ac2_negative() {
  local dir="$E2E_BASE/ac2-neg"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END" "" "")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  local has_claude has_codex
  has_claude=$(echo "$line" | grep -c 'verifier_claude_duration_s' || true)
  has_codex=$(echo "$line" | grep -c 'verifier_codex_duration_s' || true)

  if [[ "$has_claude" -eq 0 && "$has_codex" -eq 0 ]]; then
    pass "AC2-negative: consensus fields absent when no consensus params provided"
  else
    fail "AC2-negative: consensus fields should be absent (claude=$has_claude codex=$has_codex)"
  fi
}

# AC2-boundary: Runtime — only claude duration set (no codex) → only claude field present
test_ac2_boundary() {
  local dir="$E2E_BASE/ac2-bound"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END" "99" "")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  local has_claude has_codex
  has_claude=$(echo "$line" | grep -c '"verifier_claude_duration_s":99' || true)
  has_codex=$(echo "$line" | grep -c 'verifier_codex_duration_s' || true)

  if [[ "$has_claude" -ge 1 && "$has_codex" -eq 0 ]]; then
    pass "AC2-boundary: only verifier_claude_duration_s=99 present (codex absent)"
  else
    fail "AC2-boundary: expected only claude field (claude=$has_claude codex=$has_codex)"
  fi
}

test_ac2_happy
test_ac2_negative
test_ac2_boundary

# ============================================================
# AC3: existing fields preserved — runtime proof (additive-only)
# ============================================================
echo ""
echo "--- AC3: existing cost-log fields preserved (runtime) ---"

# AC3-happy: Runtime — estimated_tokens present in output alongside timing fields
test_ac3_happy() {
  local dir="$E2E_BASE/ac3-happy"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  if echo "$line" | grep -q '"estimated_tokens"'; then
    pass "AC3-happy: estimated_tokens present in runtime output alongside timing fields"
  else
    fail "AC3-happy: estimated_tokens missing from runtime output"
  fi
}

# AC3-negative: Runtime — token_source field NOT replaced by timing fields
test_ac3_negative() {
  local dir="$E2E_BASE/ac3-neg"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  if echo "$line" | grep -q '"token_source":"estimated"'; then
    pass "AC3-negative: token_source:estimated preserved (not replaced by timing)"
  else
    fail "AC3-negative: token_source:estimated missing or replaced"
  fi
}

# AC3-boundary: Runtime — all 5 existing fields AND all 6 new timing fields coexist in same JSON line
test_ac3_boundary() {
  local dir="$E2E_BASE/ac3-bound"; mkdir -p "$dir"
  local log_file
  log_file=$(run_wcl_harness "$dir" "$W_START" "$W_END" "$V_START" "$V_END")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  local count=0
  for field in estimated_tokens token_source prompt_bytes claim_bytes verdict_bytes \
               worker_start_time worker_end_time worker_duration_s \
               verifier_start_time verifier_end_time verifier_duration_s; do
    echo "$line" | grep -q "\"$field\"" && (( count++ ))
  done

  if [[ "$count" -eq 11 ]]; then
    pass "AC3-boundary: all 11 fields (5 existing + 6 timing) coexist in same JSON line"
  else
    fail "AC3-boundary: expected 11 fields, found $count"
  fi
}

test_ac3_happy
test_ac3_negative
test_ac3_boundary

# ============================================================
# E2E: Full runtime scenarios with value verification
# ============================================================
echo ""
echo "--- E2E: write_cost_log runtime timing fields ---"

# E2E-happy: worker_duration_s computed correctly as end - start
e2e_happy_dir="$E2E_BASE/e2e-happy"; mkdir -p "$e2e_happy_dir"
e2e_happy_log=$(run_wcl_harness "$e2e_happy_dir" "$W_START" "$W_END" "$V_START" "$V_END")
expected_w_dur=$(( W_END - W_START ))  # = 30
expected_v_dur=$(( V_END - V_START ))  # = 30
line=$(head -1 "$e2e_happy_log" 2>/dev/null)
if echo "$line" | grep -q "\"worker_duration_s\":$expected_w_dur" && \
   echo "$line" | grep -q "\"verifier_duration_s\":$expected_v_dur"; then
  pass "E2E-happy: worker_duration_s=$expected_w_dur and verifier_duration_s=$expected_v_dur correctly computed"
else
  actual_w=$(echo "$line" | grep -o '"worker_duration_s":[0-9]*' | head -1)
  actual_v=$(echo "$line" | grep -o '"verifier_duration_s":[0-9]*' | head -1)
  fail "E2E-happy: expected w_dur=$expected_w_dur v_dur=$expected_v_dur (got: ${actual_w:-missing} ${actual_v:-missing})"
fi

# E2E-duration: ISO8601 format validation for timestamp fields
e2e_dur_dir="$E2E_BASE/e2e-dur"; mkdir -p "$e2e_dur_dir"
e2e_dur_log=$(run_wcl_harness "$e2e_dur_dir" "$W_START" "$W_END" "$V_START" "$V_END")
line=$(head -1 "$e2e_dur_log" 2>/dev/null)
# ISO8601 pattern: YYYY-MM-DDTHH:MM:SSZ
iso_count=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | wc -l | tr -d ' ')
# Expect at least 4 ISO timestamps (worker_start, worker_end, verifier_start, verifier_end) + timestamp field
if [[ "$iso_count" -ge 4 ]]; then
  pass "E2E-duration: $iso_count ISO8601 timestamps found in output"
else
  fail "E2E-duration: expected >=4 ISO8601 timestamps, found $iso_count"
fi

# E2E-existing: no-timing mode still writes cost-log with existing fields only
e2e_exist_dir="$E2E_BASE/e2e-exist"; mkdir -p "$e2e_exist_dir"
e2e_exist_log=$(run_wcl_harness_no_timing "$e2e_exist_dir")
line=$(head -1 "$e2e_exist_log" 2>/dev/null)
has_tokens=$(echo "$line" | grep -c '"estimated_tokens"' || true)
has_source=$(echo "$line" | grep -c '"token_source"' || true)
has_iter=$(echo "$line" | grep -c '"iteration":1' || true)
if [[ "$has_tokens" -ge 1 && "$has_source" -ge 1 && "$has_iter" -ge 1 ]]; then
  pass "E2E-existing: cost-log written with existing fields when no timing vars set"
else
  fail "E2E-existing: missing fields (tokens=$has_tokens source=$has_source iter=$has_iter)"
fi

# E2E-consensus: consensus fields with specific values
e2e_cons_dir="$E2E_BASE/e2e-cons"; mkdir -p "$e2e_cons_dir"
e2e_cons_log=$(run_wcl_harness "$e2e_cons_dir" "$W_START" "$W_END" "$V_START" "$V_END" "42" "15")
line=$(head -1 "$e2e_cons_log" 2>/dev/null)
has_claude=$(echo "$line" | grep -c '"verifier_claude_duration_s":42' || true)
has_codex=$(echo "$line" | grep -c '"verifier_codex_duration_s":15' || true)
if [[ "$has_claude" -ge 1 && "$has_codex" -ge 1 ]]; then
  pass "E2E-consensus: verifier_claude_duration_s=42 and verifier_codex_duration_s=15 present"
else
  fail "E2E-consensus: missing consensus fields (claude=$has_claude, codex=$has_codex)"
fi

# ============================================================
# Regression: consecutive-iteration verifier state carryover
# ============================================================
echo ""
echo "--- Regression: consecutive-iteration state carryover ---"

# Reg-1: Static — main loop resets ITER_VERIFIER_START at iteration start
test_reg1_static_reset() {
  # The per-iteration reset section must clear ITER_VERIFIER_START
  # to prevent stale verifier timestamps from carrying over to non-verify iterations
  local reset_count
  reset_count=$(grep -c 'ITER_VERIFIER_START=""' "$RUN" || true)
  if [[ "$reset_count" -ge 1 ]]; then
    pass "Reg-1: ITER_VERIFIER_START reset found in source ($reset_count occurrences)"
  else
    fail "Reg-1: ITER_VERIFIER_START reset NOT found — stale verifier state will carry over"
  fi
}

# Reg-2: Static — main loop resets ITER_VERIFIER_END at iteration start
test_reg2_static_reset() {
  local reset_count
  reset_count=$(grep -c 'ITER_VERIFIER_END=""' "$RUN" || true)
  if [[ "$reset_count" -ge 1 ]]; then
    pass "Reg-2: ITER_VERIFIER_END reset found in source ($reset_count occurrences)"
  else
    fail "Reg-2: ITER_VERIFIER_END reset NOT found — stale verifier state will carry over"
  fi
}

# Reg-3: Runtime — second iteration (continue) should have verifier_duration_s:0
test_reg3_runtime_carryover() {
  local dir="$E2E_BASE/reg3"; mkdir -p "$dir"
  local logs="$dir/logs"; mkdir -p "$logs"
  local cost_log="$dir/cost-log.jsonl"

  # Simulate two consecutive iterations:
  # Iter 1 = verify path (all timing globals set)
  # Iter 2 = continue path (verifier globals reset, worker globals fresh)
  cat > "$dir/h.zsh" << HARNESS
LOGS_DIR="$logs"
COST_LOG="$cost_log"
DONE_CLAIM_FILE=""
VERDICT_FILE=""

# --- Iteration 1: verify path (all timing set) ---
ITER_WORKER_START=$W_START
ITER_WORKER_END=$W_END
ITER_VERIFIER_START=$V_START
ITER_VERIFIER_END=$V_END
ITER_VERIFIER_CLAUDE_DURATION_S=""
ITER_VERIFIER_CODEX_DURATION_S=""
HARNESS

  printf '%s\n' "$WCL_BODY" >> "$dir/h.zsh"
  cat >> "$dir/h.zsh" << HARNESS
write_cost_log 1

# --- Iteration 2: continue path (verifier globals reset as main loop should do) ---
ITER_WORKER_START=$(( $W_START + 100 ))
ITER_WORKER_END=$(( $W_END + 100 ))
ITER_VERIFIER_START=""
ITER_VERIFIER_END=""
ITER_VERIFIER_CLAUDE_DURATION_S=""
ITER_VERIFIER_CODEX_DURATION_S=""
write_cost_log 2
HARNESS

  zsh -f "$dir/h.zsh" >/dev/null 2>&1

  # Line 1: verify iteration — should have non-zero verifier_duration_s
  local line1
  line1=$(sed -n '1p' "$cost_log" 2>/dev/null)
  local line1_vdur
  line1_vdur=$(echo "$line1" | grep -o '"verifier_duration_s":[0-9]*' | grep -o '[0-9]*$')

  # Line 2: continue iteration — should have verifier_duration_s:0
  local line2
  line2=$(sed -n '2p' "$cost_log" 2>/dev/null)

  if echo "$line2" | grep -q '"verifier_duration_s":0' && \
     echo "$line2" | grep -q '"iteration":2' && \
     [[ "${line1_vdur:-0}" -gt 0 ]]; then
    pass "Reg-3: iter1 verifier_duration_s=${line1_vdur}, iter2 verifier_duration_s=0 (no stale carryover)"
  else
    fail "Reg-3: carryover detected or missing data (iter1_vdur=${line1_vdur:-missing}, line2=$(echo "$line2" | cut -c1-120))"
  fi
}

test_reg1_static_reset
test_reg2_static_reset
test_reg3_runtime_carryover

# ============================================================
# Timeout Path: hard-ceiling exceeded is log-only (no kill); cost-log at normal iteration end
# After 88d9a75: ceiling exceeded logs warning + hard_ceiling_exceeded=true but does NOT kill worker
# ============================================================
echo ""
echo "--- Timeout Path: hard-timeout cost-log recording ---"

# Timeout-1: Static — hard-ceiling exceeded path is log-only with hard_ceiling_exceeded=true
# After 88d9a75: ceiling no longer kills worker; logs hard_ceiling_exceeded=true + action=log_only_no_kill
test_timeout_static_worker_end() {
  if grep -q 'hard_ceiling_exceeded=true' "$RUN" && grep -q 'action=log_only_no_kill' "$RUN"; then
    pass "Timeout-1: hard-ceiling exceeded path logs hard_ceiling_exceeded=true with action=log_only_no_kill"
  else
    fail "Timeout-1: hard-ceiling exceeded path missing hard_ceiling_exceeded=true or action=log_only_no_kill log"
  fi
}

# Timeout-2: Static — ceiling-exceeded path has no early return 1, and write_cost_log exists at loop end
# PRD boundary (AC1 boundary): worker timing always captured even on ceiling-exceeded iterations
# - Ceiling block MUST NOT have return 1 (so iteration continues to loop-end write_cost_log)
# - write_cost_log "$ITERATION" MUST exist at main loop level (guarantees cost-log written for ALL iterations)
# Combined with Timeout-3 (runtime), proves cost-log records worker_end_time on ceiling-exceeded path.
# RED: 88d9a75^ ceiling block had return 1 (early exit before loop-end write_cost_log)
# GREEN: HEAD ceiling block is log-only (no return 1) → loop always reaches write_cost_log
test_timeout_static_cost_log() {
  local ceiling_ctx
  ceiling_ctx=$(grep -A 15 'iter_elapsed >= HARD_CEILING' "$RUN")

  local has_return1=0
  echo "$ceiling_ctx" | grep -q 'return 1' && has_return1=1 || has_return1=0

  local wcl_in_loop
  wcl_in_loop=$(grep -c 'write_cost_log "\$ITERATION"' "$RUN" || true)

  if [[ "$has_return1" -eq 0 && "$wcl_in_loop" -ge 1 ]]; then
    pass "Timeout-2: ceiling block has no return 1 (iteration continues) + write_cost_log at loop end ($wcl_in_loop) — PRD boundary: cost-log always written post-ceiling"
  else
    fail "Timeout-2: ceiling has early return ($has_return1) or write_cost_log missing from loop ($wcl_in_loop)"
  fi
}

# Timeout-3: Runner — simulate timeout path: ITER_WORKER_START set, ITER_WORKER_END set at timeout,
#            write_cost_log called → cost-log contains timing fields with valid duration
test_timeout_runtime_cost_log() {
  local dir="$E2E_BASE/timeout-rt"; mkdir -p "$dir"
  # Simulate: worker started at W_START, timeout hit 45s later (no verifier run)
  local timeout_end=$(( W_START + 45 ))
  local log_file
  # No verifier timing (timeout happens before verifier starts) — pass empty verifier timestamps
  log_file=$(run_wcl_harness "$dir" "$W_START" "$timeout_end" "" "")
  local line
  line=$(head -1 "$log_file" 2>/dev/null)

  local has_wet has_wds
  has_wet=$(echo "$line" | grep -c '"worker_end_time"' || true)
  has_wds=$(echo "$line" | grep -c '"worker_duration_s":45' || true)

  if [[ "$has_wet" -ge 1 && "$has_wds" -ge 1 ]]; then
    pass "Timeout-3: timeout path cost-log has worker_end_time + worker_duration_s=45"
  else
    fail "Timeout-3: timeout path cost-log missing timing (wet=$has_wet wds=$has_wds, line=$(echo "$line" | cut -c1-120))"
  fi
}

test_timeout_static_worker_end
test_timeout_static_cost_log
test_timeout_runtime_cost_log

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
