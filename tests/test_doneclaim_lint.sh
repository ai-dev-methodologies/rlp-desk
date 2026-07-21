#!/usr/bin/env zsh
# Layer 1.5 — done-claim TDD-sequence lint (zsh predicate) behavioral + parity tests.
#
# Sources the REAL lib functions (run_pregate_doneclaim_lint,
# _pregate_register_fail_doneclaim_lint) and drives them over the SAME shared
# fixtures the Node test-done-claim-lint uses (tests/fixtures/done-claim-lint/),
# asserting IDENTICAL violations JSON (jq↔Node parity). Plus: fix-contract file
# written with per-AC coordinates on fail, jq-missing skip (jq-less PATH), and
# RLP_DONECLAIM_LINT=0 disabled skip.
set -uo pipefail
unset TMUX
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
FIXTURES="$REPO/tests/fixtures/done-claim-lint"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Driver: source lib in a clean zsh, point DONE_CLAIM_FILE at $1, run the lint,
# print status/reason/rc + violations. Extra env (RLP_DONECLAIM_LINT, jq-less
# PATH override for the no-jq fail-open case) passed via caller exports.
lint() { # $1 = done-claim fixture path ; env: DC_ENV extras
  local dc="$1"
  DC_LINT="$dc" LOGS_L="$TMP/logs-$RANDOM" zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    mkdir -p "$LOGS_L"; LOGS_DIR="$LOGS_L"; DONE_CLAIM_FILE="$DC_LINT"
    '"${DC_PRE:-}"'
    run_pregate_doneclaim_lint; rc=$?
    print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$rc"
    print "VIOL=$PREGATE_LINT_VIOLATIONS"
  '
}

# ---------------------------------------------------------------------------
# Parity: every build/pass fixture must produce the EXACT expected violations
# JSON and status; skip fixtures must produce the expected skip reason.
print -r -- "-- parity: fixtures produce Node-identical status/violations"
for dc in "$FIXTURES"/*.json; do
  [[ "$dc" == *.expected.json ]] && continue
  name="${dc:t:r}"
  exp="$FIXTURES/$name.expected.json"
  [[ -f "$exp" ]] || { no "$name: missing expected file"; continue; }
  exp_status=$(jq -r '.status' "$exp")
  out=$(lint "$dc")
  got_status=$(print -r -- "$out" | sed -n 's/^STATUS=\([a-z]*\).*/\1/p')
  if [[ "$got_status" != "$exp_status" ]]; then
    no "$name: status $got_status != $exp_status (out: $out)"; continue
  fi
  if [[ "$exp_status" == "skip" ]]; then
    exp_reason=$(jq -r '.reason' "$exp")
    got_reason=$(print -r -- "$out" | sed -n 's/^STATUS=[a-z]* REASON=\([a-z-]*\).*/\1/p')
    [[ "$got_reason" == "$exp_reason" ]] \
      && ok "$name: skip ($got_reason)" \
      || no "$name: reason $got_reason != $exp_reason (out: $out)"
  else
    got_viol=$(print -r -- "$out" | sed -n 's/^VIOL=//p')
    exp_viol=$(jq -c '.violations' "$exp")
    # normalize both through jq -c for a stable compare
    if [[ "$(print -r -- "$got_viol" | jq -cS . 2>/dev/null)" == "$(print -r -- "$exp_viol" | jq -cS .)" ]]; then
      ok "$name: $got_status, violations parity"
    else
      no "$name: violations $got_viol != $exp_viol"
    fi
  fi
done

