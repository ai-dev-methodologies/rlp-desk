# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 9 implemented US-008 only. The rewrite now has a Node CLI entry point at `src/node/run.mjs` that exposes the current top-level command surface, parses the documented `run` flags, wires `init`/`status` to the existing Node modules, and exits cleanly for unsupported commands. `scripts/postinstall.js` now installs the Node runtime under `~/.claude/ralph-desk/node`, copies the command/docs payload, removes the legacy zsh runtime files, and falls back safely when Node.js is older than 16 or malformed. `scripts/uninstall.js` now removes the installed Node runtime tree during npm uninstall cleanup. `package.json` now publishes only the Node runtime sources plus the command/docs payload, so the packed artifact no longer distributes `src/scripts/*.zsh`. `tests/node/us008-cli-entrypoint.test.mjs` adds 12 node:test cases so every US-008 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-008 traceability rows, smoke commands, and verification mapping.

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
  - `scripts/postinstall.js` now installs the Node runtime under `~/.claude/ralph-desk/node`, removes legacy zsh runtime files, and preserves existing zsh installs when Node.js is unsupported
  - `scripts/uninstall.js` removes the installed Node runtime tree, and `package.json` now excludes legacy zsh runtime files from the published artifact
  - `tests/node/us008-cli-entrypoint.test.mjs` provides 12 node:test cases with 3 tests per AC across happy, boundary, and negative coverage

## Next Iteration Contract
Verifier should check US-008 only.

**Criteria**:
- US-008 AC8.1: npm postinstall installs the Node runtime under `~/.claude/ralph-desk` and replaces the old zsh runtime files
- US-008 AC8.2: the Node CLI parses `/rlp-desk run` flags correctly and launches the campaign with the expected configuration
- US-008 AC8.3: `node src/node/run.mjs --help` shows the current CLI command surface with no missing run flags
- US-008 AC8.4: unsupported Node.js versions fail gracefully during postinstall without corrupting an existing zsh installation

## Key Decisions
- Kept US-008 surgical by adding a single Node CLI entry point instead of trying to rewrite the slash-command markdown protocol in the same iteration.
- Installed the runtime under `~/.claude/ralph-desk/node` so copied modules keep their relative imports intact and the package can remove the legacy shell runtime entirely.
- Per the PRD boundary cases, the installer removes stale mixed-install state on supported Node versions but refuses to touch the existing zsh runtime on unsupported versions.
- Narrowed the `package.json` publish list to `src/node`, `src/commands`, and the supporting docs so `npm pack` no longer ships the old zsh scripts.

## Patterns Discovered
- A basename-based direct-entry check in `run.mjs` is more reliable than comparing raw `import.meta.url` strings once the runtime is copied outside the repo.
- The CLI can stay minimal if it forwards only the current `run` defaults and documented flags while leaving unsupported commands explicit instead of silently no-oping.
- Real `npm pack` verification catches packaging/runtime issues that unit tests miss, especially around installed-path execution.

## Learnings
- Installing a copied ESM runtime is straightforward as long as the copied directory structure mirrors the repo tree under `src/node`.
- The unsupported-Node safeguard belongs at the top of `postinstall.js`; once copy/remove work starts, preserving the legacy runtime becomes much harder.
- Packaging scope matters as much as install logic here because the PRD explicitly treats shipping legacy zsh files as a regression.

## Evidence Chain
- RED full US-008 suite: `node --test tests/node/us008-cli-entrypoint.test.mjs` -> exit 1 because `src/node/run.mjs` did not exist, postinstall still copied zsh scripts, and unsupported-node fallback was missing
- GREEN full US-008 suite: `node --test tests/node/us008-cli-entrypoint.test.mjs` -> exit 0, 12/12 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs'); await import('./src/node/runner/campaign-main-loop.mjs'); await import('./src/node/reporting/campaign-reporting.mjs'); await import('./src/node/run.mjs');"` -> exit 0
- GREEN CLI help smoke: `node src/node/run.mjs --help` -> exit 0 and prints the current command surface plus all documented run flags
- GREEN pack/install smoke: `npm pack --json` + `npm install <tarball>` into a temp prefix/home -> exit 0, installed `~/.claude/ralph-desk/node/run.mjs` exists, legacy zsh runtime files are absent, and the installed CLI help includes `--autonomous`
