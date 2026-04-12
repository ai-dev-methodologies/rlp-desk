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
- US-002 CLI command builder remains implemented:
  - `src/node/cli/command-builder.mjs`
  - `tests/node/us002-cli-command-builder.test.mjs`
- US-003 signal and verdict poller remains implemented:
  - `src/node/polling/signal-poller.mjs`
  - `tests/node/us003-signal-poller.test.mjs`
- US-004 prompt assembler is now implemented:
  - `src/node/prompts/prompt-assembler.mjs`
  - `tests/node/us004-prompt-assembler.test.mjs`
  - `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-004 traceability and criteria mappings
### In Progress
- Verifier handoff for US-004 evidence
### Next
- If US-004 passes verification, move to the next unverified Node rewrite story with fresh failing tests first

## Key Decisions
- Implemented the smallest Node API that matches the PRD: `assembleWorkerPrompt(options)`, `assembleVerifierPrompt(options)`, and `FileNotFoundError`.
- Kept prompt assembly string-based and file-path-driven instead of introducing new prompt object models or templating layers.
- Matched the shell runner's section order and wording for iteration context, fix-contract, per-US scope, verifier scope, and autonomous-mode guidance.
- Applied soft fallbacks for optional files: missing fix-contracts and per-US split files do not fail assembly, but missing base prompt files do.

## Known Issues
- No Node wrapper exists yet for higher-level runner orchestration, initializer flow, main loop behavior, analytics, or CLI entrypoints.
- The worktree still contains unrelated untracked files outside the US-004 scope and they were left untouched.

## Files Changed This Iteration
- `src/node/prompts/prompt-assembler.mjs`
- `tests/node/us004-prompt-assembler.test.mjs`
- `.claude/ralph-desk/plans/test-spec-node-rewrite.md`
- `.claude/ralph-desk/memos/node-rewrite-memory.md`
- `.claude/ralph-desk/context/node-rewrite-latest.md`
- `.claude/ralph-desk/memos/node-rewrite-done-claim.json`
- `.claude/ralph-desk/memos/node-rewrite-iter-signal.json`

## Verification Status
- RED full US-004 suite: `node --test tests/node/us004-prompt-assembler.test.mjs` -> exit 1 because `src/node/prompts/prompt-assembler.mjs` did not exist yet
- GREEN AC4.1 subset: `node --test --test-name-pattern "US-004 AC4.1" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 3/3 pass
- GREEN AC4.2 subset: `node --test --test-name-pattern "US-004 AC4.2" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 3/3 pass
- GREEN AC4.3 subset: `node --test --test-name-pattern "US-004 AC4.3" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 3/3 pass
- GREEN AC4.4 subset: `node --test --test-name-pattern "US-004 AC4.4" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 happy subset: `node --test --test-name-pattern "US-004 AC4.1 happy|US-004 AC4.2 happy|US-004 AC4.3 happy" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 boundary subset: `node --test --test-name-pattern "US-004 AC4.1 boundary|US-004 AC4.2 boundary|US-004 AC4.3 boundary|US-004 AC4.4 boundary" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 4/4 pass
- GREEN L3 error subset: `node --test --test-name-pattern "US-004 AC4.1 negative|US-004 AC4.2 negative|US-004 AC4.3 negative|US-004 AC4.4 happy|US-004 AC4.4 negative" tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 5/5 pass
- GREEN full US-004 suite: `node --test tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 12/12 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs` -> exit 0, 57/57 pass
