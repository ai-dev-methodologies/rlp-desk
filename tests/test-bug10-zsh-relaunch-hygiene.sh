#!/bin/zsh
# Bug Report #10 — operator manual recovery hygiene (zsh side).
#
# Validates _validate_operator_recovery_artifacts in lib_ralph_desk.zsh.
# Five scenarios mirror the Node-side AC-R1..R5 contract:
#   Z1. All 5 checks pass        → return 0
#   Z2. missing done-claim       → return 1, reason mentions "missing"
#   Z3. us_id mismatch           → return 1, reason mentions "us_id"
#   Z4. signal_quality=generic   → return 1, reason mentions "specific"
#   Z5. mtime older than prompt  → return 1, reason mentions "mtime"
#
# Pattern mirrored from tests/test-bug7-post-sentinel-race.sh.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB_SCRIPT="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

if [[ ! -f "$LIB_SCRIPT" ]]; then
  print -u2 "FAIL: lib_ralph_desk.zsh not found at $LIB_SCRIPT"
  exit 1
fi

# --- Extract just the helper we need ---
TMP_LIB=$(mktemp -t bug10-helpers.XXXXXX)
WORK_DIR=""
trap 'rm -f "$TMP_LIB" 2>/dev/null; [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null; true' EXIT
sed -n '/^_validate_operator_recovery_artifacts()/,/^}/p' "$LIB_SCRIPT" >> "$TMP_LIB"

if [[ ! -s "$TMP_LIB" ]]; then
  print -u2 "FAIL: _validate_operator_recovery_artifacts not found in $LIB_SCRIPT"
  exit 1
fi

# Source the extracted helper
source "$TMP_LIB"

# Sanity check: helper must be defined now
if ! typeset -f _validate_operator_recovery_artifacts >/dev/null 2>&1; then
  print -u2 "FAIL: _validate_operator_recovery_artifacts could not be sourced"
  exit 1
fi

WORK_DIR=$(mktemp -d -t bug10-fixtures.XXXXXX)

# Helper to write a JSON fixture
_write_json() {
  local file="$1" content="$2"
  print -- "$content" > "$file"
}

