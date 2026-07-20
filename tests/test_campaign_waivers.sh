#!/usr/bin/env zsh
# US-002 — first-class campaign-scope waiver mechanism: zsh behavioral tests.
#
# Sources the REAL lib helpers (load_campaign_waivers, _waiver_reject,
# _emit_waiver_contract) and drives the SHARED parity matrix
# (tests/fixtures/campaign-waivers/matrix.json — the same matrix
# tests/node/test-campaign-waivers.test.mjs feeds the Node loader) against REAL
# temp files with REAL shasum -a 256 hashes. Also exercises the prompt-injection
# helper (single source, verifier-only citation instruction) and the status.json
# block-reason folding (AC2.2a).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
MATRIX="$REPO/tests/fixtures/campaign-waivers/matrix.json"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

BOGUS="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
STALE="cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Materialize a matrix scenario into a real temp dir. Prints a tab line:
#   <root>\t<waivers_path>\t<slug>\t<expected_sha>
build_scenario(){
  local idx="$1"
  local R="$TMP/scn$idx"; mkdir -p "$R/.rlp-desk/plans/baseline"
  local slug fileShape schema auth
  slug=$(jq -r ".scenarios[$idx].slug" "$MATRIX")
  fileShape=$(jq -r ".scenarios[$idx].fileShape" "$MATRIX")
  schema=$(jq -r ".scenarios[$idx].schema" "$MATRIX")
  auth=$(jq -r ".scenarios[$idx].auth" "$MATRIX")
  local w_id w_slug w_gate w_fid w_reason
  w_id=$(jq -r ".scenarios[$idx].waiver.id" "$MATRIX")
  w_slug=$(jq -r ".scenarios[$idx].waiver.campaign_slug" "$MATRIX")
  w_gate=$(jq -r ".scenarios[$idx].waiver.gate" "$MATRIX")
  w_fid=$(jq -r ".scenarios[$idx].waiver.finding_id" "$MATRIX")
  w_reason=$(jq -r ".scenarios[$idx].waiver.reason" "$MATRIX")
  local a_present a_gate a_recorded
  a_present=$(jq -r ".scenarios[$idx].artifact.present" "$MATRIX")
  a_gate=$(jq -r ".scenarios[$idx].artifact.gate" "$MATRIX")
  a_recorded=$(jq -r ".scenarios[$idx].artifact.recordedSha" "$MATRIX")

  local artRel=".rlp-desk/plans/baseline/${a_gate}.json"
  local artAbs="$R/$artRel"
  local recordedSha="$BOGUS"
  if [[ "$a_present" == "true" ]]; then
    local findings
    findings=$(jq -c ".scenarios[$idx].artifact.findings | map({finding_id: ., severity:\"high\"})" "$MATRIX")
    jq -n --arg g "$a_gate" --argjson f "$findings" \
      '{gate:$g, captured_at:"2026-07-20T00:00:00Z", findings:$f}' > "$artAbs"
    [[ "$a_recorded" == "match" ]] && recordedSha=$(shasum -a 256 "$artAbs" | awk '{print $1}')
  fi

  local waiverJson
  if [[ "$schema" == "drop-reason" ]]; then
    waiverJson=$(jq -n --arg id "$w_id" --arg cs "$w_slug" --arg g "$w_gate" --arg fid "$w_fid" \
      --arg ap "$artRel" --arg as "$recordedSha" \
      '{id:$id, campaign_slug:$cs, gate:$g, finding_id:$fid, baseline_artifact_path:$ap, baseline_artifact_sha256:$as}')
  else
    waiverJson=$(jq -n --arg id "$w_id" --arg cs "$w_slug" --arg g "$w_gate" --arg fid "$w_fid" \
      --arg ap "$artRel" --arg as "$recordedSha" --arg r "$w_reason" \
      '{id:$id, campaign_slug:$cs, gate:$g, finding_id:$fid, baseline_artifact_path:$ap, baseline_artifact_sha256:$as, reason:$r}')
  fi

  local waiversPath="$R/.rlp-desk/plans/waivers.json"
  case "$fileShape" in
    not-array)    echo '{"not":"array"}' > "$waiversPath" ;;
    invalid-json) echo '{ not json'      > "$waiversPath" ;;
    *)            jq -n --argjson w "$waiverJson" '[$w]' > "$waiversPath" ;;
  esac
  local actualSha; actualSha=$(shasum -a 256 "$waiversPath" | awk '{print $1}')
  local expected=""
  case "$auth" in
    match)  expected="$actualSha" ;;
    stale)  expected="$STALE" ;;
    absent) expected="" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$R" "$waiversPath" "$slug" "$expected"
}

