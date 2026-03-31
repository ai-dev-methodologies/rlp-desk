#!/usr/bin/env bash
# Test Suite: Batch Mode Partial Progress Tracking
# Tests: per_us_results parsing, VERIFIED_US update on FAIL, CF reset on progress,
#        fix contract scope narrowing, verifier prompt VERIFIED_US in batch mode,
#        worker prompt batch partial progress guidance

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

extract_fn() {
  local fn_name="$1" file="${2:-$LIB}"
  sed -n "/^${fn_name}() {$/,/^}$/p" "$file" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    sed -n "/^${fn_name}() {$/,/^}$/p" "$RUN" 2>/dev/null
  fi
}

run_harness() {
  local script="$1"
  zsh -c "$script" 2>&1
}

echo "=== Batch Partial Progress Tracking ==="
echo ""

# --- AC1: PASS verdict tracks VERIFIED_US for both modes ---
echo "--- AC1: VERIFIED_US tracking mode-independent ---"

# Check that PASS verdict code no longer requires per-us mode
grep -q 'VERIFY_MODE.*=.*per-us.*signal_us_id' "$RUN" 2>/dev/null
if (( $? == 0 )); then
  # Old pattern found — check it's not the tracking line
  old_pattern=$(grep -n 'VERIFY_MODE.*=.*per-us.*signal_us_id.*!= "ALL"' "$RUN" 2>/dev/null | head -1)
  if [[ -n "$old_pattern" ]]; then
    fail "AC1-1: VERIFIED_US tracking still gated by per-us mode"
  else
    pass "AC1-1: VERIFIED_US tracking not gated by per-us mode"
  fi
else
  pass "AC1-1: VERIFIED_US tracking not gated by per-us mode"
fi

# Check new pattern: the if-condition line itself must NOT contain VERIFY_MODE
if grep -q 'signal_us_id" != "ALL"' "$RUN" 2>/dev/null; then
  condition_line=$(grep 'signal_us_id" != "ALL"' "$RUN" | head -1)
  if echo "$condition_line" | grep -q 'VERIFY_MODE'; then
    fail "AC1-2: VERIFIED_US if-condition still includes VERIFY_MODE gate"
  else
    pass "AC1-2: VERIFIED_US updated when signal_us_id is specific (mode-independent)"
  fi
else
  fail "AC1-2: VERIFIED_US update pattern not found"
fi

# --- AC2: FAIL verdict parses per_us_results ---
echo ""
echo "--- AC2: FAIL verdict per_us_results parsing ---"

if grep -q 'per_us_results' "$RUN" 2>/dev/null; then
  pass "AC2-1: per_us_results parsing present in run script"
else
  fail "AC2-1: per_us_results parsing not found in run script"
fi

if grep -q 'jq.*per_us_results.*pass' "$RUN" 2>/dev/null; then
  pass "AC2-2: jq extraction of pass status from per_us_results"
else
  fail "AC2-2: jq per_us_results pass extraction not found"
fi

# Test actual jq parsing of per_us_results
tmpverdict=$(mktemp)
cat > "$tmpverdict" <<'JSONEOF'
{
  "verdict": "fail",
  "per_us_results": {"US-001": "pass", "US-002": "pass", "US-003": "fail", "US-004": "not_started"},
  "issues": [{"severity": "major", "description": "US-003 tests fail"}]
}
JSONEOF

newly_passed=$(jq -r '.per_us_results | to_entries[] | select(.value == "pass") | .key' "$tmpverdict" 2>/dev/null | sort | tr '\n' ',')
if [[ "$newly_passed" == "US-001,US-002," ]]; then
  pass "AC2-3: jq correctly extracts passed US from per_us_results"
else
  fail "AC2-3: jq extraction wrong (got '$newly_passed', expected 'US-001,US-002,')"
fi
rm -f "$tmpverdict"

# --- AC3: Consecutive failures reset on partial progress ---
echo ""
echo "--- AC3: CF reset on partial progress ---"

if grep -q 'VERIFIED_US.*_prev_verified.*CONSECUTIVE_FAILURES=0' "$RUN" 2>/dev/null; then
  pass "AC3-1: CF reset logic when VERIFIED_US changes"
