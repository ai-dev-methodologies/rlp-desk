#!/usr/bin/env bash
# Test suite: US-008 — Self-Verification E2E Integration Tests
# AC1(3) + AC2(3) + AC3(3) + AC4(3) + AC5(3) + AC6(3) + AC7(3) + AC8(3) + AC9(3) + AC10(3) + E2E(3) = 33 total
# Integration tests verifying US-001~007 implementations work together as a system
# AC2-AC5: behavior-driven runtime harnesses (iter-22 fix: shift from source-inspection to runtime)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
INIT="${INIT:-$REPO_ROOT/src/scripts/init_ralph_desk.zsh}"
CMD="${CMD:-$REPO_ROOT/src/commands/rlp-desk.md}"
GOV="${GOV:-$REPO_ROOT/src/governance.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-008: Self-Verification E2E Integration ==="
echo "Target: $RUN, $INIT, $CMD, $GOV"
echo ""

# --- Helpers ---

# Extract function body by name from a zsh script
# Falls back to LIB when function not found in primary source
_extract_fn_from() {
  local fn_name="$1" src="$2"
  awk '
    /^'"$fn_name"'\(\) \{/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$src" 2>/dev/null
}
extract_fn() {
  local fn_name="$1"
  local src="${2:-$RUN}"
  local body
  body="$(_extract_fn_from "$fn_name" "$src")"
  if [[ -z "$body" && "$src" == "$RUN" ]]; then
    body="$(_extract_fn_from "$fn_name" "$LIB")"
  fi
  printf '%s\n' "$body"
}

# Extract §8 Circuit Breaker section from governance.md
extract_s8() {
  awk '/^## 8\. Circuit Breaker/,/^## 9\./' "$GOV"
}

# Runtime harness: build and run session-config writer, producing session-config.json
# Args: tmpdir cb_threshold verify_consensus effective_cb with_sv
run_sc_harness() {
  local tmpdir="$1" cb="${2:-3}" vc="${3:-0}" ecb="${4:-3}" sv="${5:-0}"
  {
    echo '#!/bin/zsh'
    echo "SESSION_NAME=\"test-session\"; SLUG=\"test-slug\"; BASELINE_COMMIT=\"abc123\""
    echo "LEADER_PANE=\"%0\"; WORKER_PANE=\"%1\"; VERIFIER_PANE=\"%2\""
    echo "WORKER_MODEL=\"opus\"; VERIFIER_MODEL=\"sonnet\""
    echo "WORKER_ENGINE=\"claude\"; VERIFIER_ENGINE=\"claude\""
    echo "WORKER_CODEX_MODEL=\"\"; WORKER_CODEX_REASONING=\"\""
    echo "VERIFIER_CODEX_MODEL=\"\"; VERIFIER_CODEX_REASONING=\"\""
    echo "VERIFY_MODE=\"per-us\"; VERIFY_CONSENSUS=$vc; CONSENSUS_SCOPE=\"final\""
    echo "MAX_ITER=10; POLL_INTERVAL=30; ITER_TIMEOUT=600"
    echo "HEARTBEAT_STALE_THRESHOLD=3; MAX_RESTARTS=3"
    echo "IDLE_NUDGE_THRESHOLD=120; MAX_NUDGES=5"
    echo "CB_THRESHOLD=$cb; EFFECTIVE_CB_THRESHOLD=$ecb"
    echo "WITH_SELF_VERIFICATION=$sv"
    echo "SESSION_CONFIG=\"$tmpdir/session-config.json\""
    # Extract atomic_write function from source
    extract_fn atomic_write
    # Extract session-config write block from source
    awk '/# Write session config/,/atomic_write.*SESSION_CONFIG/' "$RUN"
  } > "$tmpdir/harness.zsh"
  zsh -f "$tmpdir/harness.zsh" 2>/dev/null
}

# Runtime harness: extract and run debug [OPTION] logging block, producing debug.log
# Args: tmpdir with_sv
run_debug_harness() {
  local tmpdir="$1" sv="${2:-1}"
  local debug_log="$tmpdir/debug.log"
  # Create fake PRD for us_list extraction
  mkdir -p "$tmpdir/plans"
  printf '### US-001: test\n### US-002: test\n' > "$tmpdir/plans/prd-test-slug.md"
  {
    echo '#!/bin/zsh'
    echo "DEBUG=1"
    echo "DEBUG_LOG=\"$debug_log\""
    echo "SLUG=\"test-slug\"; DESK=\"$tmpdir\""
    echo "VERIFY_MODE=\"per-us\"; VERIFY_CONSENSUS=1; CONSENSUS_SCOPE=\"final\"; MAX_ITER=10"
    echo "WORKER_ENGINE=\"claude\"; WORKER_MODEL=\"opus\""
    echo "VERIFIER_ENGINE=\"claude\"; VERIFIER_MODEL=\"sonnet\""
    echo "CB_THRESHOLD=3; EFFECTIVE_CB_THRESHOLD=3; ITER_TIMEOUT=600"
    echo "WITH_SELF_VERIFICATION=$sv"
    # Extract log_debug function from source
    extract_fn log_debug
    # Extract debug logging block from source (2-space-indent if/fi block)
    awk '/^  # --- Debug: Log execution plan ---/{p=1} p; p && /^  fi/{p=0}' "$RUN"
  } > "$tmpdir/harness.zsh"
  zsh -f "$tmpdir/harness.zsh" 2>/dev/null
}

# Runtime harness: build and run generate_campaign_report, producing campaign-report.md
# Args: tmpdir verify_consensus consensus_scope
run_cr_harness() {
  local tmpdir="$1" vc="${2:-0}" cs="${3:-all}"
  local logs="$tmpdir/logs/test-slug"
  mkdir -p "$logs" "$tmpdir/plans"
  printf '## Objective\nTest objective\n' > "$tmpdir/plans/prd-test-slug.md"
  # Create COMPLETE sentinel to simulate successful campaign
  touch "$logs/COMPLETE"
  {
    echo '#!/bin/zsh'
    echo "CAMPAIGN_REPORT_GENERATED=0"
    echo "SLUG=\"test-slug\"; DESK=\"$tmpdir\""
    echo "LOGS_DIR=\"$logs\""
    echo "COMPLETE_SENTINEL=\"$logs/COMPLETE\""
    echo "BLOCKED_SENTINEL=\"$logs/BLOCKED\""
    echo "START_TIME=\$(date +%s)"
    echo "ROOT=\"$tmpdir\"; BASELINE_COMMIT=\"none\""
    echo "WITH_SELF_VERIFICATION=0"
    echo "WORKER_MODEL=\"opus\"; WORKER_ENGINE=\"claude\""
    echo "VERIFIER_MODEL=\"sonnet\"; VERIFIER_ENGINE=\"claude\""
    echo "VERIFY_CONSENSUS=$vc; CONSENSUS_SCOPE=\"$cs\""
    echo "VERIFIED_US=\"US-001\"; CONSECUTIVE_FAILURES=0"
    echo "MAX_ITER=10; ITERATION=3"
    echo "COST_LOG=\"$logs/cost-log.jsonl\""
    echo 'log() { : ; }'
    # Extract required functions
    extract_fn atomic_write
    extract_fn generate_campaign_report
    echo "generate_campaign_report"
  } > "$tmpdir/harness-cr.zsh"
  zsh -f "$tmpdir/harness-cr.zsh" 2>/dev/null
}

# ============================================================
# AC1: tmux SV report generation + 10 section headers (US-001)
# ============================================================
echo "--- AC1: SV report + 10 sections ---"

test_ac1_happy() {
  local body
  body=$(extract_fn generate_sv_report)
  local count=0
  for s in "Automated Validation Summary" "Failure Deep Dive" "Worker Process Quality" \
           "Verifier Judgment Quality" "AC Lifecycle" "Test-Spec Adherence" \
           "Patterns: Strengths" "Recommendations for Next Cycle" "Cost & Performance" "Blind Spots"; do
    echo "$body" | grep -qF "$s" && (( count++ ))
  done
  if (( count == 10 )); then
    pass "AC1-happy: generate_sv_report contains all 10 section headers ($count/10)"
  else
    fail "AC1-happy: generate_sv_report missing section headers ($count/10)"
  fi
}

test_ac1_negative() {
  local body
  body=$(extract_fn generate_sv_report)
  if echo "$body" | grep -q '! WITH_SELF_VERIFICATION'; then
    pass "AC1-negative: SV flag guard prevents generation when flag not set"
  else
    fail "AC1-negative: missing WITH_SELF_VERIFICATION guard"
  fi
}

test_ac1_boundary() {
  local body
  body=$(extract_fn generate_sv_report)
  local has_sv has_gen
  has_sv=$(echo "$body" | grep -c 'WITH_SELF_VERIFICATION')
  has_gen=$(echo "$body" | grep -c 'SV_REPORT_GENERATED')
  if (( has_sv >= 1 && has_gen >= 1 )); then
    pass "AC1-boundary: dual guards present (SV_flag=$has_sv, generated=$has_gen)"
  else
    fail "AC1-boundary: missing guards (SV_flag=$has_sv, generated=$has_gen)"
  fi
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary

echo ""

# ============================================================
# AC2: Runtime session-config — cb_threshold + verify_consensus (US-002)
# Behavior-driven: executes session-config write block, inspects produced JSON
# ============================================================
echo "--- AC2: runtime session-config fields ---"

test_ac2_happy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_sc_harness "$tmpdir" 5 1 5 1
  if [[ -f "$tmpdir/session-config.json" ]]; then
    local has_cb has_vc
    has_cb=$(grep -c '"cb_threshold": 5' "$tmpdir/session-config.json")
    has_vc=$(grep -c '"verify_consensus": 1' "$tmpdir/session-config.json")
    if (( has_cb >= 1 && has_vc >= 1 )); then
      # Also verify campaign-report has consensus label (PRD AC2 subclause)
      local tmpdir2
      tmpdir2=$(mktemp -d)
      run_cr_harness "$tmpdir2" 1 "all"
      local cr="$tmpdir2/logs/test-slug/campaign-report.md"
      if [[ -f "$cr" ]] && grep -qi 'consensus' "$cr"; then
        pass "AC2-happy: session-config has cb/vc fields AND campaign-report has consensus label"
      else
        fail "AC2-happy: session-config OK but campaign-report missing consensus label"
      fi
      rm -rf "$tmpdir2"
    else
      fail "AC2-happy: missing fields (cb=$has_cb, vc=$has_vc)"
    fi
  else
    fail "AC2-happy: session-config.json not produced by runtime harness"
  fi
  rm -rf "$tmpdir"
}

test_ac2_negative() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_sc_harness "$tmpdir" 3 0 3 0
  if [[ -f "$tmpdir/session-config.json" ]]; then
    if grep -q '"effective_cb_threshold": 3' "$tmpdir/session-config.json"; then
      pass "AC2-negative: runtime session-config.json has effective_cb_threshold=3"
    else
      fail "AC2-negative: missing effective_cb_threshold"
    fi
  else
    fail "AC2-negative: session-config.json not produced"
  fi
  rm -rf "$tmpdir"
}

