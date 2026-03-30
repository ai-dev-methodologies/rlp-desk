#!/usr/bin/env bash
# Test suite: US-010 — Live PRD Update Detection + Documentation
# AC1 (3) + AC2 (3) + AC3 (3) + AC4 (3) + AC5 (3) + E2E (3) = 18 total
# RED tests (fail before impl): AC1-*, AC2-*, AC3-*, AC4-*, AC5-*, E2E-detect, E2E-unchanged
# Regression tests (pass before and after): E2E-syntax

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
README="${README:-README.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-010: Live PRD Update Detection + Documentation ==="
echo "Target: $RUN"
echo ""

# Helper: extract function body by name from source
extract_fn() {
  local fn_name="$1"
  local src="${2:-$RUN}"
  awk -v fn="$fn_name" '
    $0 ~ fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$src"
}

# ============================================================
# AC1: PRD change detection (compute_prd_hash + check_prd_update)
# ============================================================
echo "--- AC1: PRD change detection ---"

# AC1-happy: compute_prd_hash() function exists
test_ac1_happy() {
  if grep -qF 'compute_prd_hash()' "$RUN"; then
    pass "AC1-happy: compute_prd_hash() function exists"
  else
    fail "AC1-happy: compute_prd_hash() function missing"
  fi
}

# AC1-negative: check_prd_update() compares with PREV_PRD_HASH and logs prd_changed=true + prd_hash
test_ac1_negative() {
  local body
  body=$(extract_fn "check_prd_update")
  local checks=0
  echo "$body" | grep -q 'PREV_PRD_HASH' && (( checks++ ))
  echo "$body" | grep -q 'prd_changed=true' && (( checks++ ))
  echo "$body" | grep -q 'prd_hash_prev=' && (( checks++ ))
  echo "$body" | grep -q 'prd_hash_now=' && (( checks++ ))
  if (( checks >= 4 )); then
    pass "AC1-negative: check_prd_update compares hash and logs change ($checks/4)"
  else
    fail "AC1-negative: check_prd_update missing hash comparison/logging ($checks/4)"
  fi
}

