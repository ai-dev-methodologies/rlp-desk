#!/usr/bin/env bash
# Test Suite: US-001 — tmux SV Report Generation
# IL-4: 3+ tests per AC (happy + negative + boundary)
# 5 ACs x 3 = 15 tests minimum

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

grep_count() {
  local pattern="$1"
  local file="${2:-$RUN}"
  local n
  n=$(grep -c "$pattern" "$file" 2>/dev/null) || n=0
  # If searching RUN (default), also add counts from LIB
  if [[ "$file" == "$RUN" ]]; then
    local n2
    n2=$(grep -c "$pattern" "$LIB" 2>/dev/null) || n2=0
    n=$(( n + n2 ))
  fi
  echo "$n"
}
grep_exists() { grep -q "$1" "$2" 2>/dev/null && echo 1 || echo 0; }

assert_eq() {
  local val="$1" expected="$2" label="$3"
  if [[ "$val" -eq "$expected" ]]; then pass "$label"; else fail "$label (got $val, expected $expected)"; fi
}
assert_ge() {
  local val="$1" min="$2" label="$3"
  if [[ "$val" -ge "$min" ]]; then pass "$label"; else fail "$label (got $val, expected >=$min)"; fi
}
assert_one() { assert_ge "$1" 1 "$2"; }

echo "=== US-001: tmux SV Report Generation ==="
echo ""

# ============================================================
# AC1: SV report file generation
# ============================================================

# AC1-happy: generate_sv_report function is defined
count=$(grep_count 'generate_sv_report()' "$RUN")
assert_one "$count" "AC1-happy: generate_sv_report() function defined in run_ralph_desk.zsh"

# AC1-negative: self-verification-report-NNN.md filename pattern present in function
count=$(grep_count 'self-verification-report-' "$RUN")
assert_ge "$count" 2 "AC1-negative: self-verification-report- pattern >= 2 occurrences"

# AC1-boundary: SV_REPORT_GENERATED guard variable initialized and checked
count=$(grep_count 'SV_REPORT_GENERATED' "$RUN")
assert_ge "$count" 3 "AC1-boundary: SV_REPORT_GENERATED guard used >= 3 times (init + guard check + set)"

# ============================================================
# AC2: Versioning existing SV reports
# ============================================================

# AC2-happy: sv_version variable used for versioning logic
count=$(grep_count 'sv_version' "$RUN")
assert_ge "$count" 3 "AC2-happy: sv_version variable used >= 3 times (init, loop, filename)"

# AC2-negative: sv_version++ increment operator in while loop (not just presence of the variable)
count=$(grep_count 'sv_version++' "$RUN")
assert_one "$count" "AC2-negative: sv_version++ increment operator in versioning while loop"

# AC2-boundary: printf '%03d' used for zero-padded version number
count=$(grep_count "printf '%03d'" "$RUN")
assert_one "$count" "AC2-boundary: printf '%03d' for zero-padded SV report version"

# ============================================================
# AC3: SV flag not used -> no report generated
# ============================================================

# AC3-happy: WITH_SELF_VERIFICATION guard inside generate_sv_report
count=$(grep_count 'WITH_SELF_VERIFICATION' "$RUN")
assert_ge "$count" 3 "AC3-happy: WITH_SELF_VERIFICATION referenced >= 3 times in script"

# AC3-negative: early return when flag is not set
count=$(grep_count '! WITH_SELF_VERIFICATION' "$RUN")
assert_one "$count" "AC3-negative: early return guard '! WITH_SELF_VERIFICATION' present"

# AC3-boundary: campaign report SV section says N/A or not enabled when flag absent
count=$(grep_count 'N/A.*not enabled\|not enabled' "$RUN")
assert_one "$count" "AC3-boundary: 'not enabled' message in campaign report when SV flag absent"

# ============================================================
# AC4: claude CLI not found -> graceful degradation
# ============================================================

# AC4-happy: command -v claude check present for CLI availability
count=$(grep_count 'command -v claude' "$RUN")
assert_one "$count" "AC4-happy: command -v claude check present in generate_sv_report"

# AC4-negative: 'claude CLI not found' error message written on failure
count=$(grep_count 'claude CLI not found\|claude.*not found' "$RUN")
assert_one "$count" "AC4-negative: 'claude CLI not found' error message present"

# AC4-boundary: return 0 (not exit 1) used so tmux session is not killed
count=$(grep_count 'return 0' "$RUN")
assert_ge "$count" 2 "AC4-boundary: return 0 used for graceful failure (not exit 1)"

# AC4-scoped: verify AC4 patterns exist WITHIN generate_sv_report() body
# (prevents false-positive from other functions matching same patterns)
# These tests FAIL when generate_sv_report() is absent — true AC4 RED evidence.
_extract_sv_fn() {
  awk '
    /^generate_sv_report\(\) \{/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$1" 2>/dev/null
}
_sv_fn_body="$(_extract_sv_fn "$RUN")"
if [[ -z "$_sv_fn_body" ]]; then
  _sv_fn_body="$(_extract_sv_fn "$LIB")"
fi

count=$(echo "$_sv_fn_body" | grep -c 'command -v claude')
assert_one "$count" "AC4-scoped-1: command -v claude within generate_sv_report body"

count=$(echo "$_sv_fn_body" | grep -c 'claude CLI not found\|claude.*not found')
assert_one "$count" "AC4-scoped-2: 'claude CLI not found' message within generate_sv_report body"

count=$(echo "$_sv_fn_body" | grep -c 'return 0')
assert_ge "$count" 1 "AC4-scoped-3: return 0 within generate_sv_report for graceful degradation"

# ============================================================
# AC5: SV generation timeout -> timeout message recorded
# ============================================================

# AC5-happy: in-process timeout variables present (background job + watchdog + flag)
count=$(grep_count '_sv_pid\|_sv_watchdog\|_sv_timeout_flag' "$RUN")
assert_ge "$count" 3 "AC5-happy: in-process timeout variables >= 3 occurrences (_sv_pid + _sv_watchdog + flag)"

# AC5-negative: exit code 124 detected as timeout signal
count=$(grep_count '== 124\|exit_code.*124' "$RUN")
assert_one "$count" "AC5-negative: exit code 124 detected as timeout"

# AC5-boundary: configurable timeout variable with 300s default
count=$(grep_count '_sv_timeout_secs\|_SV_TIMEOUT_SECS' "$RUN")
assert_ge "$count" 3 "AC5-boundary: _sv_timeout_secs configurable timeout variable >= 3 occurrences"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