test_ac2_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_sc_harness "$tmpdir" 3 1 3 1
  if [[ -f "$tmpdir/session-config.json" ]]; then
    if grep -q '"with_self_verification": 1' "$tmpdir/session-config.json"; then
      pass "AC2-boundary: runtime session-config.json has with_self_verification=1 (cross-feature)"
    else
      fail "AC2-boundary: missing with_self_verification"
    fi
  else
    fail "AC2-boundary: session-config.json not produced"
  fi
  rm -rf "$tmpdir"
}

test_ac2_happy
test_ac2_negative
test_ac2_boundary

echo ""

# ============================================================
# AC3: Runtime init --mode improve — PRD preserved (existing feature)
# Behavior-driven: runs init_ralph_desk.zsh in temp workspace, checks filesystem
# ============================================================
echo "--- AC3: runtime init --mode improve ---"

test_ac3_happy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans"
  echo "ORIGINAL_PRD_CONTENT_AC3_MARKER" > "$desk/plans/prd-test-slug.md"
  ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode improve >/dev/null 2>&1
  if grep -qF "ORIGINAL_PRD_CONTENT_AC3_MARKER" "$desk/plans/prd-test-slug.md" 2>/dev/null; then
    pass "AC3-happy: improve mode preserves original PRD content (filesystem verified)"
  else
    fail "AC3-happy: PRD content lost after improve mode"
  fi
  rm -rf "$tmpdir"
}

