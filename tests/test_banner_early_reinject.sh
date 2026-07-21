#!/usr/bin/env zsh
# request-g (v0.22.16) — known non-exhaustion usage banner blocks TUI submission.
#
# A codex/claude pane can echo the trigger prompt into its input box but leave it
# UNSUBMITTED while a non-exhaustion usage banner ("usage limit reset available",
# "increased plan usage", weekly-limit) is on screen. A single Enter resolves it
# in 6-9s. The fix is an early one-shot Enter re-inject at the first poll tick,
# gated by _pane_submit_blocked_by_banner, then the existing 90s submit path.
#
# Unit-tests the new predicate against mocked pane snapshots (incl. env override
# + invalid-ERE fail-safe), pins the two touched neighbours (detect_quota_exhausted
# / _pane_shows_progress) as regressions, and behaviorally drives BOTH real wiring
# sites (awk-extracted at test time so drift fails) with a stubbed tmux that
# records send-keys — asserting exactly ONE re-inject on a banner fixture and ZERO
# on a progress fixture, plus the layer-2 chain-position (banner branch before 90s).
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$RUN" && -f "$LIB" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

# lib helpers are safe to source (lib never runs main).
log(){ :; }; log_error(){ :; }; log_debug(){ :; }
source "$LIB"
# The lib defines its own log/log_debug (log_debug refs $DEBUG, unset under set -u).
# Re-stub to no-ops so the awk-extracted wiring blocks we eval below stay quiet and
# cannot trip set -u on $DEBUG.
log(){ :; }; log_error(){ :; }; log_debug(){ :; }

# --- fixtures -----------------------------------------------------------------
ECHO='› Read and execute the instructions in /tmp/p.md'
# banner + echoed-but-unsubmitted prompt + idle token counter → blocked
BANNER_IDLE="• You have 1 usage limit reset available. Run /usage to use one.
$ECHO
0 in · 0 out"
PLAN_USAGE="• Approaching increased plan usage this week.
$ECHO
0 in · 0 out"
WEEKLY="• You are approaching your weekly limit.
$ECHO
0 in · 0 out"
# banner + echo + PROGRESS (spinner/footer) → NOT blocked (normal case)
BANNER_PROGRESS="• You have 1 usage limit reset available. Run /usage to use one.
$ECHO
✻ Osmosing… (esc to interrupt)"
# banner + echo + nonzero token counter → NOT blocked (already running)
BANNER_RUNNING="• You have 1 usage limit reset available. Run /usage to use one.
$ECHO
12 in · 4 out"
# banner present but prompt already SUBMITTED (post-submit screen, no echo) → not ours
BANNER_NOECHO="• You have 1 usage limit reset available. Run /usage to use one.
✻ Osmosing… (esc to interrupt)"
# echo present, NO banner → the 90s path's job, not the banner predicate's
ECHO_NOBANNER="$ECHO
0 in · 0 out"

# --- unit: _pane_submit_blocked_by_banner -------------------------------------
_pane_submit_blocked_by_banner "$BANNER_IDLE" \
  && ok "banner 'reset available' + echo + idle → blocked (0)" || no "reset-available banner not detected as blocked"
_pane_submit_blocked_by_banner "$PLAN_USAGE" \
  && ok "banner 'increased plan usage' + echo + no progress → blocked (0)" || no "increased-plan-usage not detected"
_pane_submit_blocked_by_banner "$WEEKLY" \
  && ok "banner 'weekly limit' + echo → blocked (0)" || no "weekly-limit banner not detected"
! _pane_submit_blocked_by_banner "$BANNER_PROGRESS" \
  && ok "banner + echo + PROGRESS spinner → NOT blocked (normal-case reinject=0)" || no "progress spinner falsely blocked"
! _pane_submit_blocked_by_banner "$BANNER_RUNNING" \
  && ok "banner + echo + nonzero token counter → NOT blocked (running)" || no "running token counter falsely blocked"
! _pane_submit_blocked_by_banner "$BANNER_NOECHO" \
  && ok "banner present, echo ABSENT (post-submit) → NOT blocked" || no "post-submit screen falsely blocked"
