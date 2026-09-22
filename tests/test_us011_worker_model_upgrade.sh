#!/usr/bin/env bash
# Test suite: US-011 — Worker Model Auto-Upgrade (tmux mode)
# AC1 (3) + AC2 (3) + AC3 (3) + AC4 (3) + AC5 (3) + E2E (3) = 18 total
# RED tests (fail before impl): AC1-*, AC2-*, AC3-*, AC4-*, E2E-upgrade, E2E-restore
# Regression tests (pass before and after): AC5-happy, AC5-boundary, E2E-syntax

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
CMD="${CMD:-$REPO_ROOT/src/commands/rlp-desk.md}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-011: Worker Model Auto-Upgrade ==="
echo "Target: $RUN"
echo ""

# Helper: extract function body by name from source
# Falls back to LIB when function not found in primary source
_extract_fn_from() {
  local fn_name="$1" src="$2"
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
  ' "$src" 2>/dev/null
}
extract_fn() {
  local fn_name="$1"
  local src="${2:-$RUN}"
  local body
  body="$(_extract_fn_from "$fn_name" "$src")"
  if [[ -z "$body" && "$src" == "$RUN" ]]; then
    body="$(_extract_fn_from "$fn_name" "$LIB")"
  fi
  # US-001: get_next_model resolves its shipped ladder (src/node/models.json)
  # relative to $LIB_DIR (normally set by run_ralph_desk.zsh before sourcing
  # the lib). Isolated single-function harnesses never source
  # run_ralph_desk.zsh, so LIB_DIR would be unset and every extraction would
  # silently fall back to the 3-entry emergency ladder instead of the real
  # shipped file.
  #
  # Hermeticity (Codex P2-1): get_next_model also checks
  # ${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json}. Without a
  # guard, a REAL override file on the machine running these tests would
  # silently win over shipped defaults. The self-referential ${VAR:-default}
  # only applies if the harness hasn't already set RLP_DESK_MODELS_FILE
  # itself, so it never clobbers a test that intentionally sets its own
  # (assignment order: an explicit test-specific line always wins, whether
  # it runs before this default or after it).
  if [[ "$fn_name" == "get_next_model" && -n "$body" ]]; then
    body="LIB_DIR=\"$REPO_ROOT/src/scripts\"
RLP_DESK_MODELS_FILE=\"\${RLP_DESK_MODELS_FILE:-/nonexistent-hermetic-test-guard/rlp-desk-models.json}\"
$body"
  fi
  printf '%s\n' "$body"
}

