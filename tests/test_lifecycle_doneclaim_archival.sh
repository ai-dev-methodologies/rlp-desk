#!/usr/bin/env zsh
# IMP-10: sentinel_lock_to_unlock_ms for done-claim, emitted at its per-iteration
# archival close-out (archive_iter_artifacts) instead of never (closes F3.3/H2).
#
# Prior behavior: done-claim was locked (_lock_sentinel "$DONE_CLAIM_FILE") at 3
# call sites in run_ralph_desk.zsh but NONE of them called
# _lifecycle_mark_lock_start (the documented "H2 exclusion") and the happy path
# never calls _lifecycle_mark_unlock on it either — so the metric never emitted,
# period (not merely "only the last iteration", as an earlier draft of this fix
# assumed — there was no lock-start call to overwrite in the first place).
#
# Fix: _lifecycle_mark_lock_start is now called at all 3 DONE_CLAIM_FILE lock
# sites (mirroring the SIGNAL_FILE/VERDICT_FILE pattern), and
# archive_iter_artifacts (the per-iteration close-out — lib_ralph_desk.zsh,
# step 7d) now calls _lifecycle_mark_unlock with a new optional ctx_tag arg
# ("archival"), using the EXACT mark-time key (${DONE_CLAIM_FILE:t}).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

zsh -n "$LIB" && ok "lib_ralph_desk.zsh: zsh -n clean" || no "lib syntax"

# 1) mark lock for the done-claim key at iter 7, alongside an UNRELATED signal-
# file lock (scoping pin) → create fixture DONE_CLAIM_FILE/VERDICT_FILE →
# archive_iter_artifacts 7 → assert exactly one sentinel_lock_to_unlock_ms
# record: done-claim key, iter=7 (stored-iter preference intact), ctx=archival.
# Assert the pending map entry is cleared (no-op pin: a second archival call
# emits NOTHING more). Assert the signal-file lock is UNTOUCHED (scoping pin).
# ctx is free-text (log_lifecycle_metric's $3), embedded in the debug.log
# [LIFECYCLE] line, NOT a structured JSON field on LIFECYCLE_RECORDS entries
# (log_lifecycle_metric only JSON-embeds iter/us_id/sentinel_type) — so the
# ctx=archival assertion below captures debug.log via a log_debug stub with
# DEBUG=1, per the harness idiom (test_b3_lifecycle_emit.sh case 8d).
t1=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }
  DEBUG=1
  WARNFILE=$(mktemp)
  log_debug(){ print -r -- "$*" >> "$WARNFILE"; }
  export RLP_LIFECYCLE_METRICS=1
  D=$(mktemp -d)
  LOGS_DIR="$D/logs"; mkdir -p "$LOGS_DIR"
  DONE_CLAIM_FILE="$D/t-done-claim.json"
  VERDICT_FILE="$D/t-verify-verdict.json"
  echo "{\"us_id\":\"US-001\"}" > "$DONE_CLAIM_FILE"
  echo "{}" > "$VERDICT_FILE"
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "${DONE_CLAIM_FILE:t}" 7
  _lifecycle_mark_lock_start "t-iter-signal.json" 7
  sleep 0.05
  archive_iter_artifacts 7
  sleep 0.2
  print -r -- "COUNT1=${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "REC:$r"; done
  print -r -- "PENDING_DC=${LIFECYCLE_LOCK_TIMES[${DONE_CLAIM_FILE:t}]:-cleared}"
  print -r -- "PENDING_SIG=${LIFECYCLE_LOCK_TIMES[t-iter-signal.json]:-unset}"
  print -r -- "DEBUGLOG:$(cat "$WARNFILE")"
  archive_iter_artifacts 7
  print -r -- "COUNT2=${#LIFECYCLE_RECORDS[@]}"
  rm -rf "$D"; rm -f "$WARNFILE"')

count1=$(print -r -- "$t1" | grep '^COUNT1=' | cut -d= -f2)
[[ "$count1" == "1" ]] && ok "archive_iter_artifacts: exactly one sentinel_lock_to_unlock_ms record emitted for done-claim" \
  || no "expected 1 record after first archival, got $count1"

rec=$(print -r -- "$t1" | grep '^REC:' | sed 's/^REC://')
[[ "$(print -r -- "$rec" | jq -r '.sentinel_type')" == "t-done-claim.json" ]] \
  && ok "emitted record's sentinel_type == done-claim basename" \
  || no "sentinel_type wrong or missing ($rec)"
[[ "$(print -r -- "$rec" | jq -r '.iter')" == "7" ]] \
  && ok "emitted record carries iter=7 (stored-iter preference intact)" \
  || no "iter wrong or missing ($rec)"

debuglog=$(print -r -- "$t1" | grep '^DEBUGLOG:')
[[ "$debuglog" == *"sentinel_lock_to_unlock_ms"* ]] \
  && ok "debug.log LIFECYCLE line has metric=sentinel_lock_to_unlock_ms" \
  || no "debug.log missing sentinel_lock_to_unlock_ms ($debuglog)"
[[ "$debuglog" == *"t-done-claim.json"* ]] \
  && ok "debug.log LIFECYCLE line has the done-claim sentinel key" \
  || no "debug.log missing done-claim sentinel key ($debuglog)"
[[ "$debuglog" == *"iter=7"* ]] \
  && ok "debug.log LIFECYCLE line has iter=7" \
  || no "debug.log missing iter=7 ($debuglog)"
