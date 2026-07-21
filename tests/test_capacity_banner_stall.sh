#!/usr/bin/env zsh
# ① request-j (v0.22.18) — codex "Selected model is at capacity" MID-EXECUTION stall.
#
# A codex worker/verifier pane can freeze on a capacity banner AFTER the prompt was
# submitted (no progress spinner), waiting to ITER_TIMEOUT. The fix injects a resume
# line (RLP_CAPACITY_RESUME_TEXT) when a capacity banner is visible AND no progress
# is shown, bounded by a cooldown (RLP_CAPACITY_REINJECT_COOLDOWN_S) between
# injections and a strike cap (RLP_CAPACITY_MAX_STRIKES) → BLOCKED. Quota exhaustion
# WINS (a usage wall is terminal, never resume-injected).
#
# Unit-tests _pane_capacity_stalled (banner+no-progress, progress present, no-banner,
# env override, invalid-ERE fail-safe), pins detect_quota_exhausted / _pane_shows_progress
# as regressions, and behaviorally drives the REAL awk-extracted poll block with a
# recording tmux: ONE injection on a stall, ZERO on progress, ZERO on quota (quota
# wins), cooldown respected, 3-strike → BLOCKED sentinel, env-override resume text.
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

# lib helpers are safe to source (lib never runs main). Stub logging first.
log(){ :; }; log_error(){ :; }; log_debug(){ :; }
source "$LIB"
log(){ :; }; log_error(){ :; }; log_debug(){ :; }

# --- fixtures -----------------------------------------------------------------
# capacity banner + idle token counter (no progress) → stalled
CAP_STALL="⚠ Selected model is at capacity. Please try a different model.
0 in · 0 out"
# capacity banner + PROGRESS spinner → NOT stalled (never inject over a live run)
CAP_PROGRESS="⚠ Selected model is at capacity. Please try a different model.
✻ Osmosing… (esc to interrupt)"
# capacity banner + nonzero token counter → NOT stalled (already running)
CAP_RUNNING="⚠ Selected model is at capacity. Please try a different model.
42 in · 8 out"
# no banner, idle → NOT stalled
NO_BANNER="Reading files and planning the change
0 in · 0 out"
# quota exhaustion text (terminal) — capacity resume must NOT fire on this
QUOTA_TEXT="You've hit your usage limit. Try again at 3pm or purchase more credits."

# --- unit: _pane_capacity_stalled ---------------------------------------------
_pane_capacity_stalled "$CAP_STALL" \
  && ok "capacity banner + no progress → stalled (0)" || no "capacity stall not detected"
! _pane_capacity_stalled "$CAP_PROGRESS" \
  && ok "capacity banner + PROGRESS spinner → NOT stalled (no false inject)" || no "progress spinner falsely stalled"
! _pane_capacity_stalled "$CAP_RUNNING" \
  && ok "capacity banner + nonzero token counter → NOT stalled (running)" || no "running counter falsely stalled"
! _pane_capacity_stalled "$NO_BANNER" \
  && ok "no capacity banner → NOT stalled" || no "no-banner text falsely stalled"
! _pane_capacity_stalled "" \
  && ok "empty snapshot → NOT stalled" || no "empty falsely stalled"

# case-insensitive match
! _pane_capacity_stalled "everything is fine here
0 in · 0 out" \
  && ok "ordinary idle output → NOT stalled (conservative pattern)" || no "ordinary output falsely stalled"

# --- unit: RLP_CAPACITY_BANNER_RE env override --------------------------------
_saved_re="$RLP_CAPACITY_BANNER_RE"
RLP_CAPACITY_BANNER_RE="my custom capacity wall"
_pane_capacity_stalled "• my custom capacity wall is up
0 in · 0 out" \
  && ok "env override: custom regex matches custom capacity banner" || no "custom capacity regex did not match"
! _pane_capacity_stalled "$CAP_STALL" \
  && ok "env override: default banner no longer matches once overridden (configurable)" || no "override did not replace default"
RLP_CAPACITY_BANNER_RE="$_saved_re"

# --- unit: invalid ERE fails SAFE (grep exit 2 → return 1, no crash) ----------
RLP_CAPACITY_BANNER_RE="(["
_inv_out=$(_pane_capacity_stalled "$CAP_STALL"; print "rc=$?")
[[ "$_inv_out" == "rc=1" ]] \
  && ok "invalid ERE env → returns 1, no crash (fail-safe)" || no "invalid ERE not fail-safe (got '$_inv_out')"
RLP_CAPACITY_BANNER_RE="$_saved_re"

# --- regression pins ----------------------------------------------------------
detect_quota_exhausted "$QUOTA_TEXT" \
  && ok "regression: detect_quota_exhausted still detects a true usage wall" || no "quota detection regressed"
! detect_quota_exhausted "$CAP_STALL" \
  && ok "regression: detect_quota_exhausted does NOT trip on a capacity banner (distinct)" || no "quota wrongly tripped by capacity banner"
_pane_shows_progress "esc to interrupt" \
  && ok "regression: _pane_shows_progress still detects footer" || no "_pane_shows_progress regressed"

# =============================================================================
# Wiring (behavioral): drive the REAL awk-extracted capacity poll block.
# =============================================================================
TMPDIR_T=$(mktemp -d)
REC="$TMPDIR_T/rec"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Extract the capacity block: from the opening guard to its closing 4-space `fi`.
_cap_block=$(awk '/if \(\( \$\+functions\[_pane_capacity_stalled\] \)\)/,/^    fi$/' "$RUN")
[[ -n "$_cap_block" ]] && print -r -- "$_cap_block" | grep -q '_pane_capacity_stalled' \
  && ok "wiring: capacity block extracted from poll_for_signal" || no "capacity block not found (drift?)"