# D-5b restore snippet lives inline inside main() (not its own function, so
# extract_fn can't pull it out) — extracted by CONTENT, not a hardcoded line
# range, so it survives unrelated edits shifting line numbers elsewhere in
# the file (a hardcoded 'sed -n N,Mp' range silently extracted the WRONG
# lines the first time this file grew by one line above it). Captures from
# the `local _status_mu` declaration through the outer if's closing `fi`
# (4-space indent, after the inner `if [[ "$_status_mu" ...` has been seen).
_extract_d5b_snippet() {
  awk '
    /local _status_mu/ { capture=1 }
    capture { print; if (started_if && $0 ~ /^    fi$/) { exit } }
    capture && /if \[\[ "\$_status_mu"/ { started_if=1 }
  ' "$RUN"
}

# Pass-verdict model-restore block lives inline inside main() (not its own
# function, so extract_fn can't pull it out either) — extracted by CONTENT,
# the same technique as _extract_d5b_snippet above, so it survives unrelated
# edits shifting line numbers elsewhere in the file. Captures from the
# `if (( _MODEL_UPGRADED )); then` line (anchored by the following unique
# "Worker model restored:" log line, so a coincidental unrelated
# `_MODEL_UPGRADED` check elsewhere would not falsely trigger capture)
# through the outer if's closing `fi` (12-space indent, after `_MODEL_UPGRADED=0`
# — the reset line — has been seen).
_extract_pass_restore_snippet() {
  awk '
    /if \(\( _MODEL_UPGRADED \)\); then/ { capture=1 }
    capture { print; if (seen_reset && $0 ~ /^            fi$/) { exit } }
    capture && /_MODEL_UPGRADED=0/ { seen_reset=1 }
  ' "$RUN"
}

# ============================================================
# AC1: Auto-upgrade trigger (2 consecutive same-US fails → upgrade)
# ============================================================
echo "--- AC1: Auto-upgrade trigger ---"

# AC1-happy: check_model_upgrade() function exists (now in LIB)
test_ac1_happy() {
  if grep -qF 'check_model_upgrade()' "$RUN" 2>/dev/null || grep -qF 'check_model_upgrade()' "$LIB" 2>/dev/null; then
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

# AC1-boundary: [DECIDE] model_upgrade=true log format in source (now in LIB)
test_ac1_boundary() {
  local _f _found_upgrade=0 _found_reason=0
  for _f in "$RUN" "$LIB"; do
    grep -qF 'model_upgrade=true' "$_f" 2>/dev/null && _found_upgrade=1
    grep -qF 'reason=consecutive_same_ac_fail' "$_f" 2>/dev/null && _found_reason=1
  done
  if (( _found_upgrade && _found_reason )); then
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

# AC2-happy: pass verdict path has model restore logic (now in LIB/RUN)
test_ac2_happy() {
  local _f _found_upgraded=0 _found_original=0
  for _f in "$RUN" "$LIB"; do
    grep -qF '_MODEL_UPGRADED' "$_f" 2>/dev/null && _found_upgraded=1
    grep -qF '_ORIGINAL_WORKER_MODEL' "$_f" 2>/dev/null && _found_original=1
  done
  if (( _found_upgraded && _found_original )); then
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

# AC2-boundary: model_restore debug log exists (now in LIB or RUN)
test_ac2_boundary() {
  if grep -qF 'model_restore=true' "$RUN" 2>/dev/null || grep -qF 'model_restore=true' "$LIB" 2>/dev/null; then
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

# AC3-happy: Architecture Escalation triggered when upgraded model fails (in RUN or LIB)
test_ac3_happy() {
  if grep -qEi 'architecture.escalation|model_upgrade.*escalat|upgraded.*retry.*fail' "$RUN" 2>/dev/null || \
     grep -qEi 'architecture.escalation|model_upgrade.*escalat|upgraded.*retry.*fail' "$LIB" 2>/dev/null; then
    pass "AC3-happy: Architecture Escalation reference in upgrade context"
  else
    fail "AC3-happy: Architecture Escalation missing in upgrade fail path"
  fi
}

# AC3-negative: write_blocked_sentinel called with escalation reason (in RUN or LIB)
test_ac3_negative() {
  if grep -qE 'write_blocked_sentinel.*([Uu]pgrade|[Ee]scalat)' "$RUN" 2>/dev/null || \
     grep -qE 'write_blocked_sentinel.*([Uu]pgrade|[Ee]scalat)' "$LIB" 2>/dev/null; then
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

# AC4-negative: [DECIDE] model_upgrade=false reason=already_max log format (in RUN or LIB)
test_ac4_negative() {
  local _f _found_false=0 _found_max=0
  for _f in "$RUN" "$LIB"; do
    grep -qF 'model_upgrade=false' "$_f" 2>/dev/null && _found_false=1
    grep -qF 'reason=already_max' "$_f" 2>/dev/null && _found_max=1
  done
  if (( _found_false && _found_max )); then
    pass "AC4-negative: [DECIDE] model_upgrade=false reason=already_max present"
  else
    fail "AC4-negative: already_max log format missing"
  fi
}

# AC4-boundary: get_next_model returns empty/no-upgrade for opus (now in LIB)
test_ac4_boundary() {
  if grep -qF 'get_next_model()' "$RUN" 2>/dev/null || grep -qF 'get_next_model()' "$LIB" 2>/dev/null; then
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
    # A codex case is included so this test cannot pass "by coincidence" via
    # the 4-entry emergency fallback ladder (which only has claude entries,
    # and — since the Fable 5.1 wave — now ALSO resolves opus->fable:max
    # identically to the shipped ladder, so the claude cases alone no longer
    # discriminate real-vs-emergency) — the codex case forces the shipped
    # src/node/models.json resolution path to be real.
    echo 'result_codex=$(get_next_model "gpt-5.6-sol:low")'
    echo 'if [[ "$result_haiku" == "sonnet" && "$result_sonnet" == "opus" && "$result_opus" == "claude-fable-5-1:max" && "$result_codex" == "gpt-5.6-sol:medium" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "haiku->$result_haiku sonnet->$result_sonnet opus->$result_opus codex->$result_codex" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"

  zsh -f "$tmpdir/harness.zsh" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"

  if (( rc == 0 )); then
    pass "E2E-upgrade: get_next_model returns haiku→sonnet, sonnet→opus, opus→claude-fable-5-1:max, gpt-5.6-sol:low→medium"
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

# E2E-claude-production-shape (A-1 regression): reproduces the REAL production
# variable shape for a claude-engine campaign. run_ralph_desk.zsh:489-490
# unconditionally default WORKER_CODEX_MODEL/WORKER_CODEX_REASONING regardless
# of WORKER_ENGINE, so a claude campaign always has WORKER_CODEX_MODEL set
# (gpt-5.6-luna — luna-first cheap-tier start, was gpt-5.5; briefly astra
# mid-wave, reverted by owner correction since the worker default must never
# equal the ladder ceiling) alongside WORKER_ENGINE=claude. The 55
# pre-existing tests here never set WORKER_CODEX_MODEL, so they passed even
# while check_model_upgrade's engine-blind `${WORKER_CODEX_MODEL:-$WORKER_MODEL}`
# lookup silently resolved every claude campaign's ladder key to the bare
# codex-default string (no bare key for it in models.json -> get_next_model
# returns "" -> already_max, never upgrades).
test_e2e_claude_engine_production_shape() {
  local cmu_body gnm_body gms_body
  cmu_body=$(extract_fn "check_model_upgrade")
  gnm_body=$(extract_fn "get_next_model")
  gms_body=$(extract_fn "get_model_string")
  if [[ -z "$cmu_body" || -z "$gnm_body" ]]; then
    fail "E2E-claude-prod-shape: check_model_upgrade or get_next_model not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log_debug() { : ; }'
    echo 'log() { : ; }'
    # Production shape: run_ralph_desk.zsh:464/486/489-490 for a claude campaign.
    echo 'WORKER_ENGINE="claude"'
    echo 'WORKER_MODEL="haiku"'
    echo 'WORKER_CODEX_MODEL="gpt-5.6-luna"'
    echo 'WORKER_CODEX_REASONING="high"'
    echo '_ORIGINAL_WORKER_MODEL=""'
    echo '_ORIGINAL_WORKER_CODEX_REASONING=""'
    echo '_LAST_FAILED_US=""'
    echo '_SAME_US_FAIL_COUNT=0'
    echo '_MODEL_UPGRADED=0'
    echo '_MODEL_LADDER_WARNED=0'
    echo "LIB_DIR=\"$REPO_ROOT/src/scripts\""
    echo 'RLP_DESK_MODELS_FILE="/nonexistent-hermetic-test-guard/rlp-desk-models.json"'
    echo "$gms_body"
    echo "$gnm_body"
    echo "$cmu_body"
    echo ''
    echo '# Simulate 2 consecutive fails on same US (production var shape)'
    echo 'check_model_upgrade "US-001"'
    echo 'check_model_upgrade "US-001"'
    echo ''
    echo 'if [[ "$WORKER_MODEL" != "sonnet" ]]; then'
    echo '  echo "FAIL: claude engine did not upgrade haiku->sonnet (WORKER_MODEL=$WORKER_MODEL)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'if (( _MODEL_UPGRADED != 1 )); then'
    echo '  echo "FAIL: _MODEL_UPGRADED not set" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'exit 0'
  } > "$tmpdir/harness.zsh"

  local out
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  local rc=$?
  rm -rf "$tmpdir"

  if (( rc == 0 )); then
    pass "E2E-claude-prod-shape: claude engine upgrades haiku->sonnet even with WORKER_CODEX_MODEL set (production shape)"
  else
    fail "E2E-claude-prod-shape: $out"
  fi
}

# E2E-codex-engine-shape: codex path must keep behaving exactly as before —
# ladder keyed off WORKER_CODEX_MODEL:WORKER_CODEX_REASONING.
test_e2e_codex_engine_shape() {
  local cmu_body gnm_body gms_body
  cmu_body=$(extract_fn "check_model_upgrade")
  gnm_body=$(extract_fn "get_next_model")
  gms_body=$(extract_fn "get_model_string")
  if [[ -z "$cmu_body" || -z "$gnm_body" ]]; then
    fail "E2E-codex-shape: check_model_upgrade or get_next_model not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log_debug() { : ; }'
    echo 'log() { : ; }'
    echo 'WORKER_ENGINE="codex"'
    echo 'WORKER_MODEL="gpt-5.6-sol"'
    echo 'WORKER_CODEX_MODEL="gpt-5.6-sol"'
    echo 'WORKER_CODEX_REASONING="medium"'
    echo '_ORIGINAL_WORKER_MODEL=""'
    echo '_ORIGINAL_WORKER_CODEX_REASONING=""'
    echo '_LAST_FAILED_US=""'
    echo '_SAME_US_FAIL_COUNT=0'
    echo '_MODEL_UPGRADED=0'
    echo '_MODEL_LADDER_WARNED=0'
    echo "LIB_DIR=\"$REPO_ROOT/src/scripts\""
    echo 'RLP_DESK_MODELS_FILE="/nonexistent-hermetic-test-guard/rlp-desk-models.json"'
    echo "$gms_body"
    echo "$gnm_body"
    echo "$cmu_body"
    echo ''
    echo 'check_model_upgrade "US-001"'
    echo 'check_model_upgrade "US-001"'
    echo ''
    echo 'if [[ "$WORKER_CODEX_REASONING" != "high" ]]; then'
    echo '  echo "FAIL: codex engine did not upgrade medium->high (WORKER_CODEX_REASONING=$WORKER_CODEX_REASONING)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'if [[ "$WORKER_CODEX_MODEL" != "gpt-5.6-sol" || "$WORKER_MODEL" != "gpt-5.6-sol" ]]; then'
    echo '  echo "FAIL: codex model should stay gpt-5.6-sol (WORKER_CODEX_MODEL=$WORKER_CODEX_MODEL WORKER_MODEL=$WORKER_MODEL)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'exit 0'
  } > "$tmpdir/harness.zsh"

  local out
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  local rc=$?
  rm -rf "$tmpdir"

  if (( rc == 0 )); then
    pass "E2E-codex-shape: codex engine upgrades gpt-5.6-sol:medium->gpt-5.6-sol:high (unchanged behavior)"
  else
    fail "E2E-codex-shape: $out"
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
test_e2e_claude_engine_production_shape
test_e2e_codex_engine_shape
test_e2e_syntax

# ============================================================
# US-001: Single-source the Worker model-upgrade ladder + user override
# ============================================================
echo ""
echo "--- US-001: Single-source model ladder ---"

MODELS_JSON="$REPO_ROOT/src/node/models.json"

# override-precedence: RLP_DESK_MODELS_FILE wins over shipped defaults
test_us001_override_precedence() {
  local fn_body tmpdir
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-override: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  echo '{"upgrades": {"haiku": "custom-override-model"}}' > "$tmpdir/override.json"
  {
    echo '#!/usr/bin/env zsh -f'
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/override.json\""
    echo "$fn_body"
    echo 'r=$(get_next_model "haiku")'
    echo '[[ "$r" == "custom-override-model" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-override: RLP_DESK_MODELS_FILE override wins over shipped defaults"
  else
    fail "US001-override: override not honored ($out)"
  fi
}

# absent-override: no override file present -> shipped defaults used
test_us001_absent_override_uses_defaults() {
  local fn_body tmpdir
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-absent: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/does-not-exist.json\""
    echo "$fn_body"
    echo 'r=$(get_next_model "haiku")'
    echo '[[ "$r" == "sonnet" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-absent: no override file -> shipped defaults (haiku->sonnet)"
  else
    fail "US001-absent: shipped defaults not used ($out)"
  fi
}

# malformed-warn-fallthrough: malformed override JSON falls through to shipped
# defaults with a warning on stderr, never crashes.
test_us001_malformed_warns_and_falls_through() {
  local fn_body tmpdir
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-malformed: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  echo 'not valid json {{{' > "$tmpdir/override.json"
  {
    echo '#!/usr/bin/env zsh -f'
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/override.json\""
    # get_next_model's own body calls log_error() on the warning path (a
    # separate function defined elsewhere in lib_ralph_desk.zsh, not part of
    # this single-function extraction) — stub it here to capture the call
    # instead of letting it fail with "command not found".
    echo "log_error() { echo \"\$*\" >> \"$tmpdir/warn.log\"; }"
    echo "$fn_body"
    echo 'r=$(get_next_model "haiku")'
    echo '[[ "$r" == "sonnet" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
  } > "$tmpdir/harness.zsh"
  local out rc warned=0
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  [[ -s "$tmpdir/warn.log" ]] && grep -qi 'malformed\|unreadable' "$tmpdir/warn.log" && warned=1
  rm -rf "$tmpdir"
  if (( rc == 0 && warned == 1 )); then
    pass "US001-malformed: malformed override warns + falls through to shipped defaults (never crashes)"
  else
    fail "US001-malformed: malformed override handling wrong (rc=$rc warned=$warned out=$out)"
  fi
}

# schema-validation (Codex P1): a syntactically-valid JSON file whose
# upgrades VALUE isn't a string (e.g. {"upgrades":{"haiku":123}}) must be
# treated as a malformed layer -> warn + fall through, not resolved into
# junk output (e.g. echoing the literal text "123").
test_us001_schema_validation_rejects_non_string_values() {
  local fn_body tmpdir label bad_json
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-schema: get_next_model() not found"
    return
  fi
  for label in number boolean null object array; do
    case "$label" in
      number)  bad_json='{"upgrades": {"haiku": 123}}' ;;
      boolean) bad_json='{"upgrades": {"haiku": true}}' ;;
      null)    bad_json='{"upgrades": {"haiku": null}}' ;;
      object)  bad_json='{"upgrades": {"haiku": {"nested": true}}}' ;;
      array)   bad_json='{"upgrades": {"haiku": ["sonnet"]}}' ;;
    esac
    tmpdir=$(mktemp -d)
    echo "$bad_json" > "$tmpdir/override.json"
    {
      echo '#!/usr/bin/env zsh -f'
      echo "RLP_DESK_MODELS_FILE=\"$tmpdir/override.json\""
      echo "log_error() { echo \"\$*\" >> \"$tmpdir/warn.log\"; }"
      echo "$fn_body"
      echo 'r=$(get_next_model "haiku")'
      echo '[[ "$r" == "sonnet" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
    } > "$tmpdir/harness.zsh"
    local out rc warned=0
    out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
    rc=$?
    [[ -s "$tmpdir/warn.log" ]] && grep -qi 'malformed\|unreadable' "$tmpdir/warn.log" && warned=1
    rm -rf "$tmpdir"
    if (( rc == 0 && warned == 1 )); then
      pass "US001-schema: $label upgrades value rejected -> falls through to shipped defaults"
    else
      fail "US001-schema: $label upgrades value NOT rejected (rc=$rc warned=$warned out=$out)"
    fi
  done
  return 0
}

# dual-layout: installed flat layout ($LIB_DIR/node/models.json)
test_us001_dual_layout_installed_flat() {
  local fn_body tmpdir
  fn_body=$(_extract_fn_from "get_next_model" "$LIB")
  [[ -z "$fn_body" ]] && fn_body=$(_extract_fn_from "get_next_model" "$RUN")
  if [[ -z "$fn_body" ]]; then
    fail "US001-layout-flat: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/node"
  # A distinctive fixture value (not "sonnet") proves the function actually
  # READ this planted file rather than trivially satisfying the assertion
  # via its own hardcoded/default behavior.
  echo '{"upgrades": {"haiku": "flat-layout-marker"}}' > "$tmpdir/node/models.json"
  {
    echo '#!/usr/bin/env zsh -f'
    echo "LIB_DIR=\"$tmpdir\""
    # Hermeticity (Codex P2-1): guard against a real override on the machine
    # running this test — see extract_fn's comment for the same guard.
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/no-such-override.json\""
    echo "$fn_body"
    echo 'r=$(get_next_model "haiku")'
    echo '[[ "$r" == "flat-layout-marker" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-layout-flat: installed flat layout (\$LIB_DIR/node/models.json) resolves"
  else
    fail "US001-layout-flat: installed flat layout resolution failed ($out)"
  fi
}

# dual-layout: source checkout layout ($LIB_DIR/../node/models.json)
test_us001_dual_layout_checkout() {
  local fn_body tmpdir
  fn_body=$(_extract_fn_from "get_next_model" "$LIB")
  [[ -z "$fn_body" ]] && fn_body=$(_extract_fn_from "get_next_model" "$RUN")
  if [[ -z "$fn_body" ]]; then
    fail "US001-layout-checkout: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/src/scripts" "$tmpdir/src/node"
  # Distinctive fixture value — see US001-layout-flat comment above.
  echo '{"upgrades": {"haiku": "checkout-layout-marker"}}' > "$tmpdir/src/node/models.json"
  {
    echo '#!/usr/bin/env zsh -f'
    echo "LIB_DIR=\"$tmpdir/src/scripts\""
    # Hermeticity (Codex P2-1): guard against a real override on the machine
    # running this test — see extract_fn's comment for the same guard.
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/no-such-override.json\""
    echo "$fn_body"
    echo 'r=$(get_next_model "haiku")'
    echo '[[ "$r" == "checkout-layout-marker" ]] && exit 0 || { echo "got: $r" >&2; exit 1; }'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-layout-checkout: source-checkout layout (\$LIB_DIR/../node/models.json) resolves"
  else
    fail "US001-layout-checkout: source-checkout layout resolution failed ($out)"
  fi
}

# emergency-fallback: both override and shipped unreadable -> 4-entry inline ladder
test_us001_emergency_fallback() {
  local fn_body tmpdir
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-emergency: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "RLP_DESK_MODELS_FILE=\"$tmpdir/does-not-exist-override.json\""
    echo "LIB_DIR=\"$tmpdir/nonexistent-lib-dir\""
    echo "$fn_body"
    echo 'a=$(get_next_model "haiku")'
    echo 'b=$(get_next_model "sonnet")'
    echo 'c=$(get_next_model "opus")'
    echo 'd=$(get_next_model "claude-fable-5-1")'
    echo 'if [[ "$a" == "sonnet" && "$b" == "opus" && "$c" == "claude-fable-5-1:max" && -z "$d" ]]; then exit 0; else echo "a=$a b=$b c=$c d=$d" >&2; exit 1; fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-emergency: both layers unreadable -> emergency inline ladder (haiku->sonnet->opus->claude-fable-5-1:max->ceiling)"
  else
    fail "US001-emergency: emergency fallback wrong ($out)"
  fi
}

# equivalence: for every key in the shipped models.json, zsh get_next_model
# and the Node loadModelLadder() resolve to the same next-model decision
# (with the ""<->'BLOCKED' ceiling normalization applied).
test_us001_zsh_node_equivalence() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "US001-equivalence: jq not available"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    fail "US001-equivalence: node not available"
    return
  fi
  local fn_body tmpdir mismatches=0 key zsh_next node_next
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "US001-equivalence: get_next_model() not found"
    return
  fi
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'get_next_model "$1"'
  } > "$tmpdir/get_next_model.zsh"

  local keys
  keys=$(jq -r '.upgrades | keys[]' "$MODELS_JSON" 2>/dev/null)
  if [[ -z "$keys" ]]; then
    fail "US001-equivalence: no keys read from $MODELS_JSON (missing or empty — cannot compare)"
    return
  fi
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    zsh_next=$(zsh -f "$tmpdir/get_next_model.zsh" "$key" 2>/dev/null)
    [[ -z "$zsh_next" ]] && zsh_next="BLOCKED"  # "" <-> BLOCKED ceiling normalization
    # Hermeticity (Codex P2-1): explicit overrideFile pointing at a path that
    # cannot exist, so a real ~/.claude/rlp-desk-models.json on the machine
    # running this test can never silently win over shipped defaults here.
    node_next=$(REPO_ROOT="$REPO_ROOT" node -e '
      import("file://" + process.env.REPO_ROOT + "/src/node/model-ladder.mjs").then(({ loadModelLadder }) => {
        const ladder = loadModelLadder({ overrideFile: "/nonexistent-hermetic-test-guard/rlp-desk-models.json" });
        process.stdout.write(ladder[process.argv[1]] ?? "BLOCKED");
      });
    ' "$key" 2>/dev/null)
    if [[ "$zsh_next" != "$node_next" ]]; then
      echo "  mismatch: $key -> zsh=$zsh_next node=$node_next" >&2
      (( mismatches++ ))
    fi
  done <<< "$keys"
  rm -rf "$tmpdir"

  if (( mismatches == 0 )); then
    pass "US001-equivalence: zsh get_next_model and Node loadModelLadder agree on every shipped key"
  else
    fail "US001-equivalence: $mismatches key(s) disagree between zsh and Node"
  fi
}

test_us001_override_precedence
test_us001_absent_override_uses_defaults
test_us001_malformed_warns_and_falls_through
test_us001_schema_validation_rejects_non_string_values
test_us001_dual_layout_installed_flat
test_us001_dual_layout_checkout
test_us001_emergency_fallback
test_us001_zsh_node_equivalence

# ============================================================
# AC6: environment/flaky failure_category must not feed the ladder
# ============================================================
echo ""
echo "--- AC6: environment/flaky failure_category guard ---"

# AC6: environment/flaky failure_category must not feed the upgrade ladder
test_ac6_environment_guard() {
  local ctx
  ctx=$(grep -n -B2 -A6 'check_model_upgrade ' "$RUN" 2>/dev/null | grep -v 'check_model_upgrade()')
  if echo "$ctx" | grep -q 'failure_category'; then
    pass "AC6: check_model_upgrade call is guarded by failure_category"
  else
    fail "AC6: no failure_category guard around check_model_upgrade invocation"
  fi
  if echo "$ctx" | grep -qE 'environment'; then
    pass "AC6b: guard covers 'environment' category"
  else
    fail "AC6b: 'environment' category not handled"
  fi
}

test_ac6_environment_guard

# ============================================================
# Fable 5.1 / Codex 6 Astra: new-model support
# ============================================================
echo ""
echo "--- Fable 5.1 / Codex 6 Astra ---"

# gpt-6-astra: self-escalating ladder mirrors gpt-5.6-sol's shape
# (low->medium->high->xhigh ceiling; max/ultra are manual-start dead ends).
# See src/model-upgrade-table.md "GPT-6 — Astra" for the live-probe evidence
# behind this shape (minimal confirmed rejected; low/medium/high/xhigh/max
# confirmed; ultra accepted but unconfirmed as distinct).
test_gpt6_astra_ladder() {
  local fn_body
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "astra-ladder: get_next_model() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'r_low=$(get_next_model "gpt-6-astra:low")'
    echo 'r_med=$(get_next_model "gpt-6-astra:medium")'
    echo 'r_high=$(get_next_model "gpt-6-astra:high")'
    echo 'r_xhigh=$(get_next_model "gpt-6-astra:xhigh")'
    echo 'if [[ "$r_low" == "gpt-6-astra:medium" && "$r_med" == "gpt-6-astra:high" && "$r_high" == "gpt-6-astra:xhigh" && -z "$r_xhigh" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "low->$r_low medium->$r_med high->$r_high xhigh->$r_xhigh" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "astra-ladder: gpt-6-astra escalates low->medium->high->xhigh, xhigh is ceiling"
  else
    fail "astra-ladder: $out"
  fi
}

# Owner decision (applied): gpt-6-astra IS the real ceiling of the whole
# ladder now — gpt-5.6-sol:xhigh escalates into gpt-6-astra:high (one rung
# below astra's own ceiling, matching the terra:xhigh -> sol:high rule).
# INVERTED from the earlier "sol:xhigh stays terminal" version of this test
# (that was the pre-owner-decision contract) — this is the mutation control:
# it fails if a future edit re-terminates sol:xhigh or unwires the escalation.
test_gpt6_sol_escalates_into_astra() {
  local fn_body
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "astra-sol-ceiling: get_next_model() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'r_sol=$(get_next_model "gpt-5.6-sol:xhigh")'
    echo 'r_astra=$(get_next_model "gpt-6-astra:xhigh")'
    echo 'if [[ "$r_sol" == "gpt-6-astra:high" && -z "$r_astra" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "sol:xhigh -> $r_sol (expected gpt-6-astra:high) / astra:xhigh -> $r_astra (expected ceiling/empty)" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "astra-sol-ceiling: gpt-5.6-sol:xhigh escalates into gpt-6-astra:high; astra:xhigh is the real ceiling"
  else
    fail "astra-sol-ceiling: $out"
  fi
}

# _auto_detect_engine (run_ralph_desk.zsh's env-var-path model detector,
# separate implementation from parse_model_flag) must accept both new models.
test_auto_detect_engine_new_models() {
  local fn_body
  fn_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$fn_body" ]]; then
    fail "auto-detect-new-models: _auto_detect_engine() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'WORKER_MODEL="claude-fable-5-1:max"'
    echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
    echo 'if [[ "$WORKER_ENGINE" != "claude" || "$WORKER_MODEL" != "claude-fable-5-1" || "$WORKER_EFFORT" != "max" ]]; then'
    echo '  echo "fable-5-1: engine=$WORKER_ENGINE model=$WORKER_MODEL effort=$WORKER_EFFORT" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'VERIFIER_MODEL="gpt-6-astra:high"'
    echo '_auto_detect_engine VERIFIER_MODEL VERIFIER_ENGINE VERIFIER_CODEX_MODEL VERIFIER_CODEX_REASONING'
    echo 'if [[ "$VERIFIER_ENGINE" != "codex" || "$VERIFIER_MODEL" != "gpt-6-astra" || "$VERIFIER_CODEX_REASONING" != "high" ]]; then'
    echo '  echo "astra: engine=$VERIFIER_ENGINE model=$VERIFIER_MODEL reasoning=$VERIFIER_CODEX_REASONING" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'FINAL_VERIFIER_MODEL="astra:xhigh"'
    echo '_auto_detect_engine FINAL_VERIFIER_MODEL FINAL_VERIFIER_ENGINE FINAL_VERIFIER_CODEX_MODEL FINAL_VERIFIER_CODEX_REASONING'
    echo 'if [[ "$FINAL_VERIFIER_ENGINE" != "codex" || "$FINAL_VERIFIER_MODEL" != "gpt-6-astra" || "$FINAL_VERIFIER_CODEX_REASONING" != "xhigh" ]]; then'
    echo '  echo "astra-alias: engine=$FINAL_VERIFIER_ENGINE model=$FINAL_VERIFIER_MODEL reasoning=$FINAL_VERIFIER_CODEX_REASONING" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'exit 0'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "auto-detect-new-models: _auto_detect_engine accepts claude-fable-5-1:max, gpt-6-astra:high, and the astra:xhigh alias"
  else
    fail "auto-detect-new-models: $out"
  fi
}

# bare `fable` alias — REAL bug found and fixed in the Fable 5.1 wave: it was
# missing from _auto_detect_engine's claude-alias case pattern (which only
# matched claude-* for versioned ids), so `--worker-model fable` was
# misclassified as codex.
test_auto_detect_engine_fable_alias() {
  local fn_body
  fn_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$fn_body" ]]; then
    fail "auto-detect-fable-alias: _auto_detect_engine() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'WORKER_MODEL="fable:max"'
    echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
    echo 'if [[ "$WORKER_ENGINE" != "claude" || "$WORKER_MODEL" != "fable" || "$WORKER_EFFORT" != "max" ]]; then'
    echo '  echo "fable: engine=$WORKER_ENGINE model=$WORKER_MODEL effort=$WORKER_EFFORT" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'exit 0'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "auto-detect-fable-alias: _auto_detect_engine classifies bare fable:max as engine=claude, model=fable, effort=max"
  else
    fail "auto-detect-fable-alias: $out"
  fi
}

# Model-aware reasoning gate: gpt-6-astra rejects 'minimal' (server-confirmed
# HTTP 400, see src/model-upgrade-table.md "GPT-6 — Astra"); every other
# codex model must still accept it — never a blanket vocabulary narrowing.
test_auto_detect_engine_astra_minimal_rejected() {
  local fn_body
  fn_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$fn_body" ]]; then
    fail "auto-detect-astra-minimal: _auto_detect_engine() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)

  # Case 1: gpt-6-astra:minimal (full slug) must be rejected (non-zero exit).
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'WORKER_MODEL="gpt-6-astra:minimal"'
    echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
  } > "$tmpdir/case1.zsh"
  zsh -f "$tmpdir/case1.zsh" >/dev/null 2>&1
  local rc1=$?

  # Case 2: astra:minimal (alias, expanded to gpt-6-astra before the check)
  # must ALSO be rejected.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'VERIFIER_MODEL="astra:minimal"'
    echo '_auto_detect_engine VERIFIER_MODEL VERIFIER_ENGINE VERIFIER_CODEX_MODEL VERIFIER_CODEX_REASONING'
  } > "$tmpdir/case2.zsh"
  zsh -f "$tmpdir/case2.zsh" >/dev/null 2>&1
  local rc2=$?

  # Case 3 (regression): gpt-5.5:minimal — a DIFFERENT codex model — must
  # still be ACCEPTED. Proves the gate is model-specific, not a blanket
  # removal of 'minimal' from the shared vocabulary.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'FINAL_VERIFIER_MODEL="gpt-5.5:minimal"'
    echo '_auto_detect_engine FINAL_VERIFIER_MODEL FINAL_VERIFIER_ENGINE FINAL_VERIFIER_CODEX_MODEL FINAL_VERIFIER_CODEX_REASONING'
    echo '[[ "$FINAL_VERIFIER_CODEX_REASONING" == "minimal" ]] && exit 0 || { echo "reasoning=$FINAL_VERIFIER_CODEX_REASONING" >&2; exit 1; }'
  } > "$tmpdir/case3.zsh"
  local out3
  out3=$(zsh -f "$tmpdir/case3.zsh" 2>&1)
  local rc3=$?

  rm -rf "$tmpdir"
  if (( rc1 != 0 && rc2 != 0 && rc3 == 0 )); then
    pass "auto-detect-astra-minimal: gpt-6-astra:minimal and astra:minimal rejected; gpt-5.5:minimal still accepted (model-specific gate)"
  else
    fail "auto-detect-astra-minimal: rc1=$rc1 (want != 0) rc2=$rc2 (want != 0) rc3=$rc3 (want 0, out=$out3)"
  fi
}

# SV-gate CRITICAL fix: parse_model_flag() (the ACTUAL CLI --worker-model/
# --verifier-model/--final-verifier-model flag parser every real user
# invocation goes through) had ZERO reasoning-vocabulary validation before
# this fix — the gpt-6-astra:minimal rejection above only ever lived in
# _auto_detect_engine, the env-var path nobody actually uses through the CLI.
# This is the mirror of test_auto_detect_engine_astra_minimal_rejected but
# exercises parse_model_flag directly, proving the CLI path now rejects the
# same inputs. Both functions now call the SAME shared _validate_model_level
# (factored so the two cannot drift), so both must be sourced together.
test_parse_model_flag_astra_minimal_rejected() {
  local vml_body pmf_body
  vml_body=$(_extract_fn_from "_validate_model_level" "$LIB")
  pmf_body=$(_extract_fn_from "parse_model_flag" "$LIB")
  if [[ -z "$vml_body" || -z "$pmf_body" ]]; then
    fail "parse-model-flag-astra-minimal: _validate_model_level or parse_model_flag not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)

  # Case 1: gpt-6-astra:minimal (full slug) must be rejected (non-zero exit).
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$pmf_body"
    echo 'parse_model_flag "gpt-6-astra:minimal" "worker"'
  } > "$tmpdir/case1.zsh"
  zsh -f "$tmpdir/case1.zsh" >/dev/null 2>&1
  local rc1=$?

  # Case 2: astra:minimal (alias, expanded to gpt-6-astra before the check)
  # must ALSO be rejected.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$pmf_body"
    echo 'parse_model_flag "astra:minimal" "verifier"'
  } > "$tmpdir/case2.zsh"
  zsh -f "$tmpdir/case2.zsh" >/dev/null 2>&1
  local rc2=$?

  # Case 3 (regression): gpt-5.5:minimal — a DIFFERENT codex model — must
  # still be ACCEPTED, and echo the split "codex gpt-5.5 minimal" triple.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$pmf_body"
    echo 'out=$(parse_model_flag "gpt-5.5:minimal" "final-verifier") || exit 1'
    echo '[[ "$out" == "codex gpt-5.5 minimal" ]] && exit 0 || { echo "out=$out" >&2; exit 1; }'
  } > "$tmpdir/case3.zsh"
  local out3
  out3=$(zsh -f "$tmpdir/case3.zsh" 2>&1)
  local rc3=$?

  rm -rf "$tmpdir"
  if (( rc1 != 0 && rc2 != 0 && rc3 == 0 )); then
    pass "parse-model-flag-astra-minimal: gpt-6-astra:minimal and astra:minimal rejected via the CLI-flag path; gpt-5.5:minimal still accepted"
  else
    fail "parse-model-flag-astra-minimal: rc1=$rc1 (want != 0) rc2=$rc2 (want != 0) rc3=$rc3 (want 0, out=$out3)"
  fi
}

