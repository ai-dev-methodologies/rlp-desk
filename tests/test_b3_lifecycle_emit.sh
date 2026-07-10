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
# F8 (codex P2 sweep): "!= null" is vacuous — an empty {} is also non-null and
# would let a no-op default-on silently masquerade as "emitting". Require the
# specific metric key present with >= 1 record instead.
[[ "$(print -r -- "$default_on" | jq -r '.pane_eof_to_cleanup_ms // [] | length')" -ge 1 ]] \
  && ok "DEFAULT-ON: RLP_LIFECYCLE_METRICS unset now emits (was OFF pre-full-wire, pane_eof_to_cleanup_ms key present with >=1 record)" \
  || no "DEFAULT-ON regression: unset flag produced no pane_eof_to_cleanup_ms records ($default_on)"

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

# F1/F8 (codex P2 sweep): F1 resolved as a DOC fix, not a behavior fix — Node's
# reapProducer computes ONE reapMs and records() it under both metric names
# (campaign-main-loop.mjs:1475-1482), so the zsh side is CORRECT to reuse the
# same $_b4_delta for both. Assert that corrected contract directly: the two
# records must carry the SAME value_ms (same window), not different ones.
eof_vm=$(print -r -- "$reap_pair" | tail -n +2 | jq -r 'select(.metric=="pane_eof_to_cleanup_ms") | .value_ms')
reap_vm=$(print -r -- "$reap_pair" | tail -n +2 | jq -r 'select(.metric=="pane_reap_latency_ms") | .value_ms')
[[ -n "$eof_vm" && "$eof_vm" == "$reap_vm" ]] \
  && ok "F1: pane_reap_latency_ms measures the SAME kill-start->shell-idle window as pane_eof_to_cleanup_ms (value_ms=$eof_vm, mirrors Node's single reapMs)" \
  || no "F1 regression: pane_eof_to_cleanup_ms ($eof_vm) and pane_reap_latency_ms ($reap_vm) diverged"

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
# F8 (codex P2 sweep): same vacuous-assertion fix as case 11 — require the
# metric key present with >= 1 record, not merely "not null".
[[ "$(print -r -- "$truthy" | jq -r '.pane_eof_to_cleanup_ms // [] | length')" -ge 1 ]] \
  && ok "P2-1: RLP_LIFECYCLE_METRICS=true enables (matches Node's !== '0' contract, pane_eof_to_cleanup_ms key present with >=1 record)" \
  || no "P2-1: value 'true' incorrectly disabled telemetry — no pane_eof_to_cleanup_ms records ($truthy)"

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

# ═══════════════════════════════════════════════════════════════════════════
# codex round 3: CLOSES THE CLASS structurally. Three rounds of "found another
# atomic-replace-with-a-pending-mark site" means per-site clearing doesn't
# scale — moved the clear INTO atomic_write() itself (lib_ralph_desk.zsh),
# so EVERY successful atomic_write call drops any pending lock-mark for the
# basename it just replaced, by construction, with no per-call-site opt-in.
# The 3 round-2 per-site clear calls before atomic_write "$VERDICT_FILE" are
# now REMOVED as redundant (cases 22/23 below updated accordingly); the 4
# round-1 rm-site clear calls STAY (rm doesn't go through atomic_write, so
# it still needs its own explicit clear).
# ═══════════════════════════════════════════════════════════════════════════

# 22) P2-2 (structural): atomic_write() itself calls _lifecycle_clear_lock_mark
# — the hook that closes the class.
grep -qE '^atomic_write\(\)' "$REPO/src/scripts/lib_ralph_desk.zsh" \
  && atomic_write_body=$(awk '/^atomic_write\(\)/,/^}/' "$REPO/src/scripts/lib_ralph_desk.zsh") \
  || atomic_write_body=""
print -r -- "$atomic_write_body" | grep -q '_lifecycle_clear_lock_mark "\${target:t}"' \
  && ok "P2-2 round 3: atomic_write() contains the clear-mark hook" \
  || no "P2-2 round 3: atomic_write() is missing the clear-mark hook"

