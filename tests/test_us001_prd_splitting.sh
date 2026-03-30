#!/usr/bin/env bash
# Test Suite: US-001 — PRD/test-spec splitting in init
# PRD: AC1 (PRD split into per-US files), AC2 (test-spec split per US),
#       AC3 (no US markers → warning + no crash + no stale files)
# IL-4: 3 ACs × 3 = 9 minimum tests; this suite has 20 tests

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() {
  local val="$1" expected="$2" label="$3"
  if [[ "$val" -eq "$expected" ]]; then pass "$label"; else fail "$label (got $val, expected $expected)"; fi
}
assert_ge() {
  local val="$1" min="$2" label="$3"
  if [[ "$val" -ge "$min" ]]; then pass "$label"; else fail "$label (got $val, expected >=$min)"; fi
}
assert_one() { assert_ge "$1" 1 "$2"; }
assert_zero() {
  local val="$1" label="$2"
  if [[ "$val" -eq 0 ]]; then pass "$label"; else fail "$label (got $val, expected 0)"; fi
}

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

echo "=== US-001: PRD/test-spec splitting in init ==="
echo ""

# ===========================================================
# AC1: PRD split into per-US files
# Given: PRD with 3+ user stories each marked with ### US-NNN: headers
# When: init is run
# Then: each US section is extracted to plans/prd-<slug>-US-NNN.md
# ===========================================================
echo "--- AC1: PRD split into per-US files ---"

# AC1-L1-1: 2-US PRD creates exactly 2 split files (happy path)
TMP_AC1="$(mktemp -d)"; TMPDIRS+=("$TMP_AC1")
ROOT="$TMP_AC1" zsh "$INIT" ac1test "test" >/dev/null 2>&1 || true
cat > "$TMP_AC1/.claude/ralph-desk/plans/prd-ac1test.md" << 'AC1_PRD'
# PRD: ac1test
### US-001: Alpha Story
Body of alpha.
### US-002: Beta Story
Body of beta only.
AC1_PRD
rm -f "$TMP_AC1/.claude/ralph-desk/plans/test-spec-ac1test.md"
ROOT="$TMP_AC1" zsh "$INIT" ac1test "test" --mode improve >/dev/null 2>&1 || true

