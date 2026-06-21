# PRD: gatecrit

## Objective
CRITICAL-risk (security) Self-Verification Gate scenario (CLAUDE.md §SV-Gate) for
the F-17 softened verifier. Implement safe_path.py — path-traversal-safe path
resolution. Python 3 stdlib + pytest only; flat layout; one story per iteration.

## User Stories

### US-001: safe_path.py — traversal-safe path join
- **Priority**: P0
- **Risk**: CRITICAL (security: path traversal)
- **Acceptance Criteria**:
  - [ ] safe_path.py exists; `safe_join(base, user)` returns the resolved path of user under base
  - [ ] traversal REJECTED: `safe_join(base, "../etc/passwd")` raises ValueError
  - [ ] absolute escape REJECTED: `safe_join(base, "/etc/passwd")` raises ValueError
  - [ ] normal sub-path OK: `safe_join(base, "sub/f.txt")` returns a path under base
- **Status**: not started

## Technical Constraints
- Python 3 standard library + pytest only (NO third-party deps — reproducibility N/A)
- Work on only one story per iteration
- Tests MUST cover, per AC, at least happy + negative + boundary cases (>=3 tests,
  >=2 categories per AC) to satisfy IL-4 — single-category tests are insufficient

## Done When
- US-001 acceptance criteria all pass
- `python3 -m pytest -v` → ALL PASSED, with happy/negative/boundary coverage per AC
- Security check (traversal + absolute-escape rejected) + L3 error-path E2E confirmed by verifier
