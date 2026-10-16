#!/bin/zsh
# J-07: the D-5b status.json restore assigned WORKER_MODEL / WORKER_CODEX_MODEL /
# _ORIGINAL_WORKER_MODEL verbatim, so a RETIRED id saved in status.json (written by an
# older leader, or hand-edited) resumed as `codex -m <retired id>`. The restored ids
# must pass through the same retired-id remap the CLI flags get (_normalize_model_spec),
# with the standard [model-remap] WARNING, the level preserved, and current ids
# (including bare claude aliases, which _normalize_model_spec would otherwise give a
# `:level`) left exactly as saved.
set -uo pipefail
unset TMUX
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" && -f "$LIB" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 "SKIP: jq required"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"; }

log(){ :; }; log_error(){ :; }; log_debug(){ :; }
source "$LIB"
log(){ :; }; log_error(){ :; }; log_debug(){ :; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
STATUS_FILE="$TMPDIR_T/status.json"

_restore_block=$(awk '/local _status_mu$/,/^    fi$/' "$RUN")
[[ -n "$_restore_block" ]] && print -r -- "$_restore_block" | grep -q 'WORKER_CODEX_MODEL' \
  && ok "D-5b restore block extracted" || { no "D-5b restore block not found (drift?)"; exit 1; }

# $1 = status.json body. Prints the restored globals on one line; the restore's own
# stderr (the [model-remap] warnings) goes to $TMPDIR_T/stderr.
_drive_restore() {
  print -r -- "$1" > "$STATUS_FILE"
  local _ORIGINAL_WORKER_CODEX_REASONING="" _ORIGINAL_WORKER_MODEL="" _ORIGINAL_WORKER_EFFORT=""
  local WORKER_MODEL="" WORKER_ENGINE="" WORKER_CODEX_MODEL="" WORKER_CODEX_REASONING="" WORKER_EFFORT=""
  local _MODEL_UPGRADED=0 _SAME_US_FAIL_COUNT=0 _CEILING_DEFERRAL_COUNT=0
  eval "$_restore_block" 2>"$TMPDIR_T/stderr"
  print -r -- "WM=$WORKER_MODEL WCM=$WORKER_CODEX_MODEL WCR=$WORKER_CODEX_REASONING OWM=$_ORIGINAL_WORKER_MODEL WEF=$WORKER_EFFORT OWEF=$_ORIGINAL_WORKER_EFFORT WE=$WORKER_ENGINE"
}

print "== J-07: level carried on the saved id =="
_out=$(_drive_restore '{"model_upgraded":1,"worker_model":"gpt-5.3-codex-spark:high","worker_engine":"codex","worker_codex_model":"gpt-5.5:xhigh","worker_codex_reasoning":"high","original_worker_model":"gpt-5.4-mini:medium"}')
[[ "$_out" == *"WM=gpt-6-luna:high "* ]] && ok "worker_model 'gpt-5.3-codex-spark:high' restored as gpt-6-luna:high" || no "worker_model not remapped ($_out)"
[[ "$_out" == *"WCM=gpt-6.1-sol:xhigh "* ]] && ok "worker_codex_model 'gpt-5.5:xhigh' restored as gpt-6.1-sol:xhigh" || no "worker_codex_model not remapped ($_out)"
[[ "$_out" == *"OWM=gpt-6-luna:medium "* ]] && ok "original_worker_model 'gpt-5.4-mini:medium' restored as gpt-6-luna:medium" || no "original_worker_model not remapped ($_out)"
[[ "$_out" == *"WE=codex"* && "$_out" == *"WCR=high"* ]] && ok "engine and the separately saved reasoning are untouched" || no "engine/reasoning changed ($_out)"
_err=$(<"$TMPDIR_T/stderr")
[[ "$_err" == *"[model-remap] WARNING: 'gpt-5.3-codex-spark:high' is retired — using 'gpt-6-luna:high' instead."* ]] && ok "standard [model-remap] WARNING emitted (spark)" || no "no remap warning for spark ($_err)"
[[ "$_err" == *"[model-remap] WARNING: 'gpt-5.5:xhigh' is retired — using 'gpt-6.1-sol:xhigh' instead."* ]] && ok "standard [model-remap] WARNING emitted (gpt-5.5)" || no "no remap warning for gpt-5.5 ($_err)"

print "== J-07: the real saved shape (bare model id, level in its own field) =="
for _pair in "gpt-5.3-codex-spark gpt-6-luna" "spark gpt-6-luna" "gpt-5.4-mini gpt-6-luna" "gpt-5.5 gpt-6.1-sol" "gpt-5.4 gpt-5.6-terra"; do
  _old=${_pair%% *}; _new=${_pair##* }
  _out=$(_drive_restore '{"model_upgraded":1,"worker_model":"'$_old'","worker_engine":"codex","worker_codex_model":"'$_old'","worker_codex_reasoning":"xhigh","original_worker_model":"'$_old'"}')
  [[ "$_out" == "WM=$_new WCM=$_new WCR=xhigh OWM=$_new "* ]] && ok "bare retired '$_old' -> '$_new', reasoning xhigh preserved" || no "bare '$_old' not remapped ($_out)"
done

print "== J-07: current ids round-trip unchanged, no warning =="
_out=$(_drive_restore '{"model_upgraded":1,"worker_model":"gpt-6.1-sol","worker_engine":"codex","worker_codex_model":"gpt-6.1-sol","worker_codex_reasoning":"high","original_worker_model":"gpt-6-luna"}')
check "current codex ids unchanged" "WM=gpt-6.1-sol WCM=gpt-6.1-sol WCR=high OWM=gpt-6-luna WEF= OWEF= WE=codex" "$_out"
[[ ! -s "$TMPDIR_T/stderr" ]] && ok "no warning for current ids" || no "unexpected stderr: $(<"$TMPDIR_T/stderr")"
_out=$(_drive_restore '{"model_upgraded":1,"worker_model":"sonnet","worker_engine":"claude","worker_effort":"medium","original_worker_model":"claude-haiku-5-5","original_worker_effort":"low"}')
check "bare claude aliases do NOT gain a :level on restore" "WM=sonnet WCM= WCR= OWM=claude-haiku-5-5 WEF=medium OWEF=low WE=claude" "$_out"
_out=$(_drive_restore '{"model_upgraded":1,"worker_model":"claude-opus-5-5","worker_engine":"claude","worker_effort":"high","original_worker_model":"opus"}')
check "claude-opus-5-5 / opus unchanged" "WM=claude-opus-5-5 WCM= WCR= OWM=opus WEF=high OWEF= WE=claude" "$_out"

print "== J-07: not upgraded -> nothing restored (gate unchanged) =="
_out=$(_drive_restore '{"model_upgraded":0,"worker_model":"gpt-5.5","worker_engine":"codex"}')
check "model_upgraded=0 leaves env/CLI model alone" "WM= WCM= WCR= OWM= WEF= OWEF= WE=" "$_out"

print ""
print "w1_resume_model_remap: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
