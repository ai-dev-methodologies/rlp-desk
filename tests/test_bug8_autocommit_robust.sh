#!/bin/zsh
# request-b ② — Bug #8 F-8 leader-recovery auto-commit robustness.
#
# A NEW file under a .gitignore'd path (evidence dirs like test-results/ are
# force-tracked by repo convention) made the old `git add` refuse → hard BLOCK.
# The fix: normal `git add` first, `git add -f` fallback STRICTLY scoped to the
# already-narrowed worker-file list, and — when even that can't complete —
# warn+carryover+continue instead of BLOCK (the Verifier stays the completeness
# gate). This sources the real helpers against fresh tmp git repos.
#
# Scenarios:
#   A  ignored-path NEW artifact in the list  → -f fallback commits it (rc 0)
#   B  clean case: normal tracked change      → plain add path commits (rc 0)
#   C  unrecoverable (nonexistent path)        → returns 1 (caller downgrades)
#   D  _bug8_record_carryover writes the carryover record
#   S  structural: caller continues (no BLOCK), -f is scoped (never -A)
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

log(){ :; }; log_error(){ :; }; log_debug(){ :; }

# Cherry-pick the helper defs (sourcing the whole run script runs main).
EXTRACT=$(mktemp -d); trap 'rm -rf "$EXTRACT"' EXIT
awk '/^_bug8_autocommit\(\)/,/^}$/' "$RUN"        >  "$EXTRACT/h.zsh"
awk '/^_bug8_carryover_file\(\)/{print}' "$RUN"   >> "$EXTRACT/h.zsh"
awk '/^_bug8_record_carryover\(\)/,/^}$/' "$RUN"  >> "$EXTRACT/h.zsh"
grep -q '_bug8_autocommit' "$EXTRACT/h.zsh"       || { print -u2 "FAIL: _bug8_autocommit not extracted"; exit 1; }
grep -q '_bug8_record_carryover' "$EXTRACT/h.zsh" || { print -u2 "FAIL: _bug8_record_carryover not extracted"; exit 1; }
source "$EXTRACT/h.zsh"