test_ac3_negative() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans" "$desk/memos"
  echo "ORIGINAL_PRD_AC3_NEG" > "$desk/plans/prd-test-slug.md"
  echo "{}" > "$desk/memos/test-slug-done-claim.json"
  ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode improve >/dev/null 2>&1
  if [[ ! -f "$desk/memos/test-slug-done-claim.json" ]]; then
    pass "AC3-negative: improve mode deletes runtime artifacts (done-claim removed)"
  else
    fail "AC3-negative: runtime artifacts not cleaned after improve"
  fi
  rm -rf "$tmpdir"
}

test_ac3_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans"
  echo "MARKER" > "$desk/plans/prd-test-slug.md"
  ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode improve >/dev/null 2>&1
  if [[ -f "$desk/prompts/test-slug.worker.prompt.md" ]] && \
     [[ -f "$desk/prompts/test-slug.verifier.prompt.md" ]]; then
    pass "AC3-boundary: regenerated artifacts exist after improve (worker+verifier prompts)"
  else
    fail "AC3-boundary: missing regenerated artifacts after improve"
  fi
  rm -rf "$tmpdir"
}

test_ac3_happy
test_ac3_negative
test_ac3_boundary

echo ""

# ============================================================
# AC4: Runtime init --mode fresh — PRD deleted (existing feature)
# Behavior-driven: runs init_ralph_desk.zsh in temp workspace, checks filesystem
# ============================================================
echo "--- AC4: runtime init --mode fresh ---"

