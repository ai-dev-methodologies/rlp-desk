#!/bin/zsh
# Bug Report #7 — post-sentinel process race fix integration tests.
#
# Three scenarios:
#   A. _kill_pane_process: a tmux pane running `sleep 600` (proxy for an idle
#      claude/codex TUI) returns to the shell within ~7s of the helper call.
#   B. _lock_sentinel / _unlock_sentinel: chmod 0444 / 0o644 round-trip on a
#      temp file. Tolerant of FS that silently ignore chmod (WSL1/NTFS/tmpfs).
#   C. (REAL_E2E gated) verdict-mtime drift smoke. Synthesizes a "producer
#      keeps writing" attempt against a locked sentinel and asserts mtime is
#      frozen. Skipped unless REAL_E2E=1.
#
# Pattern mirrored from tests/test-bug6-worker-idle-false-positive.sh.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB_SCRIPT="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

if [[ ! -f "$LIB_SCRIPT" ]]; then
  print -u2 "FAIL: lib_ralph_desk.zsh not found at $LIB_SCRIPT"
  exit 1
fi

# --- Extract just the bug-7 helpers we need (avoid side-effects of full source) -
TMP_LIB=$(mktemp -t bug7-helpers.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
sed -n '/^_kill_pane_process()/,/^}/p'  "$LIB_SCRIPT" >> "$TMP_LIB"
print ""                                              >> "$TMP_LIB"
sed -n '/^_lock_sentinel()/,/^}/p'      "$LIB_SCRIPT" >> "$TMP_LIB"
print ""                                              >> "$TMP_LIB"
sed -n '/^_unlock_sentinel()/,/^}/p'    "$LIB_SCRIPT" >> "$TMP_LIB"
print ""                                              >> "$TMP_LIB"

# Stubs the helpers reference (typeset -f checks make them optional, but stubs
# keep the test deterministic regardless of the host shell's prior state).
log_debug() { :; }
wait_for_pane_ready() {
  local pane_id="$1" timeout="${2:-5}"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local cmd
    cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || print "")
    if [[ "$cmd" == "zsh" || "$cmd" == "bash" || "$cmd" == "sh" ]]; then
      return 0
    fi
    sleep 0.2
  done
  return 0  # fail-open like the real helper
}

source "$TMP_LIB"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

ok()   { print "  PASS: $1"; TESTS_PASSED=$(( TESTS_PASSED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }
fail() { print -u2 "  FAIL: $1"; TESTS_FAILED=$(( TESTS_FAILED + 1 )); TESTS_RUN=$(( TESTS_RUN + 1 )); }
skip() { print "  SKIP: $1"; TESTS_SKIPPED=$(( TESTS_SKIPPED + 1 )); }

# ---------------------------------------------------------------------------
# Scenario A: _kill_pane_process returns the pane to shell within ~7s.
# ---------------------------------------------------------------------------
print ""
print "Scenario A: _kill_pane_process kills idle TUI proxy"
if ! command -v tmux >/dev/null 2>&1; then
  skip "tmux not installed; cannot exercise pane lifecycle"
else
  SESSION="bug7-test-$$"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  PANE_ID=$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" 2>/dev/null)
  if [[ -z "$PANE_ID" ]]; then
    fail "could not create tmux test session"
  else
    tmux send-keys -t "$PANE_ID" 'sleep 600' C-m
    sleep 0.8
    BEFORE_CMD=$(tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null)
    if [[ "$BEFORE_CMD" != "sleep" ]]; then
      fail "expected pane to be running 'sleep' (got '$BEFORE_CMD')"
    else
      START=$(date +%s)
      _kill_pane_process "$PANE_ID" "test"
      ELAPSED=$(( $(date +%s) - START ))
      AFTER_CMD=$(tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null)
      if [[ "$AFTER_CMD" == "zsh" || "$AFTER_CMD" == "bash" || "$AFTER_CMD" == "sh" ]]; then
        if (( ELAPSED <= 7 )); then
          ok "pane returned to shell ($AFTER_CMD) in ${ELAPSED}s"
        else
          fail "pane returned to shell but took too long (${ELAPSED}s)"
        fi
      else
        fail "pane still running '$AFTER_CMD' after _kill_pane_process (${ELAPSED}s elapsed)"
      fi
      # Plan Verification end-to-end §5: capture-pane must not show ongoing
      # claude/codex TUI activity ('esc to interrupt', 'Working...', 'Worked
      # for Xm') after the reaper has fired.
      AFTER_CAPTURE=$(tmux capture-pane -p -t "$PANE_ID" 2>/dev/null || true)
      if echo "$AFTER_CAPTURE" | grep -qE 'esc to interrupt|Working\.\.\.|Worked for [0-9]+m'; then
        fail "pane still shows TUI activity markers post-reap"
      else
        ok "pane has no residual TUI activity markers post-reap"
      fi
    fi
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Scenario B: _lock_sentinel + _unlock_sentinel chmod round-trip.
# ---------------------------------------------------------------------------
print ""
print "Scenario B: _lock_sentinel / _unlock_sentinel chmod round-trip"
TMP_DIR=$(mktemp -d -t bug7-lock.XXXXXX)
TARGET="$TMP_DIR/verify-verdict.json"
print '{"verdict":"pass"}' > "$TARGET"

ORIG_MODE=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET" 2>/dev/null)
_lock_sentinel "$TARGET"
LOCKED_MODE=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET" 2>/dev/null)
if [[ "$LOCKED_MODE" == "444" ]]; then
  ok "lock set mode to 0444"
elif [[ "$LOCKED_MODE" == "$ORIG_MODE" ]]; then
  skip "filesystem ignores chmod (locked=$LOCKED_MODE == orig=$ORIG_MODE) — graceful degradation OK"
else
  fail "unexpected mode after lock: orig=$ORIG_MODE locked=$LOCKED_MODE"
fi

_unlock_sentinel "$TARGET"
UNLOCKED_MODE=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET" 2>/dev/null)
case "$UNLOCKED_MODE" in
  644|664|666)
    ok "unlock restored writable mode ($UNLOCKED_MODE)"
    ;;
  *)
    if [[ "$UNLOCKED_MODE" == "$ORIG_MODE" ]]; then
      skip "filesystem ignores chmod ($UNLOCKED_MODE) — graceful degradation OK"
    else
      fail "unexpected mode after unlock: $UNLOCKED_MODE"
    fi
    ;;
