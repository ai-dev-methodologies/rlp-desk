#!/usr/bin/env bash
# Test suite: US-003 TIMEOUT path double generate_campaign_report call removal
# Tests: AC1 (3) + AC2 (4) = 7 total
# RED tests (fail before change): AC1-happy, AC1-boundary, AC2-sole-path
# Regression tests (pass before and after): AC1-negative, AC2-happy, AC2-negative, AC2-boundary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-003: TIMEOUT path double-call removal ==="
echo "Target: $RUN"
echo ""

# --- AC1: TIMEOUT path direct call removed ---
echo "--- AC1: TIMEOUT path direct call removed ---"

# AC1-happy: the TIMEOUT-path direct call line must not exist
test_ac1_happy() {
  if grep -qF 'generate_campaign_report  # AC4: TIMEOUT terminal path' "$RUN"; then
    fail "AC1-happy: 'generate_campaign_report  # AC4: TIMEOUT terminal path' still present (must be removed)"
  else
    pass "AC1-happy: direct generate_campaign_report call in TIMEOUT path removed"
  fi
}

# AC1-negative: CAMPAIGN_REPORT_GENERATED guard must still be present (must not be deleted)
test_ac1_negative() {
  if grep -qF 'CAMPAIGN_REPORT_GENERATED=0' "$RUN" 2>/dev/null || grep -qF 'CAMPAIGN_REPORT_GENERATED=0' "$LIB" 2>/dev/null; then
    pass "AC1-negative: CAMPAIGN_REPORT_GENERATED=0 guard still present"
  else
    fail "AC1-negative: CAMPAIGN_REPORT_GENERATED=0 guard was removed (MUST NOT)"
  fi
}

