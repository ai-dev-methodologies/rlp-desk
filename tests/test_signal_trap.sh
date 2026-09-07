#!/bin/zsh
# A-5 (reaudit wave 1, round 2) — signal-trap fix regression test.
#
# History: round-1 split the combined `trap '...; cleanup' EXIT INT TERM HUP`
# into an EXIT-only cleanup chain plus `_on_signal()` (calls `exit
# $((128+signum))` for INT/TERM/HUP). That fixed the RESUME bug (Ctrl-C no
# longer just runs cleanup() and keeps looping) but an independent review
# caught a SECOND, more subtle zsh bug the round-1 test missed entirely
# (it armed the trap at FILE scope, not inside a function, so it could not
# reproduce this): a FUNCTION-SCOPED EXIT trap triggered by an actual `exit`
# call (not by the function returning) runs ONLY ITS FIRST COMMAND under
# zsh's default (non-POSIX) trap semantics — `_emit_final_cost_log` and
# `cleanup` were silently dropped, so panes were never killed, reports were
# never generated, and INTERRUPTED was unreachable. This is ALSO pre-existing
# on every bare `exit 1` inside main() (e.g. the runner-lock-busy exit),
# unrelated to signals.
#
# Empirically verified (see the two-way matrix below, reproduced against the
# real extracted code, not a paraphrase):
#   explicit chain call | setopt POSIX_TRAPS | result
#   ---------------------+---------------------+-------------------------
#         yes            |        yes          | correct (production)
#         yes            |        no           | correct (chain covers it)
#         no             |        yes          | correct (POSIX_TRAPS covers it)
#         no             |        no           | BUG: only the first EXIT-trap
#                         |                     | command runs (truncation)
# Only removing BOTH mechanisms reproduces the bug — they are independently
# sufficient. This test's mutation controls (b)/(c)/(d) below exercise all
# three off-diagonal / bug cells against the real extracted code.
#
# Fix, in order: (1) `setopt POSIX_TRAPS` (run_ralph_desk.zsh:22, right after
# `set -uo pipefail`) makes a function-scoped EXIT trap run to completion on
# `exit` and preserves `$?`. (2) `_on_signal` (~3494) now calls the full
# chain (`_emit_launch_record_outcome; _emit_final_cost_log; cleanup`)
# EXPLICITLY before `exit`, as defense in depth — all three are individually
# idempotent-guarded, so this and the (now POSIX-complete) EXIT trap's own
# run of the same chain never double-execute real work. (3)
# `_emit_launch_record_outcome` no longer trusts ambient `$?` when
# SIGNAL_RECEIVED is set (it was observed reading a bogus value) — it derives
# the conventional 128+signum exit code directly from SIGNAL_RECEIVED.
#
# This test extracts the REAL current implementation (never a mirror) of
# `_on_signal`, `_emit_launch_record_outcome`, the 4 trap-arm lines in
# main(), and cleanup()'s final_status conditional (COMPLETE/BLOCKED/
# INTERRUPTED/TIMEOUT), and wraps them in a `main() { ... }; main "$@"`
# structure exactly like production — a function-scoped trap is essential to
# reproducing the truncation bug; round-1's file-scoped-trap harness could
# not have caught it.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 "FAIL: jq not installed"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMP=$(mktemp -d)
trap 'jobs -p | xargs -I{} kill -9 {} 2>/dev/null; rm -rf "$TMP"' EXIT

# --- Extract the REAL implementation (brace-depth-aware, mirrors the
# extraction style already used by tests/test_us011_worker_model_upgrade.sh) ---
_extract_fn() {
  local fn_name="$1" src="$2"
  awk -v fn="$fn_name" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$src"
}

POSIX_TRAPS_PRESENT=0
grep -q '^setopt POSIX_TRAPS$' "$RUN" && POSIX_TRAPS_PRESENT=1
(( POSIX_TRAPS_PRESENT )) || print -u2 "NOTE: setopt POSIX_TRAPS not found in $RUN — 'new' scenarios below will rely on the explicit chain alone"

SIGNAL_RECEIVED_LINE=$(grep -n '^typeset -g SIGNAL_RECEIVED=""' "$RUN" | head -1 | cut -d: -f2-)
[[ -n "$SIGNAL_RECEIVED_LINE" ]] || { print -u2 "FAIL: SIGNAL_RECEIVED global not found in $RUN"; exit 1; }

ON_SIGNAL_BODY=$(_extract_fn "_on_signal" "$RUN")
[[ -n "$ON_SIGNAL_BODY" ]] || { print -u2 "FAIL: _on_signal not found in $RUN"; exit 1; }
print -r -- "$ON_SIGNAL_BODY" | grep -q 'exit \$(( 128 + signum ))' \
  || { print -u2 "FAIL: extracted _on_signal does not exit with 128+signum — extraction or source drifted"; exit 1; }
print -r -- "$ON_SIGNAL_BODY" | grep -q '_emit_launch_record_outcome' \
  && print -r -- "$ON_SIGNAL_BODY" | grep -q '_emit_final_cost_log' \
  && print -r -- "$ON_SIGNAL_BODY" | grep -q '^  cleanup$' \
  || { print -u2 "FAIL: _on_signal does not call the full chain before exit — round-2 fix not present"; exit 1; }

# _on_signal WITHOUT the explicit chain (mutation b/c below) — same function,
# with the three chain-call lines stripped, everything else byte-identical.
ON_SIGNAL_BODY_NO_CHAIN=$(print -r -- "$ON_SIGNAL_BODY" | grep -vE '^  (_emit_launch_record_outcome|_emit_final_cost_log|cleanup)$')

EMIT_LAUNCH_BODY=$(_extract_fn "_emit_launch_record_outcome" "$RUN")
[[ -n "$EMIT_LAUNCH_BODY" ]] || { print -u2 "FAIL: _emit_launch_record_outcome not found in $RUN"; exit 1; }
print -r -- "$EMIT_LAUNCH_BODY" | grep -q 'SIGNAL_RECEIVED' \
  || { print -u2 "FAIL: _emit_launch_record_outcome does not special-case SIGNAL_RECEIVED — round-2 fix not present"; exit 1; }

TRAP_LINES=$(grep -A3 "^  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT$" "$RUN" | head -4)
[[ -n "$TRAP_LINES" ]] || { print -u2 "FAIL: EXIT-only trap-arm block not found in $RUN"; exit 1; }
print -r -- "$TRAP_LINES" | grep -q "trap '_on_signal INT'"  || { print -u2 "FAIL: INT trap-arm line missing"; exit 1; }
print -r -- "$TRAP_LINES" | grep -q "trap '_on_signal TERM'" || { print -u2 "FAIL: TERM trap-arm line missing"; exit 1; }
print -r -- "$TRAP_LINES" | grep -q "trap '_on_signal HUP'"  || { print -u2 "FAIL: HUP trap-arm line missing"; exit 1; }