[[ "$debuglog" == *"ctx=archival"* ]] \
  && ok "debug.log LIFECYCLE line tagged ctx=archival" \
  || no "ctx=archival tag missing from debug.log ($debuglog)"

pending_dc=$(print -r -- "$t1" | grep '^PENDING_DC=' | cut -d= -f2)
[[ "$pending_dc" == "cleared" ]] && ok "done-claim pending lock-mark cleared after unlock" \
  || no "done-claim pending mark still set after unlock ($pending_dc)"

pending_sig=$(print -r -- "$t1" | grep '^PENDING_SIG=' | cut -d= -f2)
[[ "$pending_sig" != "unset" ]] && ok "scoping pin: an unrelated signal-file lock-mark set alongside is UNTOUCHED by the done-claim archival unlock" \
  || no "scoping violation: signal-file lock-mark was cleared by the done-claim unlock ($pending_sig)"

count2=$(print -r -- "$t1" | grep '^COUNT2=' | cut -d= -f2)
[[ "$count2" == "$count1" ]] && ok "no-op pin: a second archival call (no intervening re-lock) emits NOTHING" \
  || no "second archival call emitted a new record (count1=$count1 count2=$count2)"

# 2) Two-iteration case: mark iter 1 → archive 1 → mark iter 2 → archive 2 →
# TWO samples with correct per-iteration values (pins the fix — this metric
# now fires every iteration, not merely "the last one" nor "never").
t2=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  D=$(mktemp -d)
  LOGS_DIR="$D/logs"; mkdir -p "$LOGS_DIR"
  DONE_CLAIM_FILE="$D/t-done-claim.json"
  VERDICT_FILE="$D/t-verify-verdict.json"
  echo "{}" > "$VERDICT_FILE"
  LIFECYCLE_RECORDS=()
  echo "{\"us_id\":\"US-001\"}" > "$DONE_CLAIM_FILE"
  _lifecycle_mark_lock_start "${DONE_CLAIM_FILE:t}" 1
  sleep 0.05
  archive_iter_artifacts 1
  echo "{\"us_id\":\"US-002\"}" > "$DONE_CLAIM_FILE"
  _lifecycle_mark_lock_start "${DONE_CLAIM_FILE:t}" 2
  sleep 0.05
  archive_iter_artifacts 2
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  for r in "${LIFECYCLE_RECORDS[@]}"; do print -r -- "$r"; done
  rm -rf "$D"')

n=$(print -r -- "$t2" | head -1)
[[ "$n" == "2" ]] && ok "two-iteration case: mark->archive->mark->archive emits TWO samples (not 1, not 0)" \
  || no "expected 2 records across 2 iterations, got $n"
iters=$(print -r -- "$t2" | tail -n +2 | jq -r '.iter' 2>/dev/null | tr '\n' ',')
[[ "$iters" == "1,2," ]] && ok "two-iteration case: samples carry correct distinct per-iteration values (1 then 2, no overwrite-discard)" \
  || no "two-iteration case: iter values wrong (got $iters, want 1,2,)"

# 3) Pre-existing 2-arg _lifecycle_mark_unlock callers (sentinel_key, iter —
# no ctx_tag) stay byte-identical: no " ctx=" suffix appears in the debug.log
# detail string, and the JSON record shape is unchanged.
noctx=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }
  DEBUG=1
  WARNFILE=$(mktemp)
  log_debug(){ print -r -- "$*" >> "$WARNFILE"; }
  export RLP_LIFECYCLE_METRICS=1
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "verdict.json" 3
  _lifecycle_mark_unlock "verdict.json" 3
  sleep 0.2
  print -r -- "REC:${LIFECYCLE_RECORDS[1]}"
  print -r -- "DEBUGLOG:$(cat "$WARNFILE")"
  rm -f "$WARNFILE"')
noctx_rec=$(print -r -- "$noctx" | grep '^REC:' | sed 's/^REC://')
noctx_log=$(print -r -- "$noctx" | grep '^DEBUGLOG:')
[[ "$(print -r -- "$noctx_rec" | jq -r 'keys | sort | join(",")')" == "iter,metric,sentinel_type,ts,value_ms" ]] \
  && ok "2-arg _lifecycle_mark_unlock caller: JSON record shape unchanged (no ctx field)" \
  || no "2-arg caller's JSON record shape changed ($noctx_rec)"
[[ "$noctx_log" != *"ctx="* ]] \
  && ok "2-arg _lifecycle_mark_unlock caller (no ctx_tag) stays byte-identical: no ' ctx=' suffix in debug.log" \
  || no "2-arg caller unexpectedly carries a ctx= tag ($noctx_log)"

# 4) No done-claim file present this iteration (worker timeout / archival
# branch not entered) → no emission, no crash.
notfound=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  export RLP_LIFECYCLE_METRICS=1
  D=$(mktemp -d)
  LOGS_DIR="$D/logs"; mkdir -p "$LOGS_DIR"
  DONE_CLAIM_FILE="$D/missing-done-claim.json"
  VERDICT_FILE="$D/missing-verify-verdict.json"
  LIFECYCLE_RECORDS=()
  _lifecycle_mark_lock_start "${DONE_CLAIM_FILE:t}" 5
  archive_iter_artifacts 5
  print -r -- "${#LIFECYCLE_RECORDS[@]}"
  rm -rf "$D"')
[[ "$notfound" == "0" ]] && ok "edge case: no done-claim file this iteration → archival branch not entered, no emission" \
  || no "expected 0 records when DONE_CLAIM_FILE is absent, got $notfound"

print ""
print "TOTAL: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) && exit 0 || exit 1
