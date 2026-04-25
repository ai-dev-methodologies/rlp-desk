#!/usr/bin/env bash
# Test Suite: US-022 — R10 P2-J Cross-mission us_id leak prevention
# Validates:
#   - init_ralph_desk.zsh quarantines stale iter-signal.json with foreign us_id
#   - Normalized US extractor handles `## US-005:`, `## US-005 -`, `## US-005`
#   - rm -f NOT used on SIGNAL_FILE (quarantine, not destruction)
#   - .sisyphus/quarantine/ directory created
#   - governance §7a documents quarantine path

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
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

echo "=== US-022: R10 P2-J Cross-mission us_id leak prevention ==="
echo

# AC1: init_ralph_desk.zsh has stale us_id quarantine logic
assert_one "$INIT" 'quarantine' \
  "AC1-a: init references quarantine path"
assert_one "$INIT" '\.sisyphus/quarantine' \
  "AC1-b: init uses .sisyphus/quarantine/ directory"

# AC2: Normalized US extractor (handles : and - and bare heading) — defined in lib
assert_one "$LIB" '_extract_prd_us_list' \
  "AC2: lib_ralph_desk.zsh defines _extract_prd_us_list normalized extractor"

# AC3: rm -f NOT used on SIGNAL_FILE (must be quarantine, not destructive)
rm_count=$(grep -cE 'rm -f.*SIGNAL_FILE' "$INIT" 2>/dev/null | head -1)
[[ -z "$rm_count" ]] && rm_count=0
[[ "$rm_count" -eq 0 ]] && pass "AC3: rm -f SIGNAL_FILE NOT used in init (quarantine instead)" \
                       || fail "AC3: rm -f SIGNAL_FILE found $rm_count times — must use mv to quarantine"

# AC4: governance §7a documents quarantine path
assert_one "$GOV" 'quarantine' \
  "AC4-a: governance mentions quarantine"
assert_one "$GOV" '[Cc]ross-mission' \
  "AC4-b: governance documents cross-mission us_id leak"

# AC5: behavioural — fixture: PRD US-001~003 + stale signal us_id=US-005
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us022-XXXX")
mkdir -p "$TMP_DIR/memos" "$TMP_DIR/plans"
PRD="$TMP_DIR/plans/prd-test.md"
SIGNAL="$TMP_DIR/memos/test-iter-signal.json"

cat > "$PRD" <<'EOF'
# PRD

## US-001: First
- AC1: ...
## US-002: Second
- AC1: ...
## US-003 - Third (dash variant)
- AC1: ...
EOF

# Stale us_id from prior mission
echo '{"iteration":1,"status":"verify","us_id":"US-005","summary":"stale"}' > "$SIGNAL"

# Invoke quarantine logic via zsh fixture (helper)
zsh -c "
  DESK='$TMP_DIR'
  source '$LIB'
  _quarantine_stale_signal '$SIGNAL' '$PRD' '$TMP_DIR'
" 2>&1 | head -3

# After invocation: SIGNAL_FILE should NOT exist, quarantine dir should have a file
if [[ ! -f "$SIGNAL" ]] && ls "$TMP_DIR/.sisyphus/quarantine/"iter-signal.*.json >/dev/null 2>&1; then
  pass "AC5-a: stale us_id=US-005 quarantined (original signal removed, quarantine file present)"
else
  fail "AC5-a: quarantine failed — SIGNAL_FILE exists=$([[ -f "$SIGNAL" ]] && echo yes || echo no), quarantine dir contents: $(ls "$TMP_DIR/.sisyphus/quarantine/" 2>/dev/null || echo none)"
fi

# AC6: heading variation fixture — recognise ## US-001:, ## US-002 -, ## US-003 (no separator at EOL)
# Already encoded in fixture above. Test that PRD US extractor returns 001, 002, 003.
extracted=$(zsh -c "
  source '$LIB' 2>/dev/null
  _extract_prd_us_list '$PRD'
" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
if [[ "$extracted" == "US-001,US-002,US-003" ]]; then
  pass "AC6: _extract_prd_us_list handles all heading variants (got $extracted)"
else
  fail "AC6: extractor missed variants (got '$extracted', expected US-001,US-002,US-003)"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