# Invoke the REAL load_campaign_waivers in a clean sourced-lib zsh.
run_load(){ # $1=root $2=waivers_path $3=slug $4=expected_sha
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$1"'"
    load_campaign_waivers "'"$2"'" "'"$3"'" "'"$4"'" "'"$1"'"
    print "HONORED=${#WAIVERS_HONORED_LINES} SUMMARY=[${WAIVER_REJECTION_SUMMARY}] AUTHSHA=[${WAIVERS_AUTHORIZED_SHA:-}]"
  '
}

print -r -- "== shared parity matrix (zsh load_campaign_waivers vs real files) =="
_n=$(jq '.scenarios | length' "$MATRIX")
for (( i=0; i<_n; i++ )); do
  name=$(jq -r ".scenarios[$i].name" "$MATRIX")
  eHon=$(jq -r ".scenarios[$i].expect.honored" "$MATRIX")
  eReason=$(jq -r ".scenarios[$i].expect.reason" "$MATRIX")
  line=$(build_scenario "$i")
  R="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  WP="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  SLUG="${rest%%$'\t'*}"; EXP="${rest#*$'\t'}"
  out=$(run_load "$R" "$WP" "$SLUG" "$EXP")
  if [[ "$eHon" == "true" ]]; then
    if [[ "$out" == *"HONORED=1"* && "$out" == *"SUMMARY=[]"* ]]; then
      ok "$name → honored (no rejection)"
    else
      no "$name — expected HONORED=1 empty summary; got: $out"
    fi
  else
    # rejected: zero honored + the summary names the expected reason with the id
    if [[ "$out" == *"HONORED=0"* && "$out" == *"($eReason)"* ]]; then
      ok "$name → rejected ($eReason)"
    else
      no "$name — expected HONORED=0 reason=$eReason; got: $out"
    fi
  fi
done

print -r -- "== absent waivers.json → zero waivers, no rejection (AC2.4a) =="
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }
  ROOT="'"$TMP"'"
  load_campaign_waivers "'"$TMP"'/nope.json" camp "" "'"$TMP"'"
  print "HONORED=${#WAIVERS_HONORED_LINES} SUMMARY=[${WAIVER_REJECTION_SUMMARY}]"
')
[[ "$out" == *"HONORED=0"* && "$out" == *"SUMMARY=[]"* ]] \
  && ok "absent file → zero waivers, no rejection" \
  || no "absent file should be a clean no-op (got: $out)"

print -r -- "== _emit_waiver_contract: single source, verifier-only citation (AC2.6/2.7) =="
wout=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  WAIVERS_HONORED_LINES=("W-1|audit|CVE-1|pre-existing high vuln")
  _emit_waiver_contract worker
')
vout=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  WAIVERS_HONORED_LINES=("W-1|audit|CVE-1|pre-existing high vuln")
  _emit_waiver_contract verifier
')
[[ "$wout" == *"## CAMPAIGN WAIVERS"* && "$wout" == *"Waiver \`W-1\`: gate=audit finding_id=CVE-1"* ]] \
  && ok "worker section emits the honored waiver line" \
  || no "worker section missing waiver line (got: $wout)"
[[ "$wout" != *"MUST cite"* ]] \
  && ok "worker section omits the verdict-cite-id instruction" \
  || no "worker section should NOT carry the citation instruction"
[[ "$vout" == *"## CAMPAIGN WAIVERS"* && "$vout" == *"MUST cite the waiver id"* ]] \
  && ok "verifier section carries the AC2.7 citation instruction" \
  || no "verifier section missing citation instruction (got: $vout)"

print -r -- "== empty honored set → _emit_waiver_contract emits nothing =="
eout=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  WAIVERS_HONORED_LINES=()
  _emit_waiver_contract worker
')
[[ -z "$eout" ]] && ok "no honored waivers → no section" || no "empty set should emit nothing (got: $eout)"

print -r -- "== AC2.2a: rejections fold into status.json last_block_reason on BLOCK =="
STATUS="$TMP/status.json"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }
  SLUG=camp; BASELINE_COMMIT=none; ITERATION=3; MAX_ITER=5
  WORKER_MODEL=haiku; VERIFIER_MODEL=sonnet; WORKER_ENGINE=claude; VERIFIER_ENGINE=claude
  WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""
  VERIFY_MODE=per-us; CONSENSUS_MODE=off; CONSECUTIVE_FAILURES=1; CONSECUTIVE_BLOCKS=1
  VERIFIED_US=""; LAST_BLOCK_REASON="pre_gate_failed"; ITER_START_HEAD=""
  WAIVER_REJECTION_SUMMARY="waiver W-7 rejected (unauthorized_hash_change)"
  STATUS_FILE="'"$STATUS"'"
  update_status blocked blocked
  jq -r ".last_block_reason" "'"$STATUS"'"
')
[[ "$out" == *"pre_gate_failed"* && "$out" == *"waiver W-7 rejected (unauthorized_hash_change)"* ]] \
  && ok "block reason folds base reason + waiver rejection summary" \
  || no "status block reason missing waiver summary (got: $out)"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
