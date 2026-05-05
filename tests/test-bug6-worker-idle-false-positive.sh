#!/bin/zsh
# v0.14.5 unit test — Bug Report #6 Fix-M.
#
# Validates two helpers + their interaction:
#   1. _worker_pane_has_signal()  — recognizes a valid worker iter-signal
#   2. check_no_progress()        — defers BLOCKED escalation when signal is on disk
#
# Mocks tmux, write_blocked_sentinel, and the global state so we can exercise
# the helpers without a live tmux server. Mirror of test_codex_idle_no_progress.sh
# (Bug #3) but on the worker side.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Extract just the helpers we need. _verifier_pane_has_verdict +
# _migrate_legacy_verdict are also extracted because check_no_progress
# calls them on every invocation.
TMP_LIB=$(mktemp -t bug6-worker-idle.XXXXXX)
sed -n '/^is_codex_idle_ui()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_migrate_legacy_verdict()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_verifier_pane_has_verdict()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_worker_pane_has_signal()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^check_no_progress()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"

# --- Stubs ------------------------------------------------------------------
log()       { :; }
log_error() { :; }
log_debug() { :; }

# Mocked clock so we can advance "now" deterministically.
MOCK_NOW=1000
_now_s() { print -- "$MOCK_NOW"; }

# Counter for write_blocked_sentinel calls so the test can assert.
WRITE_BLOCKED_CALLS=0
WRITE_BLOCKED_LAST_REASON=""
write_blocked_sentinel() {
  WRITE_BLOCKED_CALLS=$(( WRITE_BLOCKED_CALLS + 1 ))
  WRITE_BLOCKED_LAST_REASON="$1"
}

# Mocked tmux capture-pane: returns whatever is in MOCK_CAPTURE.
MOCK_CAPTURE=""
tmux() {
  if [[ "$1" == "capture-pane" ]]; then
    print -- "$MOCK_CAPTURE"
    return 0
  fi
  return 1
}

# Globals required by check_no_progress.
typeset -gA PANE_LAST_CONTENT_FOR_PROGRESS
typeset -gA PANE_LAST_CHANGE_TS
typeset -gA PANE_VERIFIER_TRACE_LOGGED
typeset -gA PANE_CODEX_IDLE_GRACED
PROGRESS_NO_CHANGE_TIMEOUT=600
CODEX_IDLE_GRACE_S=300
ITERATION=3
CURRENT_US="US-010"

source "$TMP_LIB"

PASS=0
FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (expected '$expected', got '$actual')"
    (( FAIL++ ))
  fi
}

# ---------------------------------------------------------------------------
# _worker_pane_has_signal — direct unit tests
# ---------------------------------------------------------------------------

TMP_DESK=$(mktemp -d -t bug6-worker-desk.XXXXXX)
mkdir -p "$TMP_DESK/memos"
SIGNAL_FILE="$TMP_DESK/memos/test-iter-signal.json"
WORKER_PANE="%w"
VERIFIER_PANE="%v"
FINAL_VERIFIER_PANE="%fv"
VERDICT_FILE="$TMP_DESK/memos/test-verify-verdict.json"
LEGACY_VERDICT_FILE=""

# Wrong pane → return 1.
print -- '{"slug":"foo","iteration":3,"us_id":"US-010","status":"verify","signal_type":"signal","summary":"x"}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%v"
assert_eq "worker helper: wrong pane (verifier) → return 1" 1 $?

# Worker pane + valid signal → return 0.
_worker_pane_has_signal "%w"
assert_eq "worker helper: worker pane + valid verify signal → return 0" 0 $?

# Worker pane + verify_partial → return 0.
print -- '{"iteration":3,"us_id":"US-010","status":"verify_partial","verified_acs":["a"]}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: verify_partial accepted → return 0" 0 $?

# Worker pane + status=fail → return 1.
print -- '{"iteration":3,"us_id":"US-010","status":"fail"}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: status=fail (not verify*) → return 1" 1 $?

# Worker pane + missing iteration → return 1.
print -- '{"us_id":"US-010","status":"verify"}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: missing iteration → return 1" 1 $?

# Worker pane + non-numeric iteration → return 1.
print -- '{"iteration":"three","us_id":"US-010","status":"verify"}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: non-numeric iteration → return 1" 1 $?

# Worker pane + missing us_id → return 1.
print -- '{"iteration":3,"status":"verify"}' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: missing us_id → return 1" 1 $?

# Worker pane + malformed JSON → return 1.
print -- 'not-json' > "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: malformed JSON → return 1" 1 $?

# Worker pane + missing file → return 1.
rm -f "$SIGNAL_FILE"
_worker_pane_has_signal "%w"
assert_eq "worker helper: missing SIGNAL_FILE → return 1" 1 $?

