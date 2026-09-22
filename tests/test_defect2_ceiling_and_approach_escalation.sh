#!/bin/zsh
# Test suite: DEFECT-2 — the ceiling model never gets a turn (2a), and
# repeated failure escalates price but never approach (2b).
#
# Root cause (found by adversarial probe, confirmed by reading + tracing the
# code): check_model_upgrade() upgrades the Worker model on the 2nd
# consecutive same-US failure. With the default CB_THRESHOLD=6 and the
# 4-rung claude ladder (haiku -> sonnet -> opus -> claude-fable-5-1:max),
# the arithmetic lands the opus->fable upgrade on EXACTLY the same failure
# (#6) that trips the circuit breaker — so the ceiling model is assigned to
# WORKER_MODEL but never actually dispatched, while the old BLOCKED text
# read "Worker upgraded to ceiling model" as if it had run and failed there.
#
# Fix (2a): the circuit-breaker check now defers blocking while the current
# (possibly just-upgraded) model has not yet had its own 2-attempt window
# (_SAME_US_FAIL_COUNT < 2), so the ceiling model is guaranteed at least one
# real dispatch before BLOCKED can fire on it.
#
# Fix (2b): write_worker_trigger now injects an explicit "APPROACH ESCALATION
# REQUIRED" section (with the capped, newest-first attempt history recorded
# by _record_us_attempt) whenever the in-flight US is running on an upgraded
# model, requiring the next Worker to name a materially different strategy.
#
# This test EXECUTES the real extracted production functions/blocks
# (check_model_upgrade, get_next_model, the circuit-breaker block, and
# _record_us_attempt / write_worker_trigger) — never retypes their logic.

set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL: $1"; }

echo "=== DEFECT-2: ceiling model must get a turn; escalation must change approach ==="

# --- Extraction helpers (real production code, never retyped) -------------
extract_cb_block() { # $1 = run_src
  # Stops at the exact 12-space-indented "update_status \"verifier\" \"fail\""
  # line that follows the WHOLE if-block (both the fixed and a pre-fix/
  # reverted shape reach that same line next) — deliberately NOT a bare
  # /update_status "verifier" "fail"/ match, since the fixed shape's deferred
  # branch also calls that at 16-space indent, which would truncate the
  # extraction mid-block.
  awk '
    /# Circuit breaker: consecutive failures/ { f=1 }
    f && $0 == "            update_status \"verifier\" \"fail\"" { exit }
    f { print }
  ' "$1"
}
extract_fn() { # $1 = fn_name  $2 = src
  awk -v fn="$1() {" 'index($0, fn) == 1 { f=1 } f { print; if ($0 == "}") exit }' "$2"
}

CB_TEXT="$(extract_cb_block "$RUN")"
[[ -n "$CB_TEXT" ]] && echo "$CB_TEXT" | grep -q "write_blocked_sentinel" \
  && ok "extraction sanity: circuit-breaker block found in real source" \
  || { no "extraction sanity: circuit-breaker block NOT found — test cannot proceed"; exit 1; }
CMU_TEXT="$(extract_fn check_model_upgrade "$LIB")"
[[ -n "$CMU_TEXT" ]] && ok "extraction sanity: check_model_upgrade() found in real source" \
  || { no "extraction sanity: check_model_upgrade() NOT found — test cannot proceed"; exit 1; }
GNM_TEXT="$(extract_fn get_next_model "$LIB")"
[[ -n "$GNM_TEXT" ]] && ok "extraction sanity: get_next_model() found in real source" \
  || { no "extraction sanity: get_next_model() NOT found — test cannot proceed"; exit 1; }