# AC1-boundary: No generate_campaign_report call in the 'Max iterations reached' block
# Checks: after "Max iterations" line, before "return 1" at end of main(), no direct call exists
test_ac1_boundary() {
  local hit
  hit=$(awk '
    /Max iterations.*reached/ { in_block=1; next }
    in_block && /generate_campaign_report[^(]/ { print; exit }
    in_block && /return 1/ { exit }
  ' "$RUN")
  if [[ -n "$hit" ]]; then
    fail "AC1-boundary: generate_campaign_report still called in Max iterations block: $hit"
  else
    pass "AC1-boundary: no generate_campaign_report in Max iterations block"
  fi
}

# --- AC2: cleanup() is the sole report generation path ---
echo ""
echo "--- AC2: cleanup() is sole report generation path ---"

# AC2-happy: cleanup() must still contain generate_campaign_report call
# Note: inside a function body, generate_campaign_report is always a call (not definition).
# Use !/\(\)/ to exclude any definition lines as extra safety.
test_ac2_happy() {
  local hit
  hit=$(awk '
    /^cleanup\(\)/ { in_fn=1 }
    in_fn && !/generate_campaign_report\(\)/ && /generate_campaign_report/ { print; exit }
    in_fn && /^}/ { in_fn=0 }
  ' "$RUN")
  if [[ -n "$hit" ]]; then
    pass "AC2-happy: cleanup() contains generate_campaign_report call"
  else
    fail "AC2-happy: cleanup() does NOT contain generate_campaign_report (MUST)"
  fi
}

# AC2-negative: write_complete_sentinel and write_blocked_sentinel must NOT directly call generate_campaign_report
# These functions are now in LIB; search both files
test_ac2_negative() {
  local _search_file
  local complete_hit blocked_hit
  for _search_file in "$RUN" "$LIB"; do
    local _hit
    _hit=$(awk '
      /^write_complete_sentinel\(\)/ { in_fn=1 }
      in_fn && !/generate_campaign_report\(\)/ && /generate_campaign_report/ { print; exit }
      in_fn && /^}/ { in_fn=0 }
    ' "$_search_file" 2>/dev/null)
    [[ -n "$_hit" ]] && complete_hit="$_hit"
    _hit=$(awk '
      /^write_blocked_sentinel\(\)/ { in_fn=1 }
      in_fn && !/generate_campaign_report\(\)/ && /generate_campaign_report/ { print; exit }
      in_fn && /^}/ { in_fn=0 }
    ' "$_search_file" 2>/dev/null)
    [[ -n "$_hit" ]] && blocked_hit="$_hit"
  done
  if [[ -n "$complete_hit" || -n "$blocked_hit" ]]; then
    fail "AC2-negative: COMPLETE/BLOCKED sentinel functions directly call generate_campaign_report"
  else
    pass "AC2-negative: COMPLETE/BLOCKED paths do not directly call generate_campaign_report"
  fi
}

# AC2-boundary: CAMPAIGN_REPORT_GENERATED guard inside generate_campaign_report() must be intact
# generate_campaign_report() is now in LIB; fall back to LIB when not found in RUN
test_ac2_boundary() {
  local hit
  hit=$(awk '
    /^generate_campaign_report\(\)/ { in_fn=1; next }
    in_fn && /CAMPAIGN_REPORT_GENERATED/ { print; exit }
    in_fn && /^}/ { in_fn=0 }
  ' "$RUN" 2>/dev/null)
  if [[ -z "$hit" ]]; then
    hit=$(awk '
      /^generate_campaign_report\(\)/ { in_fn=1; next }
      in_fn && /CAMPAIGN_REPORT_GENERATED/ { print; exit }
      in_fn && /^}/ { in_fn=0 }
    ' "$LIB" 2>/dev/null)
  fi
  if [[ -n "$hit" ]]; then
    pass "AC2-boundary: CAMPAIGN_REPORT_GENERATED guard inside generate_campaign_report() intact"
  else
    fail "AC2-boundary: CAMPAIGN_REPORT_GENERATED guard missing from generate_campaign_report()"
  fi
}

# AC2-sole-path: generate_campaign_report must ONLY be called from cleanup()
# cleanup() is in RUN; generate_campaign_report() definition is in LIB.
# Scan RUN for calls outside cleanup(), and scan LIB excluding any definition line.
test_ac2_sole_path() {
  local outside_run outside_lib
  outside_run=$(awk '
    /^cleanup\(\)/ { in_cleanup=1 }
    in_cleanup && /^\}/ { in_cleanup=0; next }
    /^generate_campaign_report\(\)[ \t]*\{/ { next }
    !in_cleanup && /generate_campaign_report[^(]/ { print NR": "$0 }
  ' "$RUN" 2>/dev/null)
  # In LIB, only the definition should exist — any call lines outside the definition are a violation
  outside_lib=$(awk '
    /^generate_campaign_report\(\)[ \t]*\{/ { in_def=1; depth=0 }
    in_def {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { in_def=0; next } }
      }
      next
    }
    /generate_campaign_report[^(]/ { print NR": "$0 }
  ' "$LIB" 2>/dev/null)
  if [[ -z "$outside_run" && -z "$outside_lib" ]]; then
    pass "AC2-sole-path: generate_campaign_report only called from cleanup()"
  else
    fail "AC2-sole-path: generate_campaign_report called outside cleanup(): run=${outside_run} lib=${outside_lib}"
  fi
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary
test_ac2_happy
test_ac2_negative
test_ac2_boundary
test_ac2_sole_path


# ---------------------------------------------------------------------------
# E2E: AC1 Runtime — TIMEOUT-path double-call protection
# Extracts generate_campaign_report() and calls it twice to prove the
# CAMPAIGN_REPORT_GENERATED guard ensures singleton report production.
# ---------------------------------------------------------------------------
echo ""
echo "--- E2E: AC1 runtime double-call protection (TIMEOUT-path singleton proof) ---"

_extract_gcrf_body() {
  local _f="$1"
  awk '
    /^generate_campaign_report\(\) \{/ { in_fn=1; depth=0 }
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
  ' "$_f" 2>/dev/null
}
GCRF_BODY="$(_extract_gcrf_body "$RUN")"
if [[ -z "$GCRF_BODY" ]]; then
  GCRF_BODY="$(_extract_gcrf_body "$LIB")"
fi

if [[ -z "$GCRF_BODY" ]]; then
  fail "E2E-extract: could not extract generate_campaign_report() from $RUN"
  fail "E2E-red: skipped (extract failed)"
  fail "E2E-green: skipped (extract failed)"
  fail "E2E-status: skipped (extract failed)"
else

E2E_BASE="$(mktemp -d)"
trap 'rm -rf "$E2E_BASE"' EXIT

# Helper: build and run a harness calling generate_campaign_report() twice
# $1=dir  $2=reset_guard: 1=reset CAMPAIGN_REPORT_GENERATED=0 between calls (RED), 0=normal (GREEN)
run_gcrf_harness() {
  local dir="$1" reset_guard="${2:-0}"
  local logs="$dir/logs"
  mkdir -p "$logs"

  cat > "$dir/h.zsh" << HARNESS
CAMPAIGN_REPORT_GENERATED=0
LOGS_DIR="$logs"
ROOT="$dir"
SLUG="e2e-test"
DESK="$dir"
COMPLETE_SENTINEL="$dir/complete"
BLOCKED_SENTINEL="$dir/blocked"
START_TIME=$(date +%s)
ITERATION=1; MAX_ITER=5
WORKER_MODEL="test-m"; WORKER_ENGINE="tmux"
VERIFIER_MODEL="test-m"; VERIFIER_ENGINE="tmux"
WITH_SELF_VERIFICATION=0; COST_LOG=""
CONSECUTIVE_FAILURES=0; VERIFIED_US=""; BASELINE_COMMIT=""
log() { :; }
atomic_write() { local t="\$1" p="\${t}.tmp.\$\$"; cat>"\$p"; mv "\$p" "\$t"; }
HARNESS

  printf '%s\n' "$GCRF_BODY" >> "$dir/h.zsh"

  if [[ "$reset_guard" == "1" ]]; then
    printf 'generate_campaign_report\nCAMPAIGN_REPORT_GENERATED=0\ngenerate_campaign_report\n' >> "$dir/h.zsh"
  else
    printf 'generate_campaign_report\ngenerate_campaign_report\n' >> "$dir/h.zsh"
  fi

  zsh -f "$dir/h.zsh" >/dev/null 2>&1
}

# E2E-red: reset guard between calls → produces campaign-report-v1.md (confirms test detects failure)
red_dir="$E2E_BASE/red"; mkdir -p "$red_dir"
run_gcrf_harness "$red_dir" 1
red_v="$(ls "$red_dir/logs/campaign-report-v1.md" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$red_v" -ge 1 ]]; then
  pass "E2E-red: guard-bypassed double-call creates campaign-report-v1.md (RED confirmed)"
else
  fail "E2E-red: expected campaign-report-v1.md with bypassed guard (got $red_v)"
fi

# E2E-green: normal double-call with guard → 1 campaign-report.md, no -v1 (AC1 runtime proof)
green_dir="$E2E_BASE/green"; mkdir -p "$green_dir"
run_gcrf_harness "$green_dir" 0
green_r="$(ls "$green_dir/logs/campaign-report.md" 2>/dev/null | wc -l | tr -d ' ')"
green_v="$(ls "$green_dir/logs/campaign-report-v1.md" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$green_r" -eq 1 && "$green_v" -eq 0 ]]; then
  pass "E2E-green: double-call with guard produces exactly 1 campaign-report.md, no -v1"
else
  fail "E2E-green: expected r=1 v=0 (got r=$green_r v=$green_v)"
fi

# E2E-status: TIMEOUT status detected when no sentinel files present
status_dir="$E2E_BASE/status"; mkdir -p "$status_dir"
run_gcrf_harness "$status_dir" 0
if grep -q 'Status: TIMEOUT' "$status_dir/logs/campaign-report.md" 2>/dev/null; then
  pass "E2E-status: TIMEOUT status written to campaign-report.md when no sentinel"
else
  fail "E2E-status: TIMEOUT status not found in campaign-report.md"
fi

fi  # end if GCRF_BODY not empty

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
