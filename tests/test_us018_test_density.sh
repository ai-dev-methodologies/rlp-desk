#!/usr/bin/env bash
# Test Suite: US-018 — R6 P1-F Test-spec Density Enforcement (≥3 tests/AC)
# Validates:
#   - --test-density-strict CLI flag (zsh + Node)
#   - _lint_test_density helper in init_ralph_desk.zsh (or lib)
#   - WARN default: ratio<3 → init exit=0 + audit log + visible stderr warning
#   - STRICT: ratio<3 → init exit=1 + visible warning
#   - governance §7f Test Density Enforcement section

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
RUN_NODE="$ROOT_REPO/src/node/run.mjs"
GOV="$ROOT_REPO/src/governance.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  local file="$1" pat="$2" n
  n=$(grep -cE -- "$pat" "$file" 2>/dev/null) || n=0
  printf '%s' "$n"
}
assert_one() {
  local n; n=$(_match_count "$1" "$2")
  [[ "$n" -ge 1 ]] && pass "$3" || fail "$3 (matches=0)"
}

echo "=== US-018: R6 P1-F Test Density Enforcement ==="
echo

# AC1: zsh runner --test-density-strict flag
assert_one "$RUN" '\-\-test-density-strict\)' \
  "AC1-a: zsh runner parses --test-density-strict CLI flag"
assert_one "$RUN" 'TEST_DENSITY_MODE="strict"' \
  "AC1-b: --test-density-strict sets TEST_DENSITY_MODE=strict"
assert_one "$RUN" 'TEST_DENSITY_MODE="\$\{TEST_DENSITY_MODE:-warn\}"' \
  "AC1-c: TEST_DENSITY_MODE variable initialized (default warn)"

# AC2: Node run.mjs --test-density-strict stub
assert_one "$RUN_NODE" 'testDensityStrict: false' \
  "AC2-a: RUN_DEFAULTS includes testDensityStrict default"
assert_one "$RUN_NODE" "case '--test-density-strict':" \
  "AC2-b: --test-density-strict CLI parser case present"

# AC3: _lint_test_density helper defined in init or lib
helper_in_init=$(grep -c '_lint_test_density' "$INIT" 2>/dev/null | head -1)
helper_in_lib=$(grep -c '_lint_test_density' "$LIB" 2>/dev/null | head -1)
[[ -z "$helper_in_init" ]] && helper_in_init=0
[[ -z "$helper_in_lib" ]] && helper_in_lib=0
helper_total=$((helper_in_init + helper_in_lib))
[[ "$helper_total" -ge 1 ]] && pass "AC3: _lint_test_density helper defined (init=$helper_in_init lib=$helper_in_lib)" \
                            || fail "AC3: _lint_test_density helper not found"

# AC4: governance §7f Test Density Enforcement section
assert_one "$GOV" '## 7f\. Test Density Enforcement' \
  "AC4-a: §7f Test Density Enforcement section present"
assert_one "$GOV" 'WARN.default' \
  "AC4-b: §7f clarifies WARN default"
assert_one "$GOV" 'happy.*negative.*boundary' \
  "AC4-c: §7f references happy+negative+boundary categories"

# AC5: behavioural — _lint_test_density on bad fixture (1 test for 3 ACs)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us018-XXXX")
PRD_BAD="$TMP_DIR/prd-bad.md"
SPEC_BAD="$TMP_DIR/test-spec-bad.md"

cat > "$PRD_BAD" <<'EOF'
# PRD

## US-001: Sample
- AC1: do thing one
- AC2: do thing two
- AC3: do thing three
EOF

cat > "$SPEC_BAD" <<'EOF'
# Test Spec

## US-001: Sample
### Test 1: covers AC1
EOF

# Invoke helper via zsh fixture (lib only — init has runnable side effects)
result=$(zsh -c "
  LOGS_DIR='$TMP_DIR'
  source '$LIB' 2>/dev/null
  _lint_test_density '$PRD_BAD' '$SPEC_BAD' 'warn' 2>&1
  echo \"EXIT=\$?\"
" 2>/dev/null)

if echo "$result" | grep -q "Test density warning\|test_density_warning\|density.*warn"; then
  pass "AC5-a: _lint_test_density emits warning for bad fixture (1 test / 3 ACs)"
else
  fail "AC5-a: warning not emitted (output: $(echo "$result" | head -3))"
fi

if echo "$result" | grep -q "EXIT=0"; then
  pass "AC5-b: WARN mode exits 0 (non-fatal)"
else
  fail "AC5-b: WARN should exit 0 (output: $result)"
fi

# AC6: STRICT mode → exit 1
result_strict=$(zsh -c "
  LOGS_DIR='$TMP_DIR'
  source '$LIB' 2>/dev/null
  _lint_test_density '$PRD_BAD' '$SPEC_BAD' 'strict' 2>&1
  echo \"EXIT=\$?\"
" 2>/dev/null)

if echo "$result_strict" | grep -q "EXIT=1"; then
  pass "AC6: STRICT mode exits 1 for bad fixture"
else
  fail "AC6: STRICT should exit 1 (output: $result_strict)"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
