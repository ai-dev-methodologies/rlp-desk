# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 5 implemented US-004 only. The new Node module `src/node/prompts/prompt-assembler.mjs` adds `assembleWorkerPrompt()`, `assembleVerifierPrompt()`, and `FileNotFoundError` for the rewrite's prompt-assembly flow. The worker assembler now preserves the base prompt content, injects iteration context, fix-contract text, per-US scope locking, final-verification messaging, and autonomous-mode guidance while falling back to the full PRD/test-spec when per-US files are missing. The verifier assembler now appends scoped verification context for a single US or `ALL`, carries forward the previously verified stories note, and mirrors the autonomous conflict-resolution guidance. `tests/node/us004-prompt-assembler.test.mjs` adds 12 node:test cases so every US-004 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-004 traceability rows, criteria mappings, and verification commands.

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
- US-004: Prompt Assembler
  - `src/node/prompts/prompt-assembler.mjs` adds `assembleWorkerPrompt`, `assembleVerifierPrompt`, and `FileNotFoundError`
  - The worker assembler mirrors the zsh prompt protocol for iteration context, fix contracts, per-US scope locking, final verification messaging, and autonomous conflict guidance
  - The verifier assembler mirrors the zsh verification-context protocol for per-US and full-verify scopes, previously verified story notes, and autonomous conflict guidance
  - `tests/node/us004-prompt-assembler.test.mjs` provides 12 node:test cases with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should check US-004 only.

**Criteria**:
- US-004 AC4.1: `assembleWorkerPrompt()` preserves the base prompt and appends iteration context, fix-contract details, and per-US scope lock content with the correct US ID
- US-004 AC4.2: `assembleWorkerPrompt()` appends the AUTONOMOUS MODE section with PRD priority and conflict-log guidance when autonomous mode is enabled
- US-004 AC4.3: `assembleVerifierPrompt()` scopes verification to the requested US and notes already verified stories
- US-004 AC4.4: `assembleWorkerPrompt()` throws `FileNotFoundError` with the missing path when the worker prompt base file does not exist

## Key Decisions
- Kept US-004 surgical: one new module under `src/node/prompts/` with only the APIs required by the PRD.
- Matched the zsh prompt section wording closely instead of introducing a new prompt schema, so later runner work can swap implementations without rewriting the contract text.
- Treated per-US PRD replacement as a pure base-prompt content transform and handled per-US test-spec selection in the appended section, matching the current shell behavior.
- Used `FileNotFoundError` only for required base prompt files and left optional artifacts such as fix contracts and per-US split files as soft fallbacks.

## Patterns Discovered
- The worker and verifier prompt flows share the same structure: read a required base prompt first, then append deterministic context sections in a fixed order.
- Empty campaign-memory sections should degrade to explicit defaults (`unknown`, `Start from the beginning`) instead of omitting the section entirely.
- The per-US final-verify branch is distinct from the normal scope-lock branch and should suppress the PER-US SCOPE LOCK section once every listed US is already verified.
- The verifier prompt keeps previously verified stories as a comma-separated list, matching the shell runner's existing string format.

## Learnings
- Prompt assembly can stay independent from higher-level runner orchestration if the module accepts plain file paths and already-computed iteration state.
- Real-file fixture tests are enough to cover the output-assembly boundary cases without introducing template engines or mock-heavy infrastructure.
- Mirroring the shell text exactly where it matters keeps the Node rewrite low-risk because downstream workers and verifiers already rely on that wording.

## Evidence Chain
- RED full US-004 suite: `node --test tests/node/us004-prompt-assembler.test.mjs` -> exit 1 because `src/node/prompts/prompt-assembler.mjs` did not exist yet (`ERR_MODULE_NOT_FOUND`)
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