esac

if rm -f "$TARGET" 2>/dev/null && [[ ! -e "$TARGET" ]]; then
  ok "rm -f works after lock/unlock cycle"
else
  fail "could not rm sentinel after unlock"
fi

# Idempotence: missing-file calls are no-ops.
if _lock_sentinel "$TMP_DIR/never-existed.json" && _unlock_sentinel "$TMP_DIR/never-existed.json"; then
  ok "lock/unlock on missing file are no-ops"
else
  fail "lock/unlock raised on missing file"
fi

rm -rf "$TMP_DIR"

# ---------------------------------------------------------------------------
# Scenario C (REAL_E2E gated): verdict-mtime drift smoke.
# ---------------------------------------------------------------------------
print ""
print "Scenario C: verdict-mtime drift smoke (REAL_E2E only)"
if [[ "${REAL_E2E:-0}" != "1" ]]; then
  skip "REAL_E2E!=1; skipping heavy live-campaign check"
else
  TMP_DIR=$(mktemp -d -t bug7-e2e.XXXXXX)
  TARGET="$TMP_DIR/verify-verdict.json"
  print '{"verdict":"pass","iteration":1}' > "$TARGET"
  _lock_sentinel "$TARGET"
  T0=$(stat -f '%m' "$TARGET" 2>/dev/null || stat -c '%Y' "$TARGET" 2>/dev/null)
  print '{"verdict":"fail","iteration":99}' > "$TARGET" 2>/dev/null || true
  T1=$(stat -f '%m' "$TARGET" 2>/dev/null || stat -c '%Y' "$TARGET" 2>/dev/null)
  if [[ "$T0" == "$T1" ]]; then
    ok "verdict mtime frozen after lock (T0=$T0 T1=$T1)"
  else
    LOCKED_MODE=$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET" 2>/dev/null)
    if [[ "$LOCKED_MODE" != "444" ]]; then
      skip "filesystem ignored chmod (mode=$LOCKED_MODE) — kill-Q remains primary defense"
    else
      fail "verdict mtime drifted despite lock (T0=$T0 T1=$T1, mode=$LOCKED_MODE)"
    fi
  fi
  rm -rf "$TMP_DIR"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print ""
print "Bug #7 helper integration tests: ran=$TESTS_RUN passed=$TESTS_PASSED failed=$TESTS_FAILED skipped=$TESTS_SKIPPED"

if (( TESTS_FAILED > 0 )); then
  exit 1
fi
exit 0
