#!/usr/bin/env bash
# Test Suite: US-003 — Unified --worker-model and --verifier-model format
# PRD: AC1 (colon format → codex), AC2 (plain name → claude), AC3 (invalid → error, exit 1)
# IL-4: 3 ACs × 3 = 9 minimum; this suite has 18 tests (AC1:6, AC2:5, AC3:4, L3:3)

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

PARSE_STDOUT=""
PARSE_STDERR=""
PARSE_EXIT=0

# Helper: extract parse_model_flag from run_ralph_desk.zsh and invoke it in a zsh subshell
_run_parse() {
  local value="$1" role="${2:-worker}"
  local func_body
  func_body=$(sed -n '/^parse_model_flag() {$/,/^}$/p' "$RUN" 2>/dev/null)
  if [[ -z "$func_body" ]]; then
    PARSE_STDOUT=""
    PARSE_STDERR="ERROR: parse_model_flag not found in $RUN"
    PARSE_EXIT=1
    return
  fi
  local tmp_script tmpout tmperr
  tmp_script=$(mktemp /tmp/us003_XXXXXX.zsh)
  tmpout=$(mktemp); tmperr=$(mktemp)
  printf '%s\n' "$func_body" > "$tmp_script"
  printf "parse_model_flag '%s' '%s'\n" "$value" "$role" >> "$tmp_script"
  zsh "$tmp_script" > "$tmpout" 2> "$tmperr"
  PARSE_EXIT=$?
  PARSE_STDOUT=$(cat "$tmpout")
  PARSE_STDERR=$(cat "$tmperr")
  rm -f "$tmp_script" "$tmpout" "$tmperr"
}

# Guard: skip assertion and fail if parse_model_flag not found in script
_func_or_fail() {
  local label="$1"
  if [[ "$PARSE_STDERR" == *"parse_model_flag not found"* ]]; then
    fail "$label (parse_model_flag not found in run_ralph_desk.zsh)"
    return 1
  fi
  return 0
}

echo "=== US-003: Unified --worker-model and --verifier-model format ==="
echo ""

# ============================================================
# AC1: Colon format → codex engine (engine, model, reasoning)
# ============================================================
echo "--- AC1: Colon format parsed as codex ---"

_run_parse "gpt-5.4:medium" "worker"
if _func_or_fail "AC1-L1-1: gpt-5.4:medium → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-1: gpt-5.4:medium → engine=codex"
fi

_run_parse "gpt-5.4:medium" "worker"
if _func_or_fail "AC1-L1-2: gpt-5.4:medium → model=gpt-5.4"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.4" \
    "AC1-L1-2: gpt-5.4:medium → model=gpt-5.4"
fi

_run_parse "gpt-5.4:medium" "worker"
if _func_or_fail "AC1-L1-3: gpt-5.4:medium → reasoning=medium"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "medium" \
    "AC1-L1-3: gpt-5.4:medium → reasoning=medium"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-4: gpt-5.3-codex-spark:high → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-4: gpt-5.3-codex-spark:high → engine=codex"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-5: gpt-5.3-codex-spark:high → model=spark (alias)"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "spark" \
    "AC1-L1-5: gpt-5.3-codex-spark:high → model=spark (alias)"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-6: gpt-5.3-codex-spark:high → reasoning=high"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-6: gpt-5.3-codex-spark:high → reasoning=high"
fi

# AC1-L1-7 (boundary): colon format with empty reasoning still detected as codex
_run_parse "gpt-5.4:" "worker"
if _func_or_fail "AC1-L1-7: gpt-5.4: (empty reasoning) → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-7: gpt-5.4: boundary (empty reasoning) → still engine=codex"
fi

# AC1-L1-8 (negative): identical model name without colon → NOT codex (proves colon is required)
_run_parse "gpt-5.4" "worker"
if _func_or_fail "AC1-L1-8: gpt-5.4 (no colon) → NOT codex"; then
  engine="$(echo "$PARSE_STDOUT" | awk '{print $1}')"
  if [[ "$engine" != "codex" ]]; then
    pass "AC1-L1-8: gpt-5.4 (no colon) → engine=$engine, proves colon required for codex"
  else
    fail "AC1-L1-8: gpt-5.4 without colon must NOT be codex engine (colon is required)"
  fi
fi

echo ""

# ============================================================
# AC2: Plain name → claude engine
# ============================================================
echo "--- AC2: Plain name parsed as claude ---"

_run_parse "sonnet" "worker"
if _func_or_fail "AC2-L1-1: sonnet → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC2-L1-1: sonnet → engine=claude"
fi

