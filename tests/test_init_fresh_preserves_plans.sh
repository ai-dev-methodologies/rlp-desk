#!/usr/bin/env zsh
# US-002 (v0.22.3): init --mode fresh must preserve authored plans.
#
# Dogfood 2026-07-11: --mode fresh deleted an operator-authored PRD and
# test-spec and regenerated blank templates — plan assets silently lost.
# New contract: fresh preserves AUTHORED plans (detected PER FILE), deletes
# only template scaffolds; --reset-plans restores the wipe but versions a
# backup first. Per-US split files are always regenerated from the surviving
# PRD (stale splits from a previous PRD must not leak into the new run).
set -uo pipefail
REPO="${0:A:h:h}"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

AUTHORED_PRD='# PRD: t — real plan

### US-001: Do the real thing
- AC1: real criterion
'
AUTHORED_TS='# Test Specification: t

## Verification Context (fill BEFORE implementation)

### Target Behavior
What behavior does this project change or introduce?
- Real authored behavior description
'

scaffold() { # $1=case dir; fresh scaffold via a first init run
  local d="$TMP/$1"; mkdir -p "$d"; cd "$d"
  git init -q; git config user.email t@t; git config user.name t
  ROOT="$d" zsh "$INIT" t "toy" >/dev/null 2>&1
  print -r -- "$d"
}
refresh() { # $1=dir, rest=extra args; second init run in fresh mode
  local d="$1"; shift
  cd "$d"; ROOT="$d" zsh "$INIT" t "toy" --mode fresh "$@" >/dev/null 2>&1
}

print -r -- "-- case 1: authored PRD + authored test-spec survive --mode fresh"
D=$(scaffold case1)
print -r -- "$AUTHORED_PRD" > "$D/.rlp-desk/plans/prd-t.md"
print -r -- "$AUTHORED_TS"  > "$D/.rlp-desk/plans/test-spec-t.md"
refresh "$D"
grep -q "Do the real thing" "$D/.rlp-desk/plans/prd-t.md" 2>/dev/null \
  && ok "authored PRD content preserved" || no "authored PRD was destroyed"
grep -q "Real authored behavior" "$D/.rlp-desk/plans/test-spec-t.md" 2>/dev/null \
  && ok "authored test-spec content preserved" || no "authored test-spec was destroyed"
grep -q "Do the real thing" "$D/.rlp-desk/plans/prd-t-US-001.md" 2>/dev/null \
  && ok "per-US split regenerated from the preserved PRD" || no "split not regenerated"

print -r -- "-- case 2: template-only plans are regenerated as before (no behavior change)"
D=$(scaffold case2)
refresh "$D"
test -f "$D/.rlp-desk/plans/prd-t.md" \
  && ok "template PRD regenerated" || no "template PRD missing after fresh"
grep -q "US-001: \[Title\]" "$D/.rlp-desk/plans/prd-t.md" 2>/dev/null \
  && ok "regenerated PRD is the scaffold template" || no "unexpected PRD content"

print -r -- "-- case 3: mixed — authored test-spec + template PRD (per-file detection)"
D=$(scaffold case3)
print -r -- "$AUTHORED_TS" > "$D/.rlp-desk/plans/test-spec-t.md"
refresh "$D"
grep -q "Real authored behavior" "$D/.rlp-desk/plans/test-spec-t.md" 2>/dev/null \
  && ok "authored test-spec survives even when PRD is template" \
  || no "mixed state: authored test-spec destroyed"

print -r -- "-- case 4: mixed — authored PRD + template test-spec"
D=$(scaffold case4)
print -r -- "$AUTHORED_PRD" > "$D/.rlp-desk/plans/prd-t.md"
refresh "$D"
grep -q "Do the real thing" "$D/.rlp-desk/plans/prd-t.md" 2>/dev/null \
  && ok "authored PRD survives even when test-spec is template" \
  || no "mixed state: authored PRD destroyed"

print -r -- "-- case 5: --reset-plans wipes but versions a backup first"
D=$(scaffold case5)
print -r -- "$AUTHORED_PRD" > "$D/.rlp-desk/plans/prd-t.md"
print -r -- "$AUTHORED_TS"  > "$D/.rlp-desk/plans/test-spec-t.md"
refresh "$D" --reset-plans
grep -q "Do the real thing" "$D/.rlp-desk/plans/prd-t.md" 2>/dev/null \
  && no "--reset-plans did not wipe the PRD" || ok "--reset-plans wiped the PRD"
ls "$D/.rlp-desk/plans/"prd-t-v*.md >/dev/null 2>&1 \
  && ok "PRD backup versioned before wipe" || no "no PRD backup found"
ls "$D/.rlp-desk/plans/"test-spec-t-v*.md >/dev/null 2>&1 \
  && ok "test-spec backup versioned before wipe" || no "no test-spec backup found"

print -r -- "-- case 5b: verified ledger is RUNTIME state — fresh removes it (P1-2)"
D=$(scaffold case5b)
mkdir -p "$D/.rlp-desk/memos"
print -r -- '{"us_id":"US-001","iter":1,"commit":"x","prd":"y"}' > "$D/.rlp-desk/memos/t-verified.jsonl"
chmod 0444 "$D/.rlp-desk/memos/t-verified.jsonl"
refresh "$D"
test -f "$D/.rlp-desk/memos/t-verified.jsonl" \
  && no "stale verified ledger survived fresh (old credit inherited)" \
  || ok "fresh removes the verified ledger (0444 handled)"

print -r -- "-- case 5c: test-spec edited ONLY outside Target Behavior is still authored (P1-3)"
D=$(scaffold case5c)
TS="$D/.rlp-desk/plans/test-spec-t.md"
perl -0pi -e 's/(### Impacted Tests\n[^\n]*\n)- TODO[^\n]*/\1- real: tests\/test_x.sh may break/' "$TS"
grep -q '^- real: tests/test_x.sh may break' "$TS" || no "fixture setup failed (Impacted Tests edit)"
refresh "$D"
grep -q '^- real: tests/test_x.sh may break' "$TS" 2>/dev/null \
  && ok "spec with edits only in Impacted Tests preserved" \
  || no "P1-3 regression: non-Target-Behavior edit misclassified as template"

print -r -- "-- case 6: stale per-US splits from an old PRD do not survive fresh"
D=$(scaffold case6)
print -r -- "$AUTHORED_PRD" > "$D/.rlp-desk/plans/prd-t.md"
printf '### US-009: Stale story\n' > "$D/.rlp-desk/plans/prd-t-US-009.md"
refresh "$D"
test -f "$D/.rlp-desk/plans/prd-t-US-009.md" \
  && no "stale US-009 split survived fresh" || ok "stale split removed on fresh"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
