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

## Iteration rules
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly the work specified in the Next Iteration Contract.
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- Write evidence artifacts.
- **Commit all changes when the iteration is complete** (include iteration number and story ID in commit message).

MANDATORY: When done with this iteration, write the following signal file:
- Path: $DESK/memos/$SLUG-iter-signal.json
- Format: {"iteration": N, "status": "continue|verify|blocked", "summary": "what was done", "timestamp": "ISO"}
- Status values:
  - "continue" = current action done but more work remains
  - "verify" = all work complete + done-claim written
  - "blocked" = autonomous blocker

## Stop behavior
- Objective achieved → write done-claim JSON to $DESK/memos/$SLUG-done-claim.json, exit
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

Required reads:
- PRD: $DESK/plans/prd-$SLUG.md
- Test Spec: $DESK/plans/test-spec-$SLUG.md
- Campaign Memory: $DESK/memos/$SLUG-memory.md (orientation only — not source of truth)
- Latest Context: $DESK/context/$SLUG-latest.md
- Done Claim: $DESK/memos/$SLUG-done-claim.json

Process:
1. Read PRD acceptance criteria
2. Read done claim
3. Identify scope: run \`git diff --name-only\` to find changed files, then read those files + related imports only
4. Run fresh verification: build, test, lint, typecheck (per test-spec tools)
5. Check each criterion against fresh evidence
6. Run smoke test if defined in PRD
7. Write verdict JSON to: $DESK/memos/$SLUG-verify-verdict.json

Verdict JSON:
{
  "verdict": "pass|fail|request_info",
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "criteria_results": [{"criterion":"...","met":true/false,"evidence":"..."}],
  "missing_evidence": [],
  "issues": [{"id":"...","severity":"critical|major|minor","description":"...","fix_hint":"(suggestion, non-authoritative)"}],
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
- **Depends on**: []
- **Acceptance Criteria**:
  - [ ] [Specific, testable criterion]
- **Status**: not started

## Non-Goals
## Technical Constraints
## Done When
- All acceptance criteria pass
- Independent verifier confirms
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Test Spec ---
F="$DESK/plans/test-spec-$SLUG.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# Test Specification: $SLUG

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

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1 | TODO | TODO |
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
