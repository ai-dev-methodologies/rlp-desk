#!/bin/zsh
# ============================================================================
# Model-upgrade ladder — deterministic E2E of the REAL lib functions.
#
# The worker model-upgrade ladder (check_model_upgrade / get_next_model /
# get_model_string / record_us_failure, in lib_ralph_desk.zsh) is exercised
# only when the SAME US fails >= 2 consecutive times — a path that natural
# dogfoods rarely hit (a competent worker passes within one fix). This test
# SOURCES the actual lib functions (extracted at file scope) and drives the
# full ladder deterministically: climb, ceiling, reset-on-pass, codex path,
# lock-worker-model, and the same-US-vs-different-US counter semantics.
#
# Not a mirror — it runs the real function bodies from src/scripts/lib_ralph_desk.zsh.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }
print -P "%F{cyan}Model-upgrade ladder (real lib functions)%f"

LIB="${0:A:h:h:h}/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print "FATAL: lib not found at $LIB"; exit 1; }

# Stub the leader logging the functions call (file-scope, before sourcing).
log() { : }
log_debug() { : }
log_error() { : }
ITERATION=1
typeset -gA US_FAIL_HISTORY

# US-001: get_next_model resolves its shipped ladder (src/node/models.json)
# relative to $LIB_DIR — normally set by run_ralph_desk.zsh before sourcing
# the lib. This harness sources the ladder functions standalone, so LIB_DIR
# must be set explicitly to the real source-checkout script dir, or shipped
# resolution fails and every call silently falls back to the 3-entry
# emergency ladder (which lacks the codex entries this test exercises).
LIB_DIR="${0:A:h:h:h}/src/scripts"
# Hermeticity (Codex P2-1): get_next_model also checks
# ${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json} — guard against
# a real override file on the machine running this test silently winning
# over the shipped defaults this test asserts on.
RLP_DESK_MODELS_FILE="/nonexistent-hermetic-test-guard/rlp-desk-models.json"

# Extract ONLY the ladder functions (get_model_string, get_next_model,
# check_model_upgrade, record_us_failure) and source them at FILE scope
# (lib's funcstack source-guard requires file scope; extracting just these
# functions avoids pulling the whole lib's global/dependency surface).
# Function-name based, not a line range — drift-proof against the lib's
# functions moving around as it grows (top-level functions close with a
# `}` at column 0).
_LADDER_SRC=$(mktemp -t ladder-fns.XXXXXX.zsh)
for _fn in get_model_string get_next_model check_model_upgrade record_us_failure; do
  awk "/^${_fn}\(\)/{f=1} f{print} f&&/^\}/{f=0}" "$LIB" >> "$_LADDER_SRC"
done
source "$_LADDER_SRC"
rm -f "$_LADDER_SRC"

# Sanity: real functions are loaded
for fn in get_model_string get_next_model check_model_upgrade record_us_failure; do
  (( $+functions[$fn] )) || { no "real lib function '$fn' not loaded"; print "  (cannot run ladder test)"; exit 1; }
done
ok "real lib ladder functions sourced from lib_ralph_desk.zsh"

# ---- get_next_model: the documented ladders ----
[[ "$(get_next_model haiku)" == sonnet && "$(get_next_model sonnet)" == opus && -z "$(get_next_model opus)" ]] \
  && ok "claude ladder: haiku→sonnet→opus→ceiling" || no "claude ladder wrong"
[[ "$(get_next_model gpt-5.5:low)" == gpt-5.5:medium && "$(get_next_model gpt-5.5:medium)" == gpt-5.5:high && "$(get_next_model gpt-5.5:high)" == gpt-5.5:xhigh && -z "$(get_next_model gpt-5.5:xhigh)" ]] \
  && ok "codex gpt-5.5 ladder: low→medium→high→xhigh→ceiling" || no "codex gpt-5.5 ladder wrong"
[[ "$(get_next_model gpt-5.3-codex-spark:high)" == gpt-5.3-codex-spark:xhigh && -z "$(get_next_model gpt-5.3-codex-spark:xhigh)" ]] \
  && ok "codex spark ladder ceiling at xhigh" || no "codex spark ladder wrong"
[[ -z "$(get_next_model some-unknown-model)" ]] \
  && ok "unknown model → ceiling (no upgrade, safe)" || no "unknown model not treated as ceiling"
