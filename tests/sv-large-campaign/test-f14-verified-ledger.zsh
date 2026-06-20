#!/bin/zsh
# ============================================================================
# F-14 regression: VERIFIED_US must be restorable from a durable, structured,
# append-only ledger (drift-proof leader output) instead of sed-parsing the
# Worker's prose "## Completed Stories" (fresh-context LLM output that can drift).
# Mirrors the _append_verified_ledger writer + the ledger-primary restore query
# in run_ralph_desk.zsh. Restore is robust to a corrupt/partial trailing line.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

ITERATION=1
# mirror of the writer
_append_verified_ledger(){
  local us="$1"
  [[ -z "$us" || "$us" == "ALL" ]] && return 0
  printf '{"us_id":"%s","iter":%s,"verified_at":"x"}\n' "$us" "${ITERATION:-0}" >> "$VERIFIED_LEDGER"
}
# mirror of the restore query (robust to corrupt lines via fromjson?)
restore_from_ledger(){ jq -rR 'fromjson? | .us_id // empty' "$1" 2>/dev/null | grep -E '^US-[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//'; }

print -P "%F{cyan}F-14 durable verified-US ledger regression%f"
D=$(mktemp -d); VERIFIED_LEDGER="$D/verified.jsonl"

# writer: append US-001, US-002, dup US-001, then ALL + empty (must be skipped)
_append_verified_ledger US-001
_append_verified_ledger US-002
_append_verified_ledger US-001
_append_verified_ledger ALL
_append_verified_ledger ""

[[ $(wc -l < "$VERIFIED_LEDGER") -eq 3 ]] \
  && ok "writer appends only real US (ALL + empty skipped): 3 lines" \
  || no "writer wrote $(wc -l < "$VERIFIED_LEDGER") lines (expected 3)"

[[ "$(restore_from_ledger "$VERIFIED_LEDGER")" == "US-001,US-002" ]] \
  && ok "restore yields distinct sorted US (dup collapsed): US-001,US-002" \
  || no "restore got '$(restore_from_ledger "$VERIFIED_LEDGER")'"

# inject a corrupt/partial trailing line (simulates a crash mid-append)
print -n '{"us_id":"US-003","iter' >> "$VERIFIED_LEDGER"
[[ "$(restore_from_ledger "$VERIFIED_LEDGER")" == "US-001,US-002" ]] \
  && ok "corrupt trailing line ignored — earlier valid US still restored (drift/crash-proof)" \
  || no "corrupt line broke restore: '$(restore_from_ledger "$VERIFIED_LEDGER")'"

# a complete US-003 line after recovery is then picked up
print '' >> "$VERIFIED_LEDGER"; _append_verified_ledger US-003
[[ "$(restore_from_ledger "$VERIFIED_LEDGER")" == "US-001,US-002,US-003" ]] \
  && ok "newly verified US-003 appended and restored alongside prior" \
  || no "US-003 not restored: '$(restore_from_ledger "$VERIFIED_LEDGER")'"

# empty/absent ledger → empty restore (falls through to prose/status in the runner)
: > "$VERIFIED_LEDGER"
[[ -z "$(restore_from_ledger "$VERIFIED_LEDGER")" ]] \
  && ok "empty ledger → empty restore (runner falls back to prose/status)" \
  || no "empty ledger returned '$(restore_from_ledger "$VERIFIED_LEDGER")'"

# Item-4 promotion: restore precedence ledger > status.json > prose (durable first)
cascade(){ local v="" l="$1" s="$2" p="$3"; [[ -z "$v" && -n "$l" ]] && v="$l"; [[ -z "$v" && -n "$s" ]] && v="$s"; [[ -z "$v" && -n "$p" ]] && v="$p"; print -r -- "$v"; }
[[ "$(cascade US-001,US-002 US-001 US-001)" == "US-001,US-002" ]] \
  && ok "precedence: ledger wins over status.json + prose" || no "ledger precedence broken"
[[ "$(cascade '' US-005 US-009)" == "US-005" ]] \
  && ok "precedence: status.json wins over prose when no ledger (Item-4 promotion)" || no "status>prose broken"
[[ "$(cascade '' '' US-009)" == "US-009" ]] \
  && ok "precedence: prose is the LAST resort (legacy only)" || no "prose fallback broken"

rm -rf "$D"
print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-14 durable ledger: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-14 durable ledger: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
