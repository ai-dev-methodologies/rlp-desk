#!/bin/zsh
# ============================================================================
# F-8 regression + F-19 scoping: when a Worker leaves its US work as an
# uncommitted TRACKED modification (a weak-model commit slip — done-claim says
# "Committed" but the commit never landed), the leader must RECOVER (auto-commit
# the Worker's OWN tracked changes) rather than terminally BLOCK — AND must NEVER
# sweep an operator's PRE-EXISTING uncommitted edits into the recovery commit.
#
# Mirrors Gate 3 at src/scripts/run_ralph_desk.zsh: commit (tracked-dirty-vs-HEAD
# MINUS the campaign-start snapshot CAMPAIGN_PREEXISTING_DIRTY), never untracked
# cruft, never the operator's pre-existing edits.
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

# Mirror of Gate 3 (F-19 scoped): commit only the Worker's files = (tracked files
# dirty vs HEAD) MINUS the pre-existing dirty set captured at campaign start.
# rc=0 committed Worker files; rc=2 only pre-existing edits dirty (nothing to do).
recover_scoped(){
  local repo="$1" preexisting="$2" dirty worker_files
  dirty=$(git -C "$repo" diff --name-only HEAD 2>/dev/null)
  worker_files=$(comm -23 \
    <(printf '%s\n' "$dirty" | sort -u) \
    <(printf '%s\n' "$preexisting" | sort -u) \
    | grep -v '^[[:space:]]*$')
  [[ -z "$worker_files" ]] && return 2
  local -a add=("${(@f)worker_files}")
  git -C "$repo" add -- "${add[@]}" \
    && git -C "$repo" commit -q -m "chore(leader-recovery): commit Worker's uncommitted changes (Bug #8 F-8)"
}

print -P "%F{cyan}F-8 commit-slip recovery + F-19 scoping%f"

# ── Case A: clean start, Worker slip + untracked cruft → recover Worker work only ──
R=$(mkrepo)
PREEX=$(git -C "$R" diff --name-only HEAD)                        # clean start → empty
print "    # 55 more lines of US-006 tests" >> "$R/test_us.py"   # tracked modification (the slip)
print "scratch" > "$R/local-notes.txt"                            # untracked cruft

[[ -n "$(git -C "$R" status --porcelain --untracked-files=no)" ]] \
  && ok "A pre: gate sees uncommitted TRACKED change (the F-8 trigger)" \
  || no "A pre: gate did not see the tracked modification"

recover_scoped "$R" "$PREEX"

[[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ]] \
  && ok "A recovery: tracked tree CLEAN after auto-commit (synthesis proceeds)" \
  || no "A recovery: tracked tree still dirty: '$(git -C "$R" status --porcelain --untracked-files=no)'"
[[ -n "$(git -C "$R" status --porcelain | grep '^??')" ]] \
  && ok "A recovery: untracked cruft PRESERVED (never swept into the commit)" \
  || no "A recovery: cruft was wrongly committed/removed"
git -C "$R" show --stat HEAD | grep -q "test_us.py" \
  && ok "A recovery: the Worker's actual US work was committed" \
  || no "A recovery: Worker work missing from recovery commit"
git -C "$R" show --stat HEAD | grep -q "local-notes.txt" \
  && no "A recovery: cruft leaked into the recovery commit" \
  || ok "A recovery: cruft absent from the recovery commit"
rm -rf "$R"

# ── Case B (F-19): operator has a PRE-EXISTING tracked edit; Worker slips on its
#    own file. Recovery commits ONLY the Worker's file; the operator's edit is
#    never swept into the Worker-recovery commit and stays uncommitted. ──
R=$(mkrepo)
print "operator local hotfix" >> "$R/service.py"   # operator's PRE-EXISTING tracked edit
PREEX=$(git -C "$R" diff --name-only HEAD)          # snapshot at campaign start: service.py
[[ "$PREEX" == "service.py" ]] || no "B setup: preexisting snapshot wrong ('$PREEX')"
print "    # US-007 tests" >> "$R/test_us.py"        # Worker's slip (its own file)

recover_scoped "$R" "$PREEX"

git -C "$R" show --stat HEAD | grep -q "test_us.py" \
  && ok "B recovery: Worker's file committed" \
  || no "B recovery: Worker file missing from recovery commit"
git -C "$R" show --stat HEAD | grep -q "service.py" \
  && no "B recovery: operator's pre-existing edit SWEPT into the recovery commit (F-19 violated)" \
  || ok "B recovery: operator's pre-existing edit NOT in the recovery commit (F-19)"
git -C "$R" diff --name-only HEAD | grep -q "service.py" \
  && ok "B recovery: operator's pre-existing edit PRESERVED (still uncommitted, untouched)" \
  || no "B recovery: operator's pre-existing edit lost"
rm -rf "$R"

# ── Case C (F-19): only the operator's pre-existing edit is dirty (Worker did
#    commit its own work) → recovery commits NOTHING and allows synthesis. ──
R=$(mkrepo)
print "operator edit" >> "$R/service.py"
PREEX=$(git -C "$R" diff --name-only HEAD)   # service.py
recover_scoped "$R" "$PREEX"; rc=$?
[[ $rc -eq 2 ]] \
  && ok "C recovery: only pre-existing edits dirty → no auto-commit (synthesis allowed)" \
  || no "C recovery: expected no-commit (rc=2), got rc=$rc"
git -C "$R" diff --name-only HEAD | grep -q "service.py" \
  && ok "C recovery: operator edit untouched" || no "C recovery: operator edit altered"
rm -rf "$R"

print ""
if (( FAIL == 0 )); then
  print -P "%F{green}F-8 recovery + F-19 scoping: $PASS/$((PASS+FAIL)) PASS%f"
else
  print -P "%F{red}F-8 recovery + F-19 scoping: $PASS pass, $FAIL FAIL%f"
fi
exit $(( FAIL > 0 ))
