#!/bin/zsh
# v5.7 §4.24 — Mechanical SV gate (FULL).
# Runs sv-gate-fast.sh + REAL tmux E2E + REAL campaign E2E.
# Target: < 6 min wallclock. Run before merge / release.
# Exit 0 = SV gate PASS. Anything non-zero = FAIL.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT" || exit 1

red()    { print -P "%F{red}$*%f"; }
green()  { print -P "%F{green}$*%f"; }
bold()   { print -P "%B$*%b"; }

bold "▶ SV Gate FULL — running fast gate first"
if ! zsh "$SCRIPT_DIR/sv-gate-fast.sh"; then
  red "Fast gate failed — aborting full gate"
  exit 1
fi

PASS_FULL=0
FAIL_FULL=0
check_full() {
  local label="$1"; shift
  if "$@"; then
    PASS_FULL=$((PASS_FULL+1))
    green "  ✓ $label"
  else
    FAIL_FULL=$((FAIL_FULL+1))
    red   "  ✗ $label"
  fi
}

bold ""
bold "▶ SV Gate FULL — REAL tmux E2E (mocked tmux capture)"
check_full "REAL tmux E2E (9 scenarios, in-repo)" zsh "$SCRIPT_DIR/sv-gate-real-e2e.sh"

bold ""
bold "▶ SV Gate FULL — REAL campaign E2E (haiku, max-iter 3, iter-timeout 300)"
# Verify a clean campaign run actually completes or BLOCKs with sentinel.
# Pre-conditions: TMUX env set, claude/node installed, ~/.claude/ralph-desk synced.
if [[ -z "${TMUX:-}" ]]; then
  red "  ✗ TMUX env not set — skip campaign E2E (must run inside tmux session)"
  FAIL_FULL=$((FAIL_FULL+1))
else
  CAMP="/tmp/rlp-sv-gate-camp-$$"
  rm -rf "$CAMP"
  mkdir -p "$CAMP" && cd "$CAMP" && git init -q . && git commit --allow-empty -q -m init
  zsh ~/.claude/ralph-desk/init_ralph_desk.zsh sumchk "Add a sum(a, b) function in src/sum.mjs that returns a+b, with one test in tests/sum.test.mjs that verifies sum(2,3)===5. JS only, no TS, no deps." 2>&1 | tail -1
  tmux kill-session -t rlp-sumchk 2>/dev/null
  node ~/.claude/ralph-desk/node/run.mjs run sumchk --mode tmux --max-iter 3 --iter-timeout 300 --debug --worker-model haiku --verifier-model haiku 2>&1 | tee "$CAMP/leader.log"
  EXIT_CODE=$?

  # Validate post-conditions: at least ONE sentinel must exist.
  if [[ -f "$CAMP/.claude/ralph-desk/memos/sumchk-complete.md" ]]; then
    green "  ✓ campaign produced complete.md (success path)"
    PASS_FULL=$((PASS_FULL+1))
  elif [[ -f "$CAMP/.claude/ralph-desk/memos/sumchk-blocked.md" ]]; then
    green "  ✓ campaign produced blocked.md (file-guarantee maintained)"
    PASS_FULL=$((PASS_FULL+1))
  else
    red "  ✗ campaign produced NEITHER complete NOR blocked sentinel — FILE-GUARANTEE VIOLATED"
    FAIL_FULL=$((FAIL_FULL+1))
  fi
  cd "$ROOT" || exit 1
  tmux kill-session -t rlp-sumchk 2>/dev/null
fi

bold ""
print "═════════════════════════════════════════════════"
if (( FAIL_FULL == 0 )); then
  green "▶ SV GATE FULL: $PASS_FULL pass — RELEASE READY"
else
  red   "▶ SV GATE FULL: $PASS_FULL pass, $FAIL_FULL FAIL — DO NOT MERGE"
fi
print "═════════════════════════════════════════════════"
exit $(( FAIL_FULL == 0 ? 0 : 1 ))
