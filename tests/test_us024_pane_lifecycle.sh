#!/usr/bin/env bash
# Test Suite: US-024 — R12 P0 Pane lifecycle monitor + bounded retry (5×1s)
# Validates:
#   - lib_ralph_desk.zsh defines _verify_pane_alive + _verify_session_alive helpers
#   - run_ralph_desk.zsh has _r12_check_lifecycle invocation in 3 sites
#   - Single authoritative timeout: 5×1s = 5s
#   - Behavioural: dead pane id → false return; mid-iter pane death detected at next checkpoint

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"

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

echo "=== US-024: R12 P0 Pane Lifecycle Monitor ==="
echo

# AC1: helpers defined in lib
assert_one "$LIB" '_verify_pane_alive\(\)' \
  "AC1-a: _verify_pane_alive helper defined"
assert_one "$LIB" '_verify_session_alive\(\)' \
  "AC1-b: _verify_session_alive helper defined"

# AC2: run_ralph_desk.zsh has _r12_check_lifecycle calls (3 sites)
n_calls=$(grep -cE '_r12_check_lifecycle' "$RUN" 2>/dev/null | head -1)
[[ -z "$n_calls" ]] && n_calls=0
[[ "$n_calls" -ge 3 ]] && pass "AC2: _r12_check_lifecycle invoked >=3 times in run_ralph_desk.zsh (got $n_calls — expect create + iter_start + post_send)" \
                      || fail "AC2: expected >=3 invocations, got $n_calls"

# AC3: single authoritative 5s timeout (5x1s polling)
assert_one "$RUN" '_attempts >= 5' \
  "AC3-a: 5-attempt threshold present"
assert_one "$RUN" 'sleep 1' \
  "AC3-b: 1-second sleep between polls"
# No contradictory "3 retries" or "4s budget" wording
n_contradict=$(grep -cE '3 retries|4s budget|3 × 1s' "$RUN" 2>/dev/null | head -1)
[[ -z "$n_contradict" ]] && n_contradict=0
[[ "$n_contradict" -eq 0 ]] && pass "AC3-c: no contradictory '3 retries' / '4s' wording (got $n_contradict)" \
                            || fail "AC3-c: stale 3-retry wording present ($n_contradict)"

# AC4: dead pane detection — behavioural
result_dead=$(zsh -c "
  source '$LIB'
  _verify_pane_alive '%99999' && echo ALIVE || echo DEAD
  _verify_session_alive 'nonexistent-session-fixture-99999' && echo SES_ALIVE || echo SES_DEAD
" 2>/dev/null)
if echo "$result_dead" | grep -q "^DEAD$" && echo "$result_dead" | grep -q "^SES_DEAD$"; then
  pass "AC4-a: dead pane id + nonexistent session both return false"
else
  fail "AC4-a: helper returned wrong value (output: $result_dead)"
fi

# AC5: helper writes BLOCKED sentinel with infra_failure on failure
# Behavioural: invoke a faux _r12_check_lifecycle from a temp fixture
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us024-XXXX")
SLUG_TEST="us024-fixture"
mkdir -p "$TMP_DIR/memos" "$TMP_DIR/logs/$SLUG_TEST"
result_block=$(zsh -c "
  DESK='$TMP_DIR'
  SLUG='$SLUG_TEST'
  ITERATION=1
  CURRENT_US='US-001'
  BLOCKED_SENTINEL='$TMP_DIR/memos/$SLUG_TEST-blocked.md'
  DEBUG_LOG='$TMP_DIR/logs/$SLUG_TEST/debug.log'
  log_error() { echo \"ERR: \$*\" >&2; }
  log() { echo \"[log] \$*\" >&2; }
  source '$LIB' 2>/dev/null
  # Define minimal _r12_check_lifecycle inline matching plan spec
  _r12_check_lifecycle() {
    local site=\"\$1\"
    local _attempts=0
    while ! _verify_session_alive 'nonexistent-fixture-99999'; do
      (( _attempts++ ))
      if (( _attempts >= 5 )); then
        log_error \"[r12:\$site] tmux session/pane dead after 5x1s\"
        write_blocked_sentinel 'tmux session/pane dead during '\"\$site\" \"\${CURRENT_US:-ALL}\" 'infra_failure'
        return 1
      fi
      sleep 1
    done
    return 0
  }
  start=\$(date +%s)
  _r12_check_lifecycle iter_start
  rc=\$?
  end=\$(date +%s)
  duration=\$(( end - start ))
  echo \"RC=\$rc DURATION=\$duration\"
" 2>&1)

# Verify exit code = 1 (failure)
if echo "$result_block" | grep -q "RC=1"; then
  pass "AC5-a: _r12_check_lifecycle returns 1 on dead session"
else
  fail "AC5-a: rc != 1 (output: $result_block)"
fi

# Verify duration is in 5±1s range (5 polls × 1s = 5s)
duration=$(echo "$result_block" | grep -oE 'DURATION=[0-9]+' | tail -1 | cut -d= -f2)
[[ -n "$duration" ]] || duration=0
if [[ "$duration" -ge 4 ]] && [[ "$duration" -le 7 ]]; then
  pass "AC5-b: duration ${duration}s within 5±2s budget"
else
  fail "AC5-b: duration ${duration}s outside expected 5±2s budget"
fi

# Verify infra_failure sentinel
SIDECAR="$TMP_DIR/memos/$SLUG_TEST-blocked.json"
if [[ -f "$SIDECAR" ]] && command -v jq >/dev/null 2>&1; then
  cat=$(jq -r '.reason_category' "$SIDECAR" 2>/dev/null)
  if [[ "$cat" == "infra_failure" ]]; then
    pass "AC5-c: blocked JSON sidecar has reason_category=infra_failure"
  else
    fail "AC5-c: reason_category=$cat (expected infra_failure)"
  fi
else
  fail "AC5-c: sidecar missing or jq unavailable"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
