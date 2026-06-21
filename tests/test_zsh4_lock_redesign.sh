#!/bin/zsh
# ZSH-4 redesign (v0.17.1): race-safe per-slug lock acquisition.
# Verifies acquire_slug_lock (lib_ralph_desk.zsh) against the four race classes
# codex flagged in the earlier patch attempts:
#   1. fresh acquire
#   2. live holder  -> busy (no double-acquire)
#   3. stale lock (dead owner) -> recover
#   4. leaked recovery mutex owned by a DEAD pid -> reaped, then acquire (no leak)
#   5. recovery mutex owned by a LIVE pid -> busy (never clobber a live recoverer)
#   6. EMPTY-owner mutex a live recoverer fills mid-settle -> busy, preserved
#      (the mkdir->owner-write TOCTOU: an empty owner must NOT be reaped as stale)
#   7. EMPTY-owner mutex that stays empty (creator died in the gap) -> reaped
set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
source "$ROOT/src/scripts/lib_ralph_desk.zsh" 2>/dev/null

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); print -P "  %F{green}PASS%f: $1"; }
no()   { FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f: $1"; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
LF="$TMPD/svc.lock"

print "▶ ZSH-4 acquire_slug_lock race-safety"

# 1. fresh acquire
if acquire_slug_lock "$LF" && [[ "$(cat "$LF")" == "$$" ]]; then ok "1 fresh acquire writes our PID"; else no "1 fresh acquire"; fi

# 2. live holder -> busy
sleep 30 & SL=$!
echo "$SL" > "$LF"
acquire_slug_lock "$LF"; rc=$?
[[ $rc -eq 1 && "$(cat "$LF")" == "$SL" ]] && ok "2 live holder -> busy, lock untouched" || no "2 live holder (rc=$rc)"
kill "$SL" 2>/dev/null

# 3. stale lock (dead owner) -> recover
echo 999999 > "$LF"   # unused high PID
acquire_slug_lock "$LF"; rc=$?
[[ $rc -eq 0 && "$(cat "$LF")" == "$$" ]] && ok "3 stale (dead) lock recovered" || no "3 stale recover (rc=$rc)"

# 4. leaked recovery mutex owned by DEAD pid -> reaped + acquire, no leak
echo 999998 > "$LF"; mkdir -p "$LF.recovery.d"; echo 999997 > "$LF.recovery.d/owner"
acquire_slug_lock "$LF"; rc=$?
[[ $rc -eq 0 ]] && ok "4 dead-owner mutex reaped, acquired" || no "4 dead-mutex reap (rc=$rc)"
[[ -d "$LF.recovery.d" ]] && no "4b recovery mutex leaked" || ok "4b recovery mutex cleaned up"

# 5. recovery mutex owned by LIVE pid -> busy (never clobber)
sleep 30 & MO=$!
echo 999996 > "$LF"; mkdir -p "$LF.recovery.d"; echo "$MO" > "$LF.recovery.d/owner"
acquire_slug_lock "$LF"; rc=$?
[[ $rc -eq 1 ]] && ok "5 live-owner mutex -> busy (no clobber)" || no "5 live-mutex busy (rc=$rc)"
kill "$MO" 2>/dev/null; rm -rf "$LF.recovery.d"

# 6. EMPTY-owner mutex (another recoverer mid-creation) that gets its PID written
#    DURING our settle window -> must back off, never reap the live holder. This is
#    the mkdir->owner-write TOCTOU codex flagged: empty owner != stale.
sleep 30 & MO6=$!
echo 999995 > "$LF"; mkdir -p "$LF.recovery.d"; : > "$LF.recovery.d/owner"   # empty owner now
( sleep 0.1; echo "$MO6" > "$LF.recovery.d/owner" ) &   # creator fills PID mid-settle
acquire_slug_lock "$LF"; rc=$?
if [[ $rc -eq 1 && -d "$LF.recovery.d" ]]; then ok "6 empty-owner mid-creation -> busy, mutex preserved (TOCTOU closed)"; else no "6 mid-creation race (rc=$rc, mutex=$([[ -d $LF.recovery.d ]] && echo present || echo GONE))"; fi
wait 2>/dev/null
kill "$MO6" 2>/dev/null; rm -rf "$LF.recovery.d"

# 7. EMPTY-owner mutex that STAYS empty (creator died between mkdir and owner
#    write) -> genuinely leaked; reaped after the settle re-read, then acquire.
echo 999994 > "$LF"; mkdir -p "$LF.recovery.d"; : > "$LF.recovery.d/owner"
acquire_slug_lock "$LF"; rc=$?
[[ $rc -eq 0 && "$(cat "$LF")" == "$$" ]] && ok "7 leaked empty-owner reaped after settle, acquired" || no "7 leaked empty-owner reap (rc=$rc)"
[[ -d "$LF.recovery.d" ]] && no "7b leaked empty mutex not cleaned" || ok "7b leaked empty mutex cleaned up"

print ""
print "─────────────────────────────────────────"
if (( FAIL == 0 )); then
  print -P "%F{green}▶ ZSH-4 lock redesign: $PASS/$((PASS+FAIL)) PASS%f"; exit 0
else
  print -P "%F{red}▶ ZSH-4 lock redesign: $PASS pass, $FAIL FAIL%f"; exit 1
fi
