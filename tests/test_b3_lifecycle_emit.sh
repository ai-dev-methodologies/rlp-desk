#!/usr/bin/env zsh
# B3 zsh-leader lifecycle port — deterministic regression (no real-LLM).
#
# The production zsh leader (--mode tmux) now flushes a `lifecycle_metrics` object into
# campaign.jsonl: LIFECYCLE_RECORDS accumulates synchronously in log_lifecycle_metric,
# write_campaign_jsonl drains+resets it. Shape contract (cross-leader): null when the
# flag is off, grouped object {metric:[{value_ms,ts}]} when on with records, {} when on
# with none. This pins: off-neutrality, grouped shape, reset, FAIL-OPEN (a malformed
# record must never drop the always-on campaign row), and the tightened B3-S1 (a non-empty
# metric array is required; empty {} or null do NOT count as telemetry present).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
B3="$REPO/tests/sv-real-llm/lib/b3-lifecycle-assertions.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

zsh -n "$LIB" && ok "lib_ralph_desk.zsh: zsh -n clean" || no "lib syntax"

# Harness: run a write_campaign_jsonl scenario in a subshell, echo the last row.
# v0.15.4 full-wire: flag=0 is now an EXPLICIT opt-out (export ...=0), NOT unset —
# unset now means ON (default flip, see case 11 below). A bare `unset` here would
# no longer exercise the OFF path this harness's callers expect.
emit_row() {  # $1=flag(0/1)  $2..=pre-flush log_lifecycle_metric "metric value" pairs
  local flag="$1"; shift
  zsh -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }
    D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
    WORKER_MODEL=haiku; WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; CONSENSUS_MODE=off
    CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
    [[ "'"$flag"'" == 1 ]] && export RLP_LIFECYCLE_METRICS=1 || export RLP_LIFECYCLE_METRICS=0
    for pair in "$@"; do log_lifecycle_metric ${=pair} "ctx=z"; done
    write_campaign_jsonl 1 US-001 pass
    tail -1 "$CAMPAIGN_JSONL"
    rm -rf "$D"
  ' _ "$@"
}

# 1) explicit OFF (=0) -> null + legacy fields intact
row=$(emit_row 0)
[[ "$(print -r -- "$row" | jq -c .lifecycle_metrics)" == "null" ]] && ok "explicit off (=0) → lifecycle_metrics null" || no "off not null ($row)"
[[ "$(print -r -- "$row" | jq -r '[.iter,.us_id,.slug] | join(",")')" == "1,US-001,t" ]] && ok "off → legacy fields intact (schema-neutral)" || no "off legacy fields drifted"

# 2) ON + 2 records -> grouped, length 2, numeric value_ms
row=$(emit_row 1 "pane_eof_to_cleanup_ms 120" "pane_eof_to_cleanup_ms 80")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms | length')" == "2" ]] && ok "on+records → grouped array length 2" || no "grouped length wrong ($row)"
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms[0].value_ms')" == "120" ]] && ok "on+records → value_ms is numeric 120" || no "value_ms wrong"

# 3) ON + no records -> {}
row=$(emit_row 1)
[[ "$(print -r -- "$row" | jq -c .lifecycle_metrics)" == "{}" ]] && ok "on+empty → {}" || no "on+empty not {} ($row)"

# 4) reset after flush
reset_ok=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=1
  log_lifecycle_metric pane_eof_to_cleanup_ms 50 "c=z"
  write_campaign_jsonl 1 US-001 pass
  print "${#LIFECYCLE_RECORDS[@]}"
  rm -rf "$D"')
[[ "$reset_ok" == "0" ]] && ok "accumulator reset to 0 after flush" || no "not reset ($reset_ok)"

# 5) FAIL-OPEN: malformed record -> null + row still written
failopen=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=("{bad json")
  write_campaign_jsonl 7 US-001 pass
  print "rows=$(wc -l < "$CAMPAIGN_JSONL" | tr -d " ") iter=$(tail -1 "$CAMPAIGN_JSONL" | jq -c .iter) lm=$(tail -1 "$CAMPAIGN_JSONL" | jq -c .lifecycle_metrics)"
  rm -rf "$D"')
[[ "$failopen" == "rows=1 iter=7 lm=null" ]] && ok "fail-open: malformed record → null, row still written" || no "fail-open broke ($failopen)"