# Explicit parity assertion (team-lead's exact requirement): the CLI-flag
# path (parse_model_flag) and the env-var path (_auto_detect_engine) must
# accept and reject the SAME set of inputs. Runs a shared input table through
# both and asserts every input's accept/reject verdict agrees.
test_cli_env_validation_parity() {
  local vml_body pmf_body ade_body
  vml_body=$(_extract_fn_from "_validate_model_level" "$LIB")
  pmf_body=$(_extract_fn_from "parse_model_flag" "$LIB")
  ade_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$vml_body" || -z "$pmf_body" || -z "$ade_body" ]]; then
    fail "cli-env-parity: _validate_model_level, parse_model_flag, or _auto_detect_engine not found"
    return
  fi

  # value -> expect ("accept" or "reject")
  local -a cases=(
    "haiku:high:accept"
    "opus:max:accept"
    "opus:extreme:reject"
    "gpt-5.5:medium:accept"
    "gpt-5.5:minimal:accept"
    "gpt-5.5:bogus:reject"
    "sol:xhigh:accept"
    "astra:high:accept"
    "gpt-6-astra:xhigh:accept"
    "gpt-6-astra:minimal:reject"
    "astra:minimal:reject"
    "claude-fable-5-1:max:accept"
  )

  local tmpdir
  tmpdir=$(mktemp -d)
  local mismatches=""
  local entry value expect cli_rc env_rc
  for entry in "${cases[@]}"; do
    value="${entry%%:*}"
    # value itself may contain a colon (model:level) — strip only the
    # trailing :accept/:reject tag, keep the model:level pair intact.
    value="${entry%:accept}"; value="${value%:reject}"
    expect="${entry##*:}"

    {
      echo '#!/usr/bin/env zsh -f'
      echo "$vml_body"
      echo "$pmf_body"
      echo "parse_model_flag '$value' 'worker'"
    } > "$tmpdir/cli.zsh"
    zsh -f "$tmpdir/cli.zsh" >/dev/null 2>&1
    cli_rc=$?

    {
      echo '#!/usr/bin/env zsh -f'
      echo "$ade_body"
      echo "WORKER_MODEL='$value'"
      echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
    } > "$tmpdir/env.zsh"
    zsh -f "$tmpdir/env.zsh" >/dev/null 2>&1
    env_rc=$?

    local cli_verdict env_verdict
    [[ $cli_rc -eq 0 ]] && cli_verdict="accept" || cli_verdict="reject"
    [[ $env_rc -eq 0 ]] && env_verdict="accept" || env_verdict="reject"

    if [[ "$cli_verdict" != "$expect" || "$env_verdict" != "$expect" ]]; then
      mismatches="$mismatches [$value: want=$expect cli=$cli_verdict env=$env_verdict]"
    fi
  done
  rm -rf "$tmpdir"

  if [[ -z "$mismatches" ]]; then
    pass "cli-env-parity: parse_model_flag (CLI path) and _auto_detect_engine (env path) accept/reject identically across ${#cases[@]} cases"
  else
    fail "cli-env-parity: mismatches -$mismatches"
  fi
}

