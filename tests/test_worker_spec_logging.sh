#!/usr/bin/env zsh
# F-LOG — every place that names the Worker model must name its EFFORT too.
#
# Root cause: a claude ladder hop can be effort-only (claude-sonnet-5-5:medium ->
# claude-sonnet-5-5:high keeps the model id), and a codex hop can be
# (gpt-5.6-terra:medium -> :high). The leader printed bare model ids in five
# places, so an effort-only promotion logged "X -> X" and the Worker was told it
# "was upgraded to X" with no hint what changed; the D-5b crash-restore log
# printed the CODEX reasoning default for claude workers.
#   (a) lib   check_model_upgrade   "Worker model upgraded: A -> B"  (+ [DECIDE] from=/to=)
#   (b) run   write_worker_trigger  "the Worker model was upgraded to B"
#   (c) run   attempt-history entry "iter N (<model>): ..."
#   (d) run   D-5b crash-restore    "Restored auto-upgraded Worker model: ..." (the region now starts at the F6 same-US restore)
#   (e) run   pass-restore          "Worker model restored: B -> A"  (symmetry with (a))
# Fix: print model:effort, engine-aware (claude -> WORKER_EFFORT, codex ->
# WORKER_CODEX_REASONING), bare model when the effort is empty.
#
# Drives the REAL functions / blocks extracted from the shipped scripts.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

extract_fn() { awk -v fn="$1() {" 'index($0, fn) == 1 { f=1 } f { print; if ($0 == "}") exit }' "$2"; }

# ---- (a) check_model_upgrade log + [DECIDE] ---------------------------------
# upgrade_log <engine> <model> <claude_effort> <codex_model> <codex_reasoning> <nfails>
upgrade_log() {
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    LIB_DIR="'"$REPO"'/src/scripts"; RLP_DESK_MODELS_FILE=/nonexistent/x.json
    log(){ print -r -- "LOG: $*"; }; log_debug(){ print -r -- "DEBUG: $*"; }; log_error(){ :; }
    WORKER_ENGINE="'"$1"'"; WORKER_MODEL="'"$2"'"; WORKER_EFFORT="'"$3"'"; WORKER_CODEX_MODEL="'"$4"'"; WORKER_CODEX_REASONING="'"$5"'"
    LOCK_WORKER_MODEL=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; ITERATION=1
    _ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""
    for i in {1..'"$6"'}; do check_model_upgrade US-001; done
  ' 2>&1
}
want_line() { # <output> <exact line> <label> <red message>
  if print -r -- "$1" | grep -qxF -- "$2"; then ok "$3"; else no "$4 — got: $(print -r -- "$1" | grep 'Worker model' | tr '\n' '|')"; fi
}

print -r -- "== F-LOG (a): leader.log 'Worker model upgraded' names model:effort =="
out=$(upgrade_log claude haiku "" gpt-5.6-luna high 2)
want_line "$out" "LOG:   Worker model upgraded: haiku → claude-sonnet-5-5:high (same-US consecutive fail threshold)" "a1 haiku -> claude-sonnet-5-5:high (bare start, effort on the target)" "a1 expected 'haiku → claude-sonnet-5-5:high'"
out=$(upgrade_log claude claude-sonnet-5-5 medium gpt-5.6-luna high 2)
want_line "$out" "LOG:   Worker model upgraded: claude-sonnet-5-5:medium → claude-sonnet-5-5:high (same-US consecutive fail threshold)" "a2 MEDIUM effort-only hop is visible (claude-sonnet-5-5:medium -> :high)" "a2 expected 'claude-sonnet-5-5:medium → claude-sonnet-5-5:high'"
out=$(upgrade_log claude claude-sonnet-5-5 medium gpt-5.6-luna high 4)
want_line "$out" "LOG:   Worker model upgraded: claude-sonnet-5-5:medium → claude-opus-5-5:high (same-US consecutive fail threshold)" "a3 2nd hop reports the original start tier (cumulative from the start) with effort" "a3 expected 'claude-sonnet-5-5:medium → claude-opus-5-5:high'"
out=$(upgrade_log codex gpt-5.6-terra "" gpt-5.6-terra medium 2)
want_line "$out" "LOG:   Worker model upgraded: gpt-5.6-terra:medium → gpt-5.6-terra:high (same-US consecutive fail threshold)" "a4 codex effort-only hop (terra:medium -> :high)" "a4 expected 'gpt-5.6-terra:medium → gpt-5.6-terra:high'"
out=$(upgrade_log claude claude-sonnet-5-5 medium gpt-5.6-luna xhigh 2)
if print -r -- "$out" | grep -q 'xhigh'; then no "a5 claude row leaked the codex reasoning default 'xhigh' — got: $(print -r -- "$out" | grep 'Worker model upgraded')"; else ok "a5 claude log never shows the codex reasoning value (engine-aware)"; fi
out=$(upgrade_log claude claude-sonnet-5-5 medium gpt-5.6-luna high 2)
if print -r -- "$out" | grep -qF "model_upgrade=true reason=consecutive_same_ac_fail from=claude-sonnet-5-5:medium to=claude-sonnet-5-5:high"; then
  ok "a6 [DECIDE] model_upgrade=true carries from=/to= as model:effort"
