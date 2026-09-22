#!/usr/bin/env zsh
# Guard: lib_ralph_desk.zsh must be self-sufficient for the globals ITS OWN
# functions use — it must not depend on run_ralph_desk.zsh having declared
# them first.
#
# Root cause (found live by another agent, confirmed by team-lead, 2026-09-14):
# atomic_write() (lib) and _record_us_attempt() (lib) both read/write
# US_FIX_CONTRACT / US_ATTEMPT_HISTORY, but those maps were declared with a
# bare `typeset -A` in run_ralph_desk.zsh — a file that any standalone
# consumer of the lib (e.g. tests/test_doneclaim_lint.sh, which sources only
# lib_ralph_desk.zsh) never reaches. Symptom was
# `atomic_write:45: US_FIX_CONTRACT: assignment to invalid subscript range`
# on every atomic_write call to a *.fix-contract.md path in that suite — 6
# failures that read as unrelated harness noise for a while, which is
# exactly why this needs a test that names the real cause instead of relying
# on it surfacing as noise elsewhere.
#
# Fix: both maps are now `typeset -gA` INSIDE lib_ralph_desk.zsh, next to the
# functions that use them, so the lib carries its own globals regardless of
# who sources it or in what order.
#
# This test EXECUTES the real lib_ralph_desk.zsh sourced completely on its
# own (no run_ralph_desk.zsh in the picture at all) — the exact shape of the
# regression, not a retyped assertion about it.

set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL: $1"; }

echo "=== lib_ralph_desk.zsh must be self-sufficient when sourced standalone ==="

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- A: sourcing the lib alone and calling atomic_write on a fix-contract
#        path must not error, and must populate US_FIX_CONTRACT -----------
echo "--- A: atomic_write() on a *.fix-contract.md path, lib sourced standalone ---"
OUT_A=$(zsh -c "
  set -uo pipefail
  source '$LIB'
  echo 'issue text' | atomic_write '$TMP/iter-001.fix-contract.md'
  echo \"rc=\$?\"
  echo \"file_exists=\$([[ -f '$TMP/iter-001.fix-contract.md' ]] && echo yes || echo no)\"
  echo \"tracked=\${US_FIX_CONTRACT[ALL]:-EMPTY}\"
" 2>&1)
echo "$OUT_A" | sed 's/^/    /'
echo "$OUT_A" | grep -q "^rc=0$" \
  && ok "A1: atomic_write() on a fix-contract path exits 0 standalone (no 'invalid subscript' error)" \
  || no "A1: atomic_write() failed or errored standalone — output above"
echo "$OUT_A" | grep -q "^file_exists=yes$" \
  && ok "A2: the fix-contract file is actually written" \
  || no "A2: the fix-contract file was not written"
echo "$OUT_A" | grep -q "^tracked=$TMP/iter-001.fix-contract.md$" \
  && ok "A3: US_FIX_CONTRACT[ALL] is populated with the written path" \
  || no "A3: US_FIX_CONTRACT was not populated correctly — output above"

# --- B: sourcing the lib alone and calling _record_us_attempt must not
#        error, and must populate US_ATTEMPT_HISTORY -----------------------
echo "--- B: _record_us_attempt() standalone ---"
OUT_B=$(zsh -c "
  set -uo pipefail
  source '$LIB'
  ITERATION=5
  _record_us_attempt 'US-001' 'opus' 'a failure summary'
  echo \"rc=\$?\"
  echo \"history=\${US_ATTEMPT_HISTORY[US-001]:-EMPTY}\"
" 2>&1)
echo "$OUT_B" | sed 's/^/    /'
echo "$OUT_B" | grep -q "^rc=0$" \
  && ok "B1: _record_us_attempt() exits 0 standalone" \
  || no "B1: _record_us_attempt() failed standalone — output above"
echo "$OUT_B" | grep -q "^history=iter 5 (opus): a failure summary$" \
  && ok "B2: US_ATTEMPT_HISTORY[US-001] is populated correctly" \
  || no "B2: US_ATTEMPT_HISTORY was not populated correctly — output above"

# Note: this lib refuses to be sourced from inside a function at all
# (file-header guard at lib_ralph_desk.zsh:8-11, `${funcstack[2]}` check,
# FATAL exit 1) — exactly because a bare `typeset -A` would otherwise scope
# local to that function. That guard is pre-existing and out of scope here;
# `-gA` (vs plain `-A`) on these two new declarations is still the correct,
# defensive choice per the same file-header rule, it just isn't separately
# testable through that guard (sourcing never reaches the declarations).

# --- D: mutation control — strip the -g declarations on a scratch copy,
#        prove Scenario A goes red without them -----------------------------
echo "--- D: mutation control (regression re-injected must fail A1) ---"
MUT_LIB="$TMP/lib_mutated.zsh"
cp "$LIB" "$MUT_LIB"
python3 - "$MUT_LIB" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
before = text
text = text.replace("typeset -gA US_ATTEMPT_HISTORY\n\n", "")
text = text.replace("typeset -gA US_FIX_CONTRACT\n\n", "")
assert text != before, "no typeset -gA lines found to strip — check anchors"
with open(path, "w") as f:
    f.write(text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "D0: mutation setup failed (could not strip the -gA declarations)"
else
  ok "D0: mutation setup stripped both typeset -gA declarations from a scratch copy"
  OUT_D=$(zsh -c "
    set -uo pipefail
    source '$MUT_LIB'
    echo 'issue text' | atomic_write '$TMP/iter-003.fix-contract.md'
    echo \"rc=\$?\"
  " 2>&1)
  echo "$OUT_D" | grep -q "^rc=0$" \
    && no "D1: mutation control INEFFECTIVE — atomic_write still succeeded without the -gA declarations (test does not exercise the real fix)" \
    || ok "D1: mutation control effective — without typeset -gA, atomic_write fails standalone exactly as the live regression did"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