# 6) B3-S1 tightened: non-empty PASS, empty {} FAIL, null FAIL
source "$B3"
D=$(mktemp -d)
print '{"lifecycle_metrics":{"pane_eof_to_cleanup_ms":[{"value_ms":120,"ts":"x"}]}}' > "$D/nonempty.jsonl"
print '{"lifecycle_metrics":{}}' > "$D/empty.jsonl"
print '{"lifecycle_metrics":null}' > "$D/null.jsonl"
ASSERTIONS_PASSED=0; ASSERTIONS_FAILED=0; SCENARIO_FAILURE_REASON=""
b3_assert_lifecycle_metrics_present "$D/nonempty.jsonl" >/dev/null 2>&1
[[ "$ASSERTIONS_PASSED" == 1 && "$ASSERTIONS_FAILED" == 0 ]] && ok "B3-S1: non-empty metric array → PASS" || no "B3-S1 non-empty not PASS"
ASSERTIONS_PASSED=0; ASSERTIONS_FAILED=0; SCENARIO_FAILURE_REASON=""
b3_assert_lifecycle_metrics_present "$D/empty.jsonl" >/dev/null 2>&1
[[ "$ASSERTIONS_FAILED" == 1 ]] && ok "B3-S1 (tightened): empty {} → FAIL (no longer masquerades as present)" || no "B3-S1 empty {} wrongly PASSED"
ASSERTIONS_PASSED=0; ASSERTIONS_FAILED=0; SCENARIO_FAILURE_REASON=""
b3_assert_lifecycle_metrics_present "$D/null.jsonl" >/dev/null 2>&1
[[ "$ASSERTIONS_FAILED" == 1 ]] && ok "B3-S1: null → FAIL" || no "B3-S1 null wrongly PASSED"

# 7) B3-S2 in-loop: emitted metric band-checks; unmeasured metric SKIPs
ASSERTIONS_PASSED=0; ASSERTIONS_FAILED=0; SCENARIO_FAILURE_REASON=""
out=$(b3_assert_lifecycle_metric_within_band "$D/nonempty.jsonl" "pane_eof_to_cleanup_ms" 5000 2>&1)
[[ "$ASSERTIONS_FAILED" == 0 ]] && ok "B3-S2: emitted pane_eof within band → not FAIL" || no "B3-S2 emitted FAILed"
out=$(b3_assert_lifecycle_metric_within_band "$D/nonempty.jsonl" "iter_signal_write_to_read_ms" 5000 2>&1)
[[ "$out" == *SKIP* ]] && ok "B3-S2: unmeasured metric → SKIP (not FAIL)" || no "B3-S2 unmeasured not SKIP ($out)"
rm -rf "$D"

# 8) NEGATIVE CLAMP: a negative value_ms (e.g. EPOCHREALTIME mis-scale near a second
# rollover, or a comma-decimal LC_NUMERIC corrupting the ms math) must clamp to 0, NOT
# land a negative in campaign.jsonl (a negative silently passes the `<= band` check →
# false PASS). Mirrors the Node collector which clamps non-negative.
row=$(emit_row 1 "pane_eof_to_cleanup_ms -50")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms[0].value_ms')" == "0" ]] \
  && ok "negative value_ms clamped to 0 (no negative in campaign.jsonl)" || no "negative value_ms NOT clamped ($row)"

# 9) LOCALE ROBUSTNESS (source-structural): the EPOCHREALTIME->ms parse in _kill_pane_process
# (t0/t1) AND the shared _epoch_ms() helper (v0.15.4 full-wire, used by the 4 newly-wired
# write_to_read/reap emit sites) strip the decimal separator before slicing to 13 digits.
# Under a comma-decimal LC_NUMERIC zsh renders EPOCHREALTIME with ',', so a '.'-only strip
# is a no-op and the slice corrupts the ms value (runtime behavior is locale+pane dependent,
# hence a source-structural check). Assert all 3 EPOCHREALTIME-strip sites remove ',' too.
both=$(grep -cE 'EPOCHREALTIME//\.\/}//,/' "$REPO/src/scripts/lib_ralph_desk.zsh")
[[ "$both" == "3" ]] \
  && ok "EPOCHREALTIME ms-parse strips both '.' and ',' at all 3 sites (t0/t1 + _epoch_ms, locale-robust)" \
  || no "EPOCHREALTIME strip not locale-robust (both-separator sites found: $both, want 3)"

