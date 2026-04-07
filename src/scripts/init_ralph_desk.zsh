#!/bin/zsh
set -euo pipefail

# =============================================================================
# Ralph Desk Project Initializer for Claude Code
#
# User-level tool: ~/.claude/ralph-desk/init_ralph_desk.zsh
# Creates project-local scaffold in: .claude/ralph-desk/
#
# Usage:
#   ~/.claude/ralph-desk/init_ralph_desk.zsh <slug> [objective] [--mode fresh|improve]
# =============================================================================

SLUG="${1:?Usage: $0 <slug> [objective] [--mode fresh|improve] [--server-cmd CMD] [--server-port PORT] [--server-health URL]}"
MODE=""
OBJECTIVE="TBD - fill in the objective"
SERVER_CMD=""
SERVER_PORT=""
SERVER_HEALTH=""

# Parse remaining arguments
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:?--mode requires an argument: fresh|improve}"
      shift 2
      ;;
    --mode=*)
      MODE="${1#--mode=}"
      shift
      ;;
    --server-cmd)
      SERVER_CMD="${2:?--server-cmd requires a command}"
      shift 2
      ;;
    --server-cmd=*)
      SERVER_CMD="${1#--server-cmd=}"
      shift
      ;;
    --server-port)
      SERVER_PORT="${2:?--server-port requires a port number}"
      shift 2
      ;;
    --server-port=*)
      SERVER_PORT="${1#--server-port=}"
      shift
      ;;
    --server-health)
      SERVER_HEALTH="${2:?--server-health requires a URL}"
      shift 2
      ;;
    --server-health=*)
      SERVER_HEALTH="${1#--server-health=}"
      shift
      ;;
    *)
      OBJECTIVE="$1"
      shift
      ;;
  esac
done

ROOT="${ROOT:-$PWD}"
DESK="$ROOT/.claude/ralph-desk"
RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Re-execution versioning helpers ---
# Handles ONLY debug.log and campaign-report.md versioning.
# SV reports use their own -NNN auto-increment pattern and are NOT handled here.

detect_next_version() {
  local file_path="$1"
  local dir base ext n=1
  dir="$(dirname "$file_path")"
  base="$(basename "$file_path")"
  if [[ "$base" == *.* ]]; then
    ext=".${base##*.}"
    base="${base%.*}"
  else
    ext=""
  fi
  while [[ -f "$dir/${base}-v${n}${ext}" ]]; do
    (( n++ ))
  done
  echo "$n"
}

version_file() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    local n dir base ext
    n="$(detect_next_version "$file_path")"
    dir="$(dirname "$file_path")"
    base="$(basename "$file_path")"
    if [[ "$base" == *.* ]]; then
      ext=".${base##*.}"
      base="${base%.*}"
    else
      ext=""
    fi
    mv "$file_path" "$dir/${base}-v${n}${ext}"
    echo "  Versioned: $(basename "$file_path") → ${base}-v${n}${ext}"
  fi
  # Non-existent files silently skipped (no error)
}

# --- PRD/test-spec per-US splitting helpers ---

split_prd_by_us() {
  local prd_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$prd_file")"

  [[ -f "$prd_file" ]] || return 0

  local us_count
  us_count=$(grep -c "^### US-" "$prd_file" 2>/dev/null) || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    echo "  WARNING: No US markers (### US-NNN:) found in PRD — falling back to full PRD injection" >&2
    # Clean up any stale per-US split files from previous runs to prevent stale artifacts
    local stale_count=0
    for stale in "$plans_dir"/prd-"$slug"-US-*.md(N); do
      rm "$stale"; stale_count=$(( stale_count + 1 ))
    done
    [[ $stale_count -gt 0 ]] && echo "  Cleaned $stale_count stale prd per-US file(s)"
    return 0
  fi

  awk -v dir="$plans_dir" -v slug="$slug" '
    /^### US-[0-9]+:/ {
      if (out != "") close(out)
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = dir "/prd-" slug "-" us_id ".md"
    }
    out != "" { print > out }
  ' "$prd_file"

  local count
  count=$(ls "$plans_dir"/prd-"$slug"-US-*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "  Split PRD: $count per-US files"
}