else no "a6 [DECIDE] from=/to= lack effort — got: $(print -r -- "$out" | grep 'DECIDE' | grep 'upgrade=true')"; fi

# ---- (b) worker-facing approach-escalation text ----------------------------
WWT_TEXT="$(extract_fn write_worker_trigger "$RUN")"
IPU_TEXT="$(extract_fn inject_per_us_prd "$RUN")"
AW_TEXT="$(extract_fn atomic_write "$LIB")"
[[ -n "$WWT_TEXT" && -n "$AW_TEXT" ]] && ok "extraction sanity: write_worker_trigger / atomic_write found" || { no "extraction sanity: write_worker_trigger/atomic_write NOT found"; exit 1; }
worker_prompt() { # <engine> <model> <claude_effort> <codex_reasoning> -> prints the approach-escalation sentence
  local d="$TMP/b-$RANDOM"; mkdir -p "$d/logs" "$d/plans"
  printf '## Stop Status\nrunning\n\n## Next Iteration Contract\nImplement US-001.\n' > "$d/memory.md"
  printf '# Worker Prompt Base\nRead the PRD.\n' > "$d/worker-prompt-base.md"; echo PRD > "$d/plans/prd-testslug.md"
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    _lifecycle_clear_lock_mark() { :; }; build_claude_cmd() { echo stub; }; _emit_waiver_contract() { :; }
    _bug8_carryover_file() { echo /nonexistent/bug8.md; }
    typeset -A US_FIX_CONTRACT; typeset -A US_ATTEMPT_HISTORY
    LOGS_DIR='$d/logs'; MEMORY_FILE='$d/memory.md'; WORKER_PROMPT_BASE='$d/worker-prompt-base.md'; DESK='$d'; SLUG=testslug
    _PRD_CHANGED=0; AUTONOMOUS_MODE=0; WORKER_HEARTBEAT='$d/hb.json'; SIGNAL_FILE='$d/sig.json'; VERIFY_MODE=per-us
    US_LIST=US-001; VERIFIED_US=''; _MODEL_UPGRADED=1
    WORKER_ENGINE='$1'; WORKER_MODEL='$2'; WORKER_EFFORT='$3'; WORKER_CODEX_MODEL=''; WORKER_CODEX_REASONING='$4'
    US_ATTEMPT_HISTORY[US-001]='iter 2 (haiku): AC1 missing'
    $AW_TEXT
    $IPU_TEXT
    $WWT_TEXT
    write_worker_trigger 5
  " >/dev/null 2>"$d/stderr.log"
  grep 'was upgraded to' "$d/logs/iter-005.worker-prompt.md" 2>/dev/null
}
print -r -- "== F-LOG (b): the Worker is told the model:effort it was upgraded to =="
got=$(worker_prompt claude claude-sonnet-5-5 high high)
[[ "$got" == "US-001 has failed enough consecutive times that the Worker model was upgraded to claude-sonnet-5-5:high." ]] && ok "b1 claude: 'upgraded to claude-sonnet-5-5:high.'" || no "b1 claude worker text: '$got' (want '... upgraded to claude-sonnet-5-5:high.')"
got=$(worker_prompt claude claude-opus-5-5 "" high)
[[ "$got" == "US-001 has failed enough consecutive times that the Worker model was upgraded to claude-opus-5-5." ]] && ok "b2 claude with EMPTY effort stays bare (codex default 'high' must not leak)" || no "b2 claude empty-effort text: '$got' (want '... upgraded to claude-opus-5-5.')"
got=$(worker_prompt codex gpt-5.6-terra "" high)
[[ "$got" == "US-001 has failed enough consecutive times that the Worker model was upgraded to gpt-5.6-terra:high." ]] && ok "b3 codex: 'upgraded to gpt-5.6-terra:high.'" || no "b3 codex worker text: '$got' (want '... upgraded to gpt-5.6-terra:high.')"