! _pane_submit_blocked_by_banner "$ECHO_NOBANNER" \
  && ok "echo present, NO banner → NOT blocked (90s path owns this)" || no "no-banner echo falsely blocked"
! _pane_submit_blocked_by_banner "" \
  && ok "empty snapshot → NOT blocked" || no "empty falsely blocked"

# custom needle (2nd arg): a different dispatched-instruction literal
! _pane_submit_blocked_by_banner "$BANNER_IDLE" "SOME OTHER INSTRUCTION" \
  && ok "custom needle absent → NOT blocked (needle parameterized)" || no "custom needle mismatch still blocked"
_pane_submit_blocked_by_banner "• You have 1 usage limit reset available.
> Please run the custom job now
0 in · 0 out" "run the custom job" \
  && ok "custom needle present → blocked (needle parameterized)" || no "custom needle match not blocked"

# --- unit: RLP_SUBMIT_BANNER_RE env override ----------------------------------
_saved_re="$RLP_SUBMIT_BANNER_RE"
RLP_SUBMIT_BANNER_RE="my custom banner"
_pane_submit_blocked_by_banner "$ECHO
• my custom banner text here
0 in · 0 out" \
  && ok "env override: custom regex matches custom banner" || no "custom regex did not match custom banner"
! _pane_submit_blocked_by_banner "$BANNER_IDLE" \
  && ok "env override: default banners no longer match once overridden (configurable)" || no "override did not replace default"
RLP_SUBMIT_BANNER_RE="$_saved_re"

# --- unit: invalid ERE fails SAFE (grep exit 2 → return 1, no crash) ----------
RLP_SUBMIT_BANNER_RE="(["
_inv_out=$(_pane_submit_blocked_by_banner "$BANNER_IDLE"; print "rc=$?")
[[ "$_inv_out" == "rc=1" ]] \
  && ok "invalid ERE env → returns 1, no crash (fail-safe)" || no "invalid ERE not fail-safe (got '$_inv_out')"
RLP_SUBMIT_BANNER_RE="$_saved_re"

# --- regression pins: the two touched neighbours are unchanged ----------------
! detect_quota_exhausted "3 usage limit resets available" \
  && ok "regression: detect_quota_exhausted still rejects 'resets available' (non-exhaustion)" || no "quota fast-fail regressed on resets-available"
! detect_quota_exhausted "• You have 1 usage limit reset available. Run /usage to use one." \
  && ok "regression: detect_quota_exhausted rejects the request-g banner (not exhaustion)" || no "quota fast-fail wrongly tripped by request-g banner"
_pane_shows_progress "esc to interrupt" \
  && ok "regression: _pane_shows_progress still detects footer" || no "_pane_shows_progress regressed on footer"
! _pane_shows_progress "0 in · 0 out" \
  && ok "regression: _pane_shows_progress still idle on '0 in'" || no "_pane_shows_progress regressed on idle"
! _pane_shows_progress "3 usage limit resets available" \
  && ok "regression: _pane_shows_progress unchanged on resets banner" || no "_pane_shows_progress regressed on resets banner"

# =============================================================================
# Wiring (behavioral): drive the REAL awk-extracted blocks with a recording tmux.
# =============================================================================
TMPDIR_T=$(mktemp -d)
REC="$TMPDIR_T/sendkeys"
trap 'rm -rf "$TMPDIR_T"' EXIT

# --- layer-3: codex-verifier poll banner block --------------------------------
# Extract the real block (start = the banner if with both guards; end = its fi).
_l3_block=$(awk '/if \(\( _first_progress_ts == 0 \)\) && \(\( _banner_reinject_done == 0 \)\)/,/^        fi$/' "$RUN")
[[ -n "$_l3_block" ]] && ok "layer-3: banner block extracted from run_ralph_desk.zsh" || no "layer-3 banner block not found (drift?)"