# Same asymmetry class as the fable bug and command-builder.mjs's bare-alias
# bug, fixed alongside it: a bare (no-colon) codex alias — astra/sol/terra/
# luna/spark — must classify as engine=codex on BOTH the CLI-flag path
# (parse_model_flag) and the env-var path (_auto_detect_engine), not fall
# through to claude (parse_model_flag's old unconditional "claude $value"
# bare branch) or be a total no-op (_auto_detect_engine's old behavior —
# its whole body lived inside the `*:*` guard, so a bare value never even
# reached the alias-expansion case statement).
test_bare_codex_alias_classification() {
  local vml_body pmf_body ade_body
  vml_body=$(_extract_fn_from "_validate_model_level" "$LIB")
  pmf_body=$(_extract_fn_from "parse_model_flag" "$LIB")
  ade_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$vml_body" || -z "$pmf_body" || -z "$ade_body" ]]; then
    fail "bare-codex-alias: _validate_model_level, parse_model_flag, or _auto_detect_engine not found"
    return
  fi

  # bash 3.2 (macOS default) has no associative arrays — use a case
  # statement instead, matching this file's existing bash-3.2-safe style.
  local -a aliases=(spark sol terra luna astra)

  local tmpdir
  tmpdir=$(mktemp -d)
  local failures=""
  local alias_name want_slug
  for alias_name in "${aliases[@]}"; do
    case "$alias_name" in
      spark) want_slug="gpt-5.3-codex-spark" ;;
      sol)   want_slug="gpt-5.6-sol" ;;
      terra) want_slug="gpt-5.6-terra" ;;
      luna)  want_slug="gpt-5.6-luna" ;;
      astra) want_slug="gpt-6-astra" ;;
    esac

    {
      echo '#!/usr/bin/env zsh -f'
      echo "$vml_body"
      echo "$pmf_body"
      echo "parse_model_flag '$alias_name' 'worker'"
    } > "$tmpdir/cli.zsh"
    local cli_out
    cli_out=$(zsh -f "$tmpdir/cli.zsh" 2>&1)
    local cli_rc=$?

    {
      echo '#!/usr/bin/env zsh -f'
      echo "$ade_body"
      echo "WORKER_MODEL='$alias_name'"
      echo 'WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""'
      echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
      echo 'echo "$WORKER_ENGINE $WORKER_MODEL"'
    } > "$tmpdir/env.zsh"
    local env_out
    env_out=$(zsh -f "$tmpdir/env.zsh" 2>&1)
    local env_rc=$?

    if [[ $cli_rc -ne 0 || "$cli_out" != "codex $want_slug "* ]]; then
      failures="$failures [CLI $alias_name: rc=$cli_rc out=[$cli_out] want=codex $want_slug]"
    fi
    if [[ $env_rc -ne 0 || "$env_out" != "codex $want_slug" ]]; then
      failures="$failures [ENV $alias_name: rc=$env_rc out=[$env_out] want=codex $want_slug]"
    fi
  done
  rm -rf "$tmpdir"

  if [[ -z "$failures" ]]; then
    pass "bare-codex-alias: bare astra/sol/terra/luna/spark classify as engine=codex on both parse_model_flag and _auto_detect_engine"
  else
    fail "bare-codex-alias:$failures"
  fi
}