# ---- (c) attempt-history entry records the model:effort that FAILED --------
print -r -- "== F-LOG (c): attempt history names the model:effort that produced the failure =="
SNAP="$(awk '/# DEFECT-2b: snapshot the model BEFORE check_model_upgrade can/ {c=1} c {print} c && /^            fi$/ {exit}' "$RUN")"
[[ -n "$SNAP" ]] && print -r -- "$SNAP" | grep -q '_pre_upgrade_worker_model=' && ok "extraction sanity: _pre_upgrade_worker_model snapshot found" || { no "extraction sanity: snapshot block NOT found (marker changed?)"; SNAP=""; }
attempt_line() { # <engine> <model> <claude_effort> <codex_reasoning>
  local hf="$TMP/c-$RANDOM.zsh"
  cat > "$hf" <<HARN
source '$LIB' 2>/dev/null
log() { :; }; log_debug() { :; }
typeset -gA US_ATTEMPT_HISTORY
ATTEMPT_HISTORY_CAP=3; ITERATION=3; DONE_CLAIM_FILE=''
WORKER_ENGINE='$1'; WORKER_MODEL='$2'; WORKER_EFFORT='$3'; WORKER_CODEX_REASONING='$4'
_h() {
$SNAP
  _record_us_attempt US-001 "\$_pre_upgrade_worker_model" "boom"
}
_h
print -r -- "\${US_ATTEMPT_HISTORY[US-001]}"
HARN
  zsh -f "$hf" 2>&1 | tail -1
}
got=$(attempt_line claude claude-sonnet-5-5 medium high)
[[ "$got" == "iter 3 (claude-sonnet-5-5:medium): boom" ]] && ok "c1 claude: 'iter 3 (claude-sonnet-5-5:medium): boom'" || no "c1 claude attempt history: '$got' (want 'iter 3 (claude-sonnet-5-5:medium): boom')"
got=$(attempt_line claude haiku "" high)
[[ "$got" == "iter 3 (haiku): boom" ]] && ok "c2 claude haiku (no effort) stays bare" || no "c2 haiku attempt history: '$got' (want 'iter 3 (haiku): boom')"
got=$(attempt_line codex gpt-5.6-luna "" max)
[[ "$got" == "iter 3 (gpt-5.6-luna:max): boom" ]] && ok "c3 codex: 'iter 3 (gpt-5.6-luna:max): boom'" || no "c3 codex attempt history: '$got' (want 'iter 3 (gpt-5.6-luna:max): boom')"

# ---- (d) D-5b crash-restore log --------------------------------------------
D5B="$(awk '/local _s_phase|local _status_mu$/ { if (!capture) capture=1 } capture { print; if (started_if && $0 ~ /^    fi$/) { exit } } capture && /if \[\[ "\$_status_mu"/ { started_if=1 }' "$RUN")"
[[ -n "$D5B" ]] && ok "extraction sanity: D-5b restore block found" || { no "extraction sanity: D-5b block NOT found"; D5B=""; }
d5b_log() { # <status json>
  local d="$TMP/d-$RANDOM"; mkdir -p "$d"; print -r -- "$1" > "$d/status.json"
  { print -r -- 'log(){ print -r -- "LOG: $*"; }; log_debug(){ :; }'
    print -r -- "STATUS_FILE='$d/status.json'"
    print -r -- 'WORKER_MODEL=haiku; WORKER_ENGINE=claude; WORKER_EFFORT=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=high'
    print -r -- '_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""'
    print -r -- '_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; _CEILING_DEFERRAL_COUNT=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
    print -r -- "$D5B"; } > "$d/h.zsh"
  zsh -f "$d/h.zsh" 2>&1 | grep 'Restored auto-upgraded'
}
print -r -- "== F-LOG (d): D-5b crash-restore log is engine-aware =="
got=$(d5b_log '{"model_upgraded":1,"worker_model":"claude-sonnet-5-5","worker_engine":"claude","worker_effort":"high","original_worker_model":"haiku","original_worker_codex_reasoning":"high","same_us_fail_count":1,"last_failed_us":"US-001"}')
if [[ "$got" == "LOG:   Restored auto-upgraded Worker model: claude-sonnet-5-5:high (claude), orig=haiku, same_us_fails=1, ceiling_deferrals=0 (D-5b restore-priority)" ]]; then
  ok "d1 claude: model:effort, orig=haiku bare, no codex orig_effort"
