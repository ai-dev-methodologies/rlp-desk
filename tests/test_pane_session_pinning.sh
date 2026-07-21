#!/usr/bin/env zsh
# ② request-j (v0.22.18) — campaign panes pinned to the campaign session.
#
# A `tmux split-window -t ""` (empty target) silently falls back to the ACTIVE
# ambient session — so a leader started detached could spawn worker/verifier panes
# in an unrelated session (observed contamination). Two guards close it:
#   _verify_split_target  — refuse to split on an empty/dead target (BEFORE split)
#   _assert_pane_in_session — kill + fail any pane that escaped $SESSION_NAME (AFTER)
# replace_worker_pane's LEADER_PANE fallback (the actual vector) now verifies its
# target and asserts the session invariant.
#
# Unit-tests both guards, then behaviorally drives replace_worker_pane with a stubbed
# tmux: empty LEADER_PANE fallback ERRORS (blocked sentinel) instead of splitting;
# a mismatched session kills the mis-placed pane and blocks; an in-session pane passes.
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

log(){ :; }; log_error(){ :; }; log_debug(){ :; }

# Brace-balanced function extractor (from test_imp09_paste_no_tmpfile.sh).
_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}

eval "$(_extract_fn _verify_split_target "$RUN")"
eval "$(_extract_fn _assert_pane_in_session "$RUN")"
[[ "$(whence -w _verify_split_target 2>/dev/null)" == *function* ]] \
  && ok "extracted _verify_split_target" || no "could not extract _verify_split_target"
[[ "$(whence -w _assert_pane_in_session 2>/dev/null)" == *function* ]] \
  && ok "extracted _assert_pane_in_session" || no "could not extract _assert_pane_in_session"

# --- unit: _verify_split_target -----------------------------------------------
! _verify_split_target "" "ctx" \
  && ok "verify_split_target: EMPTY target → refuse (1)" || no "empty target not refused"
tmux() { [[ "$1" == "display-message" ]] && { print "%5"; return 0; }; return 0; }
_verify_split_target "%5" "ctx" \
  && ok "verify_split_target: non-empty + live pane → ok (0)" || no "live target wrongly refused"
unfunction tmux
tmux() { return 1; }   # dead pane: display-message fails
! _verify_split_target "%9" "ctx" \
  && ok "verify_split_target: non-empty but DEAD pane → refuse (1)" || no "dead target not refused"
unfunction tmux

# --- unit: _assert_pane_in_session --------------------------------------------
SESSION_NAME="camp"
REC_KILL=""
tmux() { case "$1" in display-message) print -r -- "$STUB_SESS";; kill-pane) REC_KILL="$*";; esac; return 0; }
STUB_SESS="camp"  _assert_pane_in_session "%1" "ctx" \
  && ok "assert_pane_in_session: matching session → ok, no kill" || no "matching session wrongly failed"
[[ -z "$REC_KILL" ]] && ok "assert_pane_in_session: no kill on match" || no "killed a matching pane"
REC_KILL=""
STUB_SESS="other-session" ; ! _assert_pane_in_session "%2" "ctx" \
  && ok "assert_pane_in_session: mismatched session → fail (1)" || no "mismatch not failed"
[[ "$REC_KILL" == *"%2"* ]] && ok "assert_pane_in_session: mis-placed pane KILLED on mismatch" || no "mis-placed pane not killed"
REC_KILL=""
STUB_SESS="" ; ! _assert_pane_in_session "%3" "ctx" \
  && ok "assert_pane_in_session: unresolvable session → fail (1)" || no "empty session not failed"
unfunction tmux

# =============================================================================
# Behavioral: drive replace_worker_pane with a stubbed tmux.
# =============================================================================
TMPDIR_T=$(mktemp -d)
REC="$TMPDIR_T/rec"
trap 'rm -rf "$TMPDIR_T"' EXIT
eval "$(_extract_fn replace_worker_pane "$RUN")"
# request-l: replace_worker_pane now calls these — define them before the behavioral
# scenarios below (scenario C reaches the geometry assert on the success path).
eval "$(_extract_fn _assert_pane_geometry "$RUN")"
eval "$(_extract_fn _ensure_leader_pane_width "$RUN")"

