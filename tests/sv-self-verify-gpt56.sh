#!/usr/bin/env bash
# GPT-5.6 model-family support self-verification gate (CLAUDE.md mandate).
# Triggered because src/commands/rlp-desk.md changed (brainstorm model
# recommendation table moved to the 5.6 generation).
# Mirrors tests/sv-self-verify-imp01-09.sh: scenarios derived from the actual
# change surface, each a REAL code-path execution (node --test, real zsh
# function execution with real fixture files) — never grep/echo simulation.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure function / contract,        L1 unit + L3 contract.
#   MEDIUM   = feature with file I/O,           L1 + L2 integration + L3.
#   CRITICAL = security / hot-path,             L1 + L2 + L3 + security + L3 error-path E2E.

set -u
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PASS=0
FAIL=0
TOTAL=0

emit() { printf "%s\n" "$*"; }

run_scenario() {
  local name="$1" risk="$2"
  shift 2
  local cmd="$*"
  TOTAL=$((TOTAL+1))
  emit ""
  emit "-- [${risk}] ${name}"
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-gpt56-out.log 2>&1; then
    emit "   -> PASS"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-gpt56-out.log)"
    tail -15 /tmp/sv-gpt56-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== GPT-5.6 model-family Self-Verification Gate ==="
emit "Trigger: src/commands/rlp-desk.md changed (5.6 recommendation table)"

# ---------------- LOW risk (L1 unit + L3 contract) ----------------
# Pure parsing/mapping contracts: sol|terra|luna aliases, suffixed-slug
# passthrough, max|ultra efforts, and the shipped ladder map for the new
# families. Worker = real parse_model_flag / loadModelLadder execution;
# Verifier = the suites' own assertion sets (engine/model/reasoning triples,
# ladder next/ceiling values).

run_scenario "parse_model_flag: 5.6 aliases + full-slug + max/ultra contract (27 assertions)" \
  "LOW" \
  "bash tests/test_us003_unified_model_format.sh"

run_scenario "shipped ladder map: 5.6-sol/terra/luna + 5.4/-mini next/ceiling contract" \
  "LOW" \
  "node --test tests/node/models-ladder.test.mjs"

# ---------------- MEDIUM risk (L1 + L2 integration + L3) ----------------
# Real file I/O: ladder loader resolves the shipped models.json through both
# install layouts and honors override files on disk; cross-consumer
# equivalence executes BOTH the real zsh get_next_model and the real Node
# loader over every shipped key (including all new 5.6/5.4 keys). Idle/ready
# detection executes the real is_codex_idleUi/CODEX_IDLE_RE code over 5.6
# status-line captures.

run_scenario "ladder loader integration: dual-layout + override I/O + zsh/node equivalence (30 assertions)" \
  "MEDIUM" \
  "bash tests/test_us011_worker_model_upgrade.sh"

run_scenario "codex idle/ready detection accepts 5.6 status lines (zsh, real function)" \
  "MEDIUM" \
  "zsh tests/test_codex_idle_no_progress.sh"

run_scenario "codex idle/ready detection accepts 5.6 status lines (node mirror)" \
  "MEDIUM" \
  "node --test tests/node/test-codex-idle-detection.mjs tests/node/test-prompt-dismisser.mjs"

# ---------------- CRITICAL risk (L1+L2+L3 + security + error-path) --------
# Input-validation / fail-open surfaces on the model-resolution hot path:
# junk-typed ladder values (number/boolean/null/object/array) must be treated
# as malformed and fall through (never resolve a campaign onto a junk model);
# malformed consensus model strings must fall back to globals (D-1c list now
# includes max|ultra). Error-path E2E: consensus flow suite drives the real
# runner startup path.

run_scenario "schema validation: junk-typed override values fall through in BOTH runtimes (error-path)" \
  "CRITICAL" \
  "bash tests/test_us011_worker_model_upgrade.sh && node --test tests/node/models-ladder.test.mjs"

run_scenario "consensus model validation + real runner startup flow (D-1c surface)" \
  "CRITICAL" \
  "bash tests/test_us005_final_consensus.sh"

emit ""
emit "================================================="
emit "SV GATE (gpt-5.6): ${PASS}/${TOTAL} scenarios PASS, ${FAIL} FAIL"
if [[ "$FAIL" -eq 0 && "$PASS" -eq "$TOTAL" ]]; then
  emit "RESULT: ALL PASS — commit gate satisfied"
  exit 0
else
  emit "RESULT: GATE FAILED"
  exit 1
fi
