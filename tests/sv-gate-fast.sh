#!/bin/zsh
# v5.7 §4.24 — Mechanical SV gate (FAST).
#
# Verifies the file-guarantee contract via:
#   1. Code-pattern greps (each tracked fix has the expected code)
#   2. Node unit tests (primary behavioral assertions)
#   3. Critical zsh unit tests
#
# Target: < 30s wallclock. Run on every commit.
# For full E2E + campaign verification, run sv-gate-full.sh instead.
#
# Exit 0 = SV gate PASS. Anything non-zero = FAIL, do not commit.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
TOTAL=0

red()    { print -P "%F{red}$*%f"; }
green()  { print -P "%F{green}$*%f"; }
yellow() { print -P "%F{yellow}$*%f"; }
bold()   { print -P "%B$*%b"; }

check() {
  TOTAL=$((TOTAL+1))
  local label="$1"; shift
  if "$@" &>/dev/null; then
    PASS=$((PASS+1))
    green "  ✓ $label"
  else
    FAIL=$((FAIL+1))
    red   "  ✗ $label"
  fi
}

bold "▶ SV Gate FAST — code patterns"
# v5.7 §4.13 Bug 4 — auto_dismiss
check "Bug 4 zsh §4.13.b auto_dismiss_prompts exists" \
  grep -q "^auto_dismiss_prompts()" src/scripts/run_ralph_desk.zsh
check "Bug 4 Node prompt-dismisser exists" \
  test -f src/node/runner/prompt-dismisser.mjs
# v5.7 §4.14 Bug 5 — A4 fallback prompt guard
check "Bug 5 §4.14 A4 fallback suspended" \
  grep -q "A4 fallback suspended" src/scripts/run_ralph_desk.zsh
# v5.7 §4.16 prompt-stall escalation
check "§4.16 prompt-stall escalation" \
  grep -q "PROMPT_STALL_TIMEOUT" src/scripts/run_ralph_desk.zsh
# v5.7 §4.17 default-No BLOCK
check "§4.17 default-No BLOCK (zsh)" \
  grep -q "_DEFAULT_NO_RE" src/scripts/run_ralph_desk.zsh
check "§4.17 default-No BLOCK (Node)" \
  grep -q "DEFAULT_NO_RE" src/node/runner/prompt-dismisser.mjs
# v5.7 §4.17.b scrollback contamination scan-all
check "§4.17.b scrollback contamination scan-all (zsh)" \
  grep -q "default_no_seen" src/scripts/run_ralph_desk.zsh
check "§4.17.b scrollback contamination scan-all (Node)" \
  grep -q "defaultNoSeen" src/node/runner/prompt-dismisser.mjs
# v5.7 §4.18 unknown-prompt fast-fail
check "§4.18 unknown-prompt fast-fail (zsh)" \
  grep -q "_ACTIVE_TASK_RE" src/scripts/run_ralph_desk.zsh
check "§4.18 unknown-prompt fast-fail (Node)" \
  grep -q "ACTIVE_TASK_RE" src/node/runner/prompt-dismisser.mjs
# v5.7 §4.19 Node iterTimeout forwarded
check "§4.19 Node iterTimeoutMs forwarded" \
  grep -q "timeoutMs: iterTimeoutMs" src/node/runner/campaign-main-loop.mjs
# v5.7 §4.20 claude v2.x trust prompt patterns
check "§4.20 claude v2.x trust pattern (Node)" \
  grep -q "Quick safety check" src/node/runner/prompt-dismisser.mjs
check "§4.20 claude v2.x trust pattern (zsh)" \
  grep -q "Quick safety check" src/scripts/run_ralph_desk.zsh
# v5.7 §4.21 capture window expansion + whitespace normalization
check "§4.21 capture window -50 (Node)" \
  grep -q "'-50'" src/node/polling/signal-poller.mjs
check "§4.21 whitespace normalization (zsh)" \
  grep -q "_norm_capture" src/scripts/run_ralph_desk.zsh
# v5.7 §4.22 WorkerExitedError
check "§4.22 WorkerExitedError class" \
  grep -q "class WorkerExitedError" src/node/polling/signal-poller.mjs
check "§4.22 WorkerExitedError caught in worker poll" \
  grep -q "instanceof WorkerExitedError" src/node/runner/campaign-main-loop.mjs
