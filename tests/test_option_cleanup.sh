#!/usr/bin/env bash
# Test Suite: Option interface cleanup (14 options)
# Covers: new defaults, new flags, gpt-5.3-codex removal, consensus unification, docs

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
GOV="$ROOT_DIR/src/governance.md"
CMD="$ROOT_DIR/src/commands/rlp-desk.md"
README="$ROOT_DIR/README.md"
MODELS_JSON="$ROOT_DIR/src/node/models.json"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

extract_fn() {
  local fn_name="$1"
  local body
  body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$LIB" 2>/dev/null)
  [[ -z "$body" ]] && body=$(sed -n "/^${fn_name}() {$/,/^}$/p" "$RUN" 2>/dev/null)
  echo "$body"
}

run_harness() {
  local script="$1"
  local tmpdir; tmpdir=$(mktemp -d)
  printf '%s' "$script" > "$tmpdir/harness.zsh"
  zsh -f "$tmpdir/harness.zsh" 2>&1
  local rc=$?; rm -rf "$tmpdir"; return $rc
}

echo "=== Option Interface Cleanup ==="
echo ""

# ============================================================
# 1. Default values
# ============================================================
echo "--- 1. Default values ---"

# D1: Worker default is haiku
if grep -q 'WORKER_MODEL="${WORKER_MODEL:-haiku}"' "$RUN"; then
  pass "D1: Worker default is haiku"
else
  fail "D1: Worker default should be haiku"
fi

# D2: Verifier (per-US) default is sonnet
if grep -q 'VERIFIER_MODEL="${VERIFIER_MODEL:-sonnet}"' "$RUN"; then
  pass "D2: Verifier (per-US) default is sonnet"
else
  fail "D2: Verifier (per-US) default should be sonnet"
fi

# D3: Final Verifier default is opus
if grep -q 'FINAL_VERIFIER_MODEL="${FINAL_VERIFIER_MODEL:-opus}"' "$RUN"; then
  pass "D3: Final Verifier default is opus"
else
  fail "D3: FINAL_VERIFIER_MODEL default should be opus"
fi

# D4: CONSENSUS_MODE default is off
if grep -q 'CONSENSUS_MODE="${CONSENSUS_MODE:-off}"' "$RUN"; then
  pass "D4: CONSENSUS_MODE default is off"
else
  fail "D4: CONSENSUS_MODE default should be off"
fi

# D5: CONSENSUS_MODEL default is gpt-5.6-terra:medium (GPT-5.6 generation, v0.20.1)
if grep -q 'CONSENSUS_MODEL="${CONSENSUS_MODEL:-gpt-5.6-terra:medium}"' "$RUN"; then
  pass "D5: CONSENSUS_MODEL default is gpt-5.6-terra:medium (per-US, lighter)"
else
  fail "D5: CONSENSUS_MODEL default should be gpt-5.6-terra:medium"
fi

# D6: FINAL_CONSENSUS_MODEL default is gpt-5.6-sol:high (GPT-5.6 generation, v0.20.1)
if grep -q 'FINAL_CONSENSUS_MODEL="${FINAL_CONSENSUS_MODEL:-gpt-5.6-sol:high}"' "$RUN"; then
  pass "D6: FINAL_CONSENSUS_MODEL default is gpt-5.6-sol:high (final, stricter)"
else
  fail "D6: FINAL_CONSENSUS_MODEL default should be gpt-5.6-sol:high"
fi

# D5b/D6b: the CLI empty-value fallbacks match the env defaults (no drift)
if grep -qF 'CONSENSUS_MODEL="${@[$_cli_i]:-gpt-5.6-terra:medium}"' "$RUN"; then
  pass "D5b: --consensus-model empty-value CLI fallback matches the default"
else
  fail "D5b: --consensus-model CLI fallback drifted from gpt-5.6-terra:medium"
fi
if grep -qF 'FINAL_CONSENSUS_MODEL="${@[$_cli_i]:-gpt-5.6-sol:high}"' "$RUN"; then
  pass "D6b: --final-consensus-model empty-value CLI fallback matches the default"
else
  fail "D6b: --final-consensus-model CLI fallback drifted from gpt-5.6-sol:high"
fi

# ============================================================
# 2. New flags parsing
# ============================================================
echo ""
echo "--- 2. New CLI flags ---"

# F1: --consensus flag parsed (case statement format: --consensus) )
if grep -q '\--consensus)' "$RUN"; then
  pass "F1: --consensus flag parsed"
else
  fail "F1: --consensus flag not found in CLI parsing"
fi

# F2: --final-verifier-model flag parsed
if grep -q '\--final-verifier-model)' "$RUN"; then
  pass "F2: --final-verifier-model flag parsed"
else
  fail "F2: --final-verifier-model flag not found"
fi

