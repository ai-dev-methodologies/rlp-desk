#!/usr/bin/env zsh
# W6 text/contract pins (review-1 ledger rows C-RD/R1-06, R1-07, R1-08).
#   D1  the retired-model warning (lib _normalize_model_spec, run-side remap) reads exactly
#       `[model-remap] WARNING: '<value>' is retired — using '<normalized>' instead.`
#       (no promise of a pin the code never reads); verified by running the lib function and
#       by a source scan of run_ralph_desk.zsh.
#   D2  no shipped doc/script promises "pin the old id in ~/.claude/rlp-desk-models.json".
#   D3  R1-07: docs say a retired spark consensus model remaps to gpt-6-luna and its level is
#       then validated against gpt-6-luna (spark:minimal is rejected) — probed live first.
#   D4  R1-08: governance.md names no retired gpt-5.5 / gpt-5.4 / spark as a live example or
#       test target ("spark ceiling", "codex 5.4, spark", gpt-5.3-codex-spark:medium).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
CMD="$REPO/src/commands/rlp-desk.md"
README="$REPO/README.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

print -r -- "== D1: warning text =="
err=$(zsh -c 'source "$1"; _normalize_model_spec "gpt-5.5:high" >/dev/null' _ "$LIB" 2>&1 >/dev/null)
want="[model-remap] WARNING: 'gpt-5.5:high' is retired — using 'gpt-6.1-sol:high' instead."
[[ "$err" == "$want" ]] && ok "D1a lib warning is exactly the bare sentence" || no "D1a lib warning: [$err]"
line=$(grep -n 'print -u2.*\[model-remap\] WARNING' "$RUN")
if [[ $(print -r -- "$line" | wc -l | tr -d ' ') == 1 ]] \
   && [[ "$line" == *"is retired — using '\${_adn_new}' instead.\""* ]] \
   && [[ "$line" != *"To keep"* && "$line" != *"rlp-desk-models.json"* ]]; then
  ok "D1b run-side remap warning ends at 'instead.'"
else no "D1b run-side warning: $line"; fi

print -r -- "== D2: no pin-the-old-id promise anywhere =="
hits=$(grep -n -i -E "pin (it|the old id)|keep the old id|API-key logins" "$README" "$CMD" "$GOV" "$LIB" "$RUN" "$REPO/src/scripts/init_ralph_desk.zsh" 2>/dev/null | cut -c1-200)
[[ -z "$hits" ]] && ok "D2 no 'pin the old id' / 'keep the old id' / 'API-key logins' promise" || no "D2 promise remains:"$'\n'"$(print -r -- "$hits" | sed 's/^/      /')"

print -r -- "== D3: spark consensus wording is accurate =="
# probe: the level is validated against gpt-6-luna after the remap
probe=$(zsh -c 'source "$1"; v=spark:minimal; _validate_consensus_model_var v ctx >/dev/null 2>&1; echo "min=$?"; v=spark:high; _validate_consensus_model_var v ctx >/dev/null 2>&1; echo "high=$? $v"' _ "$LIB")
[[ "$probe" == *"min=1"* && "$probe" == *"high=0 gpt-6-luna:high"* ]] && ok "D3a probe: spark:minimal rejected, spark:high -> gpt-6-luna:high" || no "D3a probe: $probe"
for f in "$GOV" "$CMD"; do
  ln=$(grep -n -E 'retired .?spark|`spark` is a retired' "$f" | grep -i -E 'consensus' )
  if [[ -n "$ln" ]] && print -r -- "$ln" | grep -q 'spark:minimal' && print -r -- "$ln" | grep -qi 'validated against .\?gpt-6-luna'; then
    ok "D3 ${f:t} says the level is validated against gpt-6-luna (spark:minimal rejected)"
  else no "D3 ${f:t} spark consensus line lacks the validated-against-gpt-6-luna / spark:minimal wording: $ln"; fi
done
bad=$(grep -n -i 'not rejected' "$GOV" "$CMD" | cut -c1-160)
[[ -z "$bad" ]] && ok "D3c no unqualified 'not rejected' claim" || no "D3c: $bad"

print -r -- "== D4: governance.md uses no retired example =="
g=$(grep -n -E 'gpt-5\.5|gpt-5\.4|spark ceiling|codex 5\.4|codex-spark' "$GOV" | cut -c1-200)
[[ -z "$g" ]] && ok "D4 governance.md has no gpt-5.5 / gpt-5.4 / spark-ceiling / codex-spark text" || no "D4 retired text in governance.md:"$'\n'"$(print -r -- "$g" | sed 's/^/      /')"

print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
