#!/bin/zsh
# ============================================================================
# F-17 contract test: the verifier-prompt softening must (a) relax PROCESS/FORMAT
# meta-gates (so codex/gpt-5.5 stops rejecting correct work for formatting) while
# (b) keeping the real CORRECTNESS gates strict (no verification weakening).
# Deterministic grep contract over the generators (init_ralph_desk.zsh verifier
# prompt + governance.md IL-3). No LLM.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

ROOT="${0:A:h:h:h}"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"
GOV="$ROOT/src/governance.md"

print -P "%F{cyan}F-17 verifier gate contract (format soft, correctness strict)%f"

# --- SOFTENED: format/process meta is no longer a hard FAIL ---
grep -q 'Layer Enforcement (IL-3)' "$INIT" && grep -q 'NOT mandatory' "$INIT" \
  && ok "softened: layer-section headers / N/A markers NOT mandatory (init verifier prompt)" \
  || no "layer-format softening missing from verifier prompt"
grep -q 'AGGREGATE RED evidence is acceptable' "$INIT" \
  && ok "softened: aggregate (vs per-AC) RED evidence accepted" || no "per-AC RED softening missing"
grep -q 'Process-meta is NOT a PASS-blocker' "$INIT" \
  && ok "softened: process-meta is a warning, not a PASS-blocker (when ACs green)" || no "process-meta principle missing"
grep -q 'ACTUAL verification COVERAGE, not test-spec FORMAT' "$GOV" \
  && ok "softened: governance IL-3 = coverage not format" || no "governance IL-3 softening missing"

# --- ANTI-REGRESSION: the old pedantic auto-FAIL line must be GONE ---
grep -q 'ANY section with TODO or blank = FAIL (IL-3)' "$INIT" \
  && no "REGRESSION: old pedantic 'ANY section TODO/blank = FAIL' still present" \
  || ok "removed: the old format-pedantic auto-FAIL line is gone"

# --- STRICT (must remain — NO verification weakening) ---
grep -q 'Count < 3 per AC = FAIL' "$INIT" \
  && ok "strict KEPT: IL-4 test sufficiency (<3 tests/AC = FAIL)" || no "IL-4 strictness LOST — verification weakened!"
grep -qiE 'Skip detection|did not actually execute|skipped tests detected' "$INIT" \
  && ok "strict KEPT: IL-5 skip detection (skipped tests = FAIL)" || no "IL-5 skip-detection LOST — weakened!"
grep -qiE 'execute ALL commands from test-spec' "$INIT" \
  && ok "strict KEPT: Evidence Gate runs ALL test-spec commands (fresh)" || no "Evidence Gate LOST — weakened!"
grep -qiE 'Anti-Gaming' "$INIT" \
  && ok "strict KEPT: Anti-Gaming detection" || no "Anti-Gaming LOST — weakened!"
grep -q 'Count < 3 per any AC = FAIL' "$GOV" \
  && ok "strict KEPT: governance IL-4 test sufficiency" || no "governance IL-4 LOST — weakened!"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-17 gate contract: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-17 gate contract: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
