# Test Specification: node-rewrite

## Iron Law Reference
> IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
> IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3

---

## Verification Commands
### Build
```bash
node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs'); await import('./src/node/polling/signal-poller.mjs'); await import('./src/node/prompts/prompt-assembler.mjs'); await import('./src/node/init/campaign-initializer.mjs');"
```
### Test
```bash
node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs tests/node/us005-campaign-initializer.test.mjs
```
### Lint
```bash
N/A — no lint configuration exists in this repository yet
```

---

## Verification Context (fill BEFORE implementation)

### Target Behavior
What behavior does this project change or introduce?
- Introduce the initial Node rewrite bootstrap primitives needed by later stories: safe project-root path resolution and atomic file writes under `src/node/shared/`.
- Introduce a Node-native tmux pane manager under `src/node/tmux/` that can create panes, send commands, and wait for interactive pane processes to return to the shell.
- Introduce Node-native CLI command builders and unified model-flag parsing under `src/node/cli/` so later runner stories can reuse the zsh-compatible launch strings.
- Introduce a Node-native signal and verdict poller under `src/node/polling/` that waits for valid JSON artifacts, enforces timeouts, and applies Codex-specific two-phase pane-exit polling.
- Introduce a Node-native prompt assembler under `src/node/prompts/` that appends iteration and verification context sections onto worker and verifier prompt base files.
- Introduce a Node-native campaign initializer under `src/node/init/` that scaffolds the desk files, splits PRDs into per-US files, supports fresh re-init, and blocks tmux mode outside tmux sessions.

### Impacted Tests
Existing tests that may break due to this change:
- None identified. This iteration adds the first Node-native tests alongside the existing zsh test suites.
- No existing Node tmux tests existed. US-001 adds a new real-`tmux` test file.
- No existing Node command-builder tests existed. US-002 adds a new unit-only command-builder test file.
- No existing Node poller tests existed. US-003 adds a mixed unit/L3 real-file polling test file.
- No existing Node prompt-assembler tests existed. US-004 adds a mixed unit/L3 output-content test file.
- No existing Node campaign-initializer tests existed. US-005 adds a mixed unit/L3 filesystem scaffold test file.

### Required New Tests
Tests that MUST be written (minimum 3 per AC: happy + negative + boundary):
- `tests/node/us00-bootstrap.test.mjs`
- AC1: `resolveProjectPath` happy + boundary + negative
- AC2: `writeFileAtomic` happy + boundary + negative
- `tests/node/us001-tmux-pane-manager.test.mjs`
- AC1.1: `createPane` happy + boundary + negative
- AC1.2: `sendKeys` happy + boundary + negative
- AC1.3: `waitForProcessExit` happy + boundary + negative
- AC1.4: invalid pane `sendKeys` error handling happy + boundary + negative
- `tests/node/us002-cli-command-builder.test.mjs`
- AC2.1: `buildClaudeCmd` happy + boundary + negative
- AC2.2: `buildCodexCmd` happy + boundary + negative
- AC2.3: `parseModelFlag` claude parsing happy + boundary + negative
- AC2.4: `parseModelFlag` codex parsing happy + boundary + negative
- AC2.5: `parseModelFlag` invalid-format rejection happy + boundary + negative
- `tests/node/us003-signal-poller.test.mjs`
- AC3.1: `pollForSignal` file-appearance polling happy + boundary + negative
- AC3.2: `pollForSignal` codex two-phase polling happy + boundary + negative
- AC3.3: `pollForSignal` timeout handling happy + boundary + negative
- AC3.4: `pollForSignal` invalid-JSON retry happy + boundary + negative
- `tests/node/us004-prompt-assembler.test.mjs`
- AC4.1: `assembleWorkerPrompt` base prompt + iteration context + per-US scope happy + boundary + negative
- AC4.2: `assembleWorkerPrompt` autonomous-mode injection happy + boundary + negative
- AC4.3: `assembleVerifierPrompt` scoped verification context happy + boundary + negative
- AC4.4: `assembleWorkerPrompt` missing base file happy + boundary + negative
- `tests/node/us005-campaign-initializer.test.mjs`
- AC5.1: `initCampaign` scaffold creation happy + boundary + negative
- AC5.2: `initCampaign` PRD splitting happy + boundary + negative
- AC5.3: `initCampaign` fresh re-init happy + boundary + negative
- AC5.4: `initCampaign` tmux prerequisite handling happy + boundary + negative

### Forbidden Shortcuts (see Worker prompt for full list)
- Do not mock external services when L2 integration test is required
- Do not delete or weaken existing assertions to make tests pass
- Do not add test-specific logic (if __name__ == '__test__' patterns)
- Do not skip boundary cases listed in the PRD
- Do not claim "code inspection" as verification — run the actual command
- Do not say "too simple to test" — simple code breaks
- Do not say "I'll test after" — tests passing immediately prove nothing
- Do not say "already manually tested" — ad-hoc is not systematic
- Do not say "partial check is enough" — partial proves nothing
- Do not say "I'm confident" — confidence is not evidence
- Do not say "existing code has no tests" — you are improving it, add tests
- Do not write code before tests — delete it and start with tests

