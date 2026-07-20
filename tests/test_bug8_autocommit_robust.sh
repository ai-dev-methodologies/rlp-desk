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

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