[[ "$(get_next_model gpt-5.6-luna:high)" == gpt-5.6-luna:max \
   && "$(get_next_model gpt-5.6-luna:xhigh)" == gpt-5.6-luna:max \
   && "$(get_next_model gpt-5.6-luna:max)" == gpt-5.6-terra:max \
   && "$(get_next_model gpt-5.6-terra:max)" == gpt-5.6-sol:xhigh ]] \
  && ok "luna-first chain: luna:high→luna:max→terra:max→sol:xhigh" || no "luna-first chain wrong"
[[ "$(get_next_model gpt-5.6-terra:xhigh)" == gpt-5.6-sol:high && -z "$(get_next_model gpt-5.6-sol:xhigh)" ]] \
  && ok "terra:xhigh→sol:high jump and sol:xhigh ceiling unchanged" || no "unchanged entries regressed"

# ---- check_model_upgrade: claude worker climbs on same-US double fail ----
WORKER_ENGINE=claude; WORKER_MODEL=haiku; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
LOCK_WORKER_MODEL=0; _MODEL_UPGRADED=0; _ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""
_SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""
check_model_upgrade US-001   # fail#1: count=1, no upgrade
[[ "$WORKER_MODEL" == haiku && $_MODEL_UPGRADED -eq 0 ]] && ok "claude: 1st same-US fail → NO upgrade (haiku)" || no "claude 1st fail upgraded early (model=$WORKER_MODEL)"
check_model_upgrade US-001   # fail#2: count=2 → upgrade haiku→sonnet, reset
[[ "$WORKER_MODEL" == sonnet && $_MODEL_UPGRADED -eq 1 && "$_ORIGINAL_WORKER_MODEL" == haiku ]] && ok "claude: 2nd same-US fail → upgrade haiku→sonnet (_MODEL_UPGRADED=1, orig saved)" || no "claude 2nd fail upgrade wrong (model=$WORKER_MODEL up=$_MODEL_UPGRADED orig=$_ORIGINAL_WORKER_MODEL)"
check_model_upgrade US-001   # count=1 again (reset), no upgrade
[[ "$WORKER_MODEL" == sonnet ]] && ok "claude: counter reset after upgrade (3rd fail → still sonnet)" || no "claude 3rd fail (model=$WORKER_MODEL)"
check_model_upgrade US-001   # count=2 → upgrade sonnet→opus
[[ "$WORKER_MODEL" == opus ]] && ok "claude: 4th same-US fail → upgrade sonnet→opus" || no "claude 4th fail (model=$WORKER_MODEL)"
check_model_upgrade US-001; check_model_upgrade US-001   # count→2 at opus → ceiling, no upgrade
[[ "$WORKER_MODEL" == opus ]] && ok "claude: at opus ceiling → NO further upgrade (CB will BLOCK)" || no "claude ceiling broke (model=$WORKER_MODEL)"

# ---- different US resets the same-US counter (no premature upgrade) ----
WORKER_MODEL=haiku; _MODEL_UPGRADED=0; _ORIGINAL_WORKER_MODEL=""; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""
check_model_upgrade US-001   # count=1
check_model_upgrade US-002   # DIFFERENT US → count reset to 1
check_model_upgrade US-003   # DIFFERENT US → count reset to 1
[[ "$WORKER_MODEL" == haiku && $_MODEL_UPGRADED -eq 0 ]] \
  && ok "different-US failures do NOT accumulate → no upgrade (3 distinct US fails, still haiku)" || no "different-US wrongly upgraded (model=$WORKER_MODEL)"

# ---- LOCK_WORKER_MODEL disables the ladder ----
WORKER_MODEL=haiku; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; LOCK_WORKER_MODEL=1
check_model_upgrade US-001; check_model_upgrade US-001; check_model_upgrade US-001
[[ "$WORKER_MODEL" == haiku && $_MODEL_UPGRADED -eq 0 ]] \
  && ok "LOCK_WORKER_MODEL=1 → ladder disabled (haiku stays despite repeated same-US fails)" || no "lock-worker-model ignored (model=$WORKER_MODEL)"
LOCK_WORKER_MODEL=0

