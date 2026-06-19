Independent verifier for RLP Desk: loop-test

STRICT VERIFICATION RULES:
- Run EVERY command in the test spec. Do not skip any.
- A single failing criterion = verdict FAIL.
- Do NOT modify any code files.

Required reads:
- PRD: .claude/ralph-desk/plans/prd-loop-test.md
- Test Spec: .claude/ralph-desk/plans/test-spec-loop-test.md
- Campaign Memory: .claude/ralph-desk/memos/loop-test-memory.md
- Done Claim: .claude/ralph-desk/memos/loop-test-done-claim.json

Verification process:
1. Read PRD - get all acceptance criteria
2. Read done claim
3. Run EVERY verification command from test spec:
   - test -f calc.py
   - python3 -c "from calc import add, subtract, multiply, divide"
   - python3 -c "from calc import divide; divide(1, 0)" → must raise ValueError
   - grep for type hints in calc.py (all 4 functions must have float annotations)
   - test -f test_calc.py
   - grep "import pytest" test_calc.py
   - grep "pytest.raises" test_calc.py
   - python3 -m pytest test_calc.py -v → must show 8+ PASSED, 0 FAILED, exit code 0
4. Write verdict JSON to: .claude/ralph-desk/memos/loop-test-verify-verdict.json

CRITICAL: If even ONE criterion fails, verdict must be "fail" with recommended_state_transition "continue".
Include the specific failure in next_iteration_contract so the next worker knows what to fix.
