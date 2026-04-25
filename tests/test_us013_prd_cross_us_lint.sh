#!/usr/bin/env bash
# Test Suite: US-013 — RC-2 PRD cross-US dependency lint + BLOCKED Surfacing
# Covers: L1 brainstorm guide, L2 init lint (exit 2), §1f BLOCKED reason
# propagation through writeSentinel() and run.mjs stderr.

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
GOV="$ROOT_REPO/src/governance.md"
SKILL="$ROOT_REPO/src/commands/rlp-desk.md"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
RUN="$ROOT_REPO/src/node/run.mjs"
FIX_BAD="$ROOT_REPO/tests/fixtures/prd-cross-us-bad.md"
FIX_GOOD="$ROOT_REPO/tests/fixtures/prd-cross-us-good.md"

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

echo "=== US-013: RC-2 PRD cross-US dependency lint + BLOCKED Surfacing ==="
echo

# ------------------------------------------------------------------
# AC1: L1 brainstorm guide block in src/commands/rlp-desk.md
# ------------------------------------------------------------------
assert_one "$SKILL" 'Dependency Rule \(per-us mode\)' \
  "AC1-a: Dependency Rule block is present in skill file"
assert_one "$SKILL" 'Forbidden in per-us mode: future-US references' \
  "AC1-b: explicit future-US forbidden language"

# ------------------------------------------------------------------
# AC2: L1 mirror in governance.md §7a
# ------------------------------------------------------------------
assert_one "$GOV" 'Cross-US dependency rule \(per-us only\)' \
  "AC2-a: governance §7a cross-US rule present"
assert_one "$GOV" 'init_ralph_desk\.zsh' \
  "AC2-b: governance references init lint"

# ------------------------------------------------------------------
# AC3: §1f BLOCKED Surfacing paragraph
# ------------------------------------------------------------------
assert_one "$GOV" 'BLOCKED Surfacing' \
  "AC3-a: §1f BLOCKED Surfacing heading"
assert_one "$GOV" 'three channels at once' \
  "AC3-b: §1f surfacing wording (three channels)"

# ------------------------------------------------------------------
# AC4: L2 lint helper exists
# ------------------------------------------------------------------
assert_one "$INIT" '_detect_cross_us_refs\(\)' \
  "AC4-a: _detect_cross_us_refs() helper defined"
assert_one "$INIT" 'PRD cross-US dependency lint' \
  "AC4-b: lint section comment present"
assert_one "$INIT" 'exit 2' \
  "AC4-c: lint exits 2 on per-us violation"