# Globals replace_worker_pane reads.
ROOT="$TMPDIR_T"; SESSION_CONFIG="$TMPDIR_T/nonexistent-session-config.json"; ITERATION=1
SESSION_NAME="camp"

# Scenario A: worker pane dead + LEADER_PANE empty → fallback must ERROR, not split.
_drive_replace_empty_leader() {
  local WORKER_PANE="%dead" VERIFIER_PANE="%deadv" LEADER_PANE=""
  tmux() {
    case "$1" in
      kill-pane) return 0;;
      display-message) return 1;;   # every pane "dead" → forces fallback
      split-window) print -r -- "SPLIT $*" >> "$REC"; print "%NEW"; return 0;;
    esac
    return 0
  }
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|cat=$3" >> "$REC"; }
  replace_worker_pane "%old" "verifier"; local rc=$?
  unfunction tmux write_blocked_sentinel
  print "RC=$rc"
}
: > "$REC"; out=$(_drive_replace_empty_leader)
_split=$(grep -c 'SPLIT' "$REC"); _blk=$(grep -c 'BLOCKED:' "$REC")
{ [[ "$_split" == 0 && "$_blk" == 1 && "$out" == "RC=1" ]] } \
  && ok "behavioral: empty LEADER_PANE fallback → BLOCKED, NO split (was ambient-session vector) ($out)" \
  || no "empty-leader fallback wrong (split=$_split blk=$_blk $out)"
grep -q 'cat=infra_failure' "$REC" && ok "behavioral: empty-leader block is infra_failure" || no "empty-leader block wrong category"

# Scenario B: split succeeds but new pane is in a FOREIGN session → kill + block.
_drive_replace_mismatch() {
  local WORKER_PANE="%1" VERIFIER_PANE="%2" LEADER_PANE="%L"
  tmux() {
    local a="$*"
    case "$1" in
      kill-pane) print -r -- "KILL $*" >> "$REC"; return 0;;
      split-window) print "%NEW"; return 0;;
      display-message)
        if [[ "$a" == *session_name* ]]; then print -r -- "foreign-sess"; return 0
        else return 0; fi ;;   # pane_id aliveness → alive (worker split taken)
    esac
    return 0
  }
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|cat=$3" >> "$REC"; }
  replace_worker_pane "%old" "verifier"; local rc=$?
  unfunction tmux write_blocked_sentinel
  print "RC=$rc"
}
: > "$REC"; out=$(_drive_replace_mismatch)
_kill=$(grep -c 'KILL .*%NEW' "$REC"); _blk=$(grep -c 'BLOCKED:' "$REC")
{ [[ "$_kill" == 1 && "$_blk" == 1 && "$out" == "RC=1" ]] } \
  && ok "behavioral: foreign-session pane → KILLED + BLOCKED ($out)" \
  || no "session-mismatch handling wrong (kill=$_kill blk=$_blk $out)"

# Scenario C: split succeeds, new pane IS in campaign session AND geometry is
# canonical (leader left column; worker %1 above new verifier %NEW in one right
# column) → success. request-l: the stub now answers window_id/pane_left/pane_top so
# the new _assert_pane_geometry check inside replace_worker_pane passes.
_geo_stub_tmux() {   # canonical geometry: %L left=0; %1 left=80 top=0; %NEW left=80 top=25
  case "$1" in
    kill-pane|resize-pane|select-pane|set-option) return 0;;
    split-window) print "%NEW"; return 0;;
    display-message)
      local w prev="" tgt="" fmt=""
      for w in "$@"; do
        [[ "$prev" == "-t" ]] && tgt="$w"
        [[ "$w" == '#{'* ]] && fmt="$w"
        prev="$w"
      done
      case "$fmt" in
        '#{session_name}') print -r -- "camp";;
        '#{window_id}') print -r -- "@1";;
        '#{pane_left}') [[ "$tgt" == "%L" ]] && print 0 || print 80;;
        '#{pane_top}') [[ "$tgt" == "%NEW" ]] && print 25 || print 0;;
        *) return 0;;   # #{pane_id} aliveness probe (and any other) → alive, no output
      esac
      return 0;;
    *) return 0;;
  esac
}
_drive_replace_ok() {
  local WORKER_PANE="%1" VERIFIER_PANE="%2" LEADER_PANE="%L"
  local RLP_LEADER_SPLIT_WIDTH=110
  functions[tmux]=$functions[_geo_stub_tmux]
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|cat=$3" >> "$REC"; }
  local pane; pane=$(replace_worker_pane "%old" "verifier"); local rc=$?
  unfunction tmux write_blocked_sentinel
  print "PANE=$pane RC=$rc"
}
: > "$REC"; out=$(_drive_replace_ok)
_blk=$(grep -c 'BLOCKED:' "$REC")
{ [[ "$_blk" == 0 && "$out" == *"PANE=%NEW"* && "$out" == *"RC=0" ]] } \
  && ok "behavioral: in-session replacement → success, no block ($out)" \
  || no "in-session replacement wrong (blk=$_blk $out)"