ac1_count=$(ls "$TMP_AC1/.claude/ralph-desk/plans/prd-ac1test-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$ac1_count" 2 "AC1-L1-1: 2-US PRD creates exactly 2 split files"

# AC1-L1-2: US-001 split file contains its own section body text
ac1_us1="$TMP_AC1/.claude/ralph-desk/plans/prd-ac1test-US-001.md"
if [[ -f "$ac1_us1" ]]; then
  c=$(grep -c "Body of alpha" "$ac1_us1" 2>/dev/null) || c=0
  assert_one "$c" "AC1-L1-2: US-001 split file contains US-001 section body"
else
  fail "AC1-L1-2: US-001 split file not created"
fi

# AC1-L1-3: US-002 split file contains US-002 body and NOT US-001 body (content isolation)
ac1_us2="$TMP_AC1/.claude/ralph-desk/plans/prd-ac1test-US-002.md"
if [[ -f "$ac1_us2" ]]; then
  c=$(grep -c "Body of beta only" "$ac1_us2" 2>/dev/null) || c=0
  assert_one "$c" "AC1-L1-3: US-002 split file contains US-002 section body"
  c=$(grep -c "Body of alpha" "$ac1_us2" 2>/dev/null) || c=0
  assert_zero "$c" "AC1-L1-3-iso: US-002 split file does NOT contain US-001 body (isolation)"
else
  fail "AC1-L1-3: US-002 split file not created"
  fail "AC1-L1-3-iso: US-002 split file not created"
fi

# AC1-L2-4: 3-US PRD creates exactly 3 split files (boundary: minimum for "3+" PRD requirement)
TMP3="$(mktemp -d)"; TMPDIRS+=("$TMP3")
ROOT="$TMP3" zsh "$INIT" threeustest "test" >/dev/null 2>&1 || true
cat > "$TMP3/.claude/ralph-desk/plans/prd-threeustest.md" << 'PRD3_END'
# PRD: threeustest
### US-001: First Story
Content for US-001.
### US-002: Second Story
Content for US-002 only.
### US-003: Third Story
Content for US-003.
PRD3_END
rm -f "$TMP3/.claude/ralph-desk/plans/test-spec-threeustest.md"
ROOT="$TMP3" zsh "$INIT" threeustest "test" --mode improve >/dev/null 2>&1 || true
split3=$(ls "$TMP3/.claude/ralph-desk/plans/prd-threeustest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$split3" 3 "AC1-L2-4: 3-US PRD creates exactly 3 split files"

# AC1-L2-5: content isolation in 3-US case (US-001 contains own body, not other US bodies)
if [[ -f "$TMP3/.claude/ralph-desk/plans/prd-threeustest-US-001.md" ]]; then
  c=$(grep -c "Content for US-001" "$TMP3/.claude/ralph-desk/plans/prd-threeustest-US-001.md" 2>/dev/null) || c=0
  assert_one "$c" "AC1-L2-5: US-001 split file contains US-001 content (3-US case)"
  c=$(grep -c "Content for US-002\|Content for US-003" \
    "$TMP3/.claude/ralph-desk/plans/prd-threeustest-US-001.md" 2>/dev/null) || c=0
  assert_zero "$c" "AC1-L2-5-iso: US-001 split file has no other-US body text (3-US case)"
else
  fail "AC1-L2-5: US-001 split file not found in 3-US test"
  fail "AC1-L2-5-iso: US-001 split file not found in 3-US test"
fi

# AC1-L2-6: single-US PRD creates 1 split file and preserves original full PRD
TMP_SINGLE="$(mktemp -d)"; TMPDIRS+=("$TMP_SINGLE")
ROOT="$TMP_SINGLE" zsh "$INIT" single1us "test" >/dev/null 2>&1 || true
cat > "$TMP_SINGLE/.claude/ralph-desk/plans/prd-single1us.md" << 'PRD1_END'
# PRD: single1us
### US-001: Only Story
Content for single US-001 here.
PRD1_END
rm -f "$TMP_SINGLE/.claude/ralph-desk/plans/test-spec-single1us.md"
ROOT="$TMP_SINGLE" zsh "$INIT" single1us "test" --mode improve >/dev/null 2>&1 || true
split1=$(ls "$TMP_SINGLE/.claude/ralph-desk/plans/prd-single1us-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$split1" 1 "AC1-L2-6: single-US PRD creates exactly 1 split file"
if [[ -f "$TMP_SINGLE/.claude/ralph-desk/plans/prd-single1us.md" ]]; then
  pass "AC1-L2-6-full: original full PRD preserved after split"
else
  fail "AC1-L2-6-full: original full PRD NOT preserved after split"
fi

# AC1-L3-neg: ## US-NNN: (double-hash) must NOT trigger PRD splitting (wrong marker format)
TMP_NEG="$(mktemp -d)"; TMPDIRS+=("$TMP_NEG")
ROOT="$TMP_NEG" zsh "$INIT" negmarktest "test" >/dev/null 2>&1 || true
cat > "$TMP_NEG/.claude/ralph-desk/plans/prd-negmarktest.md" << 'PRD_NEG'
# PRD: negmarktest
## US-001: First Story
Content for story one.
## US-002: Second Story
Content for story two.
PRD_NEG
rm -f "$TMP_NEG/.claude/ralph-desk/plans/test-spec-negmarktest.md"
ROOT="$TMP_NEG" zsh "$INIT" negmarktest "test" --mode improve >/dev/null 2>&1 || true
neg_split=$(ls "$TMP_NEG/.claude/ralph-desk/plans/prd-negmarktest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_zero "$neg_split" "AC1-L3-neg: ## US-NNN: (double-hash) does NOT trigger PRD splitting"

# ===========================================================
# AC2: test-spec split per US
# Given: test-spec with ## US-NNN: section markers
# When: init is run
# Then: each US section extracted to plans/test-spec-<slug>-US-NNN.md
# ===========================================================
echo ""
echo "--- AC2: test-spec split per US ---"

# AC2-L1-1: test-spec with 2 US markers creates 2 split files
TMP_TS="$(mktemp -d)"; TMPDIRS+=("$TMP_TS")
ROOT="$TMP_TS" zsh "$INIT" tstest "test" >/dev/null 2>&1 || true
cat > "$TMP_TS/.claude/ralph-desk/plans/test-spec-tstest.md" << 'TS_END'
# Test Spec: tstest
## Verification Commands
### Build
zsh -n src/scripts/init_ralph_desk.zsh
### Test
bash tests/test_us001_prd_splitting.sh

---

## US-001: First Story
### L1
Some tests for US-001.
## US-002: Second Story
### L1
Some tests for US-002.
TS_END
ROOT="$TMP_TS" zsh "$INIT" tstest "test" >/dev/null 2>&1 || true
ts_count=$(ls "$TMP_TS/.claude/ralph-desk/plans/test-spec-tstest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_ge "$ts_count" 2 "AC2-L1-1: test-spec with 2 US markers creates 2 split files"

# AC2-L1-2: each split test-spec file includes the global ## Verification Commands block
for ts_split in "$TMP_TS/.claude/ralph-desk/plans/test-spec-tstest-US-"*.md; do
  [[ -f "$ts_split" ]] || continue
  vc_count=$(grep -c "^## Verification Commands" "$ts_split" 2>/dev/null) || vc_count=0
  if [[ "$vc_count" -ge 1 ]]; then
    pass "AC2-L1-2: $(basename "$ts_split") includes ## Verification Commands block"
  else
    fail "AC2-L1-2: $(basename "$ts_split") missing ## Verification Commands block"
  fi
done

# AC2-L1-3: split test-spec file contains its US-specific section content
if [[ -f "$TMP_TS/.claude/ralph-desk/plans/test-spec-tstest-US-001.md" ]]; then
  c=$(grep -c "Some tests for US-001" \
    "$TMP_TS/.claude/ralph-desk/plans/test-spec-tstest-US-001.md" 2>/dev/null) || c=0
  assert_one "$c" "AC2-L1-3: test-spec-US-001 split file contains US-001 section content"
else
  fail "AC2-L1-3: test-spec-US-001 split file not created"
fi

# AC2-L2-4: stale test-spec per-US files removed when markers disappear (boundary)
TMP_TS_STALE="$(mktemp -d)"; TMPDIRS+=("$TMP_TS_STALE")
ROOT="$TMP_TS_STALE" zsh "$INIT" tsstaletest "test" >/dev/null 2>&1 || true
cat > "$TMP_TS_STALE/.claude/ralph-desk/plans/test-spec-tsstaletest.md" << 'TS_STALE1'
# Test Spec: tsstaletest
## Verification Commands
### Build
zsh -n src/scripts/init_ralph_desk.zsh

---

## US-001: First Story
### L1
Tests for US-001.
## US-002: Second Story
### L1
Tests for US-002.
TS_STALE1
rm -f "$TMP_TS_STALE/.claude/ralph-desk/plans/prd-tsstaletest.md"
ROOT="$TMP_TS_STALE" zsh "$INIT" tsstaletest "test" --mode improve >/dev/null 2>&1 || true
ts_initial=$(ls "$TMP_TS_STALE/.claude/ralph-desk/plans/test-spec-tsstaletest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
printf '# Test Spec: tsstaletest\n## Verification Commands\n### Build\nzsh -n src/scripts/init_ralph_desk.zsh\n' \
  > "$TMP_TS_STALE/.claude/ralph-desk/plans/test-spec-tsstaletest.md"
ROOT="$TMP_TS_STALE" zsh "$INIT" tsstaletest "test" --mode improve >/dev/null 2>&1 || true
ts_stale=$(ls "$TMP_TS_STALE/.claude/ralph-desk/plans/test-spec-tsstaletest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ts_initial" -ge 2 ]]; then
  assert_zero "$ts_stale" "AC2-L2-4: stale test-spec per-US files removed on markerless re-run"
else
  fail "AC2-L2-4: test setup failed — only $ts_initial test-spec split files created initially (expected >= 2)"
fi

# ===========================================================
# AC3: no US markers fallback
# Given: PRD with no ### US-NNN: section markers
# When: init is run
# Then: warning emitted, exit 0 (no crash), no stale split files remain
# ===========================================================
echo ""
echo "--- AC3: no US markers → warning + no crash + no stale files ---"

# AC3-L1-1: WARNING message for no-marker fallback is present in init script (static check)
warn_count=$(grep -c 'WARNING.*marker\|no.*US.*marker\|No.*marker\|falling back to full PRD' \
  "$INIT" 2>/dev/null) || warn_count=0
assert_one "$warn_count" "AC3-L1-1: init script contains WARNING message for no-marker fallback"

# AC3-L1-2: init uses return 0 (graceful fallback, not hard exit 1) in the no-marker path
ret0_count=$(grep -c 'return 0' "$INIT" 2>/dev/null) || ret0_count=0
assert_ge "$ret0_count" 1 "AC3-L1-2: init script uses return 0 for graceful no-marker fallback"

# AC3-L3-3: functional: init exits 0 with markerless PRD (must NOT crash)
TMP_NOMARK="$(mktemp -d)"; TMPDIRS+=("$TMP_NOMARK")
ROOT="$TMP_NOMARK" zsh "$INIT" noustest "test" >/dev/null 2>&1 || true
printf '%s\n' "no markers here just text" > "$TMP_NOMARK/.claude/ralph-desk/plans/prd-noustest.md"
rm -f "$TMP_NOMARK/.claude/ralph-desk/plans/test-spec-noustest.md"
ROOT="$TMP_NOMARK" zsh "$INIT" noustest "test" --mode improve >/dev/null 2>&1
init_exit=$?
if [[ $init_exit -eq 0 ]]; then
  pass "AC3-L3-3: init exits 0 with no-marker PRD (no crash)"
else
  fail "AC3-L3-3: init exits 0 with no-marker PRD (got exit $init_exit)"
fi

# AC3-L3-4: stale per-US PRD split files cleaned on markerless re-run (must NOT linger)
TMP_STALE="$(mktemp -d)"; TMPDIRS+=("$TMP_STALE")
ROOT="$TMP_STALE" zsh "$INIT" staletest "test" >/dev/null 2>&1 || true
cat > "$TMP_STALE/.claude/ralph-desk/plans/prd-staletest.md" << 'STALE_PRD'
# PRD
### US-001: First
Content.
### US-002: Second
Content.
STALE_PRD
rm -f "$TMP_STALE/.claude/ralph-desk/plans/test-spec-staletest.md"
ROOT="$TMP_STALE" zsh "$INIT" staletest "test" --mode improve >/dev/null 2>&1 || true
stale_initial=$(ls "$TMP_STALE/.claude/ralph-desk/plans/prd-staletest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
printf 'no markers here\n' > "$TMP_STALE/.claude/ralph-desk/plans/prd-staletest.md"
rm -f "$TMP_STALE/.claude/ralph-desk/plans/test-spec-staletest.md"
ROOT="$TMP_STALE" zsh "$INIT" staletest "test" --mode improve >/dev/null 2>&1 || true
stale_after=$(ls "$TMP_STALE/.claude/ralph-desk/plans/prd-staletest-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$stale_initial" -ge 2 ]]; then
  assert_zero "$stale_after" "AC3-L3-4: markerless re-run removes $stale_initial stale per-US split files"
else
  fail "AC3-L3-4: test setup failed — only $stale_initial files from first run (expected >= 2)"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
