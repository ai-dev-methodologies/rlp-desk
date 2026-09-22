#!/bin/zsh
# reaudit wave 1: criteria_results LOAD-BEARING (governance §1f maker-checker rule).
#
# BEFORE this fix, the leader read only the top-level `.verdict` field from
# verify-verdict.json and never consumed `.criteria_results` at all (grep
# -rn 'criteria_results' src/scripts/*.zsh returned only the contract
# template line in init_ralph_desk.zsh — no consumer). An adversarial probe
# showed a verdict with top-level "verdict":"pass" while an individual
# criterion carried "met":false + "evidence":"missing_evidence: ..." sailing
# through uncontested — the leader credited the US anyway. That is exactly
# the partial-credit failure the maker-checker rule this project is built on
# forbids.
#
# This suite verifies:
#   1. _verdict_criteria_effective() (lib_ralph_desk.zsh) — the new pure
#      helper — against the absent / malformed / empty / populated states,
#      including malformed per-entry `met` values.
#   2. The two real call sites (main-loop verdict dispatch, and
#      _final_verify_one_us — the sequential final-verify gate) by
#      EXTRACTING the shipped lines out of run_ralph_desk.zsh by content
#      marker and EXECUTING them against fixture verdict files — this is the
#      mutation control: it runs the actual production lines, not a retyped
#      re-assertion of what they are supposed to do.
set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT/src/scripts/lib_ralph_desk.zsh"

