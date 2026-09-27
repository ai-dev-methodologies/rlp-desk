#!/usr/bin/env zsh
# reaudit wave 4 — lib-only fixes (H2, M3, L1, L2, M5-lib), confirmed by an
# earlier adversarial-review pass (scratch repros under w3adv/). All five
# functions under test live in src/scripts/lib_ralph_desk.zsh; this suite
# sources the REAL functions (never retypes their logic) and, for each
# finding, adds a mutation control: a scratch copy of the lib with the fix
# regex-stripped back out, sourced separately, proving the assertion actually
# depends on the fix rather than passing by accident.
#
# H2  [HIGH]   _verdict_criteria_effective fails open on non-object entries
#              in criteria_results (a jq type error on ANY element aborts the
#              whole comprehension with empty output -> falls back to 0).
# M3  [MEDIUM] atomic_write() let a PRE-GATE fix contract overwrite the most
#              recently recorded VERIFIER fix contract in US_FIX_CONTRACT.
# L1  [LOW]    _record_us_attempt capped with `head -n 3` on RAW LINES, so a
#              single multi-line summary could evict every prior attempt.
# L2  [LOW]    approach_summary blank-detection disagreed with the Node
#              mirror on NBSP / Unicode space / zero-width / BOM values.
# M5  [MEDIUM, lib part] _record_us_attempt never recorded the WORKER's own
#              approach_summary, only the verifier's failure summary.

set -uo pipefail
unset TMUX
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS: $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL: $1"; return 0; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# Builds a single Unicode character from a hex codepoint via python3 — used
# ONLY for L2's blank-Unicode fixtures. Deliberately avoids writing a literal
# \uXXXX escape or a raw multi-byte character anywhere in this file's own
# source (both are exactly the kind of hard-to-review invisible byte this
# suite is testing the leader's HANDLING of, not something this test file
# should itself contain).
_uchar() { python3 -c "import sys; sys.stdout.write(chr(int(sys.argv[1], 16)))" "$1"; }

echo "=== reaudit wave 4: lib-only fixes (H2 / M3 / L1 / L2 / M5-lib) ==="

# =============================================================================
# H2: _verdict_criteria_effective fail-closed on garbage array entries
# =============================================================================
echo ""
echo "--- H2: _verdict_criteria_effective fails OPEN on non-object entries (fixed) ---"
source "$LIB" 2>/dev/null

vf() { local name="$1" body="$2"; local f="$TMPD/$name.json"; print -r -- "$body" > "$f"; print -r -- "$f"; }

