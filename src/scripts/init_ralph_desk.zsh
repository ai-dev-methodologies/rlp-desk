#!/bin/zsh
set -euo pipefail

# =============================================================================
# Ralph Desk Project Initializer for Claude Code
#
# User-level tool: ~/.claude/ralph-desk/init_ralph_desk.zsh
# Creates project-local scaffold in: .claude/ralph-desk/
#
# Usage:
#   ~/.claude/ralph-desk/init_ralph_desk.zsh <slug> [objective]
# =============================================================================

SLUG="${1:?Usage: $0 <slug> [objective]}"
OBJECTIVE="${2:-TBD - fill in the objective}"
ROOT="${ROOT:-$PWD}"
DESK="$ROOT/.claude/ralph-desk"
RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Initializing Ralph Desk: $SLUG"
echo "  Root: $ROOT"
echo "  Desk: $DESK"
echo ""

mkdir -p "$DESK/prompts" "$DESK/context" "$DESK/memos" "$DESK/plans" "$DESK/logs/$SLUG"

# --- Worker Prompt ---
F="$DESK/prompts/$SLUG.worker.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
Execute the plan for $SLUG.

## Before you start
Read these files in order:
1. Campaign Memory: $DESK/memos/$SLUG-memory.md → Next Iteration Contract is your mission
2. PRD: $DESK/plans/prd-$SLUG.md → acceptance criteria
3. Test Spec: $DESK/plans/test-spec-$SLUG.md → verification methods
4. Latest Context: $DESK/context/$SLUG-latest.md → current state

## SCOPE LOCK (hard constraint — violation causes verification failure)
- You MUST only implement the work described in the "Next Iteration Contract" from campaign memory.
- If the contract says "implement US-001 only", do ONLY that. Do NOT touch other stories.
- If the contract says "implement all remaining stories", you may do all of them.
- Do NOT go beyond the contracted scope, even if you can see more work in the PRD.
- No file creation or modification outside the project root.
- Do not modify this prompt file or any PRD/test-spec files.

## Test-First Approach (read test-spec BEFORE coding)
1. Read test-spec "Impacted Tests" — if TODO (first iteration), skip to step 2 and fill this section during your work. Otherwise, run these FIRST to confirm they pass before your changes.
2. Read test-spec "Required New Tests" — write these. They SHOULD FAIL initially.
3. Implement minimum code to make all tests pass.
4. Run ALL tests (impacted + new) to confirm nothing is broken.

## Forbidden Shortcuts (Verifier will check these)
- Do not mock external services when L2 integration test is required by test-spec.
- Do not delete or weaken existing assertions to make tests pass.
- Do not add test-specific logic (code that detects it is running in a test).
- Do not skip boundary cases listed in the PRD.
- Do not claim "code inspection" as verification — run the actual command.
- Do not say "too simple to test" — simple code breaks. Test takes 30 seconds.
- Do not say "I'll test after" — tests passing immediately prove nothing.
- Do not say "already manually tested" — ad-hoc is not systematic, no record.
- Do not say "partial check is enough" — partial proves nothing about the whole.
- Do not say "I'm confident" — confidence is not evidence.
- Do not say "existing code has no tests" — you are improving it, add tests.
- Do not write code before tests — if you did, delete it and start with tests.

## Iteration rules
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly the work specified in the Next Iteration Contract.
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- Write evidence artifacts.
- **Commit all changes when the iteration is complete** (include iteration number and story ID in commit message).

MANDATORY: When done with this iteration, write the following signal file:
- Path: $DESK/memos/$SLUG-iter-signal.json
- Format: {"iteration": N, "status": "continue|verify|blocked", "us_id": "US-NNN or null", "summary": "what was done", "timestamp": "ISO"}
- Status values:
  - "continue" = current action done but more work remains (no verify needed yet)
  - "verify" = current US complete + done-claim written → Verifier checks this US
  - "blocked" = autonomous blocker

## Signal rules (per-US verification)
- After completing EACH user story → signal "verify" with "us_id" set to the story you just finished (e.g., "US-001").
- The Verifier will check ONLY that story's acceptance criteria.
- After ALL stories individually pass verification → signal "verify" with "us_id": "ALL" for a final full verify of all AC.
- Do NOT signal "continue" when a US is done — always signal "verify" per US.
- Signal "continue" ONLY when you have more work to do within the same US (e.g., a multi-step task).