# cleanup()'s final_status conditional (COMPLETE/BLOCKED/INTERRUPTED/TIMEOUT) —
# a small, self-contained block referencing only COMPLETE_SENTINEL,
# BLOCKED_SENTINEL, SIGNAL_RECEIVED, all controllable in this harness.
FINAL_STATUS_BLOCK=$(awk '/^  local final_status="UNKNOWN"$/,/^  else final_status="TIMEOUT"; fi$/' "$RUN")
[[ -n "$FINAL_STATUS_BLOCK" ]] || { print -u2 "FAIL: cleanup()'s final_status block not found in $RUN"; exit 1; }
print -r -- "$FINAL_STATUS_BLOCK" | grep -q 'INTERRUPTED' \
  || { print -u2 "FAIL: final_status block has no INTERRUPTED arm — A-5 status fix not present"; exit 1; }

# =============================================================================
# Round-2 follow-up: the trap-arm point was moved to the TOP of main(), before
# the runner-lock + registry acquisition (was armed AFTER both — a signal in
# that window, or the window's own duplicate-runner `exit 1`, bypassed the
# trap entirely, leaking the lock/registry entry). Extract the REAL new
# main() prologue (trap arm through the two lock acquisitions) plus
# cleanup()'s REAL lock-release/unregister block, and the REAL lib helpers
# they depend on, to prove: a SIGINT delivered right after both locks are
# acquired (exactly the window this closes) still results in a full,
# ownership-correct cleanup.
# =============================================================================
MAIN_PROLOGUE=$(awk '/^main\(\) \{$/,/^  mkdir -p "\$LOGS_DIR" "\$RUNTIME_DIR" "\$OMX_STATE_DIR" 2>\/dev\/null$/' "$RUN")
[[ -n "$MAIN_PROLOGUE" ]] || { print -u2 "FAIL: main() prologue not found in $RUN"; exit 1; }
print -r -- "$MAIN_PROLOGUE" | grep -q "trap '_on_signal INT'" \
  || { print -u2 "FAIL: main() prologue does not arm the trap before lock acquisition — round-2 move not present"; exit 1; }
prologue_trap_line=$(print -r -- "$MAIN_PROLOGUE" | grep -n "trap '_on_signal INT'" | head -1 | cut -d: -f1)
prologue_lock_line=$(print -r -- "$MAIN_PROLOGUE" | grep -n 'acquire_slug_lock "\$RUNNER_LOCKFILE_PATH"' | head -1 | cut -d: -f1)
[[ -n "$prologue_trap_line" && -n "$prologue_lock_line" && "$prologue_trap_line" -lt "$prologue_lock_line" ]] \
  || { print -u2 "FAIL: trap arm (L$prologue_trap_line) is not before runner-lock acquisition (L$prologue_lock_line) in the extracted prologue"; exit 1; }
# Strip the trailing "main() { ... }" body-open into a standalone block we can
# re-wrap with our own campaign-loop stand-in and closing brace below.
MAIN_PROLOGUE_BODY=$(print -r -- "$MAIN_PROLOGUE" | tail -n +2)

LOCK_RELEASE_BLOCK=$(awk '/^  # Remove lockfile$/,/^  unregister_leader$/' "$RUN")
[[ -n "$LOCK_RELEASE_BLOCK" ]] || { print -u2 "FAIL: cleanup()'s lock-release block not found in $RUN"; exit 1; }
print -r -- "$LOCK_RELEASE_BLOCK" | grep -q '"\$own_pid" == "\$\$"' \
  || { print -u2 "FAIL: lock-release block is not ownership-gated (\$own_pid == \$\$) as expected"; exit 1; }

# Follow-up review (trap-arm relocation): cleanup() now also guards
# generate_campaign_report/generate_sv_report/the metadata write behind
# _skip_campaign_artifacts (skipped when LOCKFILE_ACQUIRED=0 and no terminal
# sentinel exists) — a duplicate-runner exit must not write a spurious
# campaign-report.md or overwrite metadata.json into a SAME-SLUG incumbent's
# live log dir. Extract that exact guarded block (real code, not a mirror).
GUARD_REPORT_BLOCK=$(awk '/^  local _skip_campaign_artifacts=0$/,/mv "\$\{METADATA_FILE\}\.tmp" "\$METADATA_FILE"$/' "$RUN")
[[ -n "$GUARD_REPORT_BLOCK" ]] || { print -u2 "FAIL: cleanup()'s _skip_campaign_artifacts guard block not found in $RUN"; exit 1; }
print -r -- "$GUARD_REPORT_BLOCK" | grep -q 'LOCKFILE_ACQUIRED:-0' \
  || { print -u2 "FAIL: _skip_campaign_artifacts guard does not check LOCKFILE_ACQUIRED"; exit 1; }
GUARD_REPORT_BLOCK_FULL="$GUARD_REPORT_BLOCK"$'\n  fi'

REGISTER_LEADER_BODY=$(_extract_fn "register_leader" "$LIB")
UNREGISTER_LEADER_BODY=$(_extract_fn "unregister_leader" "$LIB")
LEADER_REGISTRY_DIR_BODY=$(_extract_fn "_leader_registry_dir" "$LIB")
ACQUIRE_SLUG_LOCK_BODY=$(_extract_fn "acquire_slug_lock" "$LIB")
[[ -n "$REGISTER_LEADER_BODY" && -n "$UNREGISTER_LEADER_BODY" && -n "$LEADER_REGISTRY_DIR_BODY" && -n "$ACQUIRE_SLUG_LOCK_BODY" ]] \
  || { print -u2 "FAIL: could not extract register_leader/unregister_leader/_leader_registry_dir/acquire_slug_lock from $LIB"; exit 1; }

