#!/usr/bin/env bash
# Test Suite: US-017 — R5 P0-D A4 Fallback Audit + Worker Prompt Mandate
# Validates:
#   - lib_ralph_desk.zsh defines _emit_a4_fallback_audit helper
#   - run_ralph_desk.zsh A4 fallback paths (line 1587, 542) call the helper
#   - init_ralph_desk.zsh worker prompt has Step N+1 mandatory + iter-signal SPECIFIC summary
#   - governance.md §1f references A4 ratio < 10% recommendation
#   - Verifier prompt detects auto_generated summary and tags meta.iter_signal_quality
#   - Behavioural: invoking helper appends entry, pre/post count delta = 1

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
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

echo "=== US-017: R5 P0-D A4 Fallback Audit ==="
echo

# AC1: helper defined in lib_ralph_desk.zsh
assert_one "$LIB" '_emit_a4_fallback_audit\(\)' \
  "AC1: _emit_a4_fallback_audit helper defined in lib_ralph_desk.zsh"

# AC2: run_ralph_desk.zsh A4 fallback paths call the helper (2 sites)
n_calls=$(grep -cE '_emit_a4_fallback_audit' "$RUN" 2>/dev/null | head -1)
[[ -z "$n_calls" ]] && n_calls=0
[[ "$n_calls" -ge 2 ]] && pass "AC2: run_ralph_desk.zsh has >=2 calls to _emit_a4_fallback_audit (got $n_calls)" \
                       || fail "AC2: expected >=2 _emit_a4_fallback_audit calls, got $n_calls"

# AC3: worker prompt has Step N+1 mandate
assert_one "$INIT" 'iter-signal\.json with SPECIFIC summary' \
  "AC3-a: worker prompt mandates SPECIFIC summary in iter-signal.json"
assert_one "$INIT" 'auto-generated.*A4 fallback.*debugging.context loss' \
  "AC3-b: worker prompt warns auto-generated A4 fallback = debugging context loss"

# AC4: governance §1f references A4 ratio recommendation
assert_one "$GOV" 'A4 [Ff]allback' \
  "AC4-a: governance references A4 fallback"
assert_one "$GOV" 'ratio.*<.*10%' \
  "AC4-b: governance §1f recommends A4 ratio < 10%"

# AC5: verifier prompt detects auto_generated summary
assert_one "$INIT" 'iter_signal_quality' \
  "AC5-a: verifier prompt mentions iter_signal_quality meta"
assert_one "$INIT" 'auto_generated' \
  "AC5-b: verifier prompt uses auto_generated tag"

# AC6: behavioural — invoking helper appends entry to audit log
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us017-XXXX")
TMP_LOGS="$TMP_DIR/logs"
mkdir -p "$TMP_LOGS"
TMP_AUDIT="$TMP_LOGS/a4-fallback-audit.jsonl"
pre=0
[[ -f "$TMP_AUDIT" ]] && pre=$(wc -l < "$TMP_AUDIT" | tr -d ' ')

# Invoke helper via zsh fixture (NEW-1 patch)
zsh -c "
  LOGS_DIR='$TMP_LOGS'
  source '$LIB' 2>/dev/null
  _emit_a4_fallback_audit US-001 1 'fixture-test' 2>/dev/null
" 2>/dev/null

post=0
[[ -f "$TMP_AUDIT" ]] && post=$(wc -l < "$TMP_AUDIT" | tr -d ' ')
delta=$(( post - pre ))
[[ "$delta" -ge 1 ]] && pass "AC6-a: helper appends entry (pre=$pre post=$post delta=$delta)" \
                    || fail "AC6-a: delta=0 (pre=$pre post=$post)"

# AC6-b: entry is valid JSON with expected fields
if [[ -f "$TMP_AUDIT" ]] && command -v jq >/dev/null 2>&1; then
  last_line=$(tail -1 "$TMP_AUDIT")
  if echo "$last_line" | jq -e '.event == "a4_fallback" and .us_id == "US-001" and .iter == 1' >/dev/null 2>&1; then
    pass "AC6-b: entry valid JSON with event/us_id/iter"
  else
    fail "AC6-b: entry malformed: $last_line"
  fi
else
  fail "AC6-b: audit file missing or jq unavailable"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
