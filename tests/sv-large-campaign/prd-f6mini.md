# PRD: f6mini

## Objective
Minimal 1-US repro to prove the F-6 fix lets a campaign COMPLETE on a DIRTY
(realistic) repo that carries a pre-existing untracked file. Implement a single
`models.py` module. Python 3 stdlib + pytest only; flat layout at project root.

## User Stories

### US-001: models.py — Task model
- **Priority**: P0
- **Acceptance Criteria**:
  - [ ] models.py exists at the project root
  - [ ] `make_task(title, priority="med")` returns a Task with a non-empty id and done=False
  - [ ] An invalid priority (not in {"low","med","high"}) raises ValueError
- **Status**: not started

## Non-Goals
- Anything beyond the single Task model.

## Technical Constraints
- Python 3 standard library + pytest only
- Work on only one story per iteration

## Done When
- US-001 acceptance criteria all pass
- `python3 -m pytest -v` → ALL PASSED
- Independent verifier confirms
