#!/usr/bin/env bash
# Test Suite: US-002 — governance.md §8 CB Table Parametrization
# IL-4: 3+ tests per AC (happy + negative + boundary)
# AC1 x 4 + AC2 x 3 = 7 tests + 3 regression = 10 total

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOV="$ROOT/src/governance.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Extract §8 section: lines from "## 8. Circuit Breaker" up to (not including) "## 9."
section8() { awk '/^## 8\. Circuit Breaker/,/^## 9\./' "$GOV"; }

# Extract §7¾ section: lines from "## 7¾." up to (not including) "## 8."
section7q() { awk '/^## 7¾\./,/^## 8\./' "$GOV"; }

s8_contains() { section8 | grep -qFe "$1" 2>/dev/null && echo 1 || echo 0; }
# count occurrences (not lines) using grep -o so two hits on same line = 2
s8_count()    { section8 | grep -oF "$1" 2>/dev/null | wc -l | tr -d ' '; }
s7q_count()   { section7q | grep -oF "$1" 2>/dev/null | wc -l | tr -d ' '; }

assert_one() {
  local val="$1" label="$2"
  if [[ "$val" -ge 1 ]]; then pass "$label"; else fail "$label (got $val, expected >=1)"; fi
}
assert_zero() {
  local val="$1" label="$2"
  if [[ "$val" -eq 0 ]]; then pass "$label"; else fail "$label (got $val, expected 0)"; fi
}
assert_ge() {
  local val="$1" min="$2" label="$3"
  if [[ "$val" -ge "$min" ]]; then pass "$label"; else fail "$label (got $val, expected >=$min)"; fi
}

echo "=== US-002: governance.md §8 CB Table Parametrization ==="
echo ""

# ============================================================
# AC1: Path B row parametrized (cb_threshold replaces hardcoded 3)
# ============================================================

# AC1-happy: Path B row (Upgrade to opus) now contains cb_threshold (parametrized)
val=$(section8 | grep -F 'Upgrade to opus' | grep -cF 'cb_threshold' 2>/dev/null; true)
assert_one "$val" "AC1-happy: Path B row (Upgrade to opus) contains cb_threshold"

# AC1-negative: old hardcoded "3 consecutive **fail** verdicts" NOT in §8 table
val=$(s8_count '3 consecutive **fail** verdicts')
assert_zero "$val" "AC1-negative: '3 consecutive **fail** verdicts' removed from §8 table"

# AC1-boundary: cb_threshold appears at least twice in §8 (consecutive + unique criterion)
val=$(s8_count 'cb_threshold')
assert_ge "$val" 2 "AC1-boundary: cb_threshold referenced >= 2 times in §8 section"

# AC1-cb-option: §8 Path B row explicitly mentions --cb-threshold option adjustability
val=$(s8_contains '--cb-threshold')
assert_one "$val" "AC1-cb-option: §8 mentions '--cb-threshold' option for adjustability"

# ============================================================
# AC2: Path A row annotated with Agent-mode + tmux note
# ============================================================

# AC2-happy: "Agent mode only" annotation in §8 Path A row
val=$(s8_contains 'Agent mode only')
assert_one "$val" "AC2-happy: 'Agent mode only' annotation in §8 table Path A row"

# AC2-negative: "tmux: same model retry" annotation in §8 Path A row
val=$(s8_contains 'tmux: same model retry')
assert_one "$val" "AC2-negative: 'tmux: same model retry' annotation in §8 table Path A row"

# AC2-boundary: Path A existing content preserved (2 consecutive iterations still present)
val=$(s8_contains 'Same acceptance criterion fails 2 consecutive')
assert_one "$val" "AC2-boundary: Path A 'Same acceptance criterion fails 2 consecutive' preserved"

# ============================================================
# Regression: §7¾ and other sections unchanged
# ============================================================

# Reg-1: §7¾ "Path A: Agent-mode only" note still present (not modified by our change)
val=$(s7q_count 'Path A: Agent-mode only')
assert_one "$val" "Reg-1: §7¾ 'Path A: Agent-mode only' note still present"

# Reg-2: §8 section header intact
val=$(grep -cF '## 8. Circuit Breaker' "$GOV" 2>/dev/null || echo 0)
assert_one "$val" "Reg-2: §8 Circuit Breaker section header intact"

# Reg-3: §7¾ cb_threshold references still present (§7¾ not broken)
val=$(s7q_count 'cb_threshold')
assert_ge "$val" 2 "Reg-3: §7¾ cb_threshold references still present (>= 2)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