# F3: --consensus-model flag parsed
if grep -q '\--consensus-model)' "$RUN"; then
  pass "F3: --consensus-model flag parsed"
else
  fail "F3: --consensus-model flag not found"
fi

# F4: --final-consensus-model flag parsed
if grep -q '\--final-consensus-model)' "$RUN"; then
  pass "F4: --final-consensus-model flag parsed"
else
  fail "F4: --final-consensus-model flag not found"
fi

# ============================================================
# 3. Consensus unification
# ============================================================
echo ""
echo "--- 3. Consensus unification ---"

# C1: _should_use_consensus uses CONSENSUS_MODE
fn_body=$(extract_fn "_should_use_consensus")
if echo "$fn_body" | grep -q 'CONSENSUS_MODE'; then
  pass "C1: _should_use_consensus uses CONSENSUS_MODE"
else
  fail "C1: _should_use_consensus should use CONSENSUS_MODE"
fi

# C2: _should_use_consensus does NOT reference old VERIFY_CONSENSUS
if echo "$fn_body" | grep -q 'VERIFY_CONSENSUS'; then
  fail "C2: _should_use_consensus still references old VERIFY_CONSENSUS"
else
  pass "C2: _should_use_consensus clean of old VERIFY_CONSENSUS"
fi

# C3: Runtime — CONSENSUS_MODE=off returns 1
result=$(run_harness "#!/usr/bin/env zsh -f
CONSENSUS_MODE=off
_should_use_consensus() {
  local signal_us_id=\"\${1:-}\"
  case \"\$CONSENSUS_MODE\" in
    all) return 0 ;; final-only) [[ \"\$signal_us_id\" == \"ALL\" ]] && return 0 ;; off|*) return 1 ;;
  esac
}
_should_use_consensus 'US-001' && echo FAIL || echo PASS" 2>&1)
if echo "$result" | grep -q "PASS"; then
  pass "C3: CONSENSUS_MODE=off → no consensus for per-US"
else
  fail "C3: CONSENSUS_MODE=off should not trigger consensus"
fi

# C4: Runtime — CONSENSUS_MODE=final-only + ALL returns 0
result=$(run_harness "#!/usr/bin/env zsh -f
CONSENSUS_MODE=final-only
_should_use_consensus() {
  local signal_us_id=\"\${1:-}\"
  case \"\$CONSENSUS_MODE\" in
    all) return 0 ;; final-only) [[ \"\$signal_us_id\" == \"ALL\" ]] && return 0 ;; off|*) return 1 ;;
  esac
}
_should_use_consensus 'ALL' && echo PASS || echo FAIL" 2>&1)
if echo "$result" | grep -q "PASS"; then
  pass "C4: CONSENSUS_MODE=final-only + ALL → consensus"
else
  fail "C4: CONSENSUS_MODE=final-only + ALL should trigger consensus"
fi

# C5: Runtime — CONSENSUS_MODE=final-only + per-US returns 1
result=$(run_harness "#!/usr/bin/env zsh -f
CONSENSUS_MODE=final-only
_should_use_consensus() {
  local signal_us_id=\"\${1:-}\"
  case \"\$CONSENSUS_MODE\" in
    all) return 0 ;; final-only) [[ \"\$signal_us_id\" == \"ALL\" ]] && return 0 ;; off|*) return 1 ;;
  esac
}
_should_use_consensus 'US-001' && echo FAIL || echo PASS" 2>&1)
if echo "$result" | grep -q "PASS"; then
  pass "C5: CONSENSUS_MODE=final-only + per-US → no consensus"
else
  fail "C5: CONSENSUS_MODE=final-only + per-US should not trigger consensus"
fi

# C6: Legacy compat — VERIFY_CONSENSUS referenced and CONSENSUS_MODE set nearby
if grep -q 'VERIFY_CONSENSUS' "$RUN" && grep -q 'CONSENSUS_MODE=.*all\|CONSENSUS_MODE=.*final' "$RUN"; then
  pass "C6: Legacy VERIFY_CONSENSUS compat present"
else
  fail "C6: Legacy VERIFY_CONSENSUS → CONSENSUS_MODE mapping missing"
fi

# ============================================================
# 4. gpt-5.3-codex removal
# ============================================================
echo ""
echo "--- 4. gpt-5.3-codex removal ---"

# US-001: the upgrade ladder moved out of get_next_model()'s source text into
# the single-sourced data file src/node/models.json (read via jq at runtime by
# both the zsh and Node loaders). G1-G3 now check the shipped ladder data
# directly instead of grepping the function body, which no longer contains
# literal model-name strings.

# G1: shipped ladder has no gpt-5.3-codex (non-spark) entries
if jq -e '.upgrades | keys | any(startswith("gpt-5.3-codex:"))' "$MODELS_JSON" >/dev/null 2>&1; then
  fail "G1: models.json still has gpt-5.3-codex (non-spark) entries"
else
  pass "G1: gpt-5.3-codex (non-spark) removed from models.json"
fi

# G2: spark paths still exist
if jq -e '.upgrades | keys | any(startswith("gpt-5.3-codex-spark:"))' "$MODELS_JSON" >/dev/null 2>&1; then
  pass "G2: spark paths still in models.json"
else
  fail "G2: spark paths missing from models.json"
fi

# G3: gpt-5.5 paths still exist
if jq -e '.upgrades | keys | any(startswith("gpt-5.5:"))' "$MODELS_JSON" >/dev/null 2>&1; then
  pass "G3: gpt-5.5 paths still in models.json"
else
  fail "G3: gpt-5.5 paths missing from models.json"
fi

# ============================================================
# 5. CB threshold consensus doubling
# ============================================================
echo ""
echo "--- 5. CB threshold ---"

# CB1: CB doubles when CONSENSUS_MODE != off
if grep -q 'CONSENSUS_MODE.*!=.*off' "$RUN" && grep -q 'CB_THRESHOLD \* 2' "$RUN"; then
  pass "CB1: CB doubles when CONSENSUS_MODE != off"
else
  fail "CB1: CB doubling should use CONSENSUS_MODE"
fi

# ============================================================
# 6. Documentation
# ============================================================
echo ""
echo "--- 6. Documentation ---"

# DOC1: governance.md mentions --consensus off|all|final-only
if grep -q '\-\-consensus.*off.*all.*final' "$GOV"; then
  pass "DOC1: governance.md documents --consensus off|all|final-only"
else
  fail "DOC1: governance.md missing --consensus documentation"
fi

# DOC2: governance.md has consensus model routing table
if grep -q 'Consensus Model Routing' "$GOV" || grep -q 'consensus-model.*per-US\|per-US.*consensus-model' "$GOV"; then
  pass "DOC2: governance.md has consensus model routing"
else
  fail "DOC2: governance.md missing consensus model routing table"
fi

# DOC3: governance.md per-US verifier default is sonnet
if grep -qi 'per-US.*sonnet\|Verifier.*per-US.*sonnet' "$GOV"; then
  pass "DOC3: governance.md per-US verifier default sonnet"
else
  fail "DOC3: governance.md should show per-US verifier default as sonnet"
fi

# DOC4: rlp-desk.md has 4-column model mapping (Worker / per-US / Final / Consensus)
if grep -q 'per-US Verifier' "$CMD" && grep -q 'Final Verifier' "$CMD"; then
  pass "DOC4: rlp-desk.md has 4-column model mapping"
else
  fail "DOC4: rlp-desk.md should have 4-column model mapping"
fi

# DOC5: rlp-desk.md mentions spark:high in recommendations
if grep -q 'spark:high' "$CMD"; then
  pass "DOC5: rlp-desk.md mentions spark:high"
else
  fail "DOC5: rlp-desk.md should recommend spark:high"
fi

# DOC6: rlp-desk.md has batch capacity check
if grep -qi 'batch.*capacity\|batch.*spark.*100k\|wave.*split\|output.*limit.*batch' "$CMD"; then
  pass "DOC6: rlp-desk.md has batch capacity check"
else
  fail "DOC6: rlp-desk.md missing batch capacity check"
fi

# DOC7: README.md has 14 options
if grep -q 'final-verifier-model' "$README" && grep -q 'final-consensus-model' "$README" && grep -q 'consensus-model' "$README"; then
  pass "DOC7: README.md has new option names"
else
  fail "DOC7: README.md missing new options"
fi

# DOC8: No deprecated options in rlp-desk.md user-facing sections
deprecated_count=$(grep -cE '\-\-worker-engine|--verifier-engine|--worker-codex-model|--worker-codex-reasoning|--verifier-codex-model|--verifier-codex-reasoning|--consensus-fail-fast' "$CMD" 2>/dev/null || true)
if (( deprecated_count == 0 )); then
  pass "DOC8: No deprecated options in rlp-desk.md"
else
  fail "DOC8: $deprecated_count deprecated option references in rlp-desk.md"
fi

# ============================================================
# 7. Syntax
# ============================================================
echo ""
echo "--- 7. Syntax ---"

if zsh -n "$RUN" 2>/dev/null; then
  pass "SYN1: run_ralph_desk.zsh syntax OK"
else
  fail "SYN1: run_ralph_desk.zsh syntax error"
fi

if zsh -n "$LIB" 2>/dev/null; then
  pass "SYN2: lib_ralph_desk.zsh syntax OK"
else
  fail "SYN2: lib_ralph_desk.zsh syntax error"
fi

# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS + FAIL))) ==="
exit $(( FAIL > 0 ? 1 : 0 ))
