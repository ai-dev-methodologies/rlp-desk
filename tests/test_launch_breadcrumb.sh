#!/usr/bin/env zsh
# US-004 AC4.2 (F3.6 zero-artifact campaign abandonment guardrail,
# failure-modes.md §3): zsh-leader launch-breadcrumb behavioral tests.
#
# Extracts the REAL `_write_launch_record_t0` and `_emit_launch_record_outcome`
# functions from run_ralph_desk.zsh (source of truth, source-and-invoke style
# per test_pregate.sh / test_b2fix_sentinel_lock.sh) into a scratch leader
# process — NOT a full campaign (no tmux session, no claude/codex/jq
# dependency check) — then verifies: (1) the t0 record lands synchronously at
# startup, before any dependency check could exit early, and (2) `kill -HUP`
# (the signal tmux teardown delivers) drives the best-effort outcome update
# via the EXIT/INT/TERM/HUP trap.
#
# Note: zsh only re-checks pending trapped signals at "safe points" between
# statements, not mid-syscall inside a single long blocking `sleep N` — so
# the scratch leader idles via a tight poll loop (short repeated sleeps),
# mirroring the zsh leader's own POLL_INTERVAL-based main loop, not a bare
# `sleep 30`.
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

TMP_LIB="$TMP/launch-record-lib.zsh"
awk '/^_write_launch_record_t0\(\)/,/^}/'     "$RUN" >  "$TMP_LIB"
awk '/^_emit_launch_record_outcome\(\)/,/^}/' "$RUN" >> "$TMP_LIB"

if [[ -s "$TMP_LIB" ]] && grep -q "_write_launch_record_t0" "$TMP_LIB" && grep -q "_emit_launch_record_outcome" "$TMP_LIB"; then
  ok "extracted both production functions from run_ralph_desk.zsh"
else
  no "extraction failed — production function names/shape drifted"
  print ""; print "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ---------------------------------------------------------------------------
print -r -- "-- AC4.2: t0 record lands synchronously at leader startup"
CASE1="$TMP/case1"; SLUG1="demo"
LOGS_DIR1="$CASE1/.rlp-desk/logs/$SLUG1"
RECORD1="$LOGS_DIR1/launch-record.json"
mkdir -p "$CASE1"

zsh --no-rcs -c '
  source "'"$TMP_LIB"'"
  SLUG="'"$SLUG1"'"; LOGS_DIR="'"$LOGS_DIR1"'"
  _write_launch_record_t0
'

if [[ -f "$RECORD1" ]]; then
  ok "launch-record.json exists after _write_launch_record_t0"
  content1=$(cat "$RECORD1")
  [[ "$content1" == *'"phase":"launched"'* ]] && ok "t0 record phase is launched" \
    || no "t0 record phase wrong (got: $content1)"
  [[ "$content1" == *'"slug":"demo"'* ]] && ok "t0 record carries slug" \
    || no "t0 record slug missing (got: $content1)"
  [[ "$content1" == *'"leader":"zsh"'* ]] && ok "t0 record identifies the zsh leader" \
    || no "t0 record leader field missing (got: $content1)"
else
  no "launch-record.json missing after _write_launch_record_t0 (expected at $RECORD1)"
fi

# ---------------------------------------------------------------------------
print -r -- "-- AC4.2: kill -HUP a scratch leader → best-effort outcome update lands (SIGHUP path)"
CASE2="$TMP/case2"; SLUG2="demo2"
LOGS_DIR2="$CASE2/.rlp-desk/logs/$SLUG2"
RECORD2="$LOGS_DIR2/launch-record.json"
PIDFILE="$TMP/case2.pid"
mkdir -p "$CASE2"

zsh --no-rcs -c '
  source "'"$TMP_LIB"'"
  SLUG="'"$SLUG2"'"; LOGS_DIR="'"$LOGS_DIR2"'"
  trap "_emit_launch_record_outcome" EXIT INT TERM HUP
  _write_launch_record_t0
  print $$ > "'"$PIDFILE"'"
  while true; do sleep 0.2; done
' &
LEADER_JOB=$!

# Poll for the scratch leader to actually reach its t0 write + pidfile before
# signaling — a bare fixed sleep would race the child on a loaded machine.
for _ in $(seq 1 50); do
  [[ -s "$PIDFILE" && -f "$RECORD2" ]] && break
  sleep 0.1
done
LEADER_PID=$(cat "$PIDFILE" 2>/dev/null || true)

if [[ -z "$LEADER_PID" || ! -f "$RECORD2" ]]; then
  no "scratch leader never reached startup (t0 record/pidfile missing)"
else
  ok "scratch leader t0 record present before signaling"
  kill -HUP "$LEADER_PID"
  for _ in $(seq 1 50); do
    grep -q '"phase":"exited"' "$RECORD2" 2>/dev/null && break
    sleep 0.1
  done
  content2=$(cat "$RECORD2" 2>/dev/null || true)
  # jq re-serializes as pretty JSON ("key": value, space after colon) — the t0
  # write (printf, no jq dependency) is compact ("key":value, no space).
  [[ "$content2" == *'"phase": "exited"'* ]] && ok "SIGHUP drives the outcome update (phase:exited)" \
    || no "outcome update missing after SIGHUP (got: $content2)"
  [[ "$content2" == *'"exit_code"'* ]] && ok "outcome update carries an exit_code" \
    || no "exit_code missing from outcome update (got: $content2)"
  [[ "$content2" == *'"exited_at"'* ]] && ok "outcome update carries an exited_at timestamp" \
    || no "exited_at missing from outcome update (got: $content2)"
  [[ "$content2" == *'"slug": "demo2"'* ]] && ok "outcome update preserves the t0 slug field (merge, not clobber)" \
    || no "outcome update lost the t0 slug field (got: $content2)"
fi

kill -9 "$LEADER_PID" 2>/dev/null || true
wait "$LEADER_JOB" 2>/dev/null || true

# ---------------------------------------------------------------------------
print -r -- "-- structural: the production trap is armed on EXIT INT TERM HUP, with the outcome update chained first"
grep -q "trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT INT TERM HUP" "$RUN" \
  && ok "production trap includes HUP and chains _emit_launch_record_outcome first" \
  || no "production trap missing HUP or the outcome-update chain"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
