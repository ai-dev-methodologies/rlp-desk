#!/bin/zsh
# F8: the zsh Worker prompt wrapper around a Verifier fix contract must not tell
# the Worker to always change code. A done-claim record-format / TDD-evidence
# issue is fixed by correcting the record and resubmitting it, keeping the
# RED/GREEN evidence already recorded. The Node mirror carries the identical text.
set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

LINE1='Where an issue is in the code, change the code — do not just resubmit the same work.'
LINE2='Where the contract asks you only to correct the done-claim record (format or TDD evidence), correct the record and resubmit it: keep the RED/GREEN evidence you already recorded, never reorder or relabel steps to differ from what you actually ran, and do not re-implement the deliverable.'

# Isolate the fix-contract wrapper block (heading through the contract cat).
BLOCK=$(awk '/## IMPORTANT: Fix Contract from Verifier/{p=1} p{print} p && /cat "\$fix_contract_file"/{exit}' "$RUN")
[[ -n "$BLOCK" ]] && ok "F8-0 fix-contract wrapper block found" || no "F8-0 wrapper block not found"

print -r -- "$BLOCK" | grep -qF -- "echo \"$LINE1\"" \
  && ok "F8-1 wrapper carries the code-issue line" || no "F8-1 code-issue line missing"
print -r -- "$BLOCK" | grep -qF -- "echo \"$LINE2\"" \
  && ok "F8-2 wrapper carries the done-claim-record line" || no "F8-2 done-claim-record line missing"
print -r -- "$BLOCK" | grep -qF -- 'Do NOT just resubmit — actually change the code to address each issue.' \
  && no "F8-3 old always-change-the-code sentence still present" || ok "F8-3 old sentence removed"
# order: the two new lines sit where the old one was (after the MUST-fix line, before the contract body)
_must=$(print -r -- "$BLOCK" | grep -n 'You MUST fix the issues below' | cut -d: -f1)
_l1=$(print -r -- "$BLOCK" | grep -nF -- "$LINE1" | cut -d: -f1)
_l2=$(print -r -- "$BLOCK" | grep -nF -- "$LINE2" | cut -d: -f1)
_cat=$(print -r -- "$BLOCK" | grep -n 'cat "$fix_contract_file"' | cut -d: -f1)
(( ${_must:-0} > 0 && ${_l1:-0} == _must + 1 && ${_l2:-0} == _l1 + 1 && ${_cat:-0} > _l2 )) \
  && ok "F8-4 order: MUST-fix line, code line, record line, then the contract body" || no "F8-4 order wrong (must=$_must l1=$_l1 l2=$_l2 cat=$_cat)"

print ""
print "w1_fix_contract_wording: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
