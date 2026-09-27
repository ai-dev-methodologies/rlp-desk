#!/bin/zsh
# reaudit wave 4 (run_ralph_desk.zsh side) — adversarial-review findings
# H1, H3, M1, M2, M4, L4a, L4b.
#
# Every check below EXTRACTS the real production lines/functions out of
# run_ralph_desk.zsh (and sources the real lib functions from
# lib_ralph_desk.zsh) by content anchor and EXECUTES them against crafted
# fixtures — never retypes the logic under test. Reverting the corresponding
# fix in run_ralph_desk.zsh makes the affected assertions fail again (this
# was verified manually during development: each fix was toggled off once
# against this exact suite to confirm the RED behavior below).
set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); print -P "  %F{green}PASS%f: $1"; }
no() { FAIL=$((FAIL+1)); print -u2 -P "  %F{red}FAIL%f: $1"; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

vf() { # write a fixture file, print its path
  local name="$1" body="$2"
  local f="$TMPD/$name.json"
  print -r -- "$body" > "$f"
  print -r -- "$f"
}

# --- generic extraction helpers (real production code, never retyped) -----
extract_between() { # <exact start line> <end-marker substring> <src file>
  awk -v s="$1" -v e="$2" '
    c && index($0, e) { exit }
    $0 == s { c = 1 }
    c { print }
  ' "$3"
}
extract_marked() { # <start marker substring> <stop line exact regex> <src>
  awk -v start="$1" -v stopre="$2" '
    $0 ~ start { c=1 }
    c { print; if ($0 ~ stopre) exit }
  ' "$3"
}

echo "=== reaudit wave 4 (run side): H1 / H3 / M1 / M2 / M4 / L4 ==="

##############################################################################
# H1 — criteria_results override must suppress ALL per_us_results crediting
##############################################################################
echo ""
echo "--- H1: criteria override must stop per-US crediting ---"

H1_OVERRIDE_SNIPPET=$(extract_marked 'reaudit wave 1: make criteria_results LOAD-BEARING' '^        fi$' "$RUN")
H1_CREDIT_SNIPPET=$(extract_marked '# Parse per_us_results from verdict to track partial progress' '^            fi$' "$RUN")
[[ -n "$H1_OVERRIDE_SNIPPET" ]] || { no "H1 EXTRACT: override-decision snippet not found (marker text changed?)"; }
[[ -n "$H1_CREDIT_SNIPPET" ]] || { no "H1 EXTRACT: per_us_results credit snippet not found (marker text changed?)"; }

# round 5 P3 follow-up: extracted by content (not retyped) so the harnesses
# below exercise the SAME `.verdict // empty` read the production code
# actually runs, instead of a second hand-copied line that could silently
# drift from it (which is exactly what happened before this fix — the
# harnesses hardcoded a bare `.verdict` copy of this line before P3 added
# `// empty` to the real one). `local verdict=""` (this exact indent) is the
# unique anchor immediately preceding the real assignment; the OTHER
# `.verdict` read site (_final_verify_one_us) uses `local verdict` with no
# `=""` and 2-space indent, so this anchor cannot collide with it.
PROD_VERDICT_READ_LINE=$(grep -A1 -- '^        local verdict=""$' "$RUN" | tail -1)
[[ "$PROD_VERDICT_READ_LINE" == *'.verdict // empty'* ]] \
  || no "P3 EXTRACT: production verdict-read line not found or missing '// empty' (marker text changed?) — got: $PROD_VERDICT_READ_LINE"

h1_harness() { # $1=verdict_file $2=top_verdict $3=prior_verified_us
  local vfile="$1" top_verdict="$2" prior="${3:-}" hf="$TMPD/h1-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { echo "LOG: \$*"; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
_append_verified_ledger() { return 0; }
VERDICT_FILE='$vfile'
ITERATION=1
signal_us_id='US-002'
verdict='$top_verdict'
VERIFIED_US='$prior'
typeset -gA US_FIX_CONTRACT US_ATTEMPT_HISTORY
SETUP
  print -r -- "$H1_OVERRIDE_SNIPPET" >> "$hf"
  print -r -- "$H1_CREDIT_SNIPPET" >> "$hf"
  print -r -- 'echo "RESULT_VERIFIED_US=$VERIFIED_US"' >> "$hf"
  zsh "$hf" 2>&1
}

# Adversarial case: top-level pass, but one criterion met:false, AND the
# verdict also carries per_us_results claiming US-002 passed. The override
# must fire (H1's prerequisite) AND must prevent the per_us_results credit —
# crediting here would grant partial progress on a verdict this project's own
# load-bearing check just rejected as untrustworthy.
f=$(vf h1-override '{"verdict":"pass","us_id":"US-002","per_us_results":{"US-001":"pass","US-002":"pass"},"criteria_results":[{"criterion":"AC-2.1","met":false}]}')
out=$(h1_harness "$f" "pass" "")
echo "$out" | grep -q '^RESULT_VERIFIED_US=$' \
  && ok "1 override fired + per_us_results present -> NOT credited (VERIFIED_US stays empty)" \
  || no "1 override should have suppressed crediting (got: $out)"
echo "$out" | grep -qi 'not crediting' \
  && ok "2 suppression is logged" \
  || no "2 expected a log line about suppressing per_us_results crediting (got: $out)"

# Malformed case: criteria_results present but not an array -> also an
# override; must also suppress crediting.
f=$(vf h1-malformed '{"verdict":"fail","per_us_results":{"US-002":"pass"},"criteria_results":"garbage"}')
out=$(h1_harness "$f" "fail" "")
echo "$out" | grep -q '^RESULT_VERIFIED_US=$' \
  && ok "3 malformed criteria_results -> per_us_results NOT credited" \
  || no "3 malformed case should have suppressed crediting (got: $out)"

# Regression guard: a NORMAL fail (no override — criteria_results absent)
# with per_us_results must still credit partial progress exactly as before.
f=$(vf h1-normal-fail '{"verdict":"fail","per_us_results":{"US-002":"pass"}}')
out=$(h1_harness "$f" "fail" "")
echo "$out" | grep -q '^RESULT_VERIFIED_US=US-002$' \
  && ok "4 REGRESSION: normal fail (no override) still credits per_us_results" \
  || no "4 regression broken — normal partial progress must still be credited (got: $out)"

# Honest-fail case (fixed by this wave's review, finding #1): the top-level
# verdict was ALREADY fail (never claimed pass) and criteria_results reports
# met:false for the FAILING US only — this is an honest verdict, not a
# contract violation, so it must NOT be treated as an override: a genuinely
# passing sibling US in the SAME batch verdict (US-001) must still be
# credited, and the "not crediting" suppression log must NOT appear.
f=$(vf h1-honest '{"verdict":"fail","us_id":"ALL","summary":"US-002 AC2 regression test missing; US-001 fully verified","per_us_results":{"US-001":"pass","US-002":"fail"},"criteria_results":[{"criterion":"US-001 AC1","met":true,"evidence":"ok"},{"criterion":"US-002 AC2","met":false,"evidence":"no test"}]}')
out=$(h1_harness "$f" "fail" "")
echo "$out" | grep -q '^RESULT_VERIFIED_US=US-001$' \
  && ok "4a honest fail (verdict already fail + met:false) still credits the passing sibling US" \
  || no "4a honest fail should have credited US-001 (got: $out)"
echo "$out" | grep -qi 'not crediting' \
  && no "4b honest fail must NOT log the override-suppression line (got: $out)" \
  || ok "4b honest fail correctly does not suppress crediting"

# Honest per-US fail (finding #1, second shape): per-US verdict, already
# fail, with met:false for the same US and no sibling to credit — the
# override must still not fire (no false "override" bookkeeping), even
# though there's nothing here for the credit branch to actually credit.
f=$(vf h1-honest2 '{"verdict":"fail","us_id":"US-002","summary":"AC2 edge case for empty input is untested; implementation otherwise correct","per_us_results":{"US-002":"fail"},"criteria_results":[{"criterion":"AC1","met":true,"evidence":"ok"},{"criterion":"AC2","met":false,"evidence":"no empty-input test"}],"issues":[{"id":"AC2","severity":"high","description":"missing empty-input test"}],"next_iteration_contract":"Add the empty-input test for AC2."}')
out=$(h1_harness "$f" "fail" "")
echo "$out" | grep -qi 'not crediting' \
  && no "4c honest per-US fail must NOT log the override-suppression line (got: $out)" \
  || ok "4c honest per-US fail correctly does not suppress crediting"

##############################################################################
# H3 — _consensus_finalize must never corrupt VERDICT_FILE on backslash-
# bearing evidence (zsh builtin `echo` reinterprets \n / \\ as escapes)
##############################################################################
echo ""
echo "--- H3: consensus merge must not corrupt VERDICT_FILE on backslash evidence ---"

CF_TEXT=$(awk '/^_consensus_finalize\(\) \{/{f=1} f{print; if ($0=="}") exit}' "$RUN")
[[ -n "$CF_TEXT" ]] || no "H3 EXTRACT: _consensus_finalize() not found in real source"

h3_harness() { # $1=claude_verdict_file $2=codex_verdict_file $3=claude_result $4=codex_result
  local cf="$1" xf="$2" cr="$3" xr="$4" hf="$TMPD/h3-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { :; }; log_debug() { :; }; log_error() { echo "LOGGED_ERROR: \$*" >&2; }
CLAUDE_VERDICT='$cr'; CODEX_VERDICT='$xr'; CONSENSUS_ROUND=1
VERDICT_FILE='$TMPD/h3-out-\$\$.json'
LOGS_DIR='$TMPD'
SETUP
  print -r -- "$CF_TEXT" >> "$hf"
  print -r -- "_consensus_finalize 3 US-001 '$cf' '$xf'; echo \"FINALIZE_RC=\$?\"" >> "$hf"
  print -r -- 'echo "OUT_FILE=$VERDICT_FILE"' >> "$hf"
  zsh "$hf" 2>&1
}

# Both-pass branch, backslash-bearing evidence in BOTH engines' criteria_results.
CLAUDE_PASS_CR='{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":true,"evidence":"line1\\nline2 path=C:\\\\Users\\\\x"}]}'
CODEX_PASS_CR='{"verdict":"pass","criteria_results":[{"criterion":"AC2","met":true,"evidence":"a\\\\b"}]}'
cf=$(vf h3-claude-pass "$CLAUDE_PASS_CR")
xf=$(vf h3-codex-pass "$CODEX_PASS_CR")
out=$(h3_harness "$cf" "$xf" "pass" "pass")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
if [[ -f "$outfile" ]] && jq empty "$outfile" 2>/dev/null; then
  ok "5 both-pass: merged VERDICT_FILE is valid JSON despite backslash evidence"
else
  no "5 both-pass: merged VERDICT_FILE is INVALID JSON (backslash corruption) — file: $(cat "$outfile" 2>/dev/null)"
fi
cr_count=$(jq '.criteria_results | length' "$outfile" 2>/dev/null || echo -1)
[[ "$cr_count" == "2" ]] \
  && ok "6 both-pass: both engines' criteria_results entries survived the merge (count=2)" \
  || no "6 both-pass: expected 2 merged criteria_results entries, got '$cr_count'"

# Disagreement branch, backslash-bearing evidence in issues[] on both sides.
CLAUDE_FAIL='{"verdict":"fail","issues":[{"severity":"high","id":"I1","description":"broke on C:\\\\path\\nline2"}],"criteria_results":[{"criterion":"AC1","met":false,"evidence":"missing\\nnewline"}]}'
CODEX_FAIL='{"verdict":"fail","issues":[{"severity":"high","id":"I2","description":"also broke\\\\here"}],"criteria_results":[]}'
cf=$(vf h3-claude-fail "$CLAUDE_FAIL")
xf=$(vf h3-codex-fail "$CODEX_FAIL")
out=$(h3_harness "$cf" "$xf" "fail" "fail")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
if [[ -f "$outfile" ]] && jq empty "$outfile" 2>/dev/null; then
  ok "7 disagreement: merged VERDICT_FILE is valid JSON despite backslash evidence in issues[]"
else
  no "7 disagreement: merged VERDICT_FILE is INVALID JSON — file: $(cat "$outfile" 2>/dev/null)"
fi
issues_count=$(jq '.issues | length' "$outfile" 2>/dev/null || echo -1)
[[ "$issues_count" == "2" ]] \
  && ok "8 disagreement: both engines' issues[] survived the merge (count=2)" \
  || no "8 disagreement: expected 2 merged issues, got '$issues_count'"
cr2_count=$(jq '.criteria_results | length' "$outfile" 2>/dev/null || echo -1)
[[ "$cr2_count" == "1" ]] \
  && ok "9 disagreement: criteria_results merged through too (count=1)" \
  || no "9 disagreement: expected 1 merged criteria_results entry, got '$cr2_count'"

##############################################################################
# Finding #3 — the criteria/issues merge must not pass large arrays through
# jq argv (`--argjson`): macOS ARG_MAX is ~1MB total for argv+environ, Linux
# caps a single arg at ~128KB. A >1MB evidence string blows the merge, and
# the `[[ -n "$merged" ]] || merged='[]'` fallback then silently classifies
# as "empty" (permissive) — dropping a real met:false instead of failing
# closed.
##############################################################################
echo ""
echo "--- Finding #3: consensus merge must not E2BIG on large criteria_results/issues ---"

# NOTE: BIG_EVIDENCE is built and interpolated directly (never through a jq
# --arg/argjson at the TEST level either) — an "x"-only string needs no JSON
# escaping, and passing it through jq's own argv here would trip the exact
# E2BIG this test exists to catch, just one layer too early (in the fixture
# builder instead of the production code under test).
BIG_EVIDENCE=$(head -c 1200000 /dev/zero | tr '\0' 'x')
big_claude_json='{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":true,"evidence":"'"$BIG_EVIDENCE"'"}]}'
cf=$(vf f3-claude-big "$big_claude_json")
xf=$(vf f3-codex-small '{"verdict":"pass","criteria_results":[{"criterion":"AC2","met":false,"evidence":"short"}]}')
out=$(h3_harness "$cf" "$xf" "pass" "pass")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
if [[ -f "$outfile" ]] && jq empty "$outfile" 2>/dev/null; then
  ok "9a large evidence: merged VERDICT_FILE is still valid JSON"
else
  no "9a large evidence: merged VERDICT_FILE is INVALID JSON — file head: $(head -c 200 "$outfile" 2>/dev/null)"
fi
cr3_count=$(jq '.criteria_results | length' "$outfile" 2>/dev/null || echo -1)
[[ "$cr3_count" == "2" ]] \
  && ok "9b large evidence: both engines' criteria_results entries survived the merge (count=2), not E2BIG-dropped to []" \
  || no "9b large evidence: expected 2 merged criteria_results entries, got '$cr3_count' (file: $(jq -c . "$outfile" 2>/dev/null | head -c 200))"
unmet3=$(jq '[.criteria_results[]? | select(.met == false)] | length' "$outfile" 2>/dev/null || echo -1)
[[ "$unmet3" == "1" ]] \
  && ok "9c large evidence: the codex side's met:false criterion survived the merge (not silently dropped)" \
  || no "9c large evidence: expected 1 unmet criterion in the merge, got '$unmet3'"

# Same shape, but on the DISAGREEMENT (fail) branch, which merges issues[] too.
big_claude_fail_json='{"verdict":"fail","issues":[{"severity":"high","id":"I1","description":"'"$BIG_EVIDENCE"'"}],"criteria_results":[{"criterion":"AC1","met":false,"evidence":"'"$BIG_EVIDENCE"'"}]}'
cf=$(vf f3-claude-big-fail "$big_claude_fail_json")
xf=$(vf f3-codex-small-fail '{"verdict":"fail","issues":[{"severity":"high","id":"I2","description":"also broke"}],"criteria_results":[]}')
out=$(h3_harness "$cf" "$xf" "fail" "fail")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
if [[ -f "$outfile" ]] && jq empty "$outfile" 2>/dev/null; then
  ok "9d large evidence (disagreement): merged VERDICT_FILE is still valid JSON"
else
  no "9d large evidence (disagreement): merged VERDICT_FILE is INVALID JSON — file head: $(head -c 200 "$outfile" 2>/dev/null)"
fi
issues3_count=$(jq '.issues | length' "$outfile" 2>/dev/null || echo -1)
[[ "$issues3_count" == "2" ]] \
  && ok "9e large evidence (disagreement): both engines' issues[] survived the merge (count=2)" \
  || no "9e large evidence (disagreement): expected 2 merged issues, got '$issues3_count'"

##############################################################################
# Finding #4 — the post-write guards must not pass a 0-byte VERDICT_FILE.
# `jq empty` on zero bytes of input processes no tokens, hits no error, and
# exits 0 — a builder that emits NOTHING (piped into atomic_write) looks
# "valid" to that guard, and the fail-closed rewrite never fires, leaving an
# empty (and therefore un-parseable-as-a-verdict) VERDICT_FILE in place.
##############################################################################
echo ""
echo "--- Finding #4: post-write guard must reject a 0-byte VERDICT_FILE ---"

GUARD_LINE='jq -e '\''type=="object" and has("verdict")'\'' "$VERDICT_FILE" >/dev/null 2>&1; then'
BOTHPASS_GUARD=$(awk -v anchor="    if ! $GUARD_LINE" '
  $0 == anchor { f=1 }
  f { print }
  f && $0 == "    fi" { exit }
' "$RUN")
DISAGREEMENT_GUARD=$(awk -v anchor="  if ! $GUARD_LINE" '
  $0 == anchor { f=1 }
  f { print }
  f && $0 == "  fi" { exit }
' "$RUN")
[[ -n "$BOTHPASS_GUARD" ]] \
  && ok "9f extraction sanity: both-pass post-write guard found in real source" \
  || no "9f extraction sanity: both-pass post-write guard NOT found (marker text changed?)"
[[ -n "$DISAGREEMENT_GUARD" ]] \
  && ok "9g extraction sanity: disagreement post-write guard found in real source" \
  || no "9g extraction sanity: disagreement post-write guard NOT found (marker text changed?)"

guard_harness() { # $1=guard snippet $2=extra setup vars (raw zsh)
  local snippet="$1" setup="$2" hf="$TMPD/guard-harness.zsh"
  local vfile="$TMPD/guard-vf-$$-${RANDOM}.json"
  : > "$vfile"   # 0-byte VERDICT_FILE — exactly the builder-emitted-nothing case
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
VERDICT_FILE='$vfile'
cons_us_id='US-001'
CLAUDE_VERDICT='pass'; CODEX_VERDICT='pass'
$setup
SETUP
  print -r -- "$snippet" >> "$hf"
  print -r -- "echo \"GUARD_RC=\$?\"" >> "$hf"
  zsh "$hf" 2>&1
  echo "VFILE=$vfile"
}

out=$(guard_harness "$BOTHPASS_GUARD" "")
vfile=$(echo "$out" | sed -n 's/^VFILE=//p' | tail -1)
guard_verdict=$(jq -r '.verdict // "MISSING"' "$vfile" 2>/dev/null)
[[ "$guard_verdict" == "fail" ]] \
  && ok "9h both-pass guard: a 0-byte VERDICT_FILE is detected and rewritten fail-closed" \
  || no "9h both-pass guard failed to fail-closed on a 0-byte file (verdict=$guard_verdict, out=$out)"

out=$(guard_harness "$DISAGREEMENT_GUARD" "")
vfile=$(echo "$out" | sed -n 's/^VFILE=//p' | tail -1)
guard_verdict=$(jq -r '.verdict // "MISSING"' "$vfile" 2>/dev/null)
[[ "$guard_verdict" == "fail" ]] \
  && ok "9i disagreement guard: a 0-byte VERDICT_FILE is detected and rewritten fail-closed" \
  || no "9i disagreement guard failed to fail-closed on a 0-byte file (verdict=$guard_verdict, out=$out)"

##############################################################################
# M1 — CB ceiling deferral must be bounded even when every failure is
# classified environment/flaky (check_model_upgrade, and therefore
# _SAME_US_FAIL_COUNT, is skipped for those categories)
##############################################################################
echo ""
echo "--- M1: CB ceiling deferral must end for environment-category failures ---"

CB_TEXT=$(extract_marked '# Circuit breaker: consecutive failures' '^            update_status "verifier" "fail"$' "$RUN")
[[ -n "$CB_TEXT" ]] && echo "$CB_TEXT" | grep -q "write_blocked_sentinel" \
  && ok "10 extraction sanity: CB block found in real source" \
  || { no "10 extraction sanity: CB block NOT found — M1 cannot proceed"; }
SKIP_TEXT=$(extract_marked 'Luna-first spec §2.5: environment/harness failures' '^            fi$' "$RUN")
[[ -n "$SKIP_TEXT" ]] \
  && ok "11 extraction sanity: model-upgrade category-skip block found in real source" \
  || { no "11 extraction sanity: category-skip block NOT found — M1 cannot proceed"; }
extract_fn() { awk -v fn="$1() {" 'index($0, fn) == 1 { f=1 } f { print; if ($0 == "}") exit }' "$2"; }
CMU_TEXT="$(extract_fn check_model_upgrade "$LIB")"
GNM_TEXT="$(extract_fn get_next_model "$LIB")"
GMS_TEXT="$(extract_fn get_model_string "$LIB")"

# Simulates N consecutive same-US failures, each with a caller-supplied
# failure category, against the REAL category-skip decision + REAL CB block +
# REAL check_model_upgrade/get_next_model ladder walk. Prints one line per
# failure: "<n> cat=<cat> model=<model> same_us=<count> ceiling_defer=<count> blocked=<0|1>".
run_m1_simulation() { # $1=space-separated categories $2=cb_threshold
  local cats_str="$1" cbt="${2:-4}" hf="$TMPD/m1-harness.zsh"
  cat > "$hf" <<SETUP
set -uo pipefail
LIB_DIR='$ROOT/src/scripts'
RLP_DESK_MODELS_FILE="\${RLP_DESK_MODELS_FILE:-/nonexistent-hermetic-test-guard/rlp-desk-models.json}"
source '$LIB' 2>/dev/null
log() { :; }; log_error() { :; }; log_debug() { :; }
write_blocked_sentinel() { echo "BLOCKED_REASON::\$1"; }
update_status() { :; }
SETUP
  print -r -- "$GNM_TEXT" >> "$hf"
  print -r -- "$GMS_TEXT" >> "$hf"
  print -r -- "$CMU_TEXT" >> "$hf"
  cat >> "$hf" <<'WRAP1'
_run_skip_decision() {
WRAP1
  print -r -- "$SKIP_TEXT" >> "$hf"
  cat >> "$hf" <<'WRAP1B'
}
_run_cb() {
WRAP1B
  print -r -- "$CB_TEXT" >> "$hf"
  cat >> "$hf" <<'WRAP2'
}
WORKER_ENGINE='claude'; WORKER_CODEX_MODEL=''; WORKER_CODEX_REASONING=''
WORKER_MODEL='haiku'; WORKER_EFFORT=''; LOCK_WORKER_MODEL=0
_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=''
_ORIGINAL_WORKER_MODEL=''; _ORIGINAL_WORKER_CODEX_REASONING=''; _ORIGINAL_WORKER_EFFORT=''
_CEILING_DEFERRAL_COUNT=0
CONSECUTIVE_FAILURES=0
CB_THRESHOLD=CBT_PLACEHOLDER
EFFECTIVE_CB_THRESHOLD=CBT_PLACEHOLDER
ITERATION=0
signal_us_id='US-001'
i=0
for cat in CATS_PLACEHOLDER; do
  (( i++ ))
  ITERATION=$i
  (( CONSECUTIVE_FAILURES++ ))
  VERDICT_FILE="VFILE_PLACEHOLDER/vf-$i.json"
  print -r -- "{\"failure_category\":\"$cat\"}" > "$VERDICT_FILE"
  _run_skip_decision
  _cmu_deferred=0
  _run_cb
  _blocked=$(( $? == 1 ? 1 : 0 ))
  echo "$i cat=$cat model=$WORKER_MODEL same_us=$_SAME_US_FAIL_COUNT ceiling_defer=$_CEILING_DEFERRAL_COUNT blocked=$_blocked"
  (( _blocked )) && break
done
WRAP2
  sed -i.bak "s/CBT_PLACEHOLDER/$cbt/g; s#VFILE_PLACEHOLDER#$TMPD#g" "$hf"
  # cats go last so a category value can never collide with the sed patterns above
  perl -0pi -e "s/CATS_PLACEHOLDER/$cats_str/" "$hf" 2>/dev/null || sed -i.bak2 "s/CATS_PLACEHOLDER/$cats_str/" "$hf"
  zsh "$hf" 2>&1
}

# Reach the ceiling normally (4 implementation-category failures, CB_THRESHOLD=4,
# 3-rung ladder haiku->sonnet:high->claude-opus-5-5:high — mirrors test_defect2's
# scenario), THEN every failure after that is "environment" category forever.
# Pre-fix: _SAME_US_FAIL_COUNT freezes at the ceiling and the campaign never
# blocks (would run to MAX_ITER). Post-fix: _CEILING_DEFERRAL_COUNT bounds the
# deferral to 2 extra failures regardless of category -> blocks at #6 (threshold+2).
SIM_M1="$(run_m1_simulation 'implementation implementation implementation implementation environment environment environment environment' 4)"
echo "$SIM_M1" | sed 's/^/    /'
BLOCKED_LINE=$(echo "$SIM_M1" | grep 'blocked=1' | head -1)
BLOCKED_AT=$(echo "$BLOCKED_LINE" | awk '{print $1}')
if [[ -z "$BLOCKED_AT" ]]; then
  no "12 M1: never blocked across 8 failures (environment-category freeze runs to MAX_ITER) — full sim:\n$SIM_M1"
elif (( BLOCKED_AT <= 6 )); then
  ok "12 M1: circuit breaker blocks at failure #$BLOCKED_AT (<= threshold+2=6), not frozen forever"
else
  no "12 M1: blocked too late (failure #$BLOCKED_AT, expected <= 6) — full sim:\n$SIM_M1"
fi

# Regression guard: the default all-implementation path (test_defect2's own
# scenario) must still block at exactly failure #6 for threshold=4.
SIM_M1B="$(run_m1_simulation 'implementation implementation implementation implementation implementation implementation' 4)"
BLOCKED_AT_B=$(echo "$SIM_M1B" | grep 'blocked=1' | head -1 | awk '{print $1}')
[[ "$BLOCKED_AT_B" == "6" ]] \
  && ok "13 REGRESSION: default all-implementation path still blocks at exactly #6 (threshold=4)" \
  || no "13 regression broken — expected block at #6, got '$BLOCKED_AT_B' — full sim:\n$SIM_M1B"

##############################################################################
# M2 — PREGATE_FAIL_CAP fail-open: forward the real lint reason even when
# Layer 1 already forced a verifier round (Layer 1.5 must still evaluate)
##############################################################################
echo ""
echo "--- M2: approach_summary_missing reason must reach the verifier, even under Layer 1 force ---"

M2_TEXT=$(extract_between '        typeset -g _DONECLAIM_LINT_LINE=""' '# --- Layer 2:' "$RUN")
[[ -n "$M2_TEXT" ]] && echo "$M2_TEXT" | grep -q 'PREGATE_LINT_STATUS' \
  && ok "14 extraction sanity: Layer 1.5 block found in real source" \
  || no "14 extraction sanity: Layer 1.5 block NOT found (marker text changed?)"

m2_harness() { # $1=_pg_short $2=_pg_force $3=lint_status $4=lint_reason $5=lint_violations
  local pgs="$1" pgf="$2" lint_status="$3" reason="$4" viol="$5" hf="$TMPD/m2-harness.zsh"
  cat > "$hf" <<SETUP
log() { echo "LOG: \$*"; }; log_debug() { :; }
_pg_short=$pgs; _pg_force=$pgf
ITERATION=1; signal_us_id='US-001'
PREGATE_FAILURES=2; PREGATE_FAIL_CAP=3
run_pregate_doneclaim_lint() { PREGATE_LINT_STATUS='$lint_status'; PREGATE_LINT_REASON='$reason'; PREGATE_LINT_VIOLATIONS='$viol'; }
_pregate_register_fail_doneclaim_lint() { return 1; }  # simulate: cap already reached -> force
SETUP
  print -r -- "$M2_TEXT" >> "$hf"
  print -r -- 'echo "RESULT_LINE=[$_DONECLAIM_LINT_LINE]"; echo "RESULT_PG_SHORT=$_pg_short"; echo "RESULT_PG_FORCE=$_pg_force"' >> "$hf"
  zsh "$hf" 2>&1
}

# Layer 1 ALREADY forced (_pg_force=1 coming in). Layer 1.5 must still run and
# forward the approach_summary_missing reason instead of the generic
# "violations: []" message that drops it on the floor.
out=$(m2_harness 0 1 fail approach_summary_missing '[]')
echo "$out" | grep -q 'RESULT_LINE=.*approach_summary_missing' \
  && ok "15 M2: Layer 1 force -> Layer 1.5 still forwards approach_summary_missing reason" \
  || no "15 M2: approach_summary_missing reason was dropped under Layer 1 force (got: $out)"
echo "$out" | grep -q '^RESULT_PG_FORCE=1$' \
  && ok "16 M2: Layer 1's force decision is preserved (not overridden by Layer 1.5)" \
  || no "16 M2: _pg_force was mutated when it should stay as Layer 1 set it (got: $out)"

# Normal path (neither short nor force coming in), Layer 1.5's OWN cap fires ->
# same requirement applies to Layer 1.5's own forced message.
out=$(m2_harness 0 0 fail approach_summary_missing '[]')
echo "$out" | grep -q 'RESULT_LINE=.*approach_summary_missing' \
  && ok "17 M2: Layer 1.5's own fail-cap also forwards approach_summary_missing (not generic 'violations: []')" \
  || no "17 M2: Layer 1.5's own cap dropped the reason (got: $out)"

##############################################################################
# M4 — fix contract + attempt-history summary must reflect the criteria
# override, not the (untrusted) verifier's own "pass" summary
##############################################################################
echo ""
echo "--- M4: fix contract must carry the criteria override detail, not the pass summary ---"

M4_TEXT=$(awk '
  /            local verdict_summary_fail/ { c=1 }
  c { print; if ($0 == "            } | atomic_write \"$fix_contract\"") exit }
' "$RUN")
[[ -n "$M4_TEXT" ]] && echo "$M4_TEXT" | grep -q 'fix_contract' \
  && ok "18 extraction sanity: fix-contract builder block found in real source" \
  || no "18 extraction sanity: fix-contract builder block NOT found (marker text changed?)"

m4_harness() { # $1=verdict_file $2=cr_state $3=cr_unmet $4=override_fired $5=original_verdict (default "pass") $6=true_override (default = $4, matching pre-P1 semantics)
  local vfile="$1" state="$2" unmet="$3" fired="$4" orig_verdict="${5:-pass}" true_override="${6:-$4}" hf="$TMPD/m4-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { :; }; log_debug() { :; }
VERDICT_FILE='$vfile'
ITERATION=1; signal_us_id='US-002'
LOGS_DIR='$TMPD'
_pre_upgrade_worker_model='haiku'
_cr_state='$state'; _cr_unmet=$unmet; _criteria_override_fired=$fired; _cr_original_verdict='$orig_verdict'; _cr_true_override=$true_override
VERIFIED_US=''
typeset -gA US_ATTEMPT_HISTORY US_FIX_CONTRACT
SETUP
  print -r -- "$M4_TEXT" >> "$hf"
  print -r -- "echo \"ATTEMPT_HISTORY=\${US_ATTEMPT_HISTORY[US-002]:-}\"" >> "$hf"
  print -r -- 'echo "FIX_CONTRACT_PATH=$fix_contract"' >> "$hf"
  zsh "$hf" 2>&1
}

f=$(vf m4-override-unmet '{"verdict":"pass","criteria_results":[{"criterion":"AC-2.1","met":false,"missing_evidence":"no proof of X"}]}')
out=$(m4_harness "$f" "populated" 1 1)
echo "$out" | grep -qi 'AC-2.1' \
  && ok "19 M4: attempt-history/summary names the actual unmet criterion, not a generic pass summary" \
  || no "19 M4: expected the unmet criterion (AC-2.1) in the derived summary (got: $out)"
fc_path=$(echo "$out" | sed -n 's/^FIX_CONTRACT_PATH=//p')
[[ -f "$fc_path" ]] && grep -qi 'AC-2.1' "$fc_path" \
  && ok "20 M4: fix contract file itself carries the unmet-criterion detail" \
  || no "20 M4: fix contract missing unmet-criterion detail (path=$fc_path)"

f=$(vf m4-override-malformed '{"verdict":"pass","criteria_results":"garbage"}')
out=$(m4_harness "$f" "malformed" 0 1)
echo "$out" | grep -qi 'malformed' \
  && ok "21 M4: malformed override -> explicit 'criteria_results malformed' line" \
  || no "21 M4: expected an explicit malformed line (got: $out)"

# Regression: no override fired -> the original verifier summary passes through unchanged.
f=$(vf m4-no-override '{"verdict":"fail","summary":"generic verifier failure text"}')
out=$(m4_harness "$f" "absent" 0 0)
fc_path=$(echo "$out" | sed -n 's/^FIX_CONTRACT_PATH=//p')
[[ -f "$fc_path" ]] && grep -q 'generic verifier failure text' "$fc_path" \
  && ok "22 REGRESSION: no override -> original verifier summary still flows through" \
  || no "22 regression broken — original summary should still appear (path=$fc_path)"

# Finding #2: a mix of a non-object array element ("garbage") alongside
# object entries (one honest met:false, one with a non-boolean met:"false")
# must not abort the whole jq comprehension — every one of the 4 unmet/
# malformed entries must be listed, not silently dropped because a raw
# string sits next to them in the array.
f=$(vf m4-garbled-mix '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":false,"evidence":"e1"},"garbage",{"criterion":"AC3","met":false,"evidence":"e3"},{"criterion":"AC4","met":"false","evidence":"e4"}]}')
out=$(m4_harness "$f" "populated" 4 1)
fc_path=$(echo "$out" | sed -n 's/^FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -q 'AC1' && echo "$fc_body" | grep -q 'AC3' \
  && ok "23 M4: object entries survive alongside a non-object array element" \
  || no "23 M4: expected AC1 and AC3 in fix contract despite the garbage entry (got: $fc_body)"
echo "$fc_body" | grep -qi 'malformed' \
  && ok "24 M4: the non-object entry itself is rendered as a malformed placeholder, not silently dropped" \
  || no "24 M4: expected some 'malformed entry' placeholder for the bare 'garbage' element (got: $fc_body)"
echo "$out" | grep -q 'ATTEMPT_HISTORY=' \
  && echo "$out" | grep 'ATTEMPT_HISTORY=' | grep -q 'AC1' \
  && ok "25 M4: attempt-history summary also lists AC1 despite the mixed array" \
  || no "25 M4: attempt-history summary should still list AC1 (got: $out)"

##############################################################################
# Round 3 finding #1 — the criteria-override fired flag must fire for ANY
# pre-override verdict that is not literally "fail" (not just literal
# "pass"): "pass.", "PASS: all ACs met", "approved", "success", null,
# "blocked", "request_info" all currently slip through the old `== "pass"`
# check, so an unmet criterion overrides verdict to fail WITHOUT setting
# fired — crediting per_us_results and keeping the untrusted "looks great"
# narrative exactly like the original H1 attack, just phrased differently.
# An honest "fail" must still behave as before (H1 4a/4b/4c).
##############################################################################
echo ""
echo "--- Round 3 finding #1: override must fire for non-pass, non-fail verdicts too ---"

f1r3_harness() { # $1=verdict_file
  local vfile="$1" hf="$TMPD/f1r3-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { echo "LOG: \$*"; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
_append_verified_ledger() { return 0; }
VERDICT_FILE='$vfile'
ITERATION=1
LOGS_DIR='$TMPD'
signal_us_id='US-002'
SETUP
  # round 5 P3 follow-up: the REAL production verdict-read line (extracted
  # above), not a hand-copied duplicate — see the PROD_VERDICT_READ_LINE
  # comment.
  print -r -- "$PROD_VERDICT_READ_LINE" >> "$hf"
  cat >> "$hf" <<SETUP
VERIFIED_US=''
_pre_upgrade_worker_model='haiku'
CONSECUTIVE_FAILURES=0
typeset -gA US_FIX_CONTRACT US_ATTEMPT_HISTORY
SETUP
  print -r -- "$H1_OVERRIDE_SNIPPET" >> "$hf"
  print -r -- "$H1_CREDIT_SNIPPET" >> "$hf"
  print -r -- "$M4_TEXT" >> "$hf"
  print -r -- 'echo "RESULT_VERIFIED_US=$VERIFIED_US"' >> "$hf"
  print -r -- 'echo "RESULT_FIRED=$_criteria_override_fired"' >> "$hf"
  print -r -- "echo \"RESULT_ATTEMPT=\${US_ATTEMPT_HISTORY[US-002]:-}\"" >> "$hf"
  zsh "$hf" 2>&1
}

f1r3_body() { # $1=verdict value, a raw already-JSON-quoted literal (e.g. '"pass."' or 'null')
  print -r -- '{"verdict":'"$1"',"per_us_results":{"US-001":"pass","US-002":"pass"},"summary":"All ACs verified, looks great","criteria_results":[{"criterion":"AC1","met":true,"evidence":"ok"},{"criterion":"AC2","met":false,"evidence":"no test"}]}'
}

check_f1r3() { # $1=label $2=verdict-json-value $3=expect_fired(0/1)
  local label="$1" vval="$2" expect_fired="$3"
  local f out fired vus
  f=$(vf "f1r3-$label" "$(f1r3_body "$vval")")
  out=$(f1r3_harness "$f")
  fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
  vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
  [[ "$fired" == "$expect_fired" ]] \
    && ok "F1R3 $label: fired=$expect_fired as expected" \
    || no "F1R3 $label: expected fired=$expect_fired, got fired=$fired (out: $out)"
  if (( expect_fired )); then
    [[ -z "$vus" ]] \
      && ok "F1R3 $label: per_us_results NOT credited" \
      || no "F1R3 $label: expected no credit, got VERIFIED_US=$vus"
    echo "$out" | grep -q 'RESULT_ATTEMPT=.*looks great' \
      && no "F1R3 $label: attempt-history still shows the untrusted 'looks great' pass narrative" \
      || ok "F1R3 $label: attempt-history summary no longer the untrusted pass narrative"
  else
    { [[ "$vus" == "US-001,US-002" ]] || [[ "$vus" == "US-002,US-001" ]]; } \
      && ok "F1R3 $label: honest fail still credits per_us_results" \
      || no "F1R3 $label: expected both US credited on honest fail, got VERIFIED_US=$vus"
  fi
}

# Regression baseline: exact/near-exact "pass" spellings already worked pre-fix.
check_f1r3 v1-PASS       '"PASS"' 1
check_f1r3 v2-trail-space '"pass "' 1
check_f1r3 v3-CR-Passed  '" Passed\r"' 1
# The actual round-3 gap: values that normalize to something OTHER than
# literal "pass" or "fail".
check_f1r3 v4-pass-dot        '"pass."' 1
check_f1r3 v5-approved        '"approved"' 1
check_f1r3 v6-success         '"success"' 1
check_f1r3 v7-null            'null' 1
check_f1r3 v8-blocked         '"blocked"' 1
check_f1r3 v9-request_info    '"request_info"' 1
check_f1r3 v10-pass-colon     '"PASS: all ACs met"' 1
# Honest fail must be unaffected (fired=0, credit kept) — same class as H1
# 4a/4b/4c, repeated here through the SAME harness/fixture shape as the
# above for a direct side-by-side comparison.
check_f1r3 honest-fail '"fail"' 0

##############################################################################
# Round 3 finding #2 — the malformed branch fires unconditionally (by design,
# H1/finding-#1), including when the ORIGINAL verdict was already an honest
# "fail". In that case the fix must still suppress partial-progress credit,
# but must NOT (a) replace the verifier's own honest summary with generic
# malformed text, or (b) print the false heading "verifier reported pass;
# overridden to fail" when nothing was actually overridden FROM pass.
##############################################################################
echo ""
echo "--- Round 3 finding #2: malformed-on-honest-fail keeps the real summary + an honest heading ---"

f2r3_harness() { # $1=verdict_file
  local vfile="$1" hf="$TMPD/f2r3-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { echo "LOG: \$*"; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
_append_verified_ledger() { return 0; }
VERDICT_FILE='$vfile'
ITERATION=1
LOGS_DIR='$TMPD'
signal_us_id='US-002'
SETUP
  # round 5 P3 follow-up: the REAL production verdict-read line, not a
  # hand-copied duplicate — see the PROD_VERDICT_READ_LINE comment.
  print -r -- "$PROD_VERDICT_READ_LINE" >> "$hf"
  cat >> "$hf" <<SETUP
VERIFIED_US=''
_pre_upgrade_worker_model='haiku'
CONSECUTIVE_FAILURES=0
typeset -gA US_FIX_CONTRACT US_ATTEMPT_HISTORY
SETUP
  print -r -- "$H1_OVERRIDE_SNIPPET" >> "$hf"
  print -r -- "$H1_CREDIT_SNIPPET" >> "$hf"
  print -r -- "$M4_TEXT" >> "$hf"
  print -r -- 'echo "RESULT_VERIFIED_US=$VERIFIED_US"' >> "$hf"
  print -r -- 'echo "RESULT_FIRED=$_criteria_override_fired"' >> "$hf"
  print -r -- "echo \"RESULT_ATTEMPT=\${US_ATTEMPT_HISTORY[US-002]:-}\"" >> "$hf"
  print -r -- 'echo "RESULT_FIX_CONTRACT_PATH=$fix_contract"' >> "$hf"
  zsh "$hf" 2>&1
}

# honest_obj.json: verdict already "fail", criteria_results is an OBJECT
# (malformed shape), a real per-US summary, and per_us_results crediting
# US-001 as pass alongside the still-failing US-002.
f=$(vf f2r3-honest-obj '{"verdict":"fail","us_id":"ALL","summary":"US-002 AC2 regression test missing; US-001 fully verified","per_us_results":{"US-001":"pass","US-002":"fail"},"criteria_results":{"US-001 AC1":{"met":true},"US-002 AC2":{"met":false,"evidence":"no test"}},"issues":[{"id":"AC2","severity":"high","description":"missing regression test"}]}')
out=$(f2r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
[[ "$fired" == "1" ]] \
  && ok "F2R3.1 malformed-on-honest-fail still fires (partial-progress credit stays suppressed)" \
  || no "F2R3.1 expected fired=1, got fired=$fired (out: $out)"
[[ -z "$vus" ]] \
  && ok "F2R3.2 per_us_results still NOT credited (malformed criteria_results distrusted)" \
  || no "F2R3.2 expected no credit despite malformed data, got VERIFIED_US=$vus"
echo "$out" | grep -q 'RESULT_ATTEMPT=.*US-002 AC2 regression test missing' \
  && ok "F2R3.3 attempt-history KEEPS the verifier's own honest summary (not replaced)" \
  || no "F2R3.3 expected the honest summary to survive in attempt-history (out: $out)"
echo "$out" | grep -qi 'RESULT_ATTEMPT=.*not an array' \
  && ok "F2R3.4 attempt-history still notes the malformed criteria_results (round 4: prepended, wording is 'not an array', not silent)" \
  || no "F2R3.4 expected a malformed note in attempt-history (out: $out)"
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -qi 'reported pass' \
  && no "F2R3.5 fix contract falsely claims 'verifier reported pass' when the original verdict was already fail (fc: $fc_body)" \
  || ok "F2R3.5 fix contract heading does not falsely claim a pass->fail override"
echo "$fc_body" | grep -qi 'US-002 AC2 regression test missing' \
  && ok "F2R3.6 fix contract Summary section keeps the verifier's own honest text" \
  || no "F2R3.6 fix contract lost the honest summary (fc: $fc_body)"

# Regression: a TRUE pass->malformed override (M4 test 21's shape) must still
# say "overridden to fail" — the heading is conditional, not removed.
f=$(vf f2r3-pass-malformed '{"verdict":"pass","criteria_results":"garbage"}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -qi 'reported .*pass.*overridden to fail' \
  && ok "F2R3.7 REGRESSION: a true pass->malformed override still says 'reported pass...overridden to fail'" \
  || no "F2R3.7 regression broken — expected the override heading for a real pass->fail case (fc: $fc_body)"

##############################################################################
# Round 3 addendum P1 (codex round 2) — an HONEST fail (original verdict
# already "fail") with a MALFORMED ENTRY among its unmet count — e.g. a
# "met":"false" STRING instead of a boolean, or a non-object array element —
# is untrusted evidence too, not just a top-level-malformed criteria_results
# or a true override. Unified rule: untrusted = (state==malformed) OR
# (entry-level malformed count > 0) OR (a real override happened). Untrusted
# suppresses per_us_results crediting for the round regardless of which of
# the three conditions triggered it. Separately, only a REAL override
# (verdict actually flipped from non-fail to fail) replaces the verifier's
# own summary/heading — an honest fail with untrusted entries keeps its own
# summary and gets a truthful note appended instead. An honest fail whose
# criteria are ALL well-formed booleans (no malformed entries) is NOT
# untrusted — it keeps crediting other passing US exactly as before.
##############################################################################
echo ""
echo "--- Round 3 addendum P1: honest fail + malformed ENTRY (not just top-level) must also suppress credit ---"

# P1-A: verdict already "fail", per_us_results credits US-001, but the
# US-002 criterion's `met` is the STRING "false", not the boolean false —
# an entry-level malformed value. Must suppress crediting AND keep the
# verifier's own honest summary (with a truthful note appended).
f=$(vf p1r3-honest-entry-malformed '{"verdict":"fail","us_id":"ALL","summary":"US-002 AC2 issue; US-001 fine","per_us_results":{"US-001":"pass","US-002":"fail"},"criteria_results":[{"criterion":"US-001 AC1","met":true},{"criterion":"US-002 AC2","met":"false"}]}')
out=$(f1r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
[[ "$fired" == "1" ]] \
  && ok "P1A.1 honest fail + entry-level malformed (met:\"false\") is treated as untrusted (fired=1)" \
  || no "P1A.1 expected fired=1 for an honest fail with a malformed entry, got fired=$fired (out: $out)"
[[ -z "$vus" ]] \
  && ok "P1A.2 US-001 is NOT credited despite the malformed entry sitting on US-002's criterion" \
  || no "P1A.2 expected no credit (untrusted evidence), got VERIFIED_US=$vus"
echo "$out" | grep -q 'RESULT_ATTEMPT=.*US-002 AC2 issue; US-001 fine' \
  && ok "P1A.3 attempt-history keeps the verifier's own honest summary" \
  || no "P1A.3 expected the honest summary to survive (out: $out)"
echo "$out" | grep -qi 'RESULT_ATTEMPT=.*not credited' \
  && ok "P1A.4 attempt-history carries a truthful 'not credited' note, not a fabricated override claim" \
  || no "P1A.4 expected a truthful note appended (out: $out)"
echo "$out" | grep -qi 'RESULT_ATTEMPT=.*reported .*fail.*overridden' \
  && no "P1A.5 attempt-history must NOT claim an override happened (verdict was already fail)" \
  || ok "P1A.5 attempt-history does not fabricate an override claim"

# P1-B regression: same shape, but ALL criteria are well-formed booleans (a
# genuine met:false, no malformed entry) — an honest fail must still credit
# the passing sibling US exactly as before (round-2 H1 4a behavior).
f=$(vf p1r3-honest-allbool '{"verdict":"fail","us_id":"ALL","summary":"US-002 AC2 issue; US-001 fine","per_us_results":{"US-001":"pass","US-002":"fail"},"criteria_results":[{"criterion":"US-001 AC1","met":true},{"criterion":"US-002 AC2","met":false}]}')
out=$(f1r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
[[ "$fired" == "0" ]] \
  && ok "P1B.1 REGRESSION: honest fail with all-boolean (well-formed) criteria is NOT untrusted" \
  || no "P1B.1 regression broken — expected fired=0 for well-formed honest fail, got fired=$fired (out: $out)"
[[ "$vus" == "US-001" ]] \
  && ok "P1B.2 REGRESSION: US-001 is still credited when the evidence is trustworthy" \
  || no "P1B.2 regression broken — expected US-001 credited, got VERIFIED_US=$vus"

##############################################################################
# Round 3 finding #3 — the consensus issues[] merge is all-or-nothing: ONE
# bare-string issue entry, or one engine's verdict file being a non-object
# (e.g. a bare array), raises a jq type error that aborts the WHOLE combined
# merge expression — both engines' issues become the fail-closed sentinel
# string, even when the OTHER engine's issues were perfectly valid objects.
# Each engine's issues must be extracted INDEPENDENTLY and tolerate a
# non-object entry (or a non-object file) without losing the other side.
##############################################################################
echo ""
echo "--- Round 3 finding #3: consensus issues merge must not be all-or-nothing ---"

# 3A: claude has a real object issue; codex's issues[] are bare strings.
CL_OBJISSUES='{"verdict":"pass","issues":[{"id":"C1","severity":"high","description":"claude found real bug","category":"environment"}],"criteria_results":[]}'
CX_STRISSUES='{"verdict":"fail","summary":"s","issues":["tests fail on AC2","lint error"],"criteria_results":[{"criterion":"AC2","met":false}]}'
cf=$(vf f3r3-cl-obj "$CL_OBJISSUES")
xf=$(vf f3r3-cx-str "$CX_STRISSUES")
out=$(h3_harness "$cf" "$xf" "pass" "fail")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
issues_json=$(jq -c '.issues' "$outfile" 2>/dev/null)
[[ "$issues_json" != '"malformed-in-consensus-merge"' ]] \
  && ok "F3R3.1 a bare-string issue on one side does not collapse BOTH sides to the sentinel" \
  || no "F3R3.1 merge collapsed to the sentinel despite claude having a valid issue (issues: $issues_json)"
issues_count=$(jq '.issues | length' "$outfile" 2>/dev/null || echo -1)
[[ "$issues_count" == "3" ]] \
  && ok "F3R3.2 all 3 issues survive (1 claude object + 2 codex bare-string-turned-object)" \
  || no "F3R3.2 expected 3 merged issues (1 claude + 2 codex), got '$issues_count' (issues: $issues_json)"
echo "$issues_json" | grep -q '"id":"C1"' \
  && ok "F3R3.3 claude's real object issue (C1) survived the merge" \
  || no "F3R3.3 claude's issue C1 missing from merge (issues: $issues_json)"
echo "$issues_json" | grep -q 'tests fail on AC2' \
  && ok "F3R3.4 codex's bare-string issue survived, converted to an object (description+source)" \
  || no "F3R3.4 codex's bare-string issue missing from merge (issues: $issues_json)"

# 3B: claude has a real object issue; codex's ENTIRE verdict file is a bare
# array (not an object at all) — `.issues` indexing on it is a hard jq error.
CX_ARR_FILE='[]'
cf=$(vf f3r3-cl-obj2 "$CL_OBJISSUES")
xf=$(vf f3r3-cx-arr "$CX_ARR_FILE")
out=$(h3_harness "$cf" "$xf" "pass" "fail")
outfile=$(echo "$out" | sed -n 's/^OUT_FILE=//p' | tail -1)
issues_json2=$(jq -c '.issues' "$outfile" 2>/dev/null)
[[ "$issues_json2" != '"malformed-in-consensus-merge"' ]] \
  && ok "F3R3.5 codex's non-object (bare array) verdict file does not collapse claude's valid issues to the sentinel" \
  || no "F3R3.5 merge collapsed to the sentinel despite claude having a valid issue (issues: $issues_json2)"
echo "$issues_json2" | grep -q '"id":"C1"' \
  && ok "F3R3.6 claude's real object issue (C1) survives even when codex's file is a bare array" \
  || no "F3R3.6 claude's issue C1 missing (issues: $issues_json2)"

##############################################################################
# L4a — write_worker_trigger must return 0 on its success path regardless of
# the trailing log calls' own exit status (e.g. a stdout EPIPE)
##############################################################################
echo ""
echo "--- L4a: write_worker_trigger success path must not inherit log's exit status ---"

WWT_TAIL=$(awk '/^  log "  Worker prompt:  \$prompt_file"$/{f=1} f{print; if ($0 == "}") exit}' "$RUN")
[[ -n "$WWT_TAIL" ]] || no "L4a EXTRACT: write_worker_trigger tail not found (marker text changed?)"

l4a_harness() {
  local hf="$TMPD/l4a-harness.zsh"
  cat > "$hf" <<'SETUP'
log() { return 1; }  # simulates an EPIPE-like failure on the trailing log write
prompt_file="/tmp/does-not-matter"
trigger_file="/tmp/does-not-matter-either"
_wwt_tail() {
SETUP
  print -r -- "$WWT_TAIL" >> "$hf"
  echo 'RC=$?; _wwt_tail; echo "TAIL_RC=$?"' >> "$hf"
  zsh "$hf" 2>&1
}
out=$(l4a_harness)
echo "$out" | grep -q '^TAIL_RC=0$' \
  && ok "23 L4a: success path returns 0 even though the trailing log() calls fail" \
  || no "23 L4a: function's return status leaked log()'s failure (got: $out)"

##############################################################################
# L4b — bare `local _cr_*` re-declaration inside the main loop must not
# print "name=value" to stdout on the 2nd+ pass through the loop
##############################################################################
echo ""
echo "--- L4b: bare _cr_* local re-declare must not leak name=value to stdout ---"

CR_DECL_LINE=$(grep -n '^        local _cr_result.*_cr_malformed' "$RUN" | head -1 | cut -d: -f2-)
[[ -n "$CR_DECL_LINE" ]] || no "L4b EXTRACT: _cr_* local declaration line not found (wave-3 site moved?)"

l4b_harness() {
  # Mirrors the REAL shape: main() is called ONCE and loops internally via
  # `while true`, so the bare `local` re-executes multiple times within the
  # SAME live call frame — not across separate function calls (which would
  # not reproduce the bug: each fresh call gets a genuinely fresh scope).
  local hf="$TMPD/l4b-harness.zsh"
  cat > "$hf" <<'SETUP'
_run_main() {
  local i=0
  while (( i < 2 )); do
    (( i++ ))
    echo "--- iter $i ---"
SETUP
  print -r -- "    $CR_DECL_LINE" >> "$hf"
  cat >> "$hf" <<'BODY'
    _cr_result="r$i"; _cr_state="s$i"; _cr_rest="x$i"; _cr_unmet=$i; _cr_malformed=0
  done
}
_run_main
BODY
  zsh "$hf" 2>&1
}
out=$(l4b_harness)
# A leaked bare re-declare prints "varname=value" lines with NO "iter N" or
# other prefix (zsh's typeset-list-on-redeclare format) between "--- iter 2
# ---" and the function body's own output.
leaked=$(echo "$out" | grep -cE '^_cr_(result|state|rest|unmet|malformed)=')
(( leaked == 0 )) \
  && ok "24 L4b: no bare local re-declare leak across loop iterations" \
  || no "24 L4b: bare local re-declare leaked $leaked name=value line(s) to stdout — full output:\n$out"

##############################################################################
# L4b follow-up — the pre-existing bare `local _fail_cat` (same class of bug,
# same fix) is now also explicit-init'd
##############################################################################
echo ""
echo "--- L4b follow-up: bare _fail_cat local re-declare must not leak name=value to stdout ---"

FAILCAT_DECL_LINE=$(grep -n '^            local _fail_cat' "$RUN" | head -1 | cut -d: -f2-)
[[ -n "$FAILCAT_DECL_LINE" ]] || no "L4b-followup EXTRACT: _fail_cat local declaration line not found (moved?)"

l4b_failcat_harness() {
  # Same shape as l4b_harness above: the loop lives INSIDE one function call,
  # matching main()'s real structure (one call, `while true` internally).
  local hf="$TMPD/l4b-failcat-harness.zsh"
  cat > "$hf" <<'SETUP'
_run_main() {
  local i=0
  while (( i < 2 )); do
    (( i++ ))
    echo "--- iter $i ---"
SETUP
  print -r -- "    $FAILCAT_DECL_LINE" >> "$hf"
  cat >> "$hf" <<'BODY'
    _fail_cat="cat$i"
  done
}
_run_main
BODY
  zsh "$hf" 2>&1
}
out=$(l4b_failcat_harness)
leaked_failcat=$(echo "$out" | grep -cE '^_fail_cat=')
(( leaked_failcat == 0 )) \
  && ok "25 L4b follow-up: no bare _fail_cat local re-declare leak across loop iterations" \
  || no "25 L4b follow-up: bare _fail_cat local re-declare leaked $leaked_failcat name=value line(s) to stdout — full output:\n$out"

##############################################################################
# Finding #5 — pre-existing bare `local NAME` (and `local NAME1 NAME2 ...`)
# re-declarations elsewhere in the SAME loop body, same class of bug as L4b/
# L4b-followup above (verified empirically: a bare `local x` prints
# "x=<value>" to stdout once x already holds a value from the PRIOR pass
# through the same call frame). Explicit `=""` inits per name suppress it
# without changing behavior — every one of these is unconditionally
# reassigned before use. Extracted by exact content (never retyped) from the
# real loop-body declaration lines flagged by the review.
##############################################################################
echo ""
echo "--- Finding #5: pre-existing bare local re-declares inside the loop must not leak ---"

typeset -a F5_DECL_LINES=(
  '    local ITER_START_TIME'
  '          local _dc_epoch'
  '        local _prev_reason'
  '      local _iter_pre'
  '        local worker_cmd'
  '    local signal_status'
  '    local signal_summary'
  '        local vp_count'
  '          local vp_us_id'
  '          local verifier_cmd'
  '          local _v_eng'
  '          local verifier_launch'
  '        local verdict'
  '        local recommended'
  '        local verdict_summary'
  '              local _verdict_us_id'
  '              local _newly_passed'
  '            local verdict_summary_fail'
  '                local _cr_unmet_detail'
  '            local verdict_summary_ri'
  '            local _verdict_cat'
  '        local _signal_cat'
)

f5_missing=0
f5_total_leaked=0
for decl in "${F5_DECL_LINES[@]}"; do
  found_line=$(grep -Fn -- "$decl" "$RUN" | head -1 | cut -d: -f2-)
  if [[ -z "$found_line" ]]; then
    (( f5_missing++ ))
    no "Finding #5 EXTRACT: declaration [$decl] not found in real source (moved/renamed?)"
    continue
  fi
  # Sanitize each token to a bare name: strips a `="..."` suffix so this
  # parses correctly whether found_line is still bare (pre-fix, RED) or
  # already has explicit `=""` inits (post-fix, GREEN) — both are real
  # possible states of the source this test extracts from.
  names=(${(s: :)${found_line##*local }})
  names=(${names[@]%%=*})
  assigns=""
  for nm in "${names[@]}"; do
    assigns+="$nm=\"v_\$iter\"; "
  done
  hf="$TMPD/f5-harness-${RANDOM}.zsh"
  cat > "$hf" <<SETUP
_run_main() {
  local iter=0
  while (( iter < 2 )); do
    (( iter++ ))
    echo "--- iter \$iter ---"
$found_line
    $assigns
  done
}
_run_main
SETUP
  out=$(zsh "$hf" 2>&1)
  leak_pat="^($(printf '%s|' "${names[@]}" | sed 's/|$//'))="
  leaked=$(echo "$out" | grep -cE "$leak_pat")
  if (( leaked > 0 )); then
    (( f5_total_leaked += leaked ))
    no "Finding #5 leak in [$decl]: $leaked name=value line(s) leaked to stdout — out: $out"
  fi
done

(( f5_missing == 0 )) \
  && ok "26 Finding #5 extraction sanity: all ${#F5_DECL_LINES[@]} flagged bare-local lines found in real source" \
  || no "26 Finding #5 extraction sanity: $f5_missing of ${#F5_DECL_LINES[@]} flagged lines NOT found"
(( f5_total_leaked == 0 )) \
  && ok "27 Finding #5: none of the ${#F5_DECL_LINES[@]} pre-existing bare local declarations leak name=value across loop iterations" \
  || no "27 Finding #5: $f5_total_leaked total leaked name=value line(s) across the flagged declarations"

##############################################################################
# Finding #6 — _CEILING_DEFERRAL_COUNT must be persisted/restored across
# leader restarts, same as _SAME_US_FAIL_COUNT (D-5b): a crash-relaunch
# mid-window must not silently reset the deferral bound back to 0 (which
# would grant the ceiling model an unbounded number of extra attempt
# windows, one per restart).
##############################################################################
echo ""
echo "--- Finding #6: _CEILING_DEFERRAL_COUNT persists across leader restart (D-5b parity) ---"

UPDATE_STATUS_TEXT=$(awk '/^update_status\(\) \{/{f=1} f{print; if ($0=="}") exit}' "$LIB")
[[ -n "$UPDATE_STATUS_TEXT" ]] && echo "$UPDATE_STATUS_TEXT" | grep -q 'same_us_fail_count' \
  && ok "28 extraction sanity: update_status() found in real source" \
  || no "28 extraction sanity: update_status() NOT found (marker changed?)"
echo "$UPDATE_STATUS_TEXT" | grep -q 'ceiling_deferral_count' \
  && ok "29 update_status() persists ceiling_deferral_count next to same_us_fail_count" \
  || no "29 update_status() does NOT persist ceiling_deferral_count — restore would silently stay 0 forever"

# Same extraction technique as tests/test_us011_worker_model_upgrade.sh's
# _extract_d5b_snippet: extracted by CONTENT (from `local _status_mu` through
# the outer if's closing `fi`), not a hardcoded line range, so it survives
# unrelated line-shifting edits elsewhere in the file.
D5B_SNIPPET=$(awk '
  /local _status_mu/ { capture=1 }
  capture { print; if (started_if && $0 ~ /^    fi$/) { exit } }
  capture && /if \[\[ "\$_status_mu"/ { started_if=1 }
' "$RUN")
[[ -n "$D5B_SNIPPET" ]] || no "Finding #6 EXTRACT: D-5b restore snippet not found (has it moved out of main()?)"
echo "$D5B_SNIPPET" | grep -q 'ceiling_deferral_count' \
  && ok "30 D-5b restore snippet reads ceiling_deferral_count from status.json" \
  || no "30 D-5b restore snippet does NOT read ceiling_deferral_count"
echo "$D5B_SNIPPET" | grep -q '_CEILING_DEFERRAL_COUNT=' \
  && ok "31 D-5b restore snippet assigns _CEILING_DEFERRAL_COUNT" \
  || no "31 D-5b restore snippet does NOT assign _CEILING_DEFERRAL_COUNT"

d6_harness() { # $1=status_json_file
  local sf="$1" hf="$TMPD/d6-harness.zsh"
  cat > "$hf" <<SETUP
log() { :; }; log_debug() { :; }
STATUS_FILE='$sf'
_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _CEILING_DEFERRAL_COUNT=0
WORKER_MODEL=""; WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""
_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""
WORKER_EFFORT=""; _ORIGINAL_WORKER_EFFORT=""
SETUP
  print -r -- "$D5B_SNIPPET" >> "$hf"
  print -r -- 'echo "RESULT_CDC=$_CEILING_DEFERRAL_COUNT"' >> "$hf"
  zsh "$hf" 2>&1
}

sf=$(vf f6-roundtrip '{"model_upgraded":1,"worker_model":"claude-opus-5-5","worker_engine":"claude","same_us_fail_count":1,"ceiling_deferral_count":2}')
out=$(d6_harness "$sf")
echo "$out" | grep -q '^RESULT_CDC=2$' \
  && ok "32 round trip: ceiling_deferral_count=2 in status.json restores _CEILING_DEFERRAL_COUNT=2" \
  || no "32 round trip failed (got: $out)"

# Legacy case: a status.json written before this fix (field absent entirely)
# must restore to 0, not error or leave it unset.
sf=$(vf f6-legacy '{"model_upgraded":1,"worker_model":"claude-opus-5-5","worker_engine":"claude","same_us_fail_count":1}')
out=$(d6_harness "$sf")
echo "$out" | grep -q '^RESULT_CDC=0$' \
  && ok "33 legacy status.json (field absent) restores _CEILING_DEFERRAL_COUNT=0 (backward compatible)" \
  || no "33 legacy-missing case failed (got: $out)"

##############################################################################
# Round 4 (rendering/doc only — no crediting/control-flow changes)
##############################################################################
echo ""
echo "--- Round 4 item A: replace (not append) on a TRUE override; PREPEND (not append) on an honest-fail note ---"

LONGX=$(head -c 200 /dev/zero | tr '\0' 'x')
# A1_MARKER sits at position 0 of the untrusted summary. A 200-char PADDING
# needle (the old approach) can never match inside a 120-char-truncated
# attempt-history line regardless of append vs. replace, making that
# assertion vacuous — a short marker at the very START is what actually
# distinguishes "discarded" (replace, marker gone) from "still there, just
# truncated further out" (append, marker survives since it sits at offset 0
# either way).
A1_MARKER="UNIQUEA1SUMMARYMARKER"
A1_SUMMARY="${A1_MARKER} ${LONGX}"

# A1: TRUE override (verdict "approved", non-fail) + top-level malformed
# criteria_results + a >120-char verifier summary. The untrusted narrative
# must be REPLACED, not appended — if it were appended, the malformed
# marker (appended at the END) would fall past _record_us_attempt's 120-char
# truncation and vanish entirely from the attempt-history line.
f=$(vf a1-true-override-malformed-long "$(printf '{"verdict":"approved","summary":"%s","criteria_results":"garbage"}' "$A1_SUMMARY")")
out=$(f2r3_harness "$f")
attempt=$(echo "$out" | sed -n 's/^RESULT_ATTEMPT=//p')
echo "$attempt" | grep -qi 'malformed' \
  && ok "A1: true-override + top-level-malformed attempt-history line carries the malformed marker despite a >120-char original summary" \
  || no "A1: malformed marker missing from attempt-history (replace, not append, was expected) — got: $attempt"
echo "$attempt" | grep -q "$A1_MARKER" \
  && no "A1: attempt-history still shows the original summary's marker (should have been fully REPLACED, not merely appended-to)" \
  || ok "A1: the untrusted original summary was replaced, not preserved"

# A1 mutation control: revert the true-override malformed branch back to the
# round-3 APPEND behavior on a scratch copy, and confirm A1's marker-absence
# assertion flips red — proving it actually depends on the replace fix
# rather than passing by construction.
echo "--- Round 4 item A mutation control ---"
MUT_A1_RUN="$TMPD/run_mut_a1.zsh"
cp "$RUN" "$MUT_A1_RUN"
python3 - "$MUT_A1_RUN" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = '''                if [[ "$_cr_state" == "malformed" ]]; then
                  verdict_summary_fail="criteria_results malformed (present but not an array) — top-level verdict '${_cr_original_verdict:-<no top-level verdict>}' could not be trusted; treated as fail (no credit on unverifiable evidence)."'''
new = '''                if [[ "$_cr_state" == "malformed" ]]; then
                  verdict_summary_fail="${verdict_summary_fail} (criteria_results malformed — present but not an array; top-level verdict '${_cr_original_verdict:-<no top-level verdict>}' could not be trusted, treated as fail)"'''
assert old in text, "A1 mutation anchor not found (true-override malformed replace line moved?)"
with open(path, "w") as f:
    f.write(text.replace(old, new, 1))
PYEOF
if [[ $? -ne 0 ]]; then
  no "A1-mut.0 mutation setup failed (could not revert the replace to an append)"
else
  ok "A1-mut.0 mutation setup reverted the true-override malformed branch to APPEND"
  MUT_H1_OVERRIDE=$(extract_marked 'reaudit wave 1: make criteria_results LOAD-BEARING' '^        fi$' "$MUT_A1_RUN")
  MUT_H1_CREDIT=$(extract_marked '# Parse per_us_results from verdict to track partial progress' '^            fi$' "$MUT_A1_RUN")
  MUT_M4_TEXT=$(awk '
    /            local verdict_summary_fail/ { c=1 }
    c { print; if ($0 == "            } | atomic_write \"$fix_contract\"") exit }
  ' "$MUT_A1_RUN")
  f2r3_harness_mut() {
    local vfile="$1" hf="$TMPD/f2r3-harness-mut.zsh"
    cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { echo "LOG: \$*"; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
_append_verified_ledger() { return 0; }
VERDICT_FILE='$vfile'
ITERATION=1
LOGS_DIR='$TMPD'
signal_us_id='US-002'
SETUP
    # round 5 P3 follow-up: same real production line as the other
    # harnesses — this mutation targets the M4 rendering block (A1), not
    # the verdict read, so it stays unmutated here too.
    print -r -- "$PROD_VERDICT_READ_LINE" >> "$hf"
    cat >> "$hf" <<SETUP
VERIFIED_US=''
_pre_upgrade_worker_model='haiku'
CONSECUTIVE_FAILURES=0
typeset -gA US_FIX_CONTRACT US_ATTEMPT_HISTORY
SETUP
    print -r -- "$MUT_H1_OVERRIDE" >> "$hf"
    print -r -- "$MUT_H1_CREDIT" >> "$hf"
    print -r -- "$MUT_M4_TEXT" >> "$hf"
    print -r -- 'echo "RESULT_ATTEMPT=${US_ATTEMPT_HISTORY[US-002]:-}"' >> "$hf"
    zsh "$hf" 2>&1
  }
  f=$(vf a1-mut "$(printf '{"verdict":"approved","summary":"%s","criteria_results":"garbage"}' "$A1_SUMMARY")")
  out=$(f2r3_harness_mut "$f")
  attempt=$(echo "$out" | sed -n 's/^RESULT_ATTEMPT=//p')
  echo "$attempt" | grep -q "$A1_MARKER" \
    && ok "A1-mut.1 mutation control effective — under APPEND, the marker survives (proves A1's absence check tests the real replace fix)" \
    || no "A1-mut.1 mutation control INEFFECTIVE — marker still absent without the fix (got: $attempt)"
fi

# A2: HONEST fail (verdict "fail") + top-level malformed criteria_results +
# a >120-char verifier summary. The note must be PREPENDED so it survives
# _record_us_attempt's 120-char truncation.
f=$(vf a2-honest-toplevel-malformed-long "$(printf '{"verdict":"fail","summary":"%s","criteria_results":"garbage"}' "$LONGX")")
out=$(f2r3_harness "$f")
attempt=$(echo "$out" | sed -n 's/^RESULT_ATTEMPT=//p')
echo "$attempt" | grep -qi 'not an array\|not credited' \
  && ok "A2: honest-fail + top-level-malformed note survives 120-char truncation (prepended)" \
  || no "A2: the honest-fail malformed note was truncated away — got: $attempt"

# A3: HONEST fail + ENTRY-level malformed criterion + a >120-char summary —
# same prepend requirement as A2.
f=$(vf a3-honest-entry-malformed-long "$(printf '{"verdict":"fail","summary":"%s","criteria_results":[{"criterion":"AC1","met":"false"}]}' "$LONGX")")
out=$(f2r3_harness "$f")
attempt=$(echo "$out" | sed -n 's/^RESULT_ATTEMPT=//p')
echo "$attempt" | grep -qi 'malformed\|not credited' \
  && ok "A3: honest-fail + entry-level-malformed note survives 120-char truncation (prepended)" \
  || no "A3: the honest-fail entry-malformed note was truncated away — got: $attempt"

echo ""
echo "--- Round 4 item B: fail-variant original verdicts stay honest; non-object verdict file gets a real placeholder ---"

# B1: verdict "FAIL." (punctuation variant of fail) with a REAL diagnosis
# summary and well-formed criteria (no malformed entries) — must be treated
# exactly like an honest "fail": not untrusted, keeps crediting, summary
# untouched.
f=$(vf b1-failpunct '{"verdict":"FAIL.","summary":"US-002 AC2 regression test missing (real diagnosis)","criteria_results":[{"criterion":"AC2","met":false,"missing_evidence":"no test"}],"per_us_results":{"US-001":"pass"}}')
out=$(f2r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
attempt=$(echo "$out" | sed -n 's/^RESULT_ATTEMPT=//p')
[[ "$fired" == "0" ]] \
  && ok "B1: 'FAIL.' (a fail-variant) is treated as an honest fail, not a true override (fired=0)" \
  || no "B1: expected fired=0 for a fail-variant original verdict, got fired=$fired (out: $out)"
[[ "$vus" == "US-001" ]] \
  && ok "B1: fail-variant honest fail still credits US-001" \
  || no "B1: expected US-001 credited, got VERIFIED_US=$vus"
echo "$attempt" | grep -q 'US-002 AC2 regression test missing (real diagnosis)' \
  && ok "B1: the real diagnosis summary is untouched (not replaced, not annotated)" \
  || no "B1: expected the real diagnosis summary unchanged — got: $attempt"

# B2: the whole VERDICT_FILE is a top-level JSON array (not an object) —
# `.verdict` cannot even be read, so the pre-override verdict is empty. The
# fix-contract heading must not render an empty-quoted "reported ''".
f=$(vf b2-arrfile '["not","an","object"]')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -q "reported ''" \
  && no "B2: fix contract heading renders an empty 'reported '''' placeholder (fc: $fc_body)" \
  || ok "B2: fix contract heading does not render an empty-quoted verdict"
echo "$fc_body" | grep -qi 'no top-level verdict' \
  && ok "B2: fix contract heading uses an honest '<no top-level verdict>' placeholder" \
  || no "B2: expected a '<no top-level verdict>' placeholder in the heading (fc: $fc_body)"

echo ""
echo "--- Round 4 item C: heading depends only on _cr_true_override; note distinguishes entry vs top-level ---"

# C1: honest fail + top-level malformed -> the non-override heading, worded
# exactly as specified, and the entry-vs-top-level note says "not an array".
f=$(vf c1-honest-toplevel '{"verdict":"fail","summary":"real summary","criteria_results":"garbage"}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -q '## Criteria Results (untrusted — partial progress not credited)' \
  && ok "C1: honest fail + top-level malformed uses the exact non-override heading" \
  || no "C1: expected the exact non-override heading (fc: $fc_body)"
echo "$fc_body" | grep -qi 'not an array' \
  && ok "C1: note text names the top-level shape (not an array)" \
  || no "C1: expected 'not an array' in the note (fc: $fc_body)"

# C2: honest fail + entry-level malformed -> same non-override heading, but
# the note names the ENTRY-level shape (count of malformed entries), not
# "not an array".
f=$(vf c2-honest-entry '{"verdict":"fail","summary":"real summary","criteria_results":[{"criterion":"AC1","met":"false"},{"criterion":"AC2","met":true}]}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -q '## Criteria Results (untrusted — partial progress not credited)' \
  && ok "C2: honest fail + entry-level malformed uses the SAME exact non-override heading" \
  || no "C2: expected the exact non-override heading (fc: $fc_body)"
echo "$fc_body" | grep -Eqi '[0-9]+ malformed criteria_results entr(y|ies)' \
  && ok "C2: note text names the entry-level shape (N malformed criteria_results entry/entries)" \
  || no "C2: expected an entry-count note, distinct from the top-level wording (fc: $fc_body)"

# C3 regression: a TRUE override still uses the "## Criteria Results
# Override" heading (unchanged from round 3).
f=$(vf c3-true-override '{"verdict":"pass","criteria_results":"garbage"}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -q '## Criteria Results Override' \
  && ok "C3 REGRESSION: a true override still uses the '## Criteria Results Override' heading" \
  || no "C3 regression broken — expected the override heading for a real override (fc: $fc_body)"

echo ""
echo "--- Round 4 item D: pre-gate L1.5 short-circuit log line names the real reason, not an empty violations list ---"

D_SNIPPET=$(awk '
  /if \(\( ! _pg_short \)\); then/ { f=1 }
  f { print; if ($0 == "        fi") exit }
' "$RUN")
[[ -n "$D_SNIPPET" ]] && echo "$D_SNIPPET" | grep -q 'run_pregate_doneclaim_lint' \
  && ok "D extraction sanity: Layer 1.5 block found in real source" \
  || no "D extraction sanity: Layer 1.5 block NOT found (marker text changed?)"

d_harness() { # $1=PREGATE_LINT_REASON $2=PREGATE_LINT_VIOLATIONS
  local reason="$1" violations="$2" hf="$TMPD/d-harness.zsh"
  cat > "$hf" <<SETUP
log() { echo "LOG:\$*"; }; log_debug() { :; }
run_pregate_doneclaim_lint() { PREGATE_LINT_STATUS="fail"; PREGATE_LINT_REASON='$reason'; PREGATE_LINT_VIOLATIONS='$violations'; }
_pregate_register_fail_doneclaim_lint() { return 0; }
_pg_short=0; _pg_force=0
ITERATION=6; signal_us_id='US-001'
PREGATE_FAILURES=1; PREGATE_FAIL_CAP=5
SETUP
  print -r -- "$D_SNIPPET" >> "$hf"
  zsh "$hf" 2>&1
}

out=$(d_harness "approach_summary_missing" "[]")
echo "$out" | grep -qi 'approach_summary_missing' \
  && ok "D: short-circuit log line names 'approach_summary_missing', not just the empty violations list" \
  || no "D: expected 'approach_summary_missing' in the log line (got: $out)"
echo "$out" | grep -q 'done-claim format lint: \[\])' \
  && no "D: log line still shows the bare empty violations list '[]' with no real reason" \
  || ok "D: log line no longer shows a bare empty violations list for approach_summary_missing"

# Regression: a normal TDD-sequence violation (no approach_summary_missing
# reason) still shows the real per-AC violations list, unchanged.
out=$(d_harness "" '[{"ac":"AC1","idx":[0,2]}]')
echo "$out" | grep -q 'AC1' \
  && ok "D REGRESSION: a normal TDD-sequence violation still shows its real per-AC violations list" \
  || no "D regression broken — expected the real violations list for a non-approach_summary_missing fail (got: $out)"

##############################################################################
# Round 5 (codex final pass on round 4)
##############################################################################
echo ""
echo "--- Round 5 P2: fail* prefix match is unbounded — bounded fail-alias match instead ---"

# P2: "failsafe-pass" (normalizes to "failsafe_pass") starts with "fail" but
# is NOT an honest fail — it must be treated as a TRUE override: not
# credited, summary replaced. The old unbounded `fail*` glob wrongly let it
# through as an honest fail.
f=$(vf p2-failsafe-pass '{"verdict":"failsafe-pass","per_us_results":{"US-001":"pass"},"summary":"looks great","criteria_results":[{"criterion":"AC1","met":false}]}')
out=$(f2r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
vus=$(echo "$out" | sed -n 's/^RESULT_VERIFIED_US=//p')
[[ "$fired" == "1" ]] \
  && ok "P2.1 'failsafe-pass' is treated as a true override (fired=1), not an honest fail" \
  || no "P2.1 expected fired=1 for 'failsafe-pass' (unbounded fail* glob bug), got fired=$fired (out: $out)"
[[ -z "$vus" ]] \
  && ok "P2.2 'failsafe-pass' override correctly suppresses per_us_results crediting" \
  || no "P2.2 expected no credit, got VERIFIED_US=$vus"

# Same for "failover" (also starts with "fail" but is not a fail alias).
f=$(vf p2-failover '{"verdict":"failover","per_us_results":{"US-001":"pass"},"summary":"looks great","criteria_results":[{"criterion":"AC1","met":false}]}')
out=$(f2r3_harness "$f")
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
[[ "$fired" == "1" ]] \
  && ok "P2.3 'failover' is also treated as a true override (fired=1), not an honest fail" \
  || no "P2.3 expected fired=1 for 'failover', got fired=$fired (out: $out)"

# Regression: genuine fail-aliases (bounded) must still be recognized as
# honest fails — "fail.", "failed", "failure", "failing", "fail: details".
for fv in 'fail.' 'failed' 'failure' 'failing' 'fail: see issues'; do
  f=$(vf "p2-genuine-$(echo "$fv" | tr -cd 'a-z')" "$(printf '{"verdict":"%s","per_us_results":{"US-001":"pass"},"summary":"real diagnosis","criteria_results":[{"criterion":"AC1","met":false}]}' "$fv")")
  out=$(f2r3_harness "$f")
  fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
  [[ "$fired" == "0" ]] \
    && ok "P2 REGRESSION: '$fv' is still recognized as a genuine fail-alias (fired=0)" \
    || no "P2 regression broken — '$fv' should be an honest fail, got fired=$fired (out: $out)"
done

echo ""
echo "--- Round 5 P3: a missing/null verdict field must render '<no top-level verdict>', not literal 'null' ---"

# P3: NO "verdict" key at all — jq -r '.verdict' returns the literal string
# "null" for a missing key, which is non-empty, so the old
# `${_cr_original_verdict:-<no top-level verdict>}` fallback never fired and
# the heading rendered "reported 'null'" instead of an honest placeholder.
f=$(vf p3-missing-verdict '{"criteria_results":"garbage"}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -qi "reported 'null'" \
  && no "P3.1 fix contract heading renders the literal 'null' instead of an honest placeholder (fc: $fc_body)" \
  || ok "P3.1 fix contract heading does not render a literal 'null' verdict"
echo "$fc_body" | grep -qi 'no top-level verdict' \
  && ok "P3.2 fix contract heading uses the '<no top-level verdict>' placeholder for a missing verdict field" \
  || no "P3.2 expected the '<no top-level verdict>' placeholder (fc: $fc_body)"
fired=$(echo "$out" | sed -n 's/^RESULT_FIRED=//p')
[[ "$fired" == "1" ]] \
  && ok "P3.3 a missing verdict field is treated as non-fail (a true override fires)" \
  || no "P3.3 expected fired=1 for a missing verdict field, got fired=$fired (out: $out)"

# Explicit JSON null verdict — same "null" literal bug via a different route.
f=$(vf p3-null-verdict '{"verdict":null,"criteria_results":"garbage"}')
out=$(f2r3_harness "$f")
fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
fc_body=$(cat "$fc_path" 2>/dev/null)
echo "$fc_body" | grep -qi "reported 'null'" \
  && no "P3.4 explicit JSON null verdict still renders literal 'null' (fc: $fc_body)" \
  || ok "P3.4 explicit JSON null verdict does not render literal 'null'"
echo "$fc_body" | grep -qi 'no top-level verdict' \
  && ok "P3.5 explicit JSON null verdict uses the '<no top-level verdict>' placeholder" \
  || no "P3.5 expected the placeholder for an explicit null verdict (fc: $fc_body)"

echo "--- Round 5 P3 mutation control ---"
MUT_P3_RUN="$TMPD/run_mut_p3.zsh"
cp "$RUN" "$MUT_P3_RUN"
python3 - "$MUT_P3_RUN" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
old = "jq -r '.verdict // empty'"
new = "jq -r '.verdict'"
assert old in text, "P3 mutation anchor not found (the '.verdict // empty' read moved?)"
with open(path, "w") as f:
    f.write(text.replace(old, new, 1))
PYEOF
if [[ $? -ne 0 ]]; then
  no "P3-mut.0 mutation setup failed (could not revert '// empty' to bare '.verdict')"
else
  ok "P3-mut.0 mutation setup reverted '.verdict // empty' back to bare '.verdict' on a scratch copy"
  MUT_P3_VERDICT_LINE=$(grep -A1 -- '^        local verdict=""$' "$MUT_P3_RUN" | tail -1)
  p3_mut_harness() { # $1=verdict_file
    local vfile="$1" hf="$TMPD/p3-mut-harness.zsh"
    cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { echo "LOG: \$*"; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
_append_verified_ledger() { return 0; }
VERDICT_FILE='$vfile'
ITERATION=1
LOGS_DIR='$TMPD'
signal_us_id='US-002'
SETUP
    print -r -- "$MUT_P3_VERDICT_LINE" >> "$hf"
    cat >> "$hf" <<SETUP
VERIFIED_US=''
_pre_upgrade_worker_model='haiku'
CONSECUTIVE_FAILURES=0
typeset -gA US_FIX_CONTRACT US_ATTEMPT_HISTORY
SETUP
    print -r -- "$H1_OVERRIDE_SNIPPET" >> "$hf"
    print -r -- "$H1_CREDIT_SNIPPET" >> "$hf"
    print -r -- "$M4_TEXT" >> "$hf"
    print -r -- 'echo "RESULT_FIX_CONTRACT_PATH=$fix_contract"' >> "$hf"
    zsh "$hf" 2>&1
  }
  f=$(vf p3-mut-missing-verdict '{"criteria_results":"garbage"}')
  out=$(p3_mut_harness "$f")
  fc_path=$(echo "$out" | sed -n 's/^RESULT_FIX_CONTRACT_PATH=//p')
  fc_body=$(cat "$fc_path" 2>/dev/null)
  echo "$fc_body" | grep -qi "reported 'null'" \
    && ok "P3-mut.1 mutation control effective — reverting '// empty' brings back the literal 'null' rendering (proves P3.1/P3.2 test the real fix)" \
    || no "P3-mut.1 mutation control INEFFECTIVE — still no literal 'null' rendering without the fix (fc: $fc_body)"
fi

##############################################################################
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
