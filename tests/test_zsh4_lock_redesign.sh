#!/bin/zsh
# ZSH-4 redesign (v0.17.1): race-safe per-slug lock acquisition.
# Verifies acquire_slug_lock (lib_ralph_desk.zsh) against the four race classes
# codex flagged in the earlier patch attempts:
#   1. fresh acquire
#   2. live holder  -> busy (no double-acquire)
#   3. stale lock (dead owner) -> recover
#   4. leaked recovery mutex owned by a DEAD pid -> reaped, then acquire (no leak)
#   5. recovery mutex owned by a LIVE pid -> busy (never clobber a live recoverer)
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

print ""
print "─────────────────────────────────────────"
if (( FAIL == 0 )); then
  print -P "%F{green}▶ ZSH-4 lock redesign: $PASS/$((PASS+FAIL)) PASS%f"; exit 0
else
  print -P "%F{red}▶ ZSH-4 lock redesign: $PASS pass, $FAIL FAIL%f"; exit 1
fi