_run_parse "sonnet" "worker"
if _func_or_fail "AC2-L1-2: sonnet → model=sonnet"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "sonnet" \
    "AC2-L1-2: sonnet → model=sonnet"
fi

_run_parse "haiku" "verifier"
if _func_or_fail "AC2-L1-3: haiku → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC2-L1-3: haiku → engine=claude"
fi

_run_parse "haiku" "verifier"
if _func_or_fail "AC2-L1-4: haiku → model=haiku"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "haiku" \
    "AC2-L1-4: haiku → model=haiku"
fi

_run_parse "opus" "worker"
if _func_or_fail "AC2-L1-5: opus → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC2-L1-5: opus → engine=claude"
fi

echo ""

# ============================================================
# AC3: Invalid model format → error message + exit 1
# ============================================================
echo "--- AC3: Invalid format rejected ---"

_run_parse "invalid:format:extra" "worker"
if _func_or_fail "AC3-L1-1: invalid:format:extra → exit 1"; then
  assert_eq "$PARSE_EXIT" "1" "AC3-L1-1: invalid:format:extra → exit code 1"
fi

_run_parse "invalid:format:extra" "worker"
if _func_or_fail "AC3-L1-2: error message on stderr"; then
  c=$(echo "$PARSE_STDERR" | grep -ci "error\|invalid" 2>/dev/null) || c=0
  if [[ "$c" -ge 1 ]]; then
    pass "AC3-L1-2: invalid:format:extra → error message on stderr"
  else
    fail "AC3-L1-2: invalid:format:extra → error message on stderr (got: '$PARSE_STDERR')"
  fi
fi

_run_parse "a:b:c:d" "worker"
if _func_or_fail "AC3-L1-3: a:b:c:d → exit 1"; then
  assert_eq "$PARSE_EXIT" "1" "AC3-L1-3: a:b:c:d (multiple extra colons) → exit code 1"
fi

_run_parse "bad:bad:bad" "worker"
if _func_or_fail "AC3-L1-4: error mentions role name"; then
  c=$(echo "$PARSE_STDERR" | grep -c "worker" 2>/dev/null) || c=0
  if [[ "$c" -ge 1 ]]; then
    pass "AC3-L1-4: error message references --worker-model flag name"
  else
    fail "AC3-L1-4: error message references --worker-model flag name (got: '$PARSE_STDERR')"
  fi
fi

echo ""

# ============================================================
# L3 E2E: --worker-model / --verifier-model flags applied at script startup
# ============================================================
echo "--- L3 E2E: flag application in startup log ---"

TMP_L3="$(mktemp -d)"; TMPDIRS+=("$TMP_L3")
mkdir -p "$TMP_L3/.claude/ralph-desk/plans" \
         "$TMP_L3/.claude/ralph-desk/memos" \
         "$TMP_L3/.claude/ralph-desk/prompts" \
         "$TMP_L3/.claude/ralph-desk/context" \
         "$TMP_L3/.claude/ralph-desk/logs/e2eslug"
touch "$TMP_L3/.claude/ralph-desk/plans/prd-e2eslug.md"

# L3-E2E-1: --worker-model gpt-5.4:medium → startup log shows gpt-5.4
L3_OUT_1=$(LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --worker-model gpt-5.4:medium 2>/dev/null || true)
c=$(echo "$L3_OUT_1" | grep -c "gpt-5.4" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "L3-E2E-1: --worker-model gpt-5.4:medium → startup log shows gpt-5.4"
else
  fail "L3-E2E-1: --worker-model gpt-5.4:medium → startup log shows gpt-5.4 (output: '$(echo "$L3_OUT_1" | head -5)')"
fi

# L3-E2E-2: --verifier-model sonnet → startup log shows sonnet
L3_OUT_2=$(LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --worker-model gpt-5.4:medium --verifier-model sonnet 2>/dev/null || true)
c=$(echo "$L3_OUT_2" | grep -c "sonnet" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "L3-E2E-2: --verifier-model sonnet → startup log shows sonnet"
else
  fail "L3-E2E-2: --verifier-model sonnet → startup log shows sonnet (output: '$(echo "$L3_OUT_2" | head -5)')"
fi

# L3-E2E-3: invalid --worker-model → exits with code 1 before campaign starts
L3_BAD_EXIT=0
LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --worker-model bad:bad:bad >/dev/null 2>&1 || L3_BAD_EXIT=$?
assert_eq "$L3_BAD_EXIT" "1" "L3-E2E-3: invalid --worker-model → exit 1 before campaign starts"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
