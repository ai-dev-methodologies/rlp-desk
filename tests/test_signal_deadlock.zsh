#!/bin/zsh
# C-01 regression: the leader must not DEADLOCK when SIGINT/SIGTERM/SIGHUP lands while it is
# inside a builtin stdio write.
#
# Root cause (reproduced + sampled, .omc/artifacts/c01-signal-deadlock/): zsh runs a trap
# synchronously inside the signal handler (zhandler -> dotrap). When the signal interrupts a
# builtin `echo`/`print` flush the process holds that stdio lock, and every fork the trap path
# then performs with fd redirection ($(...), pipes, `cmd 2>/dev/null`, `cmd > f`) deadlocks in
# the child (redup -> fileno -> flockfile) on the inherited, locked FILE; the leader blocks
# reading the child and never exits (the pane/lock/registry/report cleanup never completes).
# libc strftime/localtime inside the handler can also self-deadlock on the tz rwlock.
#
# This test drives the REAL code: the real lib is sourced at file scope and the real
# `_on_signal` chain (`_emit_launch_record_outcome`, `_emit_final_cost_log` -> `write_cost_log`,
# `cleanup` -> `generate_campaign_report`, `unregister_leader`, `log`, ...) is extracted from
# run_ralph_desk.zsh with the same brace-depth awk as tests/test_signal_trap.sh. A synthetic
# campaign loop that does back-to-back builtin stdio writes (the worst case for the race) runs
# against an isolated `tmux -L` server with two live panes; the harness is signalled at a random
# phase and must exit within a bound; more than MAX_HANGS hangs in the trial set is a FAIL.
#
# Sizing: the pre-fix hang rate of the `stress` mode was measured at 165/300 (55%); with 40
# trials P(<= 2 hangs | pre-fix) < 1e-10. Tolerance: zsh runs a trap through execlist -> fflush(stdout), so a signal
# that lands inside the few stdout flockfile/funlockfile instructions of the interrupted code still self-deadlocks
# (sampled: flockfile -> zhandler -> dotrap -> fflush -> flockfile). That floor was measured at ~1 in 1000-3000 deliveries
# in these worst-case loops (the leader itself spends almost all its time in sleep/tmux calls), so a clean run must not
# fail on 1-2 of 64; 3+ hangs is P < 1e-4 for the fixed code. The trials also assert that the cleanup the
# chain exists for really happened (exit 128+signum, cleanup exactly once, launch-record
# exit_code, metadata INTERRUPTED, final cost row, report, own lock + registry released, panes
# gone), so "no hang" cannot be bought by skipping the work.
#
# Platform note: the flockfile deadlock is a macOS libc behaviour; on Linux this test is a
# plain behavioural check of the same chain (not verified on Linux from this session).
#
# Knobs: C01_TRIALS_STRESS / C01_TRIALS_STRESSLOG / C01_TRIALS_STRESSDEBUG (default 40/12/12),
#        C01_PAR (default 12), C01_BUDGET_S (exit budget per trial, default 10), C01_MAX_HANGS (default 2).
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }
for _tool in jq git; do
  command -v "$_tool" >/dev/null 2>&1 || { print -u2 "FAIL: $_tool not installed"; exit 1; }
done
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]

N_STRESS=${C01_TRIALS_STRESS:-40}
N_STRESSLOG=${C01_TRIALS_STRESSLOG:-12}
N_STRESSDEBUG=${C01_TRIALS_STRESSDEBUG:-12}
N_STRESSREFRESH=${C01_TRIALS_STRESSREFRESH:-24}
PAR=${C01_PAR:-12}
BUDGET_S=${C01_BUDGET_S:-10}
MAX_HANGS=${C01_MAX_HANGS:-2}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