# ------------------------------------------------------------------
# AC5: L2 lint helper — bad PRD detection (functional)
# Inline-source the helper from the script and run against fixtures.
# ------------------------------------------------------------------
helper_body=$(awk '
  /^_detect_cross_us_refs\(\) \{/ { capture=1; depth=0 }
  capture {
    print
    for (i=1; i<=length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      else if (c == "}") { depth--; if (depth == 0) { capture=0; next } }
    }
  }
' "$INIT")

bad_out=$(zsh -c "$helper_body
_detect_cross_us_refs '$FIX_BAD'")
good_out=$(zsh -c "$helper_body
_detect_cross_us_refs '$FIX_GOOD'")

if echo "$bad_out" | grep -q '^US-001:.*US-003'; then
  pass "AC5-a: bad fixture flags US-001 -> US-003 violation"
else
  fail "AC5-a: bad fixture did not flag expected violation (got: $bad_out)"
fi

if [[ -z "$good_out" ]]; then
  pass "AC5-b: good fixture produces no violations"
else
  fail "AC5-b: good fixture unexpectedly flagged ($good_out)"
fi

# ------------------------------------------------------------------
# AC6: full init integration — bad PRD + per-us -> exit 2
# ------------------------------------------------------------------
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us013-XXXX")
trap "rm -rf '$TMP_ROOT'" EXIT
mkdir -p "$TMP_ROOT/.claude/ralph-desk/plans"
SLUG="us013-bad"
cp "$FIX_BAD" "$TMP_ROOT/.claude/ralph-desk/plans/prd-$SLUG.md"

set +e
ROOT="$TMP_ROOT" VERIFY_MODE="per-us" \
  zsh "$INIT" "$SLUG" "lint integration test" --mode improve \
  >"$TMP_ROOT/init-stdout.log" 2>"$TMP_ROOT/init-stderr.log"
ec=$?
set -e

if [[ "$ec" -eq 2 ]]; then
  pass "AC6-a: per-us + bad PRD exits 2 (got $ec)"
else
  fail "AC6-a: expected exit 2, got $ec (stdout=$(head -3 "$TMP_ROOT/init-stdout.log"; true) | stderr=$(head -3 "$TMP_ROOT/init-stderr.log"; true))"
fi

if grep -q 'cross-US dependency AC incompatible' "$TMP_ROOT/init-stderr.log"; then
  pass "AC6-b: stderr names the incompatibility"
else
  fail "AC6-b: stderr missing incompatibility message"
fi

if grep -q 'US-001 references a higher-numbered US' "$TMP_ROOT/init-stderr.log"; then
  pass "AC6-c: stderr identifies US-001 as the offender"
else
  fail "AC6-c: stderr missing US-001 attribution"
fi

# ------------------------------------------------------------------
# AC7: batch mode -> exit 0 + WARN
# ------------------------------------------------------------------
TMP_ROOT2=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us013-batch-XXXX")
mkdir -p "$TMP_ROOT2/.claude/ralph-desk/plans"
SLUG2="us013-bad-batch"
cp "$FIX_BAD" "$TMP_ROOT2/.claude/ralph-desk/plans/prd-$SLUG2.md"

set +e
ROOT="$TMP_ROOT2" VERIFY_MODE="batch" \
  zsh "$INIT" "$SLUG2" "lint integration test (batch)" --mode improve \
  >"$TMP_ROOT2/init-stdout.log" 2>"$TMP_ROOT2/init-stderr.log"
ec2=$?
set -e
rm -rf "$TMP_ROOT2"

if [[ "$ec2" -eq 0 ]]; then
  pass "AC7-a: batch + bad PRD exits 0 (got $ec2)"
else
  fail "AC7-a: expected exit 0 in batch mode, got $ec2"
fi

# ------------------------------------------------------------------
# AC8: good PRD + per-us -> exit 0
# ------------------------------------------------------------------
TMP_ROOT3=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us013-good-XXXX")
mkdir -p "$TMP_ROOT3/.claude/ralph-desk/plans"
SLUG3="us013-good"
cp "$FIX_GOOD" "$TMP_ROOT3/.claude/ralph-desk/plans/prd-$SLUG3.md"

set +e
ROOT="$TMP_ROOT3" VERIFY_MODE="per-us" \
  zsh "$INIT" "$SLUG3" "good PRD integration test" --mode improve \
  >"$TMP_ROOT3/init-stdout.log" 2>"$TMP_ROOT3/init-stderr.log"
ec3=$?
set -e
rm -rf "$TMP_ROOT3"

if [[ "$ec3" -eq 0 ]]; then
  pass "AC8: per-us + good PRD exits 0 (got $ec3)"
else
  fail "AC8: expected exit 0 for clean PRD, got $ec3"
fi

# ------------------------------------------------------------------
# AC9: writeSentinel signature accepts reason + propagates
# ------------------------------------------------------------------
assert_one "$LOOP" 'async function writeSentinel\(filePath, status, usId, reason\)' \
  "AC9-a: writeSentinel signature includes reason"
assert_one "$LOOP" 'lines.push\(`Reason: \$\{reason\}`\)' \
  "AC9-b: sentinel writes Reason: line"
assert_one "$LOOP" 'verdict\.reason \|\| verdict\.summary \|\| .verifier-blocked.' \
  "AC9-c: blocked branch derives reason from verdict"
assert_one "$LOOP" "writeSentinel\\(paths.blockedSentinel, 'blocked', usId, blockedReason\\)" \
  "AC9-d: blocked branch passes reason to writeSentinel"

# ------------------------------------------------------------------
# AC10: run.mjs surfaces BLOCKED on stderr with exit 2
# ------------------------------------------------------------------
assert_one "$RUN" "result\\.status === 'blocked'" \
  "AC10-a: run.mjs branches on blocked result"
assert_one "$RUN" 'Campaign BLOCKED for' \
  "AC10-b: stderr message present"
assert_one "$RUN" 'return 2' \
  "AC10-c: run.mjs exits 2 on blocked"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
