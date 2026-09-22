#!/bin/zsh
# SV-gate findings (2026-09-14) against the fix/reaudit-wave-1 work already
# on this branch — three items, all in run_ralph_desk.zsh/lib_ralph_desk.zsh:
#
#   1. CRITICAL fail-open: write_worker_trigger's attempt-history persist
#      write (DEFECT-2b enforcement) was unchecked. If it failed, the Worker
#      prompt still said "APPROACH ESCALATION REQUIRED" but
#      run_pregate_doneclaim_lint had no artifact to check against and
#      silently skipped the approach_summary requirement.
#   2. Malformed criteria_results (present, not an array) rode through
#      exactly like absent — no override, crediting a US on unverifiable
#      evidence. Absent must stay permissive; malformed must not.
#   3. _consensus_finalize hand-built VERDICT_FILE in both branches and never
#      carried criteria_results through, so the whole load-bearing-criteria
#      control was inert under CONSENSUS_MODE=all|final-only.
#
# Each section extracts and exercises the REAL production code (never
# retypes it) and carries a mutation control reproducing the pre-fix
# behavior on a scratch copy.

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

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; chmod -R u+w "$TMP" 2>/dev/null' EXIT

extract_fn() { # $1 = fn_name  $2 = src
  awk -v fn="$1() {" 'index($0, fn) == 1 { f=1 } f { print; if ($0 == "}") exit }' "$2"
}

echo "=== SV-gate findings: fail-open close, malformed criteria_results, consensus merge ==="

# ===========================================================================
# ITEM 1 — attempt-history persist write must fail closed
# ===========================================================================
echo "--- Item 1: attempt-history persist write fails closed (not open) ---"

# Sanity: confirm chmod 555 actually blocks writes on THIS filesystem before
# relying on it as the failure-injection mechanism (do not assume).
CHMOD_PROBE="$TMP/chmod-probe"; mkdir -p "$CHMOD_PROBE"
chmod 555 "$CHMOD_PROBE"
if (echo x > "$CHMOD_PROBE/f" 2>/dev/null); then
  no "sanity: chmod 555 does NOT block writes on this filesystem — Item 1 tests would be meaningless"
  chmod 755 "$CHMOD_PROBE"
  ITEM1_FS_OK=0
else
  ok "sanity: chmod 555 confirmed to block writes on this filesystem (permission denied)"
  ITEM1_FS_OK=1
fi

WWT_TEXT="$(extract_fn write_worker_trigger "$RUN")"
IPU_TEXT="$(extract_fn inject_per_us_prd "$RUN")"
AW_TEXT="$(extract_fn atomic_write "$LIB")"
[[ -n "$WWT_TEXT" ]] && ok "extraction sanity: write_worker_trigger() found in real source" \
  || { no "extraction sanity: write_worker_trigger() NOT found — Item 1 cannot proceed"; ITEM1_FS_OK=0; }

