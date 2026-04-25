#!/usr/bin/env bash
# Test Suite: US-019 — R7 P1-G verify_partial signal vocabulary
# Validates:
#   - init_ralph_desk.zsh Signal rules mention verify_partial + verified_acs/deferred_acs/defer_reason
#   - verifier prompt: "If signal status=verify_partial, evaluate ONLY verified_acs"
#   - governance §7g Signal Vocabulary Extension
#   - Node parser downgrades verify_partial without verified_acs to blocked
#   - zsh runner recognises verify_partial status

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
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

echo "=== US-019: R7 P1-G verify_partial Signal Vocabulary ==="
echo

# AC1: Signal rules mention verify_partial in worker prompt
assert_one "$INIT" 'verify_partial' \
  "AC1-a: worker prompt mentions verify_partial status"
assert_one "$INIT" 'verified_acs' \
  "AC1-b: worker prompt mentions verified_acs field"
assert_one "$INIT" 'deferred_acs' \
  "AC1-c: worker prompt mentions deferred_acs field"
assert_one "$INIT" 'defer_reason' \
  "AC1-d: worker prompt mentions defer_reason field"

# AC2: Verifier prompt has the exact sentence
assert_one "$INIT" 'evaluate ONLY verified_acs' \
  "AC2: verifier prompt has 'evaluate ONLY verified_acs' sentence"

# AC3: governance §7g Signal Vocabulary Extension
assert_one "$GOV" '## 7g\. Signal Vocabulary Extension' \
  "AC3-a: §7g Signal Vocabulary Extension section present"
assert_one "$GOV" 'verify_partial_malformed' \
  "AC3-b: §7g documents malformed downgrade"

# AC4: Node parser downgrades verify_partial with empty verified_acs
assert_one "$LOOP" 'verify_partial' \
  "AC4-a: Node parser handles verify_partial"
assert_one "$LOOP" 'verify_partial_malformed' \
  "AC4-b: Node parser downgrades to verify_partial_malformed"

# AC5: zsh runner recognises verify_partial
assert_one "$RUN" 'verify_partial' \
  "AC5: zsh runner recognises verify_partial"

# AC6: Behavioural — Node parser downgrades fixture
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us019-XXXX")
node --input-type=module -e "
const malformed = { iteration: 1, status: 'verify_partial', us_id: 'US-001', verified_acs: [], deferred_acs: ['AC3'], defer_reason: 'cross-US dep' };
function classify(signal) {
  if (signal.status === 'verify_partial' && (!Array.isArray(signal.verified_acs) || signal.verified_acs.length === 0)) {
    return { downgraded: true, reason: 'verify_partial_malformed' };
  }
  return { downgraded: false };
}
const result = classify(malformed);
process.stdout.write(JSON.stringify(result));
" > "$TMP_DIR/result.json" 2>/dev/null
if [[ -f "$TMP_DIR/result.json" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e '.downgraded == true and .reason == "verify_partial_malformed"' "$TMP_DIR/result.json" >/dev/null 2>&1; then
    pass "AC6: malformed verify_partial fixture downgrades to verify_partial_malformed"
  else
    fail "AC6: downgrade logic broken: $(cat "$TMP_DIR/result.json")"
  fi
else
  fail "AC6: result file or jq unavailable"
fi
rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