_drive_l3() {  # $1 = pane fixture text ; drives the block TWICE (one-shot check)
  local _vq_pane="$1"
  local _first_progress_ts=0 _banner_reinject_done=0 suffix="" VERIFIER_PANE="%99"
  tmux() { [[ "$1" == "send-keys" ]] && print -r -- "$*" >> "$REC"; return 0; }
  eval "$_l3_block"   # tick 1
  eval "$_l3_block"   # tick 2 — guard must suppress a second re-inject
  unfunction tmux
}

: > "$REC"; _drive_l3 "$BANNER_IDLE"
_n=$(grep -c 'send-keys' "$REC")
[[ "$_n" == 1 ]] && ok "layer-3 behavioral: banner fixture → exactly ONE Enter re-inject (one-shot)" || no "layer-3 banner reinject count=$_n (want 1)"

: > "$REC"; _drive_l3 "$BANNER_PROGRESS"
_n=$(grep -c 'send-keys' "$REC")
[[ "$_n" == 0 ]] && ok "layer-3 behavioral: progress fixture → ZERO re-inject" || no "layer-3 progress reinject count=$_n (want 0)"

# --- layer-2: poll_for_signal banner elif -------------------------------------
# Extract the banner elif..just-before-the-90s-elif, drop the trailing 90s line,
# convert the leading `elif` to a standalone `if ... fi` for isolated execution.
_l2_raw=$(awk '/elif \(\( _pfs_banner_reinject_done == 0 \)\)/,/elif \(\( now - poll_start >=/' "$RUN")
_l2_body=$(print -r -- "$_l2_raw" | sed '$d')            # strip trailing 90s-elif line
_l2_if="if ${_l2_body#*elif }"$'\n'"fi"                  # elif → if, close block
[[ -n "$_l2_raw" ]] && print -r -- "$_l2_if" | grep -q '_pane_submit_blocked_by_banner' \
  && ok "layer-2: banner elif extracted from poll_for_signal" || no "layer-2 banner elif not found (drift?)"

_drive_l2() {  # $1 = pane fixture ; capture-pane returns it, send-keys recorded
  local L2_FIX="$1"
  local _pfs_banner_reinject_done=0 pane_id="%99" role="Verifier" ITERATION=1 elapsed=7
  tmux() {
    case "$1" in
      capture-pane) print -r -- "$L2_FIX";;
      send-keys) print -r -- "$*" >> "$REC";;
    esac
    return 0
  }
  eval "$_l2_if"   # tick 1
  eval "$_l2_if"   # tick 2 — guard must suppress a second re-inject
  unfunction tmux
}

: > "$REC"; _drive_l2 "$BANNER_IDLE"
_n=$(grep -c 'send-keys' "$REC")
[[ "$_n" == 1 ]] && ok "layer-2 behavioral: banner fixture → exactly ONE Enter re-inject (one-shot)" || no "layer-2 banner reinject count=$_n (want 1)"

: > "$REC"; _drive_l2 "$BANNER_PROGRESS"
_n=$(grep -c 'send-keys' "$REC")
[[ "$_n" == 0 ]] && ok "layer-2 behavioral: progress fixture → ZERO re-inject" || no "layer-2 progress reinject count=$_n (want 0)"

# --- layer-2 structural: banner branch precedes the 90s submit-window elif ----
_pfs_body=$(awk '/^poll_for_signal\(\)/,/^}/' "$RUN")
_banner_ln=$(print -r -- "$_pfs_body" | grep -n '_pfs_banner_reinject_done == 0' | head -1 | cut -d: -f1)
_90s_ln=$(print -r -- "$_pfs_body" | grep -n 'now - poll_start >= ${SUBMISSION_TIMEOUT' | head -1 | cut -d: -f1)
[[ -n "$_banner_ln" && -n "$_90s_ln" ]] && (( _banner_ln < _90s_ln )) \
  && ok "layer-2 structural: banner elif appears BEFORE the 90s submit-window elif" \
  || no "layer-2 chain position wrong (banner=$_banner_ln 90s=$_90s_ln)"

# --- layer-3 structural: per-dispatch guard is reset on full re-dispatch -------
grep -q '_banner_reinject_done=0        # request-g' "$RUN" \
  && ok "layer-3 structural: guard reset alongside codex_poll_start on re-dispatch" || no "layer-3 guard not reset on re-dispatch"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