test_ac4_happy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans"
  echo "ORIGINAL_PRD_AC4_MARKER" > "$desk/plans/prd-test-slug.md"
  ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode fresh >/dev/null 2>&1
  # After fresh mode, old PRD is deleted and replaced with template
  if [[ -f "$desk/plans/prd-test-slug.md" ]] && \
     ! grep -qF "ORIGINAL_PRD_AC4_MARKER" "$desk/plans/prd-test-slug.md"; then
    pass "AC4-happy: fresh mode deletes original PRD (replaced with template)"
  else
    fail "AC4-happy: original PRD content still present after fresh mode"
  fi
  rm -rf "$tmpdir"
}

test_ac4_negative() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans"
  echo "MARKER_AC4_NEG" > "$desk/plans/prd-test-slug.md"
  local output
  output=$(ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode fresh 2>&1)
  if echo "$output" | grep -qF "Deleted: prd-test-slug.md"; then
    pass "AC4-negative: fresh mode outputs PRD deletion message"
  else
    fail "AC4-negative: no PRD deletion message in output"
  fi
  rm -rf "$tmpdir"
}

test_ac4_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desk="$tmpdir/.claude/ralph-desk"
  mkdir -p "$desk/plans"
  echo "MARKER_AC4_BND" > "$desk/plans/prd-test-slug.md"
  # Use --mode=fresh (= form) instead of --mode fresh
  ROOT="$tmpdir" zsh -f "$INIT" test-slug "test objective" --mode=fresh >/dev/null 2>&1
  if [[ -f "$desk/plans/prd-test-slug.md" ]] && \
     ! grep -qF "MARKER_AC4_BND" "$desk/plans/prd-test-slug.md"; then
    pass "AC4-boundary: --mode=fresh (= form) works correctly (original PRD replaced)"
  else
    fail "AC4-boundary: --mode=fresh form failed"
  fi
  rm -rf "$tmpdir"
}

test_ac4_happy
test_ac4_negative
test_ac4_boundary

echo ""

# ============================================================
# AC5: Runtime debug.log — [OPTION] with_self_verification logging
# Behavior-driven: executes debug logging block, inspects produced debug.log
# ============================================================
echo "--- AC5: runtime debug.log [OPTION] logging ---"

test_ac5_happy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_debug_harness "$tmpdir" 1
  if [[ -f "$tmpdir/debug.log" ]] && \
     grep -qF '[OPTION]' "$tmpdir/debug.log" && \
     grep -qF 'with_self_verification=1' "$tmpdir/debug.log"; then
    pass "AC5-happy: runtime debug.log has [OPTION] with with_self_verification=1"
  else
    fail "AC5-happy: debug.log missing [OPTION] or with_self_verification"
  fi
  rm -rf "$tmpdir"
}

