# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 6 implemented US-005 only. The new Node module `src/node/init/campaign-initializer.mjs` adds `initCampaign()` and `init()` for the rewrite's scaffold-creation flow. The initializer now creates the desk directories and base files, normalizes special-character slugs for stable filenames, updates `.gitignore` without duplicating the rlp-desk rule, splits PRDs on `## US-NNN:` markers while preserving the objective header, supports `mode="fresh"` by recreating the desk scaffold from scratch, and rejects `mode="tmux"` when no tmux session marker is present. `tests/node/us005-campaign-initializer.test.mjs` adds 12 node:test cases so every US-005 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-005 traceability rows, criteria mappings, and verification commands.

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

## Next Iteration Contract
Verifier should check US-005 only.

**Criteria**:
- US-005 AC5.1: `initCampaign()` creates the scaffold directories and expected base files for the campaign
- US-005 AC5.2: `initCampaign()` splits a PRD on `## US-NNN:` markers into per-US files that preserve the objective header and isolate section content
- US-005 AC5.3: `initCampaign()` with `mode="fresh"` deletes stale initializer artifacts and recreates the PRD from scratch
- US-005 AC5.4: `initCampaign()` rejects `mode="tmux"` without a tmux session and leaves no scaffold behind

## Key Decisions
- Kept US-005 surgical: one new module under `src/node/init/` with only the APIs required by the PRD.
- Used a line-based PRD splitter instead of porting the shell `awk` logic so the Node behavior stays deterministic and easy to test.
- Scoped tmux prerequisite handling to the session-marker check required by the PRD instead of introducing broader runtime validation.
- Limited initializer behavior to scaffold creation, PRD splitting, fresh cleanup, and `.gitignore` maintenance; test-spec splitting and settings-file mutation remain out of scope for this story.

## Patterns Discovered
- The Node rewrite can keep each story self-contained by mirroring only the shell behavior demanded by the current AC, not the entire shell script at once.
- Fresh re-init is simplest and safest when the desk root is removed wholesale and then regenerated from the current inputs.
- Boundary coverage for initializer work is most reliable when the tests exercise real temporary filesystem trees rather than mocks.
- A stable slug-normalization step keeps file naming predictable across prompt, memo, plan, and log paths.

## Learnings
- A small Node initializer is enough to cover the story without pulling in the higher-level runner orchestration or CLI layers prematurely.
- `.gitignore` handling is easiest to verify by enforcing the marker and rule as an idempotent block append.
- Splitting PRDs while preserving the shared objective header is easier to reason about with line parsing than regex-only extraction.

## Evidence Chain
- RED full US-005 suite: `node --test tests/node/us005-campaign-initializer.test.mjs` -> exit 1 because `src/node/init/campaign-initializer.mjs` did not exist yet (`ERR_MODULE_NOT_FOUND`)
- GREEN AC5.1 subset: `node --test --test-name-pattern "US-005 AC5.1" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 3/3 pass
- GREEN AC5.2 subset: `node --test --test-name-pattern "US-005 AC5.2" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 3/3 pass
- GREEN AC5.3 subset: `node --test --test-name-pattern "US-005 AC5.3" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 3/3 pass
- GREEN AC5.4 subset: `node --test --test-name-pattern "US-005 AC5.4" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 3/3 pass
- GREEN L3 happy subset: `node --test --test-name-pattern "US-005 AC5.1 happy|US-005 AC5.2 happy|US-005 AC5.3 happy|US-005 AC5.4 happy" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 4/4 pass
- GREEN L3 boundary subset: `node --test --test-name-pattern "US-005 AC5.1 boundary|US-005 AC5.2 boundary|US-005 AC5.3 boundary|US-005 AC5.4 boundary" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 4/4 pass
- GREEN L3 error subset: `node --test --test-name-pattern "US-005 AC5.1 negative|US-005 AC5.2 negative|US-005 AC5.3 negative|US-005 AC5.4 negative" tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 4/4 pass
- GREEN full US-005 suite: `node --test tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 12/12 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs');"` -> exit 0
- GREEN combined Node suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs tests/node/us005-campaign-initializer.test.mjs` -> exit 0, 69/69 pass
