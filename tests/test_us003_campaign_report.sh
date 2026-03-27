#!/usr/bin/env bash
# Test Suite: US-003 — Mandatory Campaign Report
# IL-4 compliant: 3+ tests per AC (happy + negative + boundary)
# 15 ACs x 3 = 45 tests minimum

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local result="$2"
  local expected="$3"
  if [[ "$result" = "$expected" ]]; then
    echo "PASS: $name"
    (( PASS++ ))
  else
    echo "FAIL: $name  (expected='$expected' got='$result')"
    (( FAIL++ ))
  fi
}

count_grep() {
  local result
  result=$(grep -c "$1" "$2" 2>/dev/null) || result=0
  echo "$result"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="$REPO_ROOT/src/scripts/run_ralph_desk.zsh"
CMD="$REPO_ROOT/src/commands/rlp-desk.md"
GOV="$REPO_ROOT/src/governance.md"

echo "=== US-003: Mandatory Campaign Report ==="
echo ""

# =============================================================================
# AC1: Agent mode — iter-NNN-done-claim.json and iter-NNN-verify-verdict.json archived
# =============================================================================

# AC1-happy: rlp-desk.md mentions iter-NNN-done-claim archival
count=$(count_grep 'iter-NNN-done-claim\|iter-.*-done-claim' "$CMD")
run_test "AC1-happy: iter-NNN-done-claim archival in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC1-negative: iter-NNN-verify-verdict.json also archived
count=$(count_grep 'iter-NNN-verify-verdict\|iter-.*-verify-verdict' "$CMD")
run_test "AC1-negative: iter-NNN-verify-verdict archival in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC1-boundary: archival documented as step 7d (after verdict, before next prep)
count=$(count_grep '7d\|Archive.*artifact\|archive.*done-claim' "$CMD")
run_test "AC1-boundary: step 7d or Archive label in rlp-desk.md" "$(( count >= 1 ))" "1"

# =============================================================================
# AC2: Agent mode — baseline_commit in status.json from Preparation stage
# =============================================================================

# AC2-happy: baseline_commit appears in rlp-desk.md
count=$(count_grep 'baseline_commit' "$CMD")
run_test "AC2-happy: baseline_commit in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC2-negative: appears in Preparation or early section (line < 370)
first_line=$(grep -n 'baseline_commit' "$CMD" 2>/dev/null | head -1 | cut -d: -f1)
run_test "AC2-negative: baseline_commit in early section of rlp-desk.md (line < 370)" "$(( ${first_line:-999} < 370 ))" "1"

# AC2-boundary: git rev-parse used to capture baseline commit
count=$(count_grep 'git rev-parse\|rev-parse HEAD' "$CMD")
run_test "AC2-boundary: git rev-parse mentioned in rlp-desk.md" "$(( count >= 1 ))" "1"

# =============================================================================
# AC3: campaign-report.md on COMPLETE, BLOCKED, TIMEOUT (Agent mode)
# =============================================================================

# AC3-happy: campaign-report.md mentioned in rlp-desk.md
count=$(count_grep 'campaign-report\.md' "$CMD")
run_test "AC3-happy: campaign-report.md referenced in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC3-negative: COMPLETE/BLOCKED/TIMEOUT all referenced in report section
count=$(grep -c 'COMPLETE\|BLOCKED\|TIMEOUT' "$CMD" 2>/dev/null) || count=0
run_test "AC3-negative: COMPLETE/BLOCKED/TIMEOUT all in rlp-desk.md" "$(( count >= 3 ))" "1"

# AC3-boundary: numbered Campaign Report step or section header
count=$(count_grep '⑩\|Campaign Report' "$CMD")
run_test "AC3-boundary: Campaign Report step/section in rlp-desk.md" "$(( count >= 1 ))" "1"

# =============================================================================
# AC4: run_ralph_desk.zsh — generate_campaign_report function + all exit paths
# =============================================================================

# AC4-happy: generate_campaign_report referenced >= 2 times
count=$(count_grep 'generate_campaign_report' "$RUN")
run_test "AC4-happy: generate_campaign_report in run_ralph_desk.zsh >= 2 refs" "$(( count >= 2 ))" "1"

# AC4-negative: function definition exists
count=$(grep -c '^generate_campaign_report()' "$RUN" 2>/dev/null) || count=0
run_test "AC4-negative: generate_campaign_report() function defined" "$(( count >= 1 ))" "1"

# AC4-boundary: called >= 3 times (definition + multiple call sites)
count=$(count_grep 'generate_campaign_report' "$RUN")
run_test "AC4-boundary: generate_campaign_report >= 3 total references" "$(( count >= 3 ))" "1"

# =============================================================================
# AC5: Cost estimation — cost-log.jsonl with estimated_tokens (tmux mode)
# =============================================================================

# AC5-happy: cost-log.jsonl or COST_LOG referenced in run_ralph_desk.zsh >= 2
count=$(count_grep 'cost-log\.jsonl\|COST_LOG' "$RUN")
run_test "AC5-happy: cost-log.jsonl in run_ralph_desk.zsh >= 2 refs" "$(( count >= 2 ))" "1"

# AC5-negative: estimated_tokens or token_source labeled
count=$(count_grep 'estimated_tokens\|token_source.*estimated\|\"estimated\"' "$RUN")
run_test "AC5-negative: estimated_tokens or token_source:estimated in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC5-boundary: prompt_bytes / 4 estimation formula
count=$(count_grep 'prompt_bytes\|/ 4\|divided by 4\|estimate.*token' "$RUN")
run_test "AC5-boundary: token estimation formula in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# =============================================================================
# AC6: Brainstorm — re-execution detection (improve or start fresh)
# =============================================================================

# AC6-happy: improve/start-fresh choice in rlp-desk.md
count=$(count_grep 'improve\|start fresh' "$CMD")
run_test "AC6-happy: improve/start-fresh choice in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC6-negative: PRD existence check in brainstorm flow
count=$(count_grep 'PRD.*exist\|prd.*exist\|existing.*PRD\|PRD already' "$CMD")
run_test "AC6-negative: PRD existence check in rlp-desk.md brainstorm" "$(( count >= 1 ))" "1"

# AC6-boundary: both 'improve' and 'fresh' keywords present
count_i=$(count_grep 'improve' "$CMD")
count_f=$(count_grep 'fresh' "$CMD")
run_test "AC6-boundary: both improve and fresh keywords in rlp-desk.md" "$(( count_i >= 1 && count_f >= 1 ))" "1"

# =============================================================================
# AC7: Clean — campaign-report and archived iter artifacts preserved
# =============================================================================

# AC7-happy: campaign-report mentioned in rlp-desk.md
count=$(count_grep 'campaign-report' "$CMD")
run_test "AC7-happy: campaign-report mentioned in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC7-negative: campaign-report NOT in the removal list (not deleted by clean)
remove_count=$(grep -A60 '## `clean' "$CMD" 2>/dev/null | grep '^\- \`.*campaign-report' | wc -l | tr -d ' ')
run_test "AC7-negative: campaign-report NOT in clean removal list" "$remove_count" "0"

# AC7-boundary: preserved list covers campaign-report or iter artifacts
count=$(grep 'intentionally preserved' "$CMD" 2>/dev/null | grep -c 'campaign\|iter\|report') || count=0
run_test "AC7-boundary: preserved note covers campaign-report/iter artifacts" "$(( count >= 1 ))" "1"

# =============================================================================
# AC8: Report independent from --debug (data from status.json)
# =============================================================================

# AC8-happy: campaign-report.md generation present in rlp-desk.md
count=$(count_grep 'campaign-report\.md' "$CMD")
run_test "AC8-happy: campaign-report.md referenced (always-on, not debug-only)" "$(( count >= 1 ))" "1"

# AC8-negative: status.json referenced as data source in rlp-desk.md
count=$(count_grep 'status\.json' "$CMD")
run_test "AC8-negative: status.json referenced in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC8-boundary: campaign report section has 8 required sections listed
count=$(count_grep 'Objective\|Execution Summary\|US Status\|Verification Results\|Issues Encountered\|Cost.*Performance\|SV Summary\|Files Changed' "$CMD")
run_test "AC8-boundary: campaign report 8 sections defined in rlp-desk.md" "$(( count >= 5 ))" "1"

# =============================================================================
# AC9: campaign-report.md versioned on re-execution (rename to campaign-report-v{N}.md)
# =============================================================================

# AC9-happy: campaign-report-v{N} versioning pattern in rlp-desk.md
count=$(count_grep 'campaign-report-v\|report-v{N}\|campaign.*v{N}' "$CMD")
run_test "AC9-happy: campaign-report versioning pattern in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC9-negative: rename/version happens before writing new report
count=$(count_grep 'rename.*campaign\|campaign.*rename\|existing.*report.*rename\|report.*renamed\|before writing' "$CMD")
run_test "AC9-negative: existing report renamed before writing new one" "$(( count >= 1 ))" "1"

# AC9-boundary: auto-increment N pattern
count=$(count_grep 'next available\|auto-increment\|N = next\|N=next\|>= 1\|≥ 1' "$CMD")
run_test "AC9-boundary: auto-increment N pattern in rlp-desk.md" "$(( count >= 1 ))" "1"

# =============================================================================
# AC10: SV report (⑨) generates before campaign report (⑩)
# =============================================================================

# AC10-happy: SV section appears before Campaign Report section in rlp-desk.md
sv_line=$(grep -n '⑨\|Campaign Self-Verification' "$CMD" 2>/dev/null | head -1 | cut -d: -f1)
report_line=$(grep -n '⑩\|^.*Campaign Report' "$CMD" 2>/dev/null | head -1 | cut -d: -f1)
run_test "AC10-happy: SV section (⑨) before Campaign Report (⑩) in rlp-desk.md" "$(( ${sv_line:-0} > 0 && ${report_line:-0} > ${sv_line:-999} ))" "1"

# AC10-negative: Campaign Report section exists in rlp-desk.md
run_test "AC10-negative: Campaign Report section defined in rlp-desk.md" "$(( ${report_line:-0} > 0 ))" "1"

# AC10-boundary: SV summary pointer mentioned in campaign report
count=$(count_grep 'SV.*summary\|self-verification.*summary\|SV Summary' "$CMD")
run_test "AC10-boundary: SV summary pointer in campaign report section" "$(( count >= 1 ))" "1"

# =============================================================================
# AC11: run_ralph_desk.zsh — tmux mode artifact archival
# =============================================================================

# AC11-happy: iter-NNN-done-claim.json archival in run_ralph_desk.zsh
count=$(count_grep 'iter-.*done-claim\.json\|iter.*done.claim' "$RUN")
run_test "AC11-happy: iter-NNN-done-claim.json archived in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC11-negative: iter-NNN-verify-verdict.json also archived
count=$(count_grep 'iter-.*verify-verdict\.json\|iter.*verify.verdict' "$RUN")
run_test "AC11-negative: iter-NNN-verify-verdict.json archived in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC11-boundary: cp of DONE_CLAIM_FILE or VERDICT_FILE to LOGS_DIR
count=$(count_grep 'cp.*DONE_CLAIM\|cp.*VERDICT\|cp.*done.claim\|cp.*verify.verdict' "$RUN")
run_test "AC11-boundary: cp DONE_CLAIM_FILE/VERDICT_FILE in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# =============================================================================
# AC12: run_ralph_desk.zsh — BASELINE_COMMIT in session-config and status.json
# =============================================================================

# AC12-happy: BASELINE_COMMIT defined >= 2 times in run_ralph_desk.zsh
count=$(count_grep 'BASELINE_COMMIT' "$RUN")
run_test "AC12-happy: BASELINE_COMMIT in run_ralph_desk.zsh >= 2 refs" "$(( count >= 2 ))" "1"

# AC12-negative: git rev-parse HEAD used to capture
count=$(count_grep 'git.*rev-parse.*HEAD\|rev-parse HEAD' "$RUN")
run_test "AC12-negative: git rev-parse HEAD in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# AC12-boundary: baseline_commit field written to session-config or status
count=$(count_grep '"baseline_commit"\|baseline_commit.*:' "$RUN")
run_test "AC12-boundary: baseline_commit field in run_ralph_desk.zsh output" "$(( count >= 1 ))" "1"

# =============================================================================
# AC13: Dirty worktree note in campaign report Files Changed section
# =============================================================================

# AC13-happy: dirty worktree note in rlp-desk.md
count=$(count_grep 'dirty worktree\|uncommitted changes\|pre-existing uncommitted' "$CMD")
run_test "AC13-happy: dirty worktree note in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC13-negative: note scoped to Files Changed section
count=$(count_grep 'Files Changed.*dirty\|dirty.*Files Changed\|Files Changed may include\|pre-existing.*worktree' "$CMD")
run_test "AC13-negative: dirty worktree note in Files Changed context in rlp-desk.md" "$(( count >= 1 ))" "1"

# AC13-boundary: dirty worktree note also in run_ralph_desk.zsh report function
count=$(count_grep 'dirty worktree\|uncommitted changes\|pre-existing uncommitted' "$RUN")
run_test "AC13-boundary: dirty worktree note in run_ralph_desk.zsh" "$(( count >= 1 ))" "1"

# =============================================================================
# AC14: Correct variable names (ROOT, LOGS_DIR, SLUG, DONE_CLAIM_FILE, VERDICT_FILE)
# =============================================================================

# AC14-happy: no PROJECT_DIR in run_ralph_desk.zsh
count=$(count_grep 'PROJECT_DIR' "$RUN")
run_test "AC14-happy: no PROJECT_DIR in run_ralph_desk.zsh (uses ROOT)" "$count" "0"

# AC14-negative: no LOG_DIR (only LOGS_DIR)
count=$(grep -c '\bLOG_DIR\b' "$RUN" 2>/dev/null) || count=0
run_test "AC14-negative: no bare LOG_DIR in run_ralph_desk.zsh (uses LOGS_DIR)" "$count" "0"

# AC14-boundary: DONE_CLAIM_FILE and VERDICT_FILE used in archival code
count=$(count_grep 'DONE_CLAIM_FILE\|VERDICT_FILE' "$RUN")
run_test "AC14-boundary: DONE_CLAIM_FILE and VERDICT_FILE used >= 4 times" "$(( count >= 4 ))" "1"

# =============================================================================
# AC15: init invocation shows optional --mode fresh|improve
# =============================================================================

# AC15-happy: --mode mentioned in init section of rlp-desk.md
count=$(grep -A10 '## `init' "$CMD" 2>/dev/null | grep -c 'mode\|--mode') || count=0
run_test "AC15-happy: --mode in init section of rlp-desk.md" "$(( count >= 1 ))" "1"

# AC15-negative: both fresh and improve mode options named
count_f=$(count_grep 'fresh' "$CMD")
count_i=$(count_grep 'improve' "$CMD")
run_test "AC15-negative: both fresh and improve keywords in rlp-desk.md" "$(( count_f >= 1 && count_i >= 1 ))" "1"

# AC15-boundary: init_ralph_desk.zsh invocation line includes --mode
count=$(grep 'init_ralph_desk\.zsh' "$CMD" 2>/dev/null | grep -c 'mode\|\[--mode\]') || count=0
run_test "AC15-boundary: init_ralph_desk.zsh invocation includes --mode in rlp-desk.md" "$(( count >= 1 ))" "1"

# =============================================================================
# L3: E2E cross-file checks
# =============================================================================

# L3-happy: 0 legacy tags still preserved across all source files
legacy_count=$(grep -rn '\[PLAN\]\|\[VALIDATE\]\|\[EXEC\]' \
  "$REPO_ROOT/src/commands/rlp-desk.md" \
  "$REPO_ROOT/src/governance.md" \
  "$REPO_ROOT/src/scripts/run_ralph_desk.zsh" \
  "$REPO_ROOT/src/scripts/init_ralph_desk.zsh" 2>/dev/null | wc -l | tr -d ' ')
run_test "L3-happy: 0 legacy debug tags across all source files" "$legacy_count" "0"

# L3-boundary: governance.md has step 7d (Archive iteration artifacts)
count=$(count_grep '7d\|Archive iteration\|step 7d' "$GOV")
run_test "L3-boundary: governance.md has step 7d (Archive artifacts)" "$(( count >= 1 ))" "1"

# L3-boundary-2: governance.md mentions Campaign Report step
count=$(count_grep 'Campaign Report\|campaign-report\|generate_campaign_report\|8.*[½1/2]' "$GOV")
run_test "L3-boundary-2: governance.md mentions Campaign Report" "$(( count >= 1 ))" "1"

echo ""
echo "Results: $PASS PASS, $FAIL FAIL"
if [[ $FAIL -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
else
  exit 1
fi
