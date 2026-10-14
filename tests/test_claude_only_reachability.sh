#!/usr/bin/env zsh
# F-DOC — the Claude-only table in src/model-upgrade-table.md must describe what
# the shipped ladder + circuit breaker actually do at the default CB_THRESHOLD=4.
#
# The table had `| HIGH | claude-sonnet-5-5:high | claude-opus-5-5:high (repeat
# until CB) | claude-opus-5-5:high (repeat until CB) |`: a HIGH start promotes at
# failure #2, the ceiling then fails #3 and #4, and the breaker blocks at #4, so
# the `5-6+` cell is never dispatched (same for CRITICAL, which starts AT the
# ceiling and plain-blocks at #4). Only LOW/MEDIUM reach `5-6` (the DEFECT-2a
# deferral gives the ceiling its own 2-attempt window: blocked at #6).
#
# This test WALKS the real check_model_upgrade() + the real circuit-breaker block
# (extracted from run_ralph_desk.zsh by content, like test_defect2_*.sh) for each
# Claude-only start row, then checks the doc against the walk:
#   W: the doc's "Reachability" table lists the walked BLOCKED-at failure number;
#   C: a main-table column starts with the model the walk dispatches at that
#      attempt when it is reached, and with "at CB 4: —" (never "repeat until CB";
#      the walk is at the default threshold, consensus doubles it) when the walk
#      never dispatches it.
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"; LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
DOC="$REPO/src/model-upgrade-table.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

extract_cb_block() { awk '/# Circuit breaker: consecutive failures/ { f=1 } f && $0 == "            update_status \"verifier\" \"fail\"" { exit } f { print }' "$1"; }
extract_fn() { awk -v fn="$1() {" 'index($0, fn) == 1 { f=1 } f { print; if ($0 == "}") exit }' "$2"; }
CB_TEXT="$(extract_cb_block "$RUN")"; CMU_TEXT="$(extract_fn check_model_upgrade "$LIB")"
GNM_TEXT="$(extract_fn get_next_model "$LIB")"; GMS_TEXT="$(extract_fn get_model_string "$LIB")"
[[ -n "$CB_TEXT" && -n "$CMU_TEXT" && -n "$GNM_TEXT" && -n "$GMS_TEXT" ]] && ok "extraction sanity: circuit-breaker block + check_model_upgrade/get_next_model/get_model_string found" || { no "extraction sanity: a real-source block was NOT found"; exit 1; }

