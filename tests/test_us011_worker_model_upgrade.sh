#!/usr/bin/env bash
# Test suite: US-011 — Worker Model Auto-Upgrade (tmux mode)
# AC1 (3) + AC2 (3) + AC3 (3) + AC4 (3) + AC5 (3) + E2E (3) = 18 total
# RED tests (fail before impl): AC1-*, AC2-*, AC3-*, AC4-*, E2E-upgrade, E2E-restore
# Regression tests (pass before and after): AC5-happy, AC5-boundary, E2E-syntax

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
CMD="${CMD:-src/commands/rlp-desk.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-011: Worker Model Auto-Upgrade ==="
echo "Target: $RUN"
echo ""

# Helper: extract function body by name from source
extract_fn() {
  local fn_name="$1"
  local src="${2:-$RUN}"
  awk -v fn="$fn_name" '
    $0 ~ fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$src"
}

# ============================================================
# AC1: Auto-upgrade trigger (2 consecutive same-US fails → upgrade)
# ============================================================
echo "--- AC1: Auto-upgrade trigger ---"

# AC1-happy: check_model_upgrade() function exists
test_ac1_happy() {
  if grep -qF 'check_model_upgrade()' "$RUN"; then
    pass "AC1-happy: check_model_upgrade() function exists"
  else
    fail "AC1-happy: check_model_upgrade() function missing"
  fi
}

# AC1-negative: upgrade logic checks for 2 consecutive same-US fails
test_ac1_negative() {
  local body
  body=$(extract_fn "check_model_upgrade")
  if [[ -z "$body" ]]; then
    fail "AC1-negative: check_model_upgrade() not found"
    return
  fi
  local checks=0
  echo "$body" | grep -q '_SAME_US_FAIL_COUNT' && (( checks++ ))
  echo "$body" | grep -qE '>= *2' && (( checks++ ))
  if (( checks >= 2 )); then
    pass "AC1-negative: upgrade checks _SAME_US_FAIL_COUNT >= 2"
  else
    fail "AC1-negative: missing same-US consecutive fail threshold check (found $checks/2)"
  fi
}

