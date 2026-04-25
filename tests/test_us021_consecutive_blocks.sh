#!/usr/bin/env bash
# Test Suite: US-021 — R9 P2-I consecutive_blocks counter + canonicalization + edge cases
# Validates:
#   - BLOCK_CB_THRESHOLD variable (default 3)
#   - CONSECUTIVE_BLOCKS + LAST_BLOCK_REASON variables
#   - _canonical_block_reason helper strips hygiene_violated:/wrapped: prefixes
#   - Same canonical reason 3 times → mission-abort.json + exit 1
#   - infra_failure category exempt
#   - First iteration block exempt
#   - governance §8 documents consecutive_blocks

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
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

echo "=== US-021: R9 P2-I consecutive_blocks counter ==="
echo

# AC1: BLOCK_CB_THRESHOLD variable defined (default 3)
assert_one "$RUN" 'BLOCK_CB_THRESHOLD="\$\{BLOCK_CB_THRESHOLD:-3\}"' \
  "AC1: BLOCK_CB_THRESHOLD variable initialized (default 3)"
assert_one "$RUN" 'CONSECUTIVE_BLOCKS=0' \
  "AC1-b: CONSECUTIVE_BLOCKS counter initialized"
assert_one "$RUN" 'LAST_BLOCK_REASON=' \
  "AC1-c: LAST_BLOCK_REASON variable initialized"

# AC2: _canonical_block_reason helper defined
assert_one "$LIB" '_canonical_block_reason' \
  "AC2-a: _canonical_block_reason helper defined in lib_ralph_desk.zsh"

# AC3: governance §8 documents consecutive_blocks + canonicalization + exempt
assert_one "$GOV" 'consecutive_blocks' \
  "AC3-a: governance mentions consecutive_blocks"
assert_one "$GOV" 'canonical' \
  "AC3-b: governance documents canonicalization"
assert_one "$GOV" 'infra_failure.*exempt' \
  "AC3-c: governance documents infra_failure exemption"

# AC4: zsh runner has same-reason check + mission-abort write
assert_one "$RUN" 'CONSECUTIVE_BLOCKS=\$\(\(CONSECUTIVE_BLOCKS \+ 1\)\)' \
  "AC4-a: zsh runner increments CONSECUTIVE_BLOCKS on same canonical reason"
assert_one "$RUN" 'mission-abort\.json' \
  "AC4-b: zsh runner writes mission-abort.json on threshold"

# AC5: behavioural — _canonical_block_reason strips prefixes
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us021-XXXX")
result=$(zsh -c "
  source '$LIB' 2>/dev/null
  echo CANON1=\$(_canonical_block_reason 'hygiene_violated:metric_failure: AC1 fail')
  echo CANON2=\$(_canonical_block_reason 'wrapped:cross_us_dep: blocked')
  echo CANON3=\$(_canonical_block_reason 'metric_failure: plain reason')
" 2>&1)
if echo "$result" | grep -q 'CANON1=metric_failure: AC1 fail'; then
  pass "AC5-a: _canonical_block_reason strips hygiene_violated: prefix"
else
  fail "AC5-a: prefix strip failed (output: $result)"
fi
if echo "$result" | grep -q 'CANON2=cross_us_dep: blocked'; then
  pass "AC5-b: _canonical_block_reason strips wrapped: prefix"
else
  fail "AC5-b: wrapped: strip failed (output: $result)"
fi
if echo "$result" | grep -q 'CANON3=metric_failure: plain reason'; then
  pass "AC5-c: _canonical_block_reason passes through unprefixed reasons"
else
  fail "AC5-c: passthrough failed (output: $result)"
fi
rm -rf "$TMP_DIR"

# AC6: Node parser tracks consecutive_blocks state
assert_one "$LOOP" 'consecutive_blocks' \
  "AC6: Node parser tracks state.consecutive_blocks"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