# 10) CROSS-LEADER PARITY: the zsh lifecycle_metrics field must match the Node flush() shape
# (src/node/util/lifecycle-metrics.mjs:88-99): a grouped OBJECT {metric: [{value_ms, ts}, ...]},
# entries keyed exactly {ts, value_ms}, value_ms a non-negative number (Node Math.max(0,…)).
# So both the --mode tmux (zsh) and --mode agent (Node) leaders write IDENTICAL-shaped rows.
row=$(emit_row 1 "pane_eof_to_cleanup_ms 6226" "pane_eof_to_cleanup_ms -3")
[[ "$(print -r -- "$row" | jq -r '.lifecycle_metrics | type')" == "object" ]] \
  && ok "parity: lifecycle_metrics is a grouped object (Node flush() shape)" || no "parity: not a grouped object"
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms[0] | keys')" == '["ts","value_ms"]' ]] \
  && ok "parity: entry keys == Node {value_ms, ts}" || no "parity: entry keys != Node shape"
[[ "$(print -r -- "$row" | jq -c '[.lifecycle_metrics.pane_eof_to_cleanup_ms[].value_ms] | min')" == "0" ]] \
  && ok "parity: negative value_ms clamped to 0 (Node Math.max(0,…) parity)" || no "parity: negative not clamped"

# ═══════════════════════════════════════════════════════════════════════════
# v0.15.4 full-wire: the 4 remaining lifecycle metrics on the zsh leader +
# default RLP_LIFECYCLE_METRICS flips from OFF to ON.
# ═══════════════════════════════════════════════════════════════════════════

# 11) DEFAULT-ON: RLP_LIFECYCLE_METRICS truly UNSET (never exported, not just
# "=0") now emits by default — all 3 zsh gate checks flip :-0 to :-1. This is
# the core behavior change of this PR: pre-full-wire, an unset flag was OFF.
default_on=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  unset RLP_LIFECYCLE_METRICS
  log_lifecycle_metric pane_eof_to_cleanup_ms 77 "c=z"
  write_campaign_jsonl 1 US-001 pass
  print -r -- "$(tail -1 "$CAMPAIGN_JSONL" | jq -c .lifecycle_metrics)"
  rm -rf "$D"')
[[ "$default_on" != "null" && -n "$default_on" ]] \
  && ok "DEFAULT-ON: RLP_LIFECYCLE_METRICS unset now emits (was OFF pre-full-wire)" \
  || no "DEFAULT-ON regression: unset flag produced null ($default_on)"

# 12) explicit opt-out (=0) still silences after the default flip.
explicit_off=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=0
  log_lifecycle_metric pane_eof_to_cleanup_ms 77 "c=z"
  write_campaign_jsonl 1 US-001 pass
  print -r -- "$(tail -1 "$CAMPAIGN_JSONL" | jq -c .lifecycle_metrics)"
  rm -rf "$D"')
[[ "$explicit_off" == "null" ]] && ok "explicit RLP_LIFECYCLE_METRICS=0 still silences" \
  || no "explicit off not silenced ($explicit_off)"

# 13) log_lifecycle_metric: optional 4th/5th args (iter, us_id) embed as JSON
# fields on the record — mirrors Node's ctx object for the 2 cheap write_to_read
# fields (campaign-main-loop.mjs:2012-2015). 3-arg callers (existing sites,
# e.g. pane_eof_to_cleanup_ms) are unaffected — see case 10 above.
ctx_row=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  log_lifecycle_metric iter_signal_write_to_read_ms 250 "iter=3 us_id=US-002" 3 US-002
  print -r -- "${LIFECYCLE_RECORDS[1]}"')
[[ "$(print -r -- "$ctx_row" | jq -r '.iter')" == "3" && "$(print -r -- "$ctx_row" | jq -r '.us_id')" == "US-002" ]] \
  && ok "log_lifecycle_metric: iter/us_id embedded when passed (4th/5th arg)" \
  || no "iter/us_id context not embedded ($ctx_row)"

# 14) log_lifecycle_metric: optional 6th arg (sentinel_type) embeds too —
# mirrors Node's { sentinel_type } context on pane_reap_latency_ms.
stype_row=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  log_lifecycle_metric pane_reap_latency_ms 500 "pane=%1" "" "" iter-signal
  print -r -- "${LIFECYCLE_RECORDS[1]}"')