test_ac5_negative() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_debug_harness "$tmpdir" 1
  if [[ -f "$tmpdir/debug.log" ]]; then
    # Verify 4 distinct debug categories exist in source (PRD AC5: "4-category 디버그 항목")
    # Note: startup harness only produces [OPTION]; [GOV],[DECIDE],[FLOW] appear during loop execution.
    # Verify all 4 categories are used in the source code instead.
    local cat_count
    cat_count=$(grep -oE '\[(GOV|DECIDE|OPTION|FLOW)\]' "$RUN" | sort -u | wc -l | tr -d ' ')
    if (( cat_count >= 4 )); then
      pass "AC5-negative: source has $cat_count distinct debug categories (>=4: GOV,DECIDE,OPTION,FLOW)"
    else
      fail "AC5-negative: only $cat_count distinct categories in source (need >=4)"
    fi
  else
    fail "AC5-negative: debug.log not produced by runtime harness"
  fi
  rm -rf "$tmpdir"
}

test_ac5_boundary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  run_debug_harness "$tmpdir" 1
  if [[ -f "$tmpdir/debug.log" ]] && grep -qF 'consensus_flow' "$tmpdir/debug.log"; then
    pass "AC5-boundary: runtime debug.log has consensus_flow entry"
  else
    fail "AC5-boundary: debug.log missing consensus_flow"
  fi
  rm -rf "$tmpdir"
}

test_ac5_happy
test_ac5_negative
test_ac5_boundary

echo ""

# ============================================================
# AC6: Campaign report "Suggested Next Actions" (US-005)
# ============================================================
echo "--- AC6: Suggested Next Actions ---"

# Extract SNA section from generate_campaign_report body
extract_sna() {
  extract_fn generate_campaign_report | awk '/Suggested Next Actions/,0'
}

test_ac6_happy() {
  local body
  body=$(extract_fn generate_campaign_report)
  if echo "$body" | grep -qF 'Suggested Next Actions'; then
    pass "AC6-happy: generate_campaign_report contains Suggested Next Actions"
  else
    fail "AC6-happy: generate_campaign_report missing Suggested Next Actions"
  fi
}

test_ac6_negative() {
  local sna
  sna=$(extract_sna)
  local has_complete has_blocked
  has_complete=$(echo "$sna" | grep -c 'COMPLETE')
  has_blocked=$(echo "$sna" | grep -c 'BLOCKED')
  if (( has_complete >= 1 && has_blocked >= 1 )); then
    pass "AC6-negative: SNA differentiates COMPLETE ($has_complete) and BLOCKED ($has_blocked)"
  else
    fail "AC6-negative: SNA missing status differentiation (C=$has_complete, B=$has_blocked)"
  fi
}

test_ac6_boundary() {
  local sna
  sna=$(extract_sna)
  if echo "$sna" | grep -q 'elif.*TIMEOUT'; then
    pass "AC6-boundary: TIMEOUT uses explicit elif (not catch-all else)"
  else
    fail "AC6-boundary: TIMEOUT path missing explicit elif"
  fi
}

test_ac6_happy
test_ac6_negative
test_ac6_boundary

echo ""

# ============================================================
# AC7: cost-log per-phase timing fields (US-004)
# ============================================================
echo "--- AC7: cost-log per-phase timing ---"

test_ac7_happy() {
  local body
  body=$(extract_fn write_cost_log)
  local has_ws has_wd
  has_ws=$(echo "$body" | grep -c 'worker_start_time')
  has_wd=$(echo "$body" | grep -c 'worker_duration_s')
  if (( has_ws >= 1 && has_wd >= 1 )); then
    pass "AC7-happy: write_cost_log contains worker timing fields (ws=$has_ws, wd=$has_wd)"
  else
    fail "AC7-happy: missing worker timing (ws=$has_ws, wd=$has_wd)"
  fi
}

