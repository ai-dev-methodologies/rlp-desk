# PRD: gatemed

## Objective
MEDIUM-risk (file I/O) Self-Verification Gate scenario (CLAUDE.md §SV-Gate) for
the F-17 softened verifier. Implement kvstore.py — JSON-file key/value
persistence. Python 3 stdlib + pytest only; flat layout; one story per iteration.

## User Stories

### US-001: kvstore.py — JSON key/value persistence
- **Priority**: P0
- **Risk**: MEDIUM (file I/O / real local integration)
- **Acceptance Criteria**:
  - [ ] kvstore.py exists; `kv_set(path, key, value)` creates/updates a JSON file
  - [ ] `kv_get(path, key)` returns the stored value; a missing key returns None
  - [ ] set then get round-trips across SEPARATE calls (real file persistence)
  - [ ] a corrupt/non-JSON file → `kv_get` returns None (graceful, no crash)
- **Status**: not started

## Technical Constraints
- Python 3 standard library + pytest only
- Work on only one story per iteration

## Done When
- US-001 acceptance criteria all pass
- `python3 -m pytest -v` → ALL PASSED
- Independent verifier confirms L1 (unit) + L3 (E2E round-trip); L2/L4 N/A
