# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 2 kept scope on US-001 only and fixed the verifier-reported AC1.3 happy-test race in `tests/node/us001-tmux-pane-manager.test.mjs`. The implementation in `src/node/tmux/pane-manager.mjs` was left unchanged. US-001 is ready for verifier review again with refreshed evidence.

## Completed Stories
- US-00: Node bootstrap foundations for the rewrite
  - `src/node/shared/paths.mjs` resolves repo-local absolute paths and rejects traversal outside the project root
  - `src/node/shared/fs.mjs` performs atomic writes inside the repo root and rejects outside-root targets
  - `tests/node/us00-bootstrap.test.mjs` provides 6 node:test cases with isolated per-process scratch paths for AC1/AC2 happy, boundary, and negative coverage
- US-001: Tmux Pane Manager
  - `src/node/tmux/pane-manager.mjs` adds `TmuxError`, `createPane`, `sendKeys`, and `waitForProcessExit`
  - `tests/node/us001-tmux-pane-manager.test.mjs` still provides 12 real-`tmux` node:test cases with 3 tests per AC across happy, boundary, and negative coverage
  - Iteration 2 changed only the AC1.3 happy test so it waits for `pane_current_command` to become `sleep` before timing `waitForProcessExit`, eliminating the flaky post-resolution shell re-check
  - `test-spec-node-rewrite.md` includes concrete US-001 traceability rows and criteria mappings with actual file paths and test names

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
- For the AC1.3 happy-path verifier fix, synchronized the test on `pane_current_command === 'sleep'` before timing `waitForProcessExit`; this validates the process-exit contract directly and avoids TOCTOU races from shell init commands after resolution.

## Patterns Discovered
- `tmux split-window -P -F '#{pane_id}'` is enough to create deterministic pane IDs for tests without extra session bookkeeping code.
- `tmux send-keys -l -- <command>` followed by `Enter` preserves quoting reliably for the shell command strings used by the runner.
- AC1.3 negative coverage needs a synchronization wait until `pane_current_command` becomes `sleep`; otherwise the race can start before the subprocess is actually running.
- AC1.3 happy coverage needs the same synchronization before the measurement window starts; without it, the test can pass or fail based on timing before the shell launches `sleep`.

## Learnings
- Real tmux integration is stable in detached sessions, so the Node rewrite can verify pane behavior without needing to be launched inside an existing interactive tmux client.
- The PRD boundary cases do not require a session-creation API yet; keeping US-001 scoped to pane-level operations avoids premature abstraction.
- A post-resolution assertion on `pane_current_command` is weaker than measuring the wait against a known running process because the shell may launch transient init commands after control returns.

## Evidence Chain
- RED regression test: `node --test --test-name-pattern "US-001 AC1.3 happy" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 1 after replacing the flaky shell re-check with an elapsed-time assertion before synchronizing on `sleep`
- GREEN targeted happy regression: `node --test --test-name-pattern "US-001 AC1.3 happy" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0 after adding `waitForCurrentCommand(rootPaneId, 'sleep', 2000)`
- GREEN AC1.3 subset: `node --test --test-name-pattern "US-001 AC1.3" tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 3/3 pass
- GREEN full US-001 suite: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
- GREEN stability run 1: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
- GREEN stability run 2: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
- GREEN stability run 3: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
- GREEN stability run 4: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
- GREEN stability run 5: `node --test tests/node/us001-tmux-pane-manager.test.mjs` -> exit 0, 12/12 pass