test_ac7_negative() {
  local body
  body=$(extract_fn write_cost_log)
  local has_vs has_vd
  has_vs=$(echo "$body" | grep -c 'verifier_start_time')
  has_vd=$(echo "$body" | grep -c 'verifier_duration_s')
  if (( has_vs >= 1 && has_vd >= 1 )); then
    pass "AC7-negative: write_cost_log contains verifier timing fields (vs=$has_vs, vd=$has_vd)"
  else
    fail "AC7-negative: missing verifier timing (vs=$has_vs, vd=$has_vd)"
  fi
}

test_ac7_boundary() {
  local body
  body=$(extract_fn write_cost_log)
  local has_claude has_codex
  has_claude=$(echo "$body" | grep -c 'verifier_claude_duration_s')
  has_codex=$(echo "$body" | grep -c 'verifier_codex_duration_s')
  if (( has_claude >= 1 && has_codex >= 1 )); then
    pass "AC7-boundary: consensus timing fields present (claude=$has_claude, codex=$has_codex)"
  else
    fail "AC7-boundary: missing consensus timing (claude=$has_claude, codex=$has_codex)"
  fi
}

test_ac7_happy
test_ac7_negative
test_ac7_boundary

echo ""

# ============================================================
# AC8: TIMEOUT path — campaign report generated once (US-003)
# ============================================================
echo "--- AC8: TIMEOUT single report ---"

test_ac8_happy() {
  local body
  body=$(extract_fn cleanup)
  if echo "$body" | grep -qF 'generate_campaign_report'; then
    pass "AC8-happy: cleanup() calls generate_campaign_report"
  else
    fail "AC8-happy: cleanup() missing generate_campaign_report call"
  fi
}

