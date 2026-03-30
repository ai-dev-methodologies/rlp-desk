#!/usr/bin/env bash
# Test Suite: US-005 — --final-consensus option
# PRD: AC1 (no flag → opus solo), AC2 (flag + codex → both engines), AC3 (flag + no codex → error)
# IL-4: 3 ACs × 3 = 9 minimum; this suite has 12 tests (AC1:3, AC2:4, AC3:3, L3:2)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() {
  local got="$1" expected="$2" label="$3"
  if [[ "$got" == "$expected" ]]; then pass "$label"; else fail "$label (got '$got', expected '$expected')"; fi
}

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

SHOULD_RC=0

# Helper: extract _should_use_consensus from run_ralph_desk.zsh and invoke in zsh subshell.
# Sets SHOULD_RC=0 if consensus should be used, SHOULD_RC=1 if not, SHOULD_RC=127 if func missing.
_run_should_use_consensus() {
  local signal_us_id="$1"
  local fc="${2:-0}"  # FINAL_CONSENSUS
  local vc="${3:-0}"  # VERIFY_CONSENSUS
  local cs="${4:-all}"  # CONSENSUS_SCOPE

  local func_body
  func_body=$(sed -n '/^_should_use_consensus() {$/,/^}$/p' "$RUN" 2>/dev/null)
  if [[ -z "$func_body" ]]; then
    SHOULD_RC=127
    return
  fi

  local tmp_script
  tmp_script=$(mktemp /tmp/us005_XXXXXX.zsh)
  {
    printf 'FINAL_CONSENSUS=%s\n' "$fc"
    printf 'VERIFY_CONSENSUS=%s\n' "$vc"
    printf 'CONSENSUS_SCOPE=%s\n' "$cs"
    printf '%s\n' "$func_body"
    printf "_should_use_consensus '%s'\n" "$signal_us_id"
    printf 'exit $?\n'
  } > "$tmp_script"
  zsh "$tmp_script" >/dev/null 2>&1
  SHOULD_RC=$?
  rm -f "$tmp_script"
}

_func_or_fail() {
  local label="$1"
  if [[ "$SHOULD_RC" -eq 127 ]]; then
    fail "$label (_should_use_consensus not found in run_ralph_desk.zsh)"
    return 1
  fi
  return 0
}

# Build a restricted PATH with jq/tmux/claude but NO codex (for AC3 tests)
TMP_BINS="$(mktemp -d)"; TMPDIRS+=("$TMP_BINS")
for _tool in jq tmux claude zsh; do
  _bin=$(command -v "$_tool" 2>/dev/null || true)
  [[ -x "$_bin" ]] && ln -sf "$_bin" "$TMP_BINS/$_tool" 2>/dev/null || true
done
unset _tool _bin
# Include standard system dirs for cut/date/md5 etc., but exclude dirs containing codex
# codex is typically in /opt/homebrew/bin or /usr/local/bin, not /usr/bin or /bin
NOCODEX_PATH="$TMP_BINS:/usr/bin:/bin"

# Empty ZDOTDIR prevents zsh from sourcing ~/.zshenv which would restore PATH
TMP_ZDOTDIR="$(mktemp -d)"; TMPDIRS+=("$TMP_ZDOTDIR")

TMP_NOCODEX="$(mktemp -d)"; TMPDIRS+=("$TMP_NOCODEX")
mkdir -p "$TMP_NOCODEX/.claude/ralph-desk/logs/testslug"

echo "=== US-005: --final-consensus option ==="
echo ""

# ============================================================
# AC1: No --final-consensus flag → single engine (no consensus)
# ============================================================
echo "--- AC1: No flag → opus solo (single engine) ---"

