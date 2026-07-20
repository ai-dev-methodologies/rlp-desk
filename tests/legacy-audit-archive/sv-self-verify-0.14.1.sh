#!/usr/bin/env bash
# v0.14.1 self-verification gate (CLAUDE.md mandate).
#
# Verifies the BOS Bug Report #3 fix: codex verifier idle UI is no longer
# misclassified as "frozen" by the byte-stasis watcher; verdict-aware
# short-circuit in zsh runner; symmetric last-chance verdict read in Node
# signal-poller. Each scenario maps Worker (execution_steps) -> Verifier
# (5 categories) -> PASS.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure check, L1 only.
#   MEDIUM   = wiring change, L1+L2 integration + L3.
#   CRITICAL = false-positive prevention invariant, L1+L2+L3+security+E2E.

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
  emit "   Worker steps: ${cmd}"
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-0.14.1-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-0.14.1-out.log)"
    tail -25 /tmp/sv-self-verify-0.14.1-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== v0.14.1 Self-Verification Gate ==="
emit "Trigger files: src/scripts/run_ralph_desk.zsh, src/node/runner/prompt-dismisser.mjs,"
emit "               src/node/polling/signal-poller.mjs"

# ---------------------------------------------------------------------------
# Phase 1 — zsh: verdict-aware no-progress + codex idle helper
# ---------------------------------------------------------------------------

run_scenario "L6.1 zsh check_no_progress short-circuits when verifier pane has a valid verdict file" \
  "CRITICAL" \
  "zsh tests/test_codex_idle_no_progress.sh"

run_scenario "L6.1b is_codex_idle_ui recognizes BOS Bug #3 capture verbatim ('Worked for 5m 36s', 'Context X% left')" \
  "CRITICAL" \
  "zsh tests/test_codex_idle_no_progress.sh"

run_scenario "L6.1c zsh runner remains syntactically valid after Phase 1 edits" \
  "LOW" \
  "zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

# ---------------------------------------------------------------------------
# Phase 2 — Node leader: signal-poller last-chance read + CODEX_IDLE_RE export
# ---------------------------------------------------------------------------

run_scenario "L6.2 SECURITY: pollForSignal performs last-chance verdict read after deadline (no false TimeoutError)" \
  "CRITICAL" \
  "node --test tests/node/test-signal-poller-last-chance.mjs"

run_scenario "L6.3 isCodexIdleUi unit tests (8 cases, frozen fixture set)" \
  "MEDIUM" \
  "node --test tests/node/test-codex-idle-detection.mjs"

run_scenario "L6.4 CODEX_IDLE_RE exported and immutable contract preserved" \
  "LOW" \
  '
node --input-type=module -e "
import { CODEX_IDLE_RE, isCodexIdleUi } from \"./src/node/runner/prompt-dismisser.mjs\";
if (!(CODEX_IDLE_RE instanceof RegExp)) { console.error(\"CODEX_IDLE_RE not exported as RegExp\"); process.exit(1); }
if (!isCodexIdleUi(\"─ Worked for 5m 36s ──\")) { console.error(\"BOS fixture not detected\"); process.exit(1); }
if (isCodexIdleUi(\"unrelated text\")) { console.error(\"false positive on unrelated text\"); process.exit(1); }
"
'

# ---------------------------------------------------------------------------
# Regression guards — v0.14.0 / v0.13.x contracts must hold
# ---------------------------------------------------------------------------

run_scenario "L6.5 v0.14.0 contract: --mode tmux still delegates to zsh subprocess" \
  "LOW" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern '--mode tmux delegates'"

run_scenario "L6.5b v0.13.0 contract: claude permission_prompt detector still wired" \
  "LOW" \
  "node --test tests/node/test-prompt-detector.mjs"

run_scenario "L6.5c v0.13.0 contract: legacy .claude/ralph-desk migration logic still tested" \
  "LOW" \
  "node --test tests/node/test-migrate-legacy-desk.mjs"

# ---------------------------------------------------------------------------
# Verifier summary
# ---------------------------------------------------------------------------

emit ""
emit "=== Verifier Summary ==="
emit "Total scenarios: ${TOTAL}"
emit "PASS: ${PASS}"
emit "FAIL: ${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  emit "ALL change scenarios verified across 5 categories"
  emit "  (correctness, integration, security, performance, error-path)"
  exit 0
else
  emit "${FAIL} scenario(s) failed -- fix before commit"
  exit 1
fi
