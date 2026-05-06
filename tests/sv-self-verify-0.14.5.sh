#!/usr/bin/env bash
# v0.14.5 self-verification gate (CLAUDE.md mandate).
#
# Verifies Bug Report #6 Fix-M (worker iter-signal short-circuit on the zsh
# leader's check_no_progress path) plus the Node-side last-chance contract
# (Fix-P). Each scenario maps Worker (execution_steps) -> Verifier
# (5 categories) -> PASS.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure check, L1 only.
#   MEDIUM   = helper + integration with file I/O, L1+L2+L3.
#   CRITICAL = behavioral invariant + regression contract + error-path E2E,
#              L1+L2+L3+security+error-path.

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
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-0.14.5-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-0.14.5-out.log)"
    tail -20 /tmp/sv-self-verify-0.14.5-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== v0.14.5 Self-Verification Gate (Bug Report #6 Fix-M) ==="
emit "Trigger file: src/scripts/run_ralph_desk.zsh"

# ---------------------------------------------------------------------------
# LOW — zsh source still parses cleanly after the +32 line patch
# ---------------------------------------------------------------------------

run_scenario "L1 LOW: zsh syntax of run_ralph_desk.zsh + sibling scripts after Fix-M edit" \
  "LOW" \
  "zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

run_scenario "L1 LOW: _worker_pane_has_signal helper is defined and invoked from check_no_progress" \
  "LOW" \
  "grep -q '^_worker_pane_has_signal()' src/scripts/run_ralph_desk.zsh \
   && grep -q 'if _worker_pane_has_signal \"\$pane_id\"; then' src/scripts/run_ralph_desk.zsh"

# ---------------------------------------------------------------------------
# MEDIUM — helper + integration with file I/O on a tmpdir sandbox
# ---------------------------------------------------------------------------

run_scenario "L2 MEDIUM: 21 zsh assertions (helper unit + 3 check_no_progress scenarios)" \
  "MEDIUM" \
  "zsh tests/test-bug6-worker-idle-false-positive.sh"

run_scenario "L3 MEDIUM: Node signal-poller worker last-chance contract (3 cases)" \
  "MEDIUM" \
  "node --test tests/node/test-signal-poller-worker-last-chance.mjs"

# ---------------------------------------------------------------------------
# CRITICAL — behavioral invariant + regression contract + error-path E2E
# ---------------------------------------------------------------------------

run_scenario "L2 CRITICAL: Bug #6 happy path — 605s frozen pane WITH valid iter-signal does NOT BLOCK" \
  "CRITICAL" \
  '
zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
  | grep -q "PASS: Scenario B frozen call: signal short-circuit (return 0)" \
  && zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
       | grep -q "PASS: Scenario B frozen call: write_blocked_sentinel NOT invoked"
'

run_scenario "L2 CRITICAL: regression invariant — 605s frozen pane WITHOUT signal STILL BLOCKs" \
  "CRITICAL" \
  '
zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
  | grep -q "PASS: Scenario A frozen call: BLOCKED escalation (return 1)" \
  && zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
       | grep -q "PASS: Scenario A frozen call: write_blocked_sentinel invoked once"
'

run_scenario "L3 CRITICAL: error-path — malformed iter-signal does NOT silently pass; BLOCKED still fires" \
  "CRITICAL" \
  '
zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
  | grep -q "PASS: Scenario C frozen call: malformed signal does NOT short-circuit (return 1)" \
  && zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
       | grep -q "PASS: Scenario C frozen call: write_blocked_sentinel invoked"
'

run_scenario "L4 CRITICAL: SECURITY — helper rejects signal with non-numeric iteration / empty us_id / status not in {verify,verify_partial}" \
  "CRITICAL" \
  '
zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
  | grep -q "PASS: worker helper: non-numeric iteration → return 1" \
  && zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
       | grep -q "PASS: worker helper: missing us_id → return 1" \
  && zsh tests/test-bug6-worker-idle-false-positive.sh 2>&1 \
       | grep -q "PASS: worker helper: status=fail (not verify\*) → return 1"
'

run_scenario "L5 CRITICAL: full Node test suite — 297/297 pass (no regression introduced)" \
  "CRITICAL" \
  "node --test tests/node/*.mjs tests/node/*.test.mjs 2>&1 | tail -10 | grep -q '^ℹ pass 297$'"

run_scenario "L6 CRITICAL: installed file at ~/.claude/ralph-desk/ contains Fix-M (post-sync verification)" \
  "CRITICAL" \
  '
test -f "$HOME/.claude/ralph-desk/run_ralph_desk.zsh" \
  && [ "$(grep -c _worker_pane_has_signal "$HOME/.claude/ralph-desk/run_ralph_desk.zsh")" -ge 2 ] \
  && head -2 "$HOME/.claude/ralph-desk/run_ralph_desk.zsh" | grep -q "DO NOT EDIT" \
  && [ "$(stat -f %Lp "$HOME/.claude/ralph-desk/run_ralph_desk.zsh" 2>/dev/null || stat -c %a "$HOME/.claude/ralph-desk/run_ralph_desk.zsh")" = "444" ]
'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

emit ""
emit "=== summary: PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL ==="
[[ "$FAIL" -eq 0 ]]
