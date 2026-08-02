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
    # the 3-entry emergency fallback ladder (which only has claude entries) —
    # it forces the shipped src/node/models.json resolution path to be real.
    echo 'result_codex=$(get_next_model "gpt-5.5:low")'
    echo 'if [[ "$result_haiku" == "sonnet" && "$result_sonnet" == "opus" && -z "$result_opus" && "$result_codex" == "gpt-5.5:medium" ]]; then'
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
    pass "E2E-upgrade: get_next_model returns haiku→sonnet, sonnet→opus, opus→empty, gpt-5.5:low→medium"
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

# emergency-fallback: both override and shipped unreadable -> 3-entry inline ladder
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
    echo 'if [[ "$a" == "sonnet" && "$b" == "opus" && -z "$c" ]]; then exit 0; else echo "a=$a b=$b c=$c" >&2; exit 1; fi'
  } > "$tmpdir/harness.zsh"
  local out rc
  out=$(zsh -f "$tmpdir/harness.zsh" 2>&1)
  rc=$?
  rm -rf "$tmpdir"
  if (( rc == 0 )); then
    pass "US001-emergency: both layers unreadable -> emergency inline ladder (haiku->sonnet->opus->ceiling)"
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
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