# 23) P2-2 (structural): exactly 4 explicit _lifecycle_clear_lock_mark
# "${VERDICT_FILE:t}" call sites remain in run_ralph_desk.zsh — the 4 round-1
# rm sites (run_single_verifier top, _final_verify_one_us top + retry, main
# consensus loop pre-dispatch). The 3 round-2 atomic_write-adjacent calls were
# removed (now redundant with the hook). The loop-top cleanup rm stays
# uninstrumented (already safe via its own unlock+mark_unlock pairing).
clear_call_count=$(grep -c '_lifecycle_clear_lock_mark "\${VERDICT_FILE:t}"' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$clear_call_count" == "4" ]] \
  && ok "P2-2 round 3: exactly 4 rm-site clear calls remain (3 atomic_write ones removed as redundant)" \
  || no "P2-2 round 3: expected 4 _lifecycle_clear_lock_mark call sites, got $clear_call_count"

# 24) P2-2 (structural): no raw `>` redirect writes SIGNAL_FILE/signal_file/
# VERDICT_FILE/verdict_file outside atomic_write anymore (handle_worker_exit_
# codex's synthesis was the one exception found in the round-3 audit —
# converted to atomic_write so it gets both F-26 truncated-write protection
# and the clear-mark hook).
raw_redirects=$(grep -cE '> ?"\$(SIGNAL_FILE|VERDICT_FILE|signal_file|verdict_file)"' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$raw_redirects" == "0" ]] \
  && ok "P2-2 round 3: no raw > redirects onto monitored files remain (all funnel through atomic_write)" \
  || no "P2-2 round 3: found $raw_redirects raw > redirect(s) onto monitored files (bypasses the hook)"

# 25) P3 round 3 (behavioral, exactly as specified): mark pending →
# atomic_write REPLACES the file → unlock (no re-lock in between) ⇒ NO
# emission. Proves the hook — NOT a manual per-call clear — is what silences
# the stale mark. This is the direct regression test for the class of bug
# codex found 3 times: a lock left dangling across a replace.
hook_silences=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  D=$(mktemp -d)
  _lifecycle_mark_lock_start "verdict.json"
  echo "{\"verdict\":\"pass\"}" | atomic_write "$D/verdict.json"
  _lifecycle_mark_unlock "verdict.json" 1
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  rm -rf "$D"')
[[ "$hook_silences" == "0" ]] \
  && ok "P3: lock→atomic_write-replace→unlock (no relock) emits NOTHING — hook cleared it" \
  || no "P3: expected 0 records after atomic_write-replace with no relock, got $hook_silences"

# 26) P3 round 3 (invariant, exactly as specified): a mark set AFTER an
# atomic_write in the SAME cycle still pairs normally — write→lock→mark→
# unlock ⇒ one sane pair. Proves the hook only clears what's ALREADY pending
# at write-time; it does not poison a mark established afterward.
write_then_lock=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  D=$(mktemp -d)
  echo "{\"verdict\":\"pass\"}" | atomic_write "$D/verdict.json"
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.05
  _lifecycle_mark_unlock "verdict.json" 1
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done
  rm -rf "$D"')
n=$(print -r -- "$write_then_lock" | head -1)
[[ "$n" == "1" ]] && ok "P3: write→lock→mark→unlock (write BEFORE lock, same cycle) still pairs normally" \
  || no "P3: write-then-lock cycle expected 1 record, got $n"

# 27) P3 round 3: lock→atomic_write-replace→re-lock→unlock (the full round-2
# scenario, re-verified against the hook alone, no manual clear call) still
# emits exactly ONE pair measuring the fresh lock — not the abandoned one.
atomic_cycle=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  D=$(mktemp -d)
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.3
  echo "{\"verdict\":\"pass\"}" | atomic_write "$D/verdict.json"
  _lifecycle_mark_lock_start "verdict.json"
  sleep 0.05
  _lifecycle_mark_unlock "verdict.json" 5
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done
  rm -rf "$D"')
n=$(print -r -- "$atomic_cycle" | head -1)
[[ "$n" == "1" ]] && ok "P3: lock→atomic_write-replace(hook)→re-lock→unlock emits exactly ONE pair" \
  || no "P3: atomic-replace cycle expected 1 record, got $n"
vms=$(print -r -- "$atomic_cycle" | tail -n +2 | jq -r '.value_ms' 2>/dev/null)
[[ -n "$vms" ]] && (( vms < 250 )) \
  && ok "P3: emitted pair measures the fresh ~50ms lock, not the abandoned ~300ms one (value_ms=$vms)" \
  || no "P3: atomic-replace cycle value_ms suspiciously large (got ${vms:-<none>})"

print ""
if (( FAIL == 0 )); then print "b3-lifecycle-emit: $PASS/$((PASS+FAIL)) PASS"; else print "b3-lifecycle-emit: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
