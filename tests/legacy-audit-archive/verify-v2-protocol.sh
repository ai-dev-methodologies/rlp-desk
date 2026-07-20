#!/bin/bash
set -euo pipefail

# =============================================================================
# RLP Desk v2-protocol comprehensive verification script
# Automated verification of 48 Acceptance Criteria across 8 User Stories
# =============================================================================

ROOT="/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol"
GOV="$ROOT/src/governance.md"
PROTO="$ROOT/docs/protocol-reference.md"
CMD="$ROOT/src/commands/rlp-desk.md"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
warn() { WARN=$((WARN+1)); echo "  ⚠️  $1"; }

check_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (pattern: '$pattern' not found in $(basename $file))"
  fi
}

check_no_grep() {
  local file="$1" pattern="$2" label="$3"
  if grep -qi "$pattern" "$file" 2>/dev/null; then
    fail "$label (pattern: '$pattern' FOUND in $(basename $file))"
  else
    pass "$label"
  fi
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  RLP Desk v2-protocol Comprehensive Verification            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
echo "━━━ US-001: Enhanced Memory Format ━━━"
# =============================================================================
check_grep "$PROTO" "Completed Stories" "AC1: Completed Stories in protocol-reference.md"
check_grep "$PROTO" "Criteria" "AC2: Criteria in Next Iteration Contract"
check_grep "$PROTO" "Key Decisions" "AC3: Key Decisions section"
check_grep "$PROTO" "Patterns Discovered" "AC4a: Patterns Discovered preserved"
check_grep "$PROTO" "Learnings" "AC4b: Learnings preserved"
check_grep "$PROTO" "Evidence Chain" "AC4c: Evidence Chain preserved"
check_grep "$PROTO" "No YAML\|no YAML\|Markdown.*not.*YAML\|plain Markdown" "AC5: No YAML declaration"
check_grep "$GOV" "Completed Stories\|completed stories" "AC6: governance.md mentions Completed Stories"
echo ""

# =============================================================================
echo "━━━ US-002: Leader Loop Prep-stage Cleanup & Post-execution Log ━━━"
# =============================================================================
check_grep "$GOV" "Prep-stage\|prep-stage\|done-claim.*if exists\|Delete.*done-claim" "AC1: Prep cleanup in governance.md"
check_grep "$PROTO" "Prep-stage\|prep-stage\|cleanup.*before" "AC2: Prep cleanup in protocol-reference.md"
check_grep "$CMD" "Prep-stage\|prep-stage\|rm -f.*done-claim\|Clean previous" "AC3: Prep cleanup in rlp-desk.md"
check_grep "$PROTO" "result.md\|Result Log" "AC4: iter-NNN.result.md format defined"
check_grep "$PROTO" "leader-measured\|git-measured" "AC5: Authorship labels"

# Loop step consistency check
echo "  --- Loop step consistency ---"
GOV_STEPS=$(grep -c '①\|②\|③\|④\|⑤\|⑥\|⑦\|⑧' "$GOV" 2>/dev/null || echo 0)
PROTO_STEPS=$(grep -c '①\|②\|③\|④\|⑤\|⑥\|⑦\|⑧' "$PROTO" 2>/dev/null || echo 0)
CMD_STEPS=$(grep -c '①\|②\|③\|④\|⑤\|⑥\|⑦\|⑧' "$CMD" 2>/dev/null || echo 0)
if [ "$GOV_STEPS" -gt 0 ] && [ "$PROTO_STEPS" -gt 0 ] && [ "$CMD_STEPS" -gt 0 ]; then
  pass "AC6: All 3 docs have circled number steps (gov=$GOV_STEPS, proto=$PROTO_STEPS, cmd=$CMD_STEPS)"
else
  fail "AC6: Missing steps in some docs (gov=$GOV_STEPS, proto=$PROTO_STEPS, cmd=$CMD_STEPS)"
fi
echo ""

# =============================================================================
echo "━━━ US-003: Circuit Breaker Enhancement ━━━"
# =============================================================================
check_grep "$GOV" "consecutive.*fail\|3 consecutive" "AC1: Consecutive failure CB in governance.md"
check_grep "$PROTO" "consecutive.*fail\|3 consecutive" "AC2: Consecutive failure CB in protocol-reference.md"
check_grep "$CMD" "consecutive.*fail\|3 consecutive" "AC3: Consecutive failure CB in rlp-desk.md"
check_grep "$PROTO" "consecutive_failures" "AC4: consecutive_failures in status.json spec"
check_grep "$PROTO" "acceptance criterion\|acceptance criteria.*consecutive\|same.*criterion" "AC5: Criterion-based 'same error' definition"

# CB consistency: count CB entries in each doc
GOV_CB=$(grep -ci "BLOCKED\|blocked" "$GOV" 2>/dev/null || echo 0)
PROTO_CB=$(grep -ci "BLOCKED\|blocked" "$PROTO" 2>/dev/null || echo 0)
CMD_CB=$(grep -ci "BLOCKED\|blocked" "$CMD" 2>/dev/null || echo 0)
if [ "$GOV_CB" -gt 2 ] && [ "$PROTO_CB" -gt 2 ] && [ "$CMD_CB" -gt 2 ]; then
  pass "AC6: CB conditions consistent (BLOCKED refs: gov=$GOV_CB, proto=$PROTO_CB, cmd=$CMD_CB)"
else
  warn "AC6: CB ref counts low (gov=$GOV_CB, proto=$PROTO_CB, cmd=$CMD_CB)"
fi
echo ""

# =============================================================================
echo "━━━ US-004: Verifier Independence Reform ━━━"
# =============================================================================
check_grep "$PROTO" "git diff" "AC1: git diff scope in protocol-reference.md"
check_grep "$PROTO" "orientation" "AC2: Memory 'orientation only'"
check_grep "$PROTO" "request_info" "AC3: 3-state verdict (request_info)"
check_grep "$PROTO" "request_info.*cannot\|cannot.*determine\|specific question\|Leader decides" "AC4: request_info meaning defined"
check_grep "$PROTO" "severity.*critical\|critical.*major.*minor" "AC5: severity field in issues"
check_no_grep "$PROTO" "uncertain.*=.*fail\|If uncertain.*fail" "AC6: No 'uncertain=fail' rule"
check_grep "$PROTO" "Delegate.*deterministic\|deterministic.*tool\|delegate.*check\|tool.*defined.*test-spec" "AC7: Deterministic checks delegated"
check_grep "$PROTO" "AC verification\|semantic review\|smoke test" "AC8: Verifier focus areas"
check_grep "$GOV" "git diff\|orientation\|request_info" "AC9: governance.md Verifier updated"
check_grep "$CMD" "request_info" "AC10: rlp-desk.md has request_info branch"
echo ""

# =============================================================================
echo "━━━ US-005: Fix Loop Protocol ━━━"
# =============================================================================
check_grep "$GOV" "Fix Loop" "AC1: Fix Loop Protocol section in governance.md"
check_grep "$GOV" "severity\|critical.*major" "AC2: Severity sorting in Fix Loop"
check_grep "$PROTO" "traceability\|Traceability" "AC3: Traceability rule in protocol-reference.md"
check_grep "$PROTO" "non-authoritative\|suggestion.*non" "AC4: fix_hint marked non-authoritative"
check_grep "$GOV" "consecutive_failures.*Leader\|Leader.*consecutive\|status.json.*counter\|Leader.*owns" "AC5: Leader manages counter"
check_grep "$PROTO" "Fix Loop\|Fix Contract" "AC6: Fix Loop detailed spec in protocol-reference.md"
check_grep "$CMD" "Fix Loop\|fix loop\|fail.*Fix" "AC7: rlp-desk.md fail branch references Fix Loop"
echo ""

# =============================================================================
echo "━━━ US-006: Worker Prompt Template Enhancement ━━━"
# =============================================================================
check_grep "$INIT" "Before you start\|Before You Start" "AC1: 'Before you start' in init script"
check_grep "$INIT" "Campaign Memory\|memory" "AC2a: Memory in read order"
check_grep "$INIT" "PRD\|prd" "AC2b: PRD in read order"
check_grep "$INIT" "Test Spec\|test-spec\|test spec" "AC2c: Test Spec in read order"
check_grep "$INIT" "Latest Context\|context" "AC2d: Latest Context in read order"
check_grep "$INIT" "Scope rules\|scope rule\|SCOPE LOCK\|outside.*root" "AC3: Scope rules"
check_grep "$INIT" "commit\|Commit" "AC4: Commit rule"
echo ""

# =============================================================================
echo "━━━ US-007: Verifier Prompt Template Enhancement ━━━"
# =============================================================================
check_no_grep "$INIT" "uncertain.*=.*fail\|If uncertain.*verdict.*fail" "AC1: No 'uncertain=fail' in verifier template"
check_grep "$INIT" "request_info" "AC2: request_info in verifier template"
check_grep "$INIT" "git diff" "AC3: git diff scope in verifier template"
check_grep "$INIT" "orientation" "AC4: Memory orientation-only"
check_grep "$INIT" "severity" "AC5: severity field in verdict JSON"
check_grep "$INIT" "smoke\|Smoke" "AC6: Smoke test step"
echo ""

# =============================================================================
echo "━━━ US-008: Scaffold & Template Updates ━━━"
# =============================================================================
check_grep "$INIT" "Depends on\|depends_on" "AC2: Depends on field in PRD template"
check_grep "$INIT" "Size.*S\|Size.*M\|S|M|L" "AC3: Size field in PRD template"
check_grep "$PROTO" "consecutive_failures.*0\|\"consecutive_failures\"" "AC4: status.json initial value"
check_grep "$PROTO" "quality-spec" "AC5: quality-spec mentioned in docs"
echo ""

# =============================================================================
echo "━━━ SMOKE TEST: Init Script ━━━"
# =============================================================================
TMPDIR="/tmp/rlp-v2-test-$$"
mkdir -p "$TMPDIR" && cd "$TMPDIR" && git init -q
if ROOT="$TMPDIR" bash "$INIT" smoke-test "test objective" > /dev/null 2>&1; then
  pass "Init script runs without error"

  WORKER="$TMPDIR/.claude/ralph-desk/prompts/smoke-test.worker.prompt.md"
  VERIFIER="$TMPDIR/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md"
  MEMORY="$TMPDIR/.claude/ralph-desk/memos/smoke-test-memory.md"
  PRD="$TMPDIR/.claude/ralph-desk/plans/prd-smoke-test.md"

  # Worker prompt checks
  if [ -f "$WORKER" ]; then
    check_grep "$WORKER" "Before you start\|Before You Start" "Worker: has 'Before you start'"
    check_grep "$WORKER" "Scope rules\|scope rule\|SCOPE LOCK" "Worker: has scope rules"
    check_grep "$WORKER" "commit\|Commit" "Worker: has commit rule"
  else
    fail "Worker prompt not generated"
  fi

  # Verifier prompt checks
  if [ -f "$VERIFIER" ]; then
    check_grep "$VERIFIER" "request_info" "Verifier: has request_info"
    check_grep "$VERIFIER" "git diff" "Verifier: has git diff scope"
    check_grep "$VERIFIER" "orientation" "Verifier: has orientation-only"
    check_grep "$VERIFIER" "severity" "Verifier: has severity"
    check_grep "$VERIFIER" "smoke\|Smoke" "Verifier: has smoke test step"
    check_no_grep "$VERIFIER" "uncertain.*=.*fail\|If uncertain.*verdict.*fail" "Verifier: no uncertain=fail"
  else
    fail "Verifier prompt not generated"
  fi

  # Memory checks
  if [ -f "$MEMORY" ]; then
    check_grep "$MEMORY" "Completed Stories" "Memory: has Completed Stories"
    check_grep "$MEMORY" "Key Decisions" "Memory: has Key Decisions"
    check_grep "$MEMORY" "Criteria\|criteria" "Memory: has Criteria in contract"
  else
    fail "Memory not generated"
  fi

  # PRD checks
  if [ -f "$PRD" ]; then
    check_grep "$PRD" "Depends on\|depends_on" "PRD: has Depends on"
    check_grep "$PRD" "Size" "PRD: has Size field"
  else
    fail "PRD not generated"
  fi
else
  fail "Init script failed to run"
fi
rm -rf "$TMPDIR"
echo ""

# =============================================================================
echo "━━━ CONSISTENCY: 3-Document Alignment ━━━"
# =============================================================================

# request_info in all 3
GOV_RI=$(grep -c "request_info" "$GOV" 2>/dev/null || echo 0)
PROTO_RI=$(grep -c "request_info" "$PROTO" 2>/dev/null || echo 0)
CMD_RI=$(grep -c "request_info" "$CMD" 2>/dev/null || echo 0)
if [ "$GOV_RI" -gt 0 ] && [ "$PROTO_RI" -gt 0 ] && [ "$CMD_RI" -gt 0 ]; then
  pass "request_info in all 3 docs (gov=$GOV_RI, proto=$PROTO_RI, cmd=$CMD_RI)"
else
  fail "request_info missing in some docs (gov=$GOV_RI, proto=$PROTO_RI, cmd=$CMD_RI)"
fi

# Fix Loop in all 3
GOV_FL=$(grep -c "Fix Loop" "$GOV" 2>/dev/null || echo 0)
PROTO_FL=$(grep -c "Fix Loop" "$PROTO" 2>/dev/null || echo 0)
CMD_FL=$(grep -c "Fix Loop\|fix loop\|Fix.*Loop" "$CMD" 2>/dev/null || echo 0)
if [ "$GOV_FL" -gt 0 ] && [ "$PROTO_FL" -gt 0 ] && [ "$CMD_FL" -gt 0 ]; then
  pass "Fix Loop referenced in all 3 docs (gov=$GOV_FL, proto=$PROTO_FL, cmd=$CMD_FL)"
else
  fail "Fix Loop missing in some docs (gov=$GOV_FL, proto=$PROTO_FL, cmd=$CMD_FL)"
fi

# consecutive in all 3
GOV_CF=$(grep -c "consecutive" "$GOV" 2>/dev/null || echo 0)
PROTO_CF=$(grep -c "consecutive" "$PROTO" 2>/dev/null || echo 0)
CMD_CF=$(grep -c "consecutive" "$CMD" 2>/dev/null || echo 0)
if [ "$GOV_CF" -gt 0 ] && [ "$PROTO_CF" -gt 0 ] && [ "$CMD_CF" -gt 0 ]; then
  pass "consecutive failures in all 3 docs (gov=$GOV_CF, proto=$PROTO_CF, cmd=$CMD_CF)"
else
  fail "consecutive missing in some docs (gov=$GOV_CF, proto=$PROTO_CF, cmd=$CMD_CF)"
fi

# Non-goals: NO YAML in memory spec
if grep -A20 "Campaign Memory" "$PROTO" | grep -qi "yaml format\|\.yaml\|\.yml"; then
  fail "Non-goal violation: YAML format mentioned in memory spec"
else
  pass "Non-goal: No YAML format in memory spec"
fi
echo ""

# =============================================================================
echo "╔══════════════════════════════════════════════════════════════╗"
printf "║  Result: ✅ PASS=%d  ❌ FAIL=%d  ⚠️  WARN=%d %*s║\n" "$PASS" "$FAIL" "$WARN" $((24 - ${#PASS} - ${#FAIL} - ${#WARN})) ""
echo "╚══════════════════════════════════════════════════════════════╝"

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "All verifications passed! v2-protocol changes are correctly applied."
  exit 0
else
  echo ""
  echo "$FAIL verification(s) failed. Check the items marked with ❌ above."
  exit 1
fi
