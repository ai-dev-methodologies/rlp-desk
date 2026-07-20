#!/usr/bin/env zsh
# Feature 1: leader-side mechanical pre-gate — behavioral tests.
#
# Sources the REAL lib functions (run_pregate, _pregate_register_fail) with
# fixtures and exercises pass / fail / timeout / absent + the same-US counter,
# the PREGATE_FAIL_CAP force-verifier decision, and the PRE-GATE FAILURE fix
# contract. Structural asserts confirm the call site skips LLM verification on
# short-circuit and is a true no-op when the gate is absent (AC-P2).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Driver: source lib in a clean zsh with the globals run_pregate/_pregate_register_fail
# read, run a snippet, and print exported result lines.
run_lib() { # $1 = zsh snippet body; env passthrough via caller exports
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    ROOT="'"$ROOT_DIR"'"; DESK="$ROOT/.rlp-desk"; SLUG="demo"
    LOGS_DIR="$DESK/logs/$SLUG"; mkdir -p "$DESK/plans" "$LOGS_DIR"
    PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=3
    '"$1"'
  '
}

# ---------------------------------------------------------------------------
print -r -- "-- run_pregate: absent gate is a true no-op (AC-P2)"
ROOT_DIR="$TMP/absent"; mkdir -p "$ROOT_DIR"
out=$(run_lib '
  run_pregate 1 demo; rc=$?
  print "RAN=$PREGATE_RAN RC=$rc"
  logs=("$DESK/logs/$SLUG"/*.pregate-output.log(N))
  (( ${#logs} )) && print "HASLOG" || print "NOLOG"
')
[[ "$out" == *"RAN=0 RC=0"* ]] && ok "absent gate → PREGATE_RAN=0, returns 0" \
  || no "absent gate should be no-op (got: $out)"
[[ "$out" == *"NOLOG"* ]] && ok "absent gate writes no output log (no side effects)" \
  || no "absent gate must not create an output log (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- run_pregate: passing gate → exit 0, proceeds"
ROOT_DIR="$TMP/pass"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
print -r -- '#!/usr/bin/env zsh\nexit 0' > "$ROOT_DIR/.rlp-desk/plans/pregate-demo.sh"
out=$(run_lib '
  run_pregate 1 demo; rc=$?
  print "RAN=$PREGATE_RAN EXIT=$PREGATE_EXIT RC=$rc"
')
[[ "$out" == *"RAN=1 EXIT=0 RC=0"* ]] && ok "passing gate → RAN=1 EXIT=0 return 0" \
  || no "passing gate wrong result (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- run_pregate: failing gate → exit!=0, output tail captured (AC-P1)"
ROOT_DIR="$TMP/fail"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
{ print -r -- '#!/usr/bin/env zsh'; print -r -- 'echo "MISSING src/index.ts"'; print -r -- 'exit 7'; } \
  > "$ROOT_DIR/.rlp-desk/plans/pregate-demo.sh"
out=$(run_lib '
  run_pregate 1 demo; rc=$?
  print "RAN=$PREGATE_RAN EXIT=$PREGATE_EXIT RC=$rc"
  print "OUT<<$PREGATE_OUTPUT>>"
')
[[ "$out" == *"RAN=1 EXIT=7 RC=1"* ]] && ok "failing gate → RAN=1 EXIT=7 return 1" \
  || no "failing gate wrong result (got: $out)"
[[ "$out" == *"MISSING src/index.ts"* ]] && ok "failing gate output tail captured in PREGATE_OUTPUT" \
  || no "gate output not captured (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- run_pregate: timeout → exit 124 + timeout message (AC-P3)"
ROOT_DIR="$TMP/timeout"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
{ print -r -- '#!/usr/bin/env zsh'; print -r -- 'sleep 30'; print -r -- 'exit 0'; } \
  > "$ROOT_DIR/.rlp-desk/plans/pregate-demo.sh"
out=$(RLP_PREGATE_TIMEOUT=1 run_lib '
  run_pregate 1 demo; rc=$?
  print "EXIT=$PREGATE_EXIT RC=$rc"
  print "OUT<<$PREGATE_OUTPUT>>"
')
[[ "$out" == *"EXIT=124 RC=1"* ]] && ok "timeout → EXIT=124 return 1" \
  || no "timeout wrong result (got: $out)"
[[ "$out" == *"pregate timeout after 1s"* ]] && ok "timeout message present in fix-contract output" \
  || no "timeout message missing (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- _pregate_register_fail: 1st fail writes PRE-GATE FAILURE contract, returns 0 (AC-P1)"
ROOT_DIR="$TMP/reg1"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
out=$(run_lib '
  PREGATE_FILE="$DESK/plans/pregate-demo.sh"; PREGATE_EXIT=7
  PREGATE_OUTPUT="TS2307 cannot find module"
  _pregate_register_fail 3 US-001; rc=$?
  print "RC=$rc FAILS=$PREGATE_FAILURES"
  c="$LOGS_DIR/iter-003.fix-contract.md"
  [[ -f "$c" ]] && { print "HASCONTRACT"; grep -q "PRE-GATE FAILURE (mechanical)" "$c" && print "LABELED"; grep -q "TS2307 cannot find module" "$c" && print "HASOUT"; } || print "NOCONTRACT"
')
[[ "$out" == *"RC=0 FAILS=1"* ]] && ok "1st fail → return 0 (short-circuit), counter=1" \
  || no "1st fail wrong (got: $out)"
[[ "$out" == *"HASCONTRACT"* && "$out" == *"LABELED"* ]] && ok "fix contract written + labeled PRE-GATE FAILURE" \
  || no "fix contract missing/unlabeled (got: $out)"
[[ "$out" == *"HASOUT"* ]] && ok "fix contract includes mechanical output" \
  || no "fix contract missing gate output (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- _pregate_register_fail: 3rd consecutive same-US → force verifier (AC-P4)"
ROOT_DIR="$TMP/reg3"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
out=$(run_lib '
  PREGATE_FILE=x; PREGATE_EXIT=1; PREGATE_OUTPUT=y; PREGATE_FAIL_CAP=3
  _pregate_register_fail 1 US-001; r1=$?
  _pregate_register_fail 2 US-001; r2=$?
  _pregate_register_fail 3 US-001; r3=$?
  print "r1=$r1 r2=$r2 r3=$r3 FAILS=$PREGATE_FAILURES"
')
[[ "$out" == *"r1=0 r2=0 r3=1 "* ]] && ok "cap: fails 1,2 short-circuit; 3rd forces verifier (return 1)" \
  || no "cap behavior wrong (got: $out)"
[[ "$out" == *"FAILS=0"* ]] && ok "counter reset to 0 when verifier round forced" \
  || no "counter should reset on force (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- _pregate_register_fail: different US resets the streak"
ROOT_DIR="$TMP/reg_us"; mkdir -p "$ROOT_DIR/.rlp-desk/plans"
out=$(run_lib '
  PREGATE_FILE=x; PREGATE_EXIT=1; PREGATE_OUTPUT=y; PREGATE_FAIL_CAP=3
  _pregate_register_fail 1 US-001
  _pregate_register_fail 2 US-002; r=$?
  print "AFTER_SWITCH_FAILS=$PREGATE_FAILURES r=$r"
')
[[ "$out" == *"AFTER_SWITCH_FAILS=1 r=0"* ]] && ok "US change resets streak to 1 (not 2)" \
  || no "US-change reset failed (got: $out)"

# ===========================================================================
# LAYER 2 — execution_steps replay
# ===========================================================================

# Driver: write a done-claim with the given execution_steps JSON array, run
# run_pregate_replay, print result globals + rc.
replay() { # $1=steps-json-array  [env: CLAIMENV extra]
  local steps="$1"
  local root="$TMP/replay-$RANDOM"; mkdir -p "$root/.rlp-desk/logs/demo"
  print -r -- "{\"execution_steps\": $steps}" > "$root/done-claim.json"
  ROOT_R="$root" STEPS_DC="$root/done-claim.json" LOGS_R="$root/.rlp-desk/logs/demo" \
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="$ROOT_R"; LOGS_DIR="$LOGS_R"; DONE_CLAIM_FILE="$STEPS_DC"
    run_pregate_replay 1 0; rc=$?
    print "RAN=$PREGATE_REPLAY_RAN FAIL=$PREGATE_REPLAY_FAIL RC=$rc CLAIMED=$PREGATE_REPLAY_CLAIMED ACTUAL=$PREGATE_REPLAY_ACTUAL STEP=$PREGATE_REPLAY_STEP"
  '
}

print -r -- "-- AC-R2: eligible steps replay to matching exits (incl verify_red nonzero==nonzero) → proceed"
out=$(replay '[{"step":"verify_green","ac_id":"AC1","command":"sh -c \"exit 0\"","exit_code":0},{"step":"verify_red","ac_id":"AC1","command":"sh -c \"exit 1\"","exit_code":1}]')
[[ "$out" == *"RAN=1 FAIL=0 RC=0"* ]] && ok "all matches (incl verify_red 1==1) → RAN=1 FAIL=0 return 0" \
  || no "AC-R2 wrong (got: $out)"

print -r -- "-- AC-R1: eligible step claims exit 0 but replays to exit≠0 → replay fail"
out=$(replay '[{"step":"verify_green","ac_id":"AC2","command":"sh -c \"exit 3\"","exit_code":0}]')
[[ "$out" == *"FAIL=1 RC=1"* ]] && ok "claimed 0 / actual 3 → FAIL=1 return 1" || no "AC-R1 rc wrong (got: $out)"
[[ "$out" == *"CLAIMED=0 ACTUAL=3"* ]] && ok "replay records claimed-vs-actual (0 vs 3)" || no "AC-R1 claim/actual missing (got: $out)"

print -r -- "-- AC-R1 contract: _pregate_register_fail_replay writes 'replay mismatch' contract with claimed vs actual"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  LOGS_DIR="'"$TMP"'/rc"; mkdir -p "$LOGS_DIR"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=3
  PREGATE_REPLAY_STEP=verify_green; PREGATE_REPLAY_AC=AC2; PREGATE_REPLAY_CMD="npm test"
  PREGATE_REPLAY_CLAIMED=0; PREGATE_REPLAY_ACTUAL=3; PREGATE_REPLAY_OUTPUT="1 failing"
  _pregate_register_fail_replay 5 US-001; print "rc=$?"
  c="$LOGS_DIR/iter-005.fix-contract.md"
  grep -q "PRE-GATE FAILURE (replay mismatch)" "$c" && print LABELED
  grep -q "Claimed exit_code.*: 0" "$c" && grep -q "Actual exit_code.*: 3" "$c" && print CLAIMVSACTUAL
  grep -q "npm test" "$c" && print HASCMD
')
[[ "$out" == *"rc=0"* && "$out" == *"LABELED"* ]] && ok "replay contract labeled PRE-GATE FAILURE (replay mismatch)" || no "replay contract label missing (got: $out)"
[[ "$out" == *"CLAIMVSACTUAL"* && "$out" == *"HASCMD"* ]] && ok "replay contract carries command + claimed vs actual" || no "replay contract fields missing (got: $out)"

print -r -- "-- AC-R3: dangerous/non-allowlisted command is SKIPPED (not executed), no fail"
SENT="$TMP/should_not_exist_$RANDOM"
out=$(replay '[{"step":"verify","ac_id":"AC3","command":"touch '"$SENT"'","exit_code":0}]')
[[ "$out" == *"RAN=0 FAIL=0 RC=0"* ]] && ok "non-allowlisted (touch) → no-op (RAN=0), not a fail" || no "AC-R3 skip wrong (got: $out)"
[[ ! -e "$SENT" ]] && ok "skipped command was NOT executed (sentinel absent)" || no "AC-R3 command executed! sentinel created"

print -r -- "-- AC-R3b: _pregate_cmd_is_safe allowlist begin + denylist"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  _pregate_cmd_is_safe "npm test" && print A_OK
  _pregate_cmd_is_safe "pytest -q" && print B_OK
  _pregate_cmd_is_safe "evilbin --do" || print C_BLOCKED
  _pregate_cmd_is_safe "npm run x && rm -rf foo" || print D_BLOCKED
  _pregate_cmd_is_safe "node s.js > /etc/x" || print E_BLOCKED
')
[[ "$out" == *"A_OK"* && "$out" == *"B_OK"* ]] && ok "allowlisted commands pass the safety gate" || no "allowlist pass wrong (got: $out)"
[[ "$out" == *"C_BLOCKED"* ]] && ok "non-allowlisted command blocked" || no "non-allowlist not blocked (got: $out)"
[[ "$out" == *"D_BLOCKED"* && "$out" == *"E_BLOCKED"* ]] && ok "denylist (rm, redirect-to-root) blocked even when allowlisted-prefixed" || no "denylist not enforced (got: $out)"

print -r -- "-- AC-R4: per-command timeout → replay mismatch (fail path)"
root4="$TMP/r4"; mkdir -p "$root4/.rlp-desk/logs/demo"
print -r -- '{"execution_steps":[{"step":"verify_e2e","ac_id":"AC4","command":"sh -c \"sleep 30\"","exit_code":0}]}' > "$root4/done-claim.json"
out=$(ROOT_R="$root4" DC="$root4/done-claim.json" LOGS_R="$root4/.rlp-desk/logs/demo" RLP_PREGATE_CMD_TIMEOUT=1 zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="$ROOT_R"; LOGS_DIR="$LOGS_R"; DONE_CLAIM_FILE="$DC"
  run_pregate_replay 1 0; print "FAIL=$PREGATE_REPLAY_FAIL RC=$? ACTUAL=$PREGATE_REPLAY_ACTUAL"
')
[[ "$out" == *"FAIL=1"* ]] && ok "per-command timeout → replay FAIL=1" || no "AC-R4 not a fail (got: $out)"
[[ "$out" == *"ACTUAL=timeout"* ]] && ok "timeout recorded as actual for the fix contract" || no "AC-R4 timeout marker missing (got: $out)"

print -r -- "-- replay no-op: absent done-claim + no execution_steps → RAN=0, not a fail"
out=$(replay '[]')
[[ "$out" == *"RAN=0 FAIL=0 RC=0"* ]] && ok "empty execution_steps → no-op (RAN=0)" || no "empty steps not no-op (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- structural: both layers feed one counter; L2 runs after L1 passes"
grep -q "_pregate_bump" "$LIB" && ok "shared _pregate_bump counter/cap helper exists" || no "shared counter helper missing"
awk '/run_pregate "\$ITERATION" "\$SLUG"/{l1=NR} /run_pregate_replay "\$ITERATION"/{if(l1 && NR>l1){print "L2_AFTER_L1"; exit}}' "$RUN" | grep -q L2_AFTER_L1 \
  && ok "layer 2 replay runs after layer 1 in the verify path" || no "layer ordering wrong"
grep -q 'if (( ! _pg_short && ! _pg_force )); then' "$RUN" \
  && ok "layer 2 skipped when layer 1 already short-circuited/forced" || no "L2 guard on L1 resolution missing"

# ---------------------------------------------------------------------------
print -r -- "-- structural: call site runs pre-gate before write_verifier_trigger + continues on short-circuit"
# run_pregate must be invoked in the verify path before the verifier is dispatched.
awk '/run_pregate "\$ITERATION" "\$SLUG"/{pg=NR} /write_verifier_trigger "\$ITERATION"/{if(pg && NR>pg){print "ORDER_OK"; exit}}' "$RUN" | grep -q ORDER_OK \
  && ok "run_pregate is invoked before write_verifier_trigger in verify path" \
  || no "pre-gate not ordered before verifier dispatch"
grep -q 'update_status "verifier" "pregate_fail"' "$RUN" \
  && grep -A1 'update_status "verifier" "pregate_fail"' "$RUN" | grep -q "continue" \
  && ok "short-circuit path sets pregate_fail status then continues (redispatch, no verifier)" \
  || no "short-circuit continue path missing"

# ---------------------------------------------------------------------------
print -r -- "-- structural: pre-gate NEVER touches the consecutive-failure CB"
grep -q "NEVER touches the consecutive-failure" "$LIB" \
  && ok "pre-gate helper documents CB separation" || no "CB separation note missing"
grep -q "early-FAIL only" "$GOV" && ok "governance documents early-FAIL-only Iron Law compat" \
  || no "governance pre-gate note missing"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