# ---------------------------------------------------------------------------
print -r -- "-- fail fixture writes a coordinate-bearing fix contract, shares PREGATE_FAIL_CAP"
out=$(DC_LINT="$FIXTURES/fail-us002-repro.json" LOGS_L="$TMP/fc" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  mkdir -p "$LOGS_L"; LOGS_DIR="$LOGS_L"; DONE_CLAIM_FILE="$DC_LINT"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=3
  run_pregate_doneclaim_lint; print "STATUS=$PREGATE_LINT_STATUS"
  _pregate_register_fail_doneclaim_lint 2 US-002; print "RC=$? FAILS=$PREGATE_FAILURES"
  c="$LOGS_DIR/iter-002.fix-contract.md"
  [[ -f "$c" ]] && { print HASCONTRACT
    grep -q "PRE-GATE FAILURE (done-claim format lint)" "$c" && print LABELED
    grep -q "AC3: idx=\[4,5,-1,6\]" "$c" && print HASCOORD
    grep -q "Do not re-implement the deliverable" "$c" && print HASNEXT
  } || print NOCONTRACT
')
[[ "$out" == *"STATUS=fail"* ]] && ok "fail-us002-repro lints as fail" || no "expected fail status (got: $out)"
[[ "$out" == *"RC=0 FAILS=1"* ]] && ok "register-fail: 1st fail short-circuits (rc0), shared counter=1" || no "register-fail counter wrong (got: $out)"
[[ "$out" == *"HASCONTRACT"* && "$out" == *"LABELED"* ]] && ok "fix contract written + labeled done-claim format lint" || no "fix contract missing/unlabeled (got: $out)"
[[ "$out" == *"HASCOORD"* ]] && ok "fix contract carries per-AC idx coordinates (AC3 idx=[4,5,-1,6])" || no "coordinates missing (got: $out)"
[[ "$out" == *"HASNEXT"* ]] && ok "fix contract carries the format-only Next Iteration Contract" || no "next-contract missing (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- register-fail: 3rd same-US fail forces verifier (shared cap, never CB)"
out=$(LOGS_L="$TMP/cap" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  mkdir -p "$LOGS_L"; LOGS_DIR="$LOGS_L"; PREGATE_LINT_VIOLATIONS="[{\"ac\":\"AC1\",\"idx\":[-1,-1,-1,-1]}]"
  PREGATE_FAILURES=0; _PREGATE_FAIL_US=""; PREGATE_FAIL_CAP=3
  _pregate_register_fail_doneclaim_lint 1 US-002; r1=$?
  _pregate_register_fail_doneclaim_lint 2 US-002; r2=$?
  _pregate_register_fail_doneclaim_lint 3 US-002; r3=$?
  print "r1=$r1 r2=$r2 r3=$r3 FAILS=$PREGATE_FAILURES"
')
[[ "$out" == *"r1=0 r2=0 r3=1 "* ]] && ok "cap: 1,2 short-circuit; 3rd forces verifier (return 1)" || no "cap behavior wrong (got: $out)"
[[ "$out" == *"FAILS=0"* ]] && ok "counter reset to 0 on forced verifier round" || no "counter should reset (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- RLP_DONECLAIM_LINT=0 → skip disabled (even for a would-fail claim)"
DC_PRE='RLP_DONECLAIM_LINT=0' out=$(lint "$FIXTURES/fail-us002-repro.json")
[[ "$out" == *"STATUS=skip REASON=disabled"* ]] && ok "opt-out skips with reason=disabled" || no "opt-out skip wrong (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- jq missing → skip no-jq (fail-open, PATH stub)"
STUB="$TMP/stubbin"; mkdir -p "$STUB"
for t in date mkdir rm cat tail head grep sed awk stat env dirname basename mktemp chmod mv; do
  p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$STUB/$t"
done
out=$(DC_LINT="$FIXTURES/fail-us002-repro.json" LOGS_L="$TMP/nojq" STUB="$STUB" zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  mkdir -p "$LOGS_L"; LOGS_DIR="$LOGS_L"; DONE_CLAIM_FILE="$DC_LINT"
  PATH="$STUB"
  run_pregate_doneclaim_lint; print "STATUS=$PREGATE_LINT_STATUS REASON=$PREGATE_LINT_REASON RC=$?"
')
[[ "$out" == *"STATUS=skip REASON=no-jq"* ]] && ok "jq missing → skip no-jq (fail-open)" || no "no-jq skip wrong (got: $out)"

# ---------------------------------------------------------------------------
print -r -- "-- structural: Node & zsh predicates + call sites are wired"
grep -q "run_pregate_doneclaim_lint" "$REPO/src/scripts/run_ralph_desk.zsh" \
  && ok "run_ralph_desk.zsh invokes the Layer 1.5 lint" || no "call site missing lint invocation"
awk '/run_pregate "\$ITERATION" "\$SLUG"/{l1=NR} /run_pregate_doneclaim_lint/{if(l1 && NR>l1){print "AFTER_L1";exit}}' \
  "$REPO/src/scripts/run_ralph_desk.zsh" | grep -q AFTER_L1 \
  && ok "Layer 1.5 runs after Layer 1 static gate" || no "L1.5 ordering wrong"
awk '/run_pregate_doneclaim_lint/{l15=NR} /run_pregate_replay "\$ITERATION"/{if(l15 && NR>l15){print "BEFORE_L2";exit}}' \
  "$REPO/src/scripts/run_ralph_desk.zsh" | grep -q BEFORE_L2 \
  && ok "Layer 1.5 runs before Layer 2 replay" || no "L1.5/L2 ordering wrong"
grep -q '_DONECLAIM_LINT_LINE' "$REPO/src/scripts/run_ralph_desk.zsh" \
  && ok "lint outcome line is injected into the verifier prompt" || no "prompt injection missing"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
