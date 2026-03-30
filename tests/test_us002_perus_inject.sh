#!/usr/bin/env bash
# Test Suite: US-002 — Per-US PRD injection in run
# PRD: AC1 (inject only relevant US), AC2 (missing split → fallback + warning),
#       AC3 (single US PRD → single split file used)
# IL-4: 3 ACs × 3 = 9 minimum tests; this suite has 11 tests

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_one() {
  local val="${1:-0}" label="$2"
  if [[ "$val" -ge 1 ]]; then pass "$label"; else fail "$label (got $val, expected >=1)"; fi
}
assert_zero() {
  local val="${1:-0}" label="$2"
  if [[ "$val" -eq 0 ]]; then pass "$label"; else fail "$label (got $val, expected 0)"; fi
}

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# Global result vars set by _run_inject
INJECT_STDOUT=""
INJECT_STDERR=""

# Helper: extract inject_per_us_prd from run_ralph_desk.zsh and invoke it
# Args: base_prompt_file full_prd_path per_us_prd_path
# Sets: INJECT_STDOUT, INJECT_STDERR
_run_inject() {
  local base_prompt="$1" full_prd="$2" per_us_prd="${3:-}"
  local func_body
  func_body=$(sed -n '/^inject_per_us_prd() {$/,/^}$/p' "$RUN" 2>/dev/null)
  if [[ -z "$func_body" ]]; then
    INJECT_STDOUT=""
    INJECT_STDERR="ERROR: inject_per_us_prd not found in $RUN"
    return 1
  fi
  local tmp_script tmpout tmperr
  tmp_script=$(mktemp /tmp/us002_XXXXXX.zsh)
  tmpout=$(mktemp); tmperr=$(mktemp)
  printf '%s\n' "$func_body" > "$tmp_script"
  printf "inject_per_us_prd '%s' '%s' '%s'\n" \
    "$base_prompt" "$full_prd" "$per_us_prd" >> "$tmp_script"
  zsh "$tmp_script" > "$tmpout" 2> "$tmperr"
  INJECT_STDOUT=$(cat "$tmpout")
  INJECT_STDERR=$(cat "$tmperr")
  rm -f "$tmp_script" "$tmpout" "$tmperr"
}

# Helper: fail with label if inject_per_us_prd was not found (prevents false-positive absence checks)
_ran_or_fail() {
  local label="$1"
  if [[ "$INJECT_STDERR" == *"inject_per_us_prd not found"* ]]; then
    fail "$label (inject_per_us_prd not found in run_ralph_desk.zsh)"
    return 1
  fi
  return 0
}

echo "=== US-002: Per-US PRD injection in run ==="
echo ""

# ===========================================================
# AC1: Worker prompt injects only relevant US
# Given: base prompt references full PRD, per-US split file exists for US-002
# When: inject_per_us_prd called with US-002 split path
# Then: only per-US-002 path in prompt, full PRD path replaced, US-001 path absent
# ===========================================================
echo "--- AC1: Prompt injects only relevant US ---"

TMP1="$(mktemp -d)"; TMPDIRS+=("$TMP1")
FULL_PRD1="$TMP1/prd-actest.md"
SPLIT_US002_1="$TMP1/prd-actest-US-002.md"
BASE1="$TMP1/base.md"

printf '### US-001: Alpha\nAlpha PRD content.\n### US-002: Beta\nBeta PRD content.\n' > "$FULL_PRD1"
printf '### US-002: Beta\nBeta PRD content.\n' > "$SPLIT_US002_1"
printf 'Read PRD: %s\nDo the work.\n' "$FULL_PRD1" > "$BASE1"

_run_inject "$BASE1" "$FULL_PRD1" "$SPLIT_US002_1"

# AC1-L1-1: per-US split path (US-002) appears in assembled prompt
c=$(echo "$INJECT_STDOUT" | grep -c "prd-actest-US-002.md" 2>/dev/null) || c=0
assert_one "$c" "AC1-L1-1: per-US split path (prd-actest-US-002.md) present in assembled prompt"

# AC1-L1-2: full PRD path no longer present in prompt (replaced by per-US path)
if _ran_or_fail "AC1-L1-2: full PRD path absent from prompt"; then
  c=$(echo "$INJECT_STDOUT" | grep -Fc "$FULL_PRD1" 2>/dev/null) || c=0
  assert_zero "$c" "AC1-L1-2: full PRD path absent from prompt after per-US injection"
fi

# AC1-L1-3: US-001 split path does NOT appear (US-002 was targeted, not US-001)
if _ran_or_fail "AC1-L1-3: US-001 path absent when targeting US-002"; then
  c=$(echo "$INJECT_STDOUT" | grep -c "prd-actest-US-001.md" 2>/dev/null) || c=0
  assert_zero "$c" "AC1-L1-3: US-001 split path absent when assembling prompt for US-002"
fi

# ===========================================================
# AC2: Missing split file → full PRD fallback + warning
# Given: per-US split file does NOT exist on disk
# When: inject_per_us_prd called with non-existent split path
# Then: full PRD path preserved in prompt + WARNING emitted to stderr
# ===========================================================
echo ""
echo "--- AC2: Missing split file → full PRD + warning ---"

TMP2="$(mktemp -d)"; TMPDIRS+=("$TMP2")
FULL_PRD2="$TMP2/prd-slug2.md"
MISSING_SPLIT="$TMP2/prd-slug2-US-007.md"   # intentionally absent
BASE2="$TMP2/base.md"