# AC1-L1-1: FINAL_CONSENSUS variable default is 0
c=$(grep -c 'FINAL_CONSENSUS.*:-0' "$RUN" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "AC1-L1-1: FINAL_CONSENSUS defaults to 0"
else
  fail "AC1-L1-1: FINAL_CONSENSUS defaults to 0 (not found in $RUN)"
fi

# AC1-L1-2: without FINAL_CONSENSUS, ALL signal → no consensus
_run_should_use_consensus "ALL" "0" "0" "all"
if _func_or_fail "AC1-L1-2: FINAL_CONSENSUS=0 + ALL → no consensus"; then
  if [[ "$SHOULD_RC" -ne 0 ]]; then
    pass "AC1-L1-2: FINAL_CONSENSUS=0 + ALL → _should_use_consensus returns false (no consensus)"
  else
    fail "AC1-L1-2: FINAL_CONSENSUS=0 + ALL → expected no consensus, got use_consensus=true"
  fi
fi

# AC1-L1-3: without FINAL_CONSENSUS, non-ALL signal → no consensus
_run_should_use_consensus "US-001" "0" "0" "all"
if _func_or_fail "AC1-L1-3: FINAL_CONSENSUS=0 + US-001 → no consensus"; then
  if [[ "$SHOULD_RC" -ne 0 ]]; then
    pass "AC1-L1-3: FINAL_CONSENSUS=0 + US-001 → no consensus"
  else
    fail "AC1-L1-3: FINAL_CONSENSUS=0 + US-001 → expected no consensus"
  fi
fi

# AC1-L1-4 (boundary): VERIFY_CONSENSUS=1 CONSENSUS_SCOPE=final-only non-ALL signal → no consensus
# final-only scope only triggers for ALL; non-ALL signals are not promoted to consensus
_run_should_use_consensus "US-001" "0" "1" "final-only"
if _func_or_fail "AC1-L1-4: VERIFY_CONSENSUS=1 final-only + non-ALL → no consensus"; then
  if [[ "$SHOULD_RC" -ne 0 ]]; then
    pass "AC1-L1-4: VERIFY_CONSENSUS=1 CONSENSUS_SCOPE=final-only + US-001 → no consensus (boundary: non-ALL not promoted)"
  else
    fail "AC1-L1-4: final-only scope with non-ALL signal should NOT trigger consensus"
  fi
fi

# AC1-L1-5 (negative): FINAL_CONSENSUS=0 reflected as 0 in startup log (not accidentally enabled)
TMP_NOFC="$(mktemp -d)"; TMPDIRS+=("$TMP_NOFC")
mkdir -p "$TMP_NOFC/.claude/ralph-desk/logs/nofcslug"
NOFC_OUT=$(LOOP_NAME=nofcslug ROOT="$TMP_NOFC" TMUX=test FINAL_CONSENSUS=0 \
  zsh "$RUN" 2>/dev/null || true)
fc_count=$(echo "$NOFC_OUT" | grep -c "Final consensus: 0" 2>/dev/null) || fc_count=0
if [[ "$fc_count" -ge 1 ]]; then
  pass "AC1-L1-5: FINAL_CONSENSUS=0 → startup log shows 'Final consensus: 0' (negative: not accidentally 1)"
else
  fail "AC1-L1-5: startup log should show 'Final consensus: 0' when flag absent (got: '$(echo "$NOFC_OUT" | grep -i "consensus" | head -3)')"
fi

echo ""

# ============================================================
# AC2: --final-consensus + codex available → both engines called
# ============================================================
echo "--- AC2: Flag set + codex → both engines ---"

# AC2-L1-1: FINAL_CONSENSUS=1 + ALL signal → use consensus
_run_should_use_consensus "ALL" "1" "0" "all"
if _func_or_fail "AC2-L1-1: FINAL_CONSENSUS=1 + ALL → use consensus"; then
  if [[ "$SHOULD_RC" -eq 0 ]]; then
    pass "AC2-L1-1: FINAL_CONSENSUS=1 + ALL → _should_use_consensus returns true"
  else
    fail "AC2-L1-1: FINAL_CONSENSUS=1 + ALL → expected use_consensus=true, got false"
  fi
fi

# AC2-L1-2: FINAL_CONSENSUS=1 + non-ALL signal → no consensus (per-US not affected)
_run_should_use_consensus "US-001" "1" "0" "all"
if _func_or_fail "AC2-L1-2: FINAL_CONSENSUS=1 + US-001 → no consensus for non-ALL"; then
  if [[ "$SHOULD_RC" -ne 0 ]]; then
    pass "AC2-L1-2: FINAL_CONSENSUS=1 + US-001 (non-ALL) → no consensus"
  else
    fail "AC2-L1-2: FINAL_CONSENSUS=1 + US-001 → expected no consensus for non-ALL signals"
  fi
fi

# AC2-L1-3: FINAL_CONSENSUS=1 works independently of VERIFY_CONSENSUS=0
_run_should_use_consensus "ALL" "1" "0" "all"
if _func_or_fail "AC2-L1-3: FINAL_CONSENSUS=1 independent of VERIFY_CONSENSUS"; then
  if [[ "$SHOULD_RC" -eq 0 ]]; then
    pass "AC2-L1-3: FINAL_CONSENSUS=1 triggers consensus independently of VERIFY_CONSENSUS=0"
  else
    fail "AC2-L1-3: FINAL_CONSENSUS=1 should trigger consensus even when VERIFY_CONSENSUS=0"
  fi
fi

# AC2-L1-4: check_dependencies references FINAL_CONSENSUS for codex requirement
c=$(grep -c 'FINAL_CONSENSUS' "$RUN" 2>/dev/null) || c=0
# Must appear at least 2 times: variable init + dependency check
if [[ "$c" -ge 2 ]]; then
  pass "AC2-L1-4: FINAL_CONSENSUS referenced in dependency check"
else
  fail "AC2-L1-4: FINAL_CONSENSUS must appear in dependency check (found $c occurrences, need >= 2)"
fi

echo ""

# ============================================================
# AC3: --final-consensus without codex → error before loop
# ============================================================
echo "--- AC3: Flag set + no codex → error before start ---"

# AC3-L1-1: FINAL_CONSENSUS=1 + codex missing → exit code 1
AC3_EXIT=0
LOOP_NAME=testslug ROOT="$TMP_NOCODEX" TMUX=test FINAL_CONSENSUS=1 \
  PATH="$NOCODEX_PATH" ZDOTDIR="$TMP_ZDOTDIR" \
  zsh "$RUN" >/dev/null 2>&1 || AC3_EXIT=$?
assert_eq "$AC3_EXIT" "1" "AC3-L1-1: FINAL_CONSENSUS=1 + no codex → exit code 1"

# AC3-L1-2: error message mentions npm install
AC3_ERR=$(LOOP_NAME=testslug ROOT="$TMP_NOCODEX" TMUX=test FINAL_CONSENSUS=1 \
  PATH="$NOCODEX_PATH" ZDOTDIR="$TMP_ZDOTDIR" \
  zsh "$RUN" 2>&1 || true)
c=$(echo "$AC3_ERR" | grep -ci "npm install" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "AC3-L1-2: error message mentions npm install"
else
  fail "AC3-L1-2: error message should mention npm install (output: '$(echo "$AC3_ERR" | head -3)')"
fi

# AC3-L1-3: campaign loop does NOT start (no "Iteration" in output)
AC3_COMBINED=$(LOOP_NAME=testslug ROOT="$TMP_NOCODEX" TMUX=test FINAL_CONSENSUS=1 \
  PATH="$NOCODEX_PATH" ZDOTDIR="$TMP_ZDOTDIR" \
  zsh "$RUN" 2>&1 || true)
c=$(echo "$AC3_COMBINED" | grep -c "Iteration " 2>/dev/null) || c=0
if [[ "$c" -eq 0 ]]; then
  pass "AC3-L1-3: main loop does NOT start when codex missing + FINAL_CONSENSUS=1"
else
  fail "AC3-L1-3: main loop should NOT start (got 'Iteration' in output)"
fi

echo ""

# ============================================================
# L3 E2E
# ============================================================
echo "--- L3 E2E ---"

# L3-E2E-1: zsh -n syntax check passes after implementation
SYNTAX_OUT=$(zsh -n "$RUN" 2>&1)
SYNTAX_RC=$?
assert_eq "$SYNTAX_RC" "0" "L3-E2E-1: zsh -n syntax check passes"

# L3-E2E-2: --final-consensus CLI flag reflected in startup log
TMP_L3="$(mktemp -d)"; TMPDIRS+=("$TMP_L3")
mkdir -p "$TMP_L3/.claude/ralph-desk/logs/e2eslug"
L3_OUT=$(LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --final-consensus 2>/dev/null || true)
c=$(echo "$L3_OUT" | grep -ci "final.consensus.*1\|final consensus.*1" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "L3-E2E-2: --final-consensus flag reflected in startup log"
else
  fail "L3-E2E-2: --final-consensus flag should appear in startup log (output: '$(echo "$L3_OUT" | head -8)')"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
