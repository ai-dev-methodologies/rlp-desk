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

# Scenario C: split succeeds and new pane IS in campaign session → success.
_drive_replace_ok() {
  local WORKER_PANE="%1" VERIFIER_PANE="%2" LEADER_PANE="%L"
  tmux() {
    local a="$*"
    case "$1" in
      kill-pane) return 0;;
      split-window) print "%NEW"; return 0;;
      display-message)
        if [[ "$a" == *session_name* ]]; then print -r -- "camp"; return 0
        else return 0; fi ;;
      *) return 0;;
    esac
    return 0
  }
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

# --- structural: create_session both branches guard + assert -------------------
_cs_body=$(_extract_fn create_session "$RUN")
_n_verify=$(print -r -- "$_cs_body" | grep -c '_verify_split_target')
_n_assert=$(print -r -- "$_cs_body" | grep -c '_assert_pane_in_session')
{ (( _n_verify >= 4 )) && (( _n_assert >= 4 )) } \
  && ok "structural: create_session guards all 4 splits + asserts all 4 panes (verify=$_n_verify assert=$_n_assert)" \
  || no "create_session guard/assert coverage incomplete (verify=$_n_verify assert=$_n_assert)"

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

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