# =============================================================================
# request-l §3: _assert_pane_geometry predicate (canonical single right-column stack)
# =============================================================================
eval "$(_extract_fn _assert_pane_geometry "$RUN")"
[[ "$(whence -w _assert_pane_geometry 2>/dev/null)" == *function* ]] \
  && ok "extracted _assert_pane_geometry" || no "could not extract _assert_pane_geometry"

# Parametric tmux stub: reads a global assoc GEO[pane:field] → value.
typeset -gA GEO
_geo_dm_tmux() {
  [[ "$1" == display-message ]] || return 0
  local w prev="" tgt="" fmt="" field=""
  for w in "$@"; do
    [[ "$prev" == "-t" ]] && tgt="$w"
    [[ "$w" == '#{'* ]] && fmt="$w"
    prev="$w"
  done
  case "$fmt" in
    '#{session_name}') field=session_name;;
    '#{window_id}') field=window_id;;
    '#{pane_left}') field=pane_left;;
    '#{pane_top}') field=pane_top;;
    '#{window_zoomed_flag}') field=window_zoomed_flag;;
    *) return 0;;
  esac
  # Brace the var — a bare $tgt:session_name triggers zsh's :s history modifier.
  [[ -n "${GEO[${tgt}:${field}]:-}" ]] && print -r -- "${GEO[${tgt}:${field}]}"
  return 0
}
_set_geo() {  # _set_geo pane sess win left top
  GEO[${1}:session_name]="$2"; GEO[${1}:window_id]="$3"
  GEO[${1}:pane_left]="$4";    GEO[${1}:pane_top]="$5"
}
_run_geo() {  # ctx leader stack... → rc
  functions[tmux]=$functions[_geo_dm_tmux]
  _assert_pane_geometry "$@"; local rc=$?
  unfunction tmux
  return $rc
}
SESSION_NAME="camp"

# PASS: canonical — leader left col; worker above verifier above consensus, one right col.
GEO=()
_set_geo "%L" camp @1 0  0
_set_geo "%W" camp @1 80 0
_set_geo "%V" camp @1 80 25
_set_geo "%C" camp @1 80 50
_run_geo "pass" "%L" "%W" "%V" "%C" \
  && ok "geometry: canonical 4-pane stack → pass" || no "canonical stack wrongly failed"
# PASS: 3-pane (human-operator form, no consensus) — same predicate, no special-casing.
_run_geo "pass3" "%L" "%W" "%V" \
  && ok "geometry: canonical 3-pane (human-operator) stack → pass" || no "canonical 3-pane wrongly failed"

# FAIL 1: extra column — verifier at a DIFFERENT pane_left (two columns, not one).
GEO=(); _set_geo "%L" camp @1 0 0; _set_geo "%W" camp @1 80 0; _set_geo "%V" camp @1 140 25
! _run_geo "extra-col" "%L" "%W" "%V" \
  && ok "geometry: differing pane_left (extra column) → fail" || no "extra column not caught"
# FAIL 2: wrong window — worker in a different window_id than leader.
GEO=(); _set_geo "%L" camp @1 0 0; _set_geo "%W" camp @2 80 0; _set_geo "%V" camp @1 80 25
! _run_geo "wrong-win" "%L" "%W" "%V" \
  && ok "geometry: worker in a different window → fail" || no "wrong window not caught"
