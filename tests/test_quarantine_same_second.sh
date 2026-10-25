#!/bin/zsh
# ============================================================================
# A-C1-05 / R1-09: _quarantine_stale_signal named its destination iter-signal.$(date +%s).json and moved
# with a plain mv, so two quarantines inside one second (two inits, or init + the leader) overwrote the
# earlier recovery copy. The destination must be exclusive (never clobbers an existing file); when no
# destination can be allocated the source stays in place for the archive step (never lost).
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
SCRIPT_DIR="${0:A:h}"; ROOT_DIR="${SCRIPT_DIR:h}"
LIB="${RLP_TEST_LIB_SCRIPT:-$ROOT_DIR/src/scripts/lib_ralph_desk.zsh}"
[[ -f "$LIB" ]] || { print -u2 "FAIL: $LIB not found"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

eval "$(awk '$0 ~ /^_quarantine_stale_signal\(\) \{/{f=1} f{print} f && /^}/{exit}' "$LIB")"
[[ "$(whence -w _quarantine_stale_signal 2>/dev/null)" == *function* ]] || { no "could not extract _quarantine_stale_signal"; exit 1; }
_lifecycle_clear_lock_mark() { :; }
date() { print -r -- 1700000000; }          # every quarantine lands in the same second

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/qsame.XXXXXX"); trap 'chmod -R u+rwX "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT
DESK="$TMPD/desk"; mkdir -p "$DESK"
SIG="$TMPD/iter-signal.json"
seed() { printf '{"iteration":1,"us_id":"US-099","summary":"%s"}\n' "$1" > "$SIG"; }

print "== two quarantines in the same second are both preserved =="
seed first;  _quarantine_stale_signal "$SIG" "$TMPD/no-prd.md" "$DESK" 2>/dev/null
seed second; _quarantine_stale_signal "$SIG" "$TMPD/no-prd.md" "$DESK" 2>/dev/null
seed third;  _quarantine_stale_signal "$SIG" "$TMPD/no-prd.md" "$DESK" 2>/dev/null
q=( "$DESK"/.sisyphus/quarantine/iter-signal.*.json(N) )
{ (( ${#q} == 3 )) && [[ ! -e "$SIG" ]]; } && ok "3 quarantines, 3 files, source moved (files: ${#q})" || no "expected 3 files and a moved source, got ${#q} (source present: $([[ -e $SIG ]] && print yes || print no))"
all=$(cat "${q[@]}" 2>/dev/null)
[[ "$all" == *'"first"'* && "$all" == *'"second"'* && "$all" == *'"third"'* ]] && ok "each recovery copy kept its own content" || no "a recovery copy was overwritten: $all"

print "== an existing quarantine file (even a dangling symlink) is never clobbered =="
rm -rf "$DESK/.sisyphus"; mkdir -p "$DESK/.sisyphus/quarantine"
print -r -- KEEP > "$DESK/.sisyphus/quarantine/iter-signal.1700000000.json"
ln -s "$TMPD/nowhere" "$DESK/.sisyphus/quarantine/iter-signal.1700000000-2.json"
seed fourth; _quarantine_stale_signal "$SIG" "$TMPD/no-prd.md" "$DESK" 2>/dev/null
[[ "$(<"$DESK/.sisyphus/quarantine/iter-signal.1700000000.json")" == KEEP && ! -e "$TMPD/nowhere" && ! -e "$SIG" ]] \
  && ok "pre-existing file kept, nothing written through the symlink, source moved to a free name" || no "clobbered or written through a link"

print "== allocation impossible -> the source stays in place (archive step handles it) =="
rm -rf "$DESK/.sisyphus"; mkdir -p "$DESK/.sisyphus/quarantine"; chmod 500 "$DESK/.sisyphus/quarantine"
seed fifth; _quarantine_stale_signal "$SIG" "$TMPD/no-prd.md" "$DESK" 2>/dev/null; rc=$?
chmod 700 "$DESK/.sisyphus/quarantine"
{ (( rc == 0 )) && [[ -f "$SIG" ]] && [[ "$(cat "$SIG")" == *fifth* ]]; } && ok "rc 0, source left untouched" || no "source lost or rc=$rc"
empties=( "$DESK"/.sisyphus/quarantine/*(N) )
(( ${#empties} == 0 )) && ok "no empty placeholder left behind" || no "leftover placeholder: ${empties[*]}"

print ""
print "quarantine_same_second: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
