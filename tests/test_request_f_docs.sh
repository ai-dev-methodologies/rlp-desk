#!/usr/bin/env bash
# Test Suite: request-f §2/§3 doc-presence — work-type classification gate + ledger-seed governance line
# Doc-presence only (grep -q on source files), per the request-f §2/§3 batch contract.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$REPO_ROOT/src/commands/rlp-desk.md"
GOV="$REPO_ROOT/src/governance.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_has() {
  local file="$1" needle="$2" label="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (missing '$needle' in $file)"
  fi
}

echo "=== request-f §2/§3: doc-presence (work-type classification + ledger-seed) ==="
echo ""

# ============================================================
# §2 — rlp-desk.md: 무인-완주 점검 extended with 명세형/발굴형 axis
# ============================================================
assert_has "$CMD" "명세형" "CMD: 명세형 (specification-type) term present"
assert_has "$CMD" "발굴형" "CMD: 발굴형 (discovery-type) term present"
assert_has "$CMD" "선행 정찰" "CMD: 선행 정찰 (prior reconnaissance) recovery-path term present"
assert_has "$CMD" "parallel supervisor investigation" "CMD: mid-campaign fragment rule (parallel supervisor investigation) present"

# ============================================================
# §2 — governance.md: new IL-2¾ block
# ============================================================
assert_has "$GOV" "IL-2¾" "GOV: IL-2¾ section marker present"
assert_has "$GOV" "명세형" "GOV: 명세형 (specification-type) term present"
assert_has "$GOV" "발굴형" "GOV: 발굴형 (discovery-type) term present"
assert_has "$GOV" "선행 정찰" "GOV: 선행 정찰 (prior reconnaissance) recovery-path term present"
assert_has "$GOV" "parallel supervisor investigation" "GOV: mid-campaign fragment rule (parallel supervisor investigation) present"

# ============================================================
# §3 — governance.md: operator-seed ledger-seed rule (§1f)
# ============================================================
assert_has "$GOV" "ledger-seed" "GOV: ledger-seed command name present"
assert_has "$GOV" "seeded:true" "GOV: seeded:true field present"
assert_has "$GOV" "operator_note" "GOV: operator_note field present"
assert_has "$GOV" "routes verification mode" "GOV: 'routes verification mode' (seed never grants a pass) present"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
