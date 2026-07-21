#!/usr/bin/env zsh
# ③ request-j (v0.22.18) — restart path must not lose model_reasoning_effort.
#
# Chain of the field-observed BLOCKED: check_model_upgrade saves
# _ORIGINAL_WORKER_CODEX_REASONING in-memory only → update_status persisted
# original_worker_model but NOT the reasoning → leader-relaunch restore rehydrated
# everything except the reasoning → restore-on-pass then assigned the empty string
# → next dispatch assembled `-c model_reasoning_effort=""` → codex refused to start
# → BLOCKED. Fix: persist + restore original_worker_codex_reasoning; keep-current
# defense on empty at restore-on-pass; a `_require_codex_effort` assembly guard.
#
# Tests: (1) update_status emits original_worker_codex_reasoning; (2) the D-5b
# restore block rehydrates _ORIGINAL_WORKER_CODEX_REASONING; (3) restore-on-pass
# yields the ORIGINAL non-empty effort AND keeps-current when the original is empty;
# (4) _require_codex_effort fails-fast on empty, passes on non-empty.
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" && -f "$LIB" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { print -u2 "SKIP: jq required"; exit 0; }

log(){ :; }; log_error(){ :; }; log_debug(){ :; }
source "$LIB"
log(){ :; }; log_error(){ :; }; log_debug(){ :; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}

# =============================================================================
# (1) update_status persists original_worker_codex_reasoning
# =============================================================================
STATUS_FILE="$TMPDIR_T/status.json"
# Minimal global surface the JSON builder reads (CONSENSUS_MODE=off skips the
# consensus branch; VERIFIED_US empty skips the array build).
SLUG="testslug"; BASELINE_COMMIT="none"; ITERATION=5; MAX_ITER=40
WORKER_MODEL="gpt-5.6-terra"; VERIFIER_MODEL="opus"
WORKER_ENGINE="codex"; VERIFIER_ENGINE="claude"
WORKER_CODEX_MODEL="gpt-5.6-terra"; WORKER_CODEX_REASONING="medium"
VERIFIER_CODEX_MODEL="gpt-5.6"; VERIFIER_CODEX_REASONING="high"
VERIFY_MODE="per-us"; CONSENSUS_MODE="off"
CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
_MODEL_UPGRADED=1; _SAME_US_FAIL_COUNT=2
_ORIGINAL_WORKER_MODEL="gpt-5.6-terra"
_ORIGINAL_WORKER_CODEX_REASONING="high"
VERIFIED_US=""; ITER_START_HEAD=""; GATE_RECEIPT_STATUS="none"

update_status "worker" "running"
_got=$(jq -r '.original_worker_codex_reasoning // "MISSING"' "$STATUS_FILE" 2>/dev/null)
[[ "$_got" == "high" ]] \
  && ok "update_status emits original_worker_codex_reasoning ('$_got')" || no "field missing/wrong in status.json ('$_got')"
jq -e . "$STATUS_FILE" >/dev/null 2>&1 && ok "status.json remains valid JSON" || no "status.json invalid JSON"

# =============================================================================
# (2) D-5b restore block rehydrates _ORIGINAL_WORKER_CODEX_REASONING
# =============================================================================
# Write a status.json that a leader-relaunch would restore from.
cat > "$STATUS_FILE" <<'JSON'
{
  "model_upgraded": 1,
  "worker_model": "gpt-5.6-terra",
  "worker_engine": "codex",
  "worker_codex_model": "gpt-5.6-terra",
  "worker_codex_reasoning": "high",
  "original_worker_model": "gpt-5.6-terra",
  "original_worker_codex_reasoning": "medium",
  "same_us_fail_count": 1
}
JSON
_restore_block=$(awk '/local _status_mu$/,/^    fi$/' "$RUN")
[[ -n "$_restore_block" ]] && print -r -- "$_restore_block" | grep -q '_ORIGINAL_WORKER_CODEX_REASONING' \
  && ok "restore block extracted and references _ORIGINAL_WORKER_CODEX_REASONING" || no "restore block missing reasoning restore (drift?)"

