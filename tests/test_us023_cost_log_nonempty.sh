#!/usr/bin/env bash
# Test Suite: US-023 — R11 P2-K Cost log non-empty in tmux mode
# Validates:
#   - write_cost_log adds note field (no_actual_usage_recorded when bytes=0)
#   - run_ralph_desk.zsh registers EXIT trap _emit_final_cost_log
#   - Early-exit path inventory (broadened grep: exit\b|return\b|die\b)
#   - Behavioural: write_cost_log with empty inputs produces an entry with note

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
GOV="$ROOT_REPO/src/governance.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  local file="$1" pat="$2" n
  n=$(grep -cE -- "$pat" "$file" 2>/dev/null) || n=0
  printf '%s' "$n"
}
assert_one() {
  local n; n=$(_match_count "$1" "$2")
  [[ "$n" -ge 1 ]] && pass "$3" || fail "$3 (matches=0)"
}

echo "=== US-023: R11 P2-K Cost log non-empty ==="
echo

# AC1: write_cost_log includes note field
assert_one "$LIB" 'no_actual_usage_recorded' \
  "AC1-a: lib_ralph_desk.zsh references no_actual_usage_recorded note"
assert_one "$LIB" '"note":' \
  "AC1-b: write_cost_log JSON includes \"note\" field"

# AC2: zsh runner registers EXIT trap
assert_one "$RUN" 'trap.*_emit_final_cost_log.*EXIT' \
  "AC2-a: zsh runner registers trap '_emit_final_cost_log' EXIT"
assert_one "$RUN" '_emit_final_cost_log\(\)' \
  "AC2-b: _emit_final_cost_log function defined"
assert_one "$RUN" 'COST_LOG_FINAL_WRITTEN' \
  "AC2-c: COST_LOG_FINAL_WRITTEN idempotency guard"

# AC3: governance §7 / §8 documents tmux estimated path
assert_one "$GOV" '(estimated.*tmux|tmux.*estimated|cost-log.*tmux)' \
  "AC3: governance mentions tmux estimated cost path"

# AC4: early-exit grep inventory (broadened)
exits=$(grep -nE '^[[:space:]]*(exit\b|return\b|die\b)' "$RUN" 2>/dev/null | wc -l | tr -d ' ')
[[ "$exits" -ge 1 ]] && pass "AC4: broadened early-exit grep finds $exits sites in run_ralph_desk.zsh" \
                    || fail "AC4: broadened early-exit grep returned 0 sites"

# AC5: behavioural — write_cost_log with empty inputs writes a note
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us023-XXXX")
LOGS="$TMP_DIR/logs"
mkdir -p "$LOGS"
zsh -c "
  LOGS_DIR='$LOGS'
  COST_LOG='$LOGS/cost-log.jsonl'
  ITERATION=1
  source '$LIB' 2>/dev/null
  write_cost_log 1 2>/dev/null
" 2>/dev/null
COST_FILE="$LOGS/cost-log.jsonl"
if [[ -f "$COST_FILE" ]] && command -v jq >/dev/null 2>&1; then
  note=$(tail -1 "$COST_FILE" | jq -r '.note // "missing"' 2>/dev/null)
  if [[ "$note" == "no_actual_usage_recorded" ]]; then
    pass "AC5-a: empty-inputs write_cost_log emits note=no_actual_usage_recorded"
  else
    fail "AC5-a: note=$note (expected no_actual_usage_recorded). Last entry: $(tail -1 "$COST_FILE")"
  fi
  lines=$(wc -l < "$COST_FILE" | tr -d ' ')
  [[ "$lines" -ge 1 ]] && pass "AC5-b: cost-log.jsonl has $lines line(s)" \
                       || fail "AC5-b: cost-log.jsonl empty"
else
  fail "AC5: cost-log.jsonl missing or jq unavailable"
fi
rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
