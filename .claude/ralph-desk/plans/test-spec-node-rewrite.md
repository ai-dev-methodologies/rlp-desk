# Test Specification: node-rewrite

## Iron Law Reference
> IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
> IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3

---

## Verification Commands
### Build
```bash
node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs'); await import('./src/node/tmux/pane-manager.mjs'); await import('./src/node/cli/command-builder.mjs');"
```
### Test
```bash
node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs
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

### Impacted Tests
Existing tests that may break due to this change:
- None identified. This iteration adds the first Node-native tests alongside the existing zsh test suites.
- No existing Node tmux tests existed. US-001 adds a new real-`tmux` test file.
- No existing Node command-builder tests existed. US-002 adds a new unit-only command-builder test file.

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
node --test tests/node/us00-bootstrap.test.mjs tests/node/us001-tmux-pane-manager.test.mjs tests/node/us002-cli-command-builder.test.mjs
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