source "$LIB" 2>/dev/null

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); print -P "  %F{green}PASS%f: $1"; }
no() { FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f: $1"; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

vf() { # write a verdict fixture, print its path
  local name="$1" body="$2"
  local f="$TMPD/$name.json"
  print -r -- "$body" > "$f"
  print -r -- "$f"
}

print -- "=== reaudit wave 1: criteria_results load-bearing ==="
echo ""
print -- "--- Part 1: _verdict_criteria_effective (lib_ralph_desk.zsh) unit tests ---"

f=$(vf absent-missing '{"verdict":"pass"}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "absent|0|0" ]] && ok "1 key missing -> absent|0|0" || no "1 key missing (got: $r)"

f=$(vf absent-null '{"verdict":"pass","criteria_results":null}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "absent|0|0" ]] && ok "2 explicit null -> absent|0|0" || no "2 explicit null (got: $r)"

f=$(vf malformed-obj '{"verdict":"pass","criteria_results":{"AC1":true}}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "malformed|0|0" ]] && ok "3 object (not array) -> malformed|0|0" || no "3 object (got: $r)"

f=$(vf malformed-str '{"verdict":"pass","criteria_results":"none"}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "malformed|0|0" ]] && ok "4 string (not array) -> malformed|0|0" || no "4 string (got: $r)"

f=$(vf empty-arr '{"verdict":"pass","criteria_results":[]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "empty|0|0" ]] && ok "5 empty array -> empty|0|0 (distinct from absent)" || no "5 empty array (got: $r)"

f=$(vf populated-allmet '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":true},{"criterion":"AC2","met":true}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|0|0" ]] && ok "6 all met:true -> populated|0|0" || no "6 all met:true (got: $r)"

f=$(vf populated-onefalse '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":true},{"criterion":"AC2","met":false,"evidence":"missing_evidence"}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|1|0" ]] && ok "7 THE ADVERSARIAL CASE: one met:false -> populated|1|0" || no "7 one met:false (got: $r)"

f=$(vf populated-missingmet '{"verdict":"pass","criteria_results":[{"criterion":"AC1"},{"criterion":"AC2","met":true}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|0|1" ]] && ok "8 entry missing 'met' -> counted malformed, NOT unmet (no false-positive fail)" || no "8 missing met (got: $r)"

f=$(vf populated-stringmet '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":"false"}]}')
r=$(_verdict_criteria_effective "$f")
[[ "$r" == "populated|0|1" ]] && ok "9 non-boolean met (string \"false\") -> malformed entry, NOT unmet" || no "9 met as string (got: $r)"

r=$(_verdict_criteria_effective "$TMPD/does-not-exist.json")
[[ "$r" == "absent|0|0" ]] && ok "10 missing verdict file -> absent|0|0, no crash" || no "10 missing file (got: $r)"

echo ""
print -- "--- Part 2: call-site override, extracted PRODUCTION code ---"

extract_marked() { # <start-marker-substring> <stop-line-exact-regex>
  awk -v start="$1" -v stopre="$2" '
    $0 ~ start { c=1 }
    c { print; if ($0 ~ stopre) exit }
  ' "$RUN"
}

main_loop_snippet=$(extract_marked 'reaudit wave 1: make criteria_results LOAD-BEARING' '^        fi$')
final_verify_snippet=$(extract_marked 'reaudit wave 1: criteria_results is load-bearing here too' '^  fi$')

[[ -n "$main_loop_snippet" ]] || no "EXTRACT: main-loop snippet not found in $RUN (marker text changed?)"
[[ -n "$final_verify_snippet" ]] || no "EXTRACT: _final_verify_one_us snippet not found in $RUN (marker text changed?)"

# --- main-loop site harness ---
# ITERATION / signal_us_id / verdict are the real globals the extracted
# snippet reads and mutates in run_ralph_desk.zsh's main(); log/log_debug/
# log_error are stubbed (their real bodies write to files/stdout using
# globals not set up in this harness) but the extracted DECISION code
# (jq parsing, the fail override, which branch logs what) is 100% real.
main_loop_harness() {
  local vfile="$1" top_verdict="$2" hf="$TMPD/mainloop-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { :; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
VERDICT_FILE='$vfile'
ITERATION=1
signal_us_id='US-001'
verdict='$top_verdict'
SETUP
  print -r -- "$main_loop_snippet" >> "$hf"
  print -r -- 'echo "RESULT_VERDICT=$verdict"' >> "$hf"
  zsh "$hf" 2>&1
}

f=$(vf mainloop-adversarial '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":true},{"criterion":"AC2","met":false}]}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "11 main-loop: top=pass + met:false -> overridden to fail" \
  || no "11 main-loop: pass+met:false (got: $out)"
print -r -- "$out" | grep -q 'LOGGED_ERROR:.*contract violation' \
  && ok "12 main-loop: pass+met:false logged as a distinct CONTRACT VIOLATION" \
  || no "12 main-loop: contract-violation log missing (got: $out)"

f=$(vf mainloop-absent '{"verdict":"pass"}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=pass$' \
  && ok "13 main-loop: absent array does NOT override pass (backward compat)" \
  || no "13 main-loop: absent (got: $out)"

# SV-gate CRITICAL finding (fix/reaudit-wave-1, 2026-09-14): this assertion
# originally expected malformed to ride through exactly like absent
# (RESULT_VERDICT=pass) — that WAS the bug. Malformed means the Verifier
# tried to emit the field that decides the verdict and produced garbage;
# crediting a US on that basis is exactly the partial-credit this control
# exists to prevent. Absent (tested above) stays permissive; malformed does
# not — it must not crash, but it must also not silently pass.
f=$(vf mainloop-malformed '{"verdict":"pass","criteria_results":"oops"}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "14 main-loop: malformed (non-array) does not crash and overrides to fail (distinct from absent)" \
  || no "14 main-loop: malformed (got: $out)"
print -r -- "$out" | grep -q 'LOGGED_ERROR:.*malformed' \
  && ok "14b main-loop: malformed logged distinctly (not conflated with the unmet-count contract-violation line)" \
  || no "14b main-loop: malformed log line missing/wrong (got: $out)"

f=$(vf mainloop-empty '{"verdict":"pass","criteria_results":[]}')
out=$(main_loop_harness "$f" "pass")
print -r -- "$out" | grep -q '^RESULT_VERDICT=pass$' \
  && ok "15 main-loop: empty array does not override" \
  || no "15 main-loop: empty (got: $out)"

f=$(vf mainloop-failplusfalse '{"verdict":"fail","criteria_results":[{"criterion":"AC1","met":false}]}')
out=$(main_loop_harness "$f" "fail")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "16 main-loop: already-fail stays fail" \
  || no "16 main-loop: already-fail (got: $out)"
print -r -- "$out" | grep -q 'LOGGED_ERROR:.*contract violation' \
  && no "17 main-loop: top=fail + met:false must NOT be mislabeled a CONTRACT VIOLATION (top-level already agrees)" \
  || ok "17 main-loop: fail+met:false not mislabeled a contract violation"

# --- _final_verify_one_us site harness ---
final_verify_harness() {
  local vfile="$1" hf="$TMPD/finalverify-harness.zsh"
  cat > "$hf" <<SETUP
source '$LIB' 2>/dev/null
log() { :; }
log_debug() { :; }
log_error() { echo "LOGGED_ERROR: \$*" >&2; }
VERDICT_FILE='$vfile'
us='US-001'
iter=1
verdict=\$(_normalize_verdict "\$(jq -r '.verdict' "\$VERDICT_FILE" 2>/dev/null)")
SETUP
  print -r -- "$final_verify_snippet" >> "$hf"
  print -r -- 'echo "RESULT_VERDICT=$verdict"' >> "$hf"
  zsh "$hf" 2>&1
}

f=$(vf finalverify-adversarial '{"verdict":"pass","criteria_results":[{"criterion":"AC1","met":false}]}')
out=$(final_verify_harness "$f")
print -r -- "$out" | grep -q '^RESULT_VERDICT=fail$' \
  && ok "18 _final_verify_one_us: top=pass + met:false -> overridden to fail" \
  || no "18 _final_verify_one_us (got: $out)"

f=$(vf finalverify-absent '{"verdict":"pass"}')
out=$(final_verify_harness "$f")
print -r -- "$out" | grep -q '^RESULT_VERDICT=pass$' \
  && ok "19 _final_verify_one_us: absent array does not override" \
  || no "19 _final_verify_one_us absent (got: $out)"

echo ""
print -- "--- Part 3 (informational, not scored): consensus-merge survival ---"
# _consensus_finalize (run_ralph_desk.zsh) builds a NEW merged verdict JSON
# for both the agree-pass and disagreement branches. If it does not carry
# criteria_results through, the fix above is inert whenever CONSENSUS_MODE
# is on (all|final-only) — reported to the team lead, NOT fixed here (owned
# by the consensus-merge lane, not the verdict-consumption lane).
if awk '/^_consensus_finalize\(\)/{c=1} c{print} c && /^}$/{exit}' "$RUN" | grep -q 'criteria_results'; then
  print "  INFO: _consensus_finalize already propagates criteria_results."
else
  print "  INFO: _consensus_finalize does NOT propagate criteria_results — the merged"
  print "        VERDICT_FILE in consensus mode never carries the array, so this fix"
  print "        is INERT under CONSENSUS_MODE=all|final-only. Reported to team lead."
fi

echo ""
echo "============================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "============================================"
(( FAIL == 0 ))