# FAIL 3: wrong stack order — verifier ABOVE worker (pane_top not increasing).
GEO=(); _set_geo "%L" camp @1 0 0; _set_geo "%W" camp @1 80 40; _set_geo "%V" camp @1 80 10
! _run_geo "bad-order" "%L" "%W" "%V" \
  && ok "geometry: verifier above worker (bad stack order) → fail" || no "bad stack order not caught"
# FAIL 4: stack pane not right of leader (pane_left <= leader).
GEO=(); _set_geo "%L" camp @1 80 0; _set_geo "%W" camp @1 80 0; _set_geo "%V" camp @1 80 25
! _run_geo "not-right" "%L" "%W" "%V" \
  && ok "geometry: stack pane_left not right of leader → fail" || no "left-of-leader not caught"
# FAIL 5: foreign session on a stack pane.
GEO=(); _set_geo "%L" camp @1 0 0; _set_geo "%W" other @1 80 0; _set_geo "%V" camp @1 80 25
! _run_geo "foreign-sess" "%L" "%W" "%V" \
  && ok "geometry: stack pane in a foreign session → fail" || no "foreign session not caught"

# review MEDIUM: ZOOMED window → SKIP the check (return 0), never false-BLOCK. Even a
# genuinely-drifted stack (verifier in a second column) must pass while zoomed.
GEO=(); _set_geo "%L" camp @1 0 0; _set_geo "%W" camp @1 80 0; _set_geo "%V" camp @1 140 25
GEO[%L:window_zoomed_flag]="1"
_run_geo "zoomed" "%L" "%W" "%V" \
  && ok "geometry: leader window zoomed → skip (return 0), no false block" || no "zoomed window not skipped"

# =============================================================================
# review HIGH: replace_worker_pane double-death fallback. The -h-off-leader fallback
# is taken ONLY when the surviving sibling is DEAD, so the geometry stack must EXCLUDE
# the dead sibling (a lone new_pane is a valid 1-element stack). Including the dead
# sibling would false-BLOCK on its empty session and neutralize request-j recovery.
# =============================================================================
# tmux stub: worker %W is DEAD (aliveness probe fails); leader %L + new %NEW alive.
# $NEWWIN controls the new pane's window (@1 = canonical, @2 = misplaced).
_dd_stub_tmux() {
  case "$1" in
    kill-pane|resize-pane|select-pane|set-option) return 0;;
    split-window) print "%NEW"; return 0;;
    display-message)
      local w prev="" tgt="" fmt=""
      for w in "$@"; do [[ "$prev" == "-t" ]] && tgt="$w"; [[ "$w" == '#{'* ]] && fmt="$w"; prev="$w"; done
      [[ "$tgt" == "%W" ]] && return 1   # worker DEAD → every probe on it fails
      case "$fmt" in
        '#{session_name}') print -r -- "camp";;
        '#{window_id}') [[ "$tgt" == "%NEW" ]] && print -r -- "$NEWWIN" || print -r -- "@1";;
        '#{window_zoomed_flag}') print -r -- "0";;
        '#{pane_width}') print -r -- "200";;
        '#{pane_left}') [[ "$tgt" == "%L" ]] && print -r -- "0" || print -r -- "80";;
        '#{pane_top}') print -r -- "0";;
        *) print -r -- "%0";;   # #{pane_id} aliveness for %L/%NEW → success
      esac
      return 0;;
  esac
  return 0
}
# Recovery case: dead worker, new pane canonical (@1) → success, NO block.
_dd_recover() {
  local WORKER_PANE="%W" VERIFIER_PANE="%2" LEADER_PANE="%L"
  local RLP_LEADER_SPLIT_WIDTH=110 NEWWIN="@1"
  functions[tmux]=$functions[_dd_stub_tmux]
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|cat=$3" >> "$REC"; }
  local pane; pane=$(replace_worker_pane "%oldv" "verifier"); local rc=$?
  unfunction tmux write_blocked_sentinel
  print "PANE=$pane RC=$rc"
}
: > "$REC"; out=$(_dd_recover)
_blk=$(grep -c 'BLOCKED:' "$REC")
{ [[ "$_blk" == 0 && "$out" == *"PANE=%NEW"* && "$out" == *"RC=0" ]] } \
  && ok "HIGH: double-death fallback → recovery proceeds, dead sibling excluded, NO block ($out)" \
  || no "double-death fallback false-blocked (blk=$_blk $out)"

