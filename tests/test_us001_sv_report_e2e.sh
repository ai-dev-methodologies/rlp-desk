#!/usr/bin/env bash
# Test Suite: US-001 E2E Harness — generate_sv_report() runtime scenarios
# Executes the actual function and inspects produced files.
# Scenarios: success, no-flag, missing-claude, rerun/versioning, timeout, distinct-dirs

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

PASS=0; FAIL=0
SCENARIO_N=0
CURRENT_TMPDIR=""

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# ---------------------------------------------------------------------------
# Extract generate_sv_report() using awk brace-depth tracking
# ---------------------------------------------------------------------------
_extract_generate_sv_report() {
  local src="$1"
  awk '
    /^generate_sv_report\(\) \{/ { in_fn=1; depth=0 }
    in_fn {
      line = $0
      for (i=1; i<=length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$src"
}
FUNC_BODY="$(_extract_generate_sv_report "$RUN")"
if [[ -z "$FUNC_BODY" ]]; then
  FUNC_BODY="$(_extract_generate_sv_report "$LIB")"
fi

if [[ -z "$FUNC_BODY" ]]; then
  echo "FATAL: could not extract generate_sv_report() from $RUN"
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# setup_scenario must be called WITHOUT $() to avoid subshell scoping issue
# Result is in $CURRENT_TMPDIR
setup_scenario() {
  SCENARIO_N=$((SCENARIO_N+1))
  CURRENT_TMPDIR="$TMPBASE/s${SCENARIO_N}"
  mkdir -p "$CURRENT_TMPDIR/logs" "$CURRENT_TMPDIR/bin"
  echo "# Campaign Report" > "$CURRENT_TMPDIR/logs/campaign-report.md"
}

write_mock_claude_ok() {
  cat > "$1/claude" << 'MOCK'
#!/bin/bash
cat << 'REPORT'
## 1. Automated Validation Summary
All 15 tests passed. 0 failures.
## 2. Failure Deep Dive
No failures recorded in this campaign.
## 3. Worker Process Quality
Worker executed all steps with execution_steps recorded.
## 4. Verifier Judgment Quality
Verifier applied all governance checks.
## 5. AC Lifecycle
All acceptance criteria completed and verified.
## 6. Test-Spec Adherence
Test specification followed. All required layers covered.
## 7. Patterns: Strengths & Weaknesses
Strengths: comprehensive test coverage.
## 8. Recommendations for Next Cycle
Continue current practices.
## 9. Cost & Performance
N/A — no cost data in test environment.
## 10. Blind Spots
None identified in this test run.
REPORT
MOCK
  chmod +x "$1/claude"
}


write_mock_claude_sleep() {
  printf '#!/bin/bash\nsleep 10\n' > "$1/claude"
  chmod +x "$1/claude"
}

run_sv_function() {
  local tmpdir="$1" with_sv="$2" scenario_path="$3" timeout_override="${4:-}"
  local logs="$tmpdir/logs"

  # Write header (bash expands $tmpdir, $logs, $with_sv here — intentional)
  cat > "$tmpdir/run.zsh" << EOF
WITH_SELF_VERIFICATION=$with_sv
SV_REPORT_GENERATED=0
LOGS_DIR="$logs"
ANALYTICS_DIR="$logs"
SLUG="test-campaign"
DESK="$tmpdir"
DEBUG=0
${timeout_override:+_SV_TIMEOUT_SECS=$timeout_override}

log() { :; }

EOF
  # Append function body literally (no bash expansion of $ inside function)
  printf '%s\n' "$FUNC_BODY" >> "$tmpdir/run.zsh"
  echo "generate_sv_report" >> "$tmpdir/run.zsh"

  PATH="$scenario_path" zsh -f "$tmpdir/run.zsh" >/dev/null 2>&1
}

echo "=== US-001 E2E Harness: generate_sv_report() runtime scenarios ==="
echo ""

# ---------------------------------------------------------------------------
# S1: success — WITH_SV=1, claude found → sv report created with content
# ---------------------------------------------------------------------------
echo "--- S1: success path ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
write_mock_claude_ok "$tmpdir/bin"
run_sv_function "$tmpdir" 1 "$tmpdir/bin:$PATH"

report_file="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | head -1)"
if [[ -f "$report_file" ]]; then
  pass "S1: sv report file created on success"
else
  fail "S1: sv report file not found after success run"
fi
if grep -q "## 1\. Automated Validation Summary" "$report_file" 2>/dev/null; then
  pass "S1: sv report file contains claude output"
else
  fail "S1: sv report file empty or missing content"
fi
if grep -q "See:.*self-verification-report" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S1: campaign-report updated with sv report reference"
else
  fail "S1: campaign-report not updated with sv report reference"
fi
header_count="$(grep -c '^## [0-9]' "$report_file" 2>/dev/null || echo 0)"
if [[ "$header_count" -ge 10 ]]; then
  pass "S1: sv report contains all 10 required section headers (got $header_count)"
else
  fail "S1: sv report missing required headers (got $header_count, need 10)"
fi

# ---------------------------------------------------------------------------
# S2: no-flag — WITH_SV=0 → function returns early, no sv report created
# ---------------------------------------------------------------------------
echo "--- S2: no-flag path ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
run_sv_function "$tmpdir" 0 "$PATH"

count="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  pass "S2: no sv report created when WITH_SELF_VERIFICATION=0"
else
  fail "S2: sv report unexpectedly created (count=$count)"
fi
line_count="$(wc -l < "$logs/campaign-report.md" | tr -d ' ')"
if [[ "$line_count" -le 1 ]]; then
  pass "S2: campaign-report not modified when flag absent"
else
  fail "S2: campaign-report unexpectedly modified (lines=$line_count)"
fi

# ---------------------------------------------------------------------------
# S3: missing-claude — no claude in PATH → error appended to campaign-report
# ---------------------------------------------------------------------------
echo "--- S3: missing-claude path ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
# Restrict PATH to minimal system dirs to exclude any real claude install
run_sv_function "$tmpdir" 1 "$tmpdir/bin:/usr/bin:/bin"
s3_exit=$?

if grep -q "claude CLI not found\|claude.*not found" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S3: error message appended to campaign-report when claude missing"
else
  fail "S3: error message not found in campaign-report"
fi
count="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  pass "S3: no sv report file created when claude missing"
else
  fail "S3: sv report unexpectedly created when claude missing"
fi
if [[ "$s3_exit" -eq 0 ]]; then
  pass "S3: generate_sv_report exits 0 when claude missing (terminal-status preserved)"
else
  fail "S3: generate_sv_report exited $s3_exit (expected 0, terminal-status violation)"
fi

# ---------------------------------------------------------------------------
# S4: rerun/versioning — report-001 exists → creates report-002
# ---------------------------------------------------------------------------
echo "--- S4: rerun/versioning ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
echo "existing report" > "$logs/self-verification-report-001.md"
write_mock_claude_ok "$tmpdir/bin"
run_sv_function "$tmpdir" 1 "$tmpdir/bin:$PATH"

if [[ -f "$logs/self-verification-report-002.md" ]]; then
  pass "S4: creates report-002.md when report-001.md already exists"
else
  fail "S4: report-002.md not created"
fi
if grep -q "existing report" "$logs/self-verification-report-001.md" 2>/dev/null; then
  pass "S4: existing report-001.md preserved (not overwritten)"
else
  fail "S4: report-001.md was deleted or overwritten"
fi

# ---------------------------------------------------------------------------
# S5: timeout — mock claude sleeps, _SV_TIMEOUT_SECS=1 → in-process watchdog kills it
# ---------------------------------------------------------------------------
echo "--- S5: timeout path ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
write_mock_claude_sleep "$tmpdir/bin"
run_sv_function "$tmpdir" 1 "$tmpdir/bin:$PATH" 1  # _SV_TIMEOUT_SECS=1

timeout_report="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | head -1)"
if [[ -n "$timeout_report" && -f "$timeout_report" ]]; then
  if grep -q "exceeded.*s\|TIMEOUT" "$timeout_report" 2>/dev/null; then
    pass "S5: timeout message written to sv report file"
  else
    fail "S5: sv report file exists but missing timeout message"
  fi
else
  fail "S5: no sv report file created on timeout path"
fi
if grep -q "TIMEOUT\|exceeded.*s" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S5: timeout message appended to campaign-report"
else
  fail "S5: campaign-report missing timeout entry"
fi

# ---------------------------------------------------------------------------
# Helper: run_mini_cleanup — simulate full cleanup path (campaign-report + sv report)
# Writes an initial campaign-report.md (as generate_campaign_report would), then
# calls generate_sv_report to prove the combined terminal-state contract.
# ---------------------------------------------------------------------------
run_mini_cleanup() {
  local tmpdir="$1" with_sv="$2" scenario_path="$3" timeout_override="${4:-}"
  local logs="$tmpdir/logs"

  # Simulate generate_campaign_report's SV Summary section
  local sv_marker
  if [[ "$with_sv" == "1" ]]; then
    sv_marker="SV report generation pending — will be appended after this report."
  else
    sv_marker="N/A — --with-self-verification not enabled"
  fi

  cat > "$logs/campaign-report.md" << EOF
# Campaign Report: test-campaign

Generated: $(date -u) | Status: COMPLETE | Iterations: 1

## SV Summary
$sv_marker
EOF

  cat > "$tmpdir/run.zsh" << EOF2
WITH_SELF_VERIFICATION=$with_sv
SV_REPORT_GENERATED=0
LOGS_DIR="$logs"
SLUG="test-campaign"
DESK="$tmpdir"
DEBUG=0
${timeout_override:+_SV_TIMEOUT_SECS=$timeout_override}

log() { :; }

EOF2
  printf '%s\n' "$FUNC_BODY" >> "$tmpdir/run.zsh"
  echo "generate_sv_report" >> "$tmpdir/run.zsh"

  PATH="$scenario_path" zsh -f "$tmpdir/run.zsh" >/dev/null 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# S6: full cleanup path, no-flag — AC3 terminal-state contract
# campaign-report pre-exists with "not enabled"; generate_sv_report WITH_SV=0
# must: no sv report created, report unchanged, exit 0
# ---------------------------------------------------------------------------
echo "--- S6: full cleanup path, no-flag (AC3 terminal contract) ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
run_mini_cleanup "$tmpdir" 0 "$PATH"
s6_exit=$?

count="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  pass "S6: no sv report created on no-flag cleanup path"
else
  fail "S6: sv report unexpectedly created (count=$count)"
fi
if grep -q "not enabled\|N/A" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S6: campaign-report retains 'not enabled' text (AC3 contract)"
else
  fail "S6: campaign-report missing 'not enabled' text"
fi
if [[ "$s6_exit" -eq 0 ]]; then
  pass "S6: full cleanup exits 0 on no-flag path (terminal-state preserved)"
else
  fail "S6: full cleanup exited $s6_exit (expected 0)"
fi

# ---------------------------------------------------------------------------
# S7: full cleanup path, missing-claude — AC4 terminal-state contract
# campaign-report pre-exists; generate_sv_report WITH_SV=1, no claude in PATH
# must: error appended to campaign-report, no sv report file, exit 0
# ---------------------------------------------------------------------------
echo "--- S7: full cleanup path, missing-claude (AC4 terminal contract) ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
run_mini_cleanup "$tmpdir" 1 "$tmpdir/bin:/usr/bin:/bin"
s7_exit=$?

if grep -q "claude CLI not found\|claude.*not found" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S7: error appended to campaign-report when claude missing (AC4 contract)"
else
  fail "S7: campaign-report missing error message"
fi
if [[ "$s7_exit" -eq 0 ]]; then
  pass "S7: full cleanup exits 0 when claude missing (terminal-status preserved)"
else
  fail "S7: full cleanup exited $s7_exit (should be 0)"
fi
count="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  pass "S7: no sv report file created when claude missing"
else
  fail "S7: sv report unexpectedly created when claude missing"
fi

# ---------------------------------------------------------------------------
# S8: runner-level startup-to-cleanup path — codex-only engines, no claude
# Exercises check_dependencies() [startup] then generate_sv_report() [cleanup]
# to verify AC4's end-to-end path, not just extracted function body.
# ---------------------------------------------------------------------------
echo "--- S8: runner-level startup-to-cleanup (AC4 codex-only, no claude) ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
echo "# Campaign Report" > "$logs/campaign-report.md"

# Build minimal PATH: mock stubs for tmux/jq/codex — NO claude
for stub in tmux jq codex; do
  printf '#!/bin/bash\nexit 0\n' > "$tmpdir/bin/$stub"
  chmod +x "$tmpdir/bin/$stub"
done
MOCK_PATH="$tmpdir/bin:/usr/bin:/bin"

# Extract check_dependencies function body from runner
CHECK_DEPS_BODY="$(awk '
  /^check_dependencies\(\) \{/ { in_fn=1; depth=0 }
  in_fn {
    for (i=1; i<=length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      else if (c == "}") {
        depth--
        if (depth == 0) { print; in_fn=0; next }
      }
    }
    print
  }
' "$RUN")"

if [[ -z "$CHECK_DEPS_BODY" ]]; then
  echo "FATAL: could not extract check_dependencies() from $RUN"
  exit 1
fi

# Write check_deps harness: codex-only engines, stub helpers, no claude in PATH
cat > "$tmpdir/check_deps.zsh" << 'HDOC'
WORKER_ENGINE=codex
VERIFIER_ENGINE=codex
VERIFY_CONSENSUS=0
CODEX_BIN=""
CLAUDE_BIN=""
log_error() { echo "ERROR: $*" >&2; }
log()       { :; }
HDOC
printf '%s\n' "$CHECK_DEPS_BODY" >> "$tmpdir/check_deps.zsh"
printf 'check_dependencies\n' >> "$tmpdir/check_deps.zsh"

PATH="$MOCK_PATH" zsh -f "$tmpdir/check_deps.zsh" >/dev/null 2>&1
s8_deps_exit=$?

if [[ "$s8_deps_exit" -eq 0 ]]; then
  pass "S8: check_dependencies() exits 0 with codex-only engines when claude absent (startup path)"
else
  fail "S8: check_dependencies() exited $s8_deps_exit — claude required unconditionally, AC4 startup blocked"
fi

# Generate SV report with same no-claude PATH — simulates cleanup phase after codex-only campaign
run_sv_function "$tmpdir" 1 "$MOCK_PATH"
s8_sv_exit=$?

if grep -q "claude CLI not found\|claude.*not found" "$logs/campaign-report.md" 2>/dev/null; then
  pass "S8: generate_sv_report gracefully degrades when claude absent after codex-only startup"
else
  fail "S8: campaign-report missing graceful-degradation message in startup-to-cleanup path"
fi
if [[ "$s8_sv_exit" -eq 0 ]]; then
  pass "S8: generate_sv_report exits 0 — terminal-status preserved across startup-to-cleanup path"
else
  fail "S8: generate_sv_report exited $s8_sv_exit (expected 0)"
fi

# ---------------------------------------------------------------------------
# S9: distinct-dirs — LOGS_DIR != ANALYTICS_DIR → report goes to LOGS_DIR (PRD path)
# Tests AC1 and AC2 with distinct log and analytics directories to prove
# the PRD-required logs/<slug> output path is honoured.
# ---------------------------------------------------------------------------
echo "--- S9: distinct-dirs (LOGS_DIR != ANALYTICS_DIR) ---"
setup_scenario; tmpdir="$CURRENT_TMPDIR"
logs="$tmpdir/logs"
analytics="$tmpdir/analytics"
mkdir -p "$analytics"
write_mock_claude_ok "$tmpdir/bin"

# Run generate_sv_report with LOGS_DIR != ANALYTICS_DIR
cat > "$tmpdir/run_s9.zsh" << EOF
WITH_SELF_VERIFICATION=1
SV_REPORT_GENERATED=0
LOGS_DIR="$logs"
ANALYTICS_DIR="$analytics"
SLUG="test-campaign"
DESK="$tmpdir"
DEBUG=0

log() { :; }

EOF
printf '%s\n' "$FUNC_BODY" >> "$tmpdir/run_s9.zsh"
echo "generate_sv_report" >> "$tmpdir/run_s9.zsh"
PATH="$tmpdir/bin:$PATH" zsh -f "$tmpdir/run_s9.zsh" >/dev/null 2>&1

report_in_logs="$(ls "$logs/self-verification-report-"*.md 2>/dev/null | head -1)"
if [[ -f "$report_in_logs" ]]; then
  pass "S9: sv report written to LOGS_DIR (PRD path: logs/<slug>/)"
else
  fail "S9: sv report not found in LOGS_DIR — written to wrong path"
fi
count_analytics="$(ls "$analytics/self-verification-report-"*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$count_analytics" -eq 0 ]]; then
  pass "S9: sv report NOT written to ANALYTICS_DIR (correct path separation)"
else
  fail "S9: sv report written to ANALYTICS_DIR instead of LOGS_DIR (path bug)"
fi

# AC2 versioning with distinct dirs: pre-create 001 in LOGS_DIR → next run creates 002 in LOGS_DIR
echo "existing" > "$logs/self-verification-report-001.md"
cat > "$tmpdir/run_s9b.zsh" << EOF
WITH_SELF_VERIFICATION=1
SV_REPORT_GENERATED=0
LOGS_DIR="$logs"
ANALYTICS_DIR="$analytics"
SLUG="test-campaign"
DESK="$tmpdir"
DEBUG=0

log() { :; }

EOF
printf '%s\n' "$FUNC_BODY" >> "$tmpdir/run_s9b.zsh"
echo "generate_sv_report" >> "$tmpdir/run_s9b.zsh"
PATH="$tmpdir/bin:$PATH" zsh -f "$tmpdir/run_s9b.zsh" >/dev/null 2>&1

if [[ -f "$logs/self-verification-report-002.md" ]]; then
  pass "S9: versioning uses LOGS_DIR — 002 created in logs/ not analytics/"
else
  fail "S9: versioning did not create report-002.md in LOGS_DIR"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
