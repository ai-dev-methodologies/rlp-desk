# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 3 implemented US-002 only. The new Node module `src/node/cli/command-builder.mjs` now ports the zsh CLI string-building behavior needed for later runner stories: `buildClaudeCmd()`, `buildCodexCmd()`, and `parseModelFlag()`. `tests/node/us002-cli-command-builder.test.mjs` adds 15 node:test cases, giving every US-002 acceptance criterion happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-002 traceability rows and criteria mappings with the actual file path and test names.

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
  - Claude command building preserves the zsh launch contract: `DISABLE_OMC=1`, `--mcp-config '{"mcpServers":{}}'`, `--strict-mcp-config`, `--dangerously-skip-permissions`, and optional `--effort`
  - Codex command building preserves the zsh launch contract: `-m`, optional `-c model_reasoning_effort="..."`, `--disable plugins`, and `--dangerously-bypass-approvals-and-sandbox`
  - Unified model parsing preserves the existing zsh mapping rules: `haiku|sonnet|opus` stay on the Claude engine, `spark` expands to `gpt-5.3-codex-spark`, and malformed `a:b:c`-style values fail with an `invalid format` error
  - `tests/node/us002-cli-command-builder.test.mjs` provides 15 unit tests with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should check US-002 only.

**Criteria**:
- US-002 AC2.1: `buildClaudeCmd("tui", "opus", {effort:"max"})` starts with `DISABLE_OMC=1` and includes the expected Claude flags and effort
- US-002 AC2.2: `buildCodexCmd("tui", "gpt-5.4", {reasoning:"high"})` includes the expected Codex model, reasoning, plugin-disable, and bypass flags
- US-002 AC2.3: `parseModelFlag("opus:max", "worker")` returns `{engine:"claude", model:"opus", effort:"max"}`
- US-002 AC2.4: `parseModelFlag("spark:medium")` returns `{engine:"codex", model:"gpt-5.3-codex-spark", reasoning:"medium"}`
- US-002 AC2.5: malformed inputs such as `a:b:c` reject with an `invalid format` error

## Key Decisions
- Kept US-002 surgical: one new module under `src/node/cli/` with only the APIs required by the PRD.
- Matched the zsh runner strings exactly where the PRD requires flag parity instead of introducing argument-object abstractions prematurely.
- Treated empty Claude effort and undefined Codex reasoning as boundary cases so later callers can preserve legacy defaults without extra branching.
- Rejected unsupported builder modes now rather than adding unused print-mode behavior that the PRD does not require for US-002.

## Patterns Discovered
- The zsh source of truth already separates Claude and Codex launch strings cleanly, so the Node port can remain string-based without needing shell-escaping helpers yet.
- `spark` is the only alias that expands to a different Codex model identifier; the other colon-form values can pass through as-is.
- Lowercase `invalid format` text matters because the verifier and tests key off that phrase directly.
- A single unit-test file can satisfy the per-AC `>= 3 tests` rule cleanly when test names embed the US/AC IDs.

## Learnings
- US-002 does not need any tmux or subprocess execution to prove correctness; direct string and object assertions are enough because the PRD marks it as L1-only.
- The existing zsh `parse_model_flag()` behavior accepts empty effort/reasoning suffixes after the colon, so the Node port should preserve that boundary rather than tightening it prematurely.
- Constraining the Node module to `tui` mode avoids speculative work until a later story actually ports the print/trigger path.

## Evidence Chain
- RED full US-002 suite: `node --test tests/node/us002-cli-command-builder.test.mjs` -> exit 1 because `src/node/cli/command-builder.mjs` did not exist yet (`ERR_MODULE_NOT_FOUND`)
- GREEN full US-002 suite: `node --test tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 15/15 pass
- GREEN AC2.1 subset: `node --test --test-name-pattern "US-002 AC2.1" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.2 subset: `node --test --test-name-pattern "US-002 AC2.2" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.3 subset: `node --test --test-name-pattern "US-002 AC2.3" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.4 subset: `node --test --test-name-pattern "US-002 AC2.4" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN AC2.5 subset: `node --test --test-name-pattern "US-002 AC2.5" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 3/3 pass
- GREEN happy-path subset: `node --test --test-name-pattern "happy" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN boundary subset: `node --test --test-name-pattern "boundary" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN negative subset: `node --test --test-name-pattern "negative" tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 5/5 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs` -> exit 0, 33/33 pass
