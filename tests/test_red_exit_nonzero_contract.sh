#!/usr/bin/env bash
# F3 (owner decision 2026-10-13) — RED evidence is a verify_red step with a NON-ZERO exit code.
#
# Why: pytest returns 1 when an assertion fails and 2 when the test module cannot be
# collected (e.g. `import kvstore` before kvstore.py exists). Both are a genuine RED.
# rlp-desk.md's audit table already says "RED exit≠0", but the Verifier contract in
# init_ralph_desk.zsh demanded "exit_code=1", so an honest greenfield RED (exit 2)
# contradicted the contract. The contract and the audit table must agree on non-zero.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
MD="$REPO/src/commands/rlp-desk.md"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

line=$(grep -n 'RED phase evidence:' "$INIT" | head -1)
[ -n "$line" ] && ok "R1 Verifier contract has a RED phase evidence rule" || no "R1 RED phase evidence rule missing from $INIT"
case "$line" in
  *"exit_code=1 for the US"*) no "R2 contract still demands exit_code=1 (must be non-zero)";;
  *) ok "R2 contract no longer demands exactly exit_code=1";;
esac
case "$line" in
  *"non-zero exit_code"*) ok "R3 contract demands a non-zero exit_code";;
  *) no "R3 contract does not say non-zero exit_code";;
esac
case "$line" in
  *"2 = "*) ok "R4 contract names exit 2 (collection/import error) as valid RED";;
  *) no "R4 contract does not name exit 2 as valid RED";;
esac
grep -q 'RED exit≠0' "$MD" && ok "R5 rlp-desk.md audit table keeps 'RED exit≠0'" || no "R5 rlp-desk.md audit table lost 'RED exit≠0'"

echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
