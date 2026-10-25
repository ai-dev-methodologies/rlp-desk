#!/usr/bin/env zsh
# security-init-a5 F-07: `init --mode fresh|improve` must really quarantine a cross-mission
# stale iter-signal.json (US-022 R10 P2-J). init called `_quarantine_stale_signal` (defined only
# in lib_ralph_desk.zsh) without ever loading it: "command not found", swallowed by
# `2>/dev/null || true`, so the documented quarantine never happened (the signal was only
# swept into runs/superseded-<ts>/ by the generic archive step).
#
# This test RUNS init_ralph_desk.zsh itself (isolated temp project, ROOT=...).
#   Q1  fresh:   a signal whose us_id is NOT in the PRD lands in .rlp-desk/.sisyphus/quarantine/
#                iter-signal.<epoch>.json byte-identical, leaves memos/, is NOT also archived,
#                and init says so on stderr ([lane] cross-mission stale us_id ...).
#   Q2  improve: same.
#   Q3  own-mission signal (us_id present in the PRD): not quarantined; archived as before.
#   Q4  us_id "ALL": not quarantined; archived as before.
#   Q5  lib_ralph_desk.zsh unreachable (init copied alone): init still succeeds and the foreign
#       signal is still preserved (archived) - the quarantine is best-effort, never data loss.
set -uo pipefail
REPO="${0:A:h:h}"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# mkproj <label>: initialized project (slug "slugx"); its scaffold PRD declares ### US-001 only.
mkproj() {
  local p="$TMP/$1"; mkdir -p "$p"
  ( cd "$p" && git init -q && git config user.email t@e.com && git config user.name t && git config commit.gpgsign false \
    && echo x > a && git add a && git commit -qm b && ROOT="$p" zsh "${2:-$INIT}" slugx "first-objective" >/dev/null 2>&1 )
  print -r -- "$p"
}
# seed_signal <project> <us_id>: write a signal; the bytes are kept in <project>.orig for comparison.
seed_signal() {
  local p="$1" us="$2"
  SIG="$p/.rlp-desk/memos/slugx-iter-signal.json"
  printf '{"iteration":3,"status":"verify","us_id":"%s","summary":"seed-%s"}\n' "$us" "$RANDOM$RANDOM" > "$SIG"
  cp "$SIG" "$p.orig"
  QDIR="$p/.rlp-desk/.sisyphus/quarantine"
  ARCHGLOB="$p/.rlp-desk/logs/slugx/runs/superseded-*/slugx-iter-signal.json"
}
quarantined() { local q; q=( "$QDIR"/iter-signal.*.json(N) ); QFILES=("${q[@]}"); (( ${#q} == 1 )) && cmp -s "$1.orig" "${q[1]}"; }
archived() { local a; a=( ${~ARCHGLOB}(N) ); (( ${#a} == 1 )) && cmp -s "$1.orig" "${a[1]}"; }

for md in fresh improve; do
  id=$([[ $md == fresh ]] && echo Q1 || echo Q2)
  print -r -- "== $id: foreign us_id (US-099) under --mode $md is quarantined =="
  p=$(mkproj "$md"); seed_signal "$p" US-099
  out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode "$md" 2>&1 ); rc=$?
  if (( rc == 0 )) && quarantined "$p" && [[ ! -e "$SIG" ]] && ! archived "$p" \
     && [[ "$out" == *"[lane] cross-mission stale us_id (US-099)"* ]]; then
    ok "$id rc=0; signal is byte-identical in .sisyphus/quarantine/, gone from memos/, not double-archived, stderr names the us_id"
  else
    no "$id rc=$rc quarantine-files=${#QFILES} memos-signal=$([[ -e $SIG ]] && echo present || echo gone) archived=$(archived "$p" && echo yes || echo no) lane-msg=$([[ "$out" == *"cross-mission stale us_id"* ]] && echo yes || echo no)"
  fi
done

print -r -- "== Q3: own-mission us_id (US-001, present in the PRD) is NOT quarantined =="
p=$(mkproj own); seed_signal "$p" US-001
out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
if (( rc == 0 )) && archived "$p" && [[ ! -e "$QDIR" && ! -e "$SIG" ]]; then
  ok "Q3 rc=0; own signal archived into runs/superseded-*/, no quarantine dir created"
else
  no "Q3 rc=$rc archived=$(archived "$p" && echo yes || echo no) quarantine-dir=$([[ -e $QDIR ]] && echo present || echo absent)"
fi

print -r -- "== Q4: us_id ALL is NOT quarantined =="
p=$(mkproj all); seed_signal "$p" ALL
out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
if (( rc == 0 )) && archived "$p" && [[ ! -e "$QDIR" && ! -e "$SIG" ]]; then
  ok "Q4 rc=0; ALL signal archived, no quarantine dir created"
else
  no "Q4 rc=$rc archived=$(archived "$p" && echo yes || echo no) quarantine-dir=$([[ -e $QDIR ]] && echo present || echo absent)"
fi

print -r -- "== Q5: lib unreachable -> best-effort: init succeeds, foreign signal still preserved =="
mkdir -p "$TMP/solo"; cp "$INIT" "$TMP/solo/init_ralph_desk.zsh"
p=$(mkproj nolib "$TMP/solo/init_ralph_desk.zsh"); seed_signal "$p" US-099
out=$( cd "$p" && ROOT="$p" zsh "$TMP/solo/init_ralph_desk.zsh" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
if (( rc == 0 )) && archived "$p" && [[ ! -e "$SIG" ]]; then
  ok "Q5 rc=0; with no lib beside init the foreign signal is still archived (never lost)"
else
  no "Q5 rc=$rc archived=$(archived "$p" && echo yes || echo no) memos-signal=$([[ -e $SIG ]] && echo present || echo gone)"
fi

print
print "=== RESULTS: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