# v5.7 §4.23 tail-15 normalized matching
check "§4.23 tail-15 normalized (Node)" \
  grep -q "tailNormalized" src/node/runner/prompt-dismisser.mjs
check "§4.23 tail-15 normalized (zsh)" \
  grep -q "_tail_normalized" src/scripts/run_ralph_desk.zsh
# v5.7 §4.24 file-guarantee contract
check "§4.24 writeSentinelExclusive exists" \
  grep -q "export async function writeSentinelExclusive" src/node/shared/fs.mjs
check "§4.24 writeSentinelExclusive imported in main loop" \
  grep -q "writeSentinelExclusive" src/node/runner/campaign-main-loop.mjs
check "§4.24 writeSentinel uses exclusive primitive" \
  grep -q "await writeSentinelExclusive(filePath" src/node/runner/campaign-main-loop.mjs
check "§4.24 §1g run() try/finally backstop" \
  grep -q "_ensureTerminalSentinel" src/node/runner/campaign-main-loop.mjs
# v5.7 §4.25 — uniform poll-failure handling + schema validator
check "§4.25 BLOCK_TAGS frozen enum" \
  grep -q "export const BLOCK_TAGS = Object.freeze" src/node/runner/campaign-main-loop.mjs
check "§4.25 _handlePollFailure helper" \
  grep -q "async function _handlePollFailure" src/node/runner/campaign-main-loop.mjs
check "§4.25 MalformedArtifactError class" \
  grep -q "export class MalformedArtifactError" src/node/runner/campaign-main-loop.mjs
check "§4.25 validateArtifact function" \
  grep -q "function validateArtifact" src/node/runner/campaign-main-loop.mjs
check "§4.25 worker poll uses _handlePollFailure" \
  grep -q "role: 'worker'" src/node/runner/campaign-main-loop.mjs
check "§4.25 verifier poll uses _handlePollFailure" \
  grep -q "role: 'verifier'" src/node/runner/campaign-main-loop.mjs
check "§4.25 final_verifier poll uses _handlePollFailure" \
  grep -q "role: 'final_verifier'" src/node/runner/campaign-main-loop.mjs
check "§4.25 flywheel poll uses _handlePollFailure" \
  grep -q "role: 'flywheel'" src/node/runner/campaign-main-loop.mjs
check "§4.25 guard poll uses _handlePollFailure" \
  grep -q "role: 'guard'" src/node/runner/campaign-main-loop.mjs
# v0.15.4 PR-B2-FIX — done-claim reaper extension across the 4 substrate sites.
check "B2-FIX zsh site 1: handle_worker_exit_codex locks DONE_CLAIM_FILE" \
  bash -c 'awk "/^handle_worker_exit_codex\\(\\)/,/^}/" src/scripts/run_ralph_desk.zsh | grep -q "_lock_sentinel \"\$DONE_CLAIM_FILE\""'
check "B2-FIX zsh site 2: A4 fallback inline kills worker pane (worker-a4)" \
  grep -q '_kill_pane_process "$pane_id" "worker-a4"' src/scripts/run_ralph_desk.zsh
check "B2-FIX zsh site 3: post iter-signal reaper locks DONE_CLAIM_FILE" \
  grep -qE 'PR-B2-FIX.*Freeze' src/scripts/run_ralph_desk.zsh
check "B2-FIX Node site: lockSentinel(paths.doneClaimFile) after worker reap" \
  grep -q 'lockSentinel(paths.doneClaimFile' src/node/runner/campaign-main-loop.mjs
# v0.15.4 PR-B4 — Lifecycle observability (flag-gated on RLP_LIFECYCLE_METRICS=1)
check "B4 LIFECYCLE category whitelisted in debug-log VALID_CATEGORIES" \
  grep -qE "VALID_CATEGORIES = new Set.*'LIFECYCLE'" src/node/util/debug-log.mjs
check "B4 LifecycleMetricsCollector module exists" \
  test -f src/node/util/lifecycle-metrics.mjs
check "B4 zsh log_lifecycle_metric helper exists" \
  grep -q "^log_lifecycle_metric()" src/scripts/lib_ralph_desk.zsh