mkrepo() { # $1 = dir
  local r="$1"; mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  print -r -- "seed" > "$r/normal.txt"
  git -C "$r" add normal.txt; git -C "$r" commit -qm init
  print -r -- "test-results/" > "$r/.gitignore"
  git -C "$r" add .gitignore; git -C "$r" commit -qm ignore
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$EXTRACT"' EXIT

# --- A: ignored-path NEW artifact + a normal tracked change ---
RA="$TMP/a"; mkrepo "$RA"
mkdir -p "$RA/test-results"; print -r -- '{"ok":1}' > "$RA/test-results/receipt.json"  # untracked + ignored
print -r -- "worker change" >> "$RA/normal.txt"                                        # tracked, modified
( cd "$RA" && _bug8_autocommit "$RA" "recover A" test-results/receipt.json normal.txt ); rcA=$?
(( rcA == 0 )) && ok "A: ignored-path new artifact → auto-commit succeeds (rc 0 via -f fallback)" \
  || no "A: expected rc 0, got $rcA"
git -C "$RA" ls-files --error-unmatch test-results/receipt.json >/dev/null 2>&1 \
  && ok "A: force-added the gitignored evidence artifact into the commit" \
  || no "A: ignored artifact was not committed"
[[ -z "$(git -C "$RA" status --porcelain -- normal.txt)" ]] \
  && ok "A: the normal tracked change is committed too" || no "A: normal.txt left uncommitted"

# --- B: clean case — a normal tracked change, no ignored path (plain add path) ---
RB="$TMP/b"; mkrepo "$RB"
print -r -- "more" >> "$RB/normal.txt"
( cd "$RB" && _bug8_autocommit "$RB" "recover B" normal.txt ); rcB=$?
(( rcB == 0 )) && ok "B: clean case commits via plain add (rc 0, regression guard)" \
  || no "B: expected rc 0, got $rcB"
[[ -z "$(git -C "$RB" status --porcelain -- normal.txt)" ]] \
  && ok "B: working tree clean for the committed file" || no "B: normal.txt not committed"

# --- C: unrecoverable — a path that does not exist (add AND add -f both fail) ---
RC="$TMP/c"; mkrepo "$RC"
( cd "$RC" && _bug8_autocommit "$RC" "recover C" does-not-exist.txt ) 2>/dev/null; rcC=$?
(( rcC == 1 )) && ok "C: unrecoverable add → returns 1 (caller downgrades to continue)" \
  || no "C: expected rc 1, got $rcC"

# --- D: carryover record is written for the next fix contract ---
export LOGS_DIR="$TMP/d-logs"; mkdir -p "$LOGS_DIR"
unset BUG8_CARRYOVER_FILE
_bug8_record_carryover "US-001" $'test-results/receipt.json\nsrc/foo.ts'
cf=$(_bug8_carryover_file)
[[ -f "$cf" ]] && grep -q 'test-results/receipt.json' "$cf" \
  && ok "D: _bug8_record_carryover persists the uncommitted list for carryover" \
  || no "D: carryover file missing or empty ($cf)"

# --- G: glob-metachar filename must NOT re-glob and sweep the tree (seal #1) ---
# A tracked file literally named '*' plus an ignored artifact triggers the -f
# fallback; with core.literalPathspecs the '*' stays literal. An operator
# preexisting-dirty file NOT in the list must stay unstaged and uncommitted.
RG="$TMP/g"; mkrepo "$RG"
print -r -- "operator wip" >> "$RG/normal.txt"                       # operator's dirty file (NOT in list)
print -r -- "glob" > "$RG/"'*'                                       # literal '*' file
git --literal-pathspecs -C "$RG" add -- '*'; git -C "$RG" commit -qm 'track literal star'
print -r -- "worker edit" >> "$RG/"'*'                               # worker modifies '*'
mkdir -p "$RG/test-results"; print -r -- 'r' > "$RG/test-results/g.json"  # ignored artifact → forces -f path
( cd "$RG" && _bug8_autocommit "$RG" "recover G" '*' test-results/g.json ); rcG=$?
(( rcG == 0 )) && ok "G: glob-named worker file + ignored artifact → commit succeeds" || no "G: expected rc 0, got $rcG"
[[ -n "$(git -C "$RG" status --porcelain -- normal.txt)" ]] \
  && ok "G: operator's dirty file NOT swept by the '*' pathspec (literalPathspecs holds)" \
  || no "G: operator file was swept into the recovery commit — glob re-expansion regression"
git -C "$RG" ls-files --error-unmatch test-results/g.json >/dev/null 2>&1 \
  && ok "G: the intended ignored artifact was still force-added" || no "G: intended artifact missing"

# --- S: structural — caller continues (no BLOCK) + -f is scoped (never -A) ---
grep -q -- '--literal-pathspecs -C "\$root" add -f -- "\${files\[@\]}"' "$RUN" \
  && ok "S: -f fallback is literal-pathspec + scoped to the worker-file list (never -A)" \
  || no "S: scoped literal -f fallback not found"
! grep -qE 'add -f (-A|-a|--all)' "$RUN" \
  && ok "S: no broadened force-add anywhere" || no "S: a broadened force-add exists"
# The graceful-continue else-branch calls _bug8_record_carryover and must NOT
# BLOCK or return 1 (the old hard-BLOCK is gone).
autoblk=$(awk '/_bug8_autocommit "\$ROOT"/,/^      fi$/' "$RUN")
print -r -- "$autoblk" | grep -q '_bug8_record_carryover "\$us_id" "\$_bug8_worker_files"' \
  && ok "S: auto-commit failure branch carries the list over" || no "S: carryover call missing in failure branch"
print -r -- "$autoblk" | grep -q 'autocommit_failed_continue' \
  && ! print -r -- "$autoblk" | grep -qE 'write_blocked_sentinel|return 1' \
  && ok "S: auto-commit failure branch CONTINUES (no BLOCK, no return 1)" \
  || no "S: auto-commit failure branch still hard-BLOCKs"

# ===========================================================================
# US-002A — per-iteration pre-existing-dirty baseline (ITER_PREEXISTING_DIRTY)
# ===========================================================================
# CAMPAIGN_PREEXISTING_DIRTY is a PROCESS-START snapshot, so a tracked file
# dirtied by a FOREIGN editor (a human, or a native-mode leader — native takes
# no runner lock) AFTER the campaign started reads as Worker output and gets
# swept into the F-8 leader-recovery commit. US-002A re-snapshots at each
# worker dispatch and subtracts the UNION (campaign ∪ iteration).
#
# These scenarios drive the REAL Gate 3 (`_bug8_check_synth_allowed` extracted
# verbatim from run_ralph_desk.zsh) against fresh tmp git repos — not a mirror.
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found"; exit 1; }

awk '/^_bug8_check_synth_allowed\(\)/,/^}$/' "$RUN" >  "$EXTRACT/gate.zsh"
awk '/^_git_dirty_base\(\)/,/^}$/'          "$LIB" >> "$EXTRACT/gate.zsh"
awk '/^_git_snapshot\(\)/,/^}$/'            "$LIB" >> "$EXTRACT/gate.zsh"
grep -q '_bug8_check_synth_allowed' "$EXTRACT/gate.zsh" || { print -u2 "FAIL: gate not extracted"; exit 1; }
grep -q '_git_dirty_base'           "$EXTRACT/gate.zsh" || { print -u2 "FAIL: _git_dirty_base not extracted"; exit 1; }
source "$EXTRACT/gate.zsh"

# Capturing stubs for the gate's collaborators (override the no-ops above).
GATE_LOG=""; BLOCKED=""
log(){       GATE_LOG+="$*"$'\n'; }
log_error(){ GATE_LOG+="ERR $*"$'\n'; }
log_debug(){ GATE_LOG+="DBG $*"$'\n'; }
write_blocked_sentinel(){ BLOCKED="$1"; }
_emit_a4_fallback_audit(){ :; }

mkrepo2() { # $1 = dir — a.txt/b.txt/c.txt committed, tree clean
  local r="$1"; mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  print -r -- a1 > "$r/a.txt"; print -r -- b1 > "$r/b.txt"; print -r -- c1 > "$r/c.txt"
  git -C "$r" add -A; git -C "$r" commit -qm base
}

GATE_N=0
run_gate() { # $1=repo  $2=CAMPAIGN_PREEXISTING_DIRTY  $3=ITER_PREEXISTING_DIRTY
  GATE_N=$((GATE_N+1))
  ROOT="$1"
  CAMPAIGN_PREEXISTING_DIRTY="$2"
  ITER_PREEXISTING_DIRTY="$3"
  LOGS_DIR="$TMP/gate-logs-$GATE_N"; mkdir -p "$LOGS_DIR"   # outside the repo on purpose
  DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
  print -r -- '{"us_id":"US-001"}' > "$DONE_CLAIM_FILE"
  BUG8_CARRYOVER_FILE="$LOGS_DIR/carry.txt"
  CURRENT_US="US-001"
  GATE_LOG=""; BLOCKED=""
  _bug8_check_synth_allowed 1 "US-001" "test"
}
committed_files() { git -C "$1" show --pretty=format: --name-only HEAD | grep -v '^$' | sort; }

# --- E (AC1): tracked file clean at campaign start, dirtied BEFORE iteration N's
#     worker dispatch → excluded from the worker-file set, never staged. ---
RE="$TMP/e"; mkrepo2 "$RE"
E_HEAD0=$(git -C "$RE" rev-parse HEAD)
print -r -- "foreign editor" >> "$RE/a.txt"     # dirtied after campaign start, before dispatch
run_gate "$RE" "" "a.txt"; rcE=$?
(( rcE == 0 )) && ok "E(AC1): gate allows synthesis (rc 0) when only iter-preexisting dirt is present" \
  || no "E(AC1): expected rc 0, got $rcE (BLOCKED='$BLOCKED')"
[[ "$(git -C "$RE" rev-parse HEAD)" == "$E_HEAD0" ]] \
  && ok "E(AC1): NO leader-recovery commit created — foreign edit not swept" \
  || no "E(AC1): a recovery commit was created ($(committed_files "$RE" | tr '\n' ' '))"
git -C "$RE" diff --name-only HEAD | grep -qx 'a.txt' \
  && ok "E(AC1): the foreign edit is PRESERVED (still uncommitted)" \
  || no "E(AC1): the foreign edit was staged/committed away"
[[ -z "$(git -C "$RE" diff --name-only --cached HEAD)" ]] \
  && ok "E(AC1): nothing left staged in the index" || no "E(AC1): index has staged content"

# --- F (AC2): file modified BY the worker during iteration N → still committed. ---
RF="$TMP/f"; mkrepo2 "$RF"
print -r -- "worker work" >> "$RF/b.txt"
run_gate "$RF" "" ""; rcF=$?
(( rcF == 0 )) && ok "F(AC2): gate allows synthesis after recovering the Worker's file" \
  || no "F(AC2): expected rc 0, got $rcF (BLOCKED='$BLOCKED')"
[[ "$(committed_files "$RF")" == "b.txt" ]] \
  && ok "F(AC2): Worker's file committed by leader-recovery (no regression)" \
  || no "F(AC2): recovery commit contents wrong: '$(committed_files "$RF" | tr '\n' ' ')'"

# --- F2 (AC1+AC2): mixed — iter-preexisting foreign edit + a real Worker edit.
#     ONLY the Worker's file is committed; the foreign edit stays uncommitted. ---
RF2="$TMP/f2"; mkrepo2 "$RF2"
print -r -- "foreign editor" >> "$RF2/a.txt"    # iter-preexisting
print -r -- "worker work"    >> "$RF2/b.txt"    # worker output
run_gate "$RF2" "" "a.txt"; rcF2=$?
(( rcF2 == 0 )) && ok "F2: gate allows synthesis on the mixed set" || no "F2: expected rc 0, got $rcF2"
[[ "$(committed_files "$RF2")" == "b.txt" ]] \
  && ok "F2(AC1/AC2): recovery commit contains ONLY the Worker's file" \
  || no "F2: recovery commit contents wrong: '$(committed_files "$RF2" | tr '\n' ' ')'"
git -C "$RF2" diff --name-only HEAD | grep -qx 'a.txt' \
  && ok "F2(AC1): the foreign edit survived the recovery commit uncommitted" \
  || no "F2: the foreign edit was swept into the recovery commit"

# --- H (AC3): EVERY dirty tracked file excluded by the UNION (one campaign-side,
#     one iteration-side) → preexisting-only no-op branch; must NOT fall through
#     to the empty-array BLOCK at the D-20 guard. ---
RH="$TMP/h"; mkrepo2 "$RH"
print -r -- "operator wip" >> "$RH/c.txt"       # campaign-start preexisting
print -r -- "foreign edit" >> "$RH/a.txt"       # iteration-start preexisting
H_HEAD0=$(git -C "$RH" rev-parse HEAD)
run_gate "$RH" "c.txt" "a.txt"; rcH=$?
(( rcH == 0 )) && ok "H(AC3): union-excluded set → rc 0 (no BLOCK)" \
  || no "H(AC3): expected rc 0, got $rcH (BLOCKED='$BLOCKED')"
[[ -z "$BLOCKED" ]] \
  && ok "H(AC3): no blocked-sentinel written — the empty-array BLOCK never fired" \
  || no "H(AC3): fell into a BLOCK: '$BLOCKED'"
print -r -- "$GATE_LOG" | grep -q 'bug8=preexisting_only_no_commit' \
  && ok "H(AC3): logged the preexisting_only_no_commit no-op branch" \
  || no "H(AC3): no-op branch not logged (log: $(print -r -- "$GATE_LOG" | tr '\n' '|'))"
print -r -- "$GATE_LOG" | grep -q 'empty worker-file list' \
  && no "H(AC3): hit the D-20 empty-array BLOCK (post-array filtering regression)" \
  || ok "H(AC3): did NOT hit the D-20 empty-array BLOCK"
[[ "$(git -C "$RH" rev-parse HEAD)" == "$H_HEAD0" ]] \
  && ok "H(AC3): no commit created; both operator and foreign edits preserved" \
  || no "H(AC3): a commit was created"

# --- H2 (AC3 hazard, documented): zsh (@f) on an EMPTY string yields ONE EMPTY
#     element, so ${#array} is 1 — which is exactly why the union must be folded
#     into the comm -23 BEFORE the -z guard and never applied post-array. ---
[[ "$(zsh -c 'x=""; a=("${(@f)x}"); echo ${#a}')" == "1" ]] \
  && ok "H2(AC3): zsh hazard confirmed live — (@f) on empty string = 1 element (why post-array filtering is banned)" \
  || no "H2(AC3): the (@f) empty-string hazard no longer reproduces — re-review the D-20 guard"

# --- I1 (AC4): F-8 must never stage UNTRACKED files. ---
RI="$TMP/i"; mkrepo2 "$RI"
print -r -- "worker work" >> "$RI/b.txt"        # tracked worker edit
print -r -- "scratch"      > "$RI/untracked.txt"
mkdir -p "$RI/evidence"; print -r -- "r" > "$RI/evidence/receipt.json"
run_gate "$RI" "" ""; rcI=$?
(( rcI == 0 )) && ok "I1(AC4): gate allows synthesis with untracked cruft present" || no "I1: expected rc 0, got $rcI"
[[ "$(committed_files "$RI")" == "b.txt" ]] \
  && ok "I1(AC4): recovery commit contains ONLY the tracked Worker file" \
  || no "I1(AC4): untracked cruft widened into the recovery commit: '$(committed_files "$RI" | tr '\n' ' ')'"
git -C "$RI" status --porcelain | grep -q '^?? untracked.txt' \
  && ok "I1(AC4): untracked.txt still untracked (F-8 never widened into untracked territory)" \
  || no "I1(AC4): untracked.txt was absorbed"
git -C "$RI" status --porcelain | grep -q '^?? evidence/' \
  && ok "I1(AC4): untracked evidence dir still untracked" || no "I1(AC4): evidence dir was absorbed"

# --- I2 (AC4): the prompted untracked-evidence CARRYOVER path in
#     write_worker_trigger must be byte-unchanged by US-002A. Pin its sha256.
#     If you intentionally change that block, update this pin AND say why. ---
CARRY_BLOCK=$(awk '/F-8 carryover \(request-b\): uncommitted deliverables/,/^    fi$/' "$RUN")
CARRY_SHA=$(print -r -- "$CARRY_BLOCK" | shasum -a 256 | cut -d' ' -f1)
[[ "$CARRY_SHA" == "e278d42e52b86ebf290c35429711f2d27b54552f3d93039550b89677136a8e3d" ]] \
  && ok "I2(AC4): carryover injection/consumption block byte-unchanged (sha256 pinned)" \
  || no "I2(AC4): carryover block changed (sha=$CARRY_SHA) — US-002A must not touch it"
print -r -- "$CARRY_BLOCK" | grep -q 'rm -f "\$_bug8_carry"' \
  && ok "I2(AC4): carryover record is still consumed exactly once" || no "I2(AC4): carryover consumption missing"

# --- J (AC5): the new baseline only ever NARROWS the staged set, never widens it.
#     Same dirty state, run twice: ITER empty vs ITER non-empty. ---
RJ1="$TMP/j1"; mkrepo2 "$RJ1"
print -r -- "x" >> "$RJ1/a.txt"; print -r -- "y" >> "$RJ1/b.txt"
run_gate "$RJ1" "" "" >/dev/null 2>&1
J_WIDE=$(committed_files "$RJ1")
RJ2="$TMP/j2"; mkrepo2 "$RJ2"
print -r -- "x" >> "$RJ2/a.txt"; print -r -- "y" >> "$RJ2/b.txt"
run_gate "$RJ2" "" "a.txt" >/dev/null 2>&1
J_NARROW=$(committed_files "$RJ2")
[[ -z "$(comm -13 <(print -r -- "$J_WIDE") <(print -r -- "$J_NARROW"))" ]] \
  && ok "J(AC5): iteration baseline never WIDENS the staged set (narrow ⊆ wide)" \
  || no "J(AC5): the iteration baseline added files: '$(comm -13 <(print -r -- "$J_WIDE") <(print -r -- "$J_NARROW") | tr '\n' ' ')'"
[[ "$J_WIDE" == $'a.txt\nb.txt' && "$J_NARROW" == "b.txt" ]] \
  && ok "J(AC5): it does narrow (wide=a,b → narrow=b)" \
  || no "J(AC5): wide='$(print -r -- "$J_WIDE" | tr '\n' ',')' narrow='$(print -r -- "$J_NARROW" | tr '\n' ',')'"

# --- J2 (AC5 / D-25): on a RELAUNCH the campaign snapshot is re-captured and the
#     iteration baseline starts empty — documented D-25 behaviour is unchanged. ---
RJ3="$TMP/j3"; mkrepo2 "$RJ3"
print -r -- "prior segment work" >> "$RJ3/a.txt"   # re-captured into CAMPAIGN on relaunch
print -r -- "worker work"        >> "$RJ3/b.txt"
run_gate "$RJ3" "a.txt" ""; rcJ3=$?
(( rcJ3 == 0 )) && [[ "$(committed_files "$RJ3")" == "b.txt" ]] \
  && ok "J2(AC5/D-25): relaunch behaviour unchanged — campaign snapshot still excludes, iter baseline empty" \
  || no "J2(AC5/D-25): relaunch behaviour changed (rc=$rcJ3 files='$(committed_files "$RJ3" | tr '\n' ' ')')"

# --- K (AC1 structural): the union is folded INTO the comm -23 BEFORE the -z
#     guard, and NOTHING filters _bug8_add after the array build. ---
f8blk=$(awk '/local _bug8_worker_files$/,/^      fi$/' "$RUN")
print -r -- "$f8blk" | grep -q 'comm -23' \
  && print -r -- "$f8blk" | grep -q 'CAMPAIGN_PREEXISTING_DIRTY' \
  && print -r -- "$f8blk" | grep -q 'ITER_PREEXISTING_DIRTY' \
  && ok "K(AC1): F-8 subtracts the campaign ∪ iteration union via comm -23" \
  || no "K(AC1): F-8 does not subtract ITER_PREEXISTING_DIRTY in the comm -23"
comm_line=$(grep -n 'comm -23' "$RUN" | awk -F: '$1>1400 && $1<1500 {print $1; exit}')
zguard_line=$(grep -n '\[\[ -z "\$_bug8_worker_files" \]\]' "$RUN" | head -1 | cut -d: -f1)
iter_ref_line=$(awk 'NR>'"${comm_line:-0}"' && NR<'"${zguard_line:-0}"' && /ITER_PREEXISTING_DIRTY/ {print NR; exit}' "$RUN")
[[ -n "$comm_line" && -n "$zguard_line" && -n "$iter_ref_line" ]] \
  && ok "K(AC1): the union lands between the comm -23 (L$comm_line) and the -z guard (L$zguard_line)" \
  || no "K(AC1): union not folded into the comm before the -z guard (comm=$comm_line zguard=$zguard_line ref=$iter_ref_line)"
postarray=$(awk '/local -a _bug8_add=/,/#_bug8_add} == 0/' "$RUN")
print -r -- "$postarray" | grep -q 'ITER_PREEXISTING_DIRTY' \
  && no "K(AC1): _bug8_add is filtered AFTER the array build — (@f) empty-string hazard reintroduced" \
  || ok "K(AC1): no post-array filtering of _bug8_add (the banned shape)"
print -r -- "$f8blk" | grep -q 'never let an empty array turn' \
  && ok "K(AC1): the load-bearing D-20 comment about the upstream -z guard is preserved" \
  || no "K(AC1): the D-20 comment was dropped"
print -r -- "$f8blk" | grep -q 'empty worker-file list at auto-commit' \
  && ok "K(AC1): the D-20 empty-array BLOCK is still present as the fail-safe" \
  || no "K(AC1): the D-20 empty-array BLOCK was removed"

# --- L (capture-site structural): the iteration baseline is captured at worker
#     dispatch via the SAME snapshot helper + diff base as Gate 3, and a snapshot
#     failure must never CLEAR the baseline (that is the fail-OPEN direction). ---
grep -q 'typeset -g ITER_PREEXISTING_DIRTY' "$RUN" \
  && ok "L: ITER_PREEXISTING_DIRTY is declared global" || no "L: no typeset -g declaration"
grep -q 'ITER_PREEXISTING_DIRTY="\$_iter_pre"' "$RUN" \
  && ok "L: baseline assigned only from a successful snapshot" || no "L: no guarded assignment found"
grep -q '_iter_pre=\$(_git_snapshot -C "\$ROOT" diff --name-only "\$(_git_dirty_base)")' "$RUN" \
  && ok "L: capture uses _git_snapshot + _git_dirty_base (same base as Gate 3)" \
  || no "L: capture does not reuse the Gate 3 snapshot helper/base"
[[ "$(grep -c 'ITER_PREEXISTING_DIRTY=""' "$RUN")" == "1" ]] \
  && ok "L: exactly one initialization to empty (the t0 declaration) — no failure-path clear" \
  || no "L: ITER_PREEXISTING_DIRTY is cleared somewhere other than its declaration"
dispatch_blk=$(awk '/if \(\( ! SKIP_NEXT_WORKER \)\); then/,/update_status "worker" "running"/' "$RUN")
print -r -- "$dispatch_blk" | grep -q 'ITER_PREEXISTING_DIRTY' \
  && ok "L: capture sits inside the worker-dispatch block (per iteration, dispatch-only)" \
  || no "L: capture is not in the worker-dispatch block"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
