#!/bin/zsh
# ============================================================================
# run-matrix.zsh — drive the full 2×2 N×M self-verification matrix and emit a
# FAIL-CLOSED coverage ledger (results/matrix-<ts>.json).
#
# Cells (engine × role launch surface only — orthogonal axes are SEPARATE tests):
#   C1 W=codex  V=codex
#   C2 W=codex  V=claude
#   C3 W=claude V=codex
#   C4 W=claude V=claude   (production default; cheapest diagonal smoke)
#
# Usage:
#   RLP_REAL_LLM_GATE=1 ./run-matrix.zsh [cells]
#     cells: space/comma list e.g. "C4" or "C1,C4" (default: all 4)
#
# Overall = PASS ONLY IF count==4 AND all ran:true AND all outcome:PASS.
# Any BLOCKED/SKIPPED/missing ⇒ PARTIAL/BLOCKED — NEVER PASS. SERIAL by default
# (shared tmux server + shared rate limits; INV-8).
# ============================================================================
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
  print -u2 "run-matrix: RLP_REAL_LLM_GATE!=1 — refusing. (set RLP_REAL_LLM_GATE=1)"
  exit 2
fi

typeset -A WENG VENG
WENG=( C1 codex  C2 codex  C3 claude C4 claude )
VENG=( C1 codex  C2 claude C3 codex  C4 claude )
ALL_CELLS=(C1 C2 C3 C4)

# requested cells (default all)
REQ="${1:-C1 C2 C3 C4}"
REQ="${REQ//,/ }"
typeset -a CELLS
for c in ${(s: :)REQ}; do CELLS+=("$c"); done

TS="$(date +%Y%m%d-%H%M%S)"
LEDGER="$RESULTS_DIR/matrix-${TS}.json"

print "═══════════════════════════════════════════════════════════"
print " N×M SELF-VERIFICATION MATRIX  cells=(${CELLS[*]})  serial"
print "═══════════════════════════════════════════════════════════"

typeset -A CELL_RESULT_FILE
for cell in "${CELLS[@]}"; do
  w="${WENG[$cell]}"; v="${VENG[$cell]}"
  if [[ -z "$w" || -z "$v" ]]; then print -u2 "unknown cell $cell"; continue; fi
  print "\n>>> $cell  (W=$w V=$v)"
  "$SCRIPT_DIR/run-cell.zsh" "$cell" "$w" "$v" "$RESULTS_DIR" || true
  # newest cell-result.json for this cell
  rf="$(ls -dt "$RESULTS_DIR"/*-"$cell"-*/cell-result.json 2>/dev/null | head -1)"
  CELL_RESULT_FILE[$cell]="$rf"
done

# --- assemble FAIL-CLOSED ledger: exactly 4 keyed entries; cells not run = SKIPPED ---
entries="[]"
for cell in "${ALL_CELLS[@]}"; do
  w="${WENG[$cell]}"; v="${VENG[$cell]}"
  rf="${CELL_RESULT_FILE[$cell]:-}"
  if [[ -n "$rf" && -f "$rf" ]]; then
    entry="$(cat "$rf")"
  else
    entry="$(jq -n --arg cell "$cell" --arg w "$w" --arg v "$v" \
      '{cell_id:$cell, worker_engine:$w, verifier_engine:$v, ran:false,
        outcome:"SKIPPED", failing_rung:"not_requested"}')"
  fi
  entries="$(jq --argjson e "$entry" '. + [$e]' <<< "$entries")"
done

# overall verdict
overall="$(jq -r '
  if (length==4)
     and (map(.ran==true)|all)
     and (map(.outcome=="PASS")|all)
  then "PASS"
  elif (map(.outcome=="FAIL")|any) then "FAIL"
  else "PARTIAL" end' <<< "$entries")"

jq -n --argjson cells "$entries" --arg ov "$overall" --arg ts "$TS" \
  '{generated_at:$ts, overall:$ov, cell_count:($cells|length), cells:$cells}' \
  > "$LEDGER"

print "\n═══════════════════════════════════════════════════════════"
print " LEDGER: $LEDGER"
jq -r '.cells[] | "  \(.cell_id)  W=\(.worker_engine)/V=\(.verifier_engine)  ran=\(.ran)  \(.outcome)  rung=\(.failing_rung // "-")"' "$LEDGER"
print " OVERALL: $overall"
print "═══════════════════════════════════════════════════════════"

[[ "$overall" == "PASS" ]]