split_test_spec_by_us() {
  local ts_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$ts_file")"

  [[ -f "$ts_file" ]] || return 0

  local us_count
  us_count=$(grep -c "^## US-" "$ts_file" 2>/dev/null) || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    echo "  WARNING: No US section markers (## US-NNN:) in test-spec — skipping split" >&2
    # Clean up any stale per-US test-spec files from previous runs
    for stale in "$plans_dir"/test-spec-"$slug"-US-*.md(N); do
      rm "$stale"
    done
    return 0
  fi

  # Extract global header (everything before first ## US- section, e.g. Verification Commands)
  local header_tmp="${plans_dir}/test-spec-${slug}-header.tmp.$$"
  awk '/^## US-[0-9]+:/{exit} {print}' "$ts_file" > "$header_tmp"

  awk -v dir="$plans_dir" -v slug="$slug" '
    /^## US-[0-9]+:/ {
      if (out != "") close(out)
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = dir "/test-spec-" slug "-" us_id ".md"
    }
    out != "" { print > out }
  ' "$ts_file"

  # Prepend global header (Verification Commands etc.) to each split file
  for split_file in "$plans_dir"/test-spec-"$slug"-US-*.md; do
    [[ -f "$split_file" ]] || continue
    local tmp="${split_file}.tmp.$$"
    cat "$header_tmp" "$split_file" > "$tmp" && mv "$tmp" "$split_file"
  done
  rm -f "$header_tmp"

  local count
  count=$(ls "$plans_dir"/test-spec-"$slug"-US-*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "  Split test-spec: $count per-US files (with global header)"
}

