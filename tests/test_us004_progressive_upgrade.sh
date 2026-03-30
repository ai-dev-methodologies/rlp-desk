#!/usr/bin/env bash
# Test Suite: US-004 — Progressive Worker upgrade on failure
# PRD: AC1 (upgrade at 2-attempt window), AC2 (ceiling → BLOCKED escalation),
#      AC3 (--lock-worker-model prevents upgrade), AC4 (pass resets counter)
# IL-4: 4 ACs × 3 = 12 minimum; this suite has 16 tests (AC1:4, AC2:3, AC3:3, AC4:3, L2:2, L3:2) - 1 (AC4-L1-1 combined)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Helper: extract function body from run_ralph_desk.zsh or lib_ralph_desk.zsh
extract_fn() {
  local fn_name="$1"
  local body
  body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$RUN" 2>/dev/null)
  if [[ -z "$body" ]]; then
    body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$LIB" 2>/dev/null)
  fi
  echo "$body"
}

# Helper: run a zsh harness script in a tmpdir, return exit code
run_harness() {
  local script="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "$script" > "$tmpdir/harness.zsh"
  zsh -f "$tmpdir/harness.zsh" 2>&1
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

echo "=== US-004: Progressive Worker upgrade on failure ==="
echo ""

# ============================================================
# AC1: Upgrade at 2-attempt window (Verifier fixed)
# ============================================================
echo "--- AC1: Upgrade at 2-attempt window ---"

# AC1-L1-1: check_model_upgrade() function exists
if grep -qF 'check_model_upgrade()' "$RUN" || grep -qF 'check_model_upgrade()' "$LIB"; then
  pass "AC1-L1-1: check_model_upgrade() function exists"
else
  fail "AC1-L1-1: check_model_upgrade() missing from run_ralph_desk.zsh"
fi

# AC1-L1-2: upgrade triggers at _SAME_US_FAIL_COUNT >= 2 for same US
fn_body=$(extract_fn "check_model_upgrade")
if [[ -z "$fn_body" ]]; then
  fail "AC1-L1-2: check_model_upgrade() not found"
else
  checks=0
  echo "$fn_body" | grep -q '_SAME_US_FAIL_COUNT' && (( checks++ ))
  echo "$fn_body" | grep -qE '>= *2' && (( checks++ ))
  if (( checks >= 2 )); then
    pass "AC1-L1-2: upgrade triggered at _SAME_US_FAIL_COUNT >= 2"
  else
    fail "AC1-L1-2: upgrade threshold check missing (found $checks/2 indicators)"
  fi
fi

# AC1-L1-3: Verifier model NOT modified by check_model_upgrade
fn_body=$(extract_fn "check_model_upgrade")
if [[ -z "$fn_body" ]]; then
  fail "AC1-L1-3: check_model_upgrade() not found"
elif echo "$fn_body" | grep -q 'VERIFIER_MODEL'; then
  fail "AC1-L1-3: check_model_upgrade() must not modify VERIFIER_MODEL"
else
  pass "AC1-L1-3: Verifier model not touched by check_model_upgrade()"
fi

# AC1-L1-4: _SAME_US_FAIL_COUNT state var initialized in script
if grep -qF '_SAME_US_FAIL_COUNT=0' "$RUN" || grep -qF '_SAME_US_FAIL_COUNT=0' "$LIB"; then
  pass "AC1-L1-4: _SAME_US_FAIL_COUNT initialized in state tracking"
else
  fail "AC1-L1-4: _SAME_US_FAIL_COUNT=0 initialization missing"
fi

# ============================================================
# AC2: Ceiling then BLOCKED (escalation message)
# ============================================================
echo ""
echo "--- AC2: Ceiling then BLOCKED ---"

# AC2-L1-1: get_next_model("opus") returns empty (claude ceiling)
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-1: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'opus')
[[ -z \"\$r\" ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-1: get_next_model(opus) returns empty (claude ceiling)"
  else
    fail "AC2-L1-1: get_next_model(opus) should return empty, got: $result"
  fi
fi

# AC2-L1-2: get_next_model("gpt-5.4:xhigh") returns empty (codex ceiling)
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-2: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.4:xhigh')
[[ -z \"\$r\" ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-2: get_next_model(gpt-5.4:xhigh) returns empty (codex ceiling)"
  else
    fail "AC2-L1-2: get_next_model(gpt-5.4:xhigh) should return empty, got: $result"
  fi
fi

# AC2-L1-2b: get_next_model("gpt-5.3-codex-spark:xhigh") returns empty (spark ceiling — must NOT cross to 5.4)
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-2b: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.3-codex-spark:xhigh')
[[ -z \"\$r\" ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-2b: get_next_model(gpt-5.3-codex-spark:xhigh) returns empty (spark ceiling)"
  else
    fail "AC2-L1-2b: get_next_model(gpt-5.3-codex-spark:xhigh) should return empty (stay in spark pool), got: $result"
  fi
fi

# AC2-L1-2c: get_next_model("gpt-5.3-codex-spark:high") returns gpt-5.3-codex-spark:xhigh (not 5.4)
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-2c: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.3-codex-spark:high')
[[ \"\$r\" = 'gpt-5.3-codex-spark:xhigh' ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-2c: get_next_model(gpt-5.3-codex-spark:high) → gpt-5.3-codex-spark:xhigh (stays in spark)"
  else
    fail "AC2-L1-2c: get_next_model(gpt-5.3-codex-spark:high) should return gpt-5.3-codex-spark:xhigh, got: $result"
  fi
fi

# AC2-L1-2d: get_next_model full upgrade chain (gpt-5.3-codex-spark:medium → high)
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-2d: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.3-codex-spark:medium')
[[ \"\$r\" = 'gpt-5.3-codex-spark:high' ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-2d: get_next_model(gpt-5.3-codex-spark:medium) → gpt-5.3-codex-spark:high"
  else
    fail "AC2-L1-2d: spark upgrade failed, got: $result"
  fi
fi

# AC2-L1-2e: get_next_model(gpt-5.3-codex-spark:low) returns gpt-5.3-codex-spark:medium
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-2e: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.3-codex-spark:low')
[[ \"\$r\" = 'gpt-5.3-codex-spark:medium' ]] && exit 0 || { echo \"got: \$r\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-2e: get_next_model(gpt-5.3-codex-spark:low) → gpt-5.3-codex-spark:medium"
  else
    fail "AC2-L1-2e: spark low upgrade failed, got: $result"
  fi
fi

# AC2-L1-3: ceiling path logs reason=already_max
if grep -qF 'reason=already_max' "$RUN" || grep -qF 'reason=already_max' "$LIB"; then
  pass "AC2-L1-3: reason=already_max log present (ceiling detection)"
else
  fail "AC2-L1-3: reason=already_max missing in ceiling path"
fi

# ============================================================
# AC3: --lock-worker-model prevents upgrade
# ============================================================
echo ""
echo "--- AC3: --lock-worker-model prevents upgrade ---"

# AC3-L1-1: LOCK_WORKER_MODEL variable initialized in script
if grep -qE 'LOCK_WORKER_MODEL.*=.*0' "$RUN" || grep -qE 'LOCK_WORKER_MODEL.*=.*0' "$LIB"; then
  pass "AC3-L1-1: LOCK_WORKER_MODEL variable initialized"
else
  fail "AC3-L1-1: LOCK_WORKER_MODEL initialization missing"
fi

# AC3-L1-2: LOCK_WORKER_MODEL=1 with 2 fails → model unchanged
fn_cmu=$(extract_fn "check_model_upgrade")
fn_gms=$(extract_fn "get_model_string")
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_cmu" || -z "$fn_gnm" ]]; then
  fail "AC3-L1-2: check_model_upgrade or get_next_model not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
log_debug() { : ; }
log() { : ; }
WORKER_ENGINE='claude'
WORKER_MODEL='sonnet'
VERIFIER_MODEL='opus'
LOCK_WORKER_MODEL=1
_LAST_FAILED_US=''
_SAME_US_FAIL_COUNT=0
_MODEL_UPGRADED=0
_ORIGINAL_WORKER_MODEL=''
ITERATION=1
${fn_gms}
${fn_gnm}
${fn_cmu}
check_model_upgrade 'US-001'
check_model_upgrade 'US-001'
[[ \"\$WORKER_MODEL\" == 'sonnet' ]] && exit 0 || { echo \"model changed to \$WORKER_MODEL\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC3-L1-2: LOCK_WORKER_MODEL=1 prevents model upgrade on 2 consecutive fails"
  else
    fail "AC3-L1-2: model changed despite LOCK_WORKER_MODEL=1: $result"
  fi
fi

# AC3-L1-3: lock guard references LOCK_WORKER_MODEL in check_model_upgrade body
fn_cmu=$(extract_fn "check_model_upgrade")
fn_gms=$(extract_fn "get_model_string")
if [[ -z "$fn_cmu" ]]; then
  fail "AC3-L1-3: check_model_upgrade() not found"
elif echo "$fn_cmu" | grep -q 'LOCK_WORKER_MODEL'; then
  pass "AC3-L1-3: LOCK_WORKER_MODEL guard present in check_model_upgrade()"
else
  fail "AC3-L1-3: LOCK_WORKER_MODEL guard missing from check_model_upgrade()"
fi

# ============================================================
# AC4: Pass resets counter (no upgrade after pass+single fail)
# ============================================================
echo ""
echo "--- AC4: Pass resets counter ---"

# AC4-L1-1: _SAME_US_FAIL_COUNT=0 appears at least twice (init + pass verdict reset)
count=$(( $(grep -c '_SAME_US_FAIL_COUNT=0' "$RUN" 2>/dev/null || echo 0) + $(grep -c '_SAME_US_FAIL_COUNT=0' "$LIB" 2>/dev/null || echo 0) ))
if (( count >= 2 )); then
  pass "AC4-L1-1: _SAME_US_FAIL_COUNT=0 reset present in both init and pass verdict path"
else
  fail "AC4-L1-1: _SAME_US_FAIL_COUNT=0 missing in pass verdict path (found $count occurrence(s), need 2+)"
fi

# AC4-L1-2: fail→pass→fail: counter=1, no upgrade triggered
fn_cmu=$(extract_fn "check_model_upgrade")
fn_gms=$(extract_fn "get_model_string")
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_cmu" || -z "$fn_gnm" ]]; then
  fail "AC4-L1-2: check_model_upgrade or get_next_model not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
log_debug() { : ; }
log() { : ; }
WORKER_ENGINE='claude'
WORKER_MODEL='haiku'
VERIFIER_MODEL='opus'
LOCK_WORKER_MODEL=0
_LAST_FAILED_US=''
_SAME_US_FAIL_COUNT=0
_MODEL_UPGRADED=0
_ORIGINAL_WORKER_MODEL=''
ITERATION=1
${fn_gms}
${fn_gnm}
${fn_cmu}
# fail once
check_model_upgrade 'US-001'
# pass: reset counters (simulates pass verdict path)
_SAME_US_FAIL_COUNT=0
_LAST_FAILED_US=''
# fail once more
check_model_upgrade 'US-001'
# expect: model unchanged (haiku), count=1
if [[ \"\$WORKER_MODEL\" == 'haiku' ]] && (( _SAME_US_FAIL_COUNT == 1 )); then
  exit 0
else
  echo \"FAIL: model=\$WORKER_MODEL count=\$_SAME_US_FAIL_COUNT\" >&2
  exit 1
fi" 2>&1)
  if (( $? == 0 )); then
    pass "AC4-L1-2: fail→pass→fail: counter=1, no upgrade (haiku unchanged)"
  else
    fail "AC4-L1-2: fail→pass→fail: unexpected state: $result"
  fi
fi

# AC4-L1-3: single fail then pass → no upgrade before pass
fn_cmu=$(extract_fn "check_model_upgrade")
fn_gms=$(extract_fn "get_model_string")
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_cmu" || -z "$fn_gnm" ]]; then
  fail "AC4-L1-3: check_model_upgrade or get_next_model not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
log_debug() { : ; }
log() { : ; }
WORKER_ENGINE='claude'
WORKER_MODEL='haiku'
VERIFIER_MODEL='opus'
LOCK_WORKER_MODEL=0
_LAST_FAILED_US=''
_SAME_US_FAIL_COUNT=0
_MODEL_UPGRADED=0
_ORIGINAL_WORKER_MODEL=''
ITERATION=1
${fn_gms}
${fn_gnm}
${fn_cmu}
# single fail
check_model_upgrade 'US-001'
# model must still be haiku (only 1 fail, threshold is 2)
[[ \"\$WORKER_MODEL\" == 'haiku' ]] && exit 0 || { echo \"unexpected upgrade to \$WORKER_MODEL\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC4-L1-3: single fail → no upgrade (below threshold)"
  else
    fail "AC4-L1-3: upgrade triggered after single fail: $result"
  fi
fi

# AC2-L1-4 (boundary): get_next_model("gpt-5.4:high") returns non-empty — proves gpt-5.4:high is NOT ceiling
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "AC2-L1-4: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
r=\$(get_next_model 'gpt-5.4:high')
# gpt-5.4:high is NOT ceiling — must return gpt-5.4:xhigh
[[ -n \"\$r\" ]] && exit 0 || { echo \"got empty: gpt-5.4:high incorrectly treated as ceiling\" >&2; exit 1; }" 2>&1)
  if (( $? == 0 )); then
    pass "AC2-L1-4: get_next_model(gpt-5.4:high) returns non-empty (not ceiling)"
  else
    fail "AC2-L1-4: get_next_model(gpt-5.4:high) must return non-empty — gpt-5.4:high is not ceiling: $result"
  fi
fi

# AC2-L1-5 (codex boundary): CB ceiling check uses full WORKER_CODEX_MODEL:WORKER_CODEX_REASONING
# Before fix: only bare WORKER_MODEL passed to get_next_model in CB path (loses reasoning suffix)
# After fix: _ceiling_model_str computed from WORKER_CODEX_MODEL:WORKER_CODEX_REASONING for codex
if (grep -q '_ceiling_model_str' "$RUN" || grep -q '_ceiling_model_str' "$LIB") && (grep -q 'WORKER_CODEX_REASONING' "$RUN" || grep -q 'WORKER_CODEX_REASONING' "$LIB"); then
  pass "AC2-L1-5: CB ceiling check uses _ceiling_model_str with WORKER_CODEX_MODEL:WORKER_CODEX_REASONING for codex"
else
  fail "AC2-L1-5: CB ceiling check must use full WORKER_CODEX_MODEL:WORKER_CODEX_REASONING for codex — bare WORKER_MODEL loses reasoning suffix after upgrade"
fi

# ============================================================
# L2: Integration — upgrade path matches documented table
# ============================================================
echo ""
echo "--- L2: Upgrade path matches documented table ---"

# L2-1: claude-only path: haiku→sonnet→opus→""
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "L2-1: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
a=\$(get_next_model 'haiku')
b=\$(get_next_model 'sonnet')
c=\$(get_next_model 'opus')
if [[ \"\$a\" == 'sonnet' && \"\$b\" == 'opus' && -z \"\$c\" ]]; then exit 0; fi
echo \"haiku->\$a sonnet->\$b opus->\$c\" >&2; exit 1" 2>&1)
  if (( $? == 0 )); then
    pass "L2-1: claude path haiku→sonnet→opus→'' correct"
  else
    fail "L2-1: claude path incorrect: $result"
  fi
fi

# L2-2: codex non-pro path: gpt-5.4:medium→high→xhigh→""
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_gnm" ]]; then
  fail "L2-2: get_next_model() not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
${fn_gnm}
a=\$(get_next_model 'gpt-5.4:medium')
b=\$(get_next_model 'gpt-5.4:high')
c=\$(get_next_model 'gpt-5.4:xhigh')
if [[ \"\$a\" == 'gpt-5.4:high' && \"\$b\" == 'gpt-5.4:xhigh' && -z \"\$c\" ]]; then exit 0; fi
echo \"med->\$a high->\$b xhigh->\$c\" >&2; exit 1" 2>&1)
  if (( $? == 0 )); then
    pass "L2-2: codex non-pro path gpt-5.4:medium→high→xhigh→'' correct"
  else
    fail "L2-2: codex non-pro path incorrect: $result"
  fi
fi

# ============================================================
# L3: E2E — full upgrade cycle runtime verification
# ============================================================
echo ""
echo "--- L3: E2E ---"

# L3-1: 2 fails→upgrade, pass→reset, 1 fail→no further upgrade
fn_cmu=$(extract_fn "check_model_upgrade")
fn_gms=$(extract_fn "get_model_string")
fn_gnm=$(extract_fn "get_next_model")
if [[ -z "$fn_cmu" || -z "$fn_gnm" ]]; then
  fail "L3-1: check_model_upgrade or get_next_model not found"
else
  result=$(run_harness "#!/usr/bin/env zsh -f
log_debug() { : ; }
log() { : ; }
WORKER_ENGINE='claude'
WORKER_MODEL='haiku'
VERIFIER_MODEL='opus'
LOCK_WORKER_MODEL=0
_LAST_FAILED_US=''
_SAME_US_FAIL_COUNT=0
_MODEL_UPGRADED=0
_ORIGINAL_WORKER_MODEL=''
ITERATION=1
${fn_gms}
${fn_gnm}
${fn_cmu}
# 2 consecutive fails → upgrade
check_model_upgrade 'US-001'
check_model_upgrade 'US-001'
if [[ \"\$WORKER_MODEL\" != 'sonnet' ]]; then
  echo \"FAIL: not upgraded (got \$WORKER_MODEL)\" >&2; exit 1
fi
if [[ \"\$VERIFIER_MODEL\" != 'opus' ]]; then
  echo \"FAIL: verifier model changed to \$VERIFIER_MODEL\" >&2; exit 1
fi
# pass verdict: reset counters
_SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=''
# single fail → no upgrade (should remain sonnet, count=1)
check_model_upgrade 'US-002'
if [[ \"\$WORKER_MODEL\" != 'sonnet' ]] || (( _SAME_US_FAIL_COUNT != 1 )); then
  echo \"FAIL: unexpected post-pass state model=\$WORKER_MODEL count=\$_SAME_US_FAIL_COUNT\" >&2; exit 1
fi
exit 0" 2>&1)
  if (( $? == 0 )); then
    pass "L3-1: full upgrade cycle: 2 fails→upgrade, verifier fixed, pass→reset, 1 fail→no upgrade"
  else
    fail "L3-1: full upgrade cycle failed: $result"
  fi
fi

# L3-2: zsh -n syntax check
if zsh -n "$RUN" 2>/dev/null; then
  pass "L3-2: zsh -n syntax check passes"
else
  fail "L3-2: zsh -n syntax check FAILED"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