# --- Harness builder ---------------------------------------------------
# $1=out_file $2=on_signal_body(yes-chain or no-chain variant) $3=1|0 apply
# setopt POSIX_TRAPS $4=1|0 use the split-trap arm lines (0 = old combined
# form, ignores $2/$3)
_build_harness() {
  local out="$1" on_signal_body="$2" with_posix="$3" split_traps="$4"
  {
    echo '#!/bin/zsh'
    echo 'LOG="$1"; METADATA_FILE="$2"; LAUNCH_RECORD_FILE="$3"'
    echo 'COMPLETE_SENTINEL="/nonexistent-complete-sentinel"'
    echo 'BLOCKED_SENTINEL="/nonexistent-blocked-sentinel"'
    (( with_posix )) && echo 'setopt POSIX_TRAPS'
    echo 'CLEANUP_DONE=0'
    echo 'cleanup() {'
    echo '  (( ${CLEANUP_DONE:-0} )) && return 0'
    echo '  CLEANUP_DONE=1'
    echo '  echo "CLEANUP_RAN" >> "$LOG"'
    print -r -- "$FINAL_STATUS_BLOCK"
    echo '  jq -n --arg status "$final_status" "{campaign_status: \$status}" > "$METADATA_FILE" 2>/dev/null'
    echo '}'
    echo 'COST_LOG_FINAL_WRITTEN=0'
    echo '_emit_final_cost_log() {'
    echo '  (( ${COST_LOG_FINAL_WRITTEN:-0} )) && return 0'
    echo '  COST_LOG_FINAL_WRITTEN=1'
    echo '  echo "EMIT_FINAL_COST_LOG_RAN" >> "$LOG"'
    echo '}'
    echo 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
    print -r -- "$EMIT_LAUNCH_BODY"
    echo "$SIGNAL_RECEIVED_LINE"
    if (( split_traps )); then
      print -r -- "$on_signal_body"
      echo 'main() {'
      print -r -- "$TRAP_LINES"
      echo '  i=0'
      echo '  while (( i < 10000 )); do'
      echo '    echo "LOOP $i" >> "$LOG"'
      echo '    sleep 0.05'
      echo '    (( i++ ))'
      echo '  done'
      echo '}'
      echo 'main "$@"'
    else
      echo 'main() {'
      echo "  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT INT TERM HUP"
      echo '  i=0'
      echo '  while (( i < 10000 )); do'
      echo '    echo "LOOP $i" >> "$LOG"'
      echo '    sleep 0.05'
      echo '    (( i++ ))'
      echo '  done'
      echo '}'
      echo 'main "$@"'
    fi
  } > "$out"
  chmod +x "$out"
}

_seed_launch_record() {
  print -r -- '{"ts":"2020-01-01T00:00:00Z","slug":"test","leader":"zsh","pid":1,"phase":"launched"}' > "$1"
}

_wait_exit_within() { # $1=pid $2=budget_seconds -> echoes 1 exited / 0 still alive
  local pid="$1" budget="$2" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    waited=$(( waited + 1 ))
    (( waited >= budget * 10 )) && { echo 0; return; }
  done
  echo 1
}

_build_harness "$TMP/h_new.zsh"          "$ON_SIGNAL_BODY"         "$POSIX_TRAPS_PRESENT" 1
_build_harness "$TMP/h_old_combined.zsh" ""                        0                       0
_build_harness "$TMP/h_no_chain_no_posix.zsh" "$ON_SIGNAL_BODY_NO_CHAIN" 0                  1
_build_harness "$TMP/h_chain_no_posix.zsh"    "$ON_SIGNAL_BODY"         0                  1
_build_harness "$TMP/h_no_chain_posix.zsh"    "$ON_SIGNAL_BODY_NO_CHAIN" 1                  1

# --- exit-1-inside-main harness builder -------------------------------
# The pre-existing (not signal-related) truncation class: a bare `exit N`
# executed from inside main() — e.g. the runner-lock-busy exit — hits the
# SAME function-scoped-EXIT-trap truncation bug. $1=out_file $2=1|0 apply
# setopt POSIX_TRAPS.
_build_exit1_harness() {
  local out="$1" with_posix="$2"
  {
    echo '#!/bin/zsh'
    echo 'LOG="$1"; METADATA_FILE="$2"; LAUNCH_RECORD_FILE="$3"'
    echo 'COMPLETE_SENTINEL="/nonexistent-complete-sentinel"'
    echo 'BLOCKED_SENTINEL="/nonexistent-blocked-sentinel"'
    (( with_posix )) && echo 'setopt POSIX_TRAPS'
    echo 'CLEANUP_DONE=0'
    echo 'cleanup() {'
    echo '  (( ${CLEANUP_DONE:-0} )) && return 0'
    echo '  CLEANUP_DONE=1'
    echo '  echo "CLEANUP_RAN" >> "$LOG"'
    print -r -- "$FINAL_STATUS_BLOCK"
    echo '  jq -n --arg status "$final_status" "{campaign_status: \$status}" > "$METADATA_FILE" 2>/dev/null'
    echo '}'
    echo 'COST_LOG_FINAL_WRITTEN=0'
    echo '_emit_final_cost_log() {'
    echo '  (( ${COST_LOG_FINAL_WRITTEN:-0} )) && return 0'
    echo '  COST_LOG_FINAL_WRITTEN=1'
    echo '  echo "EMIT_FINAL_COST_LOG_RAN" >> "$LOG"'
    echo '}'
    echo 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
    print -r -- "$EMIT_LAUNCH_BODY"
    echo "$SIGNAL_RECEIVED_LINE"
    echo 'main() {'
    echo "  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT"
    echo '  echo "in main" >> "$LOG"'
    echo '  exit 1'
    echo '}'
    echo 'main "$@"'
  } > "$out"
  chmod +x "$out"
}
_build_exit1_harness "$TMP/h_exit1_posix.zsh"    1
_build_exit1_harness "$TMP/h_exit1_no_posix.zsh" 0

# run_scenario <harness> <signal-name> <kill-sig> <expected-exit-code> <label>
run_scenario() {
  local harness="$1" signame="$2" killsig="$3" expected_ec="$4" label="$5"
  local log="$TMP/${label}.log" meta="$TMP/${label}.meta.json" lr="$TMP/${label}.lr.json"
  : > "$log"; _seed_launch_record "$lr"
  zsh -f "$harness" "$log" "$meta" "$lr" &
  local pid=$!
  sleep 0.3
  kill "-$killsig" "$pid" 2>/dev/null
  local exited; exited=$(_wait_exit_within "$pid" 2)
  local ec=""
  if [[ "$exited" == "1" ]]; then
    wait "$pid"; ec=$?
  else
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  fi
  print -r -- "$exited|$ec|$log|$meta|$lr"
}

_count() { # grep -c without the "0\n0" double-count-on-no-match hazard
  local pattern="$1" file="$2" n
  n=$(grep -c -- "$pattern" "$file" 2>/dev/null)
  print -r -- "${n:-0}"
}

