#!/usr/bin/env zsh
# IMP-01 — zsh-side verdict/transition normalizer: behavioral tests.
#
# Sources the REAL lib helper (_normalize_verdict) and drives the SHARED parity
# fixture (tests/fixtures/verdict-schema/verdict-string-cases.json — the same
# cases tests/node/test-verdict-schema-contract.test.mjs feeds through the Node
# normalizeVerdictString/normalizeTransitionString exports). Also exercises the
# exact production read-site expression (guard-critical null/empty preservation)
# and the F-23 transition-mode expression.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
FIXTURE="$REPO/tests/fixtures/verdict-schema/verdict-string-cases.json"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Invoke the REAL _normalize_verdict in a clean sourced-lib zsh (same invocation
# form the Node parity test shells).
_norm(){
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    _normalize_verdict "$1" "$2"
  ' _ "$1" "$2"
}

print -r -- "== fixture-driven: _normalize_verdict matches every shared case =="
n=$(jq 'length' "$FIXTURE")
for (( i=0; i<n; i++ )); do
  raw=$(jq -r ".[$i].raw" "$FIXTURE")
  field=$(jq -r ".[$i].field" "$FIXTURE")
  expected=$(jq -r ".[$i].expected" "$FIXTURE")
  got=$(_norm "$raw" "$field")
  if [[ "$got" == "$expected" ]]; then
    ok "case $i [$field] '$raw' -> '$got'"
  else
    no "case $i [$field] '$raw' -> got '$got' expected '$expected'"
  fi
done

print -r -- "== read-site behavioral: production verdict expression =="
# {"verdict":"PASS"} through the exact run_ralph_desk.zsh read expression -> pass
print -r -- '{"verdict":"PASS"}' > "$TMP/v.json"
got=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  VERDICT_FILE="'"$TMP"'/v.json"
  verdict=$(_normalize_verdict "$(jq -r ".verdict" "$VERDICT_FILE" 2>/dev/null)")
  print -r -- "$verdict"
')
[[ "$got" == "pass" ]] && ok "{\"verdict\":\"PASS\"} -> pass" || no "expected pass, got '$got'"

# missing file -> "" (empty preserved, A12/D-14 guard depends on it)
got=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  VERDICT_FILE="'"$TMP"'/does-not-exist.json"
  verdict=$(_normalize_verdict "$(jq -r ".verdict" "$VERDICT_FILE" 2>/dev/null)")
  print -r -- "[$verdict]"
')
[[ "$got" == "[]" ]] && ok "missing file -> empty preserved" || no "expected [], got '$got'"

# {"other":1} -> "null" (jq null for missing key; guard depends on exact "null")
print -r -- '{"other":1}' > "$TMP/o.json"
got=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  VERDICT_FILE="'"$TMP"'/o.json"
  verdict=$(_normalize_verdict "$(jq -r ".verdict" "$VERDICT_FILE" 2>/dev/null)")
  print -r -- "$verdict"
')
[[ "$got" == "null" ]] && ok "missing verdict field -> null preserved" || no "expected null, got '$got'"

print -r -- "== transition mode: F-23 recommended_state_transition expression =="
print -r -- '{"recommended_state_transition":"Done"}' > "$TMP/t.json"
got=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  VERDICT_FILE="'"$TMP"'/t.json"
  recommended=$(_normalize_verdict "$(jq -r ".recommended_state_transition" "$VERDICT_FILE" 2>/dev/null)" transition)
  print -r -- "$recommended"
')
[[ "$got" == "complete" ]] && ok "{recommended_state_transition:Done} -> complete" || no "expected complete, got '$got'"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