[[ "$(print -r -- "$stype_row" | jq -r '.sentinel_type')" == "iter-signal" ]] \
  && ok "log_lifecycle_metric: sentinel_type embedded when passed (6th arg)" \
  || no "sentinel_type context not embedded ($stype_row)"

# 15) _kill_pane_process: NEW optional 3rd arg (sentinel_type) emits
# pane_reap_latency_ms IN ADDITION to pane_eof_to_cleanup_ms — Node parity
# (reapProducer(paneId, sentinelFile, sentinelType), campaign-main-loop.mjs:
# 1476-1482). No real tmux pane needed: tmux send-keys against a fake pane id
# fails silently (2>/dev/null) and wait_for_pane_ready is undefined in this
# lib-only shell, so _kill_pane_process degrades to a pure timing no-op —
# exactly like the existing test_b3_pane_reap_integration.sh precedent, but
# without requiring a real tmux server for this specific case.
reap_pair=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _kill_pane_process "%fake-pane" worker iter-signal
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done')
n=$(print -r -- "$reap_pair" | head -1)
[[ "$n" == "2" ]] && ok "_kill_pane_process + sentinel_type: emits 2 records (pane_eof + pane_reap_latency)" \
  || no "_kill_pane_process + sentinel_type: expected 2 records, got $n"
metrics=$(print -r -- "$reap_pair" | tail -n +2 | jq -r '.metric' 2>/dev/null | sort | tr '\n' ',')
[[ "$metrics" == "pane_eof_to_cleanup_ms,pane_reap_latency_ms," ]] \
  && ok "_kill_pane_process + sentinel_type: both metric names present" \
  || no "_kill_pane_process + sentinel_type: wrong metric set ($metrics)"

# 16) _kill_pane_process: WITHOUT a 3rd arg (all 5 existing call sites that
# don't pass one — e.g. the A4-fallback worker-a4 kill), only
# pane_eof_to_cleanup_ms fires — no regression on the pre-existing contract.
noreap=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _kill_pane_process "%fake-pane" worker
  print -r -- "${#LIFECYCLE_RECORDS[@]}"')
[[ "$noreap" == "1" ]] && ok "_kill_pane_process without sentinel_type: only pane_eof_to_cleanup_ms fires (no regression)" \
  || no "_kill_pane_process without sentinel_type: expected 1 record, got $noreap"

# ═══════════════════════════════════════════════════════════════════════════
# codex round 1 (P2-1, P2-2, P3): flag-semantics parity + verdict lock-pair
# hygiene.
# ═══════════════════════════════════════════════════════════════════════════

# 17) P2-1: RLP_LIFECYCLE_METRICS="true" must ENABLE telemetry, matching
# Node's `env[FLAG] !== '0'` contract exactly (any value other than the
# literal "0" is ON). Before this fix zsh gated on `== "1"`, so "true" was
# silently disabled — a real divergence: RLP_LIFECYCLE_METRICS=true would
# disable tmux-mode telemetry while enabling agent-mode telemetry.
truthy=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=true
  log_lifecycle_metric pane_eof_to_cleanup_ms 77 "c=z"
  write_campaign_jsonl 1 US-001 pass
  print -r -- "$(tail -1 "$CAMPAIGN_JSONL" | jq -c .lifecycle_metrics)"
  rm -rf "$D"')
[[ "$truthy" != "null" && -n "$truthy" ]] \
  && ok "P2-1: RLP_LIFECYCLE_METRICS=true enables (matches Node's !== '0' contract)" \
  || no "P2-1: value 'true' incorrectly disabled telemetry ($truthy)"

# 18) P2-1 (structural): every zsh gate check uses the unified `!= "0"` form,
# not `== "1"` (which silently diverges from Node on any non-"0"/non-"1"
# value). Pins the fix so a future edit cannot silently reintroduce the
# divergence at one of the (currently 6) gate sites.
gate_count=$(grep -cE '"\$\{RLP_LIFECYCLE_METRICS:-1\}" != "0"' "$REPO/src/scripts/lib_ralph_desk.zsh")
stale_gate_count=$(grep -cE '"\$\{RLP_LIFECYCLE_METRICS:-1\}" == "1"' "$REPO/src/scripts/lib_ralph_desk.zsh")
[[ "$gate_count" -ge 6 && "$stale_gate_count" == "0" ]] \
  && ok "P2-1: all gate sites use the unified != \"0\" form ($gate_count sites, 0 stale == \"1\" sites)" \
  || no "P2-1: gate unification incomplete (!= \"0\" sites=$gate_count, stale == \"1\" sites=$stale_gate_count)"