# =============================================================================
# Scenario 1: NEW (production) form — SIGINT
# =============================================================================
result=$(run_scenario "$TMP/h_new.zsh" INT INT 130 s1)
IFS='|' read -r exited ec log meta lr <<< "$result"
if [[ "$exited" == "1" && "$ec" == "130" ]]; then ok "SIGINT: process exits within 2s with status 130"
else no "SIGINT: expected exit within budget with status 130, got exited=$exited ec=$ec"; fi
(( $(_count '^CLEANUP_RAN$' "$log") == 1 )) && ok "SIGINT: cleanup ran exactly once" || no "SIGINT: cleanup ran $(_count '^CLEANUP_RAN$' "$log") times"
(( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") == 1 )) && ok "SIGINT: _emit_final_cost_log ran exactly once (round-2: no longer truncated)" || no "SIGINT: _emit_final_cost_log ran $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") times"
[[ "$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)" == "INTERRUPTED" ]] \
  && ok "SIGINT: metadata campaign_status=INTERRUPTED" || no "SIGINT: metadata campaign_status='$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)'"
[[ "$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)" == "130" ]] \
  && ok "SIGINT: launch-record exit_code=130 (round-2: no longer bogus)" || no "SIGINT: launch-record exit_code='$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)'"

# =============================================================================
# Scenario 2: NEW (production) form — SIGTERM
# =============================================================================
result=$(run_scenario "$TMP/h_new.zsh" TERM TERM 143 s2)
IFS='|' read -r exited ec log meta lr <<< "$result"
if [[ "$exited" == "1" && "$ec" == "143" ]]; then ok "SIGTERM: process exits within 2s with status 143"
else no "SIGTERM: expected exit within budget with status 143, got exited=$exited ec=$ec"; fi
(( $(_count '^CLEANUP_RAN$' "$log") == 1 )) && ok "SIGTERM: cleanup ran exactly once" || no "SIGTERM: cleanup ran $(_count '^CLEANUP_RAN$' "$log") times"
(( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") == 1 )) && ok "SIGTERM: _emit_final_cost_log ran exactly once" || no "SIGTERM: _emit_final_cost_log ran $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") times"
[[ "$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)" == "INTERRUPTED" ]] \
  && ok "SIGTERM: metadata campaign_status=INTERRUPTED" || no "SIGTERM: metadata campaign_status='$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)'"
[[ "$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)" == "143" ]] \
  && ok "SIGTERM: launch-record exit_code=143" || no "SIGTERM: launch-record exit_code='$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)'"

# =============================================================================
# Scenario 3: NEW (production) form — SIGHUP
# =============================================================================
result=$(run_scenario "$TMP/h_new.zsh" HUP HUP 129 s3)
IFS='|' read -r exited ec log meta lr <<< "$result"
if [[ "$exited" == "1" && "$ec" == "129" ]]; then ok "SIGHUP: process exits within 2s with status 129"
else no "SIGHUP: expected exit within budget with status 129, got exited=$exited ec=$ec"; fi
(( $(_count '^CLEANUP_RAN$' "$log") == 1 )) && ok "SIGHUP: cleanup ran exactly once" || no "SIGHUP: cleanup ran $(_count '^CLEANUP_RAN$' "$log") times"
(( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") == 1 )) && ok "SIGHUP: _emit_final_cost_log ran exactly once" || no "SIGHUP: _emit_final_cost_log ran $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") times"
[[ "$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)" == "INTERRUPTED" ]] \
  && ok "SIGHUP: metadata campaign_status=INTERRUPTED" || no "SIGHUP: metadata campaign_status='$(jq -r '.campaign_status // empty' "$meta" 2>/dev/null)'"
[[ "$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)" == "129" ]] \
  && ok "SIGHUP: launch-record exit_code=129" || no "SIGHUP: launch-record exit_code='$(jq -r '.exit_code // empty' "$lr" 2>/dev/null)'"

# =============================================================================
# Mutation (a): OLD combined trap form — Ctrl-C must NOT exit within budget
# (the original resume bug this whole US started from).
# =============================================================================
result=$(run_scenario "$TMP/h_old_combined.zsh" INT INT 130 ma)
IFS='|' read -r exited ec log meta lr <<< "$result"
[[ "$exited" == "0" ]] \
  && ok "mutation (a): OLD combined trap does NOT exit within 2s of SIGINT (resumes looping, reproducing the original bug)" \
  || no "mutation (a): OLD combined trap exited within budget — this scenario would not have caught the original bug"

# =============================================================================
# Mutation (b): split traps, NEITHER fix present (no explicit chain in
# _on_signal, no POSIX_TRAPS) — the exact bug the round-2 review caught.
# Process DOES exit (that part round-1 already fixed), but the EXIT trap
# truncates: only _emit_launch_record_outcome (its first command) runs.
# =============================================================================
result=$(run_scenario "$TMP/h_no_chain_no_posix.zsh" INT INT 130 mb)
IFS='|' read -r exited ec log meta lr <<< "$result"
[[ "$exited" == "1" && "$ec" == "130" ]] \
  && ok "mutation (b): process still exits correctly (130) — the resume bug stays fixed" \
  || no "mutation (b): process did not exit as expected (exited=$exited ec=$ec)"
cleanup_ran=$(_count '^CLEANUP_RAN$' "$log")
cost_ran=$(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log")
if (( cleanup_ran == 0 && cost_ran == 0 )); then
  ok "mutation (b): confirmed — with NEITHER fix, cleanup and _emit_final_cost_log are silently dropped (truncated EXIT trap, the round-2 bug)"
else
  no "mutation (b): expected cleanup/_emit_final_cost_log to be truncated (0 runs each), got cleanup=$cleanup_ran cost_log=$cost_ran — mutation does not reproduce the bug"
fi

# =============================================================================
# Mutation (c): split traps, explicit chain KEPT, POSIX_TRAPS removed.
# Empirically verified this does NOT reproduce the bug — the explicit chain
# call inside _on_signal runs as ordinary function calls (not trap-body
# execution), so it is unaffected by EXIT-trap truncation semantics either
# way. This is a POSITIVE robustness check: fix #2 (the explicit chain) is
# independently sufficient without fix #1 (POSIX_TRAPS).
# =============================================================================
result=$(run_scenario "$TMP/h_chain_no_posix.zsh" INT INT 130 mc)
IFS='|' read -r exited ec log meta lr <<< "$result"
(( $(_count '^CLEANUP_RAN$' "$log") >= 1 )) && (( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") >= 1 )) \
  && ok "mutation (c) robustness: with POSIX_TRAPS removed but the explicit chain kept, cleanup and _emit_final_cost_log still ran (fix #2 alone is sufficient)" \
  || no "mutation (c) robustness: explicit chain alone failed to run cleanup/_emit_final_cost_log without POSIX_TRAPS"

# =============================================================================
# Mutation (d): split traps, explicit chain REMOVED, POSIX_TRAPS kept.
# Empirically verified this ALSO does not reproduce the bug — POSIX_TRAPS
# alone makes the EXIT trap run to completion. Positive robustness check for
# fix #1 in isolation.
# =============================================================================
result=$(run_scenario "$TMP/h_no_chain_posix.zsh" INT INT 130 md)
IFS='|' read -r exited ec log meta lr <<< "$result"
(( $(_count '^CLEANUP_RAN$' "$log") >= 1 )) && (( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$log") >= 1 )) \
  && ok "mutation (d) robustness: with the explicit chain removed but POSIX_TRAPS kept, cleanup and _emit_final_cost_log still ran (fix #1 alone is sufficient)" \
  || no "mutation (d) robustness: POSIX_TRAPS alone failed to run cleanup/_emit_final_cost_log without the explicit chain"

# =============================================================================
# Step 5: the PRE-EXISTING (non-signal) truncation class — a bare `exit 1`
# executed directly inside main() (e.g. the runner-lock-busy exit) hits the
# same function-scoped-EXIT-trap bug, independent of _on_signal entirely.
# =============================================================================
: > "$TMP/e1.log"; _seed_launch_record "$TMP/e1.lr.json"
zsh -f "$TMP/h_exit1_posix.zsh" "$TMP/e1.log" "$TMP/e1.meta.json" "$TMP/e1.lr.json"
e1_ec=$?
(( e1_ec == 1 )) && ok "exit-1-in-main (POSIX_TRAPS): process exits with status 1" \
  || no "exit-1-in-main (POSIX_TRAPS): expected exit 1, got $e1_ec"
(( $(_count '^CLEANUP_RAN$' "$TMP/e1.log") == 1 )) \
  && ok "exit-1-in-main (POSIX_TRAPS): cleanup ran" || no "exit-1-in-main (POSIX_TRAPS): cleanup did not run"
(( $(_count '^EMIT_FINAL_COST_LOG_RAN$' "$TMP/e1.log") == 1 )) \
  && ok "exit-1-in-main (POSIX_TRAPS): _emit_final_cost_log ran (ALL THREE chain functions completed on a bare exit, not just a signal)" \
  || no "exit-1-in-main (POSIX_TRAPS): _emit_final_cost_log did not run"

# Mutation control: the SAME bare exit-1, WITHOUT POSIX_TRAPS — reproduces
# the pre-existing truncation independent of any signal handling at all.
: > "$TMP/e1n.log"; _seed_launch_record "$TMP/e1n.lr.json"
zsh -f "$TMP/h_exit1_no_posix.zsh" "$TMP/e1n.log" "$TMP/e1n.meta.json" "$TMP/e1n.lr.json"
e1n_ec=$?
(( e1n_ec == 1 )) && ok "exit-1-in-main (no POSIX_TRAPS): process still exits with status 1" \
  || no "exit-1-in-main (no POSIX_TRAPS): expected exit 1, got $e1n_ec"
e1n_cleanup=$(_count '^CLEANUP_RAN$' "$TMP/e1n.log")
e1n_cost=$(_count '^EMIT_FINAL_COST_LOG_RAN$' "$TMP/e1n.log")
if (( e1n_cleanup == 0 && e1n_cost == 0 )); then
  ok "mutation: without POSIX_TRAPS, a bare exit-1-in-main ALSO truncates the EXIT trap (cleanup/_emit_final_cost_log dropped) — confirms this is a pre-existing bug class, not signal-specific"
else
  no "mutation: expected exit-1-in-main truncation without POSIX_TRAPS (cleanup=$e1n_cleanup cost_log=$e1n_cost)"
fi

# =============================================================================
# Round-2 follow-up harness: the REAL new main() prologue (trap arm, THEN
# runner-lock acquire + register_leader, THEN slug-lock acquire), the REAL
# lock-release/unregister block from cleanup(), and the REAL lib helpers
# (acquire_slug_lock, register_leader, unregister_leader, _leader_registry_dir).
# =============================================================================
_build_prologue_harness() {
  local out="$1" with_guard="${2:-1}"
  {
    echo '#!/bin/zsh'
    echo 'set -uo pipefail'
    echo 'setopt POSIX_TRAPS'
    echo 'LOG="$1"; RUNNER_LOCKFILE_PATH="$2"; LOCKFILE_PATH="$3"; DESK="$4"'
    echo 'LOGS_DIR="$5"; RUNTIME_DIR="$6"; OMX_STATE_DIR="$7"'
    echo 'ROOT_HASH="testroothash"; SLUG="testslug"; ROOT="/tmp/nonexistent-root"'
    echo 'START_TIME=$(date +%s)'
    echo 'COMPLETE_SENTINEL="/nonexistent-complete-sentinel"'
    echo 'BLOCKED_SENTINEL="/nonexistent-blocked-sentinel"'
    echo 'METADATA_FILE="/nonexistent-metadata.json"'
    echo 'LOCKFILE_ACQUIRED=0'
    echo 'log(){ :; }; log_error(){ echo "LOG_ERROR: $*" >> "$LOG"; }; log_debug(){ echo "LOG_DEBUG: $*" >> "$LOG"; }'
    # Stub the two report generators as simple marker writers that mimic
    # generate_campaign_report's real AC9 rotation (existing report ->
    # -v1.md, then a fresh write) — enough to prove the GUARD works without
    # pulling in the real function's much larger dependency surface.
    echo 'generate_campaign_report() {'
    echo '  local report_file="$LOGS_DIR/campaign-report.md"'
    echo '  if [[ -f "$report_file" ]]; then'
    echo '    local v=1'
    echo '    while [[ -f "${report_file%.md}-v${v}.md" ]]; do (( v++ )); done'
    echo '    mv "$report_file" "${report_file%.md}-v${v}.md"'
    echo '  fi'
    echo '  echo "REPORT_WRITTEN" > "$report_file"'
    echo '  echo "GENERATE_CAMPAIGN_REPORT_RAN" >> "$LOG"'
    echo '}'
    echo 'generate_sv_report() { echo "GENERATE_SV_REPORT_RAN" >> "$LOG"; }'
    print -r -- "$LEADER_REGISTRY_DIR_BODY"
    echo 'atomic_write() { local target="$1"; local tmp="${target}.tmp.$$"; cat > "$tmp" 2>/dev/null && mv "$tmp" "$target" 2>/dev/null; }'
    print -r -- "$REGISTER_LEADER_BODY"
    print -r -- "$UNREGISTER_LEADER_BODY"
    print -r -- "$ACQUIRE_SLUG_LOCK_BODY"
    echo 'CLEANUP_DONE=0'
    echo 'cleanup() {'
    echo '  (( ${CLEANUP_DONE:-0} )) && return 0'
    echo '  CLEANUP_DONE=1'
    echo '  echo "CLEANUP_RAN" >> "$LOG"'
    print -r -- "$LOCK_RELEASE_BLOCK"
    if (( with_guard )); then
      print -r -- "$GUARD_REPORT_BLOCK_FULL"
    else
      # Mutation control: the PRE-fix shape — unconditional report generation,
      # no _skip_campaign_artifacts guard at all.
      echo '  generate_campaign_report'
      echo '  generate_sv_report'
    fi
    echo '}'
    echo 'COST_LOG_FINAL_WRITTEN=0'
    echo '_emit_final_cost_log() {'
    echo '  (( ${COST_LOG_FINAL_WRITTEN:-0} )) && return 0'
    echo '  COST_LOG_FINAL_WRITTEN=1'
    echo '  echo "EMIT_FINAL_COST_LOG_RAN" >> "$LOG"'
    echo '}'
    echo 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
    echo '_emit_launch_record_outcome() { LAUNCH_RECORD_OUTCOME_WRITTEN=1; return 0; }'
    echo 'typeset -g SIGNAL_RECEIVED=""'
    print -r -- "$ON_SIGNAL_BODY"
    echo 'main() {'
    print -r -- "$MAIN_PROLOGUE_BODY"
    echo '  i=0'
    echo '  while (( i < 10000 )); do'
    echo '    echo "LOOP $i" >> "$LOG"'
    echo '    sleep 0.05'
    echo '    (( i++ ))'
    echo '  done'
    echo '}'
    echo 'main "$@"'
  } > "$out"
  chmod +x "$out"
}
_build_prologue_harness "$TMP/h_prologue.zsh" 1
_build_prologue_harness "$TMP/h_prologue_no_guard.zsh" 0

# --- Scenario: SIGINT after both locks are acquired (the window this closes) ---
PR1_RUNNER_LOCK="$TMP/pr1-runner.lock"
PR1_SLUG_LOCK="$TMP/pr1-slug.lock"
PR1_DESK="$TMP/pr1-desk"; mkdir -p "$PR1_DESK"
PR1_LOGS="$TMP/pr1-logs"; PR1_RUNTIME="$TMP/pr1-runtime"; PR1_OMX="$TMP/pr1-omx"
PR1_LOG="$TMP/pr1.log"; : > "$PR1_LOG"
zsh -f "$TMP/h_prologue.zsh" "$PR1_LOG" "$PR1_RUNNER_LOCK" "$PR1_SLUG_LOCK" "$PR1_DESK" "$PR1_LOGS" "$PR1_RUNTIME" "$PR1_OMX" &
pr1_pid=$!
sleep 0.3
kill -INT "$pr1_pid" 2>/dev/null
pr1_exited=$(_wait_exit_within "$pr1_pid" 2)
if [[ "$pr1_exited" == "1" ]]; then
  wait "$pr1_pid"; pr1_ec=$?
  (( pr1_ec == 130 )) && ok "prologue: SIGINT after both locks acquired exits 130" \
    || no "prologue: expected exit 130, got $pr1_ec"
else
  no "prologue: process did not exit within 2s of SIGINT"
  kill -9 "$pr1_pid" 2>/dev/null; wait "$pr1_pid" 2>/dev/null
fi
(( $(_count '^CLEANUP_RAN$' "$PR1_LOG") == 1 )) \
  && ok "prologue: cleanup ran exactly once" || no "prologue: cleanup ran $(_count '^CLEANUP_RAN$' "$PR1_LOG") times"
[[ ! -f "$PR1_RUNNER_LOCK" ]] \
  && ok "prologue: OWN runner lock released (no longer leaked in the old uncovered window)" \
  || no "prologue: runner lock file still present at $PR1_RUNNER_LOCK"
[[ ! -f "${PR1_RUNNER_LOCK}.meta" ]] \
  && ok "prologue: runner lock .meta sidecar released" \
  || no "prologue: runner lock .meta sidecar still present"
[[ ! -f "$PR1_SLUG_LOCK" ]] \
  && ok "prologue: OWN slug lock released" \
  || no "prologue: slug lock file still present at $PR1_SLUG_LOCK"
pr1_registry_dir="$PR1_DESK/logs/.rlp-desk-leaders-testroothash.d"
pr1_registry_files=("$pr1_registry_dir"/*.json(N))
(( ${#pr1_registry_files} == 0 )) \
  && ok "prologue: OWN registry entry removed (no leaked leader-registry file)" \
  || no "prologue: registry entry still present: ${pr1_registry_files[*]}"

# --- Mutation control: revert to the OLD (post-lock-acquisition) trap-arm
# position — same SIGINT timing should now LEAK the lock/registry entry,
# proving this harness actually discriminates the fix from the bug. Built by
# moving the trap-arm lines to the END of the extracted prologue instead of
# the start (mirrors the pre-fix ordering exactly, using the same real
# lock/registry code — only the ORDER of statements changes). ---
MAIN_PROLOGUE_BODY_OLD_ORDER=$(print -r -- "$MAIN_PROLOGUE_BODY" \
  | grep -vE "^  (trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT|trap '_on_signal (INT|TERM|HUP)'.*)$")
TRAP_ARM_LINES_ONLY=$(print -r -- "$MAIN_PROLOGUE_BODY" | grep -E "^  (trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT|trap '_on_signal (INT|TERM|HUP)'.*)$")
_build_prologue_harness_old_order() {
  local out="$1"
  {
    echo '#!/bin/zsh'
    echo 'set -uo pipefail'
    echo 'setopt POSIX_TRAPS'
    echo 'LOG="$1"; RUNNER_LOCKFILE_PATH="$2"; LOCKFILE_PATH="$3"; DESK="$4"'
    echo 'LOGS_DIR="$5"; RUNTIME_DIR="$6"; OMX_STATE_DIR="$7"'
    echo 'ROOT_HASH="testroothash"; SLUG="testslug"; ROOT="/tmp/nonexistent-root"'
    echo 'COMPLETE_SENTINEL="/nonexistent-complete-sentinel"'
    echo 'BLOCKED_SENTINEL="/nonexistent-blocked-sentinel"'
    echo 'LOCKFILE_ACQUIRED=0'
    echo 'log(){ :; }; log_error(){ echo "LOG_ERROR: $*" >> "$LOG"; }; log_debug(){ :; }'
    print -r -- "$LEADER_REGISTRY_DIR_BODY"
    echo 'atomic_write() { local target="$1"; local tmp="${target}.tmp.$$"; cat > "$tmp" 2>/dev/null && mv "$tmp" "$target" 2>/dev/null; }'
    print -r -- "$REGISTER_LEADER_BODY"
    print -r -- "$UNREGISTER_LEADER_BODY"
    print -r -- "$ACQUIRE_SLUG_LOCK_BODY"
    echo 'CLEANUP_DONE=0'
    echo 'cleanup() {'
    echo '  (( ${CLEANUP_DONE:-0} )) && return 0'
    echo '  CLEANUP_DONE=1'
    echo '  echo "CLEANUP_RAN" >> "$LOG"'
    print -r -- "$LOCK_RELEASE_BLOCK"
    echo '}'
    echo 'COST_LOG_FINAL_WRITTEN=0'
    echo '_emit_final_cost_log() { echo "EMIT_FINAL_COST_LOG_RAN" >> "$LOG"; }'
    echo '_emit_launch_record_outcome() { :; }'
    echo 'typeset -g SIGNAL_RECEIVED=""'
    print -r -- "$ON_SIGNAL_BODY"
    echo 'main() {'
    print -r -- "$MAIN_PROLOGUE_BODY_OLD_ORDER"
    # Synthetic widening, testing-only: the real pre-fix window between lock
    # acquisition and the (old, later) trap arm is a handful of mkdir/write
    # syscalls — microseconds, not reliably raceable from a test. Insert an
    # artificial pause here (ONLY in this mutation-control build, never in the
    # "new"/fixed harness) so this test's SIGINT deterministically lands
    # inside that window instead of trying to win a real race. The ORDER of
    # the real extracted statements (lock/registry acquisition before trap
    # arm) is unchanged — this only makes the already-real gap observable.
    echo '  sleep 1'
    print -r -- "$TRAP_ARM_LINES_ONLY"   # armed LAST, mirroring the pre-fix bug
    echo '  i=0'
    echo '  while (( i < 10000 )); do'
    echo '    echo "LOOP $i" >> "$LOG"'
    echo '    sleep 0.05'
    echo '    (( i++ ))'
    echo '  done'
    echo '}'
    echo 'main "$@"'
  } > "$out"
  chmod +x "$out"
}
_build_prologue_harness_old_order "$TMP/h_prologue_old_order.zsh"

PR2_RUNNER_LOCK="$TMP/pr2-runner.lock"
PR2_SLUG_LOCK="$TMP/pr2-slug.lock"
PR2_DESK="$TMP/pr2-desk"; mkdir -p "$PR2_DESK"
PR2_LOGS="$TMP/pr2-logs"; PR2_RUNTIME="$TMP/pr2-runtime"; PR2_OMX="$TMP/pr2-omx"
PR2_LOG="$TMP/pr2.log"; : > "$PR2_LOG"
zsh -f "$TMP/h_prologue_old_order.zsh" "$PR2_LOG" "$PR2_RUNNER_LOCK" "$PR2_SLUG_LOCK" "$PR2_DESK" "$PR2_LOGS" "$PR2_RUNTIME" "$PR2_OMX" &
pr2_pid=$!
sleep 0.3
kill -INT "$pr2_pid" 2>/dev/null
# Under the OLD order, SIGINT arrives with NO trap registered for INT yet (the
# trap-arm lines haven't executed — they're stuck behind the synthetic sleep
# above). Empirically (verified here, not assumed): an untrapped SIGINT
# delivered to a non-interactive zsh script just interrupts the CURRENTLY
# RUNNING command (the synthetic `sleep 1`) without killing the shell
# process itself — execution falls through to the next statement, which
# belatedly registers the trap, then the process settles into the campaign
# loop and simply waits there (no further signal is sent). This is a
# DIFFERENT symptom from mutation (a)'s resume-bug (there, a trap WAS
# registered and its normal RETURN resumed the loop) — here no trap catches
# the signal at all, so cleanup is skipped entirely and the already-acquired
# lock/registry are leaked silently while the process lives on. The
# leak — not the liveness — is the assertion that matters, so this scenario
# always force-kills afterward rather than asserting a particular exit
# timing.
_wait_exit_within "$pr2_pid" 2 >/dev/null
kill -9 "$pr2_pid" 2>/dev/null; wait "$pr2_pid" 2>/dev/null
(( $(_count '^CLEANUP_RAN$' "$PR2_LOG") == 0 )) \
  && ok "mutation control: OLD order — cleanup never ran (no trap was registered for INT yet when the signal arrived)" \
  || no "mutation control: cleanup ran under the OLD order (unexpected — the trap shouldn't have been armed yet)"
[[ -f "$PR2_RUNNER_LOCK" ]] \
  && ok "mutation control: OLD order leaves the runner lock file behind (leaked, matching the reported bug)" \
  || no "mutation control: runner lock was released even under the OLD order — mutation does not reproduce the leak"
pr2_registry_dir="$PR2_DESK/logs/.rlp-desk-leaders-testroothash.d"
pr2_registry_files=("$pr2_registry_dir"/*.json(N))
(( ${#pr2_registry_files} >= 1 )) \
  && ok "mutation control: OLD order leaves the registry entry behind (leaked, matching the reported bug)" \
  || no "mutation control: registry entry was removed even under the OLD order — mutation does not reproduce the leak"

# --- Scenario: duplicate-runner detection (a LIVE foreign PID already holds
# the runner lock) — our process's own exit 1 must NOT touch the foreign
# lock/meta, and must exit cleanly. Uses this TEST SCRIPT's own $$ as the
# "foreign" pid — it is alive for the duration of this test run. ---
PR3_RUNNER_LOCK="$TMP/pr3-runner.lock"
PR3_SLUG_LOCK="$TMP/pr3-slug.lock"
PR3_DESK="$TMP/pr3-desk"; mkdir -p "$PR3_DESK"
PR3_LOGS="$TMP/pr3-logs"; PR3_RUNTIME="$TMP/pr3-runtime"; PR3_OMX="$TMP/pr3-omx"
PR3_LOG="$TMP/pr3.log"; : > "$PR3_LOG"
echo "$$" > "$PR3_RUNNER_LOCK"
printf '{"pid":%s,"slug":"foreign","root":"/tmp/foreign","started_at":"2020-01-01T00:00:00Z"}\n' "$$" > "${PR3_RUNNER_LOCK}.meta"
# Simulate a LIVE incumbent campaign already writing into the shared log dir
# under the SAME slug — the exact scenario the campaign-artifact guard
# protects: this duplicate must not touch it.
mkdir -p "$PR3_LOGS"
print -r -- "INCUMBENT_REPORT_CONTENT" > "$PR3_LOGS/campaign-report.md"
zsh -f "$TMP/h_prologue.zsh" "$PR3_LOG" "$PR3_RUNNER_LOCK" "$PR3_SLUG_LOCK" "$PR3_DESK" "$PR3_LOGS" "$PR3_RUNTIME" "$PR3_OMX"
pr3_ec=$?
(( pr3_ec == 1 )) \
  && ok "prologue duplicate-runner: process exits 1 (busy runner lock, as before)" \
  || no "prologue duplicate-runner: expected exit 1, got $pr3_ec"
[[ -f "$PR3_RUNNER_LOCK" ]] && [[ "$(cat "$PR3_RUNNER_LOCK" 2>/dev/null)" == "$$" ]] \
  && ok "prologue duplicate-runner: the FOREIGN runner lock is untouched (still owned by the foreign pid)" \
  || no "prologue duplicate-runner: the foreign runner lock was modified or removed"
[[ -f "${PR3_RUNNER_LOCK}.meta" ]] \
  && ok "prologue duplicate-runner: the foreign .meta sidecar is untouched" \
  || no "prologue duplicate-runner: the foreign .meta sidecar was removed"
[[ ! -f "$PR3_SLUG_LOCK" ]] \
  && ok "prologue duplicate-runner: our own slug lock was never created (never reached that acquisition)" \
  || no "prologue duplicate-runner: unexpected slug lock file present"
(( $(_count '^CLEANUP_RAN$' "$PR3_LOG") == 1 )) \
  && ok "prologue duplicate-runner: cleanup still ran once (trap now armed before this exit 1)" \
  || no "prologue duplicate-runner: cleanup ran $(_count '^CLEANUP_RAN$' "$PR3_LOG") times"
[[ "$(cat "$PR3_LOGS/campaign-report.md" 2>/dev/null)" == "INCUMBENT_REPORT_CONTENT" ]] \
  && ok "prologue duplicate-runner: the incumbent's campaign-report.md is UNCHANGED (guard skipped generate_campaign_report)" \
  || no "prologue duplicate-runner: incumbent's campaign-report.md was overwritten: $(cat "$PR3_LOGS/campaign-report.md" 2>/dev/null)"
(( $(_count '^GENERATE_CAMPAIGN_REPORT_RAN$' "$PR3_LOG") == 0 )) \
  && ok "prologue duplicate-runner: generate_campaign_report was never called" \
  || no "prologue duplicate-runner: generate_campaign_report ran despite LOCKFILE_ACQUIRED=0"
pr3_rotated=("$PR3_LOGS"/campaign-report-v*.md(N))
(( ${#pr3_rotated} == 0 )) \
  && ok "prologue duplicate-runner: no spurious -vN.md rotation created" \
  || no "prologue duplicate-runner: incumbent's report was rotated to -vN.md (AC9 versioning fired on a duplicate exit)"

# Mutation control: the SAME fixture, but the harness cleanup() has NO
# _skip_campaign_artifacts guard (matches the pre-fix shape) — the incumbent
# report MUST get clobbered/rotated to prove this scenario is a real
# regression test, not vacuous.
PR3M_RUNNER_LOCK="$TMP/pr3m-runner.lock"
PR3M_SLUG_LOCK="$TMP/pr3m-slug.lock"
PR3M_DESK="$TMP/pr3m-desk"; mkdir -p "$PR3M_DESK"
PR3M_LOGS="$TMP/pr3m-logs"; PR3M_RUNTIME="$TMP/pr3m-runtime"; PR3M_OMX="$TMP/pr3m-omx"
PR3M_LOG="$TMP/pr3m.log"; : > "$PR3M_LOG"
echo "$$" > "$PR3M_RUNNER_LOCK"
printf '{"pid":%s,"slug":"foreign","root":"/tmp/foreign","started_at":"2020-01-01T00:00:00Z"}\n' "$$" > "${PR3M_RUNNER_LOCK}.meta"
mkdir -p "$PR3M_LOGS"
print -r -- "INCUMBENT_REPORT_CONTENT" > "$PR3M_LOGS/campaign-report.md"
zsh -f "$TMP/h_prologue_no_guard.zsh" "$PR3M_LOG" "$PR3M_RUNNER_LOCK" "$PR3M_SLUG_LOCK" "$PR3M_DESK" "$PR3M_LOGS" "$PR3M_RUNTIME" "$PR3M_OMX"
pr3m_ec=$?
if [[ "$(cat "$PR3M_LOGS/campaign-report.md" 2>/dev/null)" != "INCUMBENT_REPORT_CONTENT" ]] \
  && ls "$PR3M_LOGS"/campaign-report-v*.md >/dev/null 2>&1; then
  ok "mutation control: WITHOUT the guard, a duplicate-runner exit overwrites the incumbent report AND rotates it to -v1.md (reproduces the reported bug, ec=$pr3m_ec)"
else
  no "mutation control: WITHOUT the guard, the incumbent report was not disturbed as expected — mutation does not reproduce the bug"
fi

# =============================================================================
# POSIX_TRAPS side effect (net-positive, now pinned): it changes not just
# WHETHER the EXIT trap runs to completion, but WHEN it fires. Without
# POSIX_TRAPS, a function-scoped EXIT trap fires the moment the function
# RETURNS (capturing that return's own code) — not at the process's real
# final exit. main() is full of internal `return 1`s, so the pre-fix trap
# fired on the FIRST of those and never saw the authoritative sentinel-based
# `exit 0`/`exit "$_main_rc"` epilogue at the bottom of run_ralph_desk.zsh.
# With POSIX_TRAPS, the trap fires at that real, pinned final exit instead.
# Uses the REAL extracted _emit_launch_record_outcome (the actual consumer
# of `$?` at trap-fire time) against a minimal repro of the exact shape:
# an inner function that `return`s, then an outer epilogue `exit`.
_build_epilogue_harness() {
  local out="$1" with_posix="$2"
  {
    echo '#!/bin/zsh'
    (( with_posix )) && echo 'setopt POSIX_TRAPS'
    echo 'LAUNCH_RECORD_FILE="$1"'
    echo 'typeset -g SIGNAL_RECEIVED=""'
    echo 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
    print -r -- "$EMIT_LAUNCH_BODY"
    echo 'myfunc() {'
    echo "  trap '_emit_launch_record_outcome' EXIT"
    echo '  return 7'
    echo '}'
    echo 'myfunc'
    echo 'myrc=$?'
    echo '# mirrors run_ralph_desk.zsh'"'"'s post-main() sentinel-pinning epilogue'
    echo 'if (( myrc != 0 )); then exit 3; fi'
    echo 'exit 0'
  } > "$out"
  chmod +x "$out"
}
EPI_LR_POSIX="$TMP/epi-posix.lr.json"; _seed_launch_record "$EPI_LR_POSIX"
_build_epilogue_harness "$TMP/h_epilogue_posix.zsh" 1
zsh -f "$TMP/h_epilogue_posix.zsh" "$EPI_LR_POSIX" >/dev/null 2>&1
epi_posix_ec=$?
epi_posix_code=$(jq -r '.exit_code // empty' "$EPI_LR_POSIX" 2>/dev/null)
[[ "$epi_posix_ec" == "3" && "$epi_posix_code" == "3" ]] \
  && ok "POSIX_TRAPS: launch-record exit_code (3) matches the epilogue's pinned final exit, not myfunc's raw return (7)" \
  || no "POSIX_TRAPS: expected process ec=3 and launch-record exit_code=3, got ec=$epi_posix_ec record_exit_code=$epi_posix_code"

EPI_LR_NOPOSIX="$TMP/epi-noposix.lr.json"; _seed_launch_record "$EPI_LR_NOPOSIX"
_build_epilogue_harness "$TMP/h_epilogue_noposix.zsh" 0
zsh -f "$TMP/h_epilogue_noposix.zsh" "$EPI_LR_NOPOSIX" >/dev/null 2>&1
epi_noposix_code=$(jq -r '.exit_code // empty' "$EPI_LR_NOPOSIX" 2>/dev/null)
[[ "$epi_noposix_code" == "7" ]] \
  && ok "mutation control: WITHOUT POSIX_TRAPS, launch-record exit_code (7) wrongly captures myfunc's raw return instead of the epilogue's pinned exit (3) — reproduces the pre-fix inaccuracy" \
  || no "mutation control: WITHOUT POSIX_TRAPS, expected launch-record exit_code=7 (myfunc's raw return), got $epi_noposix_code — this scenario does not discriminate the behavior"

echo ""
echo "=== test_signal_trap.sh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