# Misplaced case: dead worker, new pane genuinely in a DIFFERENT window (@2) → block.
# The SENTINEL reason itself (the durable artifact) must name the WINDOW mismatch,
# proving (a) the detailed diagnostic is threaded into the persisted reason, not just
# the ephemeral log, and (b) the live new_pane was checked, not a dead sibling's empty
# session. Record the SENTINEL and the LOG to SEPARATE files so the assert targets the
# sentinel alone (they were previously conflated into one file).
REC_SENT="$TMPDIR_T/rec-sentinel"; REC_LOG="$TMPDIR_T/rec-log"
_dd_misplaced() {
  local WORKER_PANE="%W" VERIFIER_PANE="%2" LEADER_PANE="%L"
  local RLP_LEADER_SPLIT_WIDTH=110 NEWWIN="@2"
  functions[tmux]=$functions[_dd_stub_tmux]
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|cat=$3" >> "$REC_SENT"; }
  log_error() { print -r -- "ERR:$*" >> "$REC_LOG"; }
  local pane; pane=$(replace_worker_pane "%oldv" "verifier"); local rc=$?
  unfunction tmux write_blocked_sentinel log_error
  print "RC=$rc"
}
: > "$REC_SENT"; : > "$REC_LOG"; out=$(_dd_misplaced)
_blk=$(grep -c 'BLOCKED:' "$REC_SENT")
{ [[ "$_blk" == 1 && "$out" == *"RC=1" ]] } \
  && ok "HIGH: double-death fallback, new pane misplaced → BLOCK ($out)" \
  || no "misplaced new pane not blocked (blk=$_blk $out)"
# Assert against the SENTINEL recording ONLY (not the log): the persisted reason must
# name the window mismatch and must NOT reference a dead sibling's empty session.
{ grep -q "window '@2' != leader window '@1'" "$REC_SENT" && ! grep -q "session ''" "$REC_SENT" } \
  && ok "HIGH: PERSISTED sentinel reason names the WINDOW mismatch (threaded diagnostic, live new_pane checked)" \
  || no "sentinel reason not window-accurate ($(cat "$REC_SENT"))"

# =============================================================================
# request-l §2: _ensure_leader_pane_width (read → resize if below → re-read)
# =============================================================================
eval "$(_extract_fn _ensure_leader_pane_width "$RUN")"
[[ "$(whence -w _ensure_leader_pane_width 2>/dev/null)" == *function* ]] \
  && ok "extracted _ensure_leader_pane_width" || no "could not extract _ensure_leader_pane_width"
LEADER_PANE="%L"

# NOTE: `cur=$(tmux ...)` runs the stub in a SUBSHELL, so a call-counter set there
# does not survive. `tmux resize-pane ...` runs in the CURRENT shell, so track state
# via a global RESIZED that resize-pane flips and display-message reads.
# Already wide enough → return 0, NO resize call.
_w_already() {
  RESIZED=0
  tmux() { case "$1" in display-message) print 120;; resize-pane) RESIZED=1;; esac; return 0; }
  _ensure_leader_pane_width 110 "ctx"; local rc=$?; local res=$RESIZED
  unfunction tmux
  print "rc=$rc resize=$res"
}
[[ "$(_w_already)" == "rc=0 resize=0" ]] \
  && ok "width: already >= target → pass, no resize" || no "wide pane wrongly resized/failed"

# Below target, resize SUCCEEDS (post-resize read returns wide) → return 0, resize invoked.
_w_resize_ok() {
  RESIZED=0
  tmux() {
    case "$1" in
      display-message) (( RESIZED )) && print 110 || print 1;;
      resize-pane) RESIZED=1;;
    esac; return 0
  }
  _ensure_leader_pane_width 110 "ctx"; local rc=$?; local res=$RESIZED
  unfunction tmux
  print "rc=$rc resize=$res"
}
[[ "$(_w_resize_ok)" == "rc=0 resize=1" ]] \
  && ok "width: below target → resize invoked, then pass" || no "below-min resize path wrong"

