#!/usr/bin/env bash
# Test suite: US-007 — Brainstorm model recommendation logic
# L1 content review: AC1(3) + AC2(3) + AC3(3) + L3 E2E(1) = 10 tests

CMD_FILE="${CMD_FILE:-src/commands/rlp-desk.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-007: Brainstorm model recommendation logic ==="
echo "Target: $CMD_FILE"
echo ""

if [[ ! -f "$CMD_FILE" ]]; then
  echo "  ERROR: $CMD_FILE not found"
  exit 1
fi

# Extract brainstorm section (flag-based: avoids start pattern matching end pattern)
BRAINSTORM_SECTION="$(awk 'found && /^## `/{exit} /^## `brainstorm/{found=1} found' "$CMD_FILE" | head -400)"

if [[ -z "$BRAINSTORM_SECTION" ]]; then
  echo "  ERROR: brainstorm section not found in $CMD_FILE"
  exit 1
fi

# ── AC1: 5-factor complexity evaluation ─────────────────────────────────────
echo "--- AC1: 5-factor complexity evaluation ---"

# AC1-L1-1: all 5 complexity factors present in brainstorm section
test_ac1_l1_1() {
  local found=0
  echo "$BRAINSTORM_SECTION" | grep -qi 'US count'           && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'File change scope'  && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'Logic complexity'   && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'External dep'       && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'Existing code impact' && (( found++ ))
  if (( found >= 5 )); then
    pass "AC1-L1-1: all 5 complexity factors present in brainstorm ($found/5)"
  else
    fail "AC1-L1-1: only $found/5 complexity factors found in brainstorm (need: US count, File change scope, Logic complexity, External dep, Existing code impact)"
  fi
}

# AC1-L1-2: model mapping table with complexity → model names
test_ac1_l1_2() {
  local found=0
  echo "$BRAINSTORM_SECTION" | grep -qi 'LOW.*haiku\|haiku.*LOW'     && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'MEDIUM.*sonnet\|sonnet.*MEDIUM' && (( found++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'HIGH.*opus\|opus.*HIGH'     && (( found++ ))
  if (( found >= 2 )); then
    pass "AC1-L1-2: model mapping table in brainstorm ($found/3 mappings: LOW→haiku, MEDIUM→sonnet, HIGH→opus)"
  else
    fail "AC1-L1-2: model mapping table missing in brainstorm ($found/3 found)"
  fi
}

# AC1-L1-3: overall = highest factor rule documented
test_ac1_l1_3() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'highest.*factor\|overall.*highest\|= highest'; then
    pass "AC1-L1-3: 'overall = highest factor' rule documented in brainstorm"
  else
    fail "AC1-L1-3: 'overall = highest factor' rule not found in brainstorm"
  fi
}

# AC1-L1-4 (boundary): CRITICAL severity level is documented in complexity table
test_ac1_l1_4() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'CRITICAL'; then
    pass "AC1-L1-4: CRITICAL severity level present in complexity table (boundary: full 4-level scale)"
  else
    fail "AC1-L1-4: CRITICAL severity level missing from complexity table"
  fi
}

# AC1-L1-5 (negative): model mapping rows (LOW/MEDIUM/HIGH) do NOT recommend gpt models
test_ac1_l1_5() {
  if ! echo "$BRAINSTORM_SECTION" | grep -qiE '(LOW|MEDIUM|HIGH).*gpt'; then
    pass "AC1-L1-5: model mapping table uses only claude models for LOW/MEDIUM/HIGH rows (negative: no gpt in table)"
  else
    fail "AC1-L1-5: model mapping table must not map LOW/MEDIUM/HIGH to gpt models"
  fi
}

test_ac1_l1_1
test_ac1_l1_2
test_ac1_l1_3
test_ac1_l1_4
test_ac1_l1_5

# ── AC2: codex detected → cross-engine + cost benefits ──────────────────────
echo ""
echo "--- AC2: codex detected → cross-engine recommendation ---"

# AC2-L1-1: codex cost savings mentioned in brainstorm
test_ac2_l1_1() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'cost saving\|cost-saving\|cheaper\|cost.*token\|token.*cheaper'; then
    pass "AC2-L1-1: codex cost savings mentioned in brainstorm"
  else
    fail "AC2-L1-1: codex cost savings not mentioned in brainstorm"
  fi
}

# AC2-L1-2: cross-engine blind-spot coverage mentioned in brainstorm
test_ac2_l1_2() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'blind.spot\|cross-engine.*benefit\|cross-engine.*coverage'; then
    pass "AC2-L1-2: cross-engine blind-spot coverage mentioned in brainstorm"
  else
    fail "AC2-L1-2: cross-engine blind-spot coverage not found in brainstorm"
  fi
}

# AC2-L1-3: spark token limits mentioned in brainstorm
test_ac2_l1_3() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'spark.*token\|token.*spark\|spark.*limit\|100k\|100,000'; then
    pass "AC2-L1-3: spark token limits mentioned in brainstorm"
  else
    fail "AC2-L1-3: spark token limits not found in brainstorm (need: spark + token limit or 100k)"
  fi
}

test_ac2_l1_1
test_ac2_l1_2
test_ac2_l1_3

# ── AC3: codex not installed → claude-only + install suggestion ─────────────
echo ""
echo "--- AC3: codex not installed → install suggestion ---"

# AC3-L1-1: codex install suggestion in brainstorm section
test_ac3_l1_1() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'npm install.*codex\|install.*@openai/codex'; then
    pass "AC3-L1-1: codex install suggestion (npm install) in brainstorm"
  else
    fail "AC3-L1-1: codex install suggestion missing from brainstorm"
  fi
}

# AC3-L1-2: claude-only default when codex is absent
test_ac3_l1_2() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'claude-only\|claude only\|default.*claude\|Defaulting to claude'; then
    pass "AC3-L1-2: claude-only default documented in brainstorm"
  else
    fail "AC3-L1-2: claude-only default not documented in brainstorm"
  fi
}

# AC3-L1-3: blind spot explanation specifically for the no-codex case
test_ac3_l1_3() {
  if echo "$BRAINSTORM_SECTION" | grep -qi 'blind spot\|blind-spot\|single.*engine.*risk\|same failure mode\|single perspective'; then
    pass "AC3-L1-3: blind spot explanation for no-codex case in brainstorm"
  else
    fail "AC3-L1-3: blind spot explanation for no-codex missing in brainstorm"
  fi
}

test_ac3_l1_1
test_ac3_l1_2
test_ac3_l1_3

# ── L3 E2E: brainstorm section has complete recommendation flow ──────────────
echo ""
echo "--- L3 E2E: brainstorm section completeness ---"

# L3-E2E-1: brainstorm section has complexity evaluation + model recommendation + codex path
test_l3_e2e_1() {
  local score=0
  echo "$BRAINSTORM_SECTION" | grep -qi 'US count\|complexity factor\|5.*factor\|five.*factor' && (( score++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'recommend.*model\|model.*recommend\|suggest.*worker\|Worker.*suggest' && (( score++ ))
  echo "$BRAINSTORM_SECTION" | grep -qi 'codex.*detect\|command -v codex\|codex.*install\|codex.*installed' && (( score++ ))
  if (( score >= 3 )); then
    pass "L3-E2E-1: brainstorm section has complete recommendation flow ($score/3: complexity + model + codex)"
  else
    fail "L3-E2E-1: brainstorm recommendation flow incomplete ($score/3 checks passed)"
  fi
}

test_l3_e2e_1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

(( FAIL > 0 )) && exit 1
exit 0
