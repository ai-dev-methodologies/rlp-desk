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

# 8) F7 (codex P2 sweep): a negative value_ms (e.g. EPOCHREALTIME mis-scale near
# a second rollover, or a comma-decimal LC_NUMERIC corrupting the ms math) is
# DROPPED entirely, NOT clamped to 0. A clamp-to-0-and-keep let a corrupted
# measurement silently satisfy the B3-S2 `<= band` check as a false PASS —
# case 7 above already proves an UNMEASURED metric SKIPs (not fails) B3-S2,
# so dropping the record is safe: no data beats wrong data.
row=$(emit_row 1 "pane_eof_to_cleanup_ms -50")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics | has("pane_eof_to_cleanup_ms")')" == "false" ]] \
  && ok "F7: negative value_ms dropped entirely (no false-PASS clamp-to-0)" || no "F7: negative value_ms NOT dropped ($row)"

# 8b) F7: malformed (non-numeric) value_ms is dropped the same way as negative.
row=$(emit_row 1 "pane_eof_to_cleanup_ms notanumber")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics | has("pane_eof_to_cleanup_ms")')" == "false" ]] \
  && ok "F7: malformed (non-numeric) value_ms dropped entirely" || no "F7: malformed value_ms NOT dropped ($row)"

# 8c) F7: a GENUINE value_ms of 0 (real sub-ms measurement) is kept, not
# confused with a dropped negative/malformed value — the drop path must
# distinguish "invalid" from "validly zero".
row=$(emit_row 1 "pane_eof_to_cleanup_ms 0")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms[0].value_ms')" == "0" ]] \
  && ok "F7: genuine value_ms=0 is kept (true zero != dropped negative/malformed)" \
  || no "F7: true zero was dropped or mangled ($row)"

# 8d) F7: dropping a negative/malformed record logs ONE warning, DEBUG-gated
# (consistent with this subsystem's "audit aid, not source of truth" debug.log
# positioning — production DEBUG defaults to 0, so this is silent by default).
warn_seen=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }
  WARNFILE=$(mktemp)
  # log_debug fires from inside a backgrounded `( ) &!` subshell — a plain
  # variable mutation would land in the subshell copy, invisible to this
  # parent shell. Use a shared file instead so the write is observable.
  log_debug(){ print -r -- "$*" >> "$WARNFILE"; }
  export RLP_LIFECYCLE_METRICS=1
  DEBUG=1
  LIFECYCLE_RECORDS=()
  log_lifecycle_metric pane_eof_to_cleanup_ms -50 "c=z"
  sleep 0.2
  cat "$WARNFILE"
  rm -f "$WARNFILE"')
[[ "$warn_seen" == *"LIFECYCLE-WARN"* ]] \
  && ok "F7: dropping a negative/malformed value logs a warning (DEBUG-gated)" \
  || no "F7: no warning logged on drop ($warn_seen)"

# 8e) F2 (codex P2 sweep): log_lifecycle_metric's record assembly must be
# fork-free — no `date` or `jq` subprocess per call. Both were measurable
# forks on the post-sentinel reap hot path (metric emission happens between
# sentinel-detect and pane-reap on some call sites — see the capture/emit
# split tests below). Structural: the function body must not shell out to
# either.
_llm_body=$(awk '/^log_lifecycle_metric\(\)/,/^}/' "$REPO/src/scripts/lib_ralph_desk.zsh")
print -r -- "$_llm_body" | grep -qE '\bdate[[:space:]]+-u|\bjq[[:space:]]+-' \
  && no "F2: log_lifecycle_metric still forks date/jq (fork-free rewrite expected)" \
  || ok "F2: log_lifecycle_metric record assembly is fork-free (no date/jq calls)"