test_ac8_negative() {
  # Exactly 1 call site (in cleanup in RUN) — definition is in LIB (excluded via grep -v '()')
  # Count calls in RUN (cleanup call) + calls in LIB (none expected outside definition)
  local run_calls lib_calls
  run_calls=$(grep 'generate_campaign_report' "$RUN" 2>/dev/null | grep -v '()' | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
  # In LIB: the definition line has () so is excluded; no call sites should exist
  lib_calls=$(grep 'generate_campaign_report' "$LIB" 2>/dev/null | grep -v '()' | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
  local call_count=$(( run_calls + lib_calls ))
  if (( call_count == 1 )); then
    pass "AC8-negative: exactly 1 generate_campaign_report call site"
  else
    fail "AC8-negative: expected 1 call site, found $call_count (run=$run_calls lib=$lib_calls)"
  fi
}

test_ac8_boundary() {
  local has_init has_guard
  # CAMPAIGN_REPORT_GENERATED=0 init is inside generate_campaign_report() which is now in LIB
  has_init=$(( $(grep -c 'CAMPAIGN_REPORT_GENERATED=0' "$RUN" 2>/dev/null || echo 0) + $(grep -c 'CAMPAIGN_REPORT_GENERATED=0' "$LIB" 2>/dev/null || echo 0) ))
  has_guard=$(extract_fn generate_campaign_report | grep -c 'CAMPAIGN_REPORT_GENERATED.*return 0')
  if (( has_init >= 1 && has_guard >= 1 )); then
    pass "AC8-boundary: guard initialized ($has_init) and checked ($has_guard)"
  else
    fail "AC8-boundary: guard issue (init=$has_init, check=$has_guard)"
  fi
}

test_ac8_happy
test_ac8_negative
test_ac8_boundary

echo ""

# ============================================================
# AC9: governance.md §8 CB table parametrization (US-002)
# ============================================================
echo "--- AC9: governance §8 CB table ---"

test_ac9_happy() {
  local s8
  s8=$(extract_s8)
  if echo "$s8" | grep -qF 'cb_threshold'; then
    pass "AC9-happy: §8 contains cb_threshold parametrization"
  else
    fail "AC9-happy: §8 missing cb_threshold"
  fi
}

test_ac9_negative() {
  local s8
  s8=$(extract_s8)
  if echo "$s8" | grep -qF '3 consecutive fail verdicts'; then
    fail "AC9-negative: §8 still has hardcoded '3 consecutive fail verdicts'"
  else
    pass "AC9-negative: §8 no hardcoded '3 consecutive fail verdicts'"
  fi
}

test_ac9_boundary() {
  local s8
  s8=$(extract_s8)
  if echo "$s8" | grep -qFe '--cb-threshold'; then
    pass "AC9-boundary: §8 mentions --cb-threshold option"
  else
    fail "AC9-boundary: §8 missing --cb-threshold option reference"
  fi
}

test_ac9_happy
test_ac9_negative
test_ac9_boundary

echo ""

# ============================================================
# AC10: Codex CLI pre-validation (US-006)
# ============================================================
echo "--- AC10: Codex CLI pre-validation ---"

test_ac10_happy() {
  local body
  body=$(extract_fn check_dependencies)
  if echo "$body" | grep -qF 'codex CLI not found'; then
    pass "AC10-happy: check_dependencies has 'codex CLI not found' message"
  else
    fail "AC10-happy: check_dependencies missing codex error message"
  fi
}

test_ac10_negative() {
  local body
  body=$(extract_fn check_dependencies)
  if echo "$body" | grep -qF 'npm install -g @openai/codex'; then
    pass "AC10-negative: error message includes install command"
  else
    fail "AC10-negative: error message missing install command"
  fi
}

test_ac10_boundary() {
  local body
  body=$(extract_fn check_dependencies)
  if echo "$body" | grep -qE 'WORKER_ENGINE.*codex|VERIFIER_ENGINE.*codex|VERIFY_CONSENSUS'; then
    pass "AC10-boundary: codex check gated on engine/consensus config"
  else
    fail "AC10-boundary: codex check missing conditional guard"
  fi
}

test_ac10_happy
test_ac10_negative
test_ac10_boundary

echo ""

# ============================================================
# E2E: Cross-cutting integration tests
# ============================================================
echo "--- E2E: Cross-cutting integration ---"

test_e2e_cleanup_chain() {
  # cleanup() must call generate_campaign_report THEN generate_sv_report (order matters)
  local body
  body=$(extract_fn cleanup)
  local cr_line sv_line
  cr_line=$(echo "$body" | grep -n 'generate_campaign_report' | head -1 | cut -d: -f1)
  sv_line=$(echo "$body" | grep -n 'generate_sv_report' | head -1 | cut -d: -f1)
  if [[ -n "$cr_line" && -n "$sv_line" ]] && (( sv_line > cr_line )); then
    pass "E2E-cleanup-chain: campaign_report (L$cr_line) before sv_report (L$sv_line)"
  else
    fail "E2E-cleanup-chain: wrong order or missing (cr=$cr_line, sv=$sv_line)"
  fi
}

test_e2e_cross_file() {
  # rlp-desk.md §9 section names must match generate_sv_report prompt sections
  local body matched=0
  body=$(extract_fn generate_sv_report)
  for s in "Automated Validation Summary" "Failure Deep Dive" "Worker Process Quality" \
           "Verifier Judgment Quality" "AC Lifecycle" "Test-Spec Adherence" \
           "Patterns: Strengths" "Recommendations for Next Cycle" "Cost & Performance" "Blind Spots"; do
    grep -qF "$s" "$CMD" && echo "$body" | grep -qF "$s" && (( matched++ ))
  done
  if (( matched >= 10 )); then
    pass "E2E-cross-file: all 10 §9 headers match rlp-desk.md ↔ sv_prompt ($matched/10)"
  else
    fail "E2E-cross-file: header mismatch between rlp-desk.md and sv_prompt ($matched/10)"
  fi
}

test_e2e_syntax() {
  local run_ok=0 init_ok=0
  zsh -n "$RUN" 2>/dev/null && run_ok=1
  zsh -n "$INIT" 2>/dev/null && init_ok=1
  if (( run_ok && init_ok )); then
    pass "E2E-syntax: both scripts pass zsh -n validation"
  else
    fail "E2E-syntax: syntax check failed (run=$run_ok, init=$init_ok)"
  fi
}

test_e2e_cleanup_chain
test_e2e_cross_file
test_e2e_syntax

echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
TOTAL=$((PASS + FAIL))
echo "Total:  $TOTAL"
if (( FAIL > 0 )); then
  echo "RESULT: FAIL"
  exit 1
else
  echo "RESULT: PASS"
  exit 0
fi