_drive_restore() {
  local _ORIGINAL_WORKER_CODEX_REASONING="" _ORIGINAL_WORKER_MODEL=""
  local WORKER_MODEL="" WORKER_ENGINE="" WORKER_CODEX_MODEL="" WORKER_CODEX_REASONING=""
  local _MODEL_UPGRADED=0 _SAME_US_FAIL_COUNT=0
  eval "$_restore_block"
  print -r -- "OWCR=$_ORIGINAL_WORKER_CODEX_REASONING WCR=$WORKER_CODEX_REASONING OWM=$_ORIGINAL_WORKER_MODEL"
}
_out=$(_drive_restore)
[[ "$_out" == *"OWCR=medium"* ]] \
  && ok "restore: _ORIGINAL_WORKER_CODEX_REASONING rehydrated from status.json ($_out)" || no "reasoning not restored ($_out)"

# =============================================================================
# (3) restore-on-pass yields ORIGINAL non-empty effort, keeps-current on empty
# =============================================================================
_pass_block=$(awk '/if \(\( _MODEL_UPGRADED \)\); then/,/^            fi$/' "$RUN")
[[ -n "$_pass_block" ]] && print -r -- "$_pass_block" | grep -q 'WORKER_CODEX_REASONING' \
  && ok "restore-on-pass block extracted" || no "restore-on-pass block not found (drift?)"

_drive_pass() {  # $1 original effort ; returns final WORKER_CODEX_REASONING
  local _MODEL_UPGRADED=1 ITERATION=1
  local WORKER_ENGINE="codex" WORKER_MODEL="gpt-5.6-terra:medium"
  local WORKER_CODEX_MODEL="gpt-5.6-terra" WORKER_CODEX_REASONING="medium"
  local _ORIGINAL_WORKER_MODEL="gpt-5.6-terra" _ORIGINAL_WORKER_CODEX_REASONING="$1"
  eval "$_pass_block"
  print -r -- "$WORKER_CODEX_REASONING"
}
[[ "$(_drive_pass high)" == "high" ]] \
  && ok "restore-on-pass: non-empty original → WORKER_CODEX_REASONING restored to 'high'" || no "pass-restore did not apply original effort"
# empty original → keep the current effort ('medium'), never assign empty
[[ "$(_drive_pass '')" == "medium" ]] \
  && ok "restore-on-pass: EMPTY original → keeps current effort 'medium' (never empty)" || no "pass-restore assigned empty effort (the bug)"

# =============================================================================
# (4) _require_codex_effort guard
# =============================================================================
REC="$TMPDIR_T/guardrec"
: > "$REC"
# empty effort → writes blocked sentinel + exit 1 (subshell captures the exit).
( write_blocked_sentinel(){ print -r -- "BLOCKED:$1|cat=$3" >> "$REC"; }
  _require_codex_effort "" "worker-dispatch"
  print "SHOULD_NOT_REACH" >> "$REC" ) ; _grc=$?
{ [[ "$_grc" != 0 ]] && grep -q 'BLOCKED:' "$REC" && ! grep -q 'SHOULD_NOT_REACH' "$REC" } \
  && ok "guard: empty effort → blocked sentinel + non-zero exit (fail-fast)" || no "guard did not fail-fast on empty (rc=$_grc)"
grep -q 'cat=infra_failure' "$REC" && ok "guard: empty-effort block is infra_failure" || no "guard block wrong category"

_g_ok=$( ( write_blocked_sentinel(){ :; }; _require_codex_effort "high" "worker-dispatch" && print "PASS_THROUGH" ) )
[[ "$_g_ok" == "PASS_THROUGH" ]] \
  && ok "guard: non-empty effort → returns 0, no exit" || no "guard wrongly tripped on non-empty ('$_g_ok')"

# structural: every codex assembly site is guarded (8 sites → 8 guard calls).
_n_guard=$(grep -c '_require_codex_effort ' "$RUN")
(( _n_guard >= 8 )) && ok "structural: _require_codex_effort called at >=8 assembly sites (got $_n_guard)" || no "guard call sites incomplete (got $_n_guard)"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