else no "d1 claude D-5b log: '$got' (want '... Worker model: claude-sonnet-5-5:high (claude), orig=haiku, same_us_fails=1, ceiling_deferrals=0 ...' — the codex 'orig_effort=high' must not be printed for a claude worker)"; fi
got=$(d5b_log '{"model_upgraded":1,"worker_model":"gpt-5.6-terra","worker_engine":"codex","worker_codex_model":"gpt-5.6-terra","worker_codex_reasoning":"high","original_worker_model":"gpt-5.6-terra","original_worker_codex_reasoning":"medium","same_us_fail_count":0}')
if [[ "$got" == "LOG:   Restored auto-upgraded Worker model: gpt-5.6-terra:high (codex), orig=gpt-5.6-terra:medium, same_us_fails=0, ceiling_deferrals=0 (D-5b restore-priority)" ]]; then
  ok "d2 codex: model:reasoning for current and original"
else no "d2 codex D-5b log: '$got' (want '... gpt-5.6-terra:high (codex), orig=gpt-5.6-terra:medium, same_us_fails=0, ceiling_deferrals=0 ...')"; fi

# ---- (e) pass-restore log ----------------------------------------------------
PR="$(awk '/if \(\( _MODEL_UPGRADED \)\); then/ { capture=1 } capture { print; if (seen_reset && $0 ~ /^            fi$/) { exit } } capture && /_MODEL_UPGRADED=0/ { seen_reset=1 }' "$RUN")"
[[ -n "$PR" ]] && print -r -- "$PR" | grep -q 'Worker model restored' && ok "extraction sanity: pass-restore block found" || { no "extraction sanity: pass-restore block NOT found"; PR=""; }
restore_log() { # <engine> <cur model> <cur claude eff> <cur codex r> <orig model> <orig claude eff> <orig codex r>
  local hf="$TMP/e-$RANDOM.zsh"
  { print -r -- 'log(){ print -r -- "LOG: $*"; }; log_debug(){ print -r -- "DEBUG: $*"; }'
    print -r -- "ITERATION=9; WORKER_ENGINE='$1'; WORKER_MODEL='$2'; WORKER_EFFORT='$3'; WORKER_CODEX_REASONING='$4'; WORKER_CODEX_MODEL='$2'"
    print -r -- "_ORIGINAL_WORKER_MODEL='$5'; _ORIGINAL_WORKER_EFFORT='$6'; _ORIGINAL_WORKER_CODEX_REASONING='$7'; _MODEL_UPGRADED=1"
    print -r -- "_h(){"; print -r -- "$PR"; print -r -- "}; _h"; } > "$hf"
  zsh -f "$hf" 2>&1
}
print -r -- "== F-LOG (e): pass-restore log names model:effort on both sides =="
out=$(restore_log claude claude-sonnet-5-5 high high haiku "" high)
want_line "$out" "LOG:   Worker model restored: claude-sonnet-5-5:high → haiku (pass verdict)" "e1 claude: 'claude-sonnet-5-5:high → haiku'" "e1 expected 'restored: claude-sonnet-5-5:high → haiku'"
out=$(restore_log claude claude-opus-5-5 high high claude-sonnet-5-5 medium high)
want_line "$out" "LOG:   Worker model restored: claude-opus-5-5:high → claude-sonnet-5-5:medium (pass verdict)" "e2 MEDIUM walk-back 'claude-opus-5-5:high → claude-sonnet-5-5:medium'" "e2 expected 'restored: claude-opus-5-5:high → claude-sonnet-5-5:medium'"
out=$(restore_log codex gpt-5.6-terra "" high gpt-5.6-terra "" medium)
want_line "$out" "LOG:   Worker model restored: gpt-5.6-terra:high → gpt-5.6-terra:medium (pass verdict)" "e3 codex 'gpt-5.6-terra:high → gpt-5.6-terra:medium'" "e3 expected 'restored: gpt-5.6-terra:high → gpt-5.6-terra:medium'"
if print -r -- "$out" | grep -qF "model_restore=true from=gpt-5.6-terra:high to=gpt-5.6-terra:medium"; then ok "e4 [DECIDE] model_restore=true from=/to= carry model:reasoning"; else no "e4 [DECIDE] model_restore from=/to= lack effort — got: $(print -r -- "$out" | grep model_restore)"; fi
# e5: legacy status.json (no original_worker_codex_reasoning) -> the block keeps the ACTIVE
# reasoning, so the restore log/[DECIDE] target must show it, not a bare model.
out=$(restore_log codex gpt-5.6-terra "" high gpt-5.6-terra "" "")
want_line "$out" "LOG:   Worker model restored: gpt-5.6-terra:high → gpt-5.6-terra:high (pass verdict)" "e5 codex legacy status (no original reasoning): target shows the kept active reasoning" "e5 expected 'restored: gpt-5.6-terra:high → gpt-5.6-terra:high'"
if print -r -- "$out" | grep -qF "model_restore=true from=gpt-5.6-terra:high to=gpt-5.6-terra:high"; then ok "e6 [DECIDE] model_restore to= also shows the kept active reasoning"; else no "e6 [DECIDE] to= lacks the kept reasoning — got: $(print -r -- "$out" | grep model_restore)"; fi

