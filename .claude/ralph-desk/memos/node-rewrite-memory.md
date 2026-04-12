# node-rewrite - Campaign Memory

## Stop Status
verify

## Objective
rlp-desk zsh to Node.js rewrite

## Current State
Iteration 8 implemented US-007 only. The Node rewrite now includes `src/node/reporting/campaign-reporting.mjs` for three reporting surfaces: `prepareCampaignAnalytics()` and `appendCampaignAnalytics()` manage per-iteration `campaign.jsonl` data with versioning and required-field validation; `generateCampaignReport()` versions and writes `campaign-report.md` with the required eight sections; and `readStatus()` renders the status-command view from `status.json`, including corrupt/missing-file handling. `src/node/runner/campaign-main-loop.mjs` now persists `started_at_utc` and `max_iterations`, versions an existing `campaign.jsonl` at fresh campaign start, appends one analytics record per completed worker iteration, and generates a campaign report on COMPLETE and BLOCKED terminal states. `tests/node/us007-analytics-reporting.test.mjs` adds 9 node:test cases so every US-007 acceptance criterion has happy, boundary, and negative coverage. `.claude/ralph-desk/plans/test-spec-node-rewrite.md` now contains concrete US-007 traceability rows, commands, and smoke coverage.

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

## Next Iteration Contract
Verifier should check US-007 only.

**Criteria**:
- US-007 AC7.1: a completed five-iteration campaign writes `campaign-report.md` with the eight required sections, including versioning of any previous report
- US-007 AC7.2: completed iterations append one valid JSON line per iteration to `campaign.jsonl`, and a fresh campaign versions an existing analytics file before writing new records
- US-007 AC7.3: the status reader displays iteration, phase, models, verified US, consecutive failures, and elapsed time, while handling missing or corrupt `status.json`

## Key Decisions
- Kept US-007 surgical by adding one reporting module instead of spreading analytics/report logic across multiple new subsystems.
- Stored `campaign.jsonl` and `campaign-report.md` under `logs/<slug>/` so the Node rewrite stays inside the project root and still preserves the required runtime artifacts.
- Logged one analytics record per completed worker iteration, not per final re-verification step, so iteration counts stay aligned with the worker loop.
- Extended `status.json` only with `started_at_utc` and `max_iterations`, which was enough to support elapsed-time rendering and reporting without changing the tmux orchestration model.

## Patterns Discovered
- The runner remains easier to reason about when reporting concerns are isolated behind small helper functions and the loop only calls them at iteration boundaries or terminal states.
- Versioning old runtime artifacts before writing new ones keeps retries and reruns testable without introducing destructive cleanup into the story scope.
- Reporting from `status.json`, PRD sections, analytics lines, and fix contracts is enough to satisfy the report contract without first porting the whole legacy archival pipeline.

## Learnings
- US-007 can stay unit-focused even though it touches the runner, as long as the report and analytics behaviors are exposed through deterministic helper functions.
- Adding reporting to the existing runner did not require changing the US-006 control flow beyond a few status and terminal hooks.
- The elapsed-time requirement is easiest to satisfy when status rendering compares `updated_at_utc` against a caller-provided clock.

## Evidence Chain
- RED full US-007 suite: `node --test tests/node/us007-analytics-reporting.test.mjs` -> exit 1 because `src/node/reporting/campaign-reporting.mjs` did not exist yet and the runner did not write `campaign.jsonl` or `campaign-report.md`
- GREEN full US-007 suite: `node --test tests/node/us007-analytics-reporting.test.mjs` -> exit 0, 9/9 pass
- GREEN adjacent runner regression suite: `node --test tests/node/us006-campaign-main-loop.test.mjs tests/node/us007-analytics-reporting.test.mjs` -> exit 0, 24/24 pass
- GREEN import smoke: `node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs'); await import('./src/node/runner/campaign-main-loop.mjs'); await import('./src/node/reporting/campaign-reporting.mjs');"` -> exit 0
