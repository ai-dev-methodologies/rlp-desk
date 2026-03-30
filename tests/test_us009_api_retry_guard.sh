#!/usr/bin/env bash
# Test suite: US-003 — API Retry Guard

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

extract_fn() {
  local fn_name="$1"
  awk -v fn="$fn_name" '
    $0 ~ fn"\\(\\) \{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) {
            print
            in_fn=0
            next
          }
        }
      }
      print
    }
  ' "$RUN"
}

run_is_api_error() {
  local pane_text="$1"
  local tmpdir fn_body
  tmpdir=$(mktemp -d)

  fn_body=$(extract_fn "is_api_error")

  cat > "$tmpdir/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
if [[ "$1" == "capture-pane" ]]; then
  printf '%s' "$PANE_TEXT"
fi
TMUX_STUB
  chmod +x "$tmpdir/tmux"

  cat > "$tmpdir/harness.zsh" <<'ZSH'
#!/usr/bin/env zsh
PATH="${tmpdir}:$PATH"
export PATH
HARNESS_DIR="${0:h}"
tmux() {
  command "$HARNESS_DIR/tmux" "$@"
}
export PANE_TEXT

log() { :; }
log_debug() { echo "$*"; }
log_error() { echo "ERROR: $*"; }

ZSH
  printf '%s
' "$fn_body" >> "$tmpdir/harness.zsh"
  cat >> "$tmpdir/harness.zsh" <<'ZSH'
is_api_error "pane-1"
echo "$?"
ZSH

  chmod +x "$tmpdir/harness.zsh"

  local out
  out=$(PATH="$tmpdir:$PATH" PANE_TEXT="$pane_text" zsh --no-rcs --no-globalrcs "$tmpdir/harness.zsh" 2>&1)
  local rc="$out"
  rm -rf "$tmpdir"
  echo "$rc"
}

run_poll_for_signal() {
  local retries="$1"
  local interval="$2"
  local tmpdir fn_is_api fn_poll
  tmpdir=$(mktemp -d)

  fn_is_api=$(extract_fn "is_api_error")
  fn_poll=$(extract_fn "poll_for_signal")

  cat > "$tmpdir/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
if [[ "$1" == "capture-pane" ]]; then
  printf '%s' "ERROR: API request failed: 529"
elif [[ "$1" == "display-message" ]]; then
  if [[ "$2" == "-p" && "$3" == "#{pane_current_command}" ]]; then
    echo "claude"
  fi
fi
TMUX_STUB
  chmod +x "$tmpdir/tmux"

  cat > "$tmpdir/harness.zsh" <<'ZSH'
#!/usr/bin/env zsh
PATH="${tmpdir}:$PATH"
export PATH
HARNESS_DIR="${0:h}"
tmux() {
  command "$HARNESS_DIR/tmux" "$@"
}

log() { :; }
log_debug() { echo "$*"; }
log_error() { :; }
write_blocked_sentinel() { echo "BLOCKED:$1"; }
check_and_nudge_idle_pane() { :; }
check_heartbeat_exited() { return 1; }
check_heartbeat() { return 0; }
check_dead_pane() { return 1; }

export _API_MAX_RETRIES
export _API_RETRY_INTERVAL_S
ITERATION=1
ITER_TIMEOUT=5
POLL_INTERVAL=0
typeset -A LAST_PANE_CONTENT
typeset -A PANE_IDLE_SINCE

ZSH
  printf '%s
' "$fn_is_api" >> "$tmpdir/harness.zsh"
  printf '%s
' "$fn_poll" >> "$tmpdir/harness.zsh"
  cat >> "$tmpdir/harness.zsh" <<'ZSH'
poll_for_signal "$tmpdir/signal" "$tmpdir/missing-heartbeat" "pane-1" "$tmpdir/noop" "worker" >/tmp/poll.out 2>&1
RC=$?
cat /tmp/poll.out
echo "RC:$RC"
rm -f /tmp/poll.out
ZSH

  chmod +x "$tmpdir/harness.zsh"

  local out
  out=$(PATH="$tmpdir:$PATH" _API_MAX_RETRIES="$retries" _API_RETRY_INTERVAL_S="$interval" zsh --no-rcs --no-globalrcs "$tmpdir/harness.zsh" )
  echo "$out"
  rm -rf "$tmpdir"
}

# ---- AC1 ----
test_ac1_happy_529() {
  local rc
  rc=$(run_is_api_error "ERROR: 529 Overloaded")
  if [[ "$rc" == "0" ]]; then
    pass "AC1-happy: detects 529 in pane buffer"
  else
    fail "AC1-happy: did not detect 529 in pane buffer"
  fi
}

test_ac1_happy_500() {
  local rc
  rc=$(run_is_api_error "gateway error: 500")
  if [[ "$rc" == "0" ]]; then
    pass "AC1-happy: detects 500 in pane buffer"
  else
    fail "AC1-happy: did not detect 500 in pane buffer"
  fi
}

