Execute the plan for loop-test.

Required reads every iteration:
- PRD: .claude/ralph-desk/plans/prd-loop-test.md
- Test Spec: .claude/ralph-desk/plans/test-spec-loop-test.md
- Campaign Memory: .claude/ralph-desk/memos/loop-test-memory.md
- Latest Context: .claude/ralph-desk/context/loop-test-latest.md

CRITICAL RULE: Work on only ONE User Story per iteration.
- Check campaign memory's "Next Iteration Contract" first and do that.
- Do not touch already-completed stories.

Iteration rules:
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly ONE bounded next action (ONE user story).
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.

MANDATORY: When done, write the following signal file:
- Path: .claude/ralph-desk/memos/loop-test-iter-signal.json
- Format: {"iteration": N, "status": "continue|verify|blocked", "summary": "what was done", "timestamp": "ISO"}
- Status values:
  - "continue" = current story done but other stories remain
  - "verify" = all stories complete + done-claim written
  - "blocked" = autonomous blocker

Stop behavior:
- Current story done but other stories remain → memory stop=continue, signal status=continue
- All stories complete + all tests pass → write done-claim JSON (.claude/ralph-desk/memos/loop-test-done-claim.json) + signal status=verify
- Autonomous blocker → write blocked.md + signal status=blocked

Objective: Implement a Python calculator module: calc.py (4 functions + type hints + ValueError) + test_calc.py (pytest, 8+ tests, all passed)