mkfixture1() {
  local d="$1"
  mkdir -p "$d/plans"
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

run_dispatch_1() { # $1=dir  $2=logs_dir (may be read-only)
  local d="$1" logs="$2"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { print -r -- \"LOG_ERROR: \$*\" >> '$d/log-error.txt'; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }
    build_claude_cmd() { echo 'stub-claude-cmd'; }
    _emit_waiver_contract() { :; }
    _bug8_carryover_file() { echo '/nonexistent/bug8.md'; }
    write_blocked_sentinel() { print -r -- \"BLOCKED reason=\$1 us=\$2 category=\$3\" >> '$d/blocked-calls.txt'; }
    typeset -A US_FIX_CONTRACT
    typeset -A US_ATTEMPT_HISTORY
    LOGS_DIR='$logs'
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
    _MODEL_UPGRADED=1
    US_ATTEMPT_HISTORY[US-001]='iter 4 (opus): AC1 null check missing'
    $AW_TEXT
    $IPU_TEXT
    $WWT_TEXT
    write_worker_trigger 5
    echo \"RC=\$?\" > '$d/rc.txt'
  " 2>"$d/stderr.log"
}

if (( ITEM1_FS_OK )); then
  # --- A: persist succeeds (writable logs dir) — baseline, no regression ---
  D1A="$TMP/1a"; mkdir -p "$D1A/logs"; mkfixture1 "$D1A"
  run_dispatch_1 "$D1A" "$D1A/logs"
  RC_1A=$(cat "$D1A/rc.txt" 2>/dev/null)
  [[ "$RC_1A" == "RC=0" ]] && [[ -f "$D1A/logs/iter-005.attempt-history.md" ]] \
    && ! [[ -f "$D1A/blocked-calls.txt" ]] \
    && ok "1A: writable logs dir — succeeds normally, artifact written, no BLOCKED call (no regression)" \
    || no "1A: baseline broke — rc='$RC_1A' artifact_exists=$([[ -f "$D1A/logs/iter-005.attempt-history.md" ]] && echo yes || echo no) blocked=$([[ -f "$D1A/blocked-calls.txt" ]] && echo yes || echo no)"

  # --- B: persist fails (read-only logs dir) — must fail CLOSED ---
  D1B="$TMP/1b"; mkdir -p "$D1B/logs"; mkfixture1 "$D1B"
  chmod 555 "$D1B/logs"
  run_dispatch_1 "$D1B" "$D1B/logs"
  chmod 755 "$D1B/logs"
  RC_1B=$(cat "$D1B/rc.txt" 2>/dev/null)
  [[ "$RC_1B" == "RC=1" ]] \
    && ok "1B: read-only logs dir — write_worker_trigger returns 1 (fails closed, not silently)" \
    || no "1B: expected RC=1 on a failed persist write, got '$RC_1B'"
  if [[ -f "$D1B/blocked-calls.txt" ]] && grep -q "category=infra_failure" "$D1B/blocked-calls.txt"; then
    ok "1B: write_blocked_sentinel called with category=infra_failure (loud, correctly classified)"
  else
    no "1B: write_blocked_sentinel not called or wrong category — $(cat "$D1B/blocked-calls.txt" 2>/dev/null || echo 'NO FILE')"
  fi
  # The prompt file must NOT exist claiming a complete dispatch when the
  # function bailed before finishing (worker-prompt.md is written by a LATER
  # atomic_write in the same function than the one that just failed).
  if [[ ! -f "$D1B/logs/iter-005.worker-trigger.sh" ]]; then
    ok "1B: worker-trigger.sh never written — no half-dispatched Worker on a failed persist"
  else
    no "1B: worker-trigger.sh was written despite the persist failure — Worker would still be dispatched"
  fi

  # --- C: mutation control — revert to the unchecked pipe on a scratch copy ---
  echo "--- Item 1 mutation control ---"
  MUT1="$TMP/run_mut1.zsh"
  cp "$RUN" "$MUT1"
  python3 - "$MUT1" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '''    {
      echo "# Attempt History (iteration $iter, ${CURRENT_US})"
      echo ""
      echo "Prior attempts on ${CURRENT_US} (newest first):"
      print -r -- "${US_ATTEMPT_HISTORY[$CURRENT_US]}" | sed 's/^/- /'
    } | atomic_write "$_attempt_history_file"
    if (( ${pipestatus[-1]:-0} != 0 )); then
      log_error "FAILED to persist attempt-history artifact ($_attempt_history_file) while approach escalation was active for ${CURRENT_US} — IO/disk error. Refusing to dispatch a Worker the enforcement gate could not actually check."
      write_blocked_sentinel "leader failed to persist the attempt-history artifact for ${CURRENT_US} while approach escalation was active — IO/disk error" "$CURRENT_US" "infra_failure"
      return 1
    fi
'''
new = '''    {
      echo "# Attempt History (iteration $iter, ${CURRENT_US})"
      echo ""
      echo "Prior attempts on ${CURRENT_US} (newest first):"
      print -r -- "${US_ATTEMPT_HISTORY[$CURRENT_US]}" | sed 's/^/- /'
    } | atomic_write "$_attempt_history_file"
'''
assert old in text, "Item 1 fix anchor not found"
text2 = text.replace(old, new)
assert text2 != text
with open(path, "w") as f:
    f.write(text2)
PYEOF
  if [[ $? -ne 0 ]]; then
    no "1C0: mutation setup failed (could not strip the Item-1 check)"
  else
    ok "1C0: mutation setup reverted Item 1 to the unchecked pipe on a scratch copy"
    MUT1_WWT="$(extract_fn write_worker_trigger "$MUT1")"
    D1C="$TMP/1c"; mkdir -p "$D1C/logs"; mkfixture1 "$D1C"
    chmod 555 "$D1C/logs"
    zsh -c "
      set -uo pipefail
      log() { :; }; log_error() { :; }; log_debug() { :; }
      _lifecycle_clear_lock_mark() { :; }
      build_claude_cmd() { echo 'stub-claude-cmd'; }
      _emit_waiver_contract() { :; }
      _bug8_carryover_file() { echo '/nonexistent/bug8.md'; }
      write_blocked_sentinel() { print -r -- \"BLOCKED\" >> '$D1C/blocked-calls.txt'; }
      typeset -A US_FIX_CONTRACT
      typeset -A US_ATTEMPT_HISTORY
      LOGS_DIR='$D1C/logs'
      MEMORY_FILE='$D1C/memory.md'
      WORKER_PROMPT_BASE='$D1C/worker-prompt-base.md'
      DESK='$D1C'
      SLUG='testslug'
      _PRD_CHANGED=0
      AUTONOMOUS_MODE=0
      WORKER_ENGINE='claude'
      WORKER_CODEX_MODEL=''
      WORKER_CODEX_REASONING=''
      WORKER_MODEL='claude-fable-5-1'
      WORKER_EFFORT='max'
      WORKER_HEARTBEAT='$D1C/heartbeat.json'
      SIGNAL_FILE='$D1C/iter-signal.json'
      VERIFY_MODE='per-us'
      US_LIST='US-001'
      VERIFIED_US=''
      _MODEL_UPGRADED=1
      US_ATTEMPT_HISTORY[US-001]='iter 4 (opus): AC1 null check missing'
      $AW_TEXT
      $IPU_TEXT
      $MUT1_WWT
      write_worker_trigger 5
      echo \"RC=\$?\" > '$D1C/rc.txt'
    " 2>"$D1C/stderr.log"
    chmod 755 "$D1C/logs"
    RC_1C=$(cat "$D1C/rc.txt" 2>/dev/null)
    if [[ "$RC_1C" == "RC=0" ]] && [[ ! -f "$D1C/blocked-calls.txt" ]]; then
      ok "1C1: mutation control effective — reverted code returns RC=0 and never calls BLOCKED on the same failed write (proves 1B tests the real fix)"
    else
      no "1C1: mutation control INEFFECTIVE — reverted code still detected the failure (rc='$RC_1C', blocked=$([[ -f "$D1C/blocked-calls.txt" ]] && echo yes || echo no))"
    fi
  fi
else
  no "Item 1: skipped (chmod-based failure injection unavailable on this filesystem)"
fi

# ===========================================================================
# ITEM 2 — malformed criteria_results must override to fail, distinctly from absent
# ===========================================================================
echo "--- Item 2: malformed criteria_results is distinguished from absent and fails closed ---"

CRE_TEXT="$(extract_fn _verdict_criteria_effective "$LIB")"
[[ -n "$CRE_TEXT" ]] && ok "extraction sanity: _verdict_criteria_effective() found in real source" \
  || no "extraction sanity: _verdict_criteria_effective() NOT found"

# Extract the main-loop snippet by its unique start marker, stopping right
# before the `case "$verdict" in` line that follows it in the real source.
extract_main_loop_cr_snippet() {
  awk '
    /# reaudit wave 1: make criteria_results LOAD-BEARING/ { f=1 }
    f && /case "\$verdict" in/ { exit }
    f { print }
  ' "$1"
}
MAINLOOP_CR_TEXT="$(extract_main_loop_cr_snippet "$RUN")"
echo "$MAINLOOP_CR_TEXT" | grep -q 'criteria_results_malformed=true' \
  && ok "extraction sanity: main-loop criteria_results snippet found in real source" \
  || no "extraction sanity: main-loop criteria_results snippet NOT found"

FVOU_CR_SNIPPET=$(awk '
  /  # Read verdict$/ { f=1 }
  f { print }
  f && /^  return 1$/ { exit }
' "$RUN")
echo "$FVOU_CR_SNIPPET" | grep -q 'criteria_results_malformed=true' \
  && ok "extraction sanity: _final_verify_one_us criteria_results snippet found in real source" \
  || no "extraction sanity: _final_verify_one_us criteria_results snippet NOT found"

run_main_loop_cr() { # $1 = verdict_file  $2 = top-level verdict string
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { echo \"LOGERR:\$*\"; }; log_debug() { :; }
    $CRE_TEXT
    VERDICT_FILE='$1'
    ITERATION=5
    verdict='$2'
    signal_us_id='US-001'
    $MAINLOOP_CR_TEXT
    echo \"FINAL_VERDICT=\$verdict\"
  "
}

run_fvou_cr() { # $1 = verdict_file  $2 = top-level verdict string
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { echo \"LOGERR:\$*\"; }; log_debug() { :; }
    _normalize_verdict() { echo \"\$1\"; }
    $CRE_TEXT
    # Wrapped in a function so the snippet's own return 0/1 (a real function
    # return inside _final_verify_one_us) returns from THIS call instead of
    # aborting the whole -c script — the snippet runs at top level here.
    _run_fvou() {
      $FVOU_CR_SNIPPET
    }
    VERDICT_FILE='$1'
    iter=5
    us='US-001'
    _run_fvou
    echo \"RC=\$?\"
  "
}

D2="$TMP/2"; mkdir -p "$D2"

# --- A: absent criteria_results — stays permissive (regression check) ---
echo '{"verdict":"pass"}' > "$D2/absent.json"
OUT_2A=$(run_main_loop_cr "$D2/absent.json" "pass")
echo "$OUT_2A" | grep -q "FINAL_VERDICT=pass" \
  && ok "2A: absent criteria_results stays permissive — a legacy/no-criteria pass is still credited (main loop)" \
  || no "2A: absent criteria_results wrongly penalized — $OUT_2A"

# --- B: malformed criteria_results (a STRING, not an array) with top-level pass ---
echo '{"verdict":"pass","criteria_results":"not-an-array"}' > "$D2/malformed.json"
OUT_2B=$(run_main_loop_cr "$D2/malformed.json" "pass")
echo "$OUT_2B" | grep -q "FINAL_VERDICT=fail" \
  && ok "2B: malformed criteria_results (string) overrides top-level pass to fail (main loop)" \
  || no "2B: malformed criteria_results did NOT override to fail — $OUT_2B"
echo "$OUT_2B" | grep -q "malformed"  \
  && ok "2B: log line distinguishes malformed from the unmet-count case" \
  || no "2B: no distinguishing malformed log line — $OUT_2B"

# --- C: malformed criteria_results (a NUMBER) ---
echo '{"verdict":"pass","criteria_results":42}' > "$D2/malformed-num.json"
OUT_2C=$(run_main_loop_cr "$D2/malformed-num.json" "pass")
echo "$OUT_2C" | grep -q "FINAL_VERDICT=fail" \
  && ok "2C: malformed criteria_results (number) also overrides to fail" \
  || no "2C: numeric malformed criteria_results not caught — $OUT_2C"

# --- D: populated, all met:true — genuine pass unaffected ---
echo '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' > "$D2/populated-pass.json"
OUT_2D=$(run_main_loop_cr "$D2/populated-pass.json" "pass")
echo "$OUT_2D" | grep -q "FINAL_VERDICT=pass" \
  && ok "2D: a genuinely populated, all-met criteria_results still passes (no false positive from the malformed fix)" \
  || no "2D: a genuine pass was wrongly failed — $OUT_2D"

# --- E: same four cases against _final_verify_one_us's snippet ---
OUT_2E_ABSENT=$(run_fvou_cr "$D2/absent.json" "pass")
echo "$OUT_2E_ABSENT" | grep -q "RC=0" \
  && ok "2E-absent: _final_verify_one_us stays permissive on absent criteria_results" \
  || no "2E-absent: unexpected result — $OUT_2E_ABSENT"
OUT_2E_MALFORMED=$(run_fvou_cr "$D2/malformed.json" "pass")
echo "$OUT_2E_MALFORMED" | grep -q "RC=1" \
  && ok "2E-malformed: _final_verify_one_us fails closed on malformed criteria_results" \
  || no "2E-malformed: did not fail on malformed criteria_results — $OUT_2E_MALFORMED"

# --- F: mutation control — strip the malformed branch, keep absent permissive,
#        prove 2B/2C go red without it ------------------------------------
echo "--- Item 2 mutation control ---"
MAINLOOP_CR_SRC="$TMP/mainloop-cr-snippet.txt"
print -r -- "$MAINLOOP_CR_TEXT" > "$MAINLOOP_CR_SRC"
MAINLOOP_CR_MUT="$TMP/mainloop-cr-snippet-mut.txt"
python3 - "$MAINLOOP_CR_SRC" "$MAINLOOP_CR_MUT" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()
old = '''        if [[ "$_cr_state" == "malformed" ]]; then
          log_error "  Verifier contract violation: criteria_results is present but malformed (not an array) — cannot trust top-level verdict=$verdict; overriding to fail (no credit on unverifiable evidence)."
          log_debug "[GOV] iter=$ITERATION criteria_results_malformed=true top_level_verdict=$verdict us_id=${signal_us_id:-all}"
          verdict="fail"
        elif (( _cr_unmet > 0 )); then'''
new = '''        if (( _cr_unmet > 0 )); then'''
assert old in text, "mutation anchor not found in extracted snippet"
with open(dst, "w") as f:
    f.write(text.replace(old, new))
PYEOF
MUT2_TEXT="$(cat "$MAINLOOP_CR_MUT" 2>/dev/null)"
[[ -n "$MUT2_TEXT" ]] && ok "2F0: mutation setup stripped the malformed branch from the extracted snippet" \
  || no "2F0: mutation setup produced empty snippet"
OUT_2F=$(zsh -c "
  set -uo pipefail
  log() { :; }; log_error() { echo \"LOGERR:\$*\"; }; log_debug() { :; }
  $CRE_TEXT
  VERDICT_FILE='$D2/malformed.json'
  ITERATION=5
  verdict='pass'
  signal_us_id='US-001'
  $MUT2_TEXT
  echo \"FINAL_VERDICT=\$verdict\"
")
echo "$OUT_2F" | grep -q "FINAL_VERDICT=pass" \
  && ok "2F1: mutation control effective — without the malformed branch, a malformed criteria_results rides through as pass exactly like the pre-fix bug (proves 2B tests the real fix)" \
  || no "2F1: mutation control INEFFECTIVE — still failed without the branch — $OUT_2F"

# ===========================================================================
# ITEM 3 — consensus merge must carry criteria_results through
# ===========================================================================
echo "--- Item 3: consensus merge carries criteria_results through (NO ENGINE PRIORITY) ---"

CF_TEXT="$(extract_fn _consensus_finalize "$RUN")"
[[ -n "$CF_TEXT" ]] && ok "extraction sanity: _consensus_finalize() found in real source" \
  || { no "extraction sanity: _consensus_finalize() NOT found — Item 3 cannot proceed"; CF_TEXT=""; }

D3="$TMP/3"; mkdir -p "$D3"

run_consensus() { # $1=claude_verdict_json $2=codex_verdict_json $3=CLAUDE_VERDICT $4=CODEX_VERDICT  -> prints merged VERDICT_FILE
  local cf="$D3/claude-$RANDOM.json" kf="$D3/codex-$RANDOM.json" vf="$D3/verdict-$RANDOM.json"
  print -r -- "$1" > "$cf"
  print -r -- "$2" > "$kf"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }
    typeset -A US_FIX_CONTRACT
    typeset -A US_ATTEMPT_HISTORY
    $(extract_fn atomic_write "$LIB")
    CLAUDE_VERDICT='$3'
    CODEX_VERDICT='$4'
    CONSENSUS_ROUND=1
    VERDICT_FILE='$vf'
    LOGS_DIR='$D3'
    $CF_TEXT
    _consensus_finalize 5 US-001 '$cf' '$kf'
  " >/dev/null 2>"$D3/stderr.log"
  cat "$vf" 2>/dev/null
}

# --- A: both pass, both have clean criteria_results (all met:true) — merged
#        array present, non-empty, contains both engines' entries ----------
V3A=$(run_consensus \
  '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' \
  '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' \
  "pass" "pass")
CR3A=$(echo "$V3A" | jq -c '.criteria_results' 2>/dev/null)
[[ "$(echo "$V3A" | jq -c '.criteria_results | length' 2>/dev/null)" == "2" ]] \
  && ok "3A: both-pass merge concatenates both engines' criteria_results (length 2)" \
  || no "3A: expected a 2-entry merged array, got: $CR3A — full verdict: $V3A"

# --- B: both pass at top level, but ONE engine's criteria_results has a
#        met:false entry — NO ENGINE PRIORITY means the merge must carry
#        that met:false through so downstream re-derives a fail -----------
V3B=$(run_consensus \
  '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' \
  '{"verdict":"pass","criteria_results":[{"id":"AC2","met":false}]}' \
  "pass" "pass")
UNMET_3B=$(echo "$V3B" | jq '[.criteria_results[]? | select(.met == false)] | length' 2>/dev/null)
[[ "$UNMET_3B" == "1" ]] \
  && ok "3B: a met:false from EITHER engine survives the merge (NO ENGINE PRIORITY applied to per-criterion data)" \
  || no "3B: the met:false entry was lost in the merge — unmet count: $UNMET_3B — full verdict: $V3B"

# --- C: one engine's criteria_results is malformed (a string) — the merge
#        must not launder it into a clean array; downstream must see
#        "malformed", not "populated" or "empty" -----------------------
V3C=$(run_consensus \
  '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' \
  '{"verdict":"pass","criteria_results":"garbage"}' \
  "pass" "pass")
CR3C_TYPE=$(echo "$V3C" | jq -r '.criteria_results | type' 2>/dev/null)
[[ "$CR3C_TYPE" != "array" && "$CR3C_TYPE" != "null" ]] \
  && ok "3C: a malformed per-engine criteria_results is NOT coerced into a clean array (merged type: $CR3C_TYPE) — downstream _verdict_criteria_effective will classify this as malformed" \
  || no "3C: malformed input was laundered into type='$CR3C_TYPE' — would silently ride through as absent/empty"
# Confirm end-to-end: feeding this merged file through the REAL
# _verdict_criteria_effective actually classifies it malformed.
VF3C=$(mktemp "$D3/vf3c.XXXXXX")
print -r -- "$V3C" > "$VF3C"
CRE_STATE_3C=$(zsh -c "$CRE_TEXT; _verdict_criteria_effective '$VF3C'")
echo "$CRE_STATE_3C" | grep -q "^malformed|" \
  && ok "3C-e2e: _verdict_criteria_effective classifies the merged verdict as malformed end-to-end" \
  || no "3C-e2e: expected malformed|.., got: $CRE_STATE_3C"

# --- D: disagreement branch also carries criteria_results ------------------
V3D=$(run_consensus \
  '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' \
  '{"verdict":"fail","criteria_results":[{"id":"AC1","met":false}]}' \
  "pass" "fail")
[[ "$(echo "$V3D" | jq -c '.criteria_results | length' 2>/dev/null)" == "2" ]] \
  && ok "3D: the disagreement branch also carries the merged criteria_results (length 2)" \
  || no "3D: disagreement branch missing/wrong criteria_results — $V3D"

# --- E: mutation control — strip the merge, prove 3A/3B go red -------------
echo "--- Item 3 mutation control ---"
MUT3="$TMP/run_mut3.zsh"
cp "$RUN" "$MUT3"
python3 - "$MUT3" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old_decl = '''  local claude_cr_type codex_cr_type merged_criteria_results
  claude_cr_type=$(jq -r '.criteria_results | type' "$claude_verdict_file" 2>/dev/null)
  codex_cr_type=$(jq -r '.criteria_results | type' "$codex_verdict_file" 2>/dev/null)
  if [[ ("$claude_cr_type" == "array" || "$claude_cr_type" == "null") \\
     && ("$codex_cr_type" == "array" || "$codex_cr_type" == "null") ]]; then
    local claude_cr codex_cr
    claude_cr=$(jq -c '.criteria_results // []' "$claude_verdict_file" 2>/dev/null || echo '[]')
    codex_cr=$(jq -c '.criteria_results // []' "$codex_verdict_file" 2>/dev/null || echo '[]')
    merged_criteria_results=$(echo "$claude_cr $codex_cr" | jq -s 'add // []')
  else
    merged_criteria_results='"malformed-in-consensus-merge"'
  fi
'''
assert old_decl in text, "Item 3 merge computation anchor not found"
text2 = text.replace(old_decl, '  local merged_criteria_results="null"\n')
text2 = text2.replace('      echo \'  "criteria_results": \'"$merged_criteria_results"\',\'\n', '')
assert text2 != text
with open(path, "w") as f:
    f.write(text2)
PYEOF
if [[ $? -ne 0 ]]; then
  no "3E0: mutation setup failed (could not strip the Item-3 merge)"
else
  ok "3E0: mutation setup reverted Item 3 (merge removed, criteria_results field dropped) on a scratch copy"
  MUT3_CF_TEXT="$(extract_fn _consensus_finalize "$MUT3")"
  D3E="$TMP/3e"; mkdir -p "$D3E"
  V3E=$(
    cf="$D3E/claude.json"; kf="$D3E/codex.json"; vf="$D3E/verdict.json"
    echo '{"verdict":"pass","criteria_results":[{"id":"AC1","met":true}]}' > "$cf"
    echo '{"verdict":"pass","criteria_results":[{"id":"AC2","met":false}]}' > "$kf"
    zsh -c "
      set -uo pipefail
      log() { :; }; log_error() { :; }; log_debug() { :; }
      _lifecycle_clear_lock_mark() { :; }
      $(extract_fn atomic_write "$LIB")
      CLAUDE_VERDICT='pass'; CODEX_VERDICT='pass'; CONSENSUS_ROUND=1
      VERDICT_FILE='$vf'
      $MUT3_CF_TEXT
      _consensus_finalize 5 US-001 '$cf' '$kf'
    " >/dev/null 2>&1
    cat "$vf" 2>/dev/null
  )
  CR3E_PRESENT=$(echo "$V3E" | jq 'has("criteria_results")' 2>/dev/null)
  if [[ "$CR3E_PRESENT" != "true" ]]; then
    ok "3E1: mutation control effective — without the merge, criteria_results is absent from the consensus verdict exactly like the pre-fix bug (proves 3A-3D test the real fix)"
  else
    no "3E1: mutation control INEFFECTIVE — criteria_results still present without the merge code — $V3E"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
