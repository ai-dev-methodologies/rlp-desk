#!/bin/zsh
# ============================================================================
# F-6 regression: Bug #8 dirty-tree gate must IGNORE untracked cruft but STILL
# catch uncommitted TRACKED edits. Mirrors the exact decision the gate makes at
# src/scripts/run_ralph_desk.zsh Gate 3 (`_bug8_dirty=$(git ... status --porcelain
# --untracked-files=no); [[ -n "$_bug8_dirty" ]] && BLOCK`).
#
# Before the fix the gate used plain `status --porcelain`, which includes
# untracked (??) files, so ANY stray untracked file in ROOT false-BLOCKed the
# campaign at iter 1 — the largest "never completes" cause in large-campaign
# dogfood (a Worker that correctly implemented AND committed its US still got
# BLOCKED because an unrelated log file was untracked).
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

# The FIXED gate decision (what run_ralph_desk.zsh:684 now runs):
gate_dirty(){ git -C "$1" status --porcelain --untracked-files=no 2>/dev/null }
# The OLD (buggy) decision, kept only to demonstrate the F-6 false-BLOCK:
old_dirty(){ git -C "$1" status --porcelain 2>/dev/null }

mkrepo(){
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  print "v1" > "$d/src.py"; git -C "$d" add -A; git -C "$d" commit -q -m base
  print "$d"
}

print -P "%F{cyan}F-6 dirty-tree gate regression%f"

# Case A — Worker committed its US file; an UNRELATED untracked cruft file exists.
A=$(mkrepo); print "log line" > "$A/campaign.log"
[[ -n "$(old_dirty $A)" ]] && ok "A old gate sees DIRTY on untracked cruft (reproduces F-6 false-BLOCK)" \
                            || no "A old gate unexpectedly clean (cannot reproduce F-6)"
[[ -z "$(gate_dirty $A)" ]] && ok "A FIXED gate is CLEAN despite untracked cruft (F-6 fixed)" \
                            || no "A FIXED gate still dirty: '$(gate_dirty $A)'"

# Case B — a TRACKED file modified but NOT committed (Worker left work uncommitted).
B=$(mkrepo); print "v2-uncommitted" > "$B/src.py"
[[ -n "$(gate_dirty $B)" ]] && ok "B FIXED gate STILL BLOCKs uncommitted TRACKED edit (Bug #8 intent preserved)" \
                            || no "B FIXED gate missed an uncommitted tracked modification"

# Case C — fully clean tree (Worker committed everything, no cruft).
C=$(mkrepo)
[[ -z "$(gate_dirty $C)" ]] && ok "C FIXED gate CLEAN on pristine tree" \
                            || no "C FIXED gate dirty on a clean tree"

# Case D — untracked cruft AND a tracked modification → must still BLOCK.
D=$(mkrepo); print "x" > "$D/cruft.tmp"; print "v2" > "$D/src.py"
[[ -n "$(gate_dirty $D)" ]] && ok "D FIXED gate BLOCKs on tracked edit even amid untracked cruft" \
                            || no "D FIXED gate missed tracked edit amid cruft"

rm -rf "$A" "$B" "$C" "$D"
print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-6 gate regression: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-6 gate regression: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