### Pass/Fail Evidence Format
- Command output with exit code 0
- Quantitative result matching expected value
- Screenshot comparison (for visual tasks)

---

## Verification Layers (ALL required sections — TODO in required layer = Verifier FAIL)

### L1: Unit Test (REQUIRED)
```bash
node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs tests/node/us003-signal-poller.test.mjs tests/node/us004-prompt-assembler.test.mjs
```

### L2: Integration (required if external services exist, otherwise "N/A — reason")
```bash
N/A — no external services in US-00 bootstrap primitives, US-001 tmux pane tests use the local CLI directly, and US-002 is unit-only per the PRD
```

### L3: E2E Simulation (REQUIRED)
Known input → full pipeline → quantitative output comparison.
Must cover ALL AC types: happy path + boundary + error path.
- **Happy path input**: `resolveProjectPath('src', 'scripts', 'run_ralph_desk.zsh')` and `writeFileAtomic('.tmp/us00-bootstrap-tests/nested/artifact.txt', 'first-pass')`
- **Happy path expected output**: absolute repo path returned; file created with exact content `first-pass`
- **Happy path command**:
```bash
node --test --test-name-pattern "happy" tests/node/us00-bootstrap.test.mjs
```
- **Error path input**: `resolveProjectPath('..')` and `writeFileAtomic(<outside-project>, 'blocked')`
- **Error path expected**: error message includes `outside the project root`
- **Error path command**:
```bash
node --test --test-name-pattern "negative|boundary" tests/node/us00-bootstrap.test.mjs
```
- **US-001 happy path input**: create a real detached tmux session, split a pane, send `printf`, and wait for `sleep 1` to return to the shell
- **US-001 happy path expected output**: pane ID is listed by `tmux list-panes`; capture output includes the sent marker; `waitForProcessExit` resolves after the pane command returns to `zsh`
- **US-001 happy path command**:
```bash
node --test --test-name-pattern "happy" tests/node/us001-tmux-pane-manager.test.mjs
```
- **US-001 boundary input**: vertical pane split, quoted command payload, and waiting on an already-idle shell pane
- **US-001 boundary expected**: vertical split succeeds; output preserves spaces; idle shell resolves immediately
- **US-001 boundary command**:
```bash
node --test --test-name-pattern "boundary" tests/node/us001-tmux-pane-manager.test.mjs
```
- **US-001 error path input**: invalid layout, invalid pane IDs, and a pane that is still running `sleep 2`
- **US-001 error path expected**: `TmuxError` includes pane ID or layout detail; `waitForProcessExit` remains pending while `pane_current_command` is `sleep`
- **US-001 error path command**:
```bash
node --test --test-name-pattern "negative" tests/node/us001-tmux-pane-manager.test.mjs
```
- **US-002 L3 status**:
```bash
N/A — PRD marks US-002 as L1-only unit coverage
```
- **US-003 happy path input**: poll a missing signal file, then write a valid JSON verdict before timeout
- **US-003 happy path expected output**: parsed JSON object resolves after the file appears
- **US-003 happy path command**:
```bash
node --test --test-name-pattern "US-003 AC3.1 boundary|US-003 AC3.4 boundary" tests/node/us003-signal-poller.test.mjs
```
- **US-003 boundary input**: codex mode sees a valid verdict file while the pane is still running, or a partially written JSON file that becomes valid later
- **US-003 boundary expected**: codex mode waits for the pane to return to shell; partial JSON is ignored until valid JSON lands
- **US-003 boundary command**:
```bash
node --test --test-name-pattern "US-003 AC3.2 boundary|US-003 AC3.4 boundary" tests/node/us003-signal-poller.test.mjs
```
- **US-003 error path input**: no valid JSON appears before timeout, or codex never returns to shell after the file appears
- **US-003 error path expected**: `TimeoutError` is thrown without hanging indefinitely
- **US-003 error path command**:
```bash
node --test --test-name-pattern "US-003 AC3.3" tests/node/us003-signal-poller.test.mjs
```
- **US-004 happy path input**: assemble a worker prompt from a real base file with iteration context, a fix-contract, and per-US test-spec paths
- **US-004 happy path expected output**: output preserves the base prompt text and appends the fix-contract and per-US scope lock for `US-004`
- **US-004 happy path command**:
```bash
node --test --test-name-pattern "US-004 AC4.1 happy|US-004 AC4.2 happy|US-004 AC4.3 happy" tests/node/us004-prompt-assembler.test.mjs
```
- **US-004 boundary input**: assemble prompts with empty memory, missing per-US PRD/test-spec files, `usId="ALL"`, and custom conflict-log paths
- **US-004 boundary expected**: worker prompt falls back to the full PRD/test-spec, verifier prompt switches to full-verify scope, and autonomous mode uses the provided conflict-log path
- **US-004 boundary command**:
```bash
node --test --test-name-pattern "US-004 AC4.1 boundary|US-004 AC4.2 boundary|US-004 AC4.3 boundary|US-004 AC4.4 boundary" tests/node/us004-prompt-assembler.test.mjs
```
- **US-004 error path input**: missing worker prompt base file or disabled optional sections
- **US-004 error path expected**: `FileNotFoundError` includes the missing prompt path and autonomous/verified-US sections are omitted when disabled
- **US-004 error path command**:
```bash
node --test --test-name-pattern "US-004 AC4.1 negative|US-004 AC4.2 negative|US-004 AC4.3 negative|US-004 AC4.4 happy|US-004 AC4.4 negative" tests/node/us004-prompt-assembler.test.mjs
```
- **US-005 happy path input**: initialize a fresh campaign root with a slug, objective, and a PRD containing three `## US-NNN:` sections
- **US-005 happy path expected output**: scaffold directories exist, base prompt/memo/plan files are created, and three per-US PRD files are written
- **US-005 happy path command**:
```bash
node --test --test-name-pattern "US-005 AC5.1 happy|US-005 AC5.2 happy|US-005 AC5.3 happy|US-005 AC5.4 happy" tests/node/us005-campaign-initializer.test.mjs
```
- **US-005 boundary input**: initialize with a special-character slug, an existing `.gitignore`, a PRD that must preserve the objective header in split files, `mode=\"fresh\"`, and `mode=\"tmux\"` with a tmux marker
- **US-005 boundary expected**: slug sanitizes to stable filenames, `.gitignore` rules are not duplicated, split PRDs preserve only their own section plus the objective header, stale split files are removed on fresh re-init, and tmux mode succeeds when a tmux marker is present
- **US-005 boundary command**:
```bash
node --test --test-name-pattern "US-005 AC5.1 boundary|US-005 AC5.2 boundary|US-005 AC5.3 boundary|US-005 AC5.4 boundary" tests/node/us005-campaign-initializer.test.mjs
```
- **US-005 error path input**: initialize against a partial scaffold, a PRD with invalid `### US-NNN:` markers, `mode=\"fresh\"` without an existing PRD, and `mode=\"tmux\"` without a tmux session
- **US-005 error path expected**: missing scaffold files are filled in, invalid PRD markers produce no per-US files, fresh mode recreates the PRD from scratch, and tmux mode rejects with `tmux required` without creating any scaffold
- **US-005 error path command**:
```bash
node --test --test-name-pattern "US-005 AC5.1 negative|US-005 AC5.2 negative|US-005 AC5.3 negative|US-005 AC5.4 negative" tests/node/us005-campaign-initializer.test.mjs
```