check "B4 zsh helper gated on RLP_LIFECYCLE_METRICS" \
  grep -q 'RLP_LIFECYCLE_METRICS:-0' src/scripts/lib_ralph_desk.zsh
check "B4 Node leader instantiates LifecycleMetricsCollector" \
  grep -q "new LifecycleMetricsCollector" src/node/runner/campaign-main-loop.mjs
check "B4 lifecycle_metrics flushed into appendIterationAnalytics" \
  grep -q "lifecycle_metrics: lifecycleSnapshot" src/node/runner/campaign-main-loop.mjs
# v0.15.4 PR-B3 — Real-LLM SV scenarios with two-stage lifecycle assertions.
check "B3 shared lifecycle assertion helper exists" \
  test -f tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
check "B3 helper exports b3_assert_lifecycle_metrics_present" \
  grep -q "^b3_assert_lifecycle_metrics_present()" tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
check "B3 helper exports b3_assert_lifecycle_metric_within_band" \
  grep -q "^b3_assert_lifecycle_metric_within_band()" tests/sv-real-llm/lib/b3-lifecycle-assertions.sh
check "B3 bug-05 sources B3 helper + RLP_LIFECYCLE_METRICS=1" \
  grep -q "RLP_LIFECYCLE_METRICS=1" tests/sv-real-llm/scenarios/bug-05-worker-dead-on-reuse.test.sh
check "B3 bug-05 calls Stage 1 presence assertion" \
  grep -q "b3_assert_lifecycle_metrics_present" tests/sv-real-llm/scenarios/bug-05-worker-dead-on-reuse.test.sh
check "B3 bug-07 sources B3 helper + RLP_LIFECYCLE_METRICS=1" \
  grep -q "RLP_LIFECYCLE_METRICS=1" tests/sv-real-llm/scenarios/bug-07-post-sentinel-race.test.sh
check "B3 bug-07 calls Stage 1 presence assertion" \
  grep -q "b3_assert_lifecycle_metrics_present" tests/sv-real-llm/scenarios/bug-07-post-sentinel-race.test.sh
check "B3 bug-06 untouched (structural \$0 retained per plan v3 ADR)" \
  bash -c '! grep -q "RLP_LIFECYCLE_METRICS" tests/sv-real-llm/scenarios/bug-06-claude-worker-idle-noprogress.test.sh'

bold ""
bold "▶ SV Gate FAST — Node unit tests"
NODE_TESTS=(
  tests/node/test-prompt-dismisser.mjs
  tests/node/test-shell-quote.mjs
  tests/node/test-opus-1m-context.mjs
  tests/node/test-leader-registry.mjs
  tests/node/test-debug-log.mjs
  tests/node/test-sentinel-exclusive.mjs
  tests/node/test-leader-exit-invariant.mjs
  tests/node/test-lying-worker.mjs
  tests/node/test-artifact-schema.mjs
  tests/node/test-sentinel-reaper-invariant.test.mjs
  tests/node/test-lifecycle-metrics.test.mjs
  tests/node/test-campaign-jsonl-shape.test.mjs
  tests/node/test-b3-band-revalidation.test.mjs
  tests/node/sv-e2e/test-lying-verifier.mjs
  tests/node/sv-e2e/test-prompt-blocked.mjs
)
for t in $NODE_TESTS; do
  check "$(basename $t)" node "$t"
done

bold ""
bold "▶ SV Gate FAST — Critical zsh unit tests"
ZSH_TESTS=(
  tests/test_auto_dismiss_prompts.sh
  tests/test_a4_fallback_prompt_guard.sh
  tests/test_prompt_stall_escalation.sh
  tests/test_no_progress_and_default_no.sh
  tests/test_us012_sv_tmux_skip_traceability.sh
  tests/test_b2fix_sentinel_lock.sh
)
for t in $ZSH_TESTS; do
  check "$(basename $t)" zsh "$t"
done

bold ""
print "─────────────────────────────────────────────────"
if (( FAIL == 0 )); then
  green "▶ SV GATE FAST: $PASS/$TOTAL pass — OK"
else
  red   "▶ SV GATE FAST: $PASS/$TOTAL pass, $FAIL FAIL — DO NOT COMMIT"
fi
print "─────────────────────────────────────────────────"
exit $(( FAIL == 0 ? 0 : 1 ))
