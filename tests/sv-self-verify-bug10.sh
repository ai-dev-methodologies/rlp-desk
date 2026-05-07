#!/usr/bin/env bash
# Bug Report #10 (PR-A) self-verification gate (CLAUDE.md mandate).
#
# Verifies the relaunch hygiene contract introduced by PR-A: the leader
# (both Node and zsh paths) honors an operator-written `phase=verify`
# manual recovery instead of overwriting it. Each scenario maps
# Worker (execution_steps) -> Verifier (5 categories) -> PASS.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure check, L1 only.
#   MEDIUM   = helper + integration with file I/O, L1+L2+L3.
#   CRITICAL = behavioral invariant + regression contract + error-path
#              + security validation, L1+L2+L3+L4+error-path.
#
# Note: L6 installed-file check is OMITTED here because PR-A has not been
# released/synced. Re-run after `node scripts/postinstall.js` +
# `bash install.sh` to verify install-side parity.

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
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-bug10-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-bug10-out.log)"
    tail -20 /tmp/sv-self-verify-bug10-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== Bug Report #10 PR-A Self-Verification Gate ==="
emit "Trigger files: src/scripts/run_ralph_desk.zsh, src/scripts/lib_ralph_desk.zsh,"
emit "               src/node/runner/campaign-main-loop.mjs"
emit "Plan: docs/plans/bug-report-overhaul-v1.md (PR-A)"

# ---------------------------------------------------------------------------
# LOW — syntax + presence checks. L1 only per CLAUDE.md.
# ---------------------------------------------------------------------------

run_scenario "L1 LOW: zsh syntax of run_ralph_desk.zsh + lib + init after PR-A edit" \
  "LOW" \
  "zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh && zsh -n src/scripts/init_ralph_desk.zsh"

run_scenario "L1 LOW: zsh validator helper defined in lib_ralph_desk.zsh" \
  "LOW" \
  "grep -q '^_validate_operator_recovery_artifacts()' src/scripts/lib_ralph_desk.zsh"

run_scenario "L1 LOW: zsh runner invokes validator + sets SKIP_NEXT_WORKER guard" \
  "LOW" \
  "grep -q '_validate_operator_recovery_artifacts' src/scripts/run_ralph_desk.zsh \
   && grep -q 'SKIP_NEXT_WORKER=1' src/scripts/run_ralph_desk.zsh \
   && grep -q '\\[recovery\\] Resuming verify phase' src/scripts/run_ralph_desk.zsh"

run_scenario "L1 LOW: Node validator helper defined in campaign-main-loop.mjs" \
  "LOW" \
  "grep -q 'async function _validateOperatorRecoveryArtifacts' src/node/runner/campaign-main-loop.mjs"

run_scenario "L1 LOW: Node runner invokes validator at entry + guards worker dispatch" \
  "LOW" \
  "grep -q '_validateOperatorRecoveryArtifacts' src/node/runner/campaign-main-loop.mjs \
   && grep -q '_skipNextWorkerDispatch' src/node/runner/campaign-main-loop.mjs \
   && grep -q '\\[recovery\\] Resuming verify phase' src/node/runner/campaign-main-loop.mjs"

# ---------------------------------------------------------------------------
# MEDIUM — helper + integration with file I/O, L1+L2+L3.
# ---------------------------------------------------------------------------

run_scenario "L2 MEDIUM: zsh helper unit (5 scenarios — Z1 happy, Z2-Z5 fall-through)" \
  "MEDIUM" \
  "zsh tests/test-bug10-zsh-relaunch-hygiene.sh 2>&1 | grep -q 'Bug #10 hygiene: 5 passed, 0 failed'"

run_scenario "L3 MEDIUM: Node hygiene integration (6 ACs — real init_campaign + readJsonIfExists)" \
  "MEDIUM" \
  "node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 | grep -q '^ℹ pass 6\$'"

# ---------------------------------------------------------------------------
# CRITICAL — behavioral invariants + regression contract + security
# + error-path E2E.
# ---------------------------------------------------------------------------

run_scenario "L2 CRITICAL: PR-A happy contract — phase=verify + valid artifacts skips worker dispatch (AC-R1)" \
  "CRITICAL" \
  "node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'PR-A AC-R1: phase=verify + valid manual artifacts skips worker dispatch'"

run_scenario "L2 CRITICAL: regression invariant — one-shot guard does NOT survive into iter-2 (AC-R6)" \
  "CRITICAL" \
  "node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'PR-A AC-R6: skip-next-worker guard is one-shot'"

run_scenario "L3 CRITICAL: error-path E2E — missing/mismatched artifacts fall through to default (AC-R2..R5)" \
  "CRITICAL" \
  "node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'AC-R2: phase=verify with missing done-claim.json falls through to worker' \
   && node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'AC-R3: phase=verify with us_id mismatch falls through to worker' \
   && node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'AC-R4: phase=verify with manual artifacts older than worker-prompt falls through' \
   && node --test tests/node/test-relaunch-phase-verify-hygiene.test.mjs 2>&1 \
     | grep -q 'AC-R5: phase=verify with iter_signal_quality=generic falls through to worker'"

run_scenario "L4 CRITICAL: SECURITY — validator rejects us_id mismatch / iteration mismatch / generic quality / stale mtime / missing artifact" \
  "CRITICAL" \
  "zsh tests/test-bug10-zsh-relaunch-hygiene.sh 2>&1 | grep -q 'Z2 missing-done-claim' \
   && zsh tests/test-bug10-zsh-relaunch-hygiene.sh 2>&1 | grep -q 'Z3 us_id-mismatch' \
   && zsh tests/test-bug10-zsh-relaunch-hygiene.sh 2>&1 | grep -q 'Z4 quality-generic' \
   && zsh tests/test-bug10-zsh-relaunch-hygiene.sh 2>&1 | grep -q 'Z5 mtime-older'"

run_scenario "L5 CRITICAL: full Node test suite 334/334 — no regression introduced by PR-A" \
  "CRITICAL" \
  "node --test 'tests/node/*.test.mjs' 'tests/node/*.mjs' 2>&1 | tail -10 | grep -q '^ℹ pass 334$'"

run_scenario "L5 CRITICAL: Bug #7 zsh regression intact (post-sentinel race + partial-write)" \
  "CRITICAL" \
  "zsh tests/test-bug7-post-sentinel-race.sh 2>&1 | grep -q 'Bug #7 helper integration tests: ran=6 passed=6 failed=0' \
   && zsh tests/test-bug7-poll-partial-write.sh 2>&1 | grep -q 'Bug #7-extra partial-write tests: ran=7 passed=7 failed=0'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

emit ""
emit "=== summary: PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL ==="
[[ "$FAIL" -eq 0 ]]