# Inner wrapper so a `return 2` inside the block does not unwind the driver
# (zsh dynamic scope: it still mutates the driver's locals).
_cap_inner() { eval "$_cap_block"; }

_drive_cap() {  # $1 fixture  $2 strikes-in  $3 last-ts  $4 cooldown  [$5 max]
  local pane_output_for_retry="$1"
  local capacity_strikes="$2" _last_capacity_reinject_ts="$3"
  local RLP_CAPACITY_REINJECT_COOLDOWN_S="$4"
  local RLP_CAPACITY_MAX_STRIKES="${5:-3}"
  local pane_id="%99" role="Worker" ITERATION=1
  tmux() { case "$1" in send-keys) print -r -- "send-keys $*" >> "$REC";; capture-pane) print -r -- "$pane_output_for_retry";; esac; return 0; }
  paste_to_pane() { print -r -- "PASTE:$2" >> "$REC"; }
  write_blocked_sentinel() { print -r -- "BLOCKED:$1|us=$2|cat=$3" >> "$REC"; }
  _cap_inner; local rc=$?
  unfunction tmux paste_to_pane write_blocked_sentinel
  print -r -- "STRIKES=$capacity_strikes RC=$rc"
}

# 1) banner + no progress, cooldown satisfied (ts=0, cooldown=0) → ONE injection.
: > "$REC"; out=$(_drive_cap "$CAP_STALL" 0 0 0)
_inj=$(grep -c 'send-keys' "$REC"); _paste=$(grep -c 'PASTE:' "$REC")
{ [[ "$_inj" == 1 && "$_paste" == 1 && "$out" == "STRIKES=1 RC="* ]] } \
  && ok "behavioral: stall → exactly ONE resume injection, strikes→1 ($out)" || no "stall injection wrong (inj=$_inj paste=$_paste $out)"

# 2) progress present → ZERO injection.
: > "$REC"; out=$(_drive_cap "$CAP_PROGRESS" 0 0 0)
_inj=$(grep -c 'send-keys' "$REC")
[[ "$_inj" == 0 ]] && ok "behavioral: progress present → ZERO injection ($out)" || no "progress falsely injected (inj=$_inj)"

# 3) quota text present → ZERO injection (quota WINS). Fixture = capacity banner
#    AND quota text on the same screen.
: > "$REC"; out=$(_drive_cap "$CAP_STALL
$QUOTA_TEXT" 0 0 0)
_inj=$(grep -c 'send-keys' "$REC")
[[ "$_inj" == 0 ]] && ok "behavioral: quota text present → ZERO injection (quota wins)" || no "capacity injected over a quota wall (inj=$_inj)"

# 4) cooldown respected: strikes=1, last-ts=now, cooldown=120 → within cooldown, no inject.
_now=$(date +%s)
: > "$REC"; out=$(_drive_cap "$CAP_STALL" 1 "$_now" 120)
_inj=$(grep -c 'send-keys' "$REC")
{ [[ "$_inj" == 0 && "$out" == "STRIKES=1 RC="* ]] } \
  && ok "behavioral: within cooldown → no re-injection, strikes unchanged ($out)" || no "cooldown not respected (inj=$_inj $out)"

# 5) 3-strike cap reached → BLOCKED sentinel, RC=2, no further injection.
: > "$REC"; out=$(_drive_cap "$CAP_STALL" 3 0 0 3)
_blk=$(grep -c 'BLOCKED:' "$REC"); _inj=$(grep -c 'send-keys' "$REC")
_cat=$(grep -o 'cat=[a-z_]*' "$REC" | head -1)
{ [[ "$_blk" == 1 && "$_inj" == 0 && "$out" == *"RC=2" && "$_cat" == "cat=infra_failure" ]] } \
  && ok "behavioral: strikes>=max → BLOCKED (infra_failure), RC=2, no inject ($out $_cat)" || no "3-strike block wrong (blk=$_blk inj=$_inj cat=$_cat $out)"
grep -qi 'capacity' "$REC" \
  && ok "behavioral: blocked reason mentions model capacity" || no "blocked reason missing 'capacity'"

# 6) env-override resume text is what gets pasted.
: > "$REC"
out=$(RLP_CAPACITY_RESUME_TEXT="RESUME_NOW_PLS" _drive_cap "$CAP_STALL" 0 0 0)
grep -qF 'PASTE:RESUME_NOW_PLS' "$REC" \
  && ok "behavioral: env-override RLP_CAPACITY_RESUME_TEXT is the injected text" || no "custom resume text not used ($(grep PASTE: "$REC"))"

# --- structural: capacity block sits AFTER the API-transient block ------------
_pfs_body=$(awk '/^poll_for_signal\(\)/,/^}/' "$RUN")
_api_ln=$(print -r -- "$_pfs_body" | grep -n 'API unavailable after' | head -1 | cut -d: -f1)
_cap_ln=$(print -r -- "$_pfs_body" | grep -n '_pane_capacity_stalled' | head -1 | cut -d: -f1)
{ [[ -n "$_api_ln" && -n "$_cap_ln" ]] && (( _api_ln < _cap_ln )) } \
  && ok "structural: capacity block appears AFTER the API-transient block (single-capture reuse)" \
  || no "capacity block position wrong (api=$_api_ln cap=$_cap_ln)"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