# Adversarial repro 1 (w3adv): a real met:false object sitting next to a raw
# string entry. Before the fix, jq raised a type error indexing `.met` on the
# string, aborting the WHOLE comprehension -> unmet fell back to "0" -> the
# real met:false was silently lost.
f=$(vf h2-repro1 '{"criteria_results":[{"criterion":"AC-1","met":false},"AC-2 verified"]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|2|1" ]] \
  && ok "H2.1 repro1 [{met:false},\"string\"] -> populated|2|1 (real fail + garbage both counted, garbage folded into unmet)" \
  || no "H2.1 repro1 (got: $r, want: populated|2|1)"

# Adversarial repro 2 (w3adv): a real met:false object next to a raw number.
f=$(vf h2-repro2 '{"criteria_results":[{"met":false},42]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|2|1" ]] \
  && ok "H2.2 repro2 [{met:false},42] -> populated|2|1" \
  || no "H2.2 repro2 (got: $r, want: populated|2|1)"

# All-garbage array, no object at all: BOTH entries fold into unmet (fail-closed)
# and into malformed_entries.
f=$(vf h2-allgarbage '{"criteria_results":["x","y"]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|2|2" ]] \
  && ok "H2.3 all-non-object array -> populated|2|2 (pure garbage still forces a fail via unmet)" \
  || no "H2.3 all-garbage (got: $r, want: populated|2|2)"

# reaudit wave 4, lead's call (second pass): an OBJECT entry with a
# missing/non-boolean `met` — even with NO other met:false or non-object
# entry anywhere in the array — is now ALSO folded into unmet, not just
# malformed_entries. This overturns my own first-pass wave-4 design (which
# kept this case malformed-only, matching wave-1 test 8/9): governance says
# garbage cannot credit a US, and since neither call site branches on
# malformed_entries alone, an entry-level-only malformed result could never
# force a fail on its own — exactly the "met":"false" fail-open the
# adversarial review flagged in the first place. tests/test_criteria_results_
# load_bearing.zsh tests 8/9 were updated in lockstep to populated|1|1.
f=$(vf h2-missingmet '{"criteria_results":[{"criterion":"AC1"},{"criterion":"AC2","met":true}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|1|1" ]] \
  && ok "H2.4 object missing 'met', no other unmet entry -> populated|1|1 (folded into unmet too, matches wave-1 test 8's NEW expectation)" \
  || no "H2.4 missing-met (got: $r, want: populated|1|1)"

f=$(vf h2-stringmet '{"criteria_results":[{"criterion":"AC1","met":"false"}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|1|1" ]] \
  && ok "H2.5 met as string \"false\", no other unmet entry -> populated|1|1 (the exact adversarial repro, now forces a fail)" \
  || no "H2.5 string-met (got: $r, want: populated|1|1)"

f=$(vf h2-allmet '{"criteria_results":[{"met":true},{"met":true}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|0|0" ]] \
  && ok "H2.6 sanity: all met:true -> populated|0|0" \
  || no "H2.6 all-met-true (got: $r, want: populated|0|0)"

echo "--- H2b: real main-loop call site now fails on the adversarial fixtures ---"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
extract_marked() {
  awk -v start="$1" -v stopre="$2" '$0 ~ start { c=1 } c { print; if ($0 ~ stopre) exit }' "$RUN"
}
main_loop_snippet=$(extract_marked 'reaudit wave 1: make criteria_results LOAD-BEARING' '^        fi$')
[[ -n "$main_loop_snippet" ]] || no "H2b EXTRACT: main-loop snippet not found in $RUN (marker text changed?)"

main_loop_harness() {
  local vfile="$1" top_verdict="$2" hf="$TMPD/mainloop-h2-$RANDOM.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { :; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
VERDICT_FILE='$vfile'
ITERATION=1
signal_us_id='US-001'
verdict='$top_verdict'
SETUP
  print -r -- "$main_loop_snippet" >> "$hf"
  print -r -- 'echo "RESULT_VERDICT=$verdict"' >> "$hf"
  zsh "$hf" 2>&1
}

f=$(vf h2-mainloop-repro1 '{"verdict":"pass","criteria_results":[{"criterion":"AC-1","met":false},"AC-2 verified"]}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "H2b.1 main-loop: mixed real-fail + garbage array now overrides pass -> fail (was silently pass before the fix)" \
  || no "H2b.1 main-loop repro1 (got: $out)"

f=$(vf h2-mainloop-repro2 '{"verdict":"pass","criteria_results":[{"met":false},42]}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "H2b.2 main-loop: [{met:false},42] overrides pass -> fail" \
  || no "H2b.2 main-loop repro2 (got: $out)"

# H2b.3: THE original adversarial finding, end to end. A criteria_results
# array whose ONLY entry is an object with met:"false" (a string, not a
# boolean) — no other met:false, no non-object entry anywhere. Before the
# lead's second-pass call, this stayed malformed-only and did NOT override
# the top-level verdict here (my first wave-4 pass still had this gap).
f=$(vf h2-mainloop-stringmet '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":"false"}]}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "H2b.3 main-loop: THE adversarial repro (met:\"false\", nothing else malformed) overrides pass -> fail" \
  || no "H2b.3 main-loop met:\"false\" repro (got: $out)"

echo "--- H2c: mutation control (old unguarded jq must fail-open on repro1) ---"
MUT_LIB_H2="$TMPD/lib_mutated_h2.zsh"
cp "$LIB" "$MUT_LIB_H2"
python3 - "$MUT_LIB_H2" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '''    unmet=$(jq '[.criteria_results[]? | select((type != "object") or ((.met|type) != "boolean") or (.met == false))] | length' "$vf" 2>/dev/null)'''
new = '''    unmet=$(jq '[.criteria_results[]? | select(.met == false)] | length' "$vf" 2>/dev/null)'''
assert old in text, "H2 unmet expression not found for mutation"
text = text.replace(old, new, 1)
old2 = '''    malformed_entries=$(jq '[.criteria_results[]? | select((type != "object") or ((.met|type) != "boolean"))] | length' "$vf" 2>/dev/null)'''
new2 = '''    malformed_entries=$(jq '[.criteria_results[]? | select((.met|type) != "boolean")] | length' "$vf" 2>/dev/null)'''
assert old2 in text, "H2 malformed_entries expression not found for mutation"
text = text.replace(old2, new2, 1)
with open(path, "w") as f:
    f.write(text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "H2c.0 mutation setup failed (could not revert to the old unguarded jq)"
else
  ok "H2c.0 mutation setup reverted _verdict_criteria_effective to the pre-fix unguarded jq"
  h2c_fixture=$(vf h2-repro1-mut '{"criteria_results":[{"criterion":"AC-1","met":false},"AC-2 verified"]}')
  OUT_H2C=$(MUT_LIB="$MUT_LIB_H2" FIXTURE="$h2c_fixture" zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    _verdict_criteria_effective "$FIXTURE"
  ')
  if [[ "$OUT_H2C" == "populated|2|1" ]]; then
    no "H2c.1 mutation control INEFFECTIVE — old code still produced populated|2|1 (does not prove the fix)"
  else
    ok "H2c.1 mutation control effective — without the type guard the old code fails open (got: $OUT_H2C, real fix gives populated|2|1)"
  fi
fi

echo "--- H2d: mutation control (entry-level-only malformed must fold into unmet, lead's second-pass call) ---"
MUT_LIB_H2D="$TMPD/lib_mutated_h2d.zsh"
cp "$LIB" "$MUT_LIB_H2D"
python3 - "$MUT_LIB_H2D" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
# Revert ONLY the fold-in of the object-with-bad-met case (keep the
# non-object type guard from H2c intact) -- this isolates the lead's
# second-pass decision from the original crash-fix, proving H2.4/H2.5/H2b.3
# actually depend on it.
old = '''    unmet=$(jq '[.criteria_results[]? | select((type != "object") or ((.met|type) != "boolean") or (.met == false))] | length' "$vf" 2>/dev/null)'''
new = '''    unmet=$(jq '[.criteria_results[]? | select((type != "object") or (type == "object" and .met == false))] | length' "$vf" 2>/dev/null)'''
assert old in text, "H2 unmet expression not found for H2d mutation"
text = text.replace(old, new, 1)
with open(path, "w") as f:
    f.write(text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "H2d.0 mutation setup failed (could not revert the entry-level fold)"
else
  ok "H2d.0 mutation setup reverted to fold-only-non-object-entries (the lead's second-pass decision undone)"
  h2d_fixture=$(vf h2-stringmet-mut '{"criteria_results":[{"criterion":"AC1","met":"false"}]}')
  OUT_H2D=$(MUT_LIB="$MUT_LIB_H2D" FIXTURE="$h2d_fixture" zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    _verdict_criteria_effective "$FIXTURE"
  ')
  if [[ "$OUT_H2D" == "populated|1|1" ]]; then
    no "H2d.1 mutation control INEFFECTIVE — old fold-only-non-object code still produced populated|1|1"
  else
    ok "H2d.1 mutation control effective — without folding object-with-bad-met entries, THE adversarial repro (met:\"false\") stays fail-open (got: $OUT_H2D, real fix gives populated|1|1; proves H2.5/H2b.3 test the real fix)"
  fi
fi

# =============================================================================
# M3: pregate fix contracts must never clobber the recorded VERIFIER contract
# =============================================================================
echo ""
echo "--- M3: US_FIX_CONTRACT keeps the latest VERIFIER contract across a pregate fail ---"

m3_setup() { # prints the dir; sets up LOGS_DIR-shaped tmp tree
  local d; d=$(mktemp -d "$TMPD/m3-XXXXXX")
  mkdir -p "$d/logs"
  print -r -- "$d"
}

D=$(m3_setup)
OUT_M3=$(LOGS_D="$D/logs" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  LOGS_DIR="$LOGS_D"
  CURRENT_US="US-001"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=5
  # iter5: real VERIFIER fix contract (mirrors run_ralph_desk.zsh:5063/7052 —
  # no skip_fix_contract_record arg).
  echo "# Fix Contract (from Verifier iteration 5)" | atomic_write "$LOGS_DIR/iter-005.fix-contract.md"
  echo "AFTER_VERIFIER=${US_FIX_CONTRACT[US-001]}"
  # iter6: PRE-GATE approach_summary_missing fail (Layer 1.5).
  DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
  echo "{\"us_id\":\"US-001\",\"execution_steps\":[]}" > "$DONE_CLAIM_FILE"
  echo "prior attempts" > "$LOGS_DIR/iter-006.attempt-history.md"
  ITERATION=6
  run_pregate_doneclaim_lint
  _pregate_register_fail_doneclaim_lint 6 US-001
  echo "AFTER_PREGATE_LINT=${US_FIX_CONTRACT[US-001]}"
  # iter7: PRE-GATE Layer 1 mechanical fail too, for completeness.
  PREGATE_FILE="fake-gate.sh"; PREGATE_EXIT=1; PREGATE_OUTPUT="boom"
  _pregate_register_fail 7 US-001
  echo "AFTER_PREGATE_L1=${US_FIX_CONTRACT[US-001]}"
  # iter8: PRE-GATE Layer 2 replay-mismatch fail too.
  PREGATE_REPLAY_STEP="verify_green"; PREGATE_REPLAY_AC="AC1"; PREGATE_REPLAY_CMD="npm test"
  PREGATE_REPLAY_CLAIMED=0; PREGATE_REPLAY_ACTUAL=1; PREGATE_REPLAY_OUTPUT="mismatch"
  _pregate_register_fail_replay 8 US-001
  echo "AFTER_PREGATE_L2=${US_FIX_CONTRACT[US-001]}"
')

VERIFIER_PATH="$D/logs/iter-005.fix-contract.md"
echo "$OUT_M3" | grep -q "AFTER_VERIFIER=$VERIFIER_PATH" \
  && ok "M3.1 a real verifier fix-contract write IS recorded into US_FIX_CONTRACT" \
  || no "M3.1 verifier record (got: $OUT_M3)"
echo "$OUT_M3" | grep -q "AFTER_PREGATE_LINT=$VERIFIER_PATH" \
  && ok "M3.2 Layer 1.5 (approach_summary_missing) pregate fail does NOT clobber the verifier record" \
  || no "M3.2 pregate-lint clobber check (got: $OUT_M3)"
echo "$OUT_M3" | grep -q "AFTER_PREGATE_L1=$VERIFIER_PATH" \
  && ok "M3.3 Layer 1 (mechanical) pregate fail does NOT clobber the verifier record" \
  || no "M3.3 pregate-L1 clobber check (got: $OUT_M3)"
echo "$OUT_M3" | grep -q "AFTER_PREGATE_L2=$VERIFIER_PATH" \
  && ok "M3.4 Layer 2 (replay mismatch) pregate fail does NOT clobber the verifier record" \
  || no "M3.4 pregate-L2 clobber check (got: $OUT_M3)"
[[ -f "$D/logs/iter-006.fix-contract.md" ]] \
  && ok "M3.5 the pregate fix-contract FILE was still written to disk (only the US_FIX_CONTRACT pointer is protected)" \
  || no "M3.5 pregate contract file missing on disk"

echo "--- M3b: mutation control (unconditional recording must clobber) ---"
MUT_LIB_M3="$TMPD/lib_mutated_m3.zsh"
cp "$LIB" "$MUT_LIB_M3"
python3 - "$MUT_LIB_M3" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
# Finding #7 (reaudit wave 4 round 2) rewrote the M3 guard from a one-line
# unconditional-on-flag check into an if/elif that also allows a non-verifier
# write to occupy an EMPTY/non-verifier slot. The mutation still targets the
# same protection: strip the elif's guard condition (empty-or-non-verifier)
# down to an unconditional record, so ANY non-verifier write clobbers
# whatever is in the slot — including a real verifier contract.
old = '''    elif [[ -z "${US_FIX_CONTRACT[$_fc_us]:-}" || -n "${US_FIX_CONTRACT_NONVERIFIER[$_fc_us]:-}" ]]; then'''
new = '''    else'''
assert old in text, "M3 guard elif condition not found for mutation"
text = text.replace(old, new, 1)
with open(path, "w") as f:
    f.write(text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "M3b.0 mutation setup failed (could not strip the skip_fix_contract_record guard)"
else
  ok "M3b.0 mutation setup stripped the guard (atomic_write records unconditionally again)"
  D2=$(m3_setup)
  OUT_M3B=$(MUT_LIB="$MUT_LIB_M3" LOGS_D="$D2/logs" zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    LOGS_DIR="$LOGS_D"
    CURRENT_US="US-001"
    PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=5
    echo "# Fix Contract (from Verifier iteration 5)" | atomic_write "$LOGS_DIR/iter-005.fix-contract.md"
    DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
    echo "{\"us_id\":\"US-001\",\"execution_steps\":[]}" > "$DONE_CLAIM_FILE"
    echo "prior attempts" > "$LOGS_DIR/iter-006.attempt-history.md"
    ITERATION=6
    run_pregate_doneclaim_lint
    _pregate_register_fail_doneclaim_lint 6 US-001
    echo "AFTER_PREGATE_LINT=${US_FIX_CONTRACT[US-001]}"
  ')
  if echo "$OUT_M3B" | grep -q "AFTER_PREGATE_LINT=$D2/logs/iter-006.fix-contract.md"; then
    ok "M3b.1 mutation control effective — without the guard, the pregate write clobbers US_FIX_CONTRACT (proves M3.2 tests the real fix)"
  else
    no "M3b.1 mutation control INEFFECTIVE — still did not clobber without the guard (got: $OUT_M3B)"
  fi
fi

# =============================================================================
# Finding #7 (reaudit wave 4 round 2): (a) the commit-oracle contract write
# (_oracle_register_fail) lacks the M3 opt-out entirely, so it still clobbers
# a recorded VERIFIER contract; (b) the M3 opt-out as originally shipped has
# a side effect — when NO verifier contract has been recorded YET for a US, a
# pregate/oracle contract must still be carried (pre-wave-4 behavior), so a
# `continue` iteration doesn't lose the only contract available. Fix: the
# opt-out skips recording ONLY when a verifier contract already occupies the
# slot; otherwise it records (marked non-verifier, so a later real verifier
# contract still replaces it, but a later pregate/oracle contract does not
# replace an existing verifier one).
# =============================================================================
echo ""
echo "--- Finding #7: oracle write respects M3, AND a pregate/oracle-only contract still carries ---"

f7_setup() {
  local d; d=$(mktemp -d "$TMPD/f7-XXXXXX")
  mkdir -p "$d/logs"
  print -r -- "$d"
}

# (a) verifier -> oracle: the oracle contract write must NOT clobber the
# already-recorded verifier contract.
D=$(f7_setup)
OUT_F7A=$(LOGS_D="$D/logs" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  LOGS_DIR="$LOGS_D"
  CURRENT_US="US-001"
  ORACLE_FAILURES=0; _ORACLE_FAIL_US=""; ORACLE_FAIL_CAP=5
  ORACLE_REASON="git_facts_unavailable"; ORACLE_DETAIL="test detail"
  # iter5: real VERIFIER fix contract.
  echo "# Fix Contract (from Verifier iteration 5)" | atomic_write "$LOGS_DIR/iter-005.fix-contract.md"
  echo "AFTER_VERIFIER=${US_FIX_CONTRACT[US-001]}"
  # iter6: commit-oracle fail for the SAME US.
  _oracle_register_fail 6 US-001
  echo "AFTER_ORACLE=${US_FIX_CONTRACT[US-001]}"
')
VERIFIER_PATH_F7="$D/logs/iter-005.fix-contract.md"
echo "$OUT_F7A" | grep -q "AFTER_VERIFIER=$VERIFIER_PATH_F7" \
  && ok "F7.1 a real verifier fix-contract write IS recorded into US_FIX_CONTRACT" \
  || no "F7.1 verifier record (got: $OUT_F7A)"
echo "$OUT_F7A" | grep -q "AFTER_ORACLE=$VERIFIER_PATH_F7" \
  && ok "F7.2 commit-oracle contract write does NOT clobber the recorded verifier contract" \
  || no "F7.2 oracle write clobbered the verifier record (got: $OUT_F7A) — atomic_write's oracle call site is missing the M3 opt-out"

# (b) pregate-only (no verifier contract yet) -> continue: the pregate
# contract must still be carried, not silently dropped.
D2=$(f7_setup)
OUT_F7B=$(LOGS_D="$D2/logs" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  LOGS_DIR="$LOGS_D"
  CURRENT_US="US-001"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=5
  DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
  echo "{\"us_id\":\"US-001\",\"execution_steps\":[]}" > "$DONE_CLAIM_FILE"
  echo "prior attempts" > "$LOGS_DIR/iter-006.attempt-history.md"
  ITERATION=6
  run_pregate_doneclaim_lint
  _pregate_register_fail_doneclaim_lint 6 US-001
  echo "AFTER_PREGATE_ONLY=${US_FIX_CONTRACT[US-001]:-EMPTY}"
')
PREGATE_PATH_F7B="$D2/logs/iter-006.fix-contract.md"
echo "$OUT_F7B" | grep -q "AFTER_PREGATE_ONLY=$PREGATE_PATH_F7B" \
  && ok "F7.3 a pregate-only fail (no prior verifier contract) STILL carries its contract into US_FIX_CONTRACT" \
  || no "F7.3 pregate-only contract was lost (got: $OUT_F7B) — the only available contract must not be dropped when nothing better exists"

# (c) pregate-only -> LATER real verifier contract must still replace it
# (the non-verifier marker must not become sticky).
D3=$(f7_setup)
OUT_F7C=$(LOGS_D="$D3/logs" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  LOGS_DIR="$LOGS_D"
  CURRENT_US="US-001"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=5
  DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
  echo "{\"us_id\":\"US-001\",\"execution_steps\":[]}" > "$DONE_CLAIM_FILE"
  echo "prior attempts" > "$LOGS_DIR/iter-006.attempt-history.md"
  ITERATION=6
  run_pregate_doneclaim_lint
  _pregate_register_fail_doneclaim_lint 6 US-001
  echo "# Fix Contract (from Verifier iteration 7)" | atomic_write "$LOGS_DIR/iter-007.fix-contract.md"
  echo "AFTER_LATER_VERIFIER=${US_FIX_CONTRACT[US-001]:-EMPTY}"
')
echo "$OUT_F7C" | grep -q "AFTER_LATER_VERIFIER=$D3/logs/iter-007.fix-contract.md" \
  && ok "F7.4 a later real verifier contract still replaces an earlier pregate-only contract" \
  || no "F7.4 later verifier contract failed to replace the pregate-only one (got: $OUT_F7C)"

# =============================================================================
# L1: _record_us_attempt caps by ENTRY, not by raw line
# =============================================================================
echo ""
echo "--- L1: a multi-line summary no longer evicts every prior attempt ---"

OUT_L1=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ITERATION=1
  US_ATTEMPT_HISTORY=()
  _record_us_attempt US-001 gpt-5.4 "FIRST-CALL-MARKER"
  _record_us_attempt US-001 gpt-5.4 "SECOND-CALL-MARKER"
  _record_us_attempt US-001 gpt-5.4 $'"'"'line-one\nline-two\nline-three\nline-four'"'"'
  print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
  print -r -- "---LINECOUNT---"
  print -r -- "${US_ATTEMPT_HISTORY[US-001]}" | wc -l
')
LINECOUNT_L1=$(print -r -- "$OUT_L1" | sed -n '/---LINECOUNT---/,$p' | tail -1 | tr -d ' ')
print -r -- "$OUT_L1" | grep -q "FIRST-CALL-MARKER" \
  && ok "L1.1 oldest real attempt (FIRST-CALL-MARKER) survives a later multi-line summary" \
  || no "L1.1 FIRST-CALL-MARKER evicted (got: $OUT_L1)"
print -r -- "$OUT_L1" | grep -q "SECOND-CALL-MARKER" \
  && ok "L1.2 middle real attempt (SECOND-CALL-MARKER) survives" \
  || no "L1.2 SECOND-CALL-MARKER evicted (got: $OUT_L1)"
print -r -- "$OUT_L1" | grep -q "line-one line-two line-three line-four" \
  && ok "L1.3 the multi-line summary itself is collapsed to ONE physical line (embedded newlines -> spaces)" \
  || no "L1.3 multi-line summary not collapsed (got: $OUT_L1)"
[[ "$LINECOUNT_L1" == "3" ]] \
  && ok "L1.4 exactly 3 physical lines total (ATTEMPT_HISTORY_CAP=3 entries, not 3 raw lines-worth)" \
  || no "L1.4 expected 3 lines, got $LINECOUNT_L1"

# Cap-by-entry still evicts the genuinely oldest entry on a 4th call.
OUT_L1B=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ITERATION=1
  US_ATTEMPT_HISTORY=()
  _record_us_attempt US-001 gpt-5.4 "CALL-ONE"
  _record_us_attempt US-001 gpt-5.4 "CALL-TWO"
  _record_us_attempt US-001 gpt-5.4 "CALL-THREE"
  _record_us_attempt US-001 gpt-5.4 "CALL-FOUR"
  print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
')
print -r -- "$OUT_L1B" | grep -q "CALL-ONE" \
  && no "L1.5 CALL-ONE should have been evicted by the 4th call (cap not enforced)" \
  || ok "L1.5 the genuinely oldest entry (CALL-ONE) IS evicted once >3 real attempts exist"
print -r -- "$OUT_L1B" | grep -q "CALL-FOUR" \
  && ok "L1.6 the newest entry (CALL-FOUR) is present" \
  || no "L1.6 CALL-FOUR missing (got: $OUT_L1B)"

echo "--- L1b: mutation control (uncollapsed summary must evict prior attempts) ---"
MUT_LIB_L1="$TMPD/lib_mutated_l1.zsh"
cp "$LIB" "$MUT_LIB_L1"
python3 - "$MUT_LIB_L1" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = 'local clean_summary="${summary//$\'\\n\'/ }"'
new = 'local clean_summary="$summary"'
assert old in text, "L1 collapsing line not found for mutation"
text = text.replace(old, new, 1)
with open(path, "w") as f:
    f.write(text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "L1b.0 mutation setup failed (could not strip the newline-collapsing line)"
else
  ok "L1b.0 mutation setup stripped newline-collapsing (summary flows through raw again)"
  OUT_L1C=$(MUT_LIB="$MUT_LIB_L1" zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    ITERATION=1
    US_ATTEMPT_HISTORY=()
    _record_us_attempt US-001 gpt-5.4 "FIRST-CALL-MARKER"
    _record_us_attempt US-001 gpt-5.4 "SECOND-CALL-MARKER"
    _record_us_attempt US-001 gpt-5.4 $'"'"'line-one\nline-two\nline-three\nline-four'"'"'
    print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
  ')
  if print -r -- "$OUT_L1C" | grep -q "FIRST-CALL-MARKER"; then
    no "L1b.1 mutation control INEFFECTIVE — FIRST-CALL-MARKER survived even without collapsing"
  else
    ok "L1b.1 mutation control effective — without collapsing, a single multi-line summary evicts every prior attempt (proves L1.1/L1.2 test the real fix)"
  fi
fi

# =============================================================================
# L2: approach_summary blank-detection parity (Unicode whitespace / zero-width / BOM)
# =============================================================================
echo ""
echo "--- L2: blank-only Unicode/zero-width/BOM approach_summary values now FAIL ---"

l2_lint() { # $1 = approach_summary value (raw bytes) -> prints STATUS=.. REASON=..
  local value="$1" d; d=$(mktemp -d "$TMPD/l2-XXXXXX")
  mkdir -p "$d/logs"
  echo "prior attempts" > "$d/logs/iter-001.attempt-history.md"
  jq -n --arg v "$value" '{us_id:"US-001", approach_summary:$v, execution_steps:[]}' > "$d/done-claim.json"
  # L2 (reaudit wave 4): LC_ALL=C is the exact environment the finding names
  # — under a UTF-8 locale, zsh's own [[:space:]] class (via the C library's
  # wide-char classification) already recognizes several of these as space,
  # masking the bug this suite is pinning. The fix under test (jq-based
  # stripping) does not depend on locale at all, so forcing C here only
  # tightens the test, it never weakens it.
  LOGS_D="$d/logs" DC="$d/done-claim.json" LC_ALL=C zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    LOGS_DIR="$LOGS_D"; DONE_CLAIM_FILE="$DC"; ITERATION=1
    run_pregate_doneclaim_lint; rc=$?
    print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$rc"
  '
}

declare -a L2_LABELS L2_VALUES
L2_LABELS+=("NBSP only");            L2_VALUES+=("$(_uchar 00A0)")
L2_LABELS+=("U+2007 FIGURE SPACE");  L2_VALUES+=("$(_uchar 2007)")
L2_LABELS+=("U+3000 IDEOGRAPHIC");   L2_VALUES+=("$(_uchar 3000)")
L2_LABELS+=("U+200B ZERO WIDTH");    L2_VALUES+=("$(_uchar 200B)")
L2_LABELS+=("U+200C ZWNJ");          L2_VALUES+=("$(_uchar 200C)")
L2_LABELS+=("U+200D ZWJ");           L2_VALUES+=("$(_uchar 200D)")
L2_LABELS+=("U+2060 WORD JOINER");   L2_VALUES+=("$(_uchar 2060)")
L2_LABELS+=("U+FEFF BOM/ZWNBSP");    L2_VALUES+=("$(_uchar FEFF)")

for i in {1..8}; do
  label="${L2_LABELS[$i]}"
  value="${L2_VALUES[$i]}"
  out=$(l2_lint "$value")
  echo "$out" | grep -q "STATUS=fail REASON=approach_summary_missing" \
    && ok "L2.$i blank-only ($label) -> fail approach_summary_missing" \
    || no "L2.$i blank-only ($label) expected fail/approach_summary_missing (got: $out)"
done

# Regression: a genuinely non-blank summary (even one padded with these same
# characters) still passes the escalation branch (falls through to the
# no-steps skip — l2_lint's fixture has empty execution_steps — rather than
# failing approach_summary_missing).
padded="$(_uchar 00A0)switched to a recursive descent parser$(_uchar 200B)"
out=$(l2_lint "$padded")
echo "$out" | grep -q "REASON=approach_summary_missing" \
  && no "L2.9 padded real content wrongly flagged approach_summary_missing (got: $out)" \
  || ok "L2.9 real content padded with NBSP/zero-width chars passes the escalation branch"

echo "--- L2b: mutation control (old [[:space:]]-only strip must let some of these pass) ---"
MUT_LIB_L2="$TMPD/lib_mutated_l2.zsh"
cp "$LIB" "$MUT_LIB_L2"
python3 - "$MUT_LIB_L2" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
pattern = re.compile(
    r'    local _approach_summary_status\n.*?'
    r'    if \[\[ "\$_approach_summary_status" != "nonempty" \]\]; then',
    re.DOTALL,
)
old_block = (
    '    local _approach_summary\n'
    '    _approach_summary=$(jq -r \'if (.approach_summary|type) == "string" then .approach_summary else "" end\' "$DONE_CLAIM_FILE" 2>/dev/null)\n'
    '    if [[ -z "${_approach_summary//[[:space:]]/}" ]]; then'
)
new_text, n = pattern.subn(lambda m: old_block, text)
assert n == 1, f"expected exactly 1 match for the L2 block, got {n}"
with open(path, "w") as f:
    f.write(new_text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "L2b.0 mutation setup failed (could not revert to the old [[:space:]]-only strip)"
else
  ok "L2b.0 mutation setup reverted to the old [[:space:]]-only strip"
  d=$(mktemp -d "$TMPD/l2b-XXXXXX")
  mkdir -p "$d/logs"
  echo "prior attempts" > "$d/logs/iter-001.attempt-history.md"
  jq -n --arg v "$(_uchar 00A0)" '{us_id:"US-001", approach_summary:$v, execution_steps:[]}' > "$d/done-claim.json"
  OUT_L2B=$(MUT_LIB="$MUT_LIB_L2" LOGS_D="$d/logs" DC="$d/done-claim.json" LC_ALL=C zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    LOGS_DIR="$LOGS_D"; DONE_CLAIM_FILE="$DC"; ITERATION=1
    run_pregate_doneclaim_lint; rc=$?
    print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$rc"
  ')
  if echo "$OUT_L2B" | grep -q "STATUS=fail"; then
    no "L2b.1 mutation control INEFFECTIVE — old code still correctly failed on NBSP-only (does not prove L2.1 tests the real fix)"
  else
    ok "L2b.1 mutation control effective — under the old [[:space:]]-only strip, an NBSP-only approach_summary WRONGLY passes (got: $OUT_L2B; proves L2.1 tests the real fix)"
  fi
fi

# =============================================================================
# M5 (lib part): _record_us_attempt carries the WORKER's own approach_summary
# =============================================================================
echo ""
echo "--- M5: attempt history records the worker's approach_summary, not just the failure summary ---"

D5=$(mktemp -d "$TMPD/m5-XXXXXX")
echo '{"us_id":"US-001","approach_summary":"switched to a recursive descent parser","execution_steps":[]}' > "$D5/done-claim.json"
OUT_M5=$(DC="$D5/done-claim.json" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ITERATION=9
  DONE_CLAIM_FILE="$DC"
  US_ATTEMPT_HISTORY=()
  _record_us_attempt US-001 gpt-5.4 "verifier said AC1 not covered"
  print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
')
print -r -- "$OUT_M5" | grep -q "verifier said AC1 not covered" \
  && ok "M5.1 the verifier failure summary is still recorded" \
  || no "M5.1 failure summary missing (got: $OUT_M5)"
print -r -- "$OUT_M5" | grep -q "approach: switched to a recursive descent parser" \
  && ok "M5.2 the worker's own approach_summary is ALSO recorded" \
  || no "M5.2 approach_summary not recorded (got: $OUT_M5)"

# Negative: no approach_summary on the done-claim -> no "| approach:" suffix.
D5B=$(mktemp -d "$TMPD/m5b-XXXXXX")
echo '{"us_id":"US-001","execution_steps":[]}' > "$D5B/done-claim.json"
OUT_M5B=$(DC="$D5B/done-claim.json" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ITERATION=9
  DONE_CLAIM_FILE="$DC"
  US_ATTEMPT_HISTORY=()
  _record_us_attempt US-001 gpt-5.4 "verifier said AC1 not covered"
  print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
')
print -r -- "$OUT_M5B" | grep -q "| approach:" \
  && no "M5.3 an approach suffix was rendered with no approach_summary on the done-claim (got: $OUT_M5B)" \
  || ok "M5.3 no approach_summary on the done-claim -> no '| approach:' suffix"

echo "--- M5b: mutation control (stripped approach-reading must never show 'approach:') ---"
MUT_LIB_M5="$TMPD/lib_mutated_m5.zsh"
cp "$LIB" "$MUT_LIB_M5"
python3 - "$MUT_LIB_M5" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
pattern = re.compile(
    r'  local approach=""\n'
    r'  if \[\[ -f "\$\{DONE_CLAIM_FILE:-\}" \]\] && command -v jq >/dev/null 2>&1; then\n'
    r'    approach=\$\(jq -r .*?\n'
    r'    approach="\$\{approach//\$\'\\n\'/ \}"\n'
    r'  fi\n'
    r'  local line="iter \$\{ITERATION:-\?\} \(\$\{model\}\): \$\{clean_summary:0:120\}"\n'
    r'  \[\[ -n "\$\{approach//\[\[:space:\]\]/\}" \]\] && line="\$\{line\} \| approach: \$\{approach:0:80\}"\n',
    re.DOTALL,
)
new_block = '  local line="iter ${ITERATION:-?} (${model}): ${clean_summary:0:120}"\n'
new_text, n = pattern.subn(lambda m: new_block, text)
assert n == 1, f"expected exactly 1 match for the M5 block, got {n}"
with open(path, "w") as f:
    f.write(new_text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "M5b.0 mutation setup failed (could not strip the approach-reading block)"
else
  ok "M5b.0 mutation setup stripped the approach_summary-reading block"
  OUT_M5C=$(MUT_LIB="$MUT_LIB_M5" DC="$D5/done-claim.json" zsh --no-rcs -c '
    source "$MUT_LIB" 2>/dev/null
    ITERATION=9
    DONE_CLAIM_FILE="$DC"
    US_ATTEMPT_HISTORY=()
    _record_us_attempt US-001 gpt-5.4 "verifier said AC1 not covered"
    print -r -- "${US_ATTEMPT_HISTORY[US-001]}"
  ')
  if print -r -- "$OUT_M5C" | grep -q "approach: switched"; then
    no "M5b.1 mutation control INEFFECTIVE — approach text still appeared without the block"
  else
    ok "M5b.1 mutation control effective — without the block, the approach_summary never appears (proves M5.2 tests the real fix)"
  fi
fi

echo ""
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "============================================"
(( FAIL == 0 ))
