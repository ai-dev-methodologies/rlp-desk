#!/bin/zsh
# v5.7 §4.16 — bounded prompt-stall escalation test.
# Closes the codex Critic HIGH gap: alive process + missed prompt = infinite wait.
# Now: prompt visible for PROMPT_STALL_TIMEOUT seconds OR dismiss attempts
# exceed PROMPT_DISMISS_FAIL_LIMIT → write BLOCKED `infra_failure` and exit.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Extract the §4.13/§4.16 helper region between the banner and check_and_nudge_idle_pane.
TMP_LIB=$(mktemp -t prompt-stall-test.XXXXXX)
sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d' > "$TMP_LIB"

# Mocks
log() { :; }
log_error() { :; }
log_debug() { :; }
declare -g _BLOCKED_REASON=""
declare -g _BLOCKED_CATEGORY=""
declare -g _BLOCKED_US_ID=""
write_blocked_sentinel() {
  _BLOCKED_REASON="$1"
  _BLOCKED_US_ID="$2"
  _BLOCKED_CATEGORY="$3"
}

declare -g _CAPTURE_FIXTURE=""
tmux() {
  if [[ "$1" == "capture-pane" ]]; then
    print -- "$_CAPTURE_FIXTURE"
  fi
}

PROMPT_STALL_TIMEOUT=2  # accelerate test (2s instead of 300s)
PROMPT_DISMISS_FAIL_LIMIT=3
ITERATION=1
CURRENT_US="US-001"

source "$TMP_LIB"

PASS=0; FAIL=0
pass() { (( PASS++ )); print "PASS: $1"; }
fail() { (( FAIL++ )); print "FAIL: $1"; }

# --- Test 1: First call records PANE_PROMPT_STUCK_SINCE ---
LAST_AUTO_APPROVE_TS=()
PANE_PROMPT_STUCK_SINCE=()
PANE_DISMISS_FAILED_COUNT=()
_CAPTURE_FIXTURE="Do you want to create test.json? (y/n)"
auto_dismiss_prompts "%w"
if [[ -n "${PANE_PROMPT_STUCK_SINCE[%w]:-}" ]]; then
  pass "stuck_since recorded on first prompt detection"
else
  fail "stuck_since should be set"
fi

# --- Test 2: stall escalation NOT yet (well under timeout) ---
if check_prompt_stall "%w"; then
  pass "no escalation while within timeout"
else
  fail "should not escalate immediately"
fi

# --- Test 3: simulate timeout — backdate stuck_since ---
PANE_PROMPT_STUCK_SINCE[%w]=$(( $(_now_s) - 10 ))  # 10s ago, exceeds 2s threshold
_BLOCKED_REASON=""
if check_prompt_stall "%w"; then
  fail "should escalate after timeout"
else
  pass "escalates BLOCKED after PROMPT_STALL_TIMEOUT exceeded"
fi
if [[ "$_BLOCKED_CATEGORY" == "infra_failure" ]]; then
  pass "BLOCKED category is infra_failure"
else
  fail "BLOCKED category wrong: $_BLOCKED_CATEGORY"
fi
if [[ "$_BLOCKED_REASON" == *"stuck on TUI prompt"* ]]; then
  pass "BLOCKED reason mentions TUI prompt"
else
  fail "BLOCKED reason missing context: $_BLOCKED_REASON"
fi

# --- Test 4: dismiss-fail-limit escalation ---
PANE_PROMPT_STUCK_SINCE=()
PANE_DISMISS_FAILED_COUNT=()
PANE_PROMPT_STUCK_SINCE[%w]=$(_now_s)  # just started — under timeout
PANE_DISMISS_FAILED_COUNT[%w]=$PROMPT_DISMISS_FAIL_LIMIT
_BLOCKED_REASON=""
if check_prompt_stall "%w"; then
  fail "should escalate when dismiss_fail_count >= limit"
else
  pass "escalates when dismiss_fail_count >= PROMPT_DISMISS_FAIL_LIMIT"
fi

# --- Test 5: prompt cleared → stuck_since cleared ---
PANE_PROMPT_STUCK_SINCE=()
PANE_DISMISS_FAILED_COUNT=()
LAST_AUTO_APPROVE_TS=()
_CAPTURE_FIXTURE="Do you want to create x? (y/n)"
auto_dismiss_prompts "%w"
[[ -n "${PANE_PROMPT_STUCK_SINCE[%w]:-}" ]] && pass "stuck_since set after detection" || fail "expected stuck_since"

_CAPTURE_FIXTURE="Operation complete. No prompt visible."
auto_dismiss_prompts "%w"
if [[ -z "${PANE_PROMPT_STUCK_SINCE[%w]:-}" ]]; then
  pass "stuck_since cleared when prompt no longer visible"
else
  fail "stuck_since should be cleared"
fi

rm -f "$TMP_LIB"
print
print "Total: $PASS pass, $FAIL fail"
(( FAIL == 0 ))