HAVE_TMUX=0; command -v tmux >/dev/null 2>&1 && HAVE_TMUX=1
TMP=$(mktemp -d)
mkdir -p "$TMP/res" "$TMP/pids" "$TMP/labels"
_final_cleanup() {
  local f p l
  for f in "$TMP"/pids/*(N); do
    p=$(<"$f"); [[ -n "$p" ]] || continue
    for c in $(pgrep -P "$p" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
    kill -9 "$p" 2>/dev/null
  done
  for f in "$TMP"/labels/*(N); do
    l=$(<"$f"); [[ -n "$l" ]] && tmux -L "$l" kill-server 2>/dev/null
  done
  [[ -n "${C01_KEEP_TMP:-}" ]] && print -u2 "kept: $TMP" || rm -rf "$TMP"
}
trap '_final_cleanup' EXIT

# --- Extract the REAL implementation (brace-depth aware; same awk as test_signal_trap.sh) ---
_extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn { for (i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}"){depth--; if(depth==0){print; in_fn=0; next}}}
            print }' "$2"
}
TRAP_LINES=$(grep -A3 "^  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT$" "$RUN" | head -4)
[[ -n "$TRAP_LINES" ]] || { print -u2 "FAIL: EXIT/INT/TERM/HUP trap-arm block not found in $RUN"; exit 1; }
REQUIRED_FNS=(_emit_launch_record_outcome _emit_final_cost_log _untracked_names _untracked_complete_warning _on_signal cleanup)
for _f in $REQUIRED_FNS; do
  [[ -n "$(_extract_fn "$_f" "$RUN")" ]] || { print -u2 "FAIL: function $_f not found in $RUN"; exit 1; }
done
# Helpers that exist only once the fix is applied (extracted when present, so the same test runs
# unmodified against the pre-fix tree for the red run).
OPTIONAL_FNS=(_sigsafe_tmux)

# --- Campaign-shaped template tree, copied per trial ---------------------------------------
TPL="$TMP/template"
_make_template() {
  local R="$TPL/root" DESKD="$TPL/root/.claude/ralph-desk" L="$TPL/root/.claude/ralph-desk/logs/c01" i n m
  mkdir -p "$L" "$DESKD/memos" "$DESKD/plans" "$DESKD/runtime"
  git -C "$R" init -q -b main 2>/dev/null || git -C "$R" init -q
  local -a G=(git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
  print a > "$R/a.txt"; "${G[@]}" add -A; "${G[@]}" commit -qm one
  print b >> "$R/a.txt"; print c > "$R/b.txt"; "${G[@]}" add -A; "${G[@]}" commit -qm two
  print dirty >> "$R/a.txt"; print u1 > "$R/untracked1.txt"; print u2 > "$R/untracked2.txt"
  print -r -- $'## Objective\nDo the thing\nmore\nmore' > "$DESKD/plans/prd-c01.md"
  for ((i=1;i<=12;i++)); do
    n=$(printf %03d $i)
    print -r -- '{"us_id":"US-00'$((i%3+1))'"}' > "$L/iter-$n-done-claim.json"
    print x > "$L/iter-$n.worker-prompt.md"
    m=gpt-6-luna; (( i > 6 )) && m=gpt-5.6-terra
    print -r -- '{"iteration":'$i',"estimated_tokens":'$((i*100))',"token_source":"estimated","us_id":"US-00'$((i%3+1))'","worker_model":"'$m'","worker_engine":"codex","worker_effort":"high","verifier_engine":"claude","note":""}' >> "$L/cost-log.jsonl"
  done
  print -r -- '{"ts":"2020-01-01T00:00:00Z","slug":"c01","leader":"zsh","pid":1,"phase":"launched"}' > "$L/launch-record.json"
  print -r -- '{"campaign_status":"RUNNING"}' > "$L/metadata.json"
  # production always has status.json (update_status); generate_campaign_report reads .model_upgraded from it
  print -r -- '{"model_upgraded":1,"iteration":12}' > "$L/status.json"
}
mkdir -p "$TPL/root"; _make_template

# --- Harness: real lib sourced at file scope + real extracted signal-path functions ---------
HAR="$TMP/harness.zsh"
{
  cat <<'HDR'
#!/bin/zsh
# usage: harness.zsh <T dir> <LOOP_MODE stress|stresslog> ; env: C01_LIB C01_LIBDIR C01_DEBUG
set -uo pipefail
setopt POSIX_TRAPS
T="$1"; LOOP_MODE="${2:-stress}"
HDR
  print -r -- 'source "$C01_LIB"'
  print -r -- 'typeset -g SIGNAL_RECEIVED=""'
  print -r -- 'COST_LOG_FINAL_WRITTEN=0'
  print -r -- 'LAUNCH_RECORD_OUTCOME_WRITTEN=0'
  for _f in $OPTIONAL_FNS $REQUIRED_FNS; do _extract_fn "$_f" "$RUN"; print; done
  cat <<'STATE'
# ---- synthetic campaign state (the globals main()/top-level would have set) ----
SLUG="c01"; ROOT="$T/root"; DESK="$ROOT/.claude/ralph-desk"
LOGS_DIR="$DESK/logs/$SLUG"; MEMOS_DIR="$DESK/memos"; RUNTIME_DIR="$DESK/runtime"
METADATA_FILE="$LOGS_DIR/metadata.json"; STATUS_FILE="$LOGS_DIR/status.json"
COST_LOG="$LOGS_DIR/cost-log.jsonl"; DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"; VERDICT_FILE="$LOGS_DIR/verdict.json"
COMPLETE_SENTINEL="$DESK/memos/$SLUG-complete.md"; BLOCKED_SENTINEL="$DESK/memos/$SLUG-blocked.md"
LOCKFILE_PATH="$T/lock.d/leader.lock"; LOCKFILE_ACQUIRED=0
RUNNER_LOCKFILE_PATH="$T/lock.d/runner.lock"
LIB_DIR="$C01_LIBDIR"; ROOT_HASH="c01hash"; SESSION_NAME="c01-sess"; START_TIME=$(date +%s)
ITERATION=12; MAX_ITER=20; CONSECUTIVE_FAILURES=0; VERIFIED_US="US-001,US-002"
BASELINE_COMMIT="$(git -C "$ROOT" rev-parse HEAD~1 2>/dev/null || echo none)"
CAMPAIGN_REPORT_GENERATED=0; SV_REPORT_GENERATED=0; WITH_SELF_VERIFICATION=0
DEBUG="${C01_DEBUG:-0}"; DEBUG_LOG="$LOGS_DIR/debug.log"
WORKER_MODEL=gpt-6-luna; WORKER_ENGINE=codex; VERIFIER_MODEL=sonnet; VERIFIER_ENGINE=claude
CONSENSUS_MODE=off; CONSENSUS_MODEL=x; FINAL_CONSENSUS_MODEL=y
WORKER_CODEX_REASONING=high; WORKER_EFFORT=""
COST_LOG_NOTE=""; LAUNCH_RECORD_FILE="$LOGS_DIR/launch-record.json"
CAMPAIGN_UNTRACKED_SNAPSHOT_OK=1; CAMPAIGN_PREEXISTING_UNTRACKED=""
WORKER_PANE="${C01_WORKER_PANE:-}"; VERIFIER_PANE="${C01_VERIFIER_PANE:-}"; CONSENSUS_PANE=""
CURRENT_US=US-002; VERIFY_MODE=per-us; CLAUDE_VERDICT=""; CODEX_VERDICT=""; CONSENSUS_ROUND=0
[[ -n "${C01_TZ_REFRESH:-}" ]] && _RLP_TZ_REFRESH_S=$C01_TZ_REFRESH   # stressrefresh: every log call re-reads the UTC offset
main() {
STATE
  print -r -- "$TRAP_LINES"
  cat <<'LOOP'
  mkdir -p "$(dirname "$RUNNER_LOCKFILE_PATH")" 2>/dev/null
  acquire_slug_lock "$RUNNER_LOCKFILE_PATH" || { echo "lock-busy"; exit 1; }
  register_leader "tmux"
  LOCKFILE_ACQUIRED=1
  : > "$T/ready"
  local i=0
  case "$LOOP_MODE" in
    stress)    # worst case: back-to-back builtin stdio writes, no sleep
      while (( SECONDS < 45 )); do echo "[main] tick $((++i)) payload payload payload payload"; done ;;
    stresslog) # the leader's own log() in a tight loop
      while (( SECONDS < 45 )); do log "tick $((++i)) payload payload payload payload payload"; done ;;
  esac
}
main "$@"
LOOP
} > "$HAR"
chmod +x "$HAR"

# --- One trial: isolated tmux server (2 panes), start harness, signal at a random phase ----
# Writes $TMP/res/<mode>.<id> as space-separated key=value fields.
_trial() {
  local mode="$1" id="$2" dbg="$3" loop="$4" sig="$5" delay_ms="$6" tzr="${7:-}"
  local T; T=$(mktemp -d "$TMP/trial.XXXXXX") || return 9
  cp -R "$TPL/." "$T/"; mkdir -p "$T/lock.d" "$T/tmp"   # the leader's TMPDIR: anything it leaves there is litter
  local lbl="rlpc01_${$}_${mode}_${id}" sock="" w="" v=""
  if (( HAVE_TMUX )); then
    print -r -- "$lbl" > "$TMP/labels/$mode.$id"
    tmux -L "$lbl" -f /dev/null new-session -d -s c01 -x 100 -y 30 'cat' 2>/dev/null
    tmux -L "$lbl" -f /dev/null split-window -t c01 'cat' 2>/dev/null
    sock=$(tmux -L "$lbl" display -p '#{socket_path}' 2>/dev/null)
    local -a panes; panes=($(tmux -L "$lbl" list-panes -t c01 -F '#{pane_id}' 2>/dev/null))
    w="${panes[1]:-}"; v="${panes[2]:-}"
  fi
  local -A expect=(INT 130 TERM 143 HUP 129)
  # sig and delay_ms are drawn by the PARENT loop (`_run_mode`): background subshells all inherit the parent's RANDOM state and would
  # repeat one signal and one delay for every trial of a run.
  # env -i is not used on purpose: the real leader inherits the operator environment.
  ( [[ -n "$sock" ]] && export TMUX="$sock,1,0" || unset TMUX
    export TMPDIR="$T/tmp" C01_LIB="$LIB" C01_LIBDIR="${LIB:h}" C01_DEBUG="$dbg" C01_TZ_REFRESH="$tzr" C01_WORKER_PANE="$w" C01_VERIFIER_PANE="$v"
    exec zsh -f "$HAR" "$T" "$loop" </dev/null >"$T/out" 2>"$T/err" ) &
  local pid=$!
  print -r -- "$pid" > "$TMP/pids/$mode.$id"
  local waited=0
  until [[ -f "$T/ready" ]] || ! kill -0 $pid 2>/dev/null; do sleep 0.02; (( ++waited > 500 )) && break; done
  sleep $(( delay_ms / 1000.0 ))                  # 50..950 ms after ready: arbitrary loop phase
  kill -$sig $pid 2>/dev/null
  local hang=0 ec="" budget_ticks=$(( BUDGET_S * 10 )) t=0 t0=$EPOCHREALTIME
  while kill -0 $pid 2>/dev/null; do
    sleep 0.1
    (( ++t >= budget_ticks )) && { hang=1; break; }
  done
  local lat=$(( EPOCHREALTIME - t0 ))
  local hangnote=""
  if (( hang )); then
    local -a kids; kids=($(pgrep -P $pid 2>/dev/null))
    hangnote="kids=${#kids}"
    # Diagnostics for every hang (L-14): Linux/BSD ps know ignored/caught, macOS ps only blocked/pending/sigmask.
    { print -r -- "--- HANG $mode.$id sig=$sig pid=$pid kids=${#kids}"
      { ps -o ignored= -p $$ >/dev/null 2>&1 && ps -o pid=,stat=,ignored=,caught= -p $pid; } || ps -o pid=,stat=,blocked=,pending=,sigmask= -p $pid 2>&1
    } > "$TMP/hang-ps.$mode.$id"
    # Classify EVERY hang by its stack (macOS `sample`), not only the first one: the only hang we tolerate is the stdio-lock floor, i.e.
    # a signal that landed inside flockfile/funlockfile of the interrupted fflush and a handler whose own fflush->flockfile blocks
    # (nested zhandler -> dotrap -> fflush -> flockfile, no fork / wait / FILE-table frame anywhere in the call tree).
    local floor=unknown
    # (C01_SAMPLE_CMD overrides the stack sampler; "none" simulates a host without one, to prove that an unclassifiable hang FAILS)
    local _smp="${C01_SAMPLE_CMD:-sample}"
    if command -v "$_smp" >/dev/null 2>&1; then
      "$_smp" $pid 1 2>/dev/null | sed -E '/^Total number in stack/,$d' > "$TMP/hang-sample.$mode.$id"
      if grep -q 'zhandler' "$TMP/hang-sample.$mode.$id" && grep -q 'flockfile' "$TMP/hang-sample.$mode.$id" \
         && ! grep -qE 'fork|__sfp|open_memstream|redup|getoutput|waitforpid|waitjobs|zwaitjob' "$TMP/hang-sample.$mode.$id"; then floor=1; else floor=0; fi
      { print -r -- "--- HANG $mode.$id sig=$sig pid=$pid kids=${#kids} floor=$floor; leader stack (call tree, filtered):"
        grep -E 'flockfile|fflush|zhandler|dotrap|bin_print|fork|__sfp|open_memstream|redup|getoutput|waitfor|waitjobs|execwhile' "$TMP/hang-sample.$mode.$id" | sed -E 's/^[ +!:|]+//' | cut -c1-110 | head -14
        if [[ -n "${kids[1]:-}" ]]; then
          print -r -- "--- child ${kids[1]} stack:"
          sample ${kids[1]} 1 2>/dev/null | grep -E 'redup|fileno|flockfile|getoutput|readoutput|prefork' | sed -E 's/^[ +!:|]+//' | cut -c1-110 | head -8
        fi
      } > "$TMP/hang-evidence.$mode.$id" 2>&1
    fi
    hangnote="$hangnote floor=$floor"
    for c in $kids; do kill -9 $c 2>/dev/null; done
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  else
    wait $pid; ec=$?
  fi
  local L="$T/root/.claude/ralph-desk/logs/c01"
  local cleanups cost_rows lr_exit meta report lock_left reg_left panes_left debug_final tmp_left=0
  local -a _tl; _tl=("$T"/tmp/*(N)); (( ${#_tl} )) && tmp_left=1
  cleanups=$(grep -c '^\[.*\] Cleaning up\.\.\.$' "$T/out" 2>/dev/null); cleanups=${cleanups:-0}
  cost_rows=$(wc -l < "$L/cost-log.jsonl" 2>/dev/null | tr -d ' '); cost_rows=${cost_rows:-0}
  lr_exit=$(jq -r '.exit_code // empty' "$L/launch-record.json" 2>/dev/null)
  meta=$(jq -r '.campaign_status // empty' "$L/metadata.json" 2>/dev/null)
  report=0; grep -q '^## Suggested Next Actions' "$L/campaign-report.md" 2>/dev/null && grep -q 'INTERRUPTED' "$L/campaign-report.md" 2>/dev/null && report=1
  lock_left=0; [[ -e "$T/lock.d/runner.lock" ]] && lock_left=1
  reg_left=0; local f; for f in "$L"/../.rlp-desk-leaders-c01hash.d/*(N); do reg_left=1; done
  panes_left=0; (( HAVE_TMUX )) && panes_left=$(tmux -L "$lbl" list-panes -a 2>/dev/null | wc -l | tr -d ' ')
  debug_final=1; (( dbg )) && { grep -q '\[FLOW\] final status=INTERRUPTED' "$L/debug.log" 2>/dev/null || debug_final=0; }
  print -r -- "hang=$hang sig=$sig ec=${ec:-none} exp=${expect[$sig]} cleanups=$cleanups cost_rows=$cost_rows lr_exit=${lr_exit:-none} meta=${meta:-none} report=$report lock_left=$lock_left reg_left=$reg_left panes_left=${panes_left:-0} debug_final=$debug_final tmp_left=$tmp_left lat=$(printf %.1f $lat) $hangnote" > "$TMP/res/$mode.$id"
  if (( HAVE_TMUX )); then tmux -L "$lbl" kill-server 2>/dev/null; [[ -n "$sock" ]] && rm -f "$sock"; fi
  rm -rf "$T"
}

_run_mode() {   # <mode label> <trials> <debug 0|1> <harness loop stress|stresslog> [<_RLP_TZ_REFRESH_S override>]
  local mode="$1" n="$2" dbg="$3" loop="$4" tzr="${5:-}" i=0 sig dl
  local -a sigs=(INT TERM HUP)
  while (( i < n )); do
    while (( ${#jobstates} >= PAR )); do wait -n 2>/dev/null || sleep 0.05; done
    (( ++i ))
    sig=${sigs[$(( i % 3 + 1 ))]}; dl=$(( RANDOM % 900 + 50 ))   # drawn HERE, in the parent: round-robin signals, random delay
    _trial "$mode" $i "$dbg" "$loop" "$sig" "$dl" "$tzr" &
  done
  wait
}

print "C-01: signal during builtin stdio write must not deadlock the trap path"
print "  trials: stress=$N_STRESS stresslog=$N_STRESSLOG stressdebug=$N_STRESSDEBUG stressrefresh=$N_STRESSREFRESH parallel=$PAR budget=${BUDGET_S}s tmux=$HAVE_TMUX"
start=$EPOCHREALTIME
_run_mode stress      $N_STRESS      0 stress
_run_mode stresslog   $N_STRESSLOG   0 stresslog
_run_mode stressdebug $N_STRESSDEBUG 1 stress      # same loop, DEBUG=1 (cleanup's diagnostics block runs)
# same loop as stresslog but every log line refreshes the UTC offset (an in-process `date +%z` fork + wait): a signal can land during a refresh
_run_mode stressrefresh $N_STRESSREFRESH 0 stresslog 0
elapsed=$(( EPOCHREALTIME - start ))
print "  all trials finished in $(printf %.0f $elapsed)s"

typeset -A EXPECTED_TRIALS=(stress $N_STRESS stresslog $N_STRESSLOG stressdebug $N_STRESSDEBUG stressrefresh $N_STRESSREFRESH)
_total=0; _hang=0; _bad=0; _hang_kids=0; _hang_nonfloor=0; _hang_unknown=0; typeset -A _hang_sig=() _sig_all=()
_field() { local k="$1" line="$2" x; for x in ${=line}; do [[ "$x" == "$k="* ]] && { print -r -- "${x#*=}"; return; }; done }
for mode in stress stresslog stressdebug stressrefresh; do
  m_total=0; m_hang=0; m_bad=0
  for f in "$TMP"/res/$mode.*(N); do
    line=$(<"$f"); (( ++m_total ))
    _sig_all[$(_field sig "$line")]=$(( ${_sig_all[$(_field sig "$line")]:-0} + 1 ))
    if [[ "$(_field hang "$line")" == 1 ]]; then
      (( ++m_hang )); _hang_sig[$(_field sig "$line")]=$(( ${_hang_sig[$(_field sig "$line")]:-0} + 1 ))
      # A hung leader that still has a child process is blocked reading a forked child that deadlocked on the
      # inherited stdio lock: exactly the C-01 bug, never tolerated. Only child-less hangs are the stdio-lock floor.
      (( $(_field kids "$line") > 0 )) && (( ++_hang_kids ))
      [[ "$(_field floor "$line")" == 1 ]] || { (( ++_hang_nonfloor )); [[ "$(_field floor "$line")" == unknown ]] && (( ++_hang_unknown )); }   # N-01: unknown is not tolerated either
      continue
    fi
    good=1
    [[ "$(_field ec "$line")" == "$(_field exp "$line")" ]]     || good=0
    [[ "$(_field cleanups "$line")" == 1 ]]                     || good=0
    [[ "$(_field lr_exit "$line")" == "$(_field exp "$line")" ]] || good=0
    [[ "$(_field meta "$line")" == INTERRUPTED ]]               || good=0
    [[ "$(_field cost_rows "$line")" == 13 ]]                   || good=0
    [[ "$(_field report "$line")" == 1 ]]                       || good=0
    [[ "$(_field lock_left "$line")" == 0 ]]                    || good=0
    [[ "$(_field reg_left "$line")" == 0 ]]                     || good=0
    [[ "$(_field panes_left "$line")" == 0 ]]                   || good=0
    [[ "$(_field debug_final "$line")" == 1 ]]                  || good=0
    [[ "$(_field tmp_left "$line")" == 0 ]]                     || good=0   # no temp file left in the leader's TMPDIR
    (( good )) || { (( ++m_bad )); print -u2 "    behaviour mismatch [$mode]: $line"; }
  done
  print "  $mode: trials=$m_total hung=$m_hang (no exit within ${BUDGET_S}s) wrong-behaviour=$m_bad"
  (( _total += m_total, _hang += m_hang, _bad += m_bad ))
  (( m_total == EXPECTED_TRIALS[$mode] )) || no "$mode: expected ${EXPECTED_TRIALS[$mode]} trial results, got $m_total"
done
for e in "$TMP"/hang-evidence.*(N) "$TMP"/hang-ps.*(N[1,4]); do print -r -- "$(<"$e")" | sed 's/^/    /'; done

print "  signals drawn over all trials: INT=${_sig_all[INT]:-0} TERM=${_sig_all[TERM]:-0} HUP=${_sig_all[HUP]:-0}"
(( _total == 0 || ( ${_sig_all[INT]:-0} > 0 && ${_sig_all[TERM]:-0} > 0 && ${_sig_all[HUP]:-0} > 0 ) )) \
  && ok "the trial set covers all three signals (INT ${_sig_all[INT]:-0}, TERM ${_sig_all[TERM]:-0}, HUP ${_sig_all[HUP]:-0})" \
  || no "the trial set does not cover INT, TERM and HUP (INT ${_sig_all[INT]:-0}, TERM ${_sig_all[TERM]:-0}, HUP ${_sig_all[HUP]:-0})"
print "  hung by signal: ${(kv)_hang_sig} (INT/TERM/HUP counts; $_hang_kids of the $_hang hung leaders still had a child process)"
(( _hang_kids == 0 )) \
  && ok "no hung leader has a child process (no redirected-fork deadlock)" \
  || no "REDIRECTED-FORK DEADLOCK: $_hang_kids hung leader(s) still have a child process blocked on the inherited stdio lock (never tolerated)"
(( _hang_nonfloor == 0 )) \
  && ok "every hung leader (if any) has the stdio-lock floor stack: nested zhandler->fflush->flockfile, no fork/wait/FILE-table frame" \
  || no "NON-FLOOR HANG: $_hang_nonfloor hung leader(s) whose stack is not positively the stdio-lock floor ($_hang_unknown unclassifiable: no stack sampler; see the stacks above)"
(( _hang <= MAX_HANGS )) \
  && ok "no deadlock beyond the stdio-lock floor: $(( _total - _hang ))/$_total signalled leaders exited within ${BUDGET_S}s, $_hang hung (child-less tolerance $MAX_HANGS; INT/TERM/HUP at random phases)" \
  || no "DEADLOCK: $_hang/$_total signalled leaders did not exit within ${BUDGET_S}s, tolerance $MAX_HANGS (signal during builtin stdio write; trap path forked a redirected child)"
(( _bad == 0 )) \
  && ok "every exited trial did the full cleanup: exit 128+signum, cleanup once, launch-record exit_code, metadata INTERRUPTED, final cost row, report, lock+registry released, panes killed" \
  || no "$_bad exited trials show missing/incorrect cleanup behaviour"

# =============================================================================
# Deterministic guard (no race, runs on every platform): trace the REAL signal path (`_on_signal TERM`
# called directly, worst-case state: DEBUG=1, status.json, 3 panes, self-verification on, one scenario per terminal state,
# untracked files) under xtrace and assert it forks NOTHING but the clean-child runner. The failure class is
# "a fork whose child redirects fds", so the checker flags (1) any traced command inside a command
# substitution / pipeline / subshell / background context and (2) any external command other than
# `command zsh ...` (_sigsafe_sh). Builtins (incl. zsh/files zf_rm/zf_mv/zf_mkdir, zsh/stat, zselect) and
# shell functions are in-process and allowed. Limits: `$(<file)` is in-process and untraced (correct);
# xtrace is lost inside a function called with `2>file`, so write_cost_log is traced by an explicit pre-call.
# =============================================================================
zmodload zsh/parameter zsh/zselect 2>/dev/null; zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload -F zsh/files b:zf_rm b:zf_mv b:zf_mkdir 2>/dev/null; zmodload zsh/datetime 2>/dev/null
typeset -A KNOWN
for _b in ${(k)builtins} ${(k)reswords}; do KNOWN[$_b]=1; done
for _b in $(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$LIB" "$RUN" | sed 's/() {//'); do KNOWN[$_b]=1; done

# _check_trace parses EVERY `@@pid:ctx@@ text` segment of a trace line (xtrace prints a command substitution that sits inside an
# assignment as `@@P:@@ var=@@P2:cmdsubst@@ jq ...`). PS4 carries the REAL pid (${sysparams[pid]}), because %_ shows nothing for
# `( ... )`, `cmd &`, process substitution or coproc: a command traced under any pid but the leader's is a fork of the leader.
_check_trace() {   # <trace file> <leader pid>: prints one line per violation
  local line ctx pid cmd fw sw _o _i leader="$2"; local -a w seg
  while IFS= read -r line; do
    [[ "$line" == @@* ]] || continue
    seg=("${(@s:@@:)line}")                       # "" pid:ctx " text" pid:ctx " text" ...
    for (( _i = 2; _i <= ${#seg}; _i += 2 )); do
      pid=${seg[_i]%%:*}; ctx=${seg[_i]#*:}; cmd=${seg[_i+1]# }
      w=(${(z)cmd}); fw=${w[1]:-}; sw=${w[2]:-}
      # The one allowed foreign-pid line is the plain-exec of the clean child: the forked child itself prints `zsh -fc ...` under its own
      # pid just before the exec (it runs no other traced command: the fresh zsh does not inherit xtrace).
      if [[ "$pid" != "$leader" ]]; then
        [[ "$fw" == zsh && "$sw" == -fc ]] || print -r -- "FOREIGN-PID[$pid vs leader $leader,$ctx] $cmd"
        continue
      fi
      if [[ "$ctx" == *(cmdsubst|pipe|subsh|backgnd)* ]]; then print -r -- "FORK-CONTEXT[$ctx] $cmd"; continue; fi
      [[ -z "$fw" || "$fw" == *=* || "$fw" == '(('* || "$fw" == '[[' ]] && continue
      # libc-lock builtins: strftime (tz rwlock) and print/printf -v (open_memstream -> __sfp FILE-table lock) self-deadlock
      # when the signal interrupted the same libc critical section (sampled hang: bin_print -> open_memstream -> __sfp -> zhandler).
      if [[ "$fw" == strftime ]]; then print -r -- "LIBC-LOCK[$ctx] $cmd"; continue; fi
      if [[ "$fw" == (print|printf) ]]; then
        for _o in ${w[2,-1]}; do
          [[ "$_o" == -* && "$_o" != -- ]] || break
          [[ "$_o" =~ '^-[a-zA-Z]*v' ]] && { print -r -- "LIBC-LOCK[$ctx] $cmd"; continue 2; }
        done
      fi
      [[ "$fw" == zsh && "$sw" == -fc ]] && continue   # _sigsafe_sh (xtrace prints `command zsh -fc` without `command`)
      [[ -n "${KNOWN[$fw]:-}" ]] || { print -r -- "EXTERNAL[$ctx] $cmd"; continue; }
      [[ "$fw" == command ]] && print -r -- "EXTERNAL[$ctx] $cmd"
    done
  done < "$1"
  return 0
}

# Discrimination control on REAL traces (no hand-written trace text): one zsh run executes every pattern the checker must flag,
# one control run executes only what the signal path may do.
cat > "$TMP/selftest-bad.zsh" <<'EOS'
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]
print -r -- ${sysparams[pid]} > "$1"
PS4='@@${sysparams[pid]}:%_@@ '
setopt PROMPT_SUBST xtrace   # PS4 only expands ${...} with PROMPT_SUBST
( : in-subshell )
: in-background &
wait
x=$(print in-cmdsubst)
print in-pipe | cat
cat <(print in-procsub) > /dev/null
printf -v REPLY %04d 5
strftime -s x %Y
command rm -f /nonexistent-c01-selftest
date -u > /dev/null
y=$(print inline-in-assignment)
EOS
cat > "$TMP/selftest-good.zsh" <<'EOS'
zmodload zsh/datetime zsh/system   # zsh/system provides $sysparams[pid]
print -r -- ${sysparams[pid]} > "$1"
PS4='@@${sysparams[pid]}:%_@@ '
setopt PROMPT_SUBST xtrace
z=1
print -r -- plain-builtin
[[ -n $z ]] && : fine
zsh -fc 'true'
printf '%s\n' plain-printf
EOS
zsh -f "$TMP/selftest-bad.zsh" "$TMP/selftest-bad.pid" >/dev/null 2>"$TMP/selftest-bad.trace"
zsh -f "$TMP/selftest-good.zsh" "$TMP/selftest-good.pid" >/dev/null 2>"$TMP/selftest-good.trace"
_vbad=$(_check_trace "$TMP/selftest-bad.trace" "$(<$TMP/selftest-bad.pid)"); _vgood=$(_check_trace "$TMP/selftest-good.trace" "$(<$TMP/selftest-good.pid)")
_miss=(); for _pat in 'in-subshell' 'in-background' 'in-cmdsubst' 'in-pipe' 'in-procsub' 'printf -v' 'strftime' 'rm -f /nonexistent-c01' 'date -u' 'inline-in-assignment'; do
  [[ "$_vbad" == *"$_pat"* ]] || _miss+=("$_pat")
done
[[ "$_vbad" == *"FOREIGN-PID"*"in-subshell"* ]] || _miss+=("subshell-by-pid")
(( ${#_miss} == 0 )) && [[ -z "$_vgood" ]] \
  && ok "trace checker, on real traces: flags subshell and background (by pid, which %_ cannot see), cmd-subst, pipe, process substitution, printf -v, strftime, command rm, date and an inline x=\$(...); accepts builtins, assignments, printf and 'zsh -fc'" \
  || no "trace checker self-test failed: undetected=(${_miss[*]}) false-positives=$(print -r -- "$_vgood" | head -3)"

# The trace case also forces the UTC-offset refresh to be DUE (`_RLP_TZ_REFRESH_S=0 _RLP_TZOFF_AT=0`) while `_on_signal TERM` runs, so the guard
# proves the handler's log calls take the cached-offset branch: a lib whose _rlp_local_ts lost its SIGNAL_RECEIVED guard would fork `date` here.
# One traced scenario per terminal state so every branch of cleanup/generate_campaign_report is exercised on its own:
#   interrupted (no sentinel), blocked (BLOCKED only: the Reason:/Category: parse), complete (COMPLETE only: untracked warning).
# All of them: DEBUG=1, a status.json that DISAGREES with the cost log (the both-numbers line), 3 panes, self-verification ON with TWO
# reports whose mtime order is the reverse of their name order (001 newest), untracked files, a PRD with a dash-form heading.
_har=$(<"$HAR")
_har=${_har/'  case "$LOOP_MODE" in'/$'  case "$LOOP_MODE" in\n    trace) zmodload zsh/system; print -r -- ${sysparams[pid]} > "$T/leader.pid"; PS4=\'@@${sysparams[pid]}:%_@@ \'; setopt PROMPT_SUBST xtrace; write_cost_log 12; COST_LOG_FINAL_WRITTEN=1; _RLP_TZ_REFRESH_S=0; _RLP_TZOFF_AT=0; _on_signal TERM ;;'}
_har=${_har/WITH_SELF_VERIFICATION=0/WITH_SELF_VERIFICATION=1}
_har=${_har/CONSENSUS_PANE=\"\"/CONSENSUS_PANE=\"%3\"}
print -r -- "$_har" > "$TMP/harness_trace.zsh"
_trace_scenario() {   # <name> <state interrupted|blocked|complete>
  local name="$1" state="$2" GT="$TMP/guard-$1" want
  mkdir -p "$GT" "$GT/lock.d"; cp -R "$TPL/." "$GT/"
  local GM="$GT/root/.claude/ralph-desk/memos" GL="$GT/root/.claude/ralph-desk/logs/c01"
  [[ "$state" == complete ]] && print -r -- done > "$GM/c01-complete.md"
  [[ "$state" == blocked ]] && print -r -- $'Reason: stuck\nCategory: infra_failure' > "$GM/c01-blocked.md"
  print -r -- '{"model_upgraded":0,"iteration":12}' > "$GL/status.json"   # the cost log escalates (luna -> terra): deliberate disagreement
  print new > "$GT/root/newdeliverable.txt"
  print r1 > "$GL/self-verification-report-001.md"; print r2 > "$GL/self-verification-report-002.md"
  touch -t 202001010000 "$GL/self-verification-report-002.md"
  print -r -- $'## Objective\nx\n\n### US-001: a\n\n### US-002 - b' > "$GT/root/.claude/ralph-desk/plans/prd-c01.md"
  # TMUX points at a socket that does not exist: the traced tmux calls fail fast and can never reach a real server.
  ( export TMUX="$TMP/no-such-tmux-socket,1,0" C01_LIB="$LIB" C01_LIBDIR="${LIB:h}" C01_DEBUG=1 C01_WORKER_PANE="%1" C01_VERIFIER_PANE="%2"
    zsh -f "$TMP/harness_trace.zsh" "$GT" trace </dev/null >"$GT/out" 2>"$TMP/guard-$name.trace"; print $? > "$GT/rc" )
  local rc=$(<"$GT/rc") traced=$(grep -c '^@@' "$TMP/guard-$name.trace") leader; leader=$(<"$GT/leader.pid")
  case $state in complete) want="Final State: COMPLETE";; blocked) want="Final State: BLOCKED";; *) want="Final State: INTERRUPTED";; esac
  (( traced > 200 )) && grep -qF "$want" "$GT/out" && [[ "$rc" == 143 ]] \
    && ok "[$name] trace run reached the end of the real chain (rc=143, $traced traced commands, '$want')" \
    || no "[$name] trace run did not complete the chain (rc=$rc, traced=$traced, wanted '$want')"
  local viol; viol=$(_check_trace "$TMP/guard-$name.trace" "$leader")
  local forks; forks=$(grep -c '^@@[0-9]*:[^@]*@@ zsh -fc ' "$TMP/guard-$name.trace")
  if [[ -z "$viol" ]]; then
    ok "[$name] signal path forks only the clean-child runner: $forks x 'zsh -fc' via _sigsafe_sh, every other traced command ran in the leader pid, 0 command substitutions / pipes / bare externals / libc-lock builtins"
  else
    no "[$name] signal path forks redirected children ($(print -r -- "$viol" | wc -l | tr -d ' ') violations); first ones:"
    print -r -- "$viol" | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /' >&2
  fi
  local rep="$GL/campaign-report.md"
  grep -qE 'Escalation count: [0-9]+ ladder move\(s\) \(status\.json model_upgraded=0 .*disagreement, printing both\)' "$rep" 2>/dev/null \
    && ok "[$name] status.json cross-check: the both-numbers disagreement line (status 0 vs 1 escalation) was produced from the file read by the clean child" \
    || no "[$name] the status.json disagreement line is missing: $(grep -m1 'Escalation count' "$rep" 2>/dev/null)"
  grep -qF "See: $GL/self-verification-report-001.md" "$rep" 2>/dev/null \
    && ok "[$name] the NEWEST self-verification report (by mtime, not by name) is the one linked" \
    || no "[$name] report does not link the newest SV report: $(grep -m1 'self-verification-report' "$rep" 2>/dev/null)"
  # the DEBUG per-US diagnostic: expected_us comes from the clean child via the shared heading constant (both the colon and
  # the dash heading of the PRD must count: 2/2), verified_count from VERIFIED_US in-process.
  grep -q 'per_us_coverage=.* verified=2/2' "$GL/debug.log" 2>/dev/null \
    && ok "[$name] DEBUG per-US coverage diagnostic counted 2/2 (shared heading regexp + in-process counts)" \
    || no "[$name] DEBUG per-US coverage line wrong: $(grep -m1 per_us_coverage "$GL/debug.log" 2>/dev/null)"
  [[ "$state" == blocked ]] && { grep -q 'Blocked reason: stuck' "$rep" 2>/dev/null \
    && ok "[$name] BLOCKED sentinel Reason: parsed into the report" || no "[$name] BLOCKED reason missing from the report"; }
  [[ "$state" == complete ]] && { grep -E 'WARNING: campaign reached COMPLETE with [0-9]+ untracked' "$rep" 2>/dev/null | grep -q 'newdeliverable.txt' \
    && ok "[$name] COMPLETE path produced the specific untracked-deliverables warning naming newdeliverable.txt" \
    || no "[$name] the COMPLETE untracked-deliverables warning is missing: $(grep -m1 -i 'warning' "$rep" 2>/dev/null)"; }
}
# N-06: xtrace output is LOST inside a shell function that is called with STDERR redirected (`f 2>/dev/null`, `if ! f 2>/dev/null`, `f &>x`),
# so the traced guard above cannot see forks in such a function. Statically: the only user-defined function called on a line with a
# stderr redirect on the signal path is write_cost_log (pre-traced explicitly above), and its body contains no command substitution, pipe
# or backtick. (Stdout-only redirects such as `_untracked_names ... >/dev/null` do not blind xtrace and are not flagged.) The detector looks
# at EVERY command position of a line, not only its first word.
_redirected_fn_calls() {   # <function body on stdin>: prints the user functions called on a line that also carries a stderr redirect
  local line seg w
  while IFS= read -r line; do
    [[ "$line" =~ '^[[:space:]]*#' ]] && continue
    [[ "$line" == *2\>* || "$line" == *\&\>* || "$line" == *\>\&* ]] || continue
    line=${line//[;|&{}()!]/$'\n'}; line=${line// then /$'\n'}; line=${line// do /$'\n'}; line=${line// else /$'\n'}; line=${line//if /$'\n'}
    for seg in "${(@f)line}"; do
      w=${${=seg}[1]:-}
      [[ -n "$w" && -n "${KNOWN[$w]:-}" && -z "${builtins[$w]:-}" && ${reswords[(ie)$w]} -gt ${#reswords} && "$w" != _sigsafe_* ]] && print -r -- "$w"
    done
  done
}
# discrimination: the detector must see a redirected call in ANY command position, and must ignore stdout-only redirects and builtins
_rd_bad=$(print -r -- $'if ! _rlp_pad3 1 2>/dev/null; then :; fi\nx=1; _rlp_utc_iso 5 &>/dev/null\n[[ -n 1 ]] && log_error hi 2>/dev/null' | _redirected_fn_calls | sort -u | tr '\n' ' ')
_rd_ok=$(print -r -- $'_rlp_pad3 1 >/dev/null\nzf_rm -f x 2>/dev/null\ndone < f 2>/dev/null\n# log_error hi 2>/dev/null' | _redirected_fn_calls)
[[ "$_rd_bad" == "_rlp_pad3 _rlp_utc_iso log_error " && -z "$_rd_ok" ]] \
  && ok 'N-06 detector self-test: finds redirected calls after if !, after a semicolon and after && ; ignores stdout-only redirects, builtins and comments' \
  || no "N-06 detector self-test failed: found=[$_rd_bad] false-positives=[$_rd_ok]"
_path_fns=(_emit_launch_record_outcome _emit_final_cost_log cleanup _untracked_names _untracked_complete_warning generate_campaign_report write_cost_log unregister_leader log log_debug log_error _on_signal _sigsafe_tmux)
_redir=()
for _fn in $_path_fns; do
  _src="$LIB"; grep -q "^$_fn() {" "$LIB" || _src="$RUN"
  for _w in ${(f)"$(_extract_fn $_fn $_src | _redirected_fn_calls)"}; do _redir+=("$_fn:$_w"); done
done
_redir=(${(u)_redir})
[[ "${(j: :)_redir}" == "_emit_final_cost_log:write_cost_log" ]] \
  && ok "N-06 the only user function called with a STDERR redirect on the signal path is write_cost_log (via _emit_final_cost_log)" \
  || no "N-06 unexpected stderr-redirected function calls on the signal path (xtrace is blind inside them): ${_redir[*]}"
_wcl_forks=$(_extract_fn write_cost_log "$LIB" | grep -vE '^ *#' | grep -E '\$\([^<(]|`|[^|]\| *[a-z]|[^&]& *$' | head -3)
[[ -z "$_wcl_forks" ]] && ok "N-06 write_cost_log has no command substitution, pipe or backtick of its own (nothing hidden by its redirected call)" || no "N-06 write_cost_log forks: $_wcl_forks"

_trace_scenario interrupted interrupted
_trace_scenario blocked blocked
_trace_scenario complete complete

print ""
print "=== test_signal_deadlock.zsh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