# walk <start_model> <start_effort|-> <cb_threshold> -> "<blocked_at> <plain|architecture> <model per attempt, comma list>"
walk() {
  local sm="$1" se="$2" cbt="$3"; [[ "$se" == "-" ]] && se=""
  zsh -c "
    set -uo pipefail
    log() { :; }; log_error() { :; }; log_debug() { :; }
    write_blocked_sentinel() { _reason=\"\$1\"; }
    update_status() { :; }
    LIB_DIR='$REPO/src/scripts'; RLP_DESK_MODELS_FILE=/nonexistent-hermetic/x.json
    $GNM_TEXT
    $GMS_TEXT
    $CMU_TEXT
    _run_cb() {
      $CB_TEXT
    }
    WORKER_ENGINE=claude; WORKER_CODEX_MODEL=''; WORKER_CODEX_REASONING=''; WORKER_MODEL='$sm'; WORKER_EFFORT='$se'
    LOCK_WORKER_MODEL=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=''
    _ORIGINAL_WORKER_MODEL=''; _ORIGINAL_WORKER_CODEX_REASONING=''; _ORIGINAL_WORKER_EFFORT=''
    CONSECUTIVE_FAILURES=0; _CEILING_DEFERRAL_COUNT=0; CB_THRESHOLD=$cbt; EFFECTIVE_CB_THRESHOLD=$cbt; ITERATION=0
    models=''
    for (( i=1; i<=20; i++ )); do
      ITERATION=\$i
      models+=\"\${models:+,}\$WORKER_MODEL\${WORKER_EFFORT:+:\$WORKER_EFFORT}\"
      (( CONSECUTIVE_FAILURES++ ))
      check_model_upgrade US-001
      _cmu_deferred=0; _reason=''
      _run_cb
      if (( \$? == 1 )); then
        kind=plain; [[ \"\$_reason\" == architecture* ]] && kind=architecture
        echo \"\$i \$kind \$models\"; break
      fi
    done
  "
}

typeset -A START; START=( LOW "claude-haiku-5-5 medium" MEDIUM "claude-sonnet-5-5 medium" HIGH "claude-sonnet-5-5 high" CRITICAL "claude-opus-5-5 high" )
typeset -A BAT KIND MODELS
for row in LOW MEDIUM HIGH CRITICAL; do
  r="$(walk ${=START[$row]} 4)"; BAT[$row]="${r%% *}"; rest="${r#* }"; KIND[$row]="${rest%% *}"; MODELS[$row]="${rest#* }"
done
print -r -- "  walked (CB_THRESHOLD=4): LOW #${BAT[LOW]} MEDIUM #${BAT[MEDIUM]} HIGH #${BAT[HIGH]} CRITICAL #${BAT[CRITICAL]}"
[[ "${BAT[LOW]} ${BAT[MEDIUM]} ${BAT[HIGH]} ${BAT[CRITICAL]}" == "6 6 4 4" && "${KIND[HIGH]}" == architecture && "${KIND[CRITICAL]}" == plain ]] \
  && ok "walk sanity: LOW/MEDIUM block at #6, HIGH at #4 (architecture escalation), CRITICAL at #4 (plain breaker)" \
  || no "walk sanity: unexpected ladder behaviour — LOW=${BAT[LOW]} MEDIUM=${BAT[MEDIUM]} HIGH=${BAT[HIGH]}/${KIND[HIGH]} CRITICAL=${BAT[CRITICAL]}/${KIND[CRITICAL]} (expected 6 6 4 4; the doc and this test must be re-derived)"

# A raised threshold reaches the 5-6 column for HIGH (the doc says so).
r6="$(walk claude-sonnet-5-5 high 6)"
[[ "${r6%% *}" == "6" ]] && ok "walk: HIGH with CB_THRESHOLD=6 runs claude-opus-5-5:high through failure #6 (the 5-6+ column is reached only with a raised threshold)" || no "walk: HIGH with CB_THRESHOLD=6 blocked at '${r6%% *}' (want 6)"

# ---- W: the doc's reachability table -------------------------------------------------
SECTION="$(awk '/^## Claude-only/ {f=1; next} f && /^## / {exit} f' "$DOC")"
REACH="$(print -r -- "$SECTION" | awk '/^\*\*Reachability/ {f=1} f && /^\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {print}')"
MAIN="$(print -r -- "$SECTION" | awk '/^\*\*Reachability/ {exit} /^\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {print}')"
for row in LOW MEDIUM HIGH CRITICAL; do
  docat="$(print -r -- "$REACH" | awk -F'|' -v r="$row" '{x=$2; y=$4; gsub(/^ +| +$/,"",x); gsub(/^ +| +$/,"",y)} x==r {print y}')"
  [[ "$docat" == "${BAT[$row]}" ]] && ok "W $row: doc reachability table says BLOCKED at failure #${BAT[$row]} (matches the walk)" || no "W $row: doc says BLOCKED at '${docat:-<no reachability row>}', the real code blocks at #${BAT[$row]} (add/fix the 'Reachability' table row in src/model-upgrade-table.md)"
done

# ---- C: main-table columns (1-2 | 3-4 | 5-6+) ----------------------------------------
for row in LOW MEDIUM HIGH CRITICAL; do
  line="$(print -r -- "$MAIN" | awk -F'|' -v r="$row" '{x=$2; gsub(/^ +| +$/,"",x)} x==r {print}')"
  attempts=("${(@s:,:)MODELS[$row]}")
  for col in 1 2 3; do
    first=$(( (col-1)*2 + 1 ))
    cell="$(print -r -- "$line" | awk -F'|' -v c=$((col+2)) '{x=$c; gsub(/^ +| +$/,"",x); print x}')"
    if (( ${BAT[$row]} >= first )); then
      want="${attempts[$first]}"
      [[ -n "$want" && "$cell" == "$want"* ]] && ok "C $row col$col (attempt $first+): reached (blocked at #${BAT[$row]}), cell starts with the model the walk dispatches ($want)" || no "C $row col$col: attempt $first is dispatched (blocked at #${BAT[$row]}) as '$want' but the cell is '$cell'"
    else
      [[ "$cell" == "at CB 4: —"* && "$cell" != *"repeat until CB"* ]] && ok "C $row col$col (attempt $first+): unreached (blocked at #${BAT[$row]}), cell reads 'at CB 4: —' (the walk is at the default CB_THRESHOLD=4)" || no "C $row col$col: attempt $first is never dispatched (blocked at #${BAT[$row]}) but the cell is '$cell' (want 'at CB 4: — (not reached: BLOCKED at failure #${BAT[$row]})')"
    fi
  done
done

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