# Team-lead review follow-up: fixing only the five known codex ALIASES above
# and leaving a bare, real codex model id (e.g. "gpt-5.5", no colon)
# misclassified as claude made the rule unguessable — five names fixed, the
# actual model ids still broken, disagreeing with isClaudeEngine('gpt-5.5')
# (Node side) which already correctly says "not claude". Any bare gpt-* id
# now routes to codex on both zsh paths too, with no alias-table lookup
# needed since it's already the real slug. Also pins the regression: an
# unrecognized bare name (neither a claude id, a known alias, nor gpt-*)
# still defaults to claude — the fix narrows the exception, it does not flip
# the documented "model (no colon) = claude engine" default for every name.
#
# Why the `gpt-*)` case arm is duplicated across parse_model_flag
# (lib_ralph_desk.zsh) and _auto_detect_engine (run_ralph_desk.zsh) instead
# of one shared zsh function (unlike the Node side, where isBareCodexModelName
# in command-builder.mjs IS a single shared predicate): _auto_detect_engine's
# real call sites (run_ralph_desk.zsh, WORKER_MODEL/VERIFIER_MODEL/
# FINAL_VERIFIER_MODEL) execute BEFORE `source "$LIB_DIR/lib_ralph_desk.zsh"`
# runs — calling a lib-defined helper from inside _auto_detect_engine's body
# would reproduce the exact "command not found" ordering bug this session
# already found and fixed once for _validate_consensus_model_var. This is
# the SAME constraint the existing sol/terra/luna/astra alias table already
# lives under (three independently-duplicated tables + a parity test, not
# one shared function — see "codex model alias table... agrees across..." in
# tests/node/us008-cli-entrypoint.test.mjs) — duplication-plus-parity-test is
# this codebase's established pattern for this exact class of constraint,
# not a shortcut. This test is the zsh-side parity check for the `gpt-*`
# case arm specifically.
test_bare_gpt_star_classification() {
  local pmf_body ade_body
  pmf_body=$(_extract_fn_from "parse_model_flag" "$LIB")
  ade_body=$(_extract_fn_from "_auto_detect_engine" "$RUN")
  if [[ -z "$pmf_body" || -z "$ade_body" ]]; then
    fail "bare-gpt-star: parse_model_flag or _auto_detect_engine not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local failures=""
  local value
  for value in "gpt-5.5" "gpt-6-astra" "gpt-5.3-codex-spark"; do
    {
      echo '#!/usr/bin/env zsh -f'
      echo "$pmf_body"
      echo "parse_model_flag '$value' 'worker'"
    } > "$tmpdir/cli.zsh"
    local cli_out
    cli_out=$(zsh -f "$tmpdir/cli.zsh" 2>&1)
    local cli_rc=$?

    {
      echo '#!/usr/bin/env zsh -f'
      echo "$ade_body"
      echo "WORKER_MODEL='$value'"
      echo 'WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""'
      echo '_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT'
      echo 'echo "$WORKER_ENGINE $WORKER_MODEL"'
    } > "$tmpdir/env.zsh"
    local env_out
    env_out=$(zsh -f "$tmpdir/env.zsh" 2>&1)
    local env_rc=$?

    if [[ $cli_rc -ne 0 || "$cli_out" != "codex $value "* ]]; then
      failures="$failures [CLI $value: rc=$cli_rc out=[$cli_out] want=codex $value]"
    fi
    if [[ $env_rc -ne 0 || "$env_out" != "codex $value" ]]; then
      failures="$failures [ENV $value: rc=$env_rc out=[$env_out] want=codex $value]"
    fi
  done

  # Regression: an unrecognized bare name still defaults to claude.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$pmf_body"
    echo "parse_model_flag 'some-unknown-model' 'worker'"
  } > "$tmpdir/cli_unknown.zsh"
  local unknown_out
  unknown_out=$(zsh -f "$tmpdir/cli_unknown.zsh" 2>&1)
  local unknown_rc=$?
  if [[ $unknown_rc -ne 0 || "$unknown_out" != "claude some-unknown-model" ]]; then
    failures="$failures [CLI unrecognized bare name: rc=$unknown_rc out=[$unknown_out] want=claude some-unknown-model]"
  fi

  rm -rf "$tmpdir"
  if [[ -z "$failures" ]]; then
    pass "bare-gpt-star: bare gpt-5.5/gpt-6-astra/gpt-5.3-codex-spark classify as engine=codex on both paths; unrecognized bare name still defaults to claude"
  else
    fail "bare-gpt-star:$failures"
  fi
}

