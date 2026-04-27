#!/bin/zsh
# v5.7 §4.17 — generic no-progress timeout + default-No prompt block.
# Closes codex Critic HIGH gaps: undetected/ambiguous prompts can no longer
# infinite-wait, and default-No prompts are NOT auto-Enter'd (which would
# CANCEL the operation).
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

TMP_LIB=$(mktemp -t no-progress-test.XXXXXX)
sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d' > "$TMP_LIB"

log() { :; }
log_error() { :; }
log_debug() { :; }
declare -g _BLOCKED_REASON=""
declare -g _BLOCKED_CATEGORY=""
write_blocked_sentinel() {
  _BLOCKED_REASON="$1"
  _BLOCKED_CATEGORY="$3"
}

declare -g _CAPTURE_FIXTURE=""
tmux() {
  if [[ "$1" == "capture-pane" ]]; then
    print -- "$_CAPTURE_FIXTURE"
  fi
}

# Override timeout for fast test
PROGRESS_NO_CHANGE_TIMEOUT=2
ITERATION=1
CURRENT_US="US-001"

source "$TMP_LIB"

PASS=0; FAIL=0
pass() { (( PASS++ )); print "PASS: $1"; }
fail() { (( FAIL++ )); print "FAIL: $1"; }

# === Test 1: default-No prompt blocks instead of auto-Enter ===
LAST_AUTO_APPROVE_TS=()
PANE_PROMPT_STUCK_SINCE=()
PANE_DISMISS_FAILED_COUNT=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="Do you want to overwrite test.json? [y/N]"
auto_dismiss_prompts "%w"
if [[ "$_BLOCKED_CATEGORY" == "infra_failure" ]] && [[ "$_BLOCKED_REASON" == *"default-No"* ]]; then
  pass "default-No prompt [y/N] → BLOCKED instead of auto-Enter"
else
  fail "expected BLOCKED on [y/N], got category=$_BLOCKED_CATEGORY reason=$_BLOCKED_REASON"
fi

# === Test 2: regular [Y/n] still auto-dismissed (default-Yes) ===
LAST_AUTO_APPROVE_TS=()
PANE_PROMPT_STUCK_SINCE=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="Do you want to create x? [Y/n]"
auto_dismiss_prompts "%w"
if [[ -z "$_BLOCKED_CATEGORY" ]]; then
  pass "default-Yes prompt [Y/n] → auto-dismiss path (no BLOCKED)"
else
  fail "default-Yes should not BLOCK, got category=$_BLOCKED_CATEGORY"
fi

# === Test 3: explicit (yes/no, default no) blocked ===
LAST_AUTO_APPROVE_TS=()
PANE_PROMPT_STUCK_SINCE=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="Confirm execution? (yes/no, default no)"
auto_dismiss_prompts "%w"
if [[ "$_BLOCKED_CATEGORY" == "infra_failure" ]]; then
  pass "explicit 'default no' phrasing → BLOCKED"
else
  fail "explicit default no should BLOCK"
fi

# === Test 4: check_no_progress — first call records baseline, no escalate ===
PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="frame 1"
if check_no_progress "%w"; then
  pass "first call records baseline, no escalation"
else
  fail "first call should not escalate"
fi

# === Test 5: content changed → reset timer ===
_CAPTURE_FIXTURE="frame 2 (different)"
if check_no_progress "%w"; then
  pass "content change resets last_change_ts"
else
  fail "content change should not escalate"
fi

# === Test 6: content frozen for > timeout → escalate BLOCKED ===
PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="static frame"
check_no_progress "%w"  # baseline
PANE_LAST_CHANGE_TS[%w]=$(( $(_now_s) - 10 ))  # 10s ago, exceeds 2s threshold
# Same fixture — content didn't change
if check_no_progress "%w"; then
  fail "should escalate after PROGRESS_NO_CHANGE_TIMEOUT"
else
  pass "no-progress timeout → BLOCKED"
fi
if [[ "$_BLOCKED_REASON" == *"unchanged for"* ]]; then
  pass "BLOCKED reason mentions unchanged content"
else
  fail "BLOCKED reason missing context: $_BLOCKED_REASON"
fi

# === Test 7: no-progress fires INDEPENDENT of prompt detection ===
# (the key codex Critic concern — undetected prompts must still be caught)
PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
_BLOCKED_REASON=""
_BLOCKED_CATEGORY=""
_CAPTURE_FIXTURE="this content has NO prompt patterns at all"
check_no_progress "%w"
PANE_LAST_CHANGE_TS[%w]=$(( $(_now_s) - 10 ))
if check_no_progress "%w"; then
  fail "should escalate even without prompt patterns"
else
  pass "no-progress catches undetected/non-prompt freezes (codex HIGH gap closed)"
fi

rm -f "$TMP_LIB"
print
print "Total: $PASS pass, $FAIL fail"
(( FAIL == 0 ))
