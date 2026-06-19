# PRD: loop-test

## Objective
Implement a Python calculator module: calc.py + test_calc.py

## User Stories

### US-001: calc.py — Basic Operations
- **Priority**: P0
- **Acceptance Criteria**:
  - [ ] calc.py exists at the project root
  - [ ] Implements add(a, b), subtract(a, b), multiply(a, b), divide(a, b)
  - [ ] divide(a, 0) raises ValueError
  - [ ] All functions have type hints: (a: float, b: float) -> float
- **Status**: not started

### US-002: test_calc.py — Tests
- **Priority**: P0
- **Acceptance Criteria**:
  - [ ] test_calc.py exists at the project root
  - [ ] Uses pytest (import pytest)
  - [ ] At least 2 test cases per function (8+ total)
  - [ ] Includes divide-by-zero test (pytest.raises)
  - [ ] python3 -m pytest test_calc.py -v → ALL PASSED
- **Status**: not started

## Non-Goals
- CLI interface, complex math operations

## Technical Constraints
- Python 3 standard library + pytest only
- Work on only one story per iteration

## Done When
- US-001 and US-002 acceptance criteria all pass
- python3 -m pytest test_calc.py -v → ALL PASSED
- Independent verifier confirms