# Below target, resize FAILS (still narrow on re-read) → return 1.
_w_resize_fail() {
  tmux() { case "$1" in display-message) print 1;; resize-pane) return 0;; esac; return 0; }
  _ensure_leader_pane_width 110 "ctx"; local rc=$?
  unfunction tmux
  print "rc=$rc"
}
[[ "$(_w_resize_fail)" == "rc=1" ]] \
  && ok "width: still-narrow after resize → fail (1)" || no "persistent-narrow not failed"

# Unreadable width (non-integer) → return 1 (never splits on a bad read).
_w_unreadable() {
  tmux() { case "$1" in display-message) print "abc";; esac; return 0; }
  _ensure_leader_pane_width 110 "ctx"; local rc=$?
  unfunction tmux
  print "rc=$rc"
}
[[ "$(_w_unreadable)" == "rc=1" ]] \
  && ok "width: unreadable pane_width → fail (1)" || no "unreadable width not failed"

# --- structural: RLP_SHELL_READY_TIMEOUT_S retrofitted through D-19 -------------
grep -qE '_validate_int_knob RLP_SHELL_READY_TIMEOUT_S ' "$RUN" \
  && ok "structural: RLP_SHELL_READY_TIMEOUT_S validated via D-19 (_validate_int_knob)" \
  || no "RLP_SHELL_READY_TIMEOUT_S not run through D-19 validation"
grep -qE '_validate_int_knob RLP_LEADER_MIN_WIDTH |_validate_int_knob RLP_LEADER_SPLIT_WIDTH ' "$RUN" \
  && ok "structural: leader width knobs validated via D-19" || no "leader width knobs not D-19 validated"

# --- structural: create_session both branches guard + assert -------------------
_cs_body=$(_extract_fn create_session "$RUN")
_n_verify=$(print -r -- "$_cs_body" | grep -c '_verify_split_target')
_n_assert=$(print -r -- "$_cs_body" | grep -c '_assert_pane_in_session')
_n_width=$(print -r -- "$_cs_body" | grep -c '_ensure_leader_pane_width')
_n_geo=$(print -r -- "$_cs_body" | grep -c '_assert_pane_geometry')
{ (( _n_verify >= 4 )) && (( _n_assert >= 4 )) } \
  && ok "structural: create_session guards all 4 splits + asserts all 4 panes (verify=$_n_verify assert=$_n_assert)" \
  || no "create_session guard/assert coverage incomplete (verify=$_n_verify assert=$_n_assert)"
{ (( _n_width >= 2 )) && (( _n_geo >= 2 )) } \
  && ok "structural: create_session enforces split-width + geometry in both branches (width=$_n_width geo=$_n_geo)" \
  || no "create_session width/geometry coverage incomplete (width=$_n_width geo=$_n_geo)"

# =============================================================================
# request-j review MEDIUM: every replace_worker_pane CALLER must check the return
# and NOT re-read a stale pane id when replace hard-fails (it writes the BLOCKED
# sentinel but does NOT update SESSION_CONFIG.panes, so a bare `.panes.*` re-read
# would drive the old/killed pane for the rest of the iteration).
# =============================================================================
# structural: every callsite is guarded by `if ! replace_worker_pane` (0 bare calls).
_total_calls=$(grep -cE '[[:space:]]replace_worker_pane "' "$RUN")
_guarded_calls=$(grep -cE 'if ! replace_worker_pane "' "$RUN")
{ (( _total_calls == 6 )) && (( _guarded_calls == 6 )) } \
  && ok "structural: all 6 replace_worker_pane callers are return-checked (guarded=$_guarded_calls/$_total_calls)" \
  || no "unguarded replace_worker_pane caller(s) (guarded=$_guarded_calls total=$_total_calls)"
# every caller's guard body reaches a `return` before falling through to a stale read.
_unret=$(awk '/if ! replace_worker_pane "/{g=1; r=0; next} g&&/return /{r=1} g&&/^[[:space:]]*fi[[:space:]]*$/{if(!r)bad++; g=0} END{print bad+0}' "$RUN")
[[ "$_unret" == 0 ]] \
  && ok "structural: every guarded block returns before the stale pane re-read" || no "$_unret guarded block(s) lack a return"