test_ac1_boundary_overloaded_casefold() {
  local rc
  rc=$(run_is_api_error "service temporarily OVERLOADED")
  if [[ "$rc" == "0" ]]; then
    pass "AC1-boundary: detection is case-insensitive for overloaded"
  else
    fail "AC1-boundary: case-sensitive overloaded detection"
  fi
}

# ---- AC2 ----
test_ac2_happy_defaults() {
  if [[ -f "$RUN" ]] && grep -q '_API_MAX_RETRIES="${_API_MAX_RETRIES:-5}"' "$RUN" && grep -q '_API_RETRY_INTERVAL_S="${_API_RETRY_INTERVAL_S:-30}"' "$RUN"; then
    pass "AC2-happy: default retries/interval are 5 and 30"
  else
    fail "AC2-happy: default retry settings are not 5/30"
  fi
}

test_ac2_happy_retry_log_and_blocks() {
  local out
  out=$(run_poll_for_signal 2 0)
  if echo "$out" | grep -q "\\[FLOW\\].*api_retry=1/2" && echo "$out" | grep -q "\\[FLOW\\].*api_retry=2/2" && echo "$out" | grep -q "RC:2"; then
    pass "AC2-happy: API retry path logs progress and exits after retry limit"
  else
    fail "AC2-happy: API retry path did not log/break correctly"
  fi
}

test_ac2_negative_wrong_retries_reject_non_api() {
  local out
  out=$(run_poll_for_signal 3 0)
  if echo "$out" | grep -q "api_retry=3/3"; then
    pass "AC2-negative: non-default retry settings propagate into logs"
  else
    fail "AC2-negative: non-default retry setting did not affect behavior"
  fi
}

# ---- AC3 ----
test_ac3_happy_normal_failure() {
  local rc
  rc=$(run_is_api_error "npm test failed: assertion mismatch")
  if [[ "$rc" == "1" ]]; then
    pass "AC3-happy: normal test-fail text is not API error"
  else
    fail "AC3-happy: normal test-fail text misclassified as API error"
  fi
}

test_ac3_boundary_near_match_not_api() {
  local rc
  rc=$(run_is_api_error "exit code 5000")
  if [[ "$rc" == "1" ]]; then
    pass "AC3-boundary: near-match 5000 is not treated as API error"
  else
    fail "AC3-boundary: near-match 5000 misclassified as API error"
  fi
}

test_ac3_negative_no_api_retry_on_normal_failure() {
  local rc
  rc=$(run_is_api_error "No tokens left in budget")
  if [[ "$rc" == "1" ]]; then
    pass "AC3-negative: non-API failure avoids API retry path"
  else
    fail "AC3-negative: non-API failure was misclassified as API error"
  fi
}

# ---- AC4 ----
test_ac4_happy_blocked_message() {
  local out
  out=$(run_poll_for_signal 2 0)
  if echo "$out" | grep -q "BLOCKED:API unavailable after 2 retries"; then
    pass "AC4-happy: API exhaustion blocked with retry-count message"
  else
    fail "AC4-happy: API exhaustion message missing count"
  fi
}

test_ac4_boundary_exit_code_2() {
  local out
  out=$(run_poll_for_signal 1 0)
  if echo "$out" | grep -q "RC:2"; then
    pass "AC4-boundary: API exhaustion returns dedicated return code 2"
  else
    fail "AC4-boundary: dedicated return code 2 missing"
  fi
}

test_ac4_negative_exhaustion_blocks() {
  local out
  out=$(run_poll_for_signal 2 0)
  if echo "$out" | grep -q "RC:2" && echo "$out" | grep -q "API unavailable after 2 retries"; then
    pass "AC4-negative: API retry exhaustion blocks"
  else
    fail "AC4-negative: API retry exhaustion did not block"
  fi
}

# ---- Execution ----

echo "=== US-003: API Retry Guard (pane-buffer) ==="
echo "Target: $RUN"

printf '\n--- AC1: API error detection ---\n'
test_ac1_happy_529
test_ac1_happy_500
test_ac1_boundary_overloaded_casefold

printf '\n--- AC2: Retry behavior ---\n'
test_ac2_happy_defaults
test_ac2_happy_retry_log_and_blocks
test_ac2_negative_wrong_retries_reject_non_api

printf '\n--- AC3: Normal failure separation ---\n'
test_ac3_happy_normal_failure
test_ac3_boundary_near_match_not_api
test_ac3_negative_no_api_retry_on_normal_failure

printf '\n--- AC4: API exhaustion handling ---\n'
test_ac4_happy_blocked_message
test_ac4_boundary_exit_code_2
test_ac4_negative_exhaustion_blocks

echo "\n=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
