# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 1 implemented US-001 for the Node rewrite and refreshed the verification artifacts. US-001 is ready for verifier review.

## Completed Stories
- US-00: Node bootstrap foundations for the rewrite
  - `src/node/shared/paths.mjs` resolves repo-local absolute paths and rejects traversal outside the project root
  - `src/node/shared/fs.mjs` performs atomic writes inside the repo root and rejects outside-root targets
  - `tests/node/us00-bootstrap.test.mjs` provides 6 node:test cases with isolated per-process scratch paths for AC1/AC2 happy, boundary, and negative coverage
- US-001: Tmux Pane Manager
  - `src/node/tmux/pane-manager.mjs` adds `TmuxError`, `createPane`, `sendKeys`, and `waitForProcessExit`
  - `tests/node/us001-tmux-pane-manager.test.mjs` provides 12 real-`tmux` node:test cases with 3 tests per AC across happy, boundary, and negative coverage
  - `test-spec-node-rewrite.md` now includes concrete US-001 traceability rows and criteria mappings with actual file paths and test names

## Next Iteration Contract
Verifier should check US-001 only.

**Criteria**:
- US-001 AC1.1: pane manager creates a pane in an active tmux session, returns its pane ID, and `tmux list-panes` confirms it exists
- US-001 AC1.2: `sendKeys` writes a shell command into the target pane and the command output appears in pane capture within 2 seconds
- US-001 AC1.3: `waitForProcessExit` resolves only after `pane_current_command` returns to `zsh`/`bash`/`sh`
- US-001 AC1.4: invalid pane IDs cause `sendKeys` to reject with `TmuxError` and include the pane ID in the error message

## Key Decisions
- Kept US-001 surgical: one new module under `src/node/tmux/` with only the APIs required by the PRD.
- Used real detached tmux sessions in `node:test` instead of mocks so L3-style evidence comes from the actual CLI behavior the rewrite depends on.
- Treated shell readiness as `pane_current_command` returning to `zsh`, `bash`, or `sh`, which satisfies the PRD language without coupling to one shell.

## Patterns Discovered
- `tmux split-window -P -F '#{pane_id}'` is enough to create deterministic pane IDs for tests without extra session bookkeeping code.
- `tmux send-keys -l -- <command>` followed by `Enter` preserves quoting reliably for the shell command strings used by the runner.
- AC1.3 negative coverage needs a synchronization wait until `pane_current_command` becomes `sleep`; otherwise the race can start before the subprocess is actually running.

## Learnings
- Real tmux integration is stable in detached sessions, so the Node rewrite can verify pane behavior without needing to be launched inside an existing interactive tmux client.
- The PRD boundary cases do not require a session-creation API yet; keeping US-001 scoped to pane-level operations avoids premature abstraction.

## Evidence Chain
- RED AC1.1: `node --test --test-name-pattern "US-001 AC1.1" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 1 before implementation (`ERR_MODULE_NOT_FOUND` for `src/node/tmux/pane-manager.mjs`)
- RED AC1.2: `node --test --test-name-pattern "US-001 AC1.2" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 1 before implementation (`ERR_MODULE_NOT_FOUND`)
- RED AC1.3: `node --test --test-name-pattern "US-001 AC1.3" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 1 before implementation (`ERR_MODULE_NOT_FOUND`)
- RED AC1.4: `node --test --test-name-pattern "US-001 AC1.4" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 1 before implementation (`ERR_MODULE_NOT_FOUND`)
- GREEN build smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs');"` -> exit 0
- GREEN AC1.1: `node --test --test-name-pattern "US-001 AC1.1" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 3/3 pass
- GREEN AC1.2: `node --test --test-name-pattern "US-001 AC1.2" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 3/3 pass
- GREEN AC1.3: `node --test --test-name-pattern "US-001 AC1.3" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 3/3 pass
- GREEN AC1.4: `node --test --test-name-pattern "US-001 AC1.4" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 happy subset: `node --test --test-name-pattern "happy" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 4/4 pass
- GREEN L3 boundary subset: `node --test --test-name-pattern "boundary" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 4/4 pass
- GREEN L3 error subset: `node --test --test-name-pattern "negative" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 4/4 pass
- GREEN full suite: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