# 19) P3: sentinel_lock_to_unlock_ms normal reuse — lock→unlock→re-lock→unlock
# emits TWO sane pairs (not merged, not cross-paired), each carrying its own
# iter context.
reuse=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.05
  _lifecycle_mark_unlock "verdict.json" 1
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.05
  _lifecycle_mark_unlock "verdict.json" 2
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done')
n=$(print -r -- "$reuse" | head -1)
[[ "$n" == "2" ]] && ok "P3: lock→unlock→re-lock→unlock emits 2 sane pairs" \
  || no "P3: reuse cycle expected 2 records, got $n"
iters=$(print -r -- "$reuse" | tail -n +2 | jq -r '.iter' 2>/dev/null | tr '\n' ',')
[[ "$iters" == "1,2," ]] && ok "P3: reuse pairs carry distinct iter context (1 then 2, no cross-pairing)" \
  || no "P3: reuse pair iter context wrong ($iters)"

# 20) P2-2 fix: lock→DELETE(no unlock)→re-lock→unlock emits EXACTLY ONE pair,
# measured from the SECOND (fresh) lock — not a false pairing between the
# abandoned first lock and the eventual unlock. Reproduces the exact bug
# Codex flagged: a verdict-clear-before-relaunch rm (run_single_verifier /
# _final_verify_one_us / the main consensus loop) that happens after a lock
# was marked but BEFORE that attempt ever reached its own _lock_sentinel call
# (e.g. a poll hard-fail) must not leave a stale mark for a later, unrelated
# unlock to pair with.
delete_cycle=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.3
  # simulate: verdict file removed before relaunch, this attempt never relocks.
  _lifecycle_clear_lock_mark "verdict.json"
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.05
  _lifecycle_mark_unlock "verdict.json" 9
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done')
n=$(print -r -- "$delete_cycle" | head -1)
[[ "$n" == "1" ]] && ok "P2-2: lock→delete→re-lock→unlock emits exactly ONE pair (no cross-instance pairing)" \
  || no "P2-2: delete cycle expected 1 record, got $n"
vms=$(print -r -- "$delete_cycle" | tail -n +2 | jq -r '.value_ms' 2>/dev/null)
[[ -n "$vms" ]] && (( vms < 250 )) \
  && ok "P2-2: emitted pair measures the fresh ~50ms lock, not the stale abandoned ~300ms one (value_ms=$vms)" \
  || no "P2-2: emitted value_ms suspiciously large — stale mark may have leaked (got ${vms:-<none>})"

# 21) P2-2: lock→delete(clear)→unlock with NO relock in between is a silent
# no-op — no record, no crash (mirrors Node's markUnlock-without-
# markLockStart no-op, LifecycleMetricsCollector.markUnlock: `if (start ===
# undefined) return;`).
no_relock=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json"
  _lifecycle_clear_lock_mark "verdict.json"
  _lifecycle_mark_unlock "verdict.json" 1
  print -r -- "${#LIFECYCLE_RECORDS[@]}"')
[[ "$no_relock" == "0" ]] && ok "P2-2: lock→delete(clear)→unlock (no relock) is a silent no-op" \
  || no "P2-2: cleared-then-unlocked mark should emit nothing, got $no_relock records"

# 22) P2-2 (structural): every non-loop-top rm of $VERDICT_FILE calls
# _lifecycle_clear_lock_mark first — pins the 4 fix sites (run_single_verifier
# top, _final_verify_one_us top + retry, main consensus loop pre-dispatch).
# The loop-top cleanup rm is EXCLUDED (5th VERDICT_FILE rm site) since it is
# already preceded by a proper _unlock_sentinel + _lifecycle_mark_unlock pair
# in the same block, which already clears the mark via normal pairing.
clear_call_count=$(grep -c '_lifecycle_clear_lock_mark "\${VERDICT_FILE:t}"' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$clear_call_count" == "4" ]] \
  && ok "P2-2: all 4 non-loop-top VERDICT_FILE rm sites call _lifecycle_clear_lock_mark first" \
  || no "P2-2: expected 4 _lifecycle_clear_lock_mark call sites in run_ralph_desk.zsh, got $clear_call_count"

print ""
if (( FAIL == 0 )); then print "b3-lifecycle-emit: $PASS/$((PASS+FAIL)) PASS"; else print "b3-lifecycle-emit: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