### L4: Deploy Verification (required if deploying, otherwise "N/A — reason")
```bash
N/A — no deployment in this iteration
```

---

## Mutation Testing Gate (CRITICAL risk only)
- Required: only for CRITICAL risk classification (governance §1c)
- Tool: N/A — not CRITICAL risk
- Target: >= 60% mutation score on core business logic (project default; override in PRD if justified)
- Scope: core business logic files (not config/tests/docs)
- Command:
```bash
N/A — not CRITICAL risk
```

---

## Test Quality Checklist (Verifier checks these)
- [ ] Tests verify behavior, not implementation details
- [ ] Each test has meaningful assertions (not just "no error thrown")
- [ ] Boundary cases covered (empty, max, zero, null, concurrent)
- [ ] No tautological tests (expected value copied from implementation)
- [ ] Mock usage limited to external boundaries only
- [ ] No test-specific logic in production code
- [ ] Each AC has >= 3 tests (happy + negative + boundary) per IL-4

## Traceability Matrix (Worker fills during implementation)

| US | AC | Test File :: Function | Layer | Evidence | Status |
|----|----|----------------------|-------|----------|--------|
| US-00 | AC1 | tests/node/us00-bootstrap.test.mjs :: US-00 AC1 happy: resolveProjectPath returns an absolute path inside the repo | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC1 happy" | complete |
| US-00 | AC1 | tests/node/us00-bootstrap.test.mjs :: US-00 AC1 boundary: resolveProjectPath with no segments returns the repo root | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC1 boundary" | complete |
| US-00 | AC1 | tests/node/us00-bootstrap.test.mjs :: US-00 AC1 negative: resolveProjectPath rejects traversal outside the repo root | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC1 negative" | complete |
| US-00 | AC2 | tests/node/us00-bootstrap.test.mjs :: US-00 AC2 happy: writeFileAtomic creates a new file under the repo root | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC2 happy" | complete |
| US-00 | AC2 | tests/node/us00-bootstrap.test.mjs :: US-00 AC2 boundary: writeFileAtomic overwrites existing content and leaves no tmp file behind | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC2 boundary" | complete |
| US-00 | AC2 | tests/node/us00-bootstrap.test.mjs :: US-00 AC2 negative: writeFileAtomic rejects writes outside the repo root | L1 | node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "US-00 AC2 negative" | complete |
| US-001 | AC1.1 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.1 happy: createPane creates a horizontal split and returns a pane id listed by tmux | L1 | node --test --test-name-pattern "US-001 AC1.1 happy" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.1 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.1 boundary: createPane supports vertical layout splits | L1 | node --test --test-name-pattern "US-001 AC1.1 boundary" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.1 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.1 negative: createPane rejects an invalid layout | L1 | node --test --test-name-pattern "US-001 AC1.1 negative" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.2 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.2 happy: sendKeys sends a command that appears in pane output within 2 seconds | L1 | node --test --test-name-pattern "US-001 AC1.2 happy" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.2 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.2 boundary: sendKeys preserves shell quoting in the pane output | L1 | node --test --test-name-pattern "US-001 AC1.2 boundary" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.2 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.2 negative: sendKeys rejects an invalid pane id instead of silently failing | L1 | node --test --test-name-pattern "US-001 AC1.2 negative" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.3 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.3 happy: waitForProcessExit resolves after a running process returns to the shell | L1 | node --test --test-name-pattern "US-001 AC1.3 happy" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.3 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.3 boundary: waitForProcessExit resolves immediately when the pane is already at the shell prompt | L1 | node --test --test-name-pattern "US-001 AC1.3 boundary" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.3 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.3 negative: waitForProcessExit does not resolve while the pane process is still running | L1 | node --test --test-name-pattern "US-001 AC1.3 negative" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.4 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.4 happy: sendKeys throws TmuxError for an invalid pane id | L1 | node --test --test-name-pattern "US-001 AC1.4 happy" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.4 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.4 boundary: sendKeys includes the invalid pane id in the TmuxError message | L1 | node --test --test-name-pattern "US-001 AC1.4 boundary" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-001 | AC1.4 | tests/node/us001-tmux-pane-manager.test.mjs :: US-001 AC1.4 negative: sendKeys surfaces tmux pane lookup failures as rejected promises | L1 | node --test --test-name-pattern "US-001 AC1.4 negative" tests/node/us001-tmux-pane-manager.test.mjs | complete |
| US-002 | AC2.1 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.1 happy: buildClaudeCmd tui includes claude flags and effort | L1 | node --test --test-name-pattern "US-002 AC2.1 happy" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.1 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.1 boundary: buildClaudeCmd omits effort when it is empty | L1 | node --test --test-name-pattern "US-002 AC2.1 boundary" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.1 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.1 negative: buildClaudeCmd rejects unsupported modes | L1 | node --test --test-name-pattern "US-002 AC2.1 negative" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.2 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.2 happy: buildCodexCmd tui includes codex model and reasoning flags | L1 | node --test --test-name-pattern "US-002 AC2.2 happy" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.2 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.2 boundary: buildCodexCmd omits reasoning when it is undefined | L1 | node --test --test-name-pattern "US-002 AC2.2 boundary" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.2 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.2 negative: buildCodexCmd rejects unsupported modes | L1 | node --test --test-name-pattern "US-002 AC2.2 negative" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.3 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.3 happy: parseModelFlag returns claude engine and effort for opus:max | L1 | node --test --test-name-pattern "US-002 AC2.3 happy" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.3 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.3 boundary: parseModelFlag keeps an empty effort for claude model values | L1 | node --test --test-name-pattern "US-002 AC2.3 boundary" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.3 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.3 negative: parseModelFlag rejects an empty model before the colon | L1 | node --test --test-name-pattern "US-002 AC2.3 negative" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.4 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.4 happy: parseModelFlag maps spark:medium to codex spark defaults | L1 | node --test --test-name-pattern "US-002 AC2.4 happy" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.4 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.4 boundary: parseModelFlag keeps an empty reasoning for codex values | L1 | node --test --test-name-pattern "US-002 AC2.4 boundary" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.4 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.4 negative: parseModelFlag rejects an empty codex model alias | L1 | node --test --test-name-pattern "US-002 AC2.4 negative" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.5 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.5 happy: parseModelFlag rejects values with more than one colon | L1 | node --test --test-name-pattern "US-002 AC2.5 happy" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.5 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.5 boundary: parseModelFlag rejects an empty triple-colon format | L1 | node --test --test-name-pattern "US-002 AC2.5 boundary" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-002 | AC2.5 | tests/node/us002-cli-command-builder.test.mjs :: US-002 AC2.5 negative: parseModelFlag rejects extra segments for spark aliases | L1 | node --test --test-name-pattern "US-002 AC2.5 negative" tests/node/us002-cli-command-builder.test.mjs | complete |
| US-003 | AC3.1 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.1 happy: pollForSignal waits until a missing signal file appears with valid JSON | L1 | node --test --test-name-pattern "US-003 AC3.1 happy" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.1 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.1 boundary: pollForSignal resolves when a real signal file is written before timeout | L3 | node --test --test-name-pattern "US-003 AC3.1 boundary" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.1 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.1 negative: pollForSignal surfaces non-ENOENT file read failures | L1 | node --test --test-name-pattern "US-003 AC3.1 negative" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.2 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.2 happy: pollForSignal in codex mode waits for valid JSON and pane exit before resolving | L1 | node --test --test-name-pattern "US-003 AC3.2 happy" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.2 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.2 boundary: pollForSignal in codex mode resolves immediately when the pane is already back at the shell | L1 | node --test --test-name-pattern "US-003 AC3.2 boundary" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.2 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.2 negative: pollForSignal tolerates transient pane-read errors while waiting for codex exit | L1 | node --test --test-name-pattern "US-003 AC3.2 negative" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.3 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.3 happy: pollForSignal rejects with TimeoutError when no signal file appears before timeout | L1 | node --test --test-name-pattern "US-003 AC3.3 happy" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.3 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.3 boundary: pollForSignal times out on invalid JSON without hanging indefinitely | L3 | node --test --test-name-pattern "US-003 AC3.3 boundary" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.3 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.3 negative: pollForSignal in codex mode times out when the pane never exits | L1 | node --test --test-name-pattern "US-003 AC3.3 negative" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.4 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.4 happy: pollForSignal ignores invalid JSON and resolves once a later poll returns valid JSON | L1 | node --test --test-name-pattern "US-003 AC3.4 happy" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.4 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.4 boundary: pollForSignal handles a real partially written file before the final JSON lands | L3 | node --test --test-name-pattern "US-003 AC3.4 boundary" tests/node/us003-signal-poller.test.mjs | complete |
| US-003 | AC3.4 | tests/node/us003-signal-poller.test.mjs :: US-003 AC3.4 negative: pollForSignal does not start codex exit checks until the signal file contains valid JSON | L1 | node --test --test-name-pattern "US-003 AC3.4 negative" tests/node/us003-signal-poller.test.mjs | complete |
| US-004 | AC4.1 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.1 happy: assembleWorkerPrompt appends iteration context, fix contract, and per-US scope lock | L1 | node --test --test-name-pattern "US-004 AC4.1 happy" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.1 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.1 boundary: assembleWorkerPrompt keeps the base prompt verbatim when memory is empty and per-US PRD is missing | L3 | node --test --test-name-pattern "US-004 AC4.1 boundary" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.1 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.1 negative: assembleWorkerPrompt emits the final verification section when all user stories are already verified | L1 | node --test --test-name-pattern "US-004 AC4.1 negative" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.2 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.2 happy: assembleWorkerPrompt includes the autonomous mode section when enabled | L1 | node --test --test-name-pattern "US-004 AC4.2 happy" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.2 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.2 boundary: assembleWorkerPrompt uses the provided conflict log path in autonomous mode | L3 | node --test --test-name-pattern "US-004 AC4.2 boundary" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.2 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.2 negative: assembleWorkerPrompt omits the autonomous mode section when disabled | L1 | node --test --test-name-pattern "US-004 AC4.2 negative" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.3 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.3 happy: assembleVerifierPrompt scopes verification to a single user story and notes previously verified stories | L1 | node --test --test-name-pattern "US-004 AC4.3 happy" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.3 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.3 boundary: assembleVerifierPrompt emits the full verify scope when usId is ALL | L3 | node --test --test-name-pattern "US-004 AC4.3 boundary" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.3 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.3 negative: assembleVerifierPrompt omits previously verified guidance when none was provided | L1 | node --test --test-name-pattern "US-004 AC4.3 negative" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.4 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.4 happy: assembleWorkerPrompt throws FileNotFoundError when the worker prompt base file does not exist | L1 | node --test --test-name-pattern "US-004 AC4.4 happy" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.4 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.4 boundary: FileNotFoundError includes the missing worker prompt base path in the message | L1 | node --test --test-name-pattern "US-004 AC4.4 boundary" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-004 | AC4.4 | tests/node/us004-prompt-assembler.test.mjs :: US-004 AC4.4 negative: assembleWorkerPrompt throws FileNotFoundError before reading other inputs when the worker prompt base file is missing | L1 | node --test --test-name-pattern "US-004 AC4.4 negative" tests/node/us004-prompt-assembler.test.mjs | complete |
| US-005 | AC5.1 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.1 happy: initCampaign creates the scaffold directories and base files | L1 | node --test --test-name-pattern "US-005 AC5.1 happy" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.1 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.1 boundary: initCampaign sanitizes special-character slugs and does not duplicate gitignore rules | L3 | node --test --test-name-pattern "US-005 AC5.1 boundary" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.1 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.1 negative: initCampaign completes a partial scaffold instead of leaving missing files behind | L1 | node --test --test-name-pattern "US-005 AC5.1 negative" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.2 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.2 happy: initCampaign creates one per-US PRD file for each ## US-NNN section | L1 | node --test --test-name-pattern "US-005 AC5.2 happy" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.2 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.2 boundary: each split PRD keeps the objective header and only its own US section | L3 | node --test --test-name-pattern "US-005 AC5.2 boundary" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.2 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.2 negative: initCampaign does not create per-US PRDs when the PRD markers do not match ## US-NNN | L1 | node --test --test-name-pattern "US-005 AC5.2 negative" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.3 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.3 happy: initCampaign fresh mode recreates the PRD instead of preserving old content | L1 | node --test --test-name-pattern "US-005 AC5.3 happy" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.3 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.3 boundary: initCampaign fresh mode removes stale per-US PRD files before recreating them | L3 | node --test --test-name-pattern "US-005 AC5.3 boundary" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.3 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.3 negative: initCampaign fresh mode still creates a new PRD when no prior PRD exists | L1 | node --test --test-name-pattern "US-005 AC5.3 negative" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.4 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.4 happy: initCampaign in agent mode does not require tmux | L1 | node --test --test-name-pattern "US-005 AC5.4 happy" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.4 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.4 boundary: initCampaign in tmux mode proceeds when a tmux session marker is present | L3 | node --test --test-name-pattern "US-005 AC5.4 boundary" tests/node/us005-campaign-initializer.test.mjs | complete |
| US-005 | AC5.4 | tests/node/us005-campaign-initializer.test.mjs :: US-005 AC5.4 negative: initCampaign rejects tmux mode without a tmux session and creates no scaffold | L1 | node --test --test-name-pattern "US-005 AC5.4 negative" tests/node/us005-campaign-initializer.test.mjs | complete |

