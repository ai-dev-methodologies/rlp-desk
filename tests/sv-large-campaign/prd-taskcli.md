# PRD: taskcli

## Objective
Implement `taskcli`, a JSON-backed command-line task manager in Python (flat
module layout, pytest-verified). The project is intentionally decomposed into 12
small, dependency-chained User Stories so a real campaign must run many
iterations and carry state across fresh-context Worker/Verifier handoffs purely
through files on disk. This is the canonical LARGE self-verification repro: the
kind of multi-iteration, integration-heavy campaign where compound failures
surface (per docs/rlp-desk/failure-modes.md F1.x/F2.x).

All files live flat at the project root. Persistence is a single JSON file
(`tasks.json` by default). Python 3 standard library + pytest only.

## User Stories

### US-001: models.py — Task model
- **Priority**: P0
- **Acceptance Criteria**:
  - [ ] models.py exists at the project root
  - [ ] Defines a `Task` with fields: id:str, title:str, done:bool, priority:str, created_at:str
  - [ ] `make_task(title, priority="med")` returns a Task with a generated non-empty id and done=False
  - [ ] An invalid priority (not in {"low","med","high"}) raises ValueError
- **Status**: not started

### US-002: store.py — JSON persistence
- **Priority**: P0
- **Depends on**: US-001
- **Acceptance Criteria**:
  - [ ] store.py exists; exposes `load_tasks(path)` and `save_tasks(path, tasks)`
  - [ ] `load_tasks` on a missing path returns an empty list (no exception)
  - [ ] `save_tasks(path, tasks)` then `load_tasks(path)` round-trips task data faithfully
  - [ ] A corrupt/non-JSON file makes `load_tasks` return an empty list (graceful, no crash)
- **Status**: not started

### US-003: service.py — add_task
- **Priority**: P0
- **Depends on**: US-001, US-002
- **Acceptance Criteria**:
  - [ ] service.py exists; `add_task(path, title, priority="med")` appends a new task, persists it, and returns it
  - [ ] After `add_task`, the task is retrievable via `store.load_tasks(path)`
  - [ ] Two successive `add_task` calls yield two distinct task ids
- **Status**: not started

### US-004: service.py — list_tasks
- **Priority**: P0
- **Depends on**: US-002
- **Acceptance Criteria**:
  - [ ] `list_tasks(path)` returns all tasks ordered by created_at ascending
  - [ ] `list_tasks(path, done=False)` returns only pending tasks; `done=True` only completed
  - [ ] Returns an empty list when the store is empty
- **Status**: not started

### US-005: service.py — complete_task
- **Priority**: P0
- **Depends on**: US-003
- **Acceptance Criteria**:
  - [ ] `complete_task(path, task_id)` sets done=True for that task and persists
  - [ ] Calling it twice on the same id is idempotent (stays done, no error)
  - [ ] An unknown id raises KeyError
- **Status**: not started

### US-006: service.py — delete_task
- **Priority**: P1
- **Depends on**: US-003
- **Acceptance Criteria**:
  - [ ] `delete_task(path, task_id)` removes the task, persists, and returns the remaining count
  - [ ] An unknown id raises KeyError
  - [ ] Deleting the last task leaves an empty store that `load_tasks` reads as `[]`
- **Status**: not started

### US-007: service.py — search_tasks
- **Priority**: P1
- **Depends on**: US-004
- **Acceptance Criteria**:
  - [ ] `search_tasks(path, query)` returns tasks whose title contains the query, case-insensitively
  - [ ] An empty query returns all tasks
  - [ ] No match returns an empty list
- **Status**: not started

### US-008: stats.py — compute_stats
- **Priority**: P1
- **Depends on**: US-001
- **Acceptance Criteria**:
  - [ ] stats.py exists; `compute_stats(tasks)` returns a dict with keys total, done, pending
  - [ ] It also returns `by_priority` as a dict with keys low, med, high
  - [ ] total == done + pending, and sum(by_priority.values()) == total
- **Status**: not started

### US-009: export.py — to_csv
- **Priority**: P1
- **Depends on**: US-001
- **Acceptance Criteria**:
  - [ ] export.py exists; `to_csv(out_path, tasks)` writes a CSV with a header row then one row per task
  - [ ] The CSV columns are exactly: id, title, done, priority
  - [ ] For N tasks the file has N+1 non-empty lines
- **Status**: not started

### US-010: cli.py — argparse entrypoint
- **Priority**: P0
- **Depends on**: US-003, US-004, US-005, US-006, US-007, US-008, US-009
- **Acceptance Criteria**:
  - [ ] cli.py exists; `python3 cli.py --store <path> add "Buy milk"` creates a task and exits 0
  - [ ] `python3 cli.py --store <path> list` prints the created task's title and exits 0
  - [ ] Supports subcommands: add, list, complete, delete, search, stats, export (dispatching to service/stats/export)
- **Status**: not started

### US-011: test_taskcli.py — unit tests
- **Priority**: P0
- **Depends on**: US-001, US-002, US-003, US-004, US-005, US-006, US-007, US-008, US-009
- **Acceptance Criteria**:
  - [ ] test_taskcli.py exists and uses pytest, using a tmp_path store (never the real tasks.json)
  - [ ] At least 12 test cases covering round-trip, add, list filter, complete, delete, search, stats, export
  - [ ] Includes negative tests: unknown-id KeyError, invalid-priority ValueError, corrupt-store returns []
  - [ ] `python3 -m pytest test_taskcli.py -v` → ALL PASSED
- **Status**: not started

### US-012: test_integration.py — end-to-end flow
- **Priority**: P0
- **Depends on**: US-010, US-011
- **Acceptance Criteria**:
  - [ ] test_integration.py exists and drives the full lifecycle: add → list → complete → search → stats → export → delete
  - [ ] Asserts stats reflect the lifecycle (e.g. done count increases after complete) and the exported CSV has the expected row count
  - [ ] `python3 -m pytest test_integration.py -v` → ALL PASSED
- **Status**: not started

## Non-Goals
- Networking, databases, concurrency, or a TUI
- Task editing/renaming, recurring tasks, or due dates
- Any dependency beyond the Python 3 standard library + pytest

## Technical Constraints
- Python 3 standard library + pytest only
- Flat module layout at the project root (no packages): models.py, store.py,
  service.py, stats.py, export.py, cli.py, test_taskcli.py, test_integration.py
- Work on only ONE User Story per iteration
- Build incrementally: each story must integrate with the files written by prior
  stories (state carries through files on disk, not memory)

## Done When
- All 12 User Stories' acceptance criteria pass
- `python3 -m pytest -v` (collecting test_taskcli.py and test_integration.py) → ALL PASSED
- An independent verifier confirms the full add→complete→stats→export→delete flow