# 8f) F2: the debug.log background subshell fork must be gated on (( DEBUG ))
# itself, not spawned unconditionally and left to log_debug's OWN internal
# DEBUG check — forking `( log_debug ... ) &!` even when DEBUG=0 is pure
# waste on the hot path this metric infra instruments.
print -r -- "$_llm_body" | grep -qE '\(\(\s*DEBUG\s*\)\).*&&.*typeset -f log_debug' \
  && ok "F2: debug-log subshell fork is gated on (( DEBUG )) (not spawned when DEBUG=0)" \
  || no "F2: debug-log subshell fork is not gated on DEBUG"

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
# entries keyed exactly {ts, value_ms}. So both the --mode tmux (zsh) and --mode agent (Node)
# leaders write IDENTICAL-shaped rows for valid records.
row=$(emit_row 1 "pane_eof_to_cleanup_ms 6226" "pane_eof_to_cleanup_ms 3")
[[ "$(print -r -- "$row" | jq -r '.lifecycle_metrics | type')" == "object" ]] \
  && ok "parity: lifecycle_metrics is a grouped object (Node flush() shape)" || no "parity: not a grouped object"
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms[0] | keys')" == '["ts","value_ms"]' ]] \
  && ok "parity: entry keys == Node {value_ms, ts}" || no "parity: entry keys != Node shape"

# F7 (codex P2 sweep): INTENTIONAL divergence from Node on negative value_ms.
# Node clamps to 0 and keeps the record (Math.max(0, Math.round(valueMs)));
# zsh instead DROPS the record entirely (case 8 above) because a clamped-and-
# kept corrupted measurement let B3-S2's `<= band` check false-PASS. Assert
# the divergence directly here so a future edit cannot silently "fix" this
# back to Node's clamp behavior believing it restores parity — the array must
# contain ONLY the one valid record, not a second clamped-to-0 entry for -3.
row=$(emit_row 1 "pane_eof_to_cleanup_ms 6226" "pane_eof_to_cleanup_ms -3")
[[ "$(print -r -- "$row" | jq -c '.lifecycle_metrics.pane_eof_to_cleanup_ms | length')" == "1" ]] \
  && ok "F7: negative value_ms dropped, not clamped-and-kept (deliberate divergence from Node parity)" \
  || no "F7: negative value_ms was not dropped ($row)"

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
# — the hook that closes the class. codex P2 sweep F9: verify POST-MV
# POSITION, not mere presence — a mere-presence check would still pass if a
# future edit moved the clear call BEFORE the mv (reintroducing the exact
# "cleared before confirming" bug class F4 fixed at the rm sites, but inside
# atomic_write itself this time).
grep -qE '^atomic_write\(\)' "$REPO/src/scripts/lib_ralph_desk.zsh" \
  && atomic_write_body=$(awk '/^atomic_write\(\)/,/^}/' "$REPO/src/scripts/lib_ralph_desk.zsh") \
  || atomic_write_body=""
print -r -- "$atomic_write_body" | grep -q '_lifecycle_clear_lock_mark "\${target:t}"' \
  && ok "P2-2 round 3: atomic_write() contains the clear-mark hook" \
  || no "P2-2 round 3: atomic_write() is missing the clear-mark hook"
mv_idx=$(print -r -- "$atomic_write_body" | grep -n 'mv "\$tmp" "\$target"' | head -1 | cut -d: -f1)
clear_idx=$(print -r -- "$atomic_write_body" | grep -n '_lifecycle_clear_lock_mark "\${target:t}"' | head -1 | cut -d: -f1)
[[ -n "$mv_idx" && -n "$clear_idx" ]] && (( clear_idx > mv_idx )) \
  && ok "F9: atomic_write()'s clear-mark hook is positioned AFTER the successful mv (line $clear_idx > $mv_idx), not merely present" \
  || no "F9: atomic_write()'s clear-mark hook is NOT after the mv (mv=$mv_idx clear=$clear_idx)"

