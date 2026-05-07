#!/bin/zsh
# PR-E.zsh (Phase C1) — operator-cleared BLOCKED recovery hygiene helper test.
#
# Validates _validate_blocked_recovery in lib_ralph_desk.zsh against 5 scenarios
# mirroring the Node-side AC-BR1..BR5 contract:
#   BR-Z1. All 4 checks pass (sidecar absent, counters non-zero)         → return 0
#   BR-Z2. Sentinel still present                                         → return 1, "still present"
#   BR-Z3. Counters already zero                                          → return 1, "already zero"
#   BR-Z4. Sidecar parse error                                            → return 1, "parse error"
#   BR-Z5. Sidecar recoverable=false                                      → return 1, "non-recoverable"
#
# Pattern mirrored from tests/test-bug10-zsh-relaunch-hygiene.sh.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB_SCRIPT="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"

if [[ ! -f "$LIB_SCRIPT" ]]; then
  print -u2 "FAIL: lib_ralph_desk.zsh not found at $LIB_SCRIPT"
  exit 1
fi

# --- Extract just the helpers we need ---
TMP_LIB=$(mktemp -t pr-e-zsh-helpers.XXXXXX)
WORK_DIR=""
trap 'rm -f "$TMP_LIB" 2>/dev/null; [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null; true' EXIT
sed -n '/^_validate_blocked_recovery()/,/^}/p' "$LIB_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_archive_recovered_sidecar()/,/^}/p' "$LIB_SCRIPT" >> "$TMP_LIB"

if ! grep -q '_validate_blocked_recovery' "$TMP_LIB"; then
  print -u2 "FAIL: _validate_blocked_recovery not found in $LIB_SCRIPT"
  exit 1
fi

source "$TMP_LIB"

if ! typeset -f _validate_blocked_recovery >/dev/null 2>&1; then
  print -u2 "FAIL: _validate_blocked_recovery could not be sourced"
  exit 1
fi

WORK_DIR=$(mktemp -d -t pr-e-fixtures.XXXXXX)

# Helper to seed a complete valid set with overrides
seed_state() {
  local sentinel_present="${1:-no}"
  local sidecar="${2:-none}"  # none | recoverable | non-recoverable | malformed
  local fails="${3:-3}"
  local blocks="${4:-1}"

  rm -f "$WORK_DIR"/*.{md,json} 2>/dev/null

  if [[ "$sentinel_present" == "yes" ]]; then
    print "BLOCKED: pre-existing" > "$WORK_DIR/test-blocked.md"
  fi

  case "$sidecar" in
    recoverable)
      print -- '{"recoverable":true,"reason_category":"metric_failure","schema_version":"2.0"}' \
        > "$WORK_DIR/test-blocked.json"
      ;;
    non-recoverable)
      print -- '{"recoverable":false,"reason_category":"mission_abort","schema_version":"2.0"}' \
        > "$WORK_DIR/test-blocked.json"
      ;;
    malformed)
      print -- '{not valid json}' > "$WORK_DIR/test-blocked.json"
      ;;
    none)
      : # no sidecar
      ;;
  esac

  print -- "{\"phase\":\"blocked\",\"consecutive_failures\":$fails,\"consecutive_blocks\":$blocks,\"last_block_reason\":\"\"}" \
    > "$WORK_DIR/status.json"
}

PASS=0
FAIL=0

_check() {
  local label="$1" expected_rc="$2" actual_rc="$3" reason_substring="${4:-}"
  if [[ "$actual_rc" == "$expected_rc" ]]; then
    if [[ -n "$reason_substring" && "${BLOCKED_RECOVERY_FAIL_REASON:-}" != *"$reason_substring"* ]]; then
      print "FAIL: $label — rc OK ($actual_rc) but BLOCKED_RECOVERY_FAIL_REASON missing '$reason_substring' (got: '${BLOCKED_RECOVERY_FAIL_REASON:-}')"
      FAIL=$((FAIL+1))
      return
    fi
    print "PASS: $label (rc=$actual_rc${reason_substring:+, reason matches '$reason_substring'})"
    PASS=$((PASS+1))
  else
    print "FAIL: $label — expected rc=$expected_rc, got rc=$actual_rc (reason: '${BLOCKED_RECOVERY_FAIL_REASON:-none}')"
    FAIL=$((FAIL+1))
  fi
}

# ────────────────────────────────────────────────────────────────────────
# BR-Z1: all 4 checks pass (sentinel absent, counters non-zero, sidecar absent)
# ────────────────────────────────────────────────────────────────────────
seed_state "no" "none" 3 1
_validate_blocked_recovery "$WORK_DIR/test-blocked.md" "$WORK_DIR/test-blocked.json" "$WORK_DIR/status.json"
_check "BR-Z1 all-pass (no sidecar)" 0 $? ""

# ────────────────────────────────────────────────────────────────────────
# BR-Z2: sentinel still present
# ────────────────────────────────────────────────────────────────────────
seed_state "yes" "recoverable" 3 1
_validate_blocked_recovery "$WORK_DIR/test-blocked.md" "$WORK_DIR/test-blocked.json" "$WORK_DIR/status.json"
_check "BR-Z2 sentinel-present" 1 $? "still present"

# ────────────────────────────────────────────────────────────────────────
# BR-Z3: counters already zero
# ────────────────────────────────────────────────────────────────────────
seed_state "no" "recoverable" 0 0
_validate_blocked_recovery "$WORK_DIR/test-blocked.md" "$WORK_DIR/test-blocked.json" "$WORK_DIR/status.json"
_check "BR-Z3 counters-zero" 1 $? "already zero"

# ────────────────────────────────────────────────────────────────────────
# BR-Z4: sidecar malformed
# ────────────────────────────────────────────────────────────────────────
seed_state "no" "malformed" 3 1
_validate_blocked_recovery "$WORK_DIR/test-blocked.md" "$WORK_DIR/test-blocked.json" "$WORK_DIR/status.json"
_check "BR-Z4 sidecar-malformed" 1 $? "parse error"

# ────────────────────────────────────────────────────────────────────────
# BR-Z5: sidecar recoverable=false
# ────────────────────────────────────────────────────────────────────────
seed_state "no" "non-recoverable" 3 1
_validate_blocked_recovery "$WORK_DIR/test-blocked.md" "$WORK_DIR/test-blocked.json" "$WORK_DIR/status.json"
_check "BR-Z5 non-recoverable" 1 $? "non-recoverable"

# ────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────
print ""
print "PR-E.zsh blocked recovery: $PASS passed, $FAIL failed"

(( FAIL == 0 ))