GMS_TEXT="$(extract_fn get_model_string "$LIB")"
[[ -n "$GMS_TEXT" ]] && ok "extraction sanity: get_model_string() found in real source" \
  || { no "extraction sanity: get_model_string() NOT found — test cannot proceed"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Simulates N consecutive same-US verifier failures against the REAL
# check_model_upgrade + circuit-breaker block, using the REAL shipped model
# ladder (models.json, resolved via LIB_DIR — same hermeticity guard pattern
# used by tests/test_us011_worker_model_upgrade.sh's extract_fn). Prints one
# line per failure: "<n> model=<model> blocked=<0|1>".
run_cb_simulation() { # $1 = run_src  $2 = num_failures  $3 = cb_threshold
  local run_src="$1" n="$2" cbt="${3:-6}"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    write_blocked_sentinel() { :; }
    update_status() { :; }
    LIB_DIR='$ROOT_DIR/src/scripts'
    RLP_DESK_MODELS_FILE=\"\${RLP_DESK_MODELS_FILE:-/nonexistent-hermetic-test-guard/rlp-desk-models.json}\"
    $GNM_TEXT
    $GMS_TEXT
    $CMU_TEXT
    # Wrapped in a function so the block's own \`return 1\` (a real BLOCKED
    # exit inside main()) returns from THIS call instead of terminating the
    # whole -c script — the block runs at top level here, and a bare
    # \`return\` outside a function aborts a zsh -c script entirely.
    _run_cb() {
      $CB_TEXT
    }
    WORKER_ENGINE='claude'
    WORKER_CODEX_MODEL=''
    WORKER_CODEX_REASONING=''
    WORKER_MODEL='haiku'
    WORKER_EFFORT=''
    LOCK_WORKER_MODEL=0
    _MODEL_UPGRADED=0
    _SAME_US_FAIL_COUNT=0
    _LAST_FAILED_US=''
    _ORIGINAL_WORKER_MODEL=''
    _ORIGINAL_WORKER_CODEX_REASONING=''
    _ORIGINAL_WORKER_EFFORT=''
    CONSECUTIVE_FAILURES=0
    CB_THRESHOLD=$cbt
    EFFECTIVE_CB_THRESHOLD=$cbt
    ITERATION=0
    for (( i=1; i<=$n; i++ )); do
      ITERATION=\$i
      (( CONSECUTIVE_FAILURES++ ))
      check_model_upgrade 'US-001'
      _cmu_deferred=0
      _run_cb
      _blocked=\$(( \$? == 1 ? 1 : 0 ))
      echo \"\$i model=\$WORKER_MODEL blocked=\$_blocked same_us_fail_count=\$_SAME_US_FAIL_COUNT\"
      (( _blocked )) && break
    done
  "
}

# --- A: with the fix, the ceiling model (claude-fable-5-1) gets a real turn ---
echo "--- A: circuit breaker defers until the ceiling model has its own attempt window ---"
SIM_A="$(run_cb_simulation "$RUN" 8 6)"
echo "$SIM_A" | sed 's/^/    /'

BLOCKED_LINE=$(echo "$SIM_A" | grep 'blocked=1' | head -1)
BLOCKED_AT_N=$(echo "$BLOCKED_LINE" | awk '{print $1}')
BLOCKED_MODEL=$(echo "$BLOCKED_LINE" | sed -n 's/.*model=\([^ ]*\).*/\1/p')

[[ "$BLOCKED_AT_N" == "8" ]] \
  && ok "A1: circuit breaker fires at failure #8, not #6 (ceiling got fails #7 and #8 as its own window)" \
  || no "A1: circuit breaker fired at the wrong failure count (got '$BLOCKED_AT_N', expected 8) — full sim:\n$SIM_A"

[[ "$BLOCKED_MODEL" == "claude-fable-5-1" ]] \
  && ok "A2: the model BLOCKED fires on is the ceiling model that actually ran (claude-fable-5-1)" \
  || no "A2: BLOCKED fired on wrong/no model (got '$BLOCKED_MODEL')"

MODEL_AT_6=$(echo "$SIM_A" | awk '$1==6{print}' | sed -n 's/.*model=\([^ ]*\).*/\1/p')
BLOCKED_AT_6=$(echo "$SIM_A" | awk '$1==6{print}' | sed -n 's/.*blocked=\([^ ]*\).*/\1/p')
[[ "$MODEL_AT_6" == "claude-fable-5-1" && "$BLOCKED_AT_6" == "0" ]] \
  && ok "A3: failure #6 upgrades to the ceiling but does NOT block yet (deferred — ceiling not dispatched yet)" \
  || no "A3: expected model=claude-fable-5-1 blocked=0 at failure #6, got model=$MODEL_AT_6 blocked=$BLOCKED_AT_6"

MODEL_AT_7=$(echo "$SIM_A" | awk '$1==7{print}' | sed -n 's/.*model=\([^ ]*\).*/\1/p')
BLOCKED_AT_7=$(echo "$SIM_A" | awk '$1==7{print}' | sed -n 's/.*blocked=\([^ ]*\).*/\1/p')
[[ "$MODEL_AT_7" == "claude-fable-5-1" && "$BLOCKED_AT_7" == "0" ]] \
  && ok "A4: failure #7 is the ceiling model's OWN first attempt, still not blocked" \
  || no "A4: expected model=claude-fable-5-1 blocked=0 at failure #7, got model=$MODEL_AT_7 blocked=$BLOCKED_AT_7"

# --- B: a campaign that never reaches the ceiling is unaffected -----------
echo "--- B: no interaction when the ladder isn't exhausted at the CB boundary ---"
SIM_B="$(run_cb_simulation "$RUN" 3 10)"
BLOCKED_B=$(echo "$SIM_B" | grep -c 'blocked=1')
(( BLOCKED_B == 0 )) \
  && ok "B1: CB_THRESHOLD=10 with only 3 failures never blocks (regression check)" \
  || no "B1: unexpectedly blocked with CB_THRESHOLD=10 and only 3 failures"

# --- C: mutation control — revert 2a on a scratch copy, prove Scenario A goes RED ---
echo "--- C: mutation control (2a defect re-injected must fail A1/A3) ---"
MUT_RUN="$TMP/run_mutated.zsh"
cp "$RUN" "$MUT_RUN"
python3 - "$MUT_RUN" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '''            if (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )); then
              # For codex: use full model:reasoning string (WORKER_MODEL loses reasoning suffix after upgrade)
              _ceiling_model_str="$([[ "$WORKER_ENGINE" = "codex" ]] && echo "${WORKER_CODEX_MODEL}:${WORKER_CODEX_REASONING}" || echo "$WORKER_MODEL")"
'''
assert old in text, "anchor not found"
# Find the span from that anchor through the matching outer 'fi' we emit today,
# and replace with the ORIGINAL (pre-DEFECT-2a) 3-branch block.
start = text.index(old)
end_marker = "              unset _cmu_deferred\n            fi\n"
end = text.index(end_marker, start) + len(end_marker)
replacement = '''            if (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )); then
              # For codex: use full model:reasoning string (WORKER_MODEL loses reasoning suffix after upgrade)
              _ceiling_model_str="$([[ "$WORKER_ENGINE" = "codex" ]] && echo "${WORKER_CODEX_MODEL}:${WORKER_CODEX_REASONING}" || echo "$WORKER_MODEL")"
              if (( _MODEL_UPGRADED )) && [[ -z "$(get_next_model "$_ceiling_model_str")" ]]; then
                log_debug "[GOV] iter=$ITERATION circuit_breaker=consecutive_failures detail=\\"architecture escalation: Worker at ceiling (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive failures\\""
                log_error "Circuit breaker: architecture escalation — Worker upgraded to ceiling (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive failures"
                write_blocked_sentinel "architecture escalation: Worker upgraded to ceiling model (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures" "" "repeat_axis"
              else
                log_debug "[GOV] iter=$ITERATION circuit_breaker=consecutive_failures detail=\\"${EFFECTIVE_CB_THRESHOLD} consecutive verification failures\\""
                log_error "Circuit breaker: ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures"
                write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive verification failures" "" "repeat_axis"
              fi
              update_status "blocked" "consecutive_failures"
              return 1
            fi
'''
new_text = text[:start] + replacement + text[end:]
assert new_text != text
with open(path, "w") as f:
    f.write(new_text)
PYEOF
if [[ $? -ne 0 ]]; then
  no "C0: mutation setup failed (could not revert 2a on the scratch copy)"
else
  ok "C0: mutation setup reverted the DEFECT-2a fix on a scratch copy"
  MUT_CB_TEXT="$(extract_cb_block "$MUT_RUN")"
  SIM_C="$(zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    write_blocked_sentinel() { :; }
    update_status() { :; }
    LIB_DIR='$ROOT_DIR/src/scripts'
    RLP_DESK_MODELS_FILE=\"\${RLP_DESK_MODELS_FILE:-/nonexistent-hermetic-test-guard/rlp-desk-models.json}\"
    $GNM_TEXT
    $GMS_TEXT
    $CMU_TEXT
    # Same wrapper reasoning as run_cb_simulation() above: the block's own
    # \`return 1\` must return from a function, not abort this -c script.
    _run_cb() {
      $MUT_CB_TEXT
    }
    WORKER_ENGINE='claude'; WORKER_MODEL='haiku'; WORKER_EFFORT=''; WORKER_CODEX_MODEL=''; WORKER_CODEX_REASONING=''
    LOCK_WORKER_MODEL=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=''
    _ORIGINAL_WORKER_MODEL=''; _ORIGINAL_WORKER_CODEX_REASONING=''; _ORIGINAL_WORKER_EFFORT=''
    CONSECUTIVE_FAILURES=0; CB_THRESHOLD=6; EFFECTIVE_CB_THRESHOLD=6; ITERATION=0
    for (( i=1; i<=8; i++ )); do
      ITERATION=\$i
      (( CONSECUTIVE_FAILURES++ ))
      check_model_upgrade 'US-001'
      _run_cb
      _blocked=\$(( \$? == 1 ? 1 : 0 ))
      echo \"\$i model=\$WORKER_MODEL blocked=\$_blocked\"
      (( _blocked )) && break
    done
  ")"
  MUT_BLOCKED_AT=$(echo "$SIM_C" | grep 'blocked=1' | head -1 | awk '{print $1}')
  if [[ "$MUT_BLOCKED_AT" == "6" ]]; then
    ok "C1: mutation control effective — with 2a reverted, BLOCKED fires at #6 before the ceiling ever ran (proves A1/A3 test the real fix)"
  else
    no "C1: mutation control INEFFECTIVE — reverted code still blocked at '$MUT_BLOCKED_AT', expected 6 — sim:\n$SIM_C"
  fi
fi

# --- D: _record_us_attempt caps at 3, newest first -------------------------
echo "--- D: _record_us_attempt caps history at 3 entries, newest first ---"
RECORD_TEXT="$(extract_fn _record_us_attempt "$LIB")"
[[ -n "$RECORD_TEXT" ]] && ok "extraction sanity: _record_us_attempt() found in real source" \
  || { no "extraction sanity: _record_us_attempt() NOT found — D cannot proceed"; RECORD_TEXT=""; }

if [[ -n "$RECORD_TEXT" ]]; then
  HIST=$(zsh -c "
    typeset -A US_ATTEMPT_HISTORY
    ATTEMPT_HISTORY_CAP=3
    $RECORD_TEXT
    ITERATION=1; _record_us_attempt 'US-001' 'haiku' 'first failure reason'
    ITERATION=2; _record_us_attempt 'US-001' 'haiku' 'second failure reason'
    ITERATION=3; _record_us_attempt 'US-001' 'sonnet' 'third failure reason'
    ITERATION=4; _record_us_attempt 'US-001' 'sonnet' 'fourth failure reason'
    print -r -- \"\${US_ATTEMPT_HISTORY[US-001]}\"
  ")
  LINE_COUNT=$(print -r -- "$HIST" | wc -l | tr -d ' ')
  [[ "$LINE_COUNT" == "3" ]] \
    && ok "D1: history capped at 3 entries (ATTEMPT_HISTORY_CAP)" \
    || no "D1: expected 3 lines, got $LINE_COUNT — history:\n$HIST"
  print -r -- "$HIST" | head -1 | grep -q "fourth failure reason" \
    && ok "D2: newest entry (iter 4) is first (newest-first ordering)" \
    || no "D2: newest entry not first — history:\n$HIST"
  print -r -- "$HIST" | grep -q "first failure reason" \
    && no "D3: oldest entry (iter 1) should have been evicted by the cap but is still present" \
    || ok "D3: oldest entry (iter 1) correctly evicted by the cap"
fi

# --- E: write_worker_trigger injects the escalation section only when both
#        an upgrade is active AND this US has attempt history -------------
echo "--- E: APPROACH ESCALATION section gating ---"
WWT_TEXT="$(extract_fn write_worker_trigger "$RUN")"
IPU_TEXT="$(extract_fn inject_per_us_prd "$RUN")"
AW_TEXT="$(extract_fn atomic_write "$LIB")"

mkfixture() {
  local d="$1"
  mkdir -p "$d/logs" "$d/plans"
  cat > "$d/memory.md" <<'EOF'
## Stop Status
running

## Next Iteration Contract
Implement US-001.
EOF
  cat > "$d/worker-prompt-base.md" <<'EOF'
# Worker Prompt Base
Read the PRD at __PRD__ and implement it.
EOF
  sed -i '' "s|__PRD__|$d/plans/prd-testslug.md|" "$d/worker-prompt-base.md" 2>/dev/null \
    || sed -i "s|__PRD__|$d/plans/prd-testslug.md|" "$d/worker-prompt-base.md"
  echo "PRD placeholder" > "$d/plans/prd-testslug.md"
}

run_dispatch_e() { # $1=dir $2=model_upgraded(0|1) $3=history("" or text)
  local d="$1" upgraded="$2" hist="$3"
  mkfixture "$d"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }
    build_claude_cmd() { echo 'stub-claude-cmd'; }
    _emit_waiver_contract() { :; }
    _bug8_carryover_file() { echo '/nonexistent/bug8.md'; }
    typeset -A US_FIX_CONTRACT
    typeset -A US_ATTEMPT_HISTORY
    LOGS_DIR='$d/logs'
    MEMORY_FILE='$d/memory.md'
    WORKER_PROMPT_BASE='$d/worker-prompt-base.md'
    DESK='$d'
    SLUG='testslug'
    _PRD_CHANGED=0
    AUTONOMOUS_MODE=0
    WORKER_ENGINE='claude'
    WORKER_CODEX_MODEL=''
    WORKER_CODEX_REASONING=''
    WORKER_MODEL='claude-fable-5-1'
    WORKER_EFFORT='max'
    WORKER_HEARTBEAT='$d/heartbeat.json'
    SIGNAL_FILE='$d/iter-signal.json'
    VERIFY_MODE='per-us'
    US_LIST='US-001'
    VERIFIED_US=''
    _MODEL_UPGRADED=$upgraded
    US_ATTEMPT_HISTORY[US-001]='$hist'
    $AW_TEXT
    $IPU_TEXT
    $WWT_TEXT
    write_worker_trigger 5
  " 2>"$d/stderr.log"
}

DE1="$TMP/e1"
run_dispatch_e "$DE1" 1 $'iter 4 (opus): AC1 null check missing\niter 3 (opus): AC1 wrong return type'
if grep -q "APPROACH ESCALATION REQUIRED" "$DE1/logs/iter-005.worker-prompt.md" \
   && grep -q "AC1 null check missing" "$DE1/logs/iter-005.worker-prompt.md"; then
  ok "E1: escalation section present + lists prior attempts when upgraded=1 and history exists"
else
  no "E1: escalation section missing or history not injected (upgraded=1, history present) — stderr: $(cat "$DE1/stderr.log")"
fi

DE2="$TMP/e2"
run_dispatch_e "$DE2" 0 $'iter 4 (opus): AC1 null check missing'
if grep -q "APPROACH ESCALATION REQUIRED" "$DE2/logs/iter-005.worker-prompt.md"; then
  no "E2: escalation section injected even though _MODEL_UPGRADED=0 (should not fire)"
else
  ok "E2: no escalation section when _MODEL_UPGRADED=0, even with history present"
fi

DE3="$TMP/e3"
run_dispatch_e "$DE3" 1 ""
if grep -q "APPROACH ESCALATION REQUIRED" "$DE3/logs/iter-005.worker-prompt.md"; then
  no "E3: escalation section injected even with no attempt history (nothing to warn about)"
else
  ok "E3: no escalation section when upgraded=1 but no attempt history recorded yet"
fi

# --- F: attempt-history artifact persisted only when escalation is active,
#        content matches the Worker prompt, and the Verifier prompt carries a
#        resolvable path to it (DEFECT-2b enforcement plumbing) -------------
echo "--- F: attempt-history artifact + Verifier prompt path exposure ---"

AHF_DE1="$DE1/logs/iter-005.attempt-history.md"
if [[ -f "$AHF_DE1" ]]; then
  ok "F1: attempt-history artifact written when escalation is active (upgraded=1, history present)"
else
  no "F1: attempt-history artifact NOT written when escalation is active"
fi

if [[ -f "$AHF_DE1" ]] \
   && grep -q "AC1 null check missing" "$AHF_DE1" \
   && grep -q "AC1 wrong return type" "$AHF_DE1"; then
  ok "F2: artifact content includes the same prior-attempt lines rendered in the Worker prompt"
else
  no "F2: artifact content does not match the Worker prompt's rendered attempts"
fi

AHF_DE2="$DE2/logs/iter-005.attempt-history.md"
if [[ -f "$AHF_DE2" ]]; then
  no "F3: attempt-history artifact written on an ORDINARY failure (upgraded=0) — must only write when escalation is active"
else
  ok "F3: no attempt-history artifact written when _MODEL_UPGRADED=0 (not every failure creates one)"
fi

AHF_DE3="$DE3/logs/iter-005.attempt-history.md"
if [[ -f "$AHF_DE3" ]]; then
  no "F4: attempt-history artifact written with upgraded=1 but empty history (nothing to persist)"
else
  ok "F4: no attempt-history artifact written when upgraded=1 but no history recorded yet"
fi

WVT_TEXT="$(extract_fn write_verifier_trigger "$RUN")"
[[ -n "$WVT_TEXT" ]] && ok "extraction sanity: write_verifier_trigger() found in real source" \
  || { no "extraction sanity: write_verifier_trigger() NOT found — F5/F6 cannot proceed"; WVT_TEXT=""; }

run_dispatch_verifier() { # $1=dir (already ran run_dispatch_e against it)
  local d="$1"
  cat > "$d/verifier-prompt-base.md" <<'EOF'
# Verifier Prompt Base
Check the work.
EOF
  echo '{"us_id":"US-001"}' > "$d/iter-signal.json"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }
    build_claude_cmd() { echo 'stub-claude-cmd'; }
    _emit_waiver_contract() { :; }
    derive_verification_mode() { echo 'build|stub'; }
    LOGS_DIR='$d/logs'
    SIGNAL_FILE='$d/iter-signal.json'
    VERIFIER_PROMPT_BASE='$d/verifier-prompt-base.md'
    DONE_CLAIM_FILE='$d/done-claim.json'
    VERIFIED_LEDGER='$d/ledger.jsonl'
    PRD_FILE='$d/plans/prd-testslug.md'
    ROOT='$d'
    VERIFY_MODE='per-us'
    VERIFIED_US=''
    AUTONOMOUS_MODE=0
    VERIFIER_EFFORT=''
    VERIFIER_HEARTBEAT='$d/verifier-heartbeat.json'
    $AW_TEXT
    $WVT_TEXT
    write_verifier_trigger 5 claude sonnet
  " 2>"$d/verifier-stderr.log"
}

