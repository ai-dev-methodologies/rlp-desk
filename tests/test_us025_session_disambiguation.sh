#!/usr/bin/env bash
# Test Suite: US-025 — R13 P0 Detached session protection + new-session exit-code verify
# Validates:
#   - run_ralph_desk.zsh checks tmux new-session exit code
#   - RLP_BACKGROUND=1 + collision → SESSION_NAME suffix `-bg-$(date +%s)-$$` + has-session loop
#   - destroy-unattached off applied
#   - Limits documented (manual kill / server restart not protected)

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"

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

echo "=== US-025: R13 P0 Detached session protection ==="
echo

# AC1: tmux new-session exit-code check exists
assert_one "$RUN" 'tmux new-session.*\|\| ' \
  "AC1-a: tmux new-session exit code branch present"
assert_one "$RUN" 'has-session -t.*SESSION_NAME' \
  "AC1-b: has-session validation post-new-session"

# AC2: RLP_BACKGROUND=1 collision → -bg-$(date +%s)-$$ suffix
assert_one "$RUN" 'SESSION_NAME=.*-bg-' \
  "AC2-a: SESSION_NAME -bg- suffix on collision"
assert_one "$RUN" 'date \+%s.*\$\$' \
  "AC2-b: epoch + pid suffix combination"
assert_one "$RUN" 'while tmux has-session -t.*SESSION_NAME' \
  "AC2-c: has-session loop for residual collision"

# AC3: destroy-unattached off
assert_one "$RUN" 'set-option.*destroy-unattached.*off' \
  "AC3: destroy-unattached off applied for RLP_BACKGROUND"

# AC4: known-limit comment for manual kill / server restart
assert_one "$RUN" 'kill-session.*server restart' \
  "AC4: known-limit (manual kill / server restart) documented in code comments"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