printf '### US-001: Story\nFull PRD content.\n' > "$FULL_PRD2"
printf 'PRD: %s\n' "$FULL_PRD2" > "$BASE2"

_run_inject "$BASE2" "$FULL_PRD2" "$MISSING_SPLIT"

# AC2-L1-1: full PRD path preserved (fallback in effect, not replaced)
c=$(echo "$INJECT_STDOUT" | grep -Fc "$FULL_PRD2" 2>/dev/null) || c=0
assert_one "$c" "AC2-L1-1: full PRD path preserved in prompt when split file missing (fallback)"

# AC2-L1-2: WARNING message emitted to stderr when split file missing
c=$(echo "$INJECT_STDERR" | grep -c "WARNING" 2>/dev/null) || c=0
assert_one "$c" "AC2-L1-2: WARNING emitted to stderr when split file missing (per_us_prd known)"

# AC2-L1-3: NO warning when per_us_prd is empty (no US targeted, expected path)
BASE2B="$TMP2/base2b.md"
printf 'PRD: %s\n' "$FULL_PRD2" > "$BASE2B"
_run_inject "$BASE2B" "$FULL_PRD2" ""
if _ran_or_fail "AC2-L1-3: no WARNING when per_us_prd empty"; then
  c=$(echo "$INJECT_STDERR" | grep -c "WARNING" 2>/dev/null) || c=0
  assert_zero "$c" "AC2-L1-3: no WARNING emitted when per_us_prd is empty (no US targeted)"
fi

# ===========================================================
# AC3: Single US PRD → single split file used correctly
# Given: PRD with exactly 1 US, split file exists
# When: inject_per_us_prd called with that single split path
# Then: single US split path in prompt, full PRD path replaced, no warning
# ===========================================================
echo ""
echo "--- AC3: Single US PRD → single split file used ---"

TMP3="$(mktemp -d)"; TMPDIRS+=("$TMP3")
FULL_PRD3="$TMP3/prd-single.md"
SPLIT_ONLY="$TMP3/prd-single-US-001.md"
BASE3="$TMP3/base.md"

printf '### US-001: Only Story\nSingle US content.\n' > "$FULL_PRD3"
printf '### US-001: Only Story\nSingle US content.\n' > "$SPLIT_ONLY"
printf 'PRD: %s\n' "$FULL_PRD3" > "$BASE3"

_run_inject "$BASE3" "$FULL_PRD3" "$SPLIT_ONLY"

# AC3-L1-1: single US split path present in prompt
c=$(echo "$INJECT_STDOUT" | grep -c "prd-single-US-001.md" 2>/dev/null) || c=0
assert_one "$c" "AC3-L1-1: single US split path (prd-single-US-001.md) present in assembled prompt"

# AC3-L1-2: full PRD path replaced (not present)
if _ran_or_fail "AC3-L1-2: full PRD path replaced for single US"; then
  c=$(echo "$INJECT_STDOUT" | grep -Fc "$FULL_PRD3" 2>/dev/null) || c=0
  assert_zero "$c" "AC3-L1-2: full PRD path absent after single-US split injection"
fi

# AC3-L1-3: no warning (split file exists)
if _ran_or_fail "AC3-L1-3: no warning when single US split exists"; then
  c=$(echo "$INJECT_STDERR" | grep -c "WARNING" 2>/dev/null) || c=0
  assert_zero "$c" "AC3-L1-3: no WARNING emitted when single US split file exists"
fi

# ===========================================================
# L3 E2E: Full init creates split files → inject produces per-US path
# ===========================================================
echo ""
echo "--- L3 E2E: Full init + inject ---"

TMP_E2E="$(mktemp -d)"; TMPDIRS+=("$TMP_E2E")
ROOT="$TMP_E2E" zsh "$INIT" e2eslug "test" >/dev/null 2>&1 || true
PLANS_E2E="$TMP_E2E/.claude/ralph-desk/plans"
cat > "$PLANS_E2E/prd-e2eslug.md" << 'E2E_PRD'
# PRD: e2eslug
### US-001: First Story
Content for US-001.
### US-002: Second Story
Content for US-002.
E2E_PRD
rm -f "$PLANS_E2E/test-spec-e2eslug.md"
ROOT="$TMP_E2E" zsh "$INIT" e2eslug "test" --mode improve >/dev/null 2>&1 || true

SPLIT_E2E="$PLANS_E2E/prd-e2eslug-US-002.md"
FULL_PRD_E2E="$PLANS_E2E/prd-e2eslug.md"
BASE_E2E="$TMP_E2E/base-e2e.md"
printf 'PRD: %s\nWork on US-002.\n' "$FULL_PRD_E2E" > "$BASE_E2E"

if [[ -f "$SPLIT_E2E" ]]; then
  _run_inject "$BASE_E2E" "$FULL_PRD_E2E" "$SPLIT_E2E"
  c=$(echo "$INJECT_STDOUT" | grep -c "prd-e2eslug-US-002.md" 2>/dev/null) || c=0
  assert_one "$c" "L3-E2E-1: after full init, inject produces per-US path in assembled prompt"
  if _ran_or_fail "L3-E2E-2: full PRD path replaced in E2E"; then
    c=$(echo "$INJECT_STDOUT" | grep -Fc "$FULL_PRD_E2E" 2>/dev/null) || c=0
    assert_zero "$c" "L3-E2E-2: full PRD path replaced in E2E assembled prompt"
  fi
else
  fail "L3-E2E-1: init did not create per-US split file for US-002 (expected: $SPLIT_E2E)"
  fail "L3-E2E-2: (prerequisite failed — no split file)"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
