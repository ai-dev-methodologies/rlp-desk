#!/usr/bin/env zsh
# ============================================================================
# US-001 AC7 — stale-true `hooks` probe must degrade gracefully, not outage.
#
# The startup probe (`codex features list` name-presence, run_ralph_desk.zsh)
# can go stale mid-campaign: hours-long campaigns give an operator ample room
# to run `codex update` out-of-band, and an unknown feature name is a HARD
# error (`codex --disable bogus` -> "Error: Unknown feature flag"). Without a
# runtime fallback a stale-true probe is a total outage on EVERY subsequent
# launch, not graceful degradation.
#
# The fallback lives in exactly one chokepoint —
# `_codex_launch_with_hook_fallback` (lib_ralph_desk.zsh) — through which all
# codex launch-assembly sites route. This test simulates a probe that WAS true
# before the binary changed, using a stub `codex` on PATH that fails only when
# `--disable hooks` is present.
#
# Cases (AC7 test contract a-e):
#   (a) stub invoked EXACTLY twice — one failure, one retry, no loop
#   (b) the retry's argv contains NO `--disable hooks`
#   (c) `_CODEX_NO_HOOKS_FLAG` is empty afterwards
#   (d) a SUBSEQUENT launch in the same run emits no `--disable hooks`
#       (proves the clearing is persistent via `typeset -g`, not per-call)
#   (e) an UNRELATED launch failure produces EXACTLY one invocation and the
#       error propagates unchanged (the fallback must never mask it)
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: $LIB not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# --- stub A: fails ONLY when `--disable hooks` is present -------------------
STUB_A="$TMPD/bin-a"
mkdir -p "$STUB_A"
cat > "$STUB_A/codex" <<'STUB'
#!/bin/zsh
print -r -- "$@" >> "$CODEX_STUB_ARGV_LOG"
for a in "$@"; do
  if [[ "$a" == "hooks" ]]; then
    print -u2 "Error: Unknown feature flag: hooks"
    exit 2
  fi
done
print "codex stub ok"
exit 0
STUB
chmod +x "$STUB_A/codex"

# --- stub B: fails for an UNRELATED reason, always --------------------------
STUB_B="$TMPD/bin-b"
mkdir -p "$STUB_B"
cat > "$STUB_B/codex" <<'STUB'
#!/bin/zsh
print -r -- "$@" >> "$CODEX_STUB_ARGV_LOG"
print -u2 "Error: authentication required — run 'codex login'"
exit 7
STUB
chmod +x "$STUB_B/codex"

BASE_CMD='codex -m gpt-5.6-luna --disable plugins --dangerously-bypass-approvals-and-sandbox'

# ---------------------------------------------------------------------------
# Cases (a)-(d): one process, two sequential launches through the chokepoint.
# ---------------------------------------------------------------------------
ARGV_LOG_A="$TMPD/argv-a.log"; : > "$ARGV_LOG_A"
OUT_A="$TMPD/out-a.txt"

CODEX_STUB_ARGV_LOG="$ARGV_LOG_A" PATH="$STUB_A:$PATH" zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }

  # Simulate a probe that was TRUE at init (before the binary changed).
  typeset -g _CODEX_NO_HOOKS_FLAG=" --disable hooks"

  # Test launcher mirrors the launch_{worker,verifier}_codex contract:
  #   $1=pane $2=prompt $3=iter $4=launch_cmd
  # and publishes the failure text the chokepoint inspects, exactly as the
  # real launchers do from their final `tmux capture-pane`.
  _test_launcher() {
    local cmd="$4" out rc=0
    out=$(eval "$cmd" 2>&1) || rc=$?
    typeset -g _CODEX_LAUNCH_FAIL_TEXT="$out"
    return $rc
  }

  rc1=0
  _codex_launch_with_hook_fallback "'"$BASE_CMD"'" _test_launcher pane-1 prompt-1 1 || rc1=$?
  print -r -- "rc1=$rc1" >> "'"$OUT_A"'"

  # (d) a SUBSEQUENT launch in the same run
  rc2=0
  _codex_launch_with_hook_fallback "'"$BASE_CMD"'" _test_launcher pane-1 prompt-2 2 || rc2=$?
  print -r -- "rc2=$rc2" >> "'"$OUT_A"'"
  print -r -- "flag=[${_CODEX_NO_HOOKS_FLAG}]" >> "'"$OUT_A"'"
' >/dev/null 2>&1

_n_a=$(grep -c . "$ARGV_LOG_A" 2>/dev/null || echo 0)

# (a) exactly two invocations for the FIRST launch, plus one for the second =3
#     total; the first launch's share is asserted directly below via the log.
_first_two=$(sed -n '1,2p' "$ARGV_LOG_A" 2>/dev/null)
if [[ "$(sed -n '1p' "$ARGV_LOG_A")" == *"hooks"* && "$(sed -n '2p' "$ARGV_LOG_A")" != *"hooks"* ]]; then
  ok "(a) first launch = 1 failing (flagged) + 1 retry (unflagged) invocation"
else
  no "(a) expected invocation 1 flagged and invocation 2 unflagged; got:
$(cat "$ARGV_LOG_A" 2>/dev/null)"
fi

# (b) retry argv carries no --disable hooks
if [[ -n "$(sed -n '2p' "$ARGV_LOG_A")" && "$(sed -n '2p' "$ARGV_LOG_A")" != *"--disable hooks"* \
      && "$(sed -n '2p' "$ARGV_LOG_A")" != *" hooks"* ]]; then
  ok "(b) retry invocation argv contains no 'hooks' token"