# Independent-review finding (MED): --consensus-model / --final-consensus-model
# bypassed ALL validation, unlike --worker-model/--verifier-model/
# --final-verifier-model — so `--final-consensus-model astra:minimal` was
# accepted at parse time and only 400'd at the final consensus gate (astra is
# the final-consensus default, so this is not a hypothetical). Fixed via
# _validate_consensus_model_var (lib_ralph_desk.zsh), wired at both the
# env-var-default assignment AND the CLI-flag parsing site in
# run_ralph_desk.zsh. Also normalizes a bare alias (sol/terra/luna/astra/
# spark) to its full codex slug, since the runtime consensus-dispatch fallback
# passes the raw post-colon model straight to `codex -m` with no expansion.
test_validate_consensus_model_var() {
  local vml_body vcmv_body
  vml_body=$(_extract_fn_from "_validate_model_level" "$LIB")
  vcmv_body=$(_extract_fn_from "_validate_consensus_model_var" "$LIB")
  if [[ -z "$vml_body" || -z "$vcmv_body" ]]; then
    fail "consensus-model-validate: _validate_model_level or _validate_consensus_model_var not found"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local failures=""

  # Case 1: gpt-6-astra:minimal (full slug) rejected.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$vcmv_body"
    echo 'CONSENSUS_MODEL="gpt-6-astra:minimal"'
    echo '_validate_consensus_model_var CONSENSUS_MODEL "CONSENSUS_MODEL"'
  } > "$tmpdir/c1.zsh"
  zsh -f "$tmpdir/c1.zsh" >/dev/null 2>&1
  (( $? == 0 )) && failures="$failures [c1: gpt-6-astra:minimal should have been rejected]"

  # Case 2: astra:minimal (alias form) ALSO rejected — the exact scenario
  # the review flagged (astra is the final-consensus default).
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$vcmv_body"
    echo 'FINAL_CONSENSUS_MODEL="astra:minimal"'
    echo '_validate_consensus_model_var FINAL_CONSENSUS_MODEL "--final-consensus-model"'
  } > "$tmpdir/c2.zsh"
  zsh -f "$tmpdir/c2.zsh" >/dev/null 2>&1
  (( $? == 0 )) && failures="$failures [c2: astra:minimal should have been rejected]"

  # Case 3 (regression): a different codex model still accepts minimal.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$vcmv_body"
    echo 'CONSENSUS_MODEL="gpt-5.5:minimal"'
    echo '_validate_consensus_model_var CONSENSUS_MODEL "CONSENSUS_MODEL" || exit 1'
    echo '[[ "$CONSENSUS_MODEL" == "gpt-5.5:minimal" ]] || exit 1'
  } > "$tmpdir/c3.zsh"
  zsh -f "$tmpdir/c3.zsh" >/dev/null 2>&1
  (( $? != 0 )) && failures="$failures [c3: gpt-5.5:minimal should still be accepted]"

  # Case 4: alias normalization — astra:high -> gpt-6-astra:high in place.
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$vml_body"
    echo "$vcmv_body"
    echo 'FINAL_CONSENSUS_MODEL="astra:high"'
    echo '_validate_consensus_model_var FINAL_CONSENSUS_MODEL "--final-consensus-model" || exit 1'
    echo '[[ "$FINAL_CONSENSUS_MODEL" == "gpt-6-astra:high" ]] || { echo "got=$FINAL_CONSENSUS_MODEL" >&2; exit 1; }'
  } > "$tmpdir/c4.zsh"
  local c4out
  c4out=$(zsh -f "$tmpdir/c4.zsh" 2>&1)
  (( $? != 0 )) && failures="$failures [c4: astra:high should normalize to gpt-6-astra:high, got: $c4out]"

  rm -rf "$tmpdir"
  if [[ -z "$failures" ]]; then
    pass "consensus-model-validate: --consensus-model/--final-consensus-model reject gpt-6-astra:minimal and astra:minimal, accept gpt-5.5:minimal, normalize astra:high -> gpt-6-astra:high"
  else
    fail "consensus-model-validate:$failures"
  fi
}

# Independent-review finding: the CLI-flag parse sites for --consensus-model
# and --final-consensus-model must actually CALL _validate_consensus_model_var
# and exit non-zero on an invalid value, not just have the helper exist
# somewhere in the file. Runs the real binary end-to-end (same sandboxed
# LOOP_NAME/ROOT/TMUX invocation shape as test_us003_unified_model_format.sh's
# L3-E2E-3), so a missed wiring at the call site (the exact class of gap the
# review found — the validator existed for worker/verifier but was never
# invoked for consensus flags) is caught here too.
test_consensus_model_cli_flag_rejects_astra_minimal() {
  local tmp_l3
  tmp_l3=$(mktemp -d)
  mkdir -p "$tmp_l3/.rlp-desk/plans" "$tmp_l3/.rlp-desk/memos" \
    "$tmp_l3/.rlp-desk/prompts" "$tmp_l3/.rlp-desk/context" \
    "$tmp_l3/.rlp-desk/logs/e2eslug"
  touch "$tmp_l3/.rlp-desk/plans/prd-e2eslug.md"

  local rc=0
  LOOP_NAME=e2eslug ROOT="$tmp_l3" TMUX=test \
    zsh "$RUN" --final-consensus-model "astra:minimal" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp_l3"

  if (( rc == 1 )); then
    pass "consensus-cli-e2e: --final-consensus-model astra:minimal rejected at startup (exit 1)"
  else
    fail "consensus-cli-e2e: --final-consensus-model astra:minimal was NOT rejected (rc=$rc, want 1)"
  fi
}

