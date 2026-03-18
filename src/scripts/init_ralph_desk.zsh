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

Required reads every iteration:
- PRD: $DESK/plans/prd-$SLUG.md
- Test Spec: $DESK/plans/test-spec-$SLUG.md
- Campaign Memory: $DESK/memos/$SLUG-memory.md
- Latest Context: $DESK/context/$SLUG-latest.md

Iteration rules:
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly ONE bounded next action.
- If campaign memory has an unresolved Next iteration contract, do that first.
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- Write evidence artifacts.

Stop behavior:
- Objective achieved → write done-claim JSON to $DESK/memos/$SLUG-done-claim.json, exit
- Autonomous blocker → write to $DESK/memos/$SLUG-blocked.md, exit
- Otherwise → set stop=continue, define next iteration contract in memory, exit

Objective: $OBJECTIVE
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
- Campaign Memory: $DESK/memos/$SLUG-memory.md
- Latest Context: $DESK/context/$SLUG-latest.md
- Done Claim: $DESK/memos/$SLUG-done-claim.json

Process:
1. Read PRD acceptance criteria
2. Read done claim
3. Run fresh verification: build, test, lint, typecheck
4. Check each criterion against fresh evidence
5. Write verdict JSON to: $DESK/memos/$SLUG-verify-verdict.json

Verdict JSON:
{
  "verdict": "pass|fail|blocked",
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "criteria_results": [{"criterion":"...","met":true/false,"evidence":"..."}],
  "missing_evidence": [],
  "issues": [],
  "recommended_state_transition": "complete|continue|blocked",
  "next_iteration_contract": "...",
  "evidence_paths": []
}

Rules:
- Do NOT trust the worker's claim. Verify with fresh evidence.
- If uncertain, verdict = fail.
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

## Next Iteration Contract
Start from the beginning: read PRD and plan the first bounded action.

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
.claude/ralph-desk/logs/
.claude/ralph-desk/memos/*-done-claim.json
.claude/ralph-desk/memos/*-verify-verdict.json
.claude/ralph-desk/memos/*-complete.md
.claude/ralph-desk/memos/*-blocked.md
.claude/ralph-desk/memos/*-iter-signal.json
GIEOF
    echo "  + .gitignore (rlp-desk rules appended)"
  else
    echo "  · .gitignore (rlp-desk rules already present)"
  fi
else
  cat > "$GITIGNORE" <<'GIEOF'
# RLP Desk runtime artifacts
.claude/ralph-desk/logs/
.claude/ralph-desk/memos/*-done-claim.json
.claude/ralph-desk/memos/*-verify-verdict.json
.claude/ralph-desk/memos/*-complete.md
.claude/ralph-desk/memos/*-blocked.md
.claude/ralph-desk/memos/*-iter-signal.json
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
