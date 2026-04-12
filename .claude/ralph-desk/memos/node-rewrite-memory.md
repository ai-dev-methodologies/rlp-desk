# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 1 - US-00 bootstrap implemented and ready for verification

## Completed Stories
- US-00: Node bootstrap foundations for the rewrite
  - Added `src/node/shared/paths.mjs` with `projectRoot`, `ensureProjectPath()`, and `resolveProjectPath()`
  - Added `src/node/shared/fs.mjs` with `writeFileAtomic()` using sibling tmp-file rename semantics
  - Added `tests/node/us00-bootstrap.test.mjs` with 6 node:test cases covering happy, boundary, and negative paths for AC1 and AC2
  - Updated `test-spec-node-rewrite.md` with concrete verification commands and traceability for US-00

## Next Iteration Contract
Verifier should check US-00 only. If US-00 passes, begin US-001 (Tmux Pane Manager) with tests-first execution.

**Criteria**:
- US-00 AC1: project-root path resolution returns repo-local absolute paths and rejects escape attempts
- US-00 AC2: atomic file writes succeed inside the repo root and reject outside-root targets

## Key Decisions
- Iteration prompt required `US-00`, but the PRD defines stories starting at `US-001`; resolved by deriving a bounded bootstrap story directly from the PRD objective and logging the conflict.
- Bootstrap scope was kept below `US-001`: only shared Node filesystem/path primitives, no tmux behavior or CLI routing.

## Patterns Discovered
- Node built-in `node:test` is sufficient for the first rewrite slice; no external dependencies are required.
- Future Node modules can share `ensureProjectPath()` and `writeFileAtomic()` to satisfy the PRD atomic-write constraint consistently.

## Learnings
- The repo currently contains only zsh runtime code; a Node scaffold did not exist before this iteration.
- `node --test --test-name-pattern "<AC>" <file>` provides clean per-AC evidence for execution_steps and traceability.

## Evidence Chain
- RED: `node --test tests/node/us00-bootstrap.test.mjs` -> exit 1 (`ERR_MODULE_NOT_FOUND` for `src/node/shared/{paths,fs}.mjs`)
- GREEN AC1: `node --test --test-name-pattern "AC1" tests/node/us00-bootstrap.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2: `node --test --test-name-pattern "AC2" tests/node/us00-bootstrap.test.mjs` -> exit 0, 3/3 pass
- GREEN full suite: `node --test tests/node/us00-bootstrap.test.mjs` -> exit 0, 6/6 pass
- Build smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs');"` -> exit 0