# Claude ladder now reaches fable: opus -> claude-fable-5-1:max (terminal
# rung, effort-qualified) -> ceiling. Mirrors the Node-side ladder-shape test.
test_claude_ladder_reaches_fable() {
  local fn_body
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "claude-ladder-fable: get_next_model() not found"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    echo 'r_opus=$(get_next_model "opus")'
    echo 'r_fable=$(get_next_model "claude-fable-5-1")'
    echo 'if [[ "$r_opus" == "claude-fable-5-1:max" && -z "$r_fable" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "opus->$r_opus fable->$r_fable" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "claude-ladder-fable: opus escalates to claude-fable-5-1:max; claude-fable-5-1 is the real claude ceiling"
  else
    fail "claude-ladder-fable: $out"
  fi
}

# E2E: a claude worker auto-upgraded all the way to the new fable rung must
# carry WORKER_EFFORT=max (split from the ladder value, mirroring how the
# codex branch splits WORKER_CODEX_REASONING) — and a pass verdict must
# restore BOTH WORKER_MODEL and WORKER_EFFORT to their pre-upgrade values.
# This is the mutation control for _ORIGINAL_WORKER_EFFORT: without the save/
# restore wiring, WORKER_EFFORT would leak "max" into the restored (allegedly
# un-upgraded) state.
#
# Independent-review finding (MED, vacuous test): this test used to RETYPE
# the pass-verdict restore assignment (`WORKER_EFFORT="$_ORIGINAL_WORKER_EFFORT"`)
# instead of executing the shipped block in run_ralph_desk.zsh — so deleting
# the real line (e.g. `WORKER_EFFORT="$_ORIGINAL_WORKER_EFFORT"` at the site
# guarded by `if (( _MODEL_UPGRADED ))`) left this test green while the
# actual restore was broken. Fixed by extracting and executing the real
# block via `_extract_pass_restore_snippet` (content-anchored, same
# technique as `_extract_d5b_snippet`), the same fix class as the D-5b
# snippet extraction earlier in this file.
test_claude_worker_effort_upgrade_and_restore() {
  local cmu_body gnm_body gms_body pr_body
  cmu_body=$(extract_fn "check_model_upgrade")
  gnm_body=$(extract_fn "get_next_model")
  gms_body=$(extract_fn "get_model_string")
  pr_body=$(_extract_pass_restore_snippet)
  if [[ -z "$cmu_body" || -z "$gnm_body" ]]; then
    fail "claude-effort-restore: check_model_upgrade or get_next_model not found"
    return
  fi
  if [[ -z "$pr_body" ]] || ! echo "$pr_body" | grep -qF '_MODEL_UPGRADED'; then
    fail "claude-effort-restore: _extract_pass_restore_snippet returned nothing — has the pass-restore block moved out of main()?"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log_debug() { : ; }'
    echo 'log() { : ; }'
    echo 'WORKER_ENGINE="claude"'
    echo 'WORKER_MODEL="opus"'
    echo 'WORKER_EFFORT=""'
    echo '_ORIGINAL_WORKER_MODEL=""'
    echo '_ORIGINAL_WORKER_CODEX_REASONING=""'
    echo '_ORIGINAL_WORKER_EFFORT=""'
    echo '_LAST_FAILED_US=""'
    echo '_SAME_US_FAIL_COUNT=0'
    echo '_MODEL_UPGRADED=0'
    echo "LIB_DIR=\"$REPO_ROOT/src/scripts\""
    echo 'RLP_DESK_MODELS_FILE="/nonexistent-hermetic-test-guard/rlp-desk-models.json"'
    echo "$gms_body"
    echo "$gnm_body"
    echo "$cmu_body"
    echo ''
    echo '# 2 consecutive fails on same US: opus -> claude-fable-5-1:max'
    echo 'check_model_upgrade "US-001"'
    echo 'check_model_upgrade "US-001"'
    echo 'if [[ "$WORKER_MODEL" != "claude-fable-5-1" || "$WORKER_EFFORT" != "max" ]]; then'
    echo '  echo "FAIL upgrade: model=$WORKER_MODEL effort=$WORKER_EFFORT (want claude-fable-5-1 / max)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo ''
    echo '# Execute the REAL shipped pass-verdict restore block (run_ralph_desk.zsh),'
    echo '# not a retyped stand-in — a mutation to the real block must turn this test red.'
    echo "$pr_body"
    echo 'if [[ "$WORKER_MODEL" == "opus" && -z "$WORKER_EFFORT" && "$_MODEL_UPGRADED" == "0" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "FAIL restore: model=$WORKER_MODEL effort=$WORKER_EFFORT model_upgraded=$_MODEL_UPGRADED (want opus / empty / 0)" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "claude-effort-restore: opus->claude-fable-5-1:max upgrade sets WORKER_EFFORT=max; restore returns opus with empty effort"
  else
    fail "claude-effort-restore: $out"
  fi
}

