# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 2 repaired the US-00 verifier blockers and refreshed the verification artifacts. US-00 is ready for re-verification.

## Completed Stories
- US-00: Node bootstrap foundations for the rewrite
  - `src/node/shared/paths.mjs` resolves repo-local absolute paths and rejects traversal outside the project root
  - `src/node/shared/fs.mjs` performs atomic writes inside the repo root and rejects outside-root targets
  - `tests/node/us00-bootstrap.test.mjs` provides 6 node:test cases with isolated per-process scratch paths for AC1/AC2 happy, boundary, and negative coverage
  - `prd-node-rewrite.md` now defines US-00 explicitly so verifier scope has PRD-backed acceptance criteria
  - `test-spec-node-rewrite.md` now has concrete US-00 L3 commands, no leftover placeholder rows, and L3 criteria mapping entries for happy/boundary-negative subsets

## Next Iteration Contract
Verifier should check US-00 only.

**Criteria**:
- US-00 AC1: project-root path resolution returns repo-local absolute paths and rejects escape attempts
- US-00 AC2: atomic file writes succeed inside the repo root and reject outside-root targets

## Key Decisions
- Resolved the missing-PRD-story blocker by adding an explicit US-00 bootstrap story to the PRD rather than re-scoping verification to US-001.
- Kept the code change surgical: only the US-00 test harness was adjusted, because the implementation modules already satisfied the intended bootstrap behavior.
- Made the test scratch directory process-scoped so filtered verification commands remain deterministic even when multiple `node --test` processes run concurrently.

## Patterns Discovered
- `node:test` name filtering works as intended when `--test-name-pattern` appears before the file path.
- Shared filesystem fixtures can create false negatives across parallel test processes even when individual tests reset state; process-scoped scratch roots remove that interference cheaply.

## Learnings
- The verifier depends on PRD-defined scope, so bootstrap work must be represented as a real PRD story instead of an implied prerequisite.
- Test-spec placeholder rows are enough to fail verification even when the implementation itself is correct.

## Evidence Chain
- RED existing verification command: `node --test --test-name-pattern "AC2" tests/node/us00-bootstrap.test.mjs` -> exit 1 before the test harness fix (`directoryEntries` assertion was unstable under shared scratch paths)
- GREEN AC1: `node --test --test-name-pattern "AC1" tests/node/us00-bootstrap.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2: `node --test --test-name-pattern "AC2" tests/node/us00-bootstrap.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 happy subset: `node --test --test-name-pattern "happy" tests/node/us00-bootstrap.test.mjs` -> exit 0, 2/2 pass
- GREEN L3 boundary/negative subset: `node --test --test-name-pattern "negative|boundary" tests/node/us00-bootstrap.test.mjs` -> exit 0, 4/4 pass
- GREEN full suite: `node --test tests/node/us00-bootstrap.test.mjs` -> exit 0, 6/6 pass
- Build smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs');"` -> exit 0
