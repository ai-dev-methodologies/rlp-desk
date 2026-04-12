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
- US-004 prompt assembler remains implemented:
  - `src/node/prompts/prompt-assembler.mjs`
  - `tests/node/us004-prompt-assembler.test.mjs`
- US-005 campaign initializer remains implemented:
  - `src/node/init/campaign-initializer.mjs`
  - `tests/node/us005-campaign-initializer.test.mjs`
- US-006 campaign main loop remains implemented:
  - `src/node/runner/campaign-main-loop.mjs`
  - `tests/node/us006-campaign-main-loop.test.mjs`
- US-007 analytics and reporting remains implemented:
  - `src/node/reporting/campaign-reporting.mjs`
  - `src/node/runner/campaign-main-loop.mjs`
  - `tests/node/us007-analytics-reporting.test.mjs`
- US-008 CLI entry point and npm integration is now implemented:
  - `src/node/run.mjs`
  - `scripts/postinstall.js`
  - `scripts/uninstall.js`
  - `package.json`
  - `tests/node/us008-cli-entrypoint.test.mjs`
  - `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-008 traceability and criteria mappings
### In Progress
- Verifier handoff for US-008 evidence
### Next
- If US-008 passes verification, the next step is final ALL verification for the completed Node rewrite stories

## Key Decisions
- Added a Node CLI entry point instead of extending the old zsh runner, so the runtime can now be installed and invoked entirely from `~/.claude/ralph-desk/node`.
- Kept the CLI focused on the existing command surface and documented `run` flags without broadening scope into a slash-command markdown rewrite.
- Removed legacy zsh runtime files from the package publish list and from postinstall on supported Node versions.
- Treated unsupported or malformed Node versions as a no-op fallback during postinstall so existing zsh installs stay intact.

## Known Issues
- `brainstorm`, `logs`, `clean`, and `resume` are still explicit stubs in `src/node/run.mjs`; only `run`, `init`, `status`, and help are wired in this story.
- The installed slash-command markdown still lives outside this story scope; US-008 only guarantees the Node CLI/runtime needed once that command file points to Node.
- The worktree still contains unrelated untracked files outside the US-008 scope and they were left untouched.

## Files Changed This Iteration
- `src/node/run.mjs`
- `scripts/postinstall.js`
- `scripts/uninstall.js`
- `package.json`
- `tests/node/us008-cli-entrypoint.test.mjs`
- `.claude/ralph-desk/plans/test-spec-node-rewrite.md`
- `.claude/ralph-desk/memos/node-rewrite-memory.md`
- `.claude/ralph-desk/context/node-rewrite-latest.md`
- `.claude/ralph-desk/memos/node-rewrite-done-claim.json`
- `.claude/ralph-desk/memos/node-rewrite-iter-signal.json`

## Verification Status
- RED full US-008 suite: `node --test tests/node/us008-cli-entrypoint.test.mjs` -> exit 1 because `src/node/run.mjs` did not exist, postinstall still copied zsh scripts, and unsupported-node fallback was missing
- GREEN full US-008 suite: `node --test tests/node/us008-cli-entrypoint.test.mjs` -> exit 0, 12/12 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs'); await import('./src/node/runner/campaign-main-loop.mjs'); await import('./src/node/reporting/campaign-reporting.mjs'); await import('./src/node/run.mjs');"` -> exit 0
- GREEN CLI help smoke: `node src/node/run.mjs --help` -> exit 0 and prints the current command surface plus all documented run flags
- GREEN pack/install smoke: `npm pack --json` + `npm install <tarball>` into a temp prefix/home -> exit 0, installed `~/.claude/ralph-desk/node/run.mjs` exists, legacy zsh runtime files are absent, and the installed CLI help includes `--autonomous`