# AC1-boundary: [DECIDE] model_upgrade=true log format in source
test_ac1_boundary() {
  if grep -qF 'model_upgrade=true' "$RUN" && grep -qF 'reason=consecutive_same_ac_fail' "$RUN"; then
    pass "AC1-boundary: [DECIDE] model_upgrade=true log format present"
  else
    fail "AC1-boundary: [DECIDE] model_upgrade=true log format missing"
  fi
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary

# ============================================================
# AC2: Restore after pass (opus → original model)
# ============================================================
echo ""
echo "--- AC2: Restore after pass ---"

# AC2-happy: pass verdict path has model restore logic
test_ac2_happy() {
  # In the pass) case block, _MODEL_UPGRADED should be checked
  if grep -qF '_MODEL_UPGRADED' "$RUN" && grep -qF '_ORIGINAL_WORKER_MODEL' "$RUN"; then
    pass "AC2-happy: model restore logic present (_MODEL_UPGRADED + _ORIGINAL_WORKER_MODEL)"
  else
    fail "AC2-happy: model restore logic missing"
  fi
}

# AC2-negative: _ORIGINAL_WORKER_MODEL is saved before upgrade
test_ac2_negative() {
  local body
  body=$(extract_fn "check_model_upgrade")
  if [[ -z "$body" ]]; then
    fail "AC2-negative: check_model_upgrade() not found"
    return
  fi
  if echo "$body" | grep -qF '_ORIGINAL_WORKER_MODEL'; then
    pass "AC2-negative: _ORIGINAL_WORKER_MODEL saved in check_model_upgrade"
  else
    fail "AC2-negative: _ORIGINAL_WORKER_MODEL not saved during upgrade"
  fi
}

# AC2-boundary: model_restore debug log exists
test_ac2_boundary() {
  if grep -qF 'model_restore=true' "$RUN"; then
    pass "AC2-boundary: [DECIDE] model_restore=true log present"
  else
    fail "AC2-boundary: [DECIDE] model_restore=true log missing"
  fi
}

test_ac2_happy
test_ac2_negative
test_ac2_boundary

# ============================================================
# AC3: Escalation on upgraded-model fail
# ============================================================
echo ""
echo "--- AC3: Escalation on upgraded-model fail ---"

# AC3-happy: Architecture Escalation triggered when upgraded model fails
test_ac3_happy() {
  if grep -qE 'architecture.escalation|model_upgrade.*escalat|upgraded.*retry.*fail' "$RUN" -i; then
    pass "AC3-happy: Architecture Escalation reference in upgrade context"
  else
    fail "AC3-happy: Architecture Escalation missing in upgrade fail path"
  fi
}

# AC3-negative: write_blocked_sentinel called with escalation reason
test_ac3_negative() {
  if grep -qE 'write_blocked_sentinel.*([Uu]pgrade|[Ee]scalat)' "$RUN"; then
    pass "AC3-negative: write_blocked_sentinel with upgrade/escalation context"
  else
    fail "AC3-negative: write_blocked_sentinel missing escalation context"
  fi
}

# AC3-boundary: _MODEL_UPGRADED==1 check gates escalation (not regular CB)
test_ac3_boundary() {
  local body
  body=$(extract_fn "check_model_upgrade")
  if [[ -z "$body" ]]; then
    fail "AC3-boundary: check_model_upgrade() not found"
    return
  fi
  if echo "$body" | grep -qF '_MODEL_UPGRADED'; then
    pass "AC3-boundary: _MODEL_UPGRADED gates escalation path"
  else
    fail "AC3-boundary: _MODEL_UPGRADED not checked for escalation"
  fi
}

test_ac3_happy
test_ac3_negative
test_ac3_boundary

# ============================================================
# AC4: Already-opus guard
# ============================================================
echo ""
echo "--- AC4: Already-opus guard ---"

# AC4-happy: opus detection exists in upgrade logic (check_model_upgrade + get_next_model combined)
test_ac4_happy() {
  local body_cmu body_gnm
  body_cmu=$(extract_fn "check_model_upgrade")
  body_gnm=$(extract_fn "get_next_model")
  if [[ -z "$body_cmu" && -z "$body_gnm" ]]; then
    fail "AC4-happy: no upgrade function found"
    return
  fi
  local combined="${body_cmu}${body_gnm}"
  if echo "$combined" | grep -q 'opus'; then
    pass "AC4-happy: opus detection in upgrade logic"
  else
    fail "AC4-happy: opus detection missing"
  fi
}

# AC4-negative: [DECIDE] model_upgrade=false reason=already_max log format
test_ac4_negative() {
  if grep -qF 'model_upgrade=false' "$RUN" && grep -qF 'reason=already_max' "$RUN"; then
    pass "AC4-negative: [DECIDE] model_upgrade=false reason=already_max present"
  else
    fail "AC4-negative: already_max log format missing"
  fi
}

# AC4-boundary: get_next_model returns empty/no-upgrade for opus
test_ac4_boundary() {
  if grep -qF 'get_next_model()' "$RUN"; then
    local body
    body=$(extract_fn "get_next_model")
    # opus case should return empty string or have no upgrade path
    if echo "$body" | grep -qE 'opus|already.*max|\*\)'; then
      pass "AC4-boundary: get_next_model handles opus (no further upgrade)"
    else
      fail "AC4-boundary: get_next_model missing opus handling"
    fi
  else
    fail "AC4-boundary: get_next_model() function not found"
  fi
}

test_ac4_happy
test_ac4_negative
test_ac4_boundary

# ============================================================
# AC5: Agent mode non-interference
# ============================================================
echo ""
echo "--- AC5: Agent mode non-interference ---"

# AC5-happy (regression): model upgrade logic only in run_ralph_desk.zsh, not in rlp-desk.md Agent mode
test_ac5_happy() {
  if ! grep -qE 'check_model_upgrade|get_next_model|model_upgrade=true|_MODEL_UPGRADED' "$CMD"; then
    pass "AC5-happy: rlp-desk.md Agent mode has no model upgrade logic"
  else
    fail "AC5-happy: rlp-desk.md Agent mode contains model upgrade references"
  fi
}

# AC5-negative: rlp-desk.md Agent mode ③ Decide model does not reference auto-upgrade
test_ac5_negative() {
  # Extract Agent mode section and check ③ Decide
  local agent_section
  agent_section=$(awk '/Agent.*Approach|Smart Mode/,/^## [0-9]/' "$CMD" 2>/dev/null)
  if [[ -n "$agent_section" ]]; then
    if ! echo "$agent_section" | grep -qi 'auto.*upgrade\|check_model_upgrade'; then
      pass "AC5-negative: Agent mode ③ does not reference auto-upgrade"
    else
      fail "AC5-negative: Agent mode ③ contains auto-upgrade references"
    fi
  else
    pass "AC5-negative: Agent mode section extraction — no auto-upgrade found"
  fi
}

# AC5-boundary (regression): run_ralph_desk.zsh is tmux-only script
test_ac5_boundary() {
  if head -5 "$RUN" | grep -qi 'tmux\|run_ralph_desk'; then
    pass "AC5-boundary: run_ralph_desk.zsh is tmux runner (confirmed by header)"
  else
    # Fallback: check for tmux commands in script
    if grep -qF 'tmux send-keys' "$RUN"; then
      pass "AC5-boundary: run_ralph_desk.zsh is tmux runner (confirmed by tmux commands)"
    else
      fail "AC5-boundary: run_ralph_desk.zsh tmux identification failed"
    fi
  fi
}

test_ac5_happy
test_ac5_negative
test_ac5_boundary

# ============================================================
# E2E: Runtime verification
# ============================================================
echo ""
echo "--- E2E: Runtime verification ---"

# E2E-upgrade: runtime test — get_next_model returns correct upgrade path
test_e2e_upgrade() {
  local fn_body
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "E2E-upgrade: get_next_model() not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'result_haiku=$(get_next_model "haiku")'
    echo 'result_sonnet=$(get_next_model "sonnet")'
    echo 'result_opus=$(get_next_model "opus")'
    echo 'if [[ "$result_haiku" == "sonnet" && "$result_sonnet" == "opus" && -z "$result_opus" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "haiku->$result_haiku sonnet->$result_sonnet opus->$result_opus" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"

  zsh -f "$tmpdir/harness.zsh" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"

  if (( rc == 0 )); then
    pass "E2E-upgrade: get_next_model returns haiku→sonnet, sonnet→opus, opus→empty"
  else
    fail "E2E-upgrade: get_next_model upgrade path incorrect (rc=$rc)"
  fi
}

# E2E-restore: runtime test — model restore after upgrade
test_e2e_restore() {
  local cmu_body gnm_body gms_body
  cmu_body=$(extract_fn "check_model_upgrade")
  gnm_body=$(extract_fn "get_next_model")
  gms_body=$(extract_fn "get_model_string")
  if [[ -z "$cmu_body" || -z "$gnm_body" ]]; then
    fail "E2E-restore: check_model_upgrade or get_next_model not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log_debug() { : ; }'
    echo 'log() { : ; }'
    echo 'WORKER_MODEL="sonnet"'
    echo '_ORIGINAL_WORKER_MODEL="sonnet"'
    echo '_LAST_FAILED_US=""'
    echo '_SAME_US_FAIL_COUNT=0'
    echo '_MODEL_UPGRADED=0'
    echo "$gms_body"
    echo "$gnm_body"
    echo "$cmu_body"
    echo ''
    echo '# Simulate 2 consecutive fails on same US'
    echo 'check_model_upgrade "US-001"'
    echo 'check_model_upgrade "US-001"'
    echo ''
    echo '# After upgrade: verify model changed'
    echo 'if [[ "$WORKER_MODEL" != "opus" ]]; then'
    echo '  echo "FAIL: model not upgraded to opus (is $WORKER_MODEL)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'if (( _MODEL_UPGRADED != 1 )); then'
    echo '  echo "FAIL: _MODEL_UPGRADED not set" >&2'
    echo '  exit 1'
    echo 'fi'
    echo ''
    echo '# Simulate restore (what pass path would do)'
    echo 'WORKER_MODEL="$_ORIGINAL_WORKER_MODEL"'
    echo '_MODEL_UPGRADED=0'
    echo 'if [[ "$WORKER_MODEL" == "sonnet" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "FAIL: model not restored to sonnet (is $WORKER_MODEL)" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"

  zsh -f "$tmpdir/harness.zsh" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"

  if (( rc == 0 )); then
    pass "E2E-restore: model upgrade + restore cycle works correctly"
  else
    fail "E2E-restore: model upgrade + restore cycle failed (rc=$rc)"
  fi
}

# E2E-syntax: zsh -n syntax check on full source
test_e2e_syntax() {
  if zsh -n "$RUN" 2>/dev/null; then
    pass "E2E-syntax: zsh -n syntax check passes"
  else
    fail "E2E-syntax: zsh -n syntax check FAILED"
  fi
}

test_e2e_upgrade
test_e2e_restore
test_e2e_syntax

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