# ---- codex worker climbs and splits model:reasoning correctly ----
WORKER_ENGINE=codex; WORKER_MODEL=gpt-5.5; WORKER_CODEX_MODEL=gpt-5.5; WORKER_CODEX_REASONING=medium
_MODEL_UPGRADED=0; _ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""
check_model_upgrade US-001; check_model_upgrade US-001   # count=2 → gpt-5.5:medium → gpt-5.5:high
[[ "$WORKER_CODEX_MODEL" == gpt-5.5 && "$WORKER_CODEX_REASONING" == high && "$WORKER_MODEL" == gpt-5.5 ]] \
  && ok "codex: 2nd same-US fail → gpt-5.5:medium→high (model/reasoning split correct)" || no "codex upgrade split wrong (m=$WORKER_CODEX_MODEL r=$WORKER_CODEX_REASONING)"

# ---- record_us_failure: cumulative per-US history (persists across phases) ----
typeset -gA US_FAIL_HISTORY; US_FAIL_HISTORY=()
record_us_failure US-001; record_us_failure US-001; record_us_failure US-002
[[ "${US_FAIL_HISTORY[US-001]}" -eq 2 && "${US_FAIL_HISTORY[US-002]}" -eq 1 ]] \
  && ok "record_us_failure: per-US cumulative count (US-001=2, US-002=1)" || no "record_us_failure count wrong (001=${US_FAIL_HISTORY[US-001]:-?} 002=${US_FAIL_HISTORY[US-002]:-?})"
record_us_failure unknown; record_us_failure ""
[[ -z "${US_FAIL_HISTORY[unknown]:-}" ]] && ok "record_us_failure: 'unknown'/empty us_id ignored" || no "record_us_failure logged unknown"

# ---- D-5/D-5b relaunch restore CONTRACT: every field the restore block READS
#      must be a field update_status WRITES (else a rename silently makes the
#      crash-relaunch restore dead — model-upgrade state lost, CB reset to 0). ----
RUN="${0:A:h:h:h}/src/scripts/run_ralph_desk.zsh"
# The 9 fields the restore block (run_ralph_desk.zsh, D-5/D-5b) reads from status.json:
_restore_reads=(consecutive_blocks last_block_reason model_upgraded same_us_fail_count
                original_worker_model worker_model worker_engine worker_codex_model worker_codex_reasoning)
_missing_write=""
for _f in $_restore_reads; do
  # restore side actually reads it
  grep -qE "jq -r '\.$_f " "$RUN" || { no "D-5b contract: restore does not read .$_f (test stale?)"; _missing_write=1; continue; }
  # write side (update_status in lib) must persist it
  grep -qE "\"$_f\":" "$LIB" || { no "D-5b contract: update_status does NOT write '$_f' → restore reads it as empty → restore SILENTLY DEAD"; _missing_write=1; }
done
[[ -z "$_missing_write" ]] && ok "D-5/D-5b restore contract: all 9 restore-read fields are persisted by update_status (no silent-dead restore)"
# restore predicate logic mirror: model_upgraded==1 AND worker_model+worker_engine present → restore fires
restore_fires(){ local mu="$1" wm="$2" we="$3"; [[ "$mu" == "1" && -n "$wm" && -n "$we" ]] && print FIRE || print SKIP }
[[ "$(restore_fires 1 sonnet claude)" == FIRE && "$(restore_fires 0 sonnet claude)" == SKIP && "$(restore_fires 1 '' claude)" == SKIP && "$(restore_fires 1 sonnet '')" == SKIP ]] \
  && ok "D-5b restore predicate: fires only when model_upgraded==1 AND worker_model+engine present (fresh campaign keeps CLI model)" || no "D-5b restore predicate logic"
# CB restore is atomic: count AND reason, or neither (D-5)
cb_restore(){ local cb="$1" lbr="$2"; [[ "$cb" == <-> && "$cb" -gt 0 && -n "$lbr" ]] && print "RESTORE($cb)" || print SKIP }
[[ "$(cb_restore 3 'metric: wall')" == 'RESTORE(3)' && "$(cb_restore 3 '')" == SKIP && "$(cb_restore 0 'x')" == SKIP && "$(cb_restore abc 'x')" == SKIP ]] \
  && ok "D-5 CB restore atomic: count>0 AND non-empty reason required (half-state rejected)" || no "D-5 CB restore atomicity"

print ""
if (( FAIL == 0 )); then print -P "%F{green}Model-upgrade ladder: $PASS/$((PASS+FAIL)) PASS%f"; else print -P "%F{red}Model-upgrade ladder: $PASS pass, $FAIL FAIL%f"; fi
exit $(( FAIL > 0 ))