# Owner correction (Fable 5.1 / Codex 6 Astra wave): the shipped Worker
# default was briefly raised to the ladder ceiling on the codex side
# (gpt-6-astra) — broke luna-first three ways at once (frontier price every
# iteration, no escalation headroom so check_model_upgrade returns
# already_max from iteration 1, circuit breaker loses its escalation
# signal). Pins the INVARIANT: the shipped Worker default must have at least
# one upgrade hop left before reaching the ladder ceiling, on both engines.
# Both the starting default AND the ceiling check are extracted from the
# real source / walked via the real get_next_model() at test time — nothing
# here is a hardcoded literal — so this test keeps discriminating correctly
# through a future generation bump without needing an update itself.
test_worker_default_never_equals_ceiling() {
  local fn_body
  fn_body=$(extract_fn "get_next_model")
  if [[ -z "$fn_body" ]]; then
    fail "worker-default-not-ceiling: get_next_model() not found"
    return
  fi
  local claude_default codex_model_default codex_reasoning_default
  claude_default=$(grep -oE 'WORKER_MODEL="\$\{WORKER_MODEL:-[a-zA-Z0-9._-]+\}"' "$RUN" | head -1 | sed -E 's/.*:-([a-zA-Z0-9._-]+)\}"/\1/')
  codex_model_default=$(grep -oE 'WORKER_CODEX_MODEL="\$\{WORKER_CODEX_MODEL:-[a-zA-Z0-9._-]+\}"' "$RUN" | head -1 | sed -E 's/.*:-([a-zA-Z0-9._-]+)\}"/\1/')
  codex_reasoning_default=$(grep -oE 'WORKER_CODEX_REASONING="\$\{WORKER_CODEX_REASONING:-[a-zA-Z0-9._-]+\}"' "$RUN" | head -1 | sed -E 's/.*:-([a-zA-Z0-9._-]+)\}"/\1/')
  if [[ -z "$claude_default" || -z "$codex_model_default" || -z "$codex_reasoning_default" ]]; then
    fail "worker-default-not-ceiling: could not extract defaults from $RUN (claude='$claude_default' codex_model='$codex_model_default' codex_reasoning='$codex_reasoning_default')"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  {
    echo '#!/usr/bin/env zsh -f'
    echo "$fn_body"
    # Walk the FULL chain from each default to its ceiling (cycle-guarded) and
    # count hops — "not the ceiling" (>=1 hop) is not enough per spec; require
    # at least two rungs of headroom above the shipped default.
    echo 'hops_to_ceiling() {'
    echo '  local cur="$1" hops=0 seen="" next'
    echo '  while true; do'
    echo '    [[ " $seen " == *" $cur "* ]] && { echo "CYCLE at $cur" >&2; return 1; }'
    echo '    seen="$seen $cur"'
    echo '    next=$(get_next_model "$cur")'
    echo '    [[ -z "$next" ]] && { echo "$hops"; return 0; }'
    echo '    cur="$next"; (( hops++ ))'
    echo '  done'
    echo '}'
    echo "h_claude=\$(hops_to_ceiling '$claude_default') || exit 1"
    echo "h_codex=\$(hops_to_ceiling '${codex_model_default}:${codex_reasoning_default}') || exit 1"
    echo 'if (( h_claude >= 2 && h_codex >= 2 )); then'
    echo '  exit 0'
    echo 'else'
    echo "  echo \"claude default '$claude_default' has \$h_claude hop(s) of headroom / codex default '${codex_model_default}:${codex_reasoning_default}' has \$h_codex hop(s) — both must be >= 2\" >&2"
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "worker-default-not-ceiling: claude default '$claude_default' and codex default '${codex_model_default}:${codex_reasoning_default}' each retain >=2 hops of upgrade headroom before the ladder ceiling"
  else
    fail "worker-default-not-ceiling: $out"
  fi
}

# D-5b WORKER_EFFORT crash-restart persistence (mirrors worker_codex_reasoning
# exactly, request-j ③ same class of gap, now live on the claude side since
# the ladder reaches claude-fable-5-1:max). Simulates: opus->fable upgrade
# (sets WORKER_EFFORT=max) -> update_status() persists it to status.json ->
# a fresh "leader process" (all vars reset to init defaults) -> the real D-5b
# restore snippet (extracted by content, not retyped — see _extract_d5b_snippet)
# reads status.json back. Asserts BOTH model and effort come back, not just model.
test_d5b_worker_effort_crash_restart() {
  local cmu_body gnm_body gms_body us_body aw_body d5b_body
  cmu_body=$(extract_fn "check_model_upgrade")
  gnm_body=$(extract_fn "get_next_model")
  gms_body=$(extract_fn "get_model_string")
  us_body=$(_extract_fn_from "update_status" "$LIB")
  aw_body=$(_extract_fn_from "atomic_write" "$LIB")
  if [[ -z "$cmu_body" || -z "$gnm_body" || -z "$us_body" || -z "$aw_body" ]]; then
    fail "d5b-effort-restart: check_model_upgrade/get_next_model/update_status/atomic_write not found"
    return
  fi
  # The D-5b restore snippet is inline inside main() (not its own function),
  # so it is extracted by CONTENT (_extract_d5b_snippet, anchored on the
  # `local _status_mu` declaration through the outer if's closing `fi`) rather
  # than retyped — a moved/renamed block fails loudly (empty body, checked
  # below) instead of silently drifting from the real source. A hardcoded
  # line range was tried first and broke silently the first time an earlier
  # edit shifted lines above it; content-anchoring survives that.
  d5b_body=$(_extract_d5b_snippet)
  if [[ -z "$d5b_body" ]] || ! echo "$d5b_body" | grep -qF '_status_mu'; then
    fail "d5b-effort-restart: D-5b snippet extraction (_extract_d5b_snippet) returned nothing — has the block moved out of main()?"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local status_file="$tmpdir/status.json"
  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log() { : ; }'
    echo 'log_debug() { : ; }'
    echo '_lifecycle_clear_lock_mark() { : ; }'
    echo "LIB_DIR=\"$REPO_ROOT/src/scripts\""
    echo 'RLP_DESK_MODELS_FILE="/nonexistent-hermetic-test-guard/rlp-desk-models.json"'
    echo "STATUS_FILE=\"$status_file\""
    echo "$aw_body"
    echo "$gms_body"
    echo "$gnm_body"
    echo "$cmu_body"
    echo "$us_body"
    echo ''
    echo '# --- Segment 1: original leader process, upgrades opus -> fable ---'
    echo 'WORKER_ENGINE="claude"; WORKER_MODEL="opus"; WORKER_EFFORT=""'
    echo 'VERIFIER_MODEL="sonnet"; VERIFIER_ENGINE="claude"'
    echo 'WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""'
    echo 'VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""'
    echo '_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""'
    echo '_LAST_FAILED_US=""; _SAME_US_FAIL_COUNT=0; _MODEL_UPGRADED=0'
    echo 'SLUG="d5b-test"; BASELINE_COMMIT="none"; ITERATION=3; MAX_ITER=20'
    echo 'VERIFY_MODE="per-us"; CONSENSUS_MODE="off"'
    echo 'CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
    echo 'VERIFIED_US=""; ITER_START_HEAD=""; GATE_RECEIPT_STATUS="none"'
    echo 'check_model_upgrade "US-001"; check_model_upgrade "US-001"'
    echo 'if [[ "$WORKER_MODEL" != "claude-fable-5-1" || "$WORKER_EFFORT" != "max" ]]; then'
    echo '  echo "FAIL setup: upgrade did not reach fable:max (model=$WORKER_MODEL effort=$WORKER_EFFORT)" >&2'
    echo '  exit 1'
    echo 'fi'
    echo 'update_status "verify" "pending"'
    echo ''
    echo '# --- Segment 2: leader "crash-restarts" — every relevant var reset to'
    echo '# the same empty/zero init defaults run_ralph_desk.zsh assigns at startup ---'
    echo 'WORKER_MODEL=""; WORKER_ENGINE=""; WORKER_EFFORT=""'
    echo 'WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""'
    echo '_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""'
    echo '_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0'
    echo 'CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
    echo "$d5b_body"
    echo ''
    echo '# --- Assert: BOTH model and effort came back, not just model ---'
    echo 'if [[ "$WORKER_MODEL" == "claude-fable-5-1" && "$WORKER_EFFORT" == "max" && "$_ORIGINAL_WORKER_MODEL" == "opus" && -z "$_ORIGINAL_WORKER_EFFORT" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "FAIL restore: WORKER_MODEL=$WORKER_MODEL WORKER_EFFORT=$WORKER_EFFORT _ORIGINAL_WORKER_MODEL=$_ORIGINAL_WORKER_MODEL _ORIGINAL_WORKER_EFFORT=$_ORIGINAL_WORKER_EFFORT" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "d5b-effort-restart: crash-restart restores WORKER_MODEL=claude-fable-5-1 AND WORKER_EFFORT=max (not just the model)"
  else
    fail "d5b-effort-restart: $out"
  fi
}

test_gpt6_astra_ladder
test_gpt6_sol_escalates_into_astra
test_auto_detect_engine_new_models
test_auto_detect_engine_fable_alias
test_auto_detect_engine_astra_minimal_rejected
test_parse_model_flag_astra_minimal_rejected
test_cli_env_validation_parity
test_bare_codex_alias_classification
test_bare_gpt_star_classification
test_validate_consensus_model_var
test_consensus_model_cli_flag_rejects_astra_minimal
test_claude_ladder_reaches_fable
test_claude_worker_effort_upgrade_and_restore
test_worker_default_never_equals_ceiling
test_d5b_worker_effort_crash_restart

# Negative-case mutation control on the D-5b restore READ specifically (not
# the write path — a hand-crafted status.json bypasses update_status
# entirely). Simulates the backward-compatibility case: an OLDER status.json
# written before original_worker_effort existed, where the field is MISSING
# from the JSON entirely (not present-but-empty). Asserts the restore leaves
# _ORIGINAL_WORKER_EFFORT unset/empty — never the literal string "null" or
# any other malformed value — mirroring exactly how original_worker_codex_reasoning's
# own backward-compat case (documented in the request-j ③ comment) is handled.
test_d5b_worker_effort_missing_field_backward_compat() {
  local d5b_body
  d5b_body=$(_extract_d5b_snippet)
  if [[ -z "$d5b_body" ]] || ! echo "$d5b_body" | grep -qF '_status_mu'; then
    fail "d5b-effort-missing-field: D-5b snippet extraction (_extract_d5b_snippet) returned nothing — has the block moved out of main()?"
    return
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  local status_file="$tmpdir/status.json"
  # Hand-crafted status.json: model_upgraded=1 with worker_model/worker_engine
  # present (so the restore predicate fires) and worker_effort=max present,
  # but original_worker_effort entirely ABSENT (pre-this-field status.json).
  cat > "$status_file" << 'JSON'
{
  "model_upgraded": 1,
  "worker_model": "claude-fable-5-1",
  "worker_engine": "claude",
  "worker_codex_model": "",
  "worker_codex_reasoning": "",
  "worker_effort": "max",
  "original_worker_model": "opus",
  "original_worker_codex_reasoning": "",
  "same_us_fail_count": 0
}
JSON
  {
    echo '#!/usr/bin/env zsh -f'
    echo 'log() { : ; }'
    echo 'log_debug() { : ; }'
    echo "STATUS_FILE=\"$status_file\""
    echo 'WORKER_MODEL=""; WORKER_ENGINE=""; WORKER_EFFORT=""'
    echo 'WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""'
    echo '_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""'
    echo '_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0'
    echo 'CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
    echo "$d5b_body"
    echo 'if [[ "$WORKER_MODEL" == "claude-fable-5-1" && "$WORKER_EFFORT" == "max" && -z "$_ORIGINAL_WORKER_EFFORT" && "$_ORIGINAL_WORKER_EFFORT" != "null" ]]; then'
    echo '  exit 0'
    echo 'else'
    echo '  echo "FAIL: WORKER_MODEL=$WORKER_MODEL WORKER_EFFORT=$WORKER_EFFORT _ORIGINAL_WORKER_EFFORT=[$_ORIGINAL_WORKER_EFFORT] (want fable/max/empty-not-null)" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "d5b-effort-missing-field: missing original_worker_effort field (pre-field status.json) restores as unset, not the string 'null'"
  else
    fail "d5b-effort-missing-field: $out"
  fi
}
test_d5b_worker_effort_missing_field_backward_compat

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
