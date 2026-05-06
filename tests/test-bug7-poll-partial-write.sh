#!/bin/zsh
# Bug Report #7-extra (BOS 2026-05-06) — partial-write race in zsh poll_for_signal.
#
# Symptom: poll_for_signal accepted any iter-signal.json that EXISTED on disk,
# even if Worker (claude opus via Claude Code's Write tool) was still
# mid-write and the file held truncated/empty JSON. Verifier was dispatched
# against a half-written sentinel.
#
# Fix: gate the success branch on `jq empty` validity. Empty / truncated /
# mid-write JSON keeps the poll loop alive; the next tick re-reads.
#
# This test asserts:
#   1. jq empty rejects partial JSON.
#   2. jq empty accepts a fully-formed sentinel.
#   3. The fix code is wired into run_ralph_desk.zsh's poll_for_signal.
#   4. Live race simulation: writer produces partial content first, completes
#      ~1s later — the gate rejects partial and accepts valid on a later tick.
#
# Pattern mirrored from tests/test-bug7-post-sentinel-race.sh and
# tests/sv-gate-fast.sh (grep-pattern guard).

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

if [[ ! -f "$RUN_SCRIPT" ]]; then
  print -u2 "FAIL: run_ralph_desk.zsh not found at $RUN_SCRIPT"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "FAIL: jq not installed; cannot exercise the partial-write guard"
  exit 1
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

ok()   { print "  PASS: $1"; TESTS_PASSED=$(( TESTS_PASSED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }
fail() { print -u2 "  FAIL: $1"; TESTS_FAILED=$(( TESTS_FAILED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }

TMP_DIR=$(mktemp -d -t bug7-partial.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Partial JSON is rejected by jq empty.
# ---------------------------------------------------------------------------
print ""
print "Scenario 1: jq empty rejects partial / truncated JSON"
PARTIAL="$TMP_DIR/iter-signal-partial.json"

# 1a. completely empty file (file appears, no content yet)
: > "$PARTIAL"
if jq -e . "$PARTIAL" >/dev/null 2>&1; then
  fail "jq empty incorrectly accepted an empty file"
else
  ok "jq empty rejects empty file"
fi

# 1b. truncated mid-object
print -n '{ "iteration": 1, ' > "$PARTIAL"
if jq -e . "$PARTIAL" >/dev/null 2>&1; then
  fail "jq empty incorrectly accepted truncated JSON"
else
  ok "jq empty rejects truncated mid-object"
fi

# 1c. opening brace only
print -n '{' > "$PARTIAL"
if jq -e . "$PARTIAL" >/dev/null 2>&1; then
  fail "jq empty incorrectly accepted '{'"
else
  ok "jq empty rejects bare opening brace"
fi

# ---------------------------------------------------------------------------
# 2. Valid JSON is accepted (no false negative on the happy path).
# ---------------------------------------------------------------------------
print ""
print "Scenario 2: jq empty accepts a complete iter-signal payload"
VALID="$TMP_DIR/iter-signal-valid.json"
print '{"iteration":1,"status":"verify","us_id":"US-001","summary":"test"}' > "$VALID"
if jq -e . "$VALID" >/dev/null 2>&1; then
  ok "jq empty accepts a complete iter-signal payload"
else
  fail "jq empty falsely rejected a valid sentinel"
fi

VALID_V="$TMP_DIR/verify-verdict-valid.json"
print '{"verdict":"pass","recommended_state_transition":"continue","iteration":1}' > "$VALID_V"
if jq -e . "$VALID_V" >/dev/null 2>&1; then
  ok "jq empty accepts a complete verify-verdict payload"
else
  fail "jq empty falsely rejected a valid verdict"
fi

# ---------------------------------------------------------------------------
# 3. The fix code is present in run_ralph_desk.zsh poll_for_signal.
#    Mirror of tests/sv-gate-fast.sh grep-pattern guards.
# ---------------------------------------------------------------------------
print ""
print "Scenario 3: poll_for_signal gates on jq empty before returning success"
if grep -q 'if jq -e \. "\$signal_file" >/dev/null 2>&1; then' "$RUN_SCRIPT"; then
  ok "poll_for_signal contains the jq -e . validity gate"
else
  fail "poll_for_signal is missing the jq -e . validity gate (Bug #7-extra fix not wired)"
fi

# ---------------------------------------------------------------------------
# 4. Live race simulation: writer produces partial JSON first, completes
#    1s later. Replays poll_for_signal's key decision (file present + jq
#    empty gate) against a real concurrent writer.
# ---------------------------------------------------------------------------
print ""
print "Scenario 4: live partial-then-complete writer is correctly gated"
SIGNAL="$TMP_DIR/iter-signal-live.json"
(
  # T+0.0s: file appears with partial content
  print -n '{ "iteration": 1, ' > "$SIGNAL"
  sleep 1
  # T+1.0s: writer completes
  print '{"iteration":1,"status":"verify","us_id":"US-001","summary":"live"}' > "$SIGNAL"
) &
WRITER_PID=$!

START=$(date +%s)
DEADLINE=$(( START + 5 ))
DETECTED_PARTIAL=0
DETECTED_VALID=0
while (( $(date +%s) < DEADLINE )); do
  if [[ -f "$SIGNAL" ]]; then
    if ! jq -e . "$SIGNAL" >/dev/null 2>&1; then
      DETECTED_PARTIAL=1
    else
      DETECTED_VALID=1
      break
    fi
  fi
  sleep 0.2
done
wait $WRITER_PID 2>/dev/null

if (( DETECTED_PARTIAL == 1 && DETECTED_VALID == 1 )); then
  ok "partial JSON observed and rejected, valid JSON accepted on later tick"
elif (( DETECTED_PARTIAL == 0 && DETECTED_VALID == 1 )); then
  # Race scheduling skipped the partial window — still a pass for the gate.
  ok "valid JSON accepted (partial window not observed; OK)"
else
  fail "live race: detected_partial=$DETECTED_PARTIAL detected_valid=$DETECTED_VALID"
fi

print ""
print "Bug #7-extra partial-write tests: ran=$TESTS_RUN passed=$TESTS_PASSED failed=$TESTS_FAILED"

if (( TESTS_FAILED > 0 )); then
  exit 1
fi
exit 0