run_dispatch_verifier "$DE1"
VPROMPT_DE1="$DE1/logs/iter-005.verifier-prompt.md"
if [[ -f "$VPROMPT_DE1" ]] && grep -q "\*\*Attempt History\*\*: $AHF_DE1" "$VPROMPT_DE1"; then
  ok "F5: Verifier prompt carries a resolvable Attempt History path when the artifact exists"
else
  no "F5: Verifier prompt missing/wrong Attempt History path — stderr: $(cat "$DE1/verifier-stderr.log" 2>/dev/null)"
fi
if [[ -f "$AHF_DE1" ]]; then
  ARTIFACT_BULLETS="$(grep '^- iter ' "$AHF_DE1")"
  PROMPT_BULLETS="$(grep '^- iter ' "$DE1/logs/iter-005.worker-prompt.md")"
  [[ -n "$ARTIFACT_BULLETS" && "$ARTIFACT_BULLETS" == "$PROMPT_BULLETS" ]] \
    && ok "F6: artifact's attempt-line bullets are identical to the Worker prompt's rendered bullets" \
    || no "F6: artifact bullets diverge from the Worker prompt's — artifact:\n$ARTIFACT_BULLETS\nprompt:\n$PROMPT_BULLETS"
else
  no "F6: cannot compare — artifact missing"
fi

run_dispatch_verifier "$DE2"
VPROMPT_DE2="$DE2/logs/iter-005.verifier-prompt.md"
if [[ -f "$VPROMPT_DE2" ]] && ! grep -q "Attempt History" "$VPROMPT_DE2"; then
  ok "F7: Verifier prompt carries NO Attempt History line when no artifact exists for this iteration"
else
  no "F7: Verifier prompt unexpectedly references Attempt History with no artifact present"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