## Done Claim Format
When writing done-claim JSON, ALWAYS include execution_steps — what you did, in what order, with evidence:
\`\`\`json
{
  "us_id": "US-NNN",
  "claims": ["AC1: ...", "AC2: ..."],
  "execution_steps": [
    {"step": "write_test", "ac_id": "AC1", "command": null, "summary": "wrote tests/test_add.py with 3 tests"},
    {"step": "verify_red", "ac_id": "AC1", "command": "pytest tests/...", "exit_code": 1, "summary": "RED: test fails as expected"},
    {"step": "implement", "ac_id": "AC1", "command": null, "summary": "created add() function"},
    {"step": "verify_green", "ac_id": "AC1", "command": "pytest tests/...", "exit_code": 0, "summary": "GREEN: 3 passed"},
    {"step": "verify_e2e", "ac_id": "AC1", "command": "python -c '...'", "exit_code": 0, "summary": "E2E output matches expected"},
    {"step": "commit", "ac_id": "AC1", "command": "git commit ...", "exit_code": 0, "summary": "committed abc1234"}
  ]
}
\`\`\`
This is NOT optional. Every done-claim must include the steps you took and the evidence for each.

## Stop behavior
- Single US achieved → write done-claim JSON to $DESK/memos/$SLUG-done-claim.json with the specific US, signal verify, exit
- All US achieved → write done-claim JSON with all US, signal verify with us_id "ALL", exit
- Autonomous blocker → write to $DESK/memos/$SLUG-blocked.md, exit
- Otherwise → set stop=continue, define next iteration contract in memory, exit

## Objective
$OBJECTIVE
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Verifier Prompt ---
F="$DESK/prompts/$SLUG.verifier.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
Independent verifier for Ralph Desk: $SLUG

## Iron Law (ABSOLUTE — no exceptions)
> NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
> "should pass", "probably works", "seems to" = automatic FAIL

## Evidence Gate (MANDATORY before any verdict)
1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
5. ONLY THEN: Issue verdict

Required reads:
- PRD: $DESK/plans/prd-$SLUG.md
- Test Spec: $DESK/plans/test-spec-$SLUG.md
- Campaign Memory: $DESK/memos/$SLUG-memory.md (orientation only — not source of truth)
- Latest Context: $DESK/context/$SLUG-latest.md
- Done Claim: $DESK/memos/$SLUG-done-claim.json
- Iteration Signal: $DESK/memos/$SLUG-iter-signal.json (check us_id field)

## Verification Scope
Check the iter-signal.json "us_id" field:
- If us_id is a specific story (e.g., "US-001"): verify ONLY that story's acceptance criteria from the PRD.
- If us_id is "ALL": verify ALL acceptance criteria from the PRD (final full verify).
- If us_id is absent or null: verify all criteria in the done-claim (legacy/batch mode).

## Verification Process
1. Read PRD acceptance criteria (scoped to us_id if present)
2. Read done claim
3. Identify scope: run \`git diff --name-only\` to find changed files, then read those files + related imports only
4. **Scope Lock check**: (a) Read the Next Iteration Contract from campaign memory to identify the contracted US. (b) Run \`git diff --name-only\` to list all changed files. (c) For each changed file, verify it is plausibly related to the contracted US's acceptance criteria. (d) Flag files that appear unrelated. (e) Shared infrastructure (types, configs, common utilities) and dependency files are permitted if the AC implies them.
5. **Layer Enforcement**: check test-spec L1/L2/L3/L4 sections. ANY section with TODO or blank = FAIL (IL-3).
6. Run fresh verification: execute ALL commands from test-spec verification layers (L1, L2, L3, L4 as applicable)
7. Check each criterion against fresh evidence (only for the scoped US, or all if us_id=ALL)
8. Run smoke test if defined in PRD
9. **Test Sufficiency (IL-4)**: count test functions exercising each AC. Count < 3 per AC = FAIL.
   Check diversity: at least 2 of 3 categories (happy, negative, boundary) per AC.
10. **Anti-Gaming Detection**:
   - Assertion integrity: compare assertion count/strength via \`git diff HEAD~1\` — assertions not deleted or weakened
   - Test-specific logic: no environment-detection patterns
   - "Code inspection" claims: Worker must run actual commands
   - Tautological tests: expected values that mirror implementation logic
11. **Reproducibility check**: verify lock file committed, clean install succeeds, security scan passes, env vars documented (per test-spec Reproducibility Gate). Skip if test-spec says "N/A."
12. Write verdict JSON to: $DESK/memos/$SLUG-verify-verdict.json

Verdict JSON:
{
  "verdict": "pass|fail|request_info",
  "us_id": "US-NNN or ALL (matches the scope you verified)",
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "criteria_results": [{"criterion":"...","met":true/false,"evidence":"..."}],
  "missing_evidence": [],
  "issues": [{"id":"...","severity":"critical|major|minor","description":"...","fix_hint":"(suggestion, non-authoritative)"}],
  "reasoning": [
    {"check": "IL-1 Evidence Gate", "decision": "pass|fail", "basis": "what command was run, what output confirmed the decision"},
    {"check": "Layer Enforcement", "decision": "pass|fail", "basis": "which layers checked, any TODO found"},
    {"check": "Test Sufficiency", "decision": "pass|fail", "basis": "test count per AC, category coverage"},
    {"check": "Anti-Gaming", "decision": "pass|fail", "basis": "what was checked, any suspicious patterns"}
  ],
  "layer_status": {"L1":"pass|fail|todo|na","L2":"pass|fail|todo|na","L3":"pass|fail|todo|na","L4":"pass|fail|todo|na"},
  "test_quality": {"test_count":0,"ac_count":0,"sufficiency":"pass|fail","anti_patterns_found":[]},
  "recommended_state_transition": "complete|continue|blocked",
  "next_iteration_contract": "...",
  "evidence_paths": []
}

Rules:
- Do NOT trust the worker's claim. Verify with fresh evidence.
- If uncertain, verdict = request_info (describe your specific question in summary so Leader can decide).
- Campaign Memory is for orientation only — do NOT use it as source of truth for AC verification.
- Deterministic checks (type hints, linting, security) delegate to test-spec tools; focus on AC verification + semantic review + smoke test.
- Do NOT modify code or write sentinel files.
- If Worker claims "inspection" or "review" for an AC that requires an automated command, verdict = FAIL.
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Context ---
F="$DESK/context/$SLUG-latest.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# $SLUG - Latest Context

## Current Frontier
### Completed
### In Progress
### Next
- (TBD by first worker)

## Key Decisions
## Known Issues
## Files Changed This Iteration
## Verification Status
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Campaign Memory ---
F="$DESK/memos/$SLUG-memory.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# $SLUG - Campaign Memory

## Stop Status
continue

## Objective
$OBJECTIVE

## Current State
Iteration 0 - not started

## Completed Stories

## Next Iteration Contract
Start from the beginning: read PRD and plan the first bounded action.

**Criteria**:
- (to be defined by first worker after reading PRD)

## Key Decisions

## Patterns Discovered
## Learnings
## Evidence Chain
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- PRD ---
F="$DESK/plans/prd-$SLUG.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# PRD: $SLUG

## Objective
$OBJECTIVE

## User Stories

### US-001: [Title]
- **Priority**: P0
- **Size**: S|M|L
- **Type**: code|visual|content|integration|infra
- **Risk**: LOW|MEDIUM|HIGH|CRITICAL (governance §1c)
- **Depends on**: []
- **Acceptance Criteria** (Given/When/Then — domain language only):
  - AC1:
    - Given: [precondition in domain language]
    - When: [action in domain language]
    - Then: [expected outcome with quantitative criteria]
  - AC2:
    - Given: [precondition]
    - When: [action]
    - Then: [expected outcome with quantitative criteria]
- **Boundary Cases**: [edge cases — empty input, max values, error conditions, concurrent access]
- **Verification Layers**: [Fill per Risk level — LOW: L1+L3, MEDIUM: L1+L2(if ext deps)+L3, HIGH: L1+L2+L3+L4, CRITICAL: L1+L2+L3+L4+mutation (governance §1c)]
- **Status**: not started

## Non-Goals
## Technical Constraints
## Done When
- All acceptance criteria pass with quantitative evidence
- All boundary cases covered
- All required verification layers executed (no TODO remaining)
- Independent verifier confirms via Evidence Gate (governance §1b)
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Test Spec ---
F="$DESK/plans/test-spec-$SLUG.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# Test Specification: $SLUG

## Iron Law Reference
> IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
> IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3

---

## Verification Commands
### Build
\`\`\`bash
# TODO
\`\`\`
### Test
\`\`\`bash
# TODO
\`\`\`
### Lint
\`\`\`bash
# TODO
\`\`\`

---

## Verification Context (fill BEFORE implementation)

### Target Behavior
What behavior does this project change or introduce?
- TODO

### Impacted Tests
Existing tests that may break due to this change:
- TODO (acceptable at init; Worker fills during first iteration)

### Required New Tests
Tests that MUST be written (minimum 3 per AC: happy + negative + boundary):
- TODO

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
\`\`\`bash
# TODO — unit test command (e.g., pytest, jest, go test)
\`\`\`

### L2: Integration (required if external services exist, otherwise "N/A — reason")
\`\`\`bash
# TODO — integration test command, or write: N/A — no external services (pure computation/transformation)
\`\`\`

### L3: E2E Simulation (REQUIRED)
Known input → full pipeline → quantitative output comparison.
- **Input**: TODO (specific test data)
- **Expected output**: TODO (quantitative value)
- **Command**:
\`\`\`bash
# TODO — E2E verification command
\`\`\`

### L4: Deploy Verification (required if deploying, otherwise "N/A — reason")
\`\`\`bash
# TODO — deploy verification command, or write: N/A — no deployment (library/tool, local-only change)
\`\`\`

---

## Mutation Testing Gate (CRITICAL risk only)
- Required: only for CRITICAL risk classification (governance §1c)
- Tool: TODO (e.g., mutmut, Stryker, go-mutesting) or "N/A — not CRITICAL risk"
- Target: >= 60% mutation score on core business logic (project default; override in PRD if justified)
- Scope: core business logic files (not config/tests/docs)
- Command:
\`\`\`bash
# TODO — mutation testing command, or write: N/A — not CRITICAL risk
\`\`\`

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
| US-001 | AC1 | TODO | L1 | TODO | pending |

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
| US-001 | AC1 | L1 | TODO | TODO | TODO | TODO |
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- .gitignore for runtime artifacts ---
GITIGNORE="$ROOT/.gitignore"
MARKER="# RLP Desk runtime artifacts"
if [[ -f "$GITIGNORE" ]]; then
  if ! grep -qF "$MARKER" "$GITIGNORE"; then
    echo "" >> "$GITIGNORE"
    cat >> "$GITIGNORE" <<'GIEOF'
# RLP Desk runtime artifacts
.claude/ralph-desk/
GIEOF
    echo "  + .gitignore (rlp-desk rules appended)"
  else
    echo "  · .gitignore (rlp-desk rules already present)"
  fi
else
  cat > "$GITIGNORE" <<'GIEOF'
# RLP Desk runtime artifacts
.claude/ralph-desk/
GIEOF
  echo "  + .gitignore (created with rlp-desk rules)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Scaffold ready: $SLUG"
echo ""
echo "Next:"
echo "  1. Edit PRD:       $DESK/plans/prd-$SLUG.md"
echo "  2. Edit test spec: $DESK/plans/test-spec-$SLUG.md"
echo "  3. Run:"
echo ""
echo "  LOOP_NAME=$SLUG \\"
echo "  PROMPT_FILE=$DESK/prompts/$SLUG.worker.prompt.md \\"
echo "  VERIFIER_PROMPT_FILE=$DESK/prompts/$SLUG.verifier.prompt.md \\"
echo "  CONTEXT_FILE=$DESK/context/$SLUG-latest.md \\"
echo "  EXTRA_REQUIRED_FILES=$DESK/plans/prd-$SLUG.md:$DESK/plans/test-spec-$SLUG.md:$DESK/memos/$SLUG-memory.md \\"
echo "  MAX_ITER=20 \\"
echo "  $RUNNER_DIR/run_ralph_desk.zsh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
