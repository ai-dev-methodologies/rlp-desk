#!/bin/zsh
# ============================================================================
# F-8 regression: when a Worker leaves its US work as an uncommitted TRACKED
# modification (a frequent weak-model commit slip — done-claim says "Committed"
# but the commit never landed), the leader must RECOVER (auto-commit the
# Worker's tracked changes with `git add -u`) rather than terminally BLOCK.
#
# Mirrors the recovery the gate now performs at src/scripts/run_ralph_desk.zsh
# Gate 3: `git add -u && git commit`. Asserts the recovery (a) cleans the
# tracked tree, (b) does NOT sweep untracked cruft into the commit, (c) actually
# commits the Worker's work.
# ============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

mkrepo(){
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  print "v1" > "$d/service.py"; print "t1" > "$d/test_us.py"
  git -C "$d" add -A; git -C "$d" commit -q -m base
  print "$d"
}

print -P "%F{cyan}F-8 commit-slip recovery regression%f"

# The F-8 condition: a TRACKED test file modified (Worker's US work) but not
# committed, plus an unrelated untracked cruft file.
R=$(mkrepo)
print "    # 55 more lines of US-006 tests" >> "$R/test_us.py"   # tracked modification (the slip)
print "scratch" > "$R/local-notes.txt"                            # untracked cruft

# Pre-state: gate (F-6 form) sees the tracked modification → would have BLOCKED.
[[ -n "$(git -C "$R" status --porcelain --untracked-files=no)" ]] \
  && ok "pre: gate sees uncommitted TRACKED change (the F-8 trigger)" \
  || no "pre: gate did not see the tracked modification"

# Recovery (mirror of the fix): commit tracked changes only, never cruft.
git -C "$R" add -u && git -C "$R" commit -q -m "chore(leader-recovery): commit Worker's uncommitted US-006 changes (Bug #8 F-8)"

[[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ]] \
  && ok "recovery: tracked tree CLEAN after auto-commit (gate now passes → synthesis proceeds)" \
  || no "recovery: tracked tree still dirty: '$(git -C "$R" status --porcelain --untracked-files=no)'"

[[ -n "$(git -C "$R" status --porcelain | grep '^??')" ]] \
  && ok "recovery: untracked cruft PRESERVED (git add -u never swept it into the commit)" \
  || no "recovery: cruft was wrongly committed/removed"

git -C "$R" show --stat HEAD | grep -q "test_us.py" \
  && ok "recovery: the Worker's actual US work was committed" \
  || no "recovery: Worker work missing from recovery commit"

# Cruft must NOT be in the recovery commit.
git -C "$R" show --stat HEAD | grep -q "local-notes.txt" \
  && no "recovery: cruft leaked into the recovery commit" \
  || ok "recovery: cruft absent from the recovery commit"

rm -rf "$R"
print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-8 recovery regression: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-8 recovery regression: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