# Helper to (re-)seed a complete valid set into $WORK_DIR with optional overrides
seed_valid_set() {
  local sig_us="${1:-US-001}" sig_iter="${2:-1}" sig_quality="${3:-specific}"
  local done_us="${4:-US-001}" done_iter="${5:-1}"
  local status_us="${6:-US-001}" status_iter="${7:-1}"
  local omit_done="${8:-0}"

  rm -f "$WORK_DIR"/*.json "$WORK_DIR"/iter-001.worker-prompt.md 2>/dev/null

  _write_json "$WORK_DIR/iter-signal.json" \
    "{\"iteration\":$sig_iter,\"status\":\"verify\",\"us_id\":\"$sig_us\",\"iter_signal_quality\":\"$sig_quality\",\"summary\":\"manual recovery\"}"

  if (( omit_done == 0 )); then
    _write_json "$WORK_DIR/done-claim.json" \
      "{\"iteration\":$done_iter,\"status\":\"verify\",\"us_id\":\"$done_us\",\"execution_steps\":[\"manual\"]}"
  fi

  _write_json "$WORK_DIR/status.json" \
    "{\"phase\":\"verify\",\"iteration\":$status_iter,\"current_us\":\"$status_us\"}"

  # worker-prompt with mtime older than the JSON files
  print -- "# old prompt" > "$WORK_DIR/iter-001.worker-prompt.md"
  # Force prompt mtime to 5s in the past so subsequent JSON writes are newer.
  local past_ts=$(( $(date +%s) - 5 ))
  touch -t $(date -r $past_ts +%Y%m%d%H%M.%S) "$WORK_DIR/iter-001.worker-prompt.md" 2>/dev/null \
    || touch -d "@$past_ts" "$WORK_DIR/iter-001.worker-prompt.md" 2>/dev/null
}

# Helper to make worker-prompt NEWER than artifacts (Z5 negative)
make_prompt_newer() {
  local future_ts=$(( $(date +%s) + 5 ))
  touch -t $(date -r $future_ts +%Y%m%d%H%M.%S) "$WORK_DIR/iter-001.worker-prompt.md" 2>/dev/null \
    || touch -d "@$future_ts" "$WORK_DIR/iter-001.worker-prompt.md" 2>/dev/null
}

PASS=0
FAIL=0

# Helper to record + report results
_check() {
  local label="$1" expected_rc="$2" actual_rc="$3" reason_substring="${4:-}"
  if [[ "$actual_rc" == "$expected_rc" ]]; then
    if [[ -n "$reason_substring" && "${RECOVERY_FAIL_REASON:-}" != *"$reason_substring"* ]]; then
      print "FAIL: $label — rc OK ($actual_rc) but RECOVERY_FAIL_REASON missing '$reason_substring' (got: '${RECOVERY_FAIL_REASON:-}')"
      FAIL=$((FAIL+1))
      return
    fi
    print "PASS: $label (rc=$actual_rc${reason_substring:+, reason matches '$reason_substring'})"
    PASS=$((PASS+1))
  else
    print "FAIL: $label — expected rc=$expected_rc, got rc=$actual_rc (reason: '${RECOVERY_FAIL_REASON:-none}')"
    FAIL=$((FAIL+1))
  fi
}

# ────────────────────────────────────────────────────────────────────────
# Z1: all 5 checks pass
# ────────────────────────────────────────────────────────────────────────
seed_valid_set
_validate_operator_recovery_artifacts \
  "$WORK_DIR/iter-signal.json" \
  "$WORK_DIR/done-claim.json" \
  "$WORK_DIR/status.json" \
  "$WORK_DIR/iter-001.worker-prompt.md"
_check "Z1 all-pass" 0 $? ""

# ────────────────────────────────────────────────────────────────────────
# Z2: missing done-claim
# ────────────────────────────────────────────────────────────────────────
seed_valid_set "US-001" 1 specific "US-001" 1 "US-001" 1 1  # omit_done=1
_validate_operator_recovery_artifacts \
  "$WORK_DIR/iter-signal.json" \
  "$WORK_DIR/done-claim.json" \
  "$WORK_DIR/status.json" \
  "$WORK_DIR/iter-001.worker-prompt.md"
_check "Z2 missing-done-claim" 1 $? "missing"

# ────────────────────────────────────────────────────────────────────────
# Z3: us_id mismatch (status=US-001, iter-signal=US-002)
# ────────────────────────────────────────────────────────────────────────
seed_valid_set "US-002" 1 specific "US-001" 1 "US-001" 1
_validate_operator_recovery_artifacts \
  "$WORK_DIR/iter-signal.json" \
  "$WORK_DIR/done-claim.json" \
  "$WORK_DIR/status.json" \
  "$WORK_DIR/iter-001.worker-prompt.md"
_check "Z3 us_id-mismatch" 1 $? "us_id"

# ────────────────────────────────────────────────────────────────────────
# Z4: iter_signal_quality=generic
# ────────────────────────────────────────────────────────────────────────
seed_valid_set "US-001" 1 generic "US-001" 1 "US-001" 1
_validate_operator_recovery_artifacts \
  "$WORK_DIR/iter-signal.json" \
  "$WORK_DIR/done-claim.json" \
  "$WORK_DIR/status.json" \
  "$WORK_DIR/iter-001.worker-prompt.md"
_check "Z4 quality-generic" 1 $? "specific"

# ────────────────────────────────────────────────────────────────────────
# Z5: mtime older than worker-prompt
# ────────────────────────────────────────────────────────────────────────
seed_valid_set
make_prompt_newer
_validate_operator_recovery_artifacts \
  "$WORK_DIR/iter-signal.json" \
  "$WORK_DIR/done-claim.json" \
  "$WORK_DIR/status.json" \
  "$WORK_DIR/iter-001.worker-prompt.md"
_check "Z5 mtime-older" 1 $? "mtime"

# ────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────
print ""
print "Bug #10 hygiene: $PASS passed, $FAIL failed"

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
