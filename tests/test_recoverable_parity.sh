#!/usr/bin/env zsh
# vision-adopt §2: recoverable-flag reconciliation (zsh ↔ Node) — zsh side.
#
# Drives the zsh leader's category taxonomy against the SAME shared fixture the
# Node parity test uses (tests/fixtures/recoverable-parity/matrix.json). Pins:
#   - _blocked_recoverable_for_category agrees with the fixture per category
#     (fail-fast: infra_failure=false; external_fact=false).
#   - The genuinely-transient infra callsites keep recoverable=true + restart via
#     the per-callsite override (the documented exception to the category
#     default).
#   - write_blocked_sentinel end-to-end: default infra_failure → recoverable=false
#     + investigate; with override → recoverable=true + restart.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
MATRIX="$REPO/tests/fixtures/recoverable-parity/matrix.json"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); print "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); print "  FAIL: $1"; }

print "=== vision-adopt §2: recoverable parity (zsh side) ==="
print

command -v jq >/dev/null 2>&1 || { print "SKIP: jq unavailable"; exit 0; }
[[ -f "$MATRIX" ]] || { fail "fixture missing: $MATRIX"; print "=== RESULTS: $PASS passed, $FAIL failed ==="; exit 1; }

# Load helpers.
source "$LIB" 2>/dev/null
log() { :; }; log_error() { :; }; log_warn() { :; }; log_debug() { :; }
atomic_write() { cat > "$1"; }

# ---------------------------------------------------------------------------
# AC1: _blocked_recoverable_for_category agrees with the fixture per category.
# ---------------------------------------------------------------------------
cats=(${(f)"$(jq -r '.category_recoverable | keys[]' "$MATRIX")"})
for cat in $cats; do
  expected=$(jq -r --arg c "$cat" '.category_recoverable[$c]' "$MATRIX")
  got=$(_blocked_recoverable_for_category "$cat")
  if [[ "$got" == "$expected" ]]; then
    pass "AC1/$cat: recoverable=$got matches fixture"
  else
    fail "AC1/$cat: got recoverable=$got, fixture=$expected"
  fi
done

# ---------------------------------------------------------------------------
# AC2: fail-fast — infra_failure is recoverable=false + action=investigate.
# ---------------------------------------------------------------------------
[[ "$(_blocked_recoverable_for_category infra_failure)" == "false" ]] \
  && pass "AC2-a: infra_failure recoverable=false (fail-fast)" \
  || fail "AC2-a: infra_failure not false"
[[ "$(_blocked_action_for_category infra_failure)" == "investigate" ]] \
  && pass "AC2-b: infra_failure action=investigate" \
  || fail "AC2-b: infra_failure action=$(_blocked_action_for_category infra_failure)"

# ---------------------------------------------------------------------------
# AC3: external_fact (§3) is a known category — recoverable=false,
# action=retry_after_fix.
# ---------------------------------------------------------------------------
[[ "$(_blocked_recoverable_for_category external_fact)" == "false" ]] \
  && pass "AC3-a: external_fact recoverable=false" \
  || fail "AC3-a: external_fact recoverable=$(_blocked_recoverable_for_category external_fact)"
[[ "$(_blocked_action_for_category external_fact)" == "retry_after_fix" ]] \
  && pass "AC3-b: external_fact action=retry_after_fix" \
  || fail "AC3-b: external_fact action=$(_blocked_action_for_category external_fact)"

# ---------------------------------------------------------------------------
# AC4: the genuinely-transient infra callsites keep recoverable=true + restart
# via the per-callsite override. There are exactly 3 (lifecycle, API, capacity).
# ---------------------------------------------------------------------------
overrides=$(grep -cE 'write_blocked_sentinel .*"infra_failure" "infra" "true" "restart"' "$RUN")
if [[ "$overrides" -eq 3 ]]; then
  pass "AC4-a: 3 transient infra callsites override to recoverable=true + restart"
else
  fail "AC4-a: expected 3 transient overrides, got $overrides"
fi

# ---------------------------------------------------------------------------
# AC5: write_blocked_sentinel end-to-end.
#   default infra_failure → recoverable=false, action=investigate
#   overridden          → recoverable=true, action=restart
# ---------------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rlp-parity-XXXX"); trap "rm -rf '$TMP'" EXIT

_emit() {
  local sent="$TMP/$1.md" cat="$2" rec="${3:-}" act="${4:-}"
  ITERATION=1 BLOCKED_SENTINEL="$sent" SLUG="parity" CURRENT_US="US-001" \
    zsh -c "
source '$LIB' 2>/dev/null
log() { :; }; log_error() { :; }; log_warn() { :; }; log_debug() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'x' '' '$cat' 'infra' '$rec' '$act'
"
  cat "$TMP/$1.json"
}

def_json=$(_emit default infra_failure)
def_rec=$(printf '%s' "$def_json" | jq -r '.recoverable')
def_act=$(printf '%s' "$def_json" | jq -r '.suggested_action')
if [[ "$def_rec" == "false" && "$def_act" == "investigate" ]]; then
  pass "AC5-a: default infra_failure → recoverable=false + investigate"
else
  fail "AC5-a: got recoverable=$def_rec action=$def_act"
fi

ovr_json=$(_emit ovr infra_failure true restart)
ovr_rec=$(printf '%s' "$ovr_json" | jq -r '.recoverable')
ovr_act=$(printf '%s' "$ovr_json" | jq -r '.suggested_action')
if [[ "$ovr_rec" == "true" && "$ovr_act" == "restart" ]]; then
  pass "AC5-b: overridden infra_failure → recoverable=true + restart"
else
  fail "AC5-b: got recoverable=$ovr_rec action=$ovr_act"
fi

# external_fact sentinel end-to-end.
ef_json=$(_emit extfact external_fact)
ef_rec=$(printf '%s' "$ef_json" | jq -r '.recoverable')
ef_act=$(printf '%s' "$ef_json" | jq -r '.suggested_action')
if [[ "$ef_rec" == "false" && "$ef_act" == "retry_after_fix" ]]; then
  pass "AC5-c: external_fact → recoverable=false + retry_after_fix"
else
  fail "AC5-c: got recoverable=$ef_rec action=$ef_act"
fi

print
print "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