# Worker pane + empty SIGNAL_FILE var → return 1.
SAVED_SIGNAL_FILE="$SIGNAL_FILE"
SIGNAL_FILE=""
_worker_pane_has_signal "%w"
assert_eq "worker helper: empty SIGNAL_FILE var → return 1" 1 $?
SIGNAL_FILE="$SAVED_SIGNAL_FILE"

# Empty WORKER_PANE var → return 1.
SAVED_WORKER_PANE="$WORKER_PANE"
WORKER_PANE=""
_worker_pane_has_signal "%w"
assert_eq "worker helper: empty WORKER_PANE var → return 1" 1 $?
WORKER_PANE="$SAVED_WORKER_PANE"

# ---------------------------------------------------------------------------
# Scenario A: worker byte-stasis, NO signal → BLOCKED
# ---------------------------------------------------------------------------

# Reset state.
PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
PANE_CODEX_IDLE_GRACED=()
WRITE_BLOCKED_CALLS=0
WRITE_BLOCKED_LAST_REASON=""
rm -f "$SIGNAL_FILE"

MOCK_CAPTURE='❯ 계속 진행해
✻ Crunched for 13m 31s
⏵⏵ bypass permissions on'
MOCK_NOW=1000
check_no_progress "%w" "US-010" >/dev/null
A_INITIAL_RC=$?
assert_eq "Scenario A initial call: progress (return 0)" 0 $A_INITIAL_RC
assert_eq "Scenario A initial call: no BLOCKED" 0 "$WRITE_BLOCKED_CALLS"

# Same content, advance clock past PROGRESS_NO_CHANGE_TIMEOUT.
MOCK_NOW=$(( 1000 + PROGRESS_NO_CHANGE_TIMEOUT + 5 ))
check_no_progress "%w" "US-010" >/dev/null
A_FROZEN_RC=$?
assert_eq "Scenario A frozen call: BLOCKED escalation (return 1)" 1 $A_FROZEN_RC
assert_eq "Scenario A frozen call: write_blocked_sentinel invoked once" 1 "$WRITE_BLOCKED_CALLS"

# ---------------------------------------------------------------------------
# Scenario B: worker byte-stasis WITH valid signal → suppressed
# ---------------------------------------------------------------------------

PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
PANE_CODEX_IDLE_GRACED=()
WRITE_BLOCKED_CALLS=0
WRITE_BLOCKED_LAST_REASON=""
print -- '{"slug":"foo","iteration":3,"us_id":"US-010","status":"verify","signal_type":"signal","summary":"x"}' > "$SIGNAL_FILE"

MOCK_CAPTURE='❯ 계속 진행해
✻ Crunched for 13m 31s
⏵⏵ bypass permissions on'
MOCK_NOW=2000
check_no_progress "%w" "US-010" >/dev/null
B_INITIAL_RC=$?
assert_eq "Scenario B initial call: progress (return 0)" 0 $B_INITIAL_RC

MOCK_NOW=$(( 2000 + PROGRESS_NO_CHANGE_TIMEOUT + 5 ))
check_no_progress "%w" "US-010" >/dev/null
B_FROZEN_RC=$?
assert_eq "Scenario B frozen call: signal short-circuit (return 0)" 0 $B_FROZEN_RC
assert_eq "Scenario B frozen call: write_blocked_sentinel NOT invoked" 0 "$WRITE_BLOCKED_CALLS"

# ---------------------------------------------------------------------------
# Scenario C: worker byte-stasis with MALFORMED signal → BLOCKED still fires
# ---------------------------------------------------------------------------

PANE_LAST_CONTENT_FOR_PROGRESS=()
PANE_LAST_CHANGE_TS=()
PANE_CODEX_IDLE_GRACED=()
WRITE_BLOCKED_CALLS=0
WRITE_BLOCKED_LAST_REASON=""
print -- 'not-json' > "$SIGNAL_FILE"

MOCK_CAPTURE='❯ 계속 진행해
✻ Crunched for 13m 31s
⏵⏵ bypass permissions on'
MOCK_NOW=3000
check_no_progress "%w" "US-010" >/dev/null
C_INITIAL_RC=$?
assert_eq "Scenario C initial call: progress (return 0)" 0 $C_INITIAL_RC

MOCK_NOW=$(( 3000 + PROGRESS_NO_CHANGE_TIMEOUT + 5 ))
check_no_progress "%w" "US-010" >/dev/null
C_FROZEN_RC=$?
assert_eq "Scenario C frozen call: malformed signal does NOT short-circuit (return 1)" 1 $C_FROZEN_RC
assert_eq "Scenario C frozen call: write_blocked_sentinel invoked" 1 "$WRITE_BLOCKED_CALLS"

# ---------------------------------------------------------------------------
# Cleanup + summary
# ---------------------------------------------------------------------------

rm -rf "$TMP_DESK"
rm -f "$TMP_LIB"

print ""
print "=== summary: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
