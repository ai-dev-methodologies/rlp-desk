#!/usr/bin/env zsh
# Layer 1.5 approach-escalation enforcement (governance §1f¾, DEFECT-2b
# mechanical half) — zsh predicate behavioral tests.
#
# Sources the REAL lib functions (run_pregate_doneclaim_lint,
# _pregate_register_fail_doneclaim_lint) exactly as
# tests/test_doneclaim_lint.sh does, and drives the NEW branch: when an
# iter-<N>.attempt-history.md artifact exists for the current iteration (the
# escalation-active signal — see DEFECT-2b in run_ralph_desk.zsh), the
# done-claim's `approach_summary` field is required and must be a non-blank
# string; its type must be checked explicitly (`type == "string"`, not `//
# ""`) so a numeric value cannot slip past the emptiness check.
#
# This does NOT touch tests/test_doneclaim_lint.sh or its shared fixtures —
# those are parity-pinned against the Node predicate (src/node/runner/
# done-claim-lint.mjs), which does not yet implement this branch. Extending
# the shared fixture format is cross-agent work tracked separately; this file
# covers the zsh side alone in the meantime.

set -uo pipefail
unset TMUX
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "=== Approach-escalation enforcement (Layer 1.5, governance §1f¾) ==="

# Driver: source lib in a clean zsh with LOGS_DIR/ITERATION/DONE_CLAIM_FILE
# set, an optional attempt-history artifact, run the lint, print outcome.
lint() { # $1=done-claim json (raw text)  $2=1 to create the attempt-history artifact, else 0
  local dc_json="$1" with_history="$2"
  local d="$TMP/$RANDOM"
  mkdir -p "$d/logs"
  print -r -- "$dc_json" > "$d/done-claim.json"
  if (( with_history )); then
    echo "prior attempts" > "$d/logs/iter-005.attempt-history.md"
  fi
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    LOGS_DIR="'"$d"'/logs"
    DONE_CLAIM_FILE="'"$d"'/done-claim.json"
    ITERATION=5
    run_pregate_doneclaim_lint; rc=$?
    print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$rc"
  '
}

# --- A: no attempt-history artifact -> approach-escalation branch is a
#        complete no-op regardless of approach_summary ---------------------
echo "--- A: no escalation active -> branch never fires ---"
OUT_A1=$(lint '{"us_id":"US-001","execution_steps":[{"step":"write_test","ac_id":"AC1"},{"step":"verify_red","ac_id":"AC1"},{"step":"implement","ac_id":"AC1"},{"step":"verify_green","ac_id":"AC1"}]}' 0)
echo "$OUT_A1" | grep -q "REASON=approach_summary_missing" \
  && no "A1: fired approach_summary_missing with no escalation active — $OUT_A1" \
  || ok "A1: no approach-escalation failure when no attempt-history artifact exists"

# --- B: escalation active, approach_summary missing -> FAIL -----------------
echo "--- B: escalation active, approach_summary absent ---"
OUT_B1=$(lint '{"us_id":"US-001","execution_steps":[]}' 1)
echo "$OUT_B1" | grep -q "STATUS=fail REASON=approach_summary_missing"$'\n'"RC=1" \
  || echo "$OUT_B1" | grep -q "STATUS=fail" && echo "$OUT_B1" | grep -q "REASON=approach_summary_missing"
if echo "$OUT_B1" | grep -q "STATUS=fail" && echo "$OUT_B1" | grep -q "REASON=approach_summary_missing"; then
  ok "B1: FAILs with reason=approach_summary_missing when the field is entirely absent"
else
  no "B1: expected fail/approach_summary_missing, got: $OUT_B1"
fi

echo "--- B2: escalation active, approach_summary is blank/whitespace ---"
OUT_B2=$(lint '{"us_id":"US-001","approach_summary":"   ","execution_steps":[]}' 1)
if echo "$OUT_B2" | grep -q "STATUS=fail" && echo "$OUT_B2" | grep -q "REASON=approach_summary_missing"; then
  ok "B2: FAILs on a whitespace-only approach_summary (not just literal absence)"
else
  no "B2: expected fail/approach_summary_missing on blank string, got: $OUT_B2"
fi

echo "--- B3: escalation active, approach_summary is a NUMBER (type guard) ---"
OUT_B3=$(lint '{"us_id":"US-001","approach_summary":42,"execution_steps":[]}' 1)
if echo "$OUT_B3" | grep -q "STATUS=fail" && echo "$OUT_B3" | grep -q "REASON=approach_summary_missing"; then
  ok "B3: FAILs on a non-string (numeric) approach_summary — the explicit type==\"string\" guard, not // \"\", catches this"