# --- Run command presets ---
# Detects codex CLI availability and shows appropriate run command presets.
# AC1: codex installed → cross-engine preset first, spark Pro, claude-only, basic
# AC2: codex not installed → tmux + claude-only first, install recommendation
# AC3: full options reference with defaults always shown
print_run_presets() {
  local slug="$1"
  local codex_available=0
  command -v codex &>/dev/null && codex_available=1

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Available run commands (copy the one you want):"
  echo ""
  if [[ $codex_available -eq 1 ]]; then
    echo "# Recommended: cross-engine + final-consensus (full context + blind-spot coverage):"
    echo "/rlp-desk run $slug --worker-model gpt-5.4:medium --final-consensus --debug"
    echo ""
    echo "# Small tasks only (single-file, AC <= 4, simple logic — spark 100k context limit):"
    echo "/rlp-desk run $slug --worker-model gpt-5.3-codex-spark:high --debug"
    echo ""
    echo "# Claude-only:"
    echo "/rlp-desk run $slug --debug"
    echo ""
    echo "# Basic agent:"
    echo "/rlp-desk run $slug"
  else
    echo "# Recommended: tmux mode + claude-only (real-time visibility):"
    echo "/rlp-desk run $slug --mode tmux --debug"
    echo ""
    echo "# Agent mode:"
    echo "/rlp-desk run $slug --debug"
    echo ""
    echo "# Install codex for cost savings + cross-engine blind-spot coverage:"
    echo "npm install -g @openai/codex"
  fi
  echo ""
  echo "# Full options reference:"
  echo "#   --mode agent|tmux                (default: agent)"
  echo "#   --worker-model MODEL             haiku|sonnet|opus or gpt-5.4:low|medium|high (default: sonnet)"
  echo "#   --verifier-model MODEL           haiku|sonnet|opus (default: opus)"
  echo "#   --verify-consensus               both claude+codex must pass"
  echo "#   --verify-mode per-us|batch       (default: per-us)"
  echo "#   --max-iter N                     (default: 100)"
  echo "#   --debug                          enable debug logging"
  echo "#   --with-self-verification         post-campaign analysis report"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

echo "Initializing Ralph Desk: $SLUG"
echo "  Root: $ROOT"
echo "  Desk: $DESK"
[[ -n "$MODE" ]] && echo "  Mode: $MODE"
echo ""

mkdir -p "$DESK/prompts" "$DESK/context" "$DESK/memos" "$DESK/plans" "$DESK/logs/$SLUG"

# --- Re-execution lifecycle (--mode handling) ---
PRD_FILE="$DESK/plans/prd-$SLUG.md"
LOGS_DIR="$DESK/logs/$SLUG"

if [[ -n "$MODE" ]]; then
  echo "Re-execution mode: --mode $MODE"
  echo ""

  DELETED_COUNT=0

  # Version debug.log and campaign-report.md (NOT self-verification-report — uses -NNN)
  version_file "$LOGS_DIR/debug.log"
  version_file "$LOGS_DIR/campaign-report.md"

  # Delete iter-* artifacts (archived done-claims, verdicts, prompt logs, results)
  for f in "$LOGS_DIR"/iter-*(N); do
    [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
  done

  # Delete runtime memos
  for f in \
    "$DESK/memos/$SLUG-done-claim.json" \
    "$DESK/memos/$SLUG-iter-signal.json" \
    "$DESK/memos/$SLUG-verify-verdict.json" \
    "$DESK/memos/$SLUG-complete.md" \
    "$DESK/memos/$SLUG-blocked.md"; do
    [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
  done

  # Delete status.json, baseline.log, cost-log.jsonl
  for f in "$LOGS_DIR/runtime/status.json" "$LOGS_DIR/status.json" "$LOGS_DIR/baseline.log" "$LOGS_DIR/cost-log.jsonl"; do
    [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
  done

  # Delete test-spec only for fresh re-execution mode; improve preserves custom edits
  # and reruns split logic on the existing file.
  for f in \
    "$DESK/plans/test-spec-$SLUG.md" \
    "$DESK/prompts/$SLUG.worker.prompt.md" \
    "$DESK/prompts/$SLUG.verifier.prompt.md"; do
    [[ -f "$f" ]] &&
      if [[ "$MODE" == "fresh" ]] || [[ "$f" != "$DESK/plans/test-spec-$SLUG.md" ]]; then
        rm "$f"; (( ++DELETED_COUNT ));
      fi
  done

  # Reset memory and context to fresh templates (rm here; scaffold below regenerates them)
  rm -f "$DESK/memos/$SLUG-memory.md" "$DESK/context/$SLUG-latest.md"

  # PRD handling: --mode fresh deletes PRD; --mode improve preserves PRD in-place
  if [[ "$MODE" == "fresh" ]]; then
    [[ -f "$PRD_FILE" ]] && { rm "$PRD_FILE"; (( ++DELETED_COUNT )); echo "  Deleted: prd-$SLUG.md (--mode fresh: PRD deleted for fresh start)"; }
  fi

  # Re-execution summary
  echo "  Re-execution summary:"
  if [[ "$MODE" == "improve" ]]; then
    echo "  Preserved: prd-$SLUG.md (--mode improve: PRD kept in-place)"
  fi
  echo "  Deleted:   $DELETED_COUNT runtime artifacts"
  echo "  Reset:     memory.md + context.md (regenerating from templates)"
  echo ""
fi

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

## TDD MANDATE (hard constraint — violation = automatic FAIL)
> Write failing tests FIRST → confirm RED (exit_code=1) → implement minimum code → confirm GREEN.
> Every NEW AC requires: write_test → verify_red → implement → verify_green in execution_steps.
> No exceptions. Verifier rejects missing RED evidence. For already-passing ACs, use verify_existing.

## SCOPE LOCK (hard constraint — violation causes verification failure)
- You MUST only implement the work described in the "Next Iteration Contract" from campaign memory.
- If the contract says "implement US-001 only", do ONLY that. Do NOT touch other stories.
- If the contract says "implement all remaining stories", you may do all of them.
- Do NOT go beyond the contracted scope, even if you can see more work in the PRD.
- No file creation or modification outside the project root.
- Do not modify this prompt file or any PRD/test-spec files.

## Forbidden Shortcuts (Verifier will check these)
- Do not mock external services when L2 integration test is required by test-spec.
- Do not delete or weaken existing assertions to make tests pass.
- Do not skip boundary cases listed in the PRD.
- Do not write code before tests — if you did, delete it and start with tests.
- **NEVER modify rlp-desk infrastructure files** (~/.claude/ralph-desk/*, ~/.claude/commands/rlp-desk.md). If you discover a bug in rlp-desk itself, report it in done-claim.json with {"status": "blocked", "reason": "rlp-desk bug: <description>"} and signal blocked. Do NOT attempt to fix rlp-desk — it is the orchestration tool, not your project code.
- **NEVER modify Claude Code settings** (~/.claude/settings.json, .claude/settings.local.json, or any settings files). Do NOT add permissions, change models, or alter configuration. If a permission prompt blocks you, report it as blocked — do NOT try to edit settings to bypass it.

## When Stuck (do NOT guess-and-fix)
> 1. STOP and READ the error. Trace the call stack. Identify the root cause before touching code.
> 2. Write a minimal test that reproduces the failure, then fix the root cause only.
> 3. If 3+ fixes fail on the same issue, signal "blocked" with your diagnosis.

## Iteration rules
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly the work specified in the Next Iteration Contract.
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- Write evidence artifacts.
- **After writing tests, update test-spec Criteria Mapping with actual test file paths and function names** (replace placeholder -k filters).
- Ensure **each AC has >= 3 tests** (happy + negative + boundary). Do not just meet the total count — distribute evenly per AC.
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
execution_steps MUST be a JSON array of objects (not a dict with string keys). Each object MUST have: "step", "ac_id", "command", "exit_code", "summary".

## Stop behavior
- Single US achieved → write done-claim JSON to $DESK/memos/$SLUG-done-claim.json with the specific US, signal verify, exit
- All US achieved → write done-claim JSON with all US, signal verify with us_id "ALL", exit
- Autonomous blocker → write to $DESK/memos/$SLUG-blocked.md, exit
- Otherwise → set stop=continue, define next iteration contract in memory, exit

## Objective
$OBJECTIVE
EOF

  # Inject operational context if server options provided
  if [[ -n "$SERVER_CMD" || -n "$SERVER_PORT" ]]; then
    cat >> "$F" <<OPCTX

## Operational Context
$([ -n "$SERVER_CMD" ] && echo "- **Server Start Command**: \`$SERVER_CMD\`")
$([ -n "$SERVER_PORT" ] && echo "- **Server Port**: $SERVER_PORT")
$([ -n "$SERVER_HEALTH" ] && echo "- **Health Check URL**: $SERVER_HEALTH")

### Operational Rules (always apply when server context is present)
- After modifying server/application code, restart the server$([ -n "$SERVER_CMD" ] && echo ": \`$SERVER_CMD\`")
- Before signaling done, verify the server responds$([ -n "$SERVER_HEALTH" ] && echo ": \`curl -sf $SERVER_HEALTH\`" || [ -n "$SERVER_PORT" ] && echo ": \`curl -sf http://localhost:$SERVER_PORT/\`")
- Do NOT modify dependency files (package.json, requirements.txt, etc.) unless the AC explicitly requires it
- Do NOT run package install commands (npm install, pip install, etc.) unless the AC explicitly requires it
OPCTX
  fi

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
   **Skip detection (IL-5)**: After running tests, check output for "skip", "pending", "not run", or "0 items collected". Tests that did not actually execute do NOT count as passed. If test_count_executed < test_count_expected, verdict = FAIL ("skipped tests detected").
7. Check each criterion against fresh evidence (only for the scoped US, or all if us_id=ALL)
8. Run smoke test if defined in PRD
9. **Test Sufficiency (IL-4)**: count test functions exercising each AC. Count < 3 per AC = FAIL.
   Check diversity: at least 2 of 3 categories (happy, negative, boundary) per AC.
10. **Anti-Gaming Detection**:
   - Assertion integrity: compare assertion count/strength via \`git diff HEAD~1\` — assertions not deleted or weakened
   - Test-specific logic: no environment-detection patterns
   - "Code inspection" claims: Worker must run actual commands
   - Tautological tests: expected values that mirror implementation logic
10¼. **Anti-Rubber-Stamp Self-Check**:
   - If your verdict history shows a 100% pass rate, re-examine your last verdict with increased scrutiny — a 100% pass rate is a red flag for insufficient rigor
   - When issuing PASS with explicit warning: note any concerning patterns (e.g., low test diversity, marginal coverage) even if technically passing
   - Never issue a silent PASS — every pass verdict must cite specific evidence for each AC checked
   - Rationalization red flags: "tests pass so it works" (passing ≠ correct), "Worker is confident" (confidence ≠ evidence), "changes are minimal" (scope ≠ correctness)
10½. **Worker Process Audit**:
   - Test-first compliance: done-claim execution_steps must show write_test step before implement step for each AC
   - RED phase evidence: at least one verify_red step with exit_code=1 per AC (proves tests were written before passing)
   - Forbidden shortcuts: check done-claim claims and summary for forbidden phrases ("code inspection", "I'm confident", "too simple", "I'll test after", "already manually tested", "partial check")
   - Step completeness: each AC should have write_test → verify_red → implement → verify_green sequence in execution_steps
11. **Reproducibility check**: verify lock file committed, clean install succeeds, security scan passes, env vars documented (per test-spec Reproducibility Gate). Skip if test-spec says "N/A."
12. Write verdict JSON to: $DESK/memos/$SLUG-verify-verdict.json

Verdict JSON:
{
  "verdict": "pass|fail|request_info",
  "us_id": "US-NNN or ALL (matches the scope you verified)",
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "per_us_results": {"US-001": "pass|fail|not_started", "US-002": "pass|fail|not_started"},
  "criteria_results": [{"criterion":"...","met":true/false,"evidence":"..."}],
  "missing_evidence": [],
  "issues": [{"id":"...","severity":"critical|major|minor","description":"...","fix_hint":"(suggestion, non-authoritative)"}],
  "reasoning": [
    {"check": "IL-1 Evidence Gate", "decision": "pass|fail", "basis": "what command was run, what output confirmed the decision"},
    {"check": "Layer Enforcement", "decision": "pass|fail", "basis": "which layers checked, any TODO found"},
    {"check": "Test Sufficiency", "decision": "pass|fail", "basis": "test count per AC, category coverage"},
    {"check": "Anti-Gaming", "decision": "pass|fail", "basis": "what was checked, any suspicious patterns"},
    {"check": "Worker Process Audit", "decision": "pass|fail", "basis": "test-first followed: verify_red present per AC, no forbidden shortcuts in claims, execution_steps complete"}
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
- **ALWAYS include per_us_results** in verdict JSON — map each US to "pass", "fail", or "not_started". This is required for partial progress tracking in both batch and per-us modes.
EOF

  # Inject operational verification if server options provided
  if [[ -n "$SERVER_CMD" || -n "$SERVER_PORT" ]]; then
    cat >> "$F" <<OPVER

## Operational Verification (server context present)
- Before verifying ACs, check that the server is running$([ -n "$SERVER_PORT" ] && echo " on port $SERVER_PORT")$([ -n "$SERVER_HEALTH" ] && echo ": \`curl -sf $SERVER_HEALTH\`")
- If the server is not running, verdict = FAIL with issue: "server not running on expected port"
- If Worker modified server code but did not restart the server, verdict = FAIL with issue: "server not restarted after code change"
OPVER
  fi

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

# Split PRD into per-US files (no-op with warning if no US markers)
split_prd_by_us "$DESK/plans/prd-$SLUG.md" "$SLUG"

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
Must cover ALL AC types: happy path + boundary + error path.
- **Happy path input**: TODO (specific test data)
- **Happy path expected output**: TODO (quantitative value)
- **Happy path command**:
\`\`\`bash
# TODO — E2E happy path command
\`\`\`
- **Error path input**: TODO (invalid/boundary input that triggers error)
- **Error path expected**: TODO (error type + non-zero exit code)
- **Error path command**:
\`\`\`bash
# TODO — E2E error path command (expected exit ≠ 0)
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

# Split test-spec into per-US files (no-op with warning if no US section markers)
split_test_spec_by_us "$DESK/plans/test-spec-$SLUG.md" "$SLUG"

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

# --- Claude Code sensitive-file permissions for .claude/ralph-desk/ ---
# Worker/Verifier need Read/Edit/Write access to .claude/ralph-desk/ files.
# --dangerously-skip-permissions does NOT cover "sensitive file" access for .claude/ paths.
# Without these, every file operation triggers an interactive permission prompt that blocks automation.
SETTINGS_FILE="$ROOT/.claude/settings.local.json"
PERM_MARKER="Read(.claude/ralph-desk/**)"

if [[ -f "$SETTINGS_FILE" ]] && grep -qF "$PERM_MARKER" "$SETTINGS_FILE" 2>/dev/null; then
  echo "  · .claude/settings.local.json (rlp-desk permissions already present)"
else
  PERMS='["Read(.claude/ralph-desk/**)", "Edit(.claude/ralph-desk/**)", "Write(.claude/ralph-desk/**)"]'

  if [[ -f "$SETTINGS_FILE" ]]; then
    if command -v jq &>/dev/null; then
      jq --argjson perms "$PERMS" '
        .permissions //= {} |
        .permissions.allow //= [] |
        .permissions.allow += ($perms - .permissions.allow)
      ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      echo "  + .claude/settings.local.json (rlp-desk permissions merged)"
    else
      echo "  ⚠ jq not found. Add to .claude/settings.local.json manually:"
      echo "    permissions.allow: Read/Edit/Write(.claude/ralph-desk/**)"
    fi
  else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" <<'SETEOF'
{
  "permissions": {
    "allow": [
      "Read(.claude/ralph-desk/**)",
      "Edit(.claude/ralph-desk/**)",
      "Write(.claude/ralph-desk/**)"
    ]
  }
}
SETEOF
    echo "  + .claude/settings.local.json (created with rlp-desk permissions)"
  fi
  echo ""
  echo "  NOTE: Added Read/Edit/Write permissions for .claude/ralph-desk/ to"
  echo "        .claude/settings.local.json (local, not committed to git)."
  echo "        This prevents Worker/Verifier from being blocked by Claude Code's"
  echo "        sensitive-file prompts during automated loop execution."
  echo "        See: https://github.com/ai-dev-methodologies/rlp-desk#project-structure"
fi

# --- Post-init validation gate ---
INIT_FAIL=0
for REQUIRED_FILE in \
  "$DESK/prompts/$SLUG.worker.prompt.md" \
  "$DESK/prompts/$SLUG.verifier.prompt.md" \
  "$DESK/context/$SLUG-latest.md" \
  "$DESK/memos/$SLUG-memory.md" \
  "$DESK/plans/prd-$SLUG.md" \
  "$DESK/plans/test-spec-$SLUG.md"; do
  if [[ ! -f "$REQUIRED_FILE" ]]; then
    echo "  ✗ MISSING: $REQUIRED_FILE"
    INIT_FAIL=1
  fi
done
if [[ $INIT_FAIL -eq 1 ]]; then
  echo ""
  echo "ERROR: Scaffold incomplete. Some required files were not created."
  echo "Re-run init or check filesystem permissions."
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Scaffold ready: $SLUG"
echo ""
echo "Next:"
echo "  1. Edit PRD:       $DESK/plans/prd-$SLUG.md"
echo "  2. Edit test spec: $DESK/plans/test-spec-$SLUG.md"
echo "  3. Run (copy a command below):"
echo ""
print_run_presets "$SLUG"
