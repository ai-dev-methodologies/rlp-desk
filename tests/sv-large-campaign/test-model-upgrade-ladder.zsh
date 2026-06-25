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
ITERATION=1
typeset -gA US_FAIL_HISTORY

# Extract ONLY the ladder functions (get_model_string..record_us_failure span)
# and source them at FILE scope (lib's funcstack source-guard requires file scope;
# extracting the span avoids pulling the whole lib's global/dependency surface).
_LADDER_SRC=$(mktemp -t ladder-fns.XXXXXX.zsh)
sed -n '121,236p' "$LIB" > "$_LADDER_SRC"
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

print ""
if (( FAIL == 0 )); then print -P "%F{green}Model-upgrade ladder: $PASS/$((PASS+FAIL)) PASS%f"; else print -P "%F{red}Model-upgrade ladder: $PASS pass, $FAIL FAIL%f"; fi
exit $(( FAIL > 0 ))