# behavioral: drive the FIRST real guarded caller block (run_single_verifier
# cleanup) with a hard-failing replace_worker_pane; the jq `.panes.verifier`
# re-read must NOT run (no stale pane adopted) and the block must return early.
_caller_blk=$(awk '/if ! replace_worker_pane "\$VERIFIER_PANE" "verifier"; then/{c++} c==1{print} c==1&&/VERIFIER_PANE=\$\(jq -r/{exit}' "$RUN")
[[ -n "$_caller_blk" ]] && print -r -- "$_caller_blk" | grep -q 'jq -r' \
  && ok "extracted a real guarded caller block (guard + jq re-read)" || no "could not extract guarded caller block (drift?)"

# VERIFIER_PANE stays %OLD iff the jq `.panes.verifier` re-read never ran (the jq
# runs in a command-substitution subshell, so an in-subshell flag would not survive
# — the pane VALUE is the load-bearing signal).
_drive_caller() {  # $1 = replace rc to simulate
  local VERIFIER_PANE="%OLD" SESSION_CONFIG="/nonexistent"
  local _rc_sim="$1"
  replace_worker_pane() { return "$_rc_sim"; }
  jq() { print -r -- "%STALE_FROM_CONFIG"; }
  _run() { eval "$_caller_blk"; }   # nested so `return` unwinds only this
  _run; local rc=$?
  unfunction replace_worker_pane jq
  print "RC=$rc VP=$VERIFIER_PANE"
}
_out_fail=$(_drive_caller 1)
{ [[ "$_out_fail" == *"VP=%OLD"* && "$_out_fail" != *"RC=0"* ]] } \
  && ok "behavioral: replace hard-fail → early return, NO stale .panes re-read ($_out_fail)" \
  || no "caller proceeded with a stale pane on replace failure ($_out_fail)"
_out_ok=$(_drive_caller 0)
[[ "$_out_ok" == *"VP=%STALE_FROM_CONFIG"* ]] \
  && ok "behavioral: replace success → proceeds and re-reads the new pane ($_out_ok)" \
  || no "caller did not proceed on replace success ($_out_ok)"

# =============================================================================
# request-k P2: LEADER_PANE must come from $TMUX_PANE (this shell's OWN pane),
# NOT `display-message -p '#{pane_id}'` (which follows the attached client's ACTIVE
# pane — with multiple clients that can be the operator's pane in a foreign session,
# scattering worker/verifier splits there).
# =============================================================================
eval "$(_extract_fn _leader_own_pane "$RUN")"
[[ "$(whence -w _leader_own_pane 2>/dev/null)" == *function* ]] \
  && ok "extracted _leader_own_pane" || no "could not extract _leader_own_pane"
# display-message would report the ACTIVE client's pane; TMUX_PANE is the leader's own.
tmux() { case "$1" in display-message) print -r -- "%ACTIVE_CLIENT_PANE";; esac; return 0; }
_lp_own=$( TMUX_PANE="%2175" _leader_own_pane )
[[ "$_lp_own" == "%2175" ]] \
  && ok "LEADER pane: prefers \$TMUX_PANE (%2175), ignores active-client pane" || no "did not prefer TMUX_PANE (got $_lp_own)"
_lp_fallback=$( TMUX_PANE="" _leader_own_pane )
[[ "$_lp_fallback" == "%ACTIVE_CLIENT_PANE" ]] \
  && ok "LEADER pane: falls back to display-message when TMUX_PANE unset" || no "fallback wrong (got $_lp_fallback)"
unfunction tmux
# structural: create_session inside-tmux derives BOTH pane and session from the leader
# pane (not the active client) — the fix that lets ② session-invariant catch scatter.
_cs2=$(_extract_fn create_session "$RUN")
print -r -- "$_cs2" | grep -q 'LEADER_PANE=$(_leader_own_pane)' \
  && ok "structural: create_session uses _leader_own_pane for LEADER_PANE" || no "create_session still uses active-client pane"
print -r -- "$_cs2" | grep -q "display-message -p -t \"\$LEADER_PANE\" '#{session_name}'" \
  && ok "structural: SESSION_NAME derived FROM the leader pane (not active client)" || no "SESSION_NAME still from active client"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