# 23) P2-2 (structural): exactly 4 explicit _lifecycle_clear_lock_mark
# "${VERDICT_FILE:t}" call sites remain in run_ralph_desk.zsh — the 4 round-1
# rm sites (run_single_verifier top, _final_verify_one_us top + retry, main
# consensus loop pre-dispatch). The 3 round-2 atomic_write-adjacent calls were
# removed (now redundant with the hook). The loop-top cleanup rm stays
# uninstrumented (already safe via its own unlock+mark_unlock pairing).
# codex P2 sweep F3 added 3 MORE _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"
# call sites — the lock-failure guards (run_single_verifier,
# _final_verify_one_us, the inline single-engine verify path) that clear a
# just-set mark when _lock_sentinel genuinely fails, a DIFFERENT reason than
# the 4 round-1 rm-site clears below. 4 (rm-site) + 3 (F3 lock-guard) = 7.
clear_call_count=$(grep -c '_lifecycle_clear_lock_mark "\${VERDICT_FILE:t}"' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$clear_call_count" == "7" ]] \
  && ok "P2-2 round 3 + F3: 7 clear-mark call sites (4 rm-site + 3 F3 lock-failure guards)" \
  || no "P2-2 round 3 + F3: expected 7 _lifecycle_clear_lock_mark call sites, got $clear_call_count"

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
  # codex P2 sweep F9: set -e so a silent setup failure (mktemp/atomic_write
  # on a hardened/read-only host) aborts this scratch script instead of
  # letting the assertion below misread empty/absent output as a genuine
  # zero-record PASS.
  set -e
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
  set -e   # codex P2 sweep F9: same rationale as case 25 above.
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
  set -e   # codex P2 sweep F9: same rationale as case 25 above.
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

# ═══════════════════════════════════════════════════════════════════════════
# codex P2 sweep F2: default-on instrumentation widened the post-sentinel
# race — _lifecycle_emit_write_to_read's stat/date/jq/background-fork work ran
# BEFORE the pane reap on all 4 write_to_read call sites (worker + 3 verdict
# paths), delaying the moment the leader actually stops the claude/codex TUI
# from self-reviewing. Split into a cheap pre-reap CAPTURE (stat + a
# fork-free $EPOCHREALTIME diff — no jq/date/log-fork) and a post-reap EMIT
# (the actual log_lifecycle_metric call, now proven fork-free per F2 above).
# ═══════════════════════════════════════════════════════════════════════════

# 28) _lifecycle_capture_write_to_read helper exists.
grep -q "^_lifecycle_capture_write_to_read()" "$REPO/src/scripts/lib_ralph_desk.zsh" \
  && ok "F2: _lifecycle_capture_write_to_read helper exists" \
  || no "F2: _lifecycle_capture_write_to_read helper missing"

# 29) Behavioral: capture (before a simulated reap) + emit (after) still
# produces exactly one correct record, and the measured delta reflects the
# CAPTURE-time window, not time elapsed during the simulated reap gap after it
# — proving the two-phase split doesn't just move the same live computation
# later, but actually freezes the value at capture time.
wtr=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  D=$(mktemp -d)
  F="$D/sig.json"
  echo "{}" > "$F"
  delta=$(_lifecycle_capture_write_to_read "$F")
  sleep 1.5   # simulated reap gap — must NOT be re-measured into the emitted value
  _lifecycle_emit_write_to_read "iter_signal_write_to_read_ms" "$F" "$delta" 3 US-002
  print -r -- "$delta"
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done
  rm -rf "$D"')
captured=$(print -r -- "$wtr" | sed -n '1p')
n=$(print -r -- "$wtr" | sed -n '2p')
[[ "$n" == "1" ]] && ok "F2: capture/emit split still produces exactly one iter_signal_write_to_read_ms record" \
  || no "F2: capture/emit split produced $n records, expected 1"
emitted_vm=$(print -r -- "$wtr" | sed -n '3p' | jq -r '.value_ms')
# Exact equality (not a timing-tolerance band): emit must pass the pre-reap
# captured delta straight through, with NO further time-based computation —
# if the 1.5s simulated reap gap leaked in (the old bug: emit recomputed
# now_ms - mtime at EMIT time), emitted_vm would be ~1500ms larger than captured.
[[ -n "$captured" && "$emitted_vm" == "$captured" ]] \
  && ok "F2: emitted value_ms exactly equals the pre-reap captured delta — the 1.5s simulated reap gap did not leak in (value_ms=$captured)" \
  || no "F2: emitted value_ms ($emitted_vm) != captured delta ($captured) — the reap gap leaked into the measurement"
iter_vm=$(print -r -- "$wtr" | sed -n '3p' | jq -r '.iter')
[[ "$iter_vm" == "3" ]] && ok "F2: emit still carries iter/us_id context through the capture/emit split" \
  || no "F2: iter context lost in capture/emit split (got $iter_vm)"

# 30) Structural (source): at all 4 write_to_read call sites in
# run_ralph_desk.zsh (worker + run_single_verifier + _final_verify_one_us +
# the inline single-engine verify path), _lifecycle_capture_write_to_read
# must precede the sentinel-tagged _kill_pane_process reap, and
# _lifecycle_emit_write_to_read must follow it — a strict repeating
# capture->reap->emit state machine over the whole file, order-checked.
order_check=$(awk '
  /_lifecycle_capture_write_to_read/ { if (state=="reaped") { print "ORDER-FAIL: capture at " NR " before prior emit"; bad=1 } state="captured"; next }
  /_kill_pane_process .*"(iter-signal|verify-verdict)"$/ {
    if (state != "captured") { print "ORDER-FAIL: reap at line " NR " without a preceding capture (state=" state ")"; bad=1 }
    state="reaped"; next
  }
  /_lifecycle_emit_write_to_read/ {
    if (state != "reaped") { print "ORDER-FAIL: emit at line " NR " without a preceding reap (state=" state ")"; bad=1 }
    state="emitted"; triples++; next
  }
  END {
    if (triples != 4) { print "expected 4 capture->reap->emit triples, got " triples; bad=1 }
    if (!bad) print "OK"
  }
' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$order_check" == "OK" ]] \
  && ok "F2: all 4 write_to_read call sites follow capture(pre-reap) -> reap -> emit(post-reap) ordering" \
  || no "F2: capture/reap/emit ordering violated: $order_check"

# ═══════════════════════════════════════════════════════════════════════════
# codex P2 sweep F3: _lock_sentinel / _unlock_sentinel currently ALWAYS
# return 0 regardless of whether chmod actually succeeded, so a caller that
# marks a lifecycle lock-start before calling _lock_sentinel has no way to
# tell a genuine chmod failure (permission denied, FS error, ENOENT race)
# from success — the pending mark gets paired with a later unlock as if the
# lock had really happened, emitting a metric for a lock that never occurred.
# Fix: real success/failure (file exists AND chmod succeeded), while keeping
# fail-open idempotence on a MISSING file (AC-B3 in
# test_b2fix_sentinel_lock.sh / Scenario B in test-bug7-post-sentinel-race.sh
# — both must stay green, unchanged).
# ═══════════════════════════════════════════════════════════════════════════

# Stub `chmod` to always fail, isolated via PATH — simulates a real chmod
# failure on an EXISTING file, portable (no root/chflags/chattr needed).
_fake_chmod_dir=$(mktemp -d)
print -r -- '#!/bin/sh
exit 1' > "$_fake_chmod_dir/chmod"
chmod +x "$_fake_chmod_dir/chmod"

# 31) _lock_sentinel returns non-zero when chmod genuinely fails on an
# existing file.
lock_rc=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  D=$(mktemp -d)
  T="$D/verdict.json"
  echo "{}" > "$T"
  PATH="'"$_fake_chmod_dir"':$PATH"
  _lock_sentinel "$T"
  print -r -- "$?"
  rm -rf "$D"')
[[ "$lock_rc" != "0" ]] \
  && ok "F3: _lock_sentinel returns non-zero when chmod genuinely fails on an existing file (rc=$lock_rc)" \
  || no "F3: _lock_sentinel still returns 0 on a real chmod failure"

# 32) _unlock_sentinel: same real-failure contract.
unlock_rc=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  D=$(mktemp -d)
  T="$D/verdict.json"
  echo "{}" > "$T"
  PATH="'"$_fake_chmod_dir"':$PATH"
  _unlock_sentinel "$T"
  print -r -- "$?"
  rm -rf "$D"')
[[ "$unlock_rc" != "0" ]] \
  && ok "F3: _unlock_sentinel returns non-zero when chmod genuinely fails on an existing file (rc=$unlock_rc)" \
  || no "F3: _unlock_sentinel still returns 0 on a real chmod failure"

# 33) Missing-file idempotence is UNCHANGED — the other half of the same
# contract. (test_b2fix_sentinel_lock.sh AC-B3 already pins this from the
# outside; re-asserted here alongside the new failure-path tests.)
missing_rc=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  D=$(mktemp -d)
  _lock_sentinel "$D/never-existed.json"
  print -r -- "$?"
  rm -rf "$D"')
[[ "$missing_rc" == "0" ]] \
  && ok "F3: _lock_sentinel on a missing file still returns 0 (fail-open idempotence unchanged)" \
  || no "F3: _lock_sentinel on a missing file regressed to non-zero"

# 34) Behavioral: the guarded caller pattern (mark, attempt lock, clear the
# mark on failure) leaves NO pending mark when the lock genuinely fails, so a
# later unlock is a correct no-op — no spurious sentinel_lock_to_unlock_ms.
guarded_fail=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  D=$(mktemp -d)
  T="$D/verdict.json"
  echo "{}" > "$T"
  PATH="'"$_fake_chmod_dir"':$PATH"
  _lifecycle_mark_lock_start "verdict.json"
  if ! _lock_sentinel "$T"; then
    _lifecycle_clear_lock_mark "verdict.json"
  fi
  _lifecycle_mark_unlock "verdict.json" 1
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  rm -rf "$D"')
[[ "$guarded_fail" == "0" ]] \
  && ok "F3: a failed lock (guarded pattern) leaves no pending mark — later unlock is a correct no-op, no spurious metric" \
  || no "F3: a failed lock still let a spurious sentinel_lock_to_unlock_ms metric emit ($guarded_fail records)"

rm -rf "$_fake_chmod_dir"

# 35) Structural: all 4 mark_lock_start-adjacent _lock_sentinel calls in
# run_ralph_desk.zsh (run_single_verifier, _final_verify_one_us, worker path,
# inline single-engine verify path) must be guarded — not bare/unchecked.
guarded_lock_count=$(grep -cE 'if ! _lock_sentinel "\$(VERDICT_FILE|SIGNAL_FILE)"; then' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$guarded_lock_count" == "4" ]] \
  && ok "F3: all 4 VERDICT_FILE/SIGNAL_FILE _lock_sentinel calls are guarded (clear mark on failure)" \
  || no "F3: expected 4 guarded lock call sites, got $guarded_lock_count"

# 36) Structural: both loop-top unlock+mark_unlock pairs are guarded (mark
# only emitted when the unlock actually succeeded).
guarded_unlock_count=$(grep -cE 'if _unlock_sentinel "\$(SIGNAL_FILE|VERDICT_FILE)"; then' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$guarded_unlock_count" == "2" ]] \
  && ok "F3: both loop-top _unlock_sentinel calls are guarded (mark only on success)" \
  || no "F3: expected 2 guarded unlock call sites, got $guarded_unlock_count"

# 37) Structural: the 3 DONE_CLAIM_FILE-only lock sites (no adjacent mark —
# H2 exclusion, unpaired) don't functionally need the return code under this
# repo's `set -uo pipefail` (no -e), but are made explicit with `|| true` so
# a future `set -e` cannot silently change behavior at an unrelated call site.
done_claim_lock_true_count=$(grep -c '_lock_sentinel "\$DONE_CLAIM_FILE" || true' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$done_claim_lock_true_count" == "3" ]] \
  && ok "F3: all 3 DONE_CLAIM_FILE-only lock sites are explicit || true (unpaired, H2 exclusion)" \
  || no "F3: expected 3 explicit || true DONE_CLAIM_FILE lock sites, got $done_claim_lock_true_count"

# ═══════════════════════════════════════════════════════════════════════════
# codex P2 sweep F4 (+ F9 behavioral pairing): the 4 rm-site clears
# (run_single_verifier, _final_verify_one_us x2, the inline single-engine
# path) currently clear the lock-mark BEFORE confirming the rm actually
# succeeded. If rm fails (read-only dir, permission error), the mark is
# dropped anyway even though the stale verdict file the mark was protecting
# against is STILL on disk — losing the mark's protective value for exactly
# the failure case it exists to guard. Fix: `rm -f ... && clear` (clear only
# after a confirmed removal; `rm -f` on an ALREADY-absent file still returns
# 0, so the common case is unaffected).
# ═══════════════════════════════════════════════════════════════════════════

# 38) Behavioral: a failing rm (read-only directory) keeps the pending
# lock-mark, exercising the exact rm-then-clear pattern the fixed call sites
# use.
_ro_dir=$(mktemp -d)
touch "$_ro_dir/verdict.json"
chmod 0555 "$_ro_dir"
rm_clear_result=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  _lifecycle_mark_lock_start "verdict.json"
  rm -f "'"$_ro_dir"'/verdict.json" 2>/dev/null && _lifecycle_clear_lock_mark "verdict.json"
  [[ -n "${LIFECYCLE_LOCK_TIMES[verdict.json]:-}" ]] && print -r -- "MARK_KEPT" || print -r -- "MARK_CLEARED"')
chmod 0755 "$_ro_dir"; rm -rf "$_ro_dir"
[[ "$rm_clear_result" == "MARK_KEPT" ]] \
  && ok "F4/F9: a failing rm (read-only dir) keeps the pending lock-mark (rm && clear ordering)" \
  || no "F4/F9: mark was cleared despite rm failing ($rm_clear_result)"

# 39) Structural: the OLD bad ordering (a bare _lifecycle_clear_lock_mark
# "${VERDICT_FILE:t}" line immediately followed by the rm -f "$VERDICT_FILE"
# line) must be fully gone.
old_bad_count=$(awk '
  /_lifecycle_clear_lock_mark "\$\{VERDICT_FILE:t\}"/ { getline nxt; if (nxt ~ /rm -f "\$VERDICT_FILE"/) n++ }
  END { print (n+0) }
' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$old_bad_count" == "0" ]] \
  && ok "F4: no rm site still clears the lock-mark BEFORE the rm (old bad ordering fully removed)" \
  || no "F4: found $old_bad_count site(s) still clearing before rm"

# 40) Structural: the NEW correct ordering (rm -f "$VERDICT_FILE"
# "$LEGACY_VERDICT_FILE" ... on one line, `&& _lifecycle_clear_lock_mark
# "${VERDICT_FILE:t}"` on the next) at all 4 targeted sites. The 5th
# VERDICT_FILE rm (loop-top cleanup, combined with SIGNAL_FILE/DONE_CLAIM_FILE)
# is intentionally excluded — it's already safe via its own unlock+
# mark_unlock pairing just above it, and doesn't match this VERDICT_FILE-first
# rm signature.
next_line_clear_count=$(awk '
  /rm -f "\$VERDICT_FILE" "\$LEGACY_VERDICT_FILE"/ { getline nxt; if (nxt ~ /^[[:space:]]*&&[[:space:]]*_lifecycle_clear_lock_mark "\$\{VERDICT_FILE:t\}"/) n++ }
  END { print (n+0) }
' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$next_line_clear_count" == "4" ]] \
  && ok "F4: all 4 targeted rm sites clear the lock-mark on the following line via && (rm confirmed before clear)" \
  || no "F4: expected 4 rm-then-clear (&&) sites, got $next_line_clear_count"

# ═══════════════════════════════════════════════════════════════════════════
# codex P2 sweep F5: (a) lock samples are attributed to the AMBIENT iter at
# UNLOCK time, not the iter the lock actually started in — a lock that starts
# in iter N and is unlocked at iter N+1's loop-top (normal flow; $ITERATION
# has already incremented by then) gets its record wrongly tagged iter=N+1.
# (b) a COMPLETE exit skips the loop-top unlock entirely (no "next iteration"
# for it to run in), silently dropping the LAST iteration's pending lock
# sample from campaign.jsonl.
# ═══════════════════════════════════════════════════════════════════════════

# 41) Behavioral: _lifecycle_mark_lock_start stores the CURRENT iter at
# mark-time; _lifecycle_mark_unlock uses the STORED iter, not whatever
# ambient iter the caller happens to pass at unlock time.
iter_attr=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json" 5
  _lifecycle_mark_unlock "verdict.json" 6
  print -r -- "${LIFECYCLE_RECORDS[1]}"')
[[ "$(print -r -- "$iter_attr" | jq -r '.iter')" == "5" ]] \
  && ok "F5: lock sample is attributed to the STORED lock-time iter (5), not the ambient unlock-time iter (6)" \
  || no "F5: iter misattribution NOT fixed ($iter_attr)"

# 42) _lifecycle_flush_pending_locks helper exists.
grep -q "^_lifecycle_flush_pending_locks()" "$REPO/src/scripts/lib_ralph_desk.zsh" \
  && ok "F5: _lifecycle_flush_pending_locks helper exists" \
  || no "F5: _lifecycle_flush_pending_locks helper missing"

# 43) Behavioral: a pending lock with no matching unlock is flushed (emitted)
# using its own stored iter, and a second flush with nothing pending is a
# silent no-op.
flush_result=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json" 7
  sleep 0.05
  _lifecycle_flush_pending_locks
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done
  LIFECYCLE_RECORDS=()
  _lifecycle_flush_pending_locks
  print -r -- "${#LIFECYCLE_RECORDS[@]}"')
n1=$(print -r -- "$flush_result" | sed -n '1p')
[[ "$n1" == "1" ]] && ok "F5: a pending lock with no unlock is flushed (emitted) by _lifecycle_flush_pending_locks" \
  || no "F5: flush produced $n1 records, expected 1"
flushed_iter=$(print -r -- "$flush_result" | sed -n '2p' | jq -r '.iter')
[[ "$flushed_iter" == "7" ]] && ok "F5: flushed record carries its OWN stored iter (7), not an ambient one" \
  || no "F5: flushed record iter wrong (got $flushed_iter)"
n2=$(print -r -- "$flush_result" | sed -n '3p')
[[ "$n2" == "0" ]] && ok "F5: a second flush with nothing pending is a silent no-op" \
  || no "F5: second flush unexpectedly produced $n2 records"

# 44) Structural: both COMPLETE-exit write_campaign_jsonl calls (leader
# finalize / sequential-verify pass, and full/ALL verify pass — both end in a
# literal "pass" 3rd arg, unlike the per-iteration in-loop call which passes
# a variable) are immediately preceded by _lifecycle_flush_pending_locks.
terminal_flush_count=$(awk '
  /_lifecycle_flush_pending_locks/ { getline nxt; if (nxt ~ /write_campaign_jsonl .*"pass"$/) n++ }
  END { print (n+0) }
' "$REPO/src/scripts/run_ralph_desk.zsh")
[[ "$terminal_flush_count" == "2" ]] \
  && ok "F5: both COMPLETE-exit write_campaign_jsonl calls are immediately preceded by _lifecycle_flush_pending_locks" \
  || no "F5: expected 2 flush-then-write_campaign_jsonl(pass) sites, got $terminal_flush_count"

# ═══════════════════════════════════════════════════════════════════════════
# codex P2 sweep F6: write_campaign_jsonl currently pipes jq's record build
# straight into `>> "$CAMPAIGN_JSONL"` with no error check on either the jq
# build or the append itself, and unconditionally resets LIFECYCLE_RECORDS
# afterward regardless of outcome — so an append failure (disk full,
# permission error, missing parent dir) silently drops both the row AND the
# pending lifecycle metrics for that iteration, with no diagnostic and no way
# to retry on the next flush.
# ═══════════════════════════════════════════════════════════════════════════

# 47) Behavioral: an append failure (target directory does not exist) does
# NOT reset the lifecycle accumulator, writes no row, logs an error, and the
# function itself returns non-zero.
append_fail=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }
  ERRLOG=""
  log_error(){ ERRLOG="${ERRLOG}$* "; }
  D=$(mktemp -d)
  CAMPAIGN_JSONL="$D/nonexistent-subdir/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=("{\"metric\":\"pane_eof_to_cleanup_ms\",\"value_ms\":1,\"ts\":\"x\"}")
  write_campaign_jsonl 1 US-001 pass
  rc=$?
  written=no
  [[ -f "$CAMPAIGN_JSONL" ]] && written=yes
  print -r -- "rc=$rc records=${#LIFECYCLE_RECORDS[@]} written=$written err=[${ERRLOG}]"
  rm -rf "$D"')
rc_val=$(print -r -- "$append_fail" | grep -oE 'rc=-?[0-9]+' | cut -d= -f2)
[[ -n "$rc_val" && "$rc_val" != "0" ]] \
  && ok "F6: write_campaign_jsonl returns non-zero when the append fails (rc=$rc_val)" \
  || no "F6: write_campaign_jsonl returned rc=$rc_val despite the append failing (expected non-zero)"
records_val=$(print -r -- "$append_fail" | grep -oE 'records=[0-9]+' | cut -d= -f2)
[[ "$records_val" == "1" ]] \
  && ok "F6: a failed campaign.jsonl append does NOT reset the lifecycle accumulator (retained for retry)" \
  || no "F6: accumulator was reset despite the append failing (records=$records_val)"
written_val=$(print -r -- "$append_fail" | grep -oE 'written=(yes|no)' | cut -d= -f2)
[[ "$written_val" == "no" ]] \
  && ok "F6: no partial/garbage row was written when the append target is unwritable" \
  || no "F6: a row was unexpectedly written despite the append failing (written=$written_val)"
err_val=$(print -r -- "$append_fail" | sed -n 's/.*err=\[\(.*\)\]$/\1/p')
[[ -n "$err_val" ]] \
  && ok "F6: a failed append logs an error" \
  || no "F6: no error logged on append failure"

# 48) Regression: the normal success path still writes a correct row and
# resets the accumulator (unchanged behavior — proves the failure-path fix
# didn't break the common case).
append_ok=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_error(){ :; }
  D=$(mktemp -d); CAMPAIGN_JSONL="$D/c.jsonl"
  WORKER_MODEL=h; WORKER_ENGINE=c; VERIFIER_ENGINE=c; CONSENSUS_MODE=off
  CONSECUTIVE_FAILURES=0; ROOT="$D"; SLUG=t; typeset -gA US_FAIL_HISTORY=()
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=("{\"metric\":\"pane_eof_to_cleanup_ms\",\"value_ms\":1,\"ts\":\"x\"}")
  write_campaign_jsonl 1 US-001 pass
  print -r -- "rc=$? records=${#LIFECYCLE_RECORDS[@]} rows=$(wc -l < "$CAMPAIGN_JSONL" | tr -d " ")"
  rm -rf "$D"')
[[ "$append_ok" == "rc=0 records=0 rows=1" ]] \
  && ok "F6: the normal success path still writes one row and resets the accumulator (rc=0)" \
  || no "F6: success path regressed ($append_ok)"

print ""
if (( FAIL == 0 )); then print "b3-lifecycle-emit: $PASS/$((PASS+FAIL)) PASS"; else print "b3-lifecycle-emit: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