# ---- (f) circuit-breaker deferral / GOV / log_error / BLOCKED text -----------
CB="$(awk '/# Circuit breaker: consecutive failures/ { f=1 } f && $0 == "            update_status \"verifier\" \"fail\"" { exit } f { print }' "$RUN")"
[[ -n "$CB" ]] && print -r -- "$CB" | grep -q 'write_blocked_sentinel' && ok "extraction sanity: circuit-breaker block found" || { no "extraction sanity: circuit-breaker block NOT found"; CB=""; }
cb_out() { # <engine> <model> <claude_effort> <codex_reasoning> <consec_fails> <same_us_fails> -> every log / sentinel line
  local hf="$TMP/f-$RANDOM.zsh"
  { print -r -- 'log(){ print -r -- "LOG: $*"; }; log_debug(){ print -r -- "DEBUG: $*"; }; log_error(){ print -r -- "ERROR: $*"; }'
    print -r -- 'write_blocked_sentinel(){ print -r -- "BLOCKED: $1"; }; update_status(){ :; }; get_next_model(){ :; }'
    print -r -- "ITERATION=9; WORKER_ENGINE='$1'; WORKER_MODEL='$2'; WORKER_EFFORT='$3'; WORKER_CODEX_REASONING='$4'; WORKER_CODEX_MODEL='$2'"
    print -r -- "CONSECUTIVE_FAILURES=$5; EFFECTIVE_CB_THRESHOLD=4; _SAME_US_FAIL_COUNT=$6; _CEILING_DEFERRAL_COUNT=0; _MODEL_UPGRADED=1"
    print -r -- "_h(){"; print -r -- "$CB"; print -r -- "}; _h"; } > "$hf"
  zsh -f "$hf" 2>&1
}
print -r -- "== F-LOG (f): circuit-breaker text names the ceiling Worker as model:effort =="
out=$(cb_out claude claude-opus-5-5 high high 6 2)
want_line "$out" "BLOCKED: architecture escalation: Worker at ceiling model (claude-opus-5-5:high) failed after its own attempt window, 6 consecutive verification failures (threshold 4)" "f1 BLOCKED sentinel: claude ceiling worker as model:effort" "f1 expected 'ceiling model (claude-opus-5-5:high)'"
want_line "$out" "ERROR: Circuit breaker: architecture escalation — Worker at ceiling (claude-opus-5-5:high) failed its own attempt window, 6 consecutive failures (threshold 4)" "f2 log_error names claude-opus-5-5:high" "f2 expected log_error 'Worker at ceiling (claude-opus-5-5:high)'"
if print -r -- "$out" | grep -qF 'detail="architecture escalation: Worker at ceiling (claude-opus-5-5:high), 6 consecutive failures'; then ok "f3 [GOV] detail names claude-opus-5-5:high"; else no "f3 [GOV] detail lacks the effort — got: $(print -r -- "$out" | grep GOV)"; fi
out=$(cb_out claude claude-opus-5-5 "" high 6 2)
want_line "$out" "BLOCKED: architecture escalation: Worker at ceiling model (claude-opus-5-5) failed after its own attempt window, 6 consecutive verification failures (threshold 4)" "f4 claude with EMPTY effort stays bare (codex 'high' must not leak)" "f4 expected bare 'ceiling model (claude-opus-5-5)'"
out=$(cb_out codex gpt-5.6-sol "" xhigh 6 2)
want_line "$out" "BLOCKED: architecture escalation: Worker at ceiling model (gpt-5.6-sol:xhigh) failed after its own attempt window, 6 consecutive verification failures (threshold 4)" "f5 codex ceiling worker as model:reasoning" "f5 expected 'ceiling model (gpt-5.6-sol:xhigh)'"
out=$(cb_out claude claude-opus-5-5 high high 4 0)
want_line "$out" "LOG:   Circuit breaker deferred: Worker just reached ceiling model (claude-opus-5-5:high) — giving it its own attempt window (same-model fail 0/2, deferral 1/2) before blocking." "f6 deferral log names claude-opus-5-5:high" "f6 expected 'ceiling model (claude-opus-5-5:high)'"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
