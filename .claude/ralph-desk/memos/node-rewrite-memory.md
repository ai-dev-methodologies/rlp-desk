# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 10 performed the final ALL-verification pass for the completed Node rewrite. No product code changed in this iteration. Fresh verification confirmed that the Node runtime imports cleanly, the full node:test suite passes across US-00 through US-008, the CLI help still exposes the documented command surface and run flags, and a real `npm pack` plus isolated `npm install` cycle installs `~/.claude/ralph-desk/node/run.mjs` without shipping or restoring the legacy zsh runtime files.

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
- US-007: Analytics and Reporting
  - `src/node/reporting/campaign-reporting.mjs` adds `prepareCampaignAnalytics`, `appendCampaignAnalytics`, `generateCampaignReport`, and `readStatus`
  - The reporting module versions prior `campaign.jsonl` and `campaign-report.md` files, writes one analytics record per completed iteration, renders the required eight campaign-report sections, and formats status output from `status.json`
  - `src/node/runner/campaign-main-loop.mjs` now connects analytics/report generation to the tmux loop without expanding story scope beyond reporting
  - `tests/node/us007-analytics-reporting.test.mjs` provides 9 node:test cases with 3 tests per AC across happy, boundary, and negative coverage
- US-008: CLI Entry Point and npm Integration
  - `src/node/run.mjs` adds the Node CLI entry point with top-level help, `run` flag parsing, and `init`/`status` command wiring
  - `scripts/postinstall.js` installs the Node runtime under `~/.claude/ralph-desk/node`, removes legacy zsh runtime files on supported Node versions, and preserves existing zsh installs when Node.js is unsupported or malformed
  - `scripts/uninstall.js` removes the installed Node runtime tree, and `package.json` excludes legacy zsh runtime files from the published artifact
  - `tests/node/us008-cli-entrypoint.test.mjs` provides 12 node:test cases with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should run final ALL verification for US-00 through US-008 using the fresh iteration-10 evidence artifacts.

**Criteria**:
- Build smoke: the full Node runtime imports successfully
- Full suite: `node --test` passes for `tests/node/us00-bootstrap.test.mjs` through `tests/node/us008-cli-entrypoint.test.mjs`
- CLI help: `node src/node/run.mjs --help` prints the current command surface and run flags
- Packaging/install smoke: `npm pack --json` plus isolated `npm install` produces `~/.claude/ralph-desk/node/run.mjs` with no legacy zsh runtime files installed

## Key Decisions
- Treated iteration 10 as a verification-only pass because the implementation stories were already complete and individually verified.
- Followed the worker prompt's explicit final-verification block after logging the scope conflict with the stale US-008-only iteration context.
- Regenerated the memo-level `done-claim` and `iter-signal` artifacts that had been deleted from the worktree, using only fresh verification evidence.

## Patterns Discovered
- The full node:test suite remains a reliable regression gate because it exercises both pure modules and real `tmux`/filesystem/install flows.
- The isolated `npm pack` plus temp-home install smoke is still the fastest way to detect packaging regressions that unit tests alone would miss.
- CLI help output is a stable contract surface for verifying that the Node entry point still advertises the expected top-level commands and run flags.

## Learnings
- Final verification can be run without reopening implementation scope as long as the artifacts capture fresh evidence and clearly distinguish verification-only iterations from coding iterations.
- Memo-level orchestration files are easy to lose in a dirty tree, so regenerating them from logged evidence is safer than relying on previous working-copy state.
- Logging prompt conflicts in `conflict-log.jsonl` preserves the audit trail when the iteration contract and final verification block diverge.

## Evidence Chain
- GREEN build smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs'); await import('./src/node/runner/campaign-main-loop.mjs'); await import('./src/node/reporting/campaign-reporting.mjs'); await import('./src/node/run.mjs');"` -> exit 0
- GREEN full suite: `node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs tests/node/us005-campaign-initializer.test.mjs tests/node/us006-campaign-main-loop.test.mjs tests/node/us007-analytics-reporting.test.mjs tests/node/us008-cli-entrypoint.test.mjs` -> exit 0, 105/105 pass
- GREEN CLI help smoke: `node src/node/run.mjs --help` -> exit 0 and prints the current command surface plus all documented run flags
- GREEN pack/install smoke: `npm pack --json` + isolated `npm install <tarball>` -> exit 0, installed `~/.claude/ralph-desk/node/run.mjs` exists, no legacy zsh runtime files are installed, and the installed CLI help includes `--autonomous`
