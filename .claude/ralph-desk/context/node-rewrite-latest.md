# node-rewrite - Latest Context

## Current Frontier
### Completed
- US-00 bootstrap foundations remain implemented:
  - `src/node/shared/paths.mjs`
  - `src/node/shared/fs.mjs`
  - `tests/node/us00-bootstrap.test.mjs`
- US-001 tmux pane manager remains implemented:
  - `src/node/tmux/pane-manager.mjs`
  - `tests/node/us001-tmux-pane-manager.test.mjs`
- US-002 CLI command builder is now implemented:
  - `src/node/cli/command-builder.mjs`
  - `tests/node/us002-cli-command-builder.test.mjs`
  - `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-002 traceability and criteria mappings
### In Progress
- Verifier handoff for US-002 evidence
### Next
- If US-002 passes verification, move to the next unverified Node rewrite story with fresh failing tests first

## Key Decisions
- Implemented the smallest Node API that matches the PRD: Claude command building, Codex command building, and unified model-flag parsing.
- Preserved the legacy zsh launch strings instead of introducing extra abstractions, because later runner stories depend on those exact flag sequences.
- Kept `tui` as the only supported mode in US-002 and fail fast on unsupported modes to avoid speculative print-mode work.
- Preserved the boundary behavior where empty Claude effort and empty Codex reasoning remain parseable when the input has a trailing colon.

## Known Issues
- No Node wrapper exists yet for tmux session lifecycle, pollers, prompt assembly, initializer flow, main loop behavior, analytics, or CLI entrypoints.
- The worktree still contains unrelated untracked files outside the US-002 scope and they were left untouched.

## Files Changed This Iteration
- `src/node/cli/command-builder.mjs`
- `tests/node/us002-cli-command-builder.test.mjs`
- `.claude/ralph-desk/plans/test-spec-node-rewrite.md`
- `.claude/ralph-desk/memos/node-rewrite-memory.md`
- `.claude/ralph-desk/context/node-rewrite-latest.md`
- `.claude/ralph-desk/memos/node-rewrite-done-claim.json`
- `.claude/ralph-desk/memos/node-rewrite-iter-signal.json`

## Verification Status
- RED full US-002 suite: `node --test tests/node/us002-cli-command-builder.test.mjs` -> exit 1 because `src/node/cli/command-builder.mjs` did not exist yet
- GREEN full US-002 suite: `node --test tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 15/15 pass
- GREEN AC2.1 subset: `node --test --test-name-pattern "US-002 AC2.1" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.2 subset: `node --test --test-name-pattern "US-002 AC2.2" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.3 subset: `node --test --test-name-pattern "US-002 AC2.3" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.4 subset: `node --test --test-name-pattern "US-002 AC2.4" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.5 subset: `node --test --test-name-pattern "US-002 AC2.5" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN happy subset: `node --test --test-name-pattern "happy" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN boundary subset: `node --test --test-name-pattern "boundary" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN negative subset: `node --test --test-name-pattern "negative" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 33/33 pass