elif grep -A2 '_prev_verified' "$RUN" 2>/dev/null | grep -q 'CONSECUTIVE_FAILURES=0'; then
  pass "AC3-1: CF reset logic when VERIFIED_US changes"
else
  fail "AC3-1: CF reset on partial progress not found"
fi

if grep -q '_prev_verified.*VERIFIED_US' "$RUN" 2>/dev/null; then
  pass "AC3-2: Previous VERIFIED_US snapshot saved for comparison"
else
  fail "AC3-2: _prev_verified snapshot not found"
fi

# --- AC4: Fix contract includes VERIFIED_US ---
echo ""
echo "--- AC4: Fix contract scope narrowing ---"

if grep -q 'VERIFIED_US.*do NOT re-implement\|Verified US.*do NOT' "$RUN" 2>/dev/null; then
  pass "AC4-1: Fix contract includes verified US exclusion"
else
  fail "AC4-1: Fix contract verified US exclusion not found"
fi

if grep -q 'Focus ONLY on unverified' "$RUN" 2>/dev/null; then
  pass "AC4-2: Fix contract directs Worker to unverified stories only"
else
  fail "AC4-2: Fix contract scope narrowing text not found"
fi

# --- AC5: Verifier prompt passes VERIFIED_US in batch mode ---
echo ""
echo "--- AC5: Verifier prompt VERIFIED_US (batch-inclusive) ---"

# Old pattern: gated by per-us
if grep -q 'VERIFY_MODE.*per-us.*us_id.*Scope' "$RUN" 2>/dev/null; then
  fail "AC5-1: Verifier prompt scope still gated by per-us mode"
else
  pass "AC5-1: Verifier prompt scope not gated by per-us mode"
fi

# New pattern: VERIFIED_US passed when non-empty
if grep -q 'VERIFIED_US.*Previously verified US\|Previously verified US.*VERIFIED_US' "$RUN" 2>/dev/null; then
  pass "AC5-2: Verifier prompt includes previously verified US"
else
  fail "AC5-2: VERIFIED_US not found in verifier prompt generation"
fi

if grep -q 'Skip re-verifying' "$RUN" 2>/dev/null; then
  pass "AC5-3: Verifier instructed to skip re-verifying passed US"
else
  fail "AC5-3: Skip re-verify instruction not found"
fi

# --- AC6: Worker prompt batch partial progress ---
echo ""
echo "--- AC6: Worker prompt batch partial progress ---"

if grep -q 'BATCH MODE.*CONTINUE FROM PARTIAL PROGRESS' "$RUN" 2>/dev/null; then
  pass "AC6-1: Batch partial progress section exists in worker prompt"
else
  fail "AC6-1: Batch partial progress section not found"
fi

if grep -q 'Do NOT re-implement.*done' "$RUN" 2>/dev/null; then
  pass "AC6-2: Worker told not to re-implement verified US"
else
  fail "AC6-2: Worker re-implement exclusion not found"
fi

# --- AC7: Verifier verdict per_us_results required ---
echo ""
echo "--- AC7: Verifier verdict per_us_results format ---"

INIT="$ROOT_DIR/src/scripts/init_ralph_desk.zsh"
if grep -q 'per_us_results.*pass.*fail.*not_started' "$INIT" 2>/dev/null; then
  pass "AC7-1: per_us_results format defined in verifier prompt template"
else
  fail "AC7-1: per_us_results format not found in init verifier template"
fi

if grep -q 'ALWAYS include per_us_results' "$INIT" 2>/dev/null; then
  pass "AC7-2: per_us_results marked as mandatory in verifier rules"
else
  fail "AC7-2: per_us_results mandatory rule not found"
fi

# --- L2: syntax check ---
echo ""
echo "--- L2: Syntax ---"

zsh -n "$RUN" 2>/dev/null
if (( $? == 0 )); then
  pass "L2-1: run_ralph_desk.zsh syntax valid"
else
  fail "L2-1: run_ralph_desk.zsh syntax error"
fi

zsh -n "$INIT" 2>/dev/null
if (( $? == 0 )); then
  pass "L2-2: init_ralph_desk.zsh syntax valid"
else
  fail "L2-2: init_ralph_desk.zsh syntax error"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS+FAIL))) ==="
exit $FAIL
