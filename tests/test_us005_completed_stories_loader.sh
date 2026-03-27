#!/usr/bin/env bash
# Test Suite: US-005 — Backport Completed Stories Loader
# IL-4: 3+ tests per AC (happy + negative + boundary)
# 2 ACs x 3 = 6 tests minimum + 1 L3 E2E = 7 total

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

grep_count() {
  local n
  n=$(grep -c "$1" "$2" 2>/dev/null) || n=0
  echo "$n"
}
grep_exists() { grep -q "$1" "$2" 2>/dev/null && echo 1 || echo 0; }

assert_eq() {
  local val="$1" expected="$2" label="$3"
  if [[ "$val" -eq "$expected" ]]; then pass "$label"; else fail "$label (got $val, expected $expected)"; fi
}
assert_ge() {
  local val="$1" min="$2" label="$3"
  if [[ "$val" -ge "$min" ]]; then pass "$label"; else fail "$label (got $val, expected >=$min)"; fi
}
assert_zero() { assert_eq "$1" 0 "$2"; }

echo "=== US-005: Backport Completed Stories Loader ==="
echo ""

# ============================================================
# AC1: Feature backport — memory-loading logic present in source
# ============================================================

# AC1-happy: 'completed_us' variable appears >= 2 times (assignment + log ref)
count=$(grep_count 'completed_us' "$RUN")
assert_ge "$count" 2 "AC1-happy: 'completed_us' appears >= 2 times in run_ralph_desk.zsh"

# AC1-negative: 'Completed Stories' section header is referenced in source
count=$(grep_count 'Completed Stories' "$RUN")
assert_ge "$count" 1 "AC1-negative: 'Completed Stories' section header referenced in run_ralph_desk.zsh"

# AC1-boundary: loader is inside the per-us VERIFY_MODE block (not unconditional)
exists=$(grep_exists 'per-us' "$RUN")
assert_eq "$exists" 1 "AC1-boundary: 'per-us' VERIFY_MODE guard present (loader must be conditional)"

# ============================================================
# AC2: Functional parity — exact macOS-compatible sed pipeline
# ============================================================

# AC2-happy: sed -n range extraction step present (macOS-compatible, not nested)
exists=$(grep_exists "sed -n '/\^## Completed Stories\$/,/\^## /p'" "$RUN")
assert_eq "$exists" 1 "AC2-happy: sed -n range pipeline step present in run_ralph_desk.zsh"

# AC2-negative: grep '^- US-' filter step present
exists=$(grep_exists "grep '\\^- US-'" "$RUN")
assert_eq "$exists" 1 "AC2-negative: grep '^- US-' filter step present in run_ralph_desk.zsh"

# AC2-boundary: final normalization pipeline present (sort -u | tr | sed trailing comma)
exists=$(grep_exists "sort -u | tr" "$RUN")
assert_eq "$exists" 1 "AC2-boundary: sort -u | tr normalization pipeline present in run_ralph_desk.zsh"

# ============================================================
# L3: E2E — verify pipeline output with sample memory file
# ============================================================

echo ""
echo "--- L3: E2E pipeline verification ---"

TMPDIR_L3=$(mktemp -d)
SAMPLE_MEMORY="$TMPDIR_L3/sample-memory.md"

cat > "$SAMPLE_MEMORY" << 'MEMORY_EOF'
# Test Campaign Memory

## Stop Status
verify

## Objective
Test objective

## Completed Stories
- US-001: Debug Log 4-Category Refactoring — PASS
- US-002: Consensus Mode Stability — PASS
- US-003: Mandatory Campaign Report — PASS

## Next Iteration Contract
implement US-004

## Key Decisions
- some decision
MEMORY_EOF

# Run the exact pipeline from AC2 spec
result=$(sed -n '/^## Completed Stories$/,/^## /p' "$SAMPLE_MEMORY" 2>/dev/null \
  | grep '^- US-' \
  | sed 's/^- \(US-[0-9]*\):.*/\1/' \
  | sort -u \
  | tr '\n' ',' \
  | sed 's/,$//')

# L3-happy: pipeline produces correct comma-separated list
if [[ "$result" = "US-001,US-002,US-003" ]]; then
  pass "L3-happy: pipeline output = 'US-001,US-002,US-003'"
else
  fail "L3-happy: expected 'US-001,US-002,US-003', got '$result'"
fi

# L3-boundary (empty section): no entries → empty output
EMPTY_MEMORY="$TMPDIR_L3/empty-memory.md"
cat > "$EMPTY_MEMORY" << 'EMPTY_EOF'
# Campaign Memory

## Stop Status
continue

## Completed Stories

## Next Iteration Contract
implement US-001
EMPTY_EOF

result_empty=$(sed -n '/^## Completed Stories$/,/^## /p' "$EMPTY_MEMORY" 2>/dev/null \
  | grep '^- US-' \
  | sed 's/^- \(US-[0-9]*\):.*/\1/' \
  | sort -u \
  | tr '\n' ',' \
  | sed 's/,$//')

if [[ -z "$result_empty" ]]; then
  pass "L3-boundary: empty Completed Stories section yields empty string"
else
  fail "L3-boundary: expected empty string, got '$result_empty'"
fi

# L3-boundary (no section): memory without Completed Stories header → empty output
NO_SECTION_MEMORY="$TMPDIR_L3/no-section-memory.md"
cat > "$NO_SECTION_MEMORY" << 'NOSEC_EOF'
# Campaign Memory

## Stop Status
continue

## Next Iteration Contract
implement US-001
NOSEC_EOF

result_nosec=$(sed -n '/^## Completed Stories$/,/^## /p' "$NO_SECTION_MEMORY" 2>/dev/null \
  | grep '^- US-' \
  | sed 's/^- \(US-[0-9]*\):.*/\1/' \
  | sort -u \
  | tr '\n' ',' \
  | sed 's/,$//')

if [[ -z "$result_nosec" ]]; then
  pass "L3-boundary: memory with no Completed Stories section yields empty string"
else
  fail "L3-boundary: expected empty string, got '$result_nosec'"
fi

rm -rf "$TMPDIR_L3"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