else
  no "(b) retry argv still carries the hooks token: [$(sed -n '2p' "$ARGV_LOG_A")]"
fi

# (a') no loop: total invocations across BOTH launches is exactly 3
if [[ "$_n_a" == "3" ]]; then
  ok "(a') exactly 3 stub invocations total (2 for launch#1, 1 for launch#2) — no retry loop"
else
  no "(a') expected 3 total stub invocations, got $_n_a:
$(cat "$ARGV_LOG_A" 2>/dev/null)"
fi

# (c) flag cleared persistently
if grep -q '^flag=\[\]$' "$OUT_A" 2>/dev/null; then
  ok "(c) _CODEX_NO_HOOKS_FLAG is empty after the fallback trips"
else
  no "(c) _CODEX_NO_HOOKS_FLAG not cleared: [$(grep '^flag=' "$OUT_A" 2>/dev/null)]"
fi

# (d) subsequent launch emits no hooks token AND succeeds
if [[ -n "$(sed -n '3p' "$ARGV_LOG_A")" && "$(sed -n '3p' "$ARGV_LOG_A")" != *"hooks"* ]] \
   && grep -q '^rc2=0$' "$OUT_A" 2>/dev/null; then
  ok "(d) subsequent launch in the same run re-adds nothing and succeeds (rc2=0)"
else
  no "(d) subsequent launch wrong. argv3=[$(sed -n '3p' "$ARGV_LOG_A")] out=[$(cat "$OUT_A" 2>/dev/null)]"
fi

# rc of the first launch must be the RETRY's rc (0), not the failure's
if grep -q '^rc1=0$' "$OUT_A" 2>/dev/null; then
  ok "(a'') first launch returns the successful retry's rc (0)"
else
  no "(a'') expected rc1=0 after a successful retry, got [$(grep '^rc1=' "$OUT_A" 2>/dev/null)]"
fi

# ---------------------------------------------------------------------------
# Case (e): unrelated failure -> exactly ONE invocation, rc propagates.
# ---------------------------------------------------------------------------
ARGV_LOG_B="$TMPD/argv-b.log"; : > "$ARGV_LOG_B"
OUT_B="$TMPD/out-b.txt"

CODEX_STUB_ARGV_LOG="$ARGV_LOG_B" PATH="$STUB_B:$PATH" zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  typeset -g _CODEX_NO_HOOKS_FLAG=" --disable hooks"
  _test_launcher() {
    local cmd="$4" out rc=0
    out=$(eval "$cmd" 2>&1) || rc=$?
    typeset -g _CODEX_LAUNCH_FAIL_TEXT="$out"
    return $rc
  }
  rc=0
  _codex_launch_with_hook_fallback "'"$BASE_CMD"'" _test_launcher pane-1 prompt-1 1 || rc=$?
  print -r -- "rc=$rc" >> "'"$OUT_B"'"
  print -r -- "flag=[${_CODEX_NO_HOOKS_FLAG}]" >> "'"$OUT_B"'"
' >/dev/null 2>&1

_n_b=$(grep -c . "$ARGV_LOG_B" 2>/dev/null || echo 0)
if [[ "$_n_b" == "1" ]]; then
  ok "(e) unrelated failure -> exactly 1 invocation (no masking retry)"
else
  no "(e) expected exactly 1 invocation on an unrelated failure, got $_n_b:
$(cat "$ARGV_LOG_B" 2>/dev/null)"
fi

if grep -q '^rc=7$' "$OUT_B" 2>/dev/null; then
  ok "(e) unrelated failure rc propagates unchanged (7)"
else
  no "(e) expected rc=7 to propagate, got [$(grep '^rc=' "$OUT_B" 2>/dev/null)]"
fi

if grep -q '^flag=\[ --disable hooks\]$' "$OUT_B" 2>/dev/null; then
  ok "(e) unrelated failure does NOT clear _CODEX_NO_HOOKS_FLAG"
else
  no "(e) flag wrongly cleared on an unrelated failure: [$(grep '^flag=' "$OUT_B" 2>/dev/null)]"
fi

# ---------------------------------------------------------------------------
# Decorate-only mode: no launcher argument -> prints the decorated command.
# This is the mode the send-keys / trigger-script assembly sites use (the
# leader does not own those processes, so there is no rc to retry on).
# ---------------------------------------------------------------------------
_dec=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  typeset -g _CODEX_NO_HOOKS_FLAG=" --disable hooks"
  _codex_launch_with_hook_fallback "'"$BASE_CMD"'"
' 2>/dev/null)
if [[ "$_dec" == *"--disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox"* ]]; then
  ok "(f) decorate-only mode inserts --disable hooks immediately after --disable plugins"
else
  no "(f) decorate-only mode wrong: [$_dec]"
fi

_dec_off=$(zsh -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  typeset -g _CODEX_NO_HOOKS_FLAG=""
  _codex_launch_with_hook_fallback "'"$BASE_CMD"'"
' 2>/dev/null)
if [[ "$_dec_off" == "$BASE_CMD" ]]; then
  ok "(f) with the flag unset the command is byte-identical to the baseline"
else
  no "(f) expected byte-identical baseline, got: [$_dec_off]"
fi

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
