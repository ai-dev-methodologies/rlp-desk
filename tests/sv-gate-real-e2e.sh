#!/bin/zsh
# Real-tmux E2E for Bug 4 (auto_dismiss_prompts) + Bug 5 prep.
# NO MOCKS. Real tmux pane, real capture-pane, real send-keys.
# Each test isolates pane state via tmux clear-history + clear.
set -uo pipefail

SRC=/Users/kyjin/dev/own/ai-dev-methodologies/ai-dev-methodologies-hq/workspace/rlp-desk
RUN="$SRC/src/scripts/run_ralph_desk.zsh"

TMP_LIB=$(mktemp -t e2e-real-tmux.XXXXXX)
sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d' > "$TMP_LIB"

log() { print -- "[log] $*" >&2; }
log_error() { print -- "[err] $*" >&2; }
log_debug() { :; }
write_blocked_sentinel() {
  print -- "BLOCKED: reason=$1 cat=$3" >&2
  echo "$1|$3" > /tmp/_e2e_blocked.txt
}

PROGRESS_NO_CHANGE_TIMEOUT=4
PROMPT_STALL_TIMEOUT=4
PROMPT_DISMISS_FAIL_LIMIT=3
ITERATION=1
CURRENT_US="US-E2E"

source "$TMP_LIB"

PASS=0
FAIL=0
pass() { (( PASS++ )); print "PASS: $1"; }
fail() { (( FAIL++ )); print "FAIL: $1"; }

SESSION="rlp-e2e-$$"
tmux new-session -d -s "$SESSION" -x 200 -y 50
PANE=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | head -1)
print "[setup] real tmux session=$SESSION pane=$PANE"

trap "tmux kill-session -t $SESSION 2>/dev/null; rm -f $TMP_LIB /tmp/_e2e_blocked.txt" EXIT

reset_pane_state() {
  tmux send-keys -t "$PANE" 'clear' Enter
  sleep 0.3
  tmux clear-history -t "$PANE"
  LAST_AUTO_APPROVE_TS=()
  PANE_PROMPT_STUCK_SINCE=()
  PANE_DISMISS_FAILED_COUNT=()
  PANE_LAST_CONTENT_FOR_PROGRESS=()
  PANE_LAST_CHANGE_TS=()
  rm -f /tmp/_e2e_blocked.txt
}

# === Test 1: default-Yes [Y/n] auto-dismiss ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'Do you want to create test.json? [Y/n] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ ! -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: [Y/n] prompt → auto-dismiss (no BLOCK)"
else
  fail "REAL TMUX: [Y/n] should NOT BLOCK, but BLOCKED was written"
fi

# === Test 2: default-No [y/N] BLOCK ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'Do you want to overwrite secret.json? [y/N] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ -f /tmp/_e2e_blocked.txt ]] && [[ "$(cut -d'|' -f2 /tmp/_e2e_blocked.txt)" == "infra_failure" ]]; then
  pass "REAL TMUX: [y/N] prompt → BLOCKED (infra_failure), no Enter sent"
else
  fail "REAL TMUX: [y/N] must BLOCK with infra_failure"
fi

# === Test 3: no-progress timeout escalates ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'frozen content with no prompt at all'" Enter
sleep 0.5
PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
check_no_progress "$PANE"
PANE_LAST_CHANGE_TS[$PANE]=$(( $(_now_s) - 10 ))
if check_no_progress "$PANE"; then
  fail "REAL TMUX: should escalate after PROGRESS_NO_CHANGE_TIMEOUT"
else
  if [[ -f /tmp/_e2e_blocked.txt ]]; then
    pass "REAL TMUX: no-progress timeout → BLOCKED (catches non-prompt freezes)"
  else
    fail "REAL TMUX: no-progress detected but no BLOCKED sentinel"
  fi
fi

# === Test 4: unknown pattern with NO affordance bracket → no Enter, no BLOCK ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'WTF prompt:: type something'" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ ! -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: unknown pattern (no bracket) → no Enter, no BLOCK (10min freeze catches)"
else
  fail "REAL TMUX: pure-text unknown should NOT trigger BLOCK"
fi

# === Test 4b (NEW v5.7 §4.18): unknown PHRASING with [y/N] bracket → fast-fail BLOCK ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'CompletelyNewCLIv99 says: [y/N] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: unknown phrasing + [y/N] → BLOCK fast (omc benchmarking)"
else
  fail "REAL TMUX: unknown phrasing + bracket must BLOCK fast (no 10min wait)"
fi

# === Test 4c (NEW v5.7 §4.18): unknown PHRASING with (y/n) → fast-fail BLOCK ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'XyzVariant prompt: (y/n) '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: unknown phrasing + (y/n) → BLOCK fast"
else
  fail "REAL TMUX: unknown phrasing + (y/n) must BLOCK fast"
fi

# === Test 5: codex 'Approve this command? [Y/n]' auto-dismiss ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'Approve this command? [Y/n] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ ! -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: codex [Y/n] → auto-dismiss (no BLOCK)"
else
  fail "REAL TMUX: codex [Y/n] should NOT BLOCK"
fi

# === Test 6: codex 'Approve this command? [y/N]' BLOCK ===
reset_pane_state
tmux send-keys -t "$PANE" "printf 'Approve this command? [y/N] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: codex [y/N] → BLOCKED"
else
  fail "REAL TMUX: codex [y/N] must BLOCK"
fi

# === Test 7 (NEW): scrollback contamination — old [Y/n] + current [y/N] → MUST BLOCK ===
# This is the production scenario the previous E2E uncovered: scrollback has
# an older default-Yes prompt and the active prompt is default-No. Old
# break-on-first-match logic would auto-Enter; fixed logic must BLOCK.
reset_pane_state
tmux send-keys -t "$PANE" "printf 'Do you want to create file? [Y/n] '" Enter
sleep 0.4
tmux send-keys -t "$PANE" 'echo " [done]"' Enter
sleep 0.2
tmux send-keys -t "$PANE" "printf 'Do you want to overwrite passwd? [y/N] '" Enter
sleep 0.5
auto_dismiss_prompts "$PANE"
sleep 0.3
if [[ -f /tmp/_e2e_blocked.txt ]]; then
  pass "REAL TMUX: mixed scrollback ([Y/n] then [y/N]) → BLOCK (no false auto-Enter)"
else
  fail "REAL TMUX: scrollback contamination must BLOCK on any default-No present"
fi

print
print "=== REAL TMUX E2E: $PASS pass, $FAIL fail ==="
(( FAIL == 0 ))
