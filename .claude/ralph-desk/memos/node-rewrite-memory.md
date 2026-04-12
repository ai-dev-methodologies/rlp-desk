# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 4 implemented US-003 only. The new Node module `src/node/polling/signal-poller.mjs` adds `pollForSignal()` and `TimeoutError` for the rewrite's signal/verdict polling flow. The poller now waits for valid JSON, retries through missing or partially written files, enforces a bounded timeout, and applies a Codex-only second phase that waits for the pane process to return to a shell before resolving. `tests/node/us003-signal-poller.test.mjs` adds 12 node:test cases so every US-003 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-003 traceability rows, criteria mappings, and verification commands.

## Completed Stories
- US-00: Node bootstrap foundations for the rewrite
  - `src/node/shared/paths.mjs` resolves repo-local absolute paths and rejects traversal outside the project root
  - `src/node/shared/fs.mjs` performs atomic writes inside the repo root and rejects outside-root targets
  - `tests/node/us00-bootstrap.test.mjs` provides 6 node:test cases with isolated per-process scratch paths for AC1/AC2 happy, boundary, and negative coverage
- US-001: Tmux Pane Manager
  - `src/node/tmux/pane-manager.mjs` adds `TmuxError`, `createPane`, `sendKeys`, and `waitForProcessExit`
  - `tests/node/us001-tmux-pane-manager.test.mjs` provides 12 real-`tmux` node:test cases with 3 tests per AC across happy, boundary, and negative coverage
- US-002: CLI Command Builder
  - `src/node/cli/command-builder.mjs` adds `buildClaudeCmd`, `buildCodexCmd`, and `parseModelFlag`
  - `tests/node/us002-cli-command-builder.test.mjs` provides 15 node:test cases with 3 tests per AC across happy, boundary, and negative coverage
- US-003: Signal and Verdict Poller
  - `src/node/polling/signal-poller.mjs` adds `pollForSignal` and `TimeoutError`
  - The poller retries through `ENOENT` and invalid JSON until a valid JSON payload appears or the overall deadline expires
  - Codex mode preserves the two-phase contract by waiting for both valid JSON and the pane process returning to `zsh`/`bash`/`sh`
  - `tests/node/us003-signal-poller.test.mjs` provides 12 node:test cases with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should check US-003 only.

**Criteria**:
- US-003 AC3.1: `pollForSignal()` keeps polling until the verdict file exists and contains valid JSON, then resolves with the parsed payload
- US-003 AC3.2: `pollForSignal()` in codex mode waits for both valid JSON and pane exit before resolving
- US-003 AC3.3: `pollForSignal()` rejects with `TimeoutError` instead of hanging when no valid verdict appears before timeout
- US-003 AC3.4: invalid or partially written JSON does not resolve early and is retried until a later poll returns valid JSON

## Key Decisions
- Kept US-003 surgical: one new module under `src/node/polling/` with only the APIs required by the PRD.
- Used dependency injection for `readFile` and `getPaneCommand` so L1 tests can stay deterministic while the default path still uses real `fs` and `tmux`.
- Treated invalid JSON and partially written files as retryable states instead of surfacing parse errors to callers prematurely.
- Applied the same overall timeout budget to both phases so codex polling cannot hang after the verdict file appears.

## Patterns Discovered
- Valid JSON is the first gate; codex pane-state polling should not begin until the file parses successfully.
- Partially written files naturally surface as `SyntaxError`, so retrying parse failures is enough to cover the atomic-write-in-progress boundary.
- Treating an empty tmux command as shell-like matches the zsh poller grace-path behavior when the pane is already idle or gone.
- Repo-local `.tmp` scratch paths are sufficient for L3 real-file polling coverage without introducing new dependencies.

## Learnings
- US-003 can stay independent from the higher-level runner orchestration by focusing on one poller function with injectable I/O boundaries.
- The verifier-facing and worker-facing JSON files share the same core polling requirement: do not trust the file until `JSON.parse` succeeds.
- Codex needs explicit second-phase handling because file presence alone does not guarantee the TUI process has finished flushing output.

## Evidence Chain
- RED full US-003 suite: `node --test tests/node/us003-signal-poller.test.mjs` -> exit 1 because `src/node/polling/signal-poller.mjs` did not exist yet (`ERR_MODULE_NOT_FOUND`)
- GREEN full US-003 suite: `node --test tests/node/us003-signal-poller.test.mjs` -> exit 0, 12/12 pass
- GREEN AC3.1 subset: `node --test --test-name-pattern "US-003 AC3.1" tests/node/us003-signal-poller.test.mjs` -> exit 0, 3/3 pass
- GREEN AC3.2 subset: `node --test --test-name-pattern "US-003 AC3.2" tests/node/us003-signal-poller.test.mjs` -> exit 0, 3/3 pass
- GREEN AC3.3 subset: `node --test --test-name-pattern "US-003 AC3.3" tests/node/us003-signal-poller.test.mjs` -> exit 0, 3/3 pass
- GREEN AC3.4 subset: `node --test --test-name-pattern "US-003 AC3.4" tests/node/us003-signal-poller.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 happy subset: `node --test --test-name-pattern "US-003 AC3.1 boundary|US-003 AC3.4 happy" tests/node/us003-signal-poller.test.mjs` -> exit 0, 2/2 pass
- GREEN L3 boundary subset: `node --test --test-name-pattern "US-003 AC3.2 boundary|US-003 AC3.3 boundary|US-003 AC3.4 boundary" tests/node/us003-signal-poller.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 error subset: `node --test --test-name-pattern "US-003 AC3.1 negative|US-003 AC3.2 negative|US-003 AC3.3 negative|US-003 AC3.4 negative" tests/node/us003-signal-poller.test.mjs` -> exit 0, 4/4 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs` -> exit 0, 45/45 pass