else
  no "B3: a numeric approach_summary was NOT rejected — got: $OUT_B3 (regression in the type guard)"
fi

# --- C: escalation active, approach_summary present and non-blank -> the
#        branch is a no-op and falls through to the normal TDD-sequence lint ---
echo "--- C: escalation active, approach_summary present -> passes THIS branch ---"
OUT_C1=$(lint '{"us_id":"US-001","approach_summary":"switched to a recursive descent parser instead of regex","execution_steps":[{"step":"write_test","ac_id":"AC1"},{"step":"verify_red","ac_id":"AC1"},{"step":"implement","ac_id":"AC1"},{"step":"verify_green","ac_id":"AC1"}]}' 1)
if echo "$OUT_C1" | grep -q "STATUS=pass"; then
  ok "C1: a non-blank string approach_summary passes the escalation branch (falls through to a normal pass)"
else
  no "C1: expected pass, got: $OUT_C1"
fi

# --- D: fix-contract builder branches correctly on approach_summary_missing ---
echo "--- D: fix-contract content for an approach_summary_missing failure ---"
D_DIR="$TMP/d"; mkdir -p "$D_DIR/logs"
echo "prior attempts" > "$D_DIR/logs/iter-005.attempt-history.md"
echo '{"us_id":"US-001","execution_steps":[]}' > "$D_DIR/done-claim.json"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  LOGS_DIR="'"$D_DIR"'/logs"
  DONE_CLAIM_FILE="'"$D_DIR"'/done-claim.json"
  ITERATION=5
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=3
  run_pregate_doneclaim_lint
  _pregate_register_fail_doneclaim_lint 5 US-001
'
D_CONTRACT="$D_DIR/logs/iter-005.fix-contract.md"
if [[ -f "$D_CONTRACT" ]] && grep -q "approach_summary" "$D_CONTRACT" && grep -q "attempt-history.md" "$D_CONTRACT"; then
  ok "D1: fix contract for approach_summary_missing names the required field and points at the attempt-history file"
else
  no "D1: fix contract missing/wrong content — $(cat "$D_CONTRACT" 2>/dev/null || echo 'NO FILE')"
fi
if [[ -f "$D_CONTRACT" ]] && ! grep -q "PRE-GATE FAILURE (done-claim format lint)" "$D_CONTRACT"; then
  ok "D2: fix contract does NOT fall through to the generic TDD-sequence body (no blank violation list rendered)"
else
  no "D2: fix contract wrongly rendered the generic TDD-sequence body instead of the approach-escalation body"
fi

# --- E: mutation control — strip the escalation branch on a scratch copy,
#        prove Scenario B1 goes red without it -------------------------------
echo "--- E: mutation control (branch removed must fail B1) ---"
MUT_LIB="$TMP/lib_mutated.zsh"
cp "$LIB" "$MUT_LIB"
python3 - "$MUT_LIB" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
pattern = re.compile(
    r"\n  # Approach-escalation enforcement \(governance §1f¾\).*?"
    r"\n  fi\n\n  local steps_len",
    re.DOTALL,
)
new_text, n = pattern.subn("\n\n  local steps_len", text)
assert n == 1, f"expected exactly 1 match, got {n}"
with open(path, "w") as f:
    f.write(new_text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "E0: mutation setup failed (could not strip the escalation branch)"
else
  ok "E0: mutation setup stripped the approach-escalation branch from a scratch copy"
  OUT_E=$(DC_LIB="$MUT_LIB" zsh --no-rcs -c '
    source "$DC_LIB" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    d="'"$TMP"'/e"; mkdir -p "$d/logs"
    echo "prior attempts" > "$d/logs/iter-005.attempt-history.md"
    echo "{\"us_id\":\"US-001\",\"execution_steps\":[]}" > "$d/done-claim.json"
    LOGS_DIR="$d/logs"; DONE_CLAIM_FILE="$d/done-claim.json"; ITERATION=5
    run_pregate_doneclaim_lint; rc=$?
    print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$rc"
  ')
  if echo "$OUT_E" | grep -q "REASON=approach_summary_missing"; then
    no "E1: mutation control INEFFECTIVE — still failed with approach_summary_missing without the branch"
  else
    ok "E1: mutation control effective — without the branch, a missing approach_summary is no longer caught (proves B1 tests the real fix)"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
