#!/bin/bash
# TDD tests for template generation changes
# Run: bash tests/test_template_generation.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SCRIPT="src/scripts/init_ralph_desk.zsh"
CMD="src/commands/rlp-desk.md"
GOV="src/governance.md"
PASS=0; FAIL=0; TOTAL=0

assert_contains() {
  local file="$1" pattern="$2" label="$3"
  TOTAL=$((TOTAL+1))
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"; PASS=$((PASS+1))
  else
    echo "  FAIL: $label"; FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2" label="$3"
  TOTAL=$((TOTAL+1))
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  FAIL: $label (stale pattern still present)"; FAIL=$((FAIL+1))
  else
    echo "  PASS: $label"; PASS=$((PASS+1))
  fi
}

echo "=== Change 1: Run Preset Desync (11 tests) ==="
assert_not_contains "$SCRIPT" "\-\-final-consensus[^-]" "C1.1: no --final-consensus (not --final-consensus-model)"
assert_not_contains "$SCRIPT" "gpt-5\.3-codex-spark" "C1.2: no gpt-5.3-codex-spark"
assert_not_contains "$SCRIPT" "\-\-verify-consensus" "C1.3: no --verify-consensus"
assert_contains "$SCRIPT" "\-\-consensus final-only" "C1.4: --consensus final-only present"
assert_contains "$SCRIPT" "spark:high" "C1.5: spark:high present"
assert_contains "$SCRIPT" "default: haiku" "C1.6: worker default haiku"
assert_contains "$SCRIPT" "\-\-lock-worker-model" "C1.7: --lock-worker-model in options"
assert_contains "$SCRIPT" "\-\-cb-threshold" "C1.8: --cb-threshold in options"
assert_contains "$SCRIPT" "\-\-iter-timeout" "C1.9: --iter-timeout in options"
assert_contains "$SCRIPT" "\-\-consensus-model" "C1.10: --consensus-model in options"
assert_contains "$SCRIPT" "\-\-mode tmux" "C1.11: --mode tmux in recommended"

echo ""
echo "=== Change 2: Worker Planning Step (5 tests) ==="
assert_contains "$SCRIPT" "## Planning" "C2.1: Planning section in Worker prompt"
assert_contains "$SCRIPT" "step.*plan.*ac_id.*all" "C2.2: plan execution_step format"
assert_contains "$SCRIPT" "Keep planning lightweight" "C2.3: lightweight constraint"
assert_contains "$GOV" "\`plan\`, \`write_test\`" "C2.4: plan in governance step types"
assert_contains "$SCRIPT" "Planning Step.*decision.*info" "C2.5: Verifier plan audit"

echo ""
echo "=== Change 3: Brainstorm Exploration (3 tests) ==="
assert_contains "$CMD" "Codebase Exploration" "C3.1: exploration step present"
assert_contains "$CMD" "greenfield project" "C3.2: greenfield skip path"
assert_contains "$CMD" "entry points.*key modules" "C3.3: exploration instructions"

echo ""
echo "=== Change 4: Memory Bridge (3 tests) ==="
assert_contains "$CMD" "Campaign memory.*Key Decisions" "C4.1: init seeds memory instruction"
assert_contains "$SCRIPT" "seeded from brainstorm" "C4.2: seed markers in template"
assert_contains "$SCRIPT" "PRESERVE the Key Decisions" "C4.3: Worker preservation instruction"

echo ""
echo "=== Change 5: Coding Principles (9 tests) ==="
assert_contains "$SCRIPT" "## Coding Principles" "C5.1: Worker coding principles section"
assert_contains "$SCRIPT" "Think Before Coding" "C5.2: principle 1 in Worker"
assert_contains "$SCRIPT" "Simplicity First" "C5.3: principle 2 in Worker"
assert_contains "$SCRIPT" "Surgical Changes" "C5.4: principle 3 in Worker"
assert_contains "$SCRIPT" "Goal-Driven Execution" "C5.5: principle 4 in Worker"
assert_contains "$SCRIPT" "signal blocked with your options" "C5.6: Worker ask->blocked adapt"
assert_contains "$SCRIPT" "## Verification Principles" "C5.7: Verifier principles section"
assert_contains "$SCRIPT" "Think Before Judging" "C5.8: Verifier principle 1"
assert_contains "$SCRIPT" "Goal-Driven Verification" "C5.9: Verifier principle 2"

echo ""
echo "================================"
echo "TOTAL: $TOTAL tests"
echo "PASS:  $PASS"
echo "FAIL:  $FAIL"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
