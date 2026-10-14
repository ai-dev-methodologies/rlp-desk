#!/usr/bin/env zsh
# F-DOC-CODEX — the codex Sol / Terra / Luna tables in src/model-upgrade-table.md must describe what the
# shipped ladder + circuit breaker do at the default CB_THRESHOLD=4 (closes the deferred codex reachability audit).
# W: each section's "Reachability" table lists the walked BLOCKED-at failure number.
# C: a main-table column starts with the model the walk dispatches at that attempt when reached, and with
#    "at CB 4: —" (never "repeat until CB") when the walk never dispatches it.
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
[[ -n "$CB_TEXT" && -n "$CMU_TEXT" && -n "$GNM_TEXT" && -n "$GMS_TEXT" ]] && ok "extraction sanity" || { no "extraction sanity: real source blocks not found"; exit 1; }

# walk <model> <reasoning> <cb> -> "<blocked_at> <plain|architecture> <comma list of model:reasoning per attempt>"
walk() {
  local sm="$1" se="$2" cbt="$3"
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
    WORKER_ENGINE=codex; WORKER_CODEX_MODEL='$sm'; WORKER_CODEX_REASONING='$se'; WORKER_MODEL='$sm'; WORKER_EFFORT=''
    LOCK_WORKER_MODEL=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=''
    _ORIGINAL_WORKER_MODEL=''; _ORIGINAL_WORKER_CODEX_REASONING=''; _ORIGINAL_WORKER_EFFORT=''
    CONSECUTIVE_FAILURES=0; _CEILING_DEFERRAL_COUNT=0; CB_THRESHOLD=$cbt; EFFECTIVE_CB_THRESHOLD=$cbt; ITERATION=0
    models=''
    for (( i=1; i<=20; i++ )); do
      ITERATION=\$i
      models+=\"\${models:+,}\$WORKER_CODEX_MODEL:\$WORKER_CODEX_REASONING\"
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

# section header regex | main-table columns | "start model reasoning" per row | expected "BAT kind" per row
typeset -a SECTIONS=("sol" "terra" "luna")
typeset -A HDR NCOL EXPECT
HDR=( sol '^## GPT-6\.1 — Sol' terra '^## GPT-5\.6 — Terra' luna '^## GPT-6 — Luna' )
NCOL=( sol 4 terra 6 luna 3 )
typeset -A START
START=(
  sol/LOW "gpt-6.1-sol low"  sol/MEDIUM "gpt-6.1-sol medium"  sol/HIGH "gpt-6.1-sol medium"  sol/CRITICAL "gpt-6.1-sol high"
  terra/LOW "gpt-5.6-terra low"  terra/MEDIUM "gpt-5.6-terra medium"  terra/HIGH "gpt-5.6-terra high"  terra/CRITICAL "gpt-5.6-terra xhigh"
  luna/LOW "gpt-6-luna high"  luna/MEDIUM "gpt-6-luna xhigh"  luna/HIGH "gpt-6-luna max"  luna/CRITICAL "gpt-6.1-sol high"
)
EXPECT=(
  sol/LOW "4 plain" sol/MEDIUM "6 architecture" sol/HIGH "6 architecture" sol/CRITICAL "4 architecture"
  terra/LOW "4 plain" terra/MEDIUM "4 plain" terra/HIGH "4 plain" terra/CRITICAL "6 architecture"
  luna/LOW "6 architecture" luna/MEDIUM "6 architecture" luna/HIGH "4 architecture" luna/CRITICAL "4 architecture"
)
for sec in $SECTIONS; do
  SECTION="$(awk -v h="${HDR[$sec]}" '$0 ~ h {f=1; next} f && /^## / {exit} f' "$DOC")"
  REACH="$(print -r -- "$SECTION" | awk '/^\*\*Reachability/ {f=1} f && /^\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {print}')"
  MAIN="$(print -r -- "$SECTION" | awk '/^\*\*Reachability/ {exit} /^\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {print}')"
  [[ -n "$MAIN" && "$MAIN" != *gpt-5.6-sol* && "$MAIN" != *gpt-5.6-luna* ]] && ok "$sec main table: present, no older-generation sol/luna cell" || no "$sec main table missing or still names gpt-5.6-sol/luna"
  for row in LOW MEDIUM HIGH CRITICAL; do
    r="$(walk ${=START[$sec/$row]} 4)"; bat="${r%% *}"; rest="${r#* }"; kind="${rest%% *}"; models="${rest#* }"
    [[ "$bat $kind" == "${EXPECT[$sec/$row]}" ]] && ok "$sec $row walk sanity: '$bat $kind'" || no "$sec $row walk '$bat $kind', expected '${EXPECT[$sec/$row]}' (the doc and this test must be re-derived together)"
    docat="$(print -r -- "$REACH" | awk -F'|' -v r="$row" '{x=$2; y=$4; gsub(/^ +| +$/,"",x); gsub(/^ +| +$/,"",y)} x==r {print y}')"
    [[ "$docat" == "$bat" ]] && ok "$sec $row W: doc says BLOCKED at #$bat" || no "$sec $row W: doc says '${docat:-<no reachability row>}', walk says #$bat"
    line="$(print -r -- "$MAIN" | awk -F'|' -v r="$row" '{x=$2; gsub(/^ +| +$/,"",x)} x==r {print}')"
    attempts=("${(@s:,:)models}")
    for (( col=1; col<=${NCOL[$sec]}; col++ )); do
      first=$(( (col-1)*2 + 1 ))
      cell="$(print -r -- "$line" | awk -F'|' -v c=$((col+2)) '{x=$c; gsub(/^ +| +$/,"",x); print x}')"
      if (( bat >= first )); then
        want="${attempts[$first]}"      # full slug incl. generation: a cell naming an older generation cannot pass
        [[ -n "$want" && "$cell" == "$want"* ]] && ok "$sec $row col$col: reached, starts with $want" || no "$sec $row col$col: cell '$cell' must start with the full walked model '$want'"
      else
        [[ "$cell" == "at CB 4: —"* && "$cell" != *"repeat until CB"* ]] && ok "$sec $row col$col: unreached, reads 'at CB 4: —'" || no "$sec $row col$col: unreached (blocked at #$bat) but cell is '$cell'"
      fi
    done
  done
done
print -r -- ""; print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
