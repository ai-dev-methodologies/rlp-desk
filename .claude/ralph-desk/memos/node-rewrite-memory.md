# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 7 implemented US-006 only. The new Node module `src/node/runner/campaign-main-loop.mjs` adds `run()` and `initAndRun()` for the rewrite's tmux-mode leader loop. The runner now validates scaffold prerequisites, creates leader/worker/verifier panes, assembles and writes worker/verifier prompts into the campaign log, launches worker and verifier commands with the existing CLI builders, persists runtime status under `logs/<slug>/runtime/status.json`, falls back to current-US verification when a codex worker times out before writing a signal, escalates worker models after repeated failures, performs final sequential per-US re-verification followed by the integration check, and blocks restarts when a BLOCKED sentinel already exists. `tests/node/us006-campaign-main-loop.test.mjs` adds 15 node:test cases so every US-006 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-006 traceability rows, verification mappings, and updated smoke commands.

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
- US-005: Campaign Initializer
  - `src/node/init/campaign-initializer.mjs` adds `initCampaign` and `init`
  - The initializer creates the desk scaffold, preserves existing `.gitignore` rules without duplication, splits PRDs into per-US files with the objective header, supports fresh re-init cleanup, and rejects tmux mode outside a tmux session
  - `tests/node/us005-campaign-initializer.test.mjs` provides 12 node:test cases with 3 tests per AC across happy, boundary, and negative coverage
- US-006: Campaign Main Loop
  - `src/node/runner/campaign-main-loop.mjs` adds `run` and `initAndRun`
  - The runner validates scaffold prerequisites, creates tmux panes, dispatches worker/verifier commands with scoped prompts, persists runtime status, retries codex signal gaps with current-US fallback, escalates worker models after repeated failures, performs final sequential verify plus integration, and blocks restart when a BLOCKED sentinel exists
  - `tests/node/us006-campaign-main-loop.test.mjs` provides 15 node:test cases with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should check US-006 only.

**Criteria**:
- US-006 AC6.1: `run("test-slug", {mode:"tmux", workerModel:"gpt-5.4:medium"})` creates tmux leader/worker/verifier panes, launches the worker with the correct model flags, and writes `status.json` with iteration 1 in worker phase
- US-006 AC6.2: worker verify signals scope the verifier to the completed US and failed verdicts produce a fix contract for the next retry of that same US
- US-006 AC6.3: three consecutive failures on the same US upgrade `gpt-5.4:medium` to `gpt-5.4:high`, continued failures escalate through `xhigh`, and the campaign blocks after exhausting upgrades
- US-006 AC6.4: after all per-US verifications pass, the runner re-verifies each US sequentially, runs the integration check, and writes COMPLETE only after every step passes
- US-006 AC6.5: an existing BLOCKED sentinel prevents startup and tells the user to run clean first

## Key Decisions
- Kept US-006 surgical: one new module under `src/node/runner/` that orchestrates the already-implemented Node primitives instead of porting the full shell leader in one pass.
- Used dependency injection for tmux, polling, and integration hooks so the runner can cover L1, L2, L3, and L4 scenarios without adding test-only branches to production code.
- Scoped model escalation to the PRD-required codex upgrade path (`medium -> high -> xhigh -> BLOCKED`) and left broader governance heuristics out of this story.
- Implemented final verification as sequential per-US verifier dispatch plus one integration hook, matching the timeout-avoidance behavior described in the protocol docs.

## Patterns Discovered
- The runner stays manageable when the prompt-writing, launch-command building, and state persistence each remain separate, single-purpose steps inside the loop.
- Reusing the existing prompt assembler and command builder modules keeps the tmux loop consistent with earlier stories and reduces new surface area.
- A codex timeout fallback is safest when it stays narrowly scoped to "verify the current US" instead of inventing broader recovery logic.
- Final sequential verify is easiest to test when its verifier prompts are written to dedicated `final-US-XXX.verifier-prompt.md` files.

## Learnings
- The current Node rewrite can express the shell leader loop with a compact state machine if the story scope stays limited to tmux mode and per-US verification.
- Real tmux coverage for pane creation can coexist with fake command dispatch, which keeps the L3 check meaningful without requiring real codex/claude CLI execution.
- Capturing status transitions through one persisted `status.json` is enough to support the PRD's resume boundary case for this story.

## Evidence Chain
- RED full US-006 suite: `node --test tests/node/us006-campaign-main-loop.test.mjs` -> exit 1 because `src/node/runner/campaign-main-loop.mjs` did not exist yet (`ERR_MODULE_NOT_FOUND`)
- GREEN AC6.1 subset: `node --test --test-name-pattern "US-006 AC6.1" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 3/3 pass
- GREEN AC6.2 subset: `node --test --test-name-pattern "US-006 AC6.2" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 3/3 pass
- GREEN AC6.3 subset: `node --test --test-name-pattern "US-006 AC6.3" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 3/3 pass
- GREEN AC6.4 subset: `node --test --test-name-pattern "US-006 AC6.4" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 3/3 pass
- GREEN AC6.5 subset: `node --test --test-name-pattern "US-006 AC6.5" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 3/3 pass
- GREEN L3/L2 happy subset: `node --test --test-name-pattern "US-006 AC6.1 happy|US-006 AC6.2 happy|US-006 AC6.3 happy|US-006 AC6.4 happy|US-006 AC6.5 negative" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 5/5 pass
- GREEN boundary subset: `node --test --test-name-pattern "US-006 AC6.1 boundary|US-006 AC6.2 boundary|US-006 AC6.3 boundary|US-006 AC6.4 boundary|US-006 AC6.5 boundary" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 5/5 pass
- GREEN error subset: `node --test --test-name-pattern "US-006 AC6.1 negative|US-006 AC6.2 negative|US-006 AC6.3 negative|US-006 AC6.4 negative|US-006 AC6.5 happy" tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 5/5 pass
- GREEN full US-006 suite: `node --test tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 15/15 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs'); await import('./src/node/runner/campaign-main-loop.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs tests/node/us005-campaign-initializer.test.mjs tests/node/us006-campaign-main-loop.test.mjs` -> exit 0, 84/84 pass
