# Test Specification: node-rewrite

## Iron Law Reference
> IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
> IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3

---

## Verification Commands
### Build
```bash
node -e "await import('./src/node/shared/paths.mjs'); await import('./src/node/shared/fs.mjs');"
```
### Test
```bash
node --test tests/node/us00-bootstrap.test.mjs
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

### Impacted Tests
Existing tests that may break due to this change:
- None identified. This iteration adds the first Node-native tests alongside the existing zsh test suites.

### Required New Tests
Tests that MUST be written (minimum 3 per AC: happy + negative + boundary):
- `tests/node/us00-bootstrap.test.mjs`
- AC1: `resolveProjectPath` happy + boundary + negative
- AC2: `writeFileAtomic` happy + boundary + negative

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
node --test tests/node/us00-bootstrap.test.mjs
```

### L2: Integration (required if external services exist, otherwise "N/A — reason")
```bash
N/A — no external services in US-00 bootstrap primitives
```

### L3: E2E Simulation (REQUIRED)
Known input → full pipeline → quantitative output comparison.
Must cover ALL AC types: happy path + boundary + error path.
- **Happy path input**: TODO (specific test data)
- **Happy path input**: `resolveProjectPath('src', 'scripts', 'run_ralph_desk.zsh')` and `writeFileAtomic('.tmp/us00-bootstrap-tests/nested/artifact.txt', 'first-pass')`
- **Happy path expected output**: TODO (quantitative value)
- **Happy path expected output**: absolute repo path returned; file created with exact content `first-pass`
- **Happy path command**:
```bash
node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "happy"
```
- **Error path input**: `resolveProjectPath('..')` and `writeFileAtomic(<outside-project>, 'blocked')`
- **Error path expected**: error message includes `outside the project root`
- **Error path command**:
```bash
node --test tests/node/us00-bootstrap.test.mjs --test-name-pattern "negative|boundary"
```

### L4: Deploy Verification (required if deploying, otherwise "N/A — reason")
```bash
N/A — no deployment in this iteration
```

---

## Mutation Testing Gate (CRITICAL risk only)
- Required: only for CRITICAL risk classification (governance §1c)
- Tool: TODO (e.g., mutmut, Stryker, go-mutesting) or "N/A — not CRITICAL risk"
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
| US-00 | AC1-AC2 | L3 | node:test smoke | node --test tests/node/us00-bootstrap.test.mjs | 6 tests pass | exit 0 + all bootstrap tests pass together |
