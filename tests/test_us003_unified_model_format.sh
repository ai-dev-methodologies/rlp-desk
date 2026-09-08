#!/usr/bin/env bash
# Test Suite: US-003 — Unified --worker-model and --verifier-model format
# PRD: AC1 (colon format → codex), AC2 (plain name → claude), AC3 (invalid → error, exit 1)
# IL-4: 3 ACs × 3 = 9 minimum; this suite has 18 tests (AC1:6, AC2:5, AC3:4, L3:3)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

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

# Helper: extract parse_model_flag from run_ralph_desk.zsh or lib_ralph_desk.zsh and invoke it in a zsh subshell
_run_parse() {
  local value="$1" role="${2:-worker}"
  local func_body validate_body
  func_body=$(sed -n '/^parse_model_flag() {$/,/^}$/p' "$RUN" 2>/dev/null)
  if [[ -z "$func_body" ]]; then
    func_body=$(sed -n '/^parse_model_flag() {$/,/^}$/p' "$LIB" 2>/dev/null)
  fi
  if [[ -z "$func_body" ]]; then
    PARSE_STDOUT=""
    PARSE_STDERR="ERROR: parse_model_flag not found in $RUN"
    PARSE_EXIT=1
    return
  fi
  # SV-gate CRITICAL fix (Fable 5.1 / Codex 6 Astra wave): parse_model_flag
  # now calls the shared _validate_model_level (factored out so it and
  # _auto_detect_engine cannot drift) — must be sourced alongside it or every
  # colon-format call fails with "command not found" and returns 1 silently.
  validate_body=$(sed -n '/^_validate_model_level() {$/,/^}$/p' "$LIB" 2>/dev/null)
  local tmp_script tmpout tmperr
  tmp_script=$(mktemp /tmp/us003_XXXXXX.zsh)
  tmpout=$(mktemp); tmperr=$(mktemp)
  printf '%s\n' "$validate_body" > "$tmp_script"
  printf '%s\n' "$func_body" >> "$tmp_script"
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

_run_parse "gpt-5.5:medium" "worker"
if _func_or_fail "AC1-L1-1: gpt-5.5:medium → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-1: gpt-5.5:medium → engine=codex"
fi

_run_parse "gpt-5.5:medium" "worker"
if _func_or_fail "AC1-L1-2: gpt-5.5:medium → model=gpt-5.5"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.5" \
    "AC1-L1-2: gpt-5.5:medium → model=gpt-5.5"
fi

_run_parse "gpt-5.5:medium" "worker"
if _func_or_fail "AC1-L1-3: gpt-5.5:medium → reasoning=medium"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "medium" \
    "AC1-L1-3: gpt-5.5:medium → reasoning=medium"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-4: gpt-5.3-codex-spark:high → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-4: gpt-5.3-codex-spark:high → engine=codex"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-5: gpt-5.3-codex-spark:high → model=gpt-5.3-codex-spark"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.3-codex-spark" \
    "AC1-L1-5: gpt-5.3-codex-spark:high → model=gpt-5.3-codex-spark"
fi

# codex 0.144 / GPT-5.6 family: passthrough of suffixed names + new efforts,
# and sol|terra|luna aliases (same convention as the existing spark alias).
_run_parse "gpt-5.6-sol:max" "worker"
if _func_or_fail "AC1-L1-5a: gpt-5.6-sol:max → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-5a: gpt-5.6-sol:max → engine=codex"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.6-sol" \
    "AC1-L1-5b: gpt-5.6-sol:max → model=gpt-5.6-sol"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "max" \
    "AC1-L1-5c: gpt-5.6-sol:max → reasoning=max"
fi

_run_parse "sol:max" "worker"
if _func_or_fail "AC1-L1-5d: sol:max alias → model=gpt-5.6-sol"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.6-sol" \
    "AC1-L1-5d: sol:max alias → model=gpt-5.6-sol"
fi

_run_parse "terra:ultra" "worker"
if _func_or_fail "AC1-L1-5e: terra:ultra alias → model=gpt-5.6-terra reasoning=ultra"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.6-terra" \
    "AC1-L1-5e: terra:ultra alias → model=gpt-5.6-terra"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "ultra" \
    "AC1-L1-5f: terra:ultra alias → reasoning=ultra"
fi

_run_parse "luna:high" "worker"
if _func_or_fail "AC1-L1-5g: luna:high alias → model=gpt-5.6-luna"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-5.6-luna" \
    "AC1-L1-5g: luna:high alias → model=gpt-5.6-luna"
fi

# astra alias (GPT-6, codex 0.153) — same convention as sol/terra/luna above.
_run_parse "astra:high" "worker"
if _func_or_fail "AC1-L1-5x: astra:high alias → model=gpt-6-astra"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-5x: astra:high alias → engine=codex"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-6-astra" \
    "AC1-L1-5y: astra:high alias → model=gpt-6-astra"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-5z: astra:high alias → reasoning=high"
fi

# Full versioned claude ids WITH effort → claude engine (parity with opus:max).
# Any colon-bearing name that is NOT a claude short alias / claude-* id is codex,
# so claude-opus-4-8:high / claude-fable-5:max must classify as claude.
_run_parse "claude-opus-4-8:high" "verifier"
if _func_or_fail "AC1-L1-5h: claude-opus-4-8:high → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC1-L1-5h: claude-opus-4-8:high → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "claude-opus-4-8" \
    "AC1-L1-5i: claude-opus-4-8:high → model=claude-opus-4-8"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-5j: claude-opus-4-8:high → effort=high"
fi

_run_parse "claude-fable-5:max" "final-verifier"
if _func_or_fail "AC1-L1-5k: claude-fable-5:max → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC1-L1-5k: claude-fable-5:max → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "claude-fable-5" \
    "AC1-L1-5l: claude-fable-5:max → model=claude-fable-5"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "max" \
    "AC1-L1-5m: claude-fable-5:max → effort=max"
fi

# claude-fable-5-1: same claude-* glob path as claude-fable-5, but with a
# SECOND hyphenated numeric segment (5-1, not just 5). Guards that the glob
# is a plain prefix match and not a pattern that only tolerates one trailing
# numeric segment.
_run_parse "claude-fable-5-1:max" "final-verifier"
if _func_or_fail "AC1-L1-5q: claude-fable-5-1:max → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC1-L1-5q: claude-fable-5-1:max → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "claude-fable-5-1" \
    "AC1-L1-5r: claude-fable-5-1:max → model=claude-fable-5-1"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "max" \
    "AC1-L1-5s: claude-fable-5-1:max → effort=max"
fi

# gpt-6-astra: brand-new codex model family, typed verbatim (no short alias
# like sol/terra/luna). Must classify as codex with reasoning preserved, and
# must NOT trip the "not a gpt-* slug" typo warning (it does match gpt-*).
_run_parse "gpt-6-astra:high" "worker"
if _func_or_fail "AC1-L1-5t: gpt-6-astra:high → engine=codex"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "codex" \
    "AC1-L1-5t: gpt-6-astra:high → engine=codex"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "gpt-6-astra" \
    "AC1-L1-5u: gpt-6-astra:high → model=gpt-6-astra"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-5v: gpt-6-astra:high → reasoning=high"
  if [[ "$PARSE_STDERR" != *"is not a claude id or known codex model"* ]]; then
    pass "AC1-L1-5w: gpt-6-astra:high → no spurious typo warning"
  else
    fail "AC1-L1-5w: gpt-6-astra:high incorrectly warned as unrecognized (stderr: $PARSE_STDERR)"
  fi
fi

# Bracket+colon combo: the 1M context suffix [1m] must survive alongside effort,
# and the claude-* glob must still classify it as claude (not codex). Guards the
# zsh case-glob handling of the literal brackets in the input.
_run_parse "claude-opus-4-8[1m]:high" "verifier"
if _func_or_fail "AC1-L1-5n: claude-opus-4-8[1m]:high → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC1-L1-5n: claude-opus-4-8[1m]:high → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "claude-opus-4-8[1m]" \
    "AC1-L1-5o: claude-opus-4-8[1m]:high → model=claude-opus-4-8[1m]"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-5p: claude-opus-4-8[1m]:high → effort=high"
fi

_run_parse "gpt-5.3-codex-spark:high" "worker"
if _func_or_fail "AC1-L1-6: gpt-5.3-codex-spark:high → reasoning=high"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "high" \
    "AC1-L1-6: gpt-5.3-codex-spark:high → reasoning=high"
fi

# AC1-L1-7 (boundary, REVISED — SV-gate CRITICAL fix): colon format with an
# empty reasoning ("gpt-5.5:", trailing colon, nothing after) must now be
# REJECTED. Before the shared _validate_model_level unification,
# parse_model_flag silently accepted this (no validation at all) while
# _auto_detect_engine already rejected it (empty level_part falls through
# its case statement's `*)` arm) — a real pre-existing asymmetry between the
# CLI-flag path and the env-var path. The fix makes both paths call the same
# validator, so both now reject an empty reasoning consistently; this test's
# expectation is updated to match the corrected, unified contract rather
# than pinning the old permissive (and inconsistent-with-env-path) behavior.
_run_parse "gpt-5.5:" "worker"
assert_eq "$PARSE_EXIT" "1" \
  "AC1-L1-7: gpt-5.5: boundary (empty reasoning) → rejected (exit 1), matching _auto_detect_engine's pre-existing stricter behavior"

# AC1-L1-8 (REVISED — team-lead review follow-up): a bare gpt-* id (no
# colon) IS the codex engine. Before this fix, only the bare CLAUDE aliases
# (haiku/sonnet/opus/fable) and the five bare codex ALIASES (spark/sol/
# terra/luna/astra) were classified correctly; an actual bare gpt-* model id
# like "gpt-5.5" fell through to claude — leaving the rule unguessable
# (aliases fixed, real ids still broken) and disagreeing with
# isClaudeEngine('gpt-5.5') on the Node side, which already said "not
# claude". This test used to pin the OLD (wrong) behavior; updated to match
# the corrected, unified contract. Colon is still required to carry an
# explicit reasoning level — it is NOT required to reach the codex engine.
_run_parse "gpt-5.5" "worker"
if _func_or_fail "AC1-L1-8: gpt-5.5 (no colon) → codex (bare gpt-* id, not a claude id or alias)"; then
  engine="$(echo "$PARSE_STDOUT" | awk '{print $1}')"
  model="$(echo "$PARSE_STDOUT" | awk '{print $2}')"
  if [[ "$engine" == "codex" && "$model" == "gpt-5.5" ]]; then
    pass "AC1-L1-8: gpt-5.5 (no colon) → engine=codex, model=gpt-5.5 (bare gpt-* id routes to codex directly)"
  else
    fail "AC1-L1-8: gpt-5.5 (no colon) should be engine=codex model=gpt-5.5, got engine=$engine model=$model"
  fi
fi

# AC1-L1-8b (regression): an unrecognized bare name — neither a claude id,
# a known codex alias, nor a gpt-* id — still defaults to claude. The fix
# narrows the codex exception to known aliases + gpt-* ids, it does not
# flip the documented "model (no colon) = claude engine" default for every
# other name.
_run_parse "some-unknown-model" "worker"
if _func_or_fail "AC1-L1-8b: some-unknown-model (no colon) → still claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC1-L1-8b: some-unknown-model (no colon) → still claude (unrecognized bare name fallback unchanged)"
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

# fable: bare short alias `claude --help` documents alongside opus/sonnet —
# a REAL bug found and fixed in the Fable 5.1 wave: it was previously absent
# from the claude-alias case pattern, so `--worker-model fable` was
# misclassified as codex (only the versioned `claude-fable-5-1` id worked,
# via the claude-* glob).
_run_parse "fable" "worker"
if _func_or_fail "AC2-L1-6: fable → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC2-L1-6: fable → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "fable" \
    "AC2-L1-7: fable → model=fable"
fi

_run_parse "fable:max" "final-verifier"
if _func_or_fail "AC2-L1-8: fable:max → engine=claude"; then
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $1}')" "claude" \
    "AC2-L1-8: fable:max → engine=claude"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $2}')" "fable" \
    "AC2-L1-9: fable:max → model=fable"
  assert_eq "$(echo "$PARSE_STDOUT" | awk '{print $3}')" "max" \
    "AC2-L1-10: fable:max → effort=max"
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
mkdir -p "$TMP_L3/.rlp-desk/plans" \
         "$TMP_L3/.rlp-desk/memos" \
         "$TMP_L3/.rlp-desk/prompts" \
         "$TMP_L3/.rlp-desk/context" \
         "$TMP_L3/.rlp-desk/logs/e2eslug"
touch "$TMP_L3/.rlp-desk/plans/prd-e2eslug.md"

# L3-E2E-1: --worker-model gpt-5.5:medium → startup log shows gpt-5.5
L3_OUT_1=$(LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --worker-model gpt-5.5:medium 2>/dev/null || true)
c=$(echo "$L3_OUT_1" | grep -c "gpt-5.5" 2>/dev/null) || c=0
if [[ "$c" -ge 1 ]]; then
  pass "L3-E2E-1: --worker-model gpt-5.5:medium → startup log shows gpt-5.5"
else
  fail "L3-E2E-1: --worker-model gpt-5.5:medium → startup log shows gpt-5.5 (output: '$(echo "$L3_OUT_1" | head -5)')"
fi

# L3-E2E-2: --verifier-model sonnet → startup log shows sonnet
L3_OUT_2=$(LOOP_NAME=e2eslug ROOT="$TMP_L3" TMUX=test \
  zsh "$RUN" --worker-model gpt-5.5:medium --verifier-model sonnet 2>/dev/null || true)
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