# AC1-boundary: handles missing PRD file gracefully (no crash)
test_ac1_boundary() {
  local body
  body=$(extract_fn "compute_prd_hash")
  if echo "$body" | grep -qE '\-f.*prd|no-prd'; then
    pass "AC1-boundary: compute_prd_hash handles missing PRD file"
  else
    fail "AC1-boundary: compute_prd_hash missing PRD file guard"
  fi
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary

# ============================================================
# AC2: US count change detection
# ============================================================
echo ""
echo "--- AC2: US count change detection ---"

# AC2-happy: check_prd_update logs us_count_prev and us_count_now
test_ac2_happy() {
  local body
  body=$(extract_fn "check_prd_update")
  local checks=0
  echo "$body" | grep -q 'us_count_prev=' && (( checks++ ))
  echo "$body" | grep -q 'us_count_now=' && (( checks++ ))
  if (( checks >= 2 )); then
    pass "AC2-happy: check_prd_update logs us_count_prev and us_count_now ($checks/2)"
  else
    fail "AC2-happy: check_prd_update missing US count logging ($checks/2)"
  fi
}

# AC2-negative: logs new_us with specific US IDs
test_ac2_negative() {
  local body
  body=$(extract_fn "check_prd_update")
  if echo "$body" | grep -q 'new_us='; then
    pass "AC2-negative: check_prd_update logs new_us"
  else
    fail "AC2-negative: check_prd_update missing new_us logging"
  fi
}

# AC2-boundary: US extraction uses grep -oE 'US-[0-9]+' pattern (consistent with existing code)
test_ac2_boundary() {
  local body
  body=$(extract_fn "count_prd_us")
  if echo "$body" | grep -qE "grep.*US-\[0-9\]"; then
    pass "AC2-boundary: count_prd_us uses US-[0-9]+ pattern"
  else
    fail "AC2-boundary: count_prd_us missing US-[0-9]+ extraction pattern"
  fi
}

test_ac2_happy
test_ac2_negative
test_ac2_boundary

# ============================================================
# AC3: Worker prompt notification
# ============================================================
echo ""
echo "--- AC3: Worker prompt notification ---"

# AC3-happy: write_worker_trigger includes PRD change NOTE
test_ac3_happy() {
  local body
  body=$(extract_fn "write_worker_trigger")
  if echo "$body" | grep -q 'PRD was updated'; then
    pass "AC3-happy: write_worker_trigger includes PRD change NOTE"
  else
    fail "AC3-happy: write_worker_trigger missing PRD change NOTE"
  fi
}

# AC3-negative: NOTE text matches spec exactly
test_ac3_negative() {
  local body
  body=$(extract_fn "write_worker_trigger")
  if echo "$body" | grep -qF 'NOTE: PRD was updated since last iteration. New/changed US may exist.'; then
    pass "AC3-negative: NOTE text matches spec exactly"
  else
    fail "AC3-negative: NOTE text does not match spec"
  fi
}

# AC3-boundary: NOTE injection is conditional on _PRD_CHANGED
test_ac3_boundary() {
  local body
  body=$(extract_fn "write_worker_trigger")
  if echo "$body" | grep -q '_PRD_CHANGED'; then
    pass "AC3-boundary: NOTE injection conditional on _PRD_CHANGED flag"
  else
    fail "AC3-boundary: NOTE injection not conditional on _PRD_CHANGED"
  fi
}

test_ac3_happy
test_ac3_negative
test_ac3_boundary

# ============================================================
# AC4: No action when PRD unchanged
# ============================================================
echo ""
echo "--- AC4: No action when unchanged ---"

# AC4-happy: check_prd_update uses != to detect change (logs only on mismatch)
test_ac4_happy() {
  local body
  body=$(extract_fn "check_prd_update")
  if echo "$body" | grep -qE 'current_hash.*!=.*PREV_PRD_HASH|PREV_PRD_HASH.*!=.*current_hash'; then
    pass "AC4-happy: check_prd_update compares hashes with != operator"
  else
    fail "AC4-happy: check_prd_update missing hash inequality comparison"
  fi
}

# AC4-negative: _PRD_CHANGED is reset to 0 at start of check_prd_update
test_ac4_negative() {
  local body
  body=$(extract_fn "check_prd_update")
  if echo "$body" | grep -qE '_PRD_CHANGED=0'; then
    pass "AC4-negative: _PRD_CHANGED reset to 0 at function start"
  else
    fail "AC4-negative: _PRD_CHANGED not reset to 0"
  fi
}

# AC4-boundary: PREV_PRD_HASH initialized before loop (first iteration won't false-trigger)
test_ac4_boundary() {
  if grep -q 'PREV_PRD_HASH=.*compute_prd_hash' "$RUN"; then
    pass "AC4-boundary: PREV_PRD_HASH initialized before loop"
  else
    fail "AC4-boundary: PREV_PRD_HASH not initialized before loop"
  fi
}

test_ac4_happy
test_ac4_negative
test_ac4_boundary

# ============================================================
# AC5: README documentation
# ============================================================
echo ""
echo "--- AC5: README documentation ---"

# AC5-happy: README.md has "Live PRD Update" section
test_ac5_happy() {
  if grep -qE '^#{1,3} .*Live PRD Update' "$README"; then
    pass "AC5-happy: README has Live PRD Update section"
  else
    fail "AC5-happy: README missing Live PRD Update section"
  fi
}

# AC5-negative: section explains detection mechanism (md5/checksum/hash)
test_ac5_negative() {
  local section
  section=$(awk '/^#{1,3} .*Live PRD Update/,/^#{1,3} [^L]/' "$README" 2>/dev/null | head -30)
  if echo "$section" | grep -qi 'md5\|checksum\|hash'; then
    pass "AC5-negative: Live PRD Update section explains detection mechanism"
  else
    fail "AC5-negative: Live PRD Update section missing detection mechanism explanation"
  fi
}

# AC5-boundary: section mentions graceful degradation / non-halting behavior
test_ac5_boundary() {
  local section
  section=$(awk '/^#{1,3} .*Live PRD Update/,/^#{1,3} [^L]/' "$README" 2>/dev/null | head -30)
  if echo "$section" | grep -qi 'graceful\|fail.*safe\|not.*halt\|continue\|does not stop'; then
    pass "AC5-boundary: Live PRD Update section mentions graceful behavior"
  else
    fail "AC5-boundary: Live PRD Update section missing graceful degradation info"
  fi
}

test_ac5_happy
test_ac5_negative
test_ac5_boundary

# ============================================================
# E2E: Runtime harness + syntax
# ============================================================
echo ""
echo "--- E2E ---"

# E2E-detect: runtime harness — check_prd_update detects changed PRD
test_e2e_detect() {
  local tmpdir
  tmpdir=$(mktemp -d)

  # Build harness
  local harness="$tmpdir/harness.zsh"
  cat > "$harness" << 'HARNESS_HEAD'
#!/usr/bin/env zsh
DEBUG=1
ITERATION=2
DEBUG_LOG="$1/debug.log"
DESK="$1/desk"
SLUG="test"
mkdir -p "$DESK/plans" "$(dirname "$DEBUG_LOG")"

log_debug() {
  echo "$*" >> "$DEBUG_LOG"
}
HARNESS_HEAD

  # Extract required functions
  extract_fn "compute_prd_hash" >> "$harness"
  extract_fn "count_prd_us" >> "$harness"
  extract_fn "check_prd_update" >> "$harness"

  # Create initial PRD
  mkdir -p "$tmpdir/desk/plans"
  cat > "$tmpdir/desk/plans/prd-test.md" << 'PRD1'
### US-001: First Story
### US-002: Second Story
PRD1

  # Initialize + modify + check
  cat >> "$harness" << 'RUN_BLOCK'
PREV_PRD_HASH=$(compute_prd_hash)
PREV_PRD_US_LIST=$(count_prd_us)

# Simulate PRD change between iterations (add US-003)
cat > "$DESK/plans/prd-test.md" << 'PRD2'
### US-001: First Story
### US-002: Second Story
### US-003: Third Story
PRD2

check_prd_update
RUN_BLOCK

  local output
  output=$(zsh -f "$harness" "$tmpdir" 2>&1)

  if [[ -f "$tmpdir/debug.log" ]]; then
    local log_content
    log_content=$(cat "$tmpdir/debug.log")
  local checks=0
    echo "$log_content" | grep -q 'prd_changed=true' && (( checks++ ))
    echo "$log_content" | grep -q 'us_count_prev=2' && (( checks++ ))
    echo "$log_content" | grep -q 'us_count_now=3' && (( checks++ ))
    echo "$log_content" | grep -q 'new_us=.*US-003' && (( checks++ ))
    echo "$log_content" | grep -q 'prd_hash_prev=' && (( checks++ ))
    echo "$log_content" | grep -q 'prd_hash_now=' && (( checks++ ))
    if (( checks >= 6 )); then
      pass "E2E-detect: PRD change detected correctly ($checks/6 checks)"
    else
      fail "E2E-detect: PRD change detection incomplete ($checks/6). Log: $log_content"
    fi
  else
    fail "E2E-detect: debug.log not created"
  fi

  rm -rf "$tmpdir"
}

# E2E-unchanged: runtime harness — no prd_changed log when PRD unchanged
test_e2e_unchanged() {
  local tmpdir
  tmpdir=$(mktemp -d)

  local harness="$tmpdir/harness.zsh"
  cat > "$harness" << 'HARNESS_HEAD'
#!/usr/bin/env zsh
DEBUG=1
ITERATION=2
DEBUG_LOG="$1/debug.log"
DESK="$1/desk"
SLUG="test"
mkdir -p "$DESK/plans" "$(dirname "$DEBUG_LOG")"

log_debug() {
  echo "$*" >> "$DEBUG_LOG"
}
HARNESS_HEAD

  extract_fn "compute_prd_hash" >> "$harness"
  extract_fn "count_prd_us" >> "$harness"
  extract_fn "check_prd_update" >> "$harness"

  # Create PRD (will NOT be modified)
  mkdir -p "$tmpdir/desk/plans"
  cat > "$tmpdir/desk/plans/prd-test.md" << 'PRD1'
### US-001: First Story
### US-002: Second Story
PRD1

  cat >> "$harness" << 'RUN_BLOCK'
PREV_PRD_HASH=$(compute_prd_hash)
PREV_PRD_US_LIST=$(count_prd_us)
# No modification — PRD is unchanged
check_prd_update
RUN_BLOCK

  zsh -f "$harness" "$tmpdir" 2>&1

  if [[ -f "$tmpdir/debug.log" ]]; then
    if grep -q 'prd_changed=true' "$tmpdir/debug.log"; then
      fail "E2E-unchanged: false positive — prd_changed=true logged for unchanged PRD"
    else
      pass "E2E-unchanged: no prd_changed logged for unchanged PRD"
    fi
  else
    # No debug.log = nothing logged = correct
    pass "E2E-unchanged: no debug.log created (no changes detected)"
  fi

  rm -rf "$tmpdir"
}

# E2E-syntax: zsh -n syntax check
test_e2e_syntax() {
  if zsh -n "$RUN" 2>/dev/null; then
    pass "E2E-syntax: zsh -n syntax check passes"
  else
    fail "E2E-syntax: zsh -n syntax check failed"
  fi
}

test_e2e_detect
test_e2e_unchanged
test_e2e_syntax

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
