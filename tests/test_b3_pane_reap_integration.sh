#!/usr/bin/env zsh
# B3 zsh-leader lifecycle port — pane-reap INTEGRATION proof (no real-LLM).
#
# test_b3_lifecycle_emit.sh proves write_campaign_jsonl drains a pre-populated
# LIFECYCLE_RECORDS. It does NOT prove the one live emit site — _kill_pane_process
# (lib:372) — actually calls log_lifecycle_metric. This closes that gap end-to-end:
#
#   real _kill_pane_process (the SAME function the leader calls at run:3838 on every
#   worker-pane reap, and 2968/3075/4152 on verifier reaps)
#     -> log_lifecycle_metric "pane_eof_to_cleanup_ms"
#       -> LIFECYCLE_RECORDS (parent-shell accumulator)
#         -> write_campaign_jsonl drains into campaign.jsonl.lifecycle_metrics
#           -> b3_assert_lifecycle_metrics_present (B3-S1) PASSes on a NON-EMPTY array.
#
# This is the production code path the real-LLM SV scenarios exercise around an LLM
# worker; the metric-emit chain is identical. tmux is isolated to a private -L socket
# via a `tmux` shim so the user's default server is never touched.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
B3="$REPO/tests/sv-real-llm/lib/b3-lifecycle-assertions.sh"
SOCK="b3paneint-$$"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

command -v tmux >/dev/null 2>&1 || { print "SKIP: tmux not available"; exit 0; }
cleanup(){ command tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# Route every bare `tmux` (incl. the ones inside _kill_pane_process) to a private
# socket so the test never disturbs the operator's default tmux server.
tmux(){ command tmux -L "$SOCK" "$@"; }

# shellcheck source=src/scripts/lib_ralph_desk.zsh
source "$LIB" 2>/dev/null
source "$B3"

# Stub the leader logging helpers AFTER sourcing (the lib defines its own, which
# dereference $DEBUG and would trip `set -u`). These shadow them with no-ops.
log(){ :; }
log_debug(){ :; }

# A real pane so send-keys / wait_for_pane_ready do real work. wait_for_pane_ready
# lives in run_ralph_desk.zsh (sourcing that runs the whole leader), so stub it as a
# faithful bounded readiness poll — the metric measures kill-start -> this return.
wait_for_pane_ready(){ command tmux -L "$SOCK" list-panes 2>/dev/null >/dev/null; return 0; }

tmux new-session -d -s reap "sleep 100" 2>/dev/null
PANE_ID=$(tmux display-message -t reap -p '#{pane_id}' 2>/dev/null)
# tmux may be installed yet unable to create a server/session (sandboxed macOS/CI).
# That is a substrate gap, NOT a lifecycle regression — SKIP cleanly rather than
# letting the product assertions below hard-fail against an empty pane id.
if [[ -z "$PANE_ID" ]]; then
  print "SKIP: tmux present but cannot create a session (sandboxed runner?) — substrate unavailable"
  exit 0
fi
ok "real tmux pane created ($PANE_ID on -L $SOCK)"

D=$(mktemp -d)
CAMPAIGN_JSONL="$D/c.jsonl"
WORKER_MODEL=haiku; WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; CONSENSUS_MODE=off
CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
LIFECYCLE_RECORDS=()

# 1) The live emit site populates the accumulator.
_kill_pane_process "$PANE_ID" worker
(( ${#LIFECYCLE_RECORDS[@]} >= 1 )) && ok "_kill_pane_process emitted ${#LIFECYCLE_RECORDS[@]} lifecycle record(s)" \
  || no "_kill_pane_process emitted NO record (accumulator empty)"
print -r -- "${LIFECYCLE_RECORDS[1]:-}" | jq -e '.metric=="pane_eof_to_cleanup_ms" and (.value_ms|type=="number")' >/dev/null 2>&1 \
  && ok "record is pane_eof_to_cleanup_ms with numeric value_ms" || no "record shape wrong (${LIFECYCLE_RECORDS[1]:-none})"

# 2) write_campaign_jsonl drains it into a NON-EMPTY grouped object.
write_campaign_jsonl 1 US-001 pass
[[ -f "$CAMPAIGN_JSONL" ]] && ok "campaign.jsonl written" || no "campaign.jsonl absent"
lm=$(tail -1 "$CAMPAIGN_JSONL" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms | length' 2>/dev/null)
[[ "$lm" -ge 1 ]] 2>/dev/null && ok "campaign.jsonl.lifecycle_metrics.pane_eof_to_cleanup_ms has $lm entry" \
  || no "pane_eof_to_cleanup_ms missing in campaign.jsonl (len=$lm)"

# 3) B3-S1 (the exact SV-gate assertion) PASSes on this real, leader-written row.
ASSERTIONS_PASSED=0; ASSERTIONS_FAILED=0; SCENARIO_FAILURE_REASON=""
b3_assert_lifecycle_metrics_present "$CAMPAIGN_JSONL" >/dev/null 2>&1
[[ "$ASSERTIONS_PASSED" == 1 && "$ASSERTIONS_FAILED" == 0 ]] \
  && ok "B3-S1 PASS on real _kill_pane_process-emitted campaign.jsonl" \
  || no "B3-S1 did not PASS (passed=$ASSERTIONS_PASSED failed=$ASSERTIONS_FAILED)"

# 4) accumulator reset after the flush (no cross-iteration bleed).
(( ${#LIFECYCLE_RECORDS[@]} == 0 )) && ok "accumulator reset to 0 after flush" \
  || no "accumulator not reset (${#LIFECYCLE_RECORDS[@]} left)"

rm -rf "$D"
print ""
if (( FAIL == 0 )); then print "b3-pane-reap-integration: $PASS/$((PASS+FAIL)) PASS"; else print "b3-pane-reap-integration: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