---

## Code Quality Gates (defaults — override in PRD with justification)
- **Code duplication**: <= 3% (project-appropriate tool, e.g., jscpd, pylint, sonar)
- **Mock ratio**: mock-based assertions <= 30% of total assertions
- **Cyclomatic complexity**: <= 10 per function
- **Function length**: <= 50 lines per function
- **File length**: <= 800 lines per file

---

## Reproducibility Gate
- [ ] Lock file exists and committed (package-lock.json, poetry.lock, go.sum, etc.) or "N/A — no external dependencies"
- [ ] Clean install succeeds (npm ci, pip install, etc.) or "N/A — no external dependencies"
- [ ] Security scan passes (or known vulnerabilities documented and acknowledged in PRD) or "N/A — no dependencies"
- [ ] Environment variables documented (.env.example or equivalent) or "N/A — no env vars"

---

## Criteria → Verification Mapping

| US | AC | Layer | Method | Command | Expected Output | Pass Criteria |
|----|----|-------|--------|---------|-----------------|---------------|
| US-00 | AC1 | L1 | node:test | node --test --test-name-pattern "AC1" tests/node/us00-bootstrap.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC1 tests pass |
| US-00 | AC2 | L1 | node:test | node --test --test-name-pattern "AC2" tests/node/us00-bootstrap.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2 tests pass |
| US-00 | AC1-AC2 | L3 | node:test happy-path subset | node --test --test-name-pattern "happy" tests/node/us00-bootstrap.test.mjs | 2 tests pass | exit 0 + both happy-path bootstrap tests pass |
| US-00 | AC1-AC2 | L3 | node:test boundary/negative subset | node --test --test-name-pattern "negative|boundary" tests/node/us00-bootstrap.test.mjs | 4 tests pass | exit 0 + all boundary and negative bootstrap tests pass |
| US-00 | AC1-AC2 | L3 | node:test smoke | node --test tests/node/us00-bootstrap.test.mjs | 6 tests pass | exit 0 + all bootstrap tests pass together |
| US-001 | AC1.1 | L1 | node:test | node --test --test-name-pattern "US-001 AC1.1" tests/node/us001-tmux-pane-manager.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC1.1 tests pass |
| US-001 | AC1.2 | L1 | node:test | node --test --test-name-pattern "US-001 AC1.2" tests/node/us001-tmux-pane-manager.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC1.2 tests pass |
| US-001 | AC1.3 | L1 | node:test | node --test --test-name-pattern "US-001 AC1.3" tests/node/us001-tmux-pane-manager.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC1.3 tests pass |
| US-001 | AC1.4 | L1 | node:test | node --test --test-name-pattern "US-001 AC1.4" tests/node/us001-tmux-pane-manager.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC1.4 tests pass |
| US-001 | AC1.1-AC1.4 | L3 | node:test happy-path subset | node --test --test-name-pattern "happy" tests/node/us001-tmux-pane-manager.test.mjs | 4 tests pass | exit 0 + all happy-path tmux pane manager tests pass |
| US-001 | AC1.1-AC1.4 | L3 | node:test boundary subset | node --test --test-name-pattern "boundary" tests/node/us001-tmux-pane-manager.test.mjs | 4 tests pass | exit 0 + all boundary tmux pane manager tests pass |
| US-001 | AC1.1-AC1.4 | L3 | node:test error-path subset | node --test --test-name-pattern "negative" tests/node/us001-tmux-pane-manager.test.mjs | 4 tests pass | exit 0 + all error-path tmux pane manager tests pass |
| US-001 | AC1.1-AC1.4 | L3 | node:test smoke | node --test tests/node/us001-tmux-pane-manager.test.mjs | 12 tests pass | exit 0 + full tmux pane manager suite passes |
| US-002 | AC2.1 | L1 | node:test | node --test --test-name-pattern "US-002 AC2.1" tests/node/us002-cli-command-builder.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2.1 tests pass |
| US-002 | AC2.2 | L1 | node:test | node --test --test-name-pattern "US-002 AC2.2" tests/node/us002-cli-command-builder.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2.2 tests pass |
| US-002 | AC2.3 | L1 | node:test | node --test --test-name-pattern "US-002 AC2.3" tests/node/us002-cli-command-builder.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2.3 tests pass |
| US-002 | AC2.4 | L1 | node:test | node --test --test-name-pattern "US-002 AC2.4" tests/node/us002-cli-command-builder.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2.4 tests pass |
| US-002 | AC2.5 | L1 | node:test | node --test --test-name-pattern "US-002 AC2.5" tests/node/us002-cli-command-builder.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC2.5 tests pass |
| US-002 | AC2.1-AC2.5 | L1 | node:test happy-path subset | node --test --test-name-pattern "happy" tests/node/us002-cli-command-builder.test.mjs | 5 tests pass | exit 0 + all happy-path command-builder tests pass |
| US-002 | AC2.1-AC2.5 | L1 | node:test boundary subset | node --test --test-name-pattern "boundary" tests/node/us002-cli-command-builder.test.mjs | 5 tests pass | exit 0 + all boundary command-builder tests pass |
| US-002 | AC2.1-AC2.5 | L1 | node:test error-path subset | node --test --test-name-pattern "negative" tests/node/us002-cli-command-builder.test.mjs | 5 tests pass | exit 0 + all error-path command-builder tests pass |
| US-002 | AC2.1-AC2.5 | L1 | node:test smoke | node --test tests/node/us002-cli-command-builder.test.mjs | 15 tests pass | exit 0 + full command-builder suite passes |
| US-003 | AC3.1 | L1/L3 | node:test | node --test --test-name-pattern "US-003 AC3.1" tests/node/us003-signal-poller.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC3.1 tests pass |
| US-003 | AC3.2 | L1 | node:test | node --test --test-name-pattern "US-003 AC3.2" tests/node/us003-signal-poller.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC3.2 tests pass |
| US-003 | AC3.3 | L1/L3 | node:test | node --test --test-name-pattern "US-003 AC3.3" tests/node/us003-signal-poller.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC3.3 tests pass |
| US-003 | AC3.4 | L1/L3 | node:test | node --test --test-name-pattern "US-003 AC3.4" tests/node/us003-signal-poller.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC3.4 tests pass |
| US-003 | AC3.1-AC3.4 | L3 | node:test happy-path subset | node --test --test-name-pattern "US-003 AC3.1 boundary|US-003 AC3.4 happy" tests/node/us003-signal-poller.test.mjs | 2 tests pass | exit 0 + file-appearance and invalid-JSON recovery happy-path polling tests pass |
| US-003 | AC3.1-AC3.4 | L3 | node:test boundary subset | node --test --test-name-pattern "US-003 AC3.2 boundary|US-003 AC3.3 boundary|US-003 AC3.4 boundary" tests/node/us003-signal-poller.test.mjs | 3 tests pass | exit 0 + codex idle-pane, invalid-JSON timeout, and partial-write boundary tests pass |
| US-003 | AC3.1-AC3.4 | L3 | node:test error-path subset | node --test --test-name-pattern "US-003 AC3.1 negative|US-003 AC3.2 negative|US-003 AC3.3 negative|US-003 AC3.4 negative" tests/node/us003-signal-poller.test.mjs | 4 tests pass | exit 0 + read-error, pane-retry, codex-timeout, and invalid-JSON negative tests pass |
| US-003 | AC3.1-AC3.4 | L1/L3 | node:test smoke | node --test tests/node/us003-signal-poller.test.mjs | 12 tests pass | exit 0 + full signal poller suite passes |
| US-004 | AC4.1 | L1/L3 | node:test | node --test --test-name-pattern "US-004 AC4.1" tests/node/us004-prompt-assembler.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC4.1 tests pass |
| US-004 | AC4.2 | L1/L3 | node:test | node --test --test-name-pattern "US-004 AC4.2" tests/node/us004-prompt-assembler.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC4.2 tests pass |
| US-004 | AC4.3 | L1/L3 | node:test | node --test --test-name-pattern "US-004 AC4.3" tests/node/us004-prompt-assembler.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC4.3 tests pass |
| US-004 | AC4.4 | L1 | node:test | node --test --test-name-pattern "US-004 AC4.4" tests/node/us004-prompt-assembler.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC4.4 tests pass |
| US-004 | AC4.1-AC4.4 | L3 | node:test happy-path subset | node --test --test-name-pattern "US-004 AC4.1 happy|US-004 AC4.2 happy|US-004 AC4.3 happy" tests/node/us004-prompt-assembler.test.mjs | 3 tests pass | exit 0 + worker prompt assembly, autonomous mode, and verifier scope happy-path tests pass |
| US-004 | AC4.1-AC4.4 | L3 | node:test boundary subset | node --test --test-name-pattern "US-004 AC4.1 boundary|US-004 AC4.2 boundary|US-004 AC4.3 boundary|US-004 AC4.4 boundary" tests/node/us004-prompt-assembler.test.mjs | 4 tests pass | exit 0 + fallback paths, conflict-log override, ALL scope, and FileNotFoundError message boundary tests pass |
| US-004 | AC4.1-AC4.4 | L1 | node:test error-path subset | node --test --test-name-pattern "US-004 AC4.1 negative|US-004 AC4.2 negative|US-004 AC4.3 negative|US-004 AC4.4 happy|US-004 AC4.4 negative" tests/node/us004-prompt-assembler.test.mjs | 5 tests pass | exit 0 + final-verify branch, disabled optional sections, and missing-base-file error tests pass |
| US-004 | AC4.1-AC4.4 | L1/L3 | node:test smoke | node --test tests/node/us004-prompt-assembler.test.mjs | 12 tests pass | exit 0 + full prompt assembler suite passes |
| US-005 | AC5.1 | L1/L3 | node:test | node --test --test-name-pattern "US-005 AC5.1" tests/node/us005-campaign-initializer.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC5.1 tests pass |
| US-005 | AC5.2 | L1/L3 | node:test | node --test --test-name-pattern "US-005 AC5.2" tests/node/us005-campaign-initializer.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC5.2 tests pass |
| US-005 | AC5.3 | L1/L3 | node:test | node --test --test-name-pattern "US-005 AC5.3" tests/node/us005-campaign-initializer.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC5.3 tests pass |
| US-005 | AC5.4 | L1/L3 | node:test | node --test --test-name-pattern "US-005 AC5.4" tests/node/us005-campaign-initializer.test.mjs | 3 tests pass | exit 0 + happy, boundary, and negative AC5.4 tests pass |
| US-005 | AC5.1-AC5.4 | L3 | node:test happy-path subset | node --test --test-name-pattern "US-005 AC5.1 happy|US-005 AC5.2 happy|US-005 AC5.3 happy|US-005 AC5.4 happy" tests/node/us005-campaign-initializer.test.mjs | 4 tests pass | exit 0 + scaffold creation, PRD splitting, fresh recreation, and agent-mode happy-path tests pass |
| US-005 | AC5.1-AC5.4 | L3 | node:test boundary subset | node --test --test-name-pattern "US-005 AC5.1 boundary|US-005 AC5.2 boundary|US-005 AC5.3 boundary|US-005 AC5.4 boundary" tests/node/us005-campaign-initializer.test.mjs | 4 tests pass | exit 0 + slug/gitignore, split-file isolation, stale-file cleanup, and tmux-marker boundary tests pass |
| US-005 | AC5.1-AC5.4 | L1 | node:test error-path subset | node --test --test-name-pattern "US-005 AC5.1 negative|US-005 AC5.2 negative|US-005 AC5.3 negative|US-005 AC5.4 negative" tests/node/us005-campaign-initializer.test.mjs | 4 tests pass | exit 0 + partial scaffold recovery, invalid-marker rejection, missing-prior-PRD fresh mode, and no-tmux rejection tests pass |
| US-005 | AC5.1-AC5.4 | L1/L3 | node:test smoke | node --test tests/node/us005-campaign-initializer.test.mjs | 12 tests pass | exit 0 + full campaign initializer suite passes |
