#!/usr/bin/env bash
# Test Suite: US-020 — R8 P1-H Blocked exit hygiene (memory.md/latest.md update mandatory)
# Validates:
#   - Worker prompt mandates Blocked exit hygiene (memory.md + latest.md update)
#   - governance §1f mentions 5th channel (memory.md/latest.md hygiene)
#   - lib_ralph_desk.zsh write_blocked_sentinel auto-attaches blocked_hygiene_violated to JSON sidecar
#   - Node helper _checkBlockedHygiene defined
#   - Behavioural: stale memory.md (mtime > threshold) → JSON sidecar meta.blocked_hygiene_violated=true

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
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

echo "=== US-020: R8 P1-H Blocked exit hygiene ==="
echo

# AC1: worker prompt mandates Blocked exit hygiene
assert_one "$INIT" 'Blocked exit hygiene' \
  "AC1-a: worker prompt has 'Blocked exit hygiene' section"
assert_one "$INIT" 'memory\.md.*Blocking History' \
  "AC1-b: worker prompt mentions memory.md Blocking History"
assert_one "$INIT" 'latest\.md.*Known Issues' \
  "AC1-c: worker prompt mentions latest.md Known Issues"

# AC2: governance §1f references 5th channel
assert_one "$GOV" '5th channel' \
  "AC2-a: governance §1f mentions 5th channel"
assert_one "$GOV" 'memory\.md/latest\.md hygiene' \
  "AC2-b: governance §1f names memory.md/latest.md hygiene"

# AC3: lib_ralph_desk.zsh write_blocked_sentinel includes hygiene check
assert_one "$LIB" 'blocked_hygiene_violated' \
  "AC3-a: lib_ralph_desk.zsh references blocked_hygiene_violated"

# AC4: Node helper _checkBlockedHygiene defined
assert_one "$LOOP" '_checkBlockedHygiene' \
  "AC4: Node helper _checkBlockedHygiene defined"

# AC5: Behavioural — write_blocked_sentinel auto-attaches blocked_hygiene_violated=true when stale
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us020-XXXX")
DESK="$TMP_DIR"
SLUG="us020-test"
mkdir -p "$DESK/memos" "$DESK/context"
# Stale memory.md (mtime 10 min ago)
echo "stale" > "$DESK/memos/$SLUG-memory.md"
echo "stale" > "$DESK/context/$SLUG-latest.md"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M.%S 2>/dev/null)" \
  "$DESK/memos/$SLUG-memory.md" "$DESK/context/$SLUG-latest.md" 2>/dev/null

result=$(zsh -c "
  DESK='$DESK'
  SLUG='$SLUG'
  CURRENT_US='US-001'
  BLOCKED_SENTINEL='$DESK/$SLUG-blocked.md'
  source '$LIB' 2>/dev/null
  write_blocked_sentinel 'fixture stale memory test' 'US-001' 'metric_failure' 2>&1
  echo EXIT=\$?
" 2>&1)

JSON_SIDECAR="$DESK/$SLUG-blocked.json"
if [[ -f "$JSON_SIDECAR" ]] && command -v jq >/dev/null 2>&1; then
  hygiene=$(jq -r '.meta.blocked_hygiene_violated // "missing"' "$JSON_SIDECAR" 2>/dev/null)
  if [[ "$hygiene" == "true" ]]; then
    pass "AC5: stale memory.md → meta.blocked_hygiene_violated=true"
  else
    fail "AC5: meta.blocked_hygiene_violated=$hygiene (expected true). Sidecar: $(cat "$JSON_SIDECAR")"
  fi
else
  fail "AC5: JSON sidecar missing or jq unavailable. zsh result: $result"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
