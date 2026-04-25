#!/usr/bin/env bash
# Test Suite: US-014 — R2 P0-A multi-mission autonomy via next_mission_candidate emit.
# Validates that:
# - flywheel prompt template instructs the agent to optionally emit
#   next_mission_candidate (string | null) in flywheel-signal.json
# - Node leader captures the field into state and serializes to status.json
# - governance §7 ⑥½ + docs/multi-mission-orchestration.md document the field
# Field is OPTIONAL — absent JSON treats it as null (backward-compat).

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
GOV="$ROOT_REPO/src/governance.md"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
DOCS="$ROOT_REPO/docs/multi-mission-orchestration.md"

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

echo "=== US-014: R2 P0-A next_mission_candidate emit ==="
echo

# AC1: flywheel prompt template mentions next_mission_candidate
assert_one "$INIT" '"next_mission_candidate":' \
  "AC1-a: flywheel prompt JSON Format includes next_mission_candidate field"
assert_one "$INIT" 'Optional field — \`next_mission_candidate\` \(string \| null\)' \
  "AC1-b: flywheel prompt explains the field semantics"
assert_one "$INIT" 'consumer wrapper' \
  "AC1-c: flywheel prompt clarifies wrapper is the consumer (not auto-launch)"

# AC2: Node leader captures field into state
assert_one "$LOOP" 'state\.next_mission_candidate = flywheelSignal\.next_mission_candidate \?\? null' \
  "AC2: campaign-main-loop captures next_mission_candidate with null fallback"

# AC3: governance.md §7 documents the field
assert_one "$GOV" 'next_mission_candidate' \
  "AC3-a: governance §7 references next_mission_candidate"
assert_one "$GOV" 'multi-mission-orchestration\.md' \
  "AC3-b: governance points wrappers to the orchestration doc"

# AC4: docs/multi-mission-orchestration.md describes both emit and consumer sides
assert_one "$DOCS" 'Emit side \(rlp-desk responsibility\)' \
  "AC4-a: docs explicitly cover the emit side"
assert_one "$DOCS" 'Consumer side \(wrapper responsibility\)' \
  "AC4-b: docs explicitly cover the consumer side"
assert_one "$DOCS" 'absence is treated as `null`' \
  "AC4-c: docs document backward-compat (absent → null)"

# AC5: behavioural — fixture flywheel signal JSON parses through the leader's
# capture pattern. We don't spawn the full leader; we exercise the JS expression
# in isolation to lock the contract. Pass JSON via stdin to avoid shell-escape
# issues with embedded quotes.
_capture() {
  local fixture="$1"
  printf '%s' "$fixture" | node --input-type=module -e '
let raw = "";
process.stdin.on("data", c => raw += c);
process.stdin.on("end", () => {
  const flywheelSignal = JSON.parse(raw);
  const captured = flywheelSignal.next_mission_candidate ?? null;
  process.stdout.write(captured === null ? "null" : captured);
});
' 2>&1
}
out_present=$(_capture '{"decision":"hold","next_mission_candidate":"axis-7-improve"}')
if [[ "$out_present" == "axis-7-improve" ]]; then
  pass "AC5-a: present field captured as slug string"
else
  fail "AC5-a: expected 'axis-7-improve', got '$out_present'"
fi
out_absent=$(_capture '{"decision":"hold"}')
if [[ "$out_absent" == "null" ]]; then
  pass "AC5-b: absent field captured as null (backward-compat)"
else
  fail "AC5-b: expected 'null', got '$out_absent'"
fi
out_explicit_null=$(_capture '{"decision":"hold","next_mission_candidate":null}')
if [[ "$out_explicit_null" == "null" ]]; then
  pass "AC5-c: explicit null captured as null"
else
  fail "AC5-c: expected 'null', got '$out_explicit_null'"
fi

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
