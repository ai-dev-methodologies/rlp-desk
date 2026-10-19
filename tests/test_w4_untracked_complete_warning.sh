#!/usr/bin/env zsh
# W4 / F5 — advisory warning when a campaign reaches COMPLETE with untracked
# deliverables (judge-a4 F5: completeness is LLM-judged and the §1f½ commit
# oracle is a no-op when no commit is claimed).
#
# Owner decision 2026-10-14: WARNING ONLY. The leader snapshots git-untracked,
# not-ignored files at campaign start (_untracked_snapshot_t0) and, on COMPLETE
# in cleanup(), logs ONE line + appends the same line to campaign-report.md for
# files that appeared during the campaign (_untracked_complete_warning). It
# never blocks, never changes the verdict or the exit status.
#
# The REAL functions are extracted from run_ralph_desk.zsh / lib_ralph_desk.zsh
# (never a mirror) and driven in a clean zsh against real temp git repos.
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Extract the REAL implementation --------------------------------------
EX="$TMP/extract.zsh"
{
  # C-01: _untracked_names runs git via the lib's fork-safe _sigsafe_sh and removes its temp file with zf_rm.
  print -r -- 'zmodload -F zsh/files b:zf_rm 2>/dev/null'
  grep '^_sigsafe_sh()'                          "$LIB"
  grep '^typeset -g _UNTRACKED_NAMES='           "$RUN"
  awk '/^_untracked_names\(\)/,/^}$/'            "$RUN"
  awk '/^_untracked_snapshot_t0\(\)/,/^}$/'      "$RUN"
  awk '/^_untracked_complete_warning\(\)/,/^}$/' "$RUN"
} > "$EX"
for fn in _untracked_names _untracked_snapshot_t0 _untracked_complete_warning; do
  grep -q "^$fn()" "$EX" || { no "$fn not extracted (must be defined at column 0 in run_ralph_desk.zsh)"; }
done

mkrepo() { # $1=dir — committed baseline + .gitignore, with a desk dir
  local r="$1"; mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false
  print -r -- base > "$r/a.txt"; print -r -- '*.ignored' > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm base
}

# drive <root> <mutation-snippet> <sentinel: complete|blocked|none>
# Runs: t0 snapshot -> mutation (run with cwd=root) -> terminal state ->
# warning function (the cleanup() call). Prints, on stdout:
#   LOG:<line>            every log() call
#   REPORT:<line>         every line of campaign-report.md after the call
#   RC:<n>                the warning function's return code
#   ERR:<stderr text>     anything written to stderr
drive() {
  local root="$1" mutate="$2" state="$3"
  local logs; logs=$(mktemp -d "$TMP/logs-XXXXXX")   # mktemp: $RANDOM repeats across $(...) subshells
  print -r -- "# Campaign Report" > "$logs/campaign-report.md"
  zsh --no-rcs -c '
    set -u
    ROOT="$1"; DESK="$1/.rlp-desk"; LOGS_DIR="$2"; MUTATE="$3"; STATE="$4"
    COMPLETE_SENTINEL="$2/complete.md"; BLOCKED_SENTINEL="$2/blocked.md"
    log(){ print -r -- "LOG:$*"; }
    log_debug(){ print -r -- "DBG:$*" >> "$LOGS_DIR/debug.txt"; }
    log_error(){ print -r -- "ERRLOG:$*" >&2; }
    source "'"$EX"'"
    _untracked_snapshot_t0
    ( cd "$ROOT" && eval "$MUTATE" )
    case "$STATE" in complete) : > "$COMPLETE_SENTINEL";; blocked) : > "$BLOCKED_SENTINEL";; esac
    _untracked_complete_warning
    print -r -- "RC:$?"
    sed "s/^/REPORT:/" "$LOGS_DIR/campaign-report.md"
  ' _ "$root" "$logs" "$mutate" "$state" 2>"$logs/stderr.txt"
  print -r -- "ERR:$(cat "$logs/stderr.txt")"
}

has() { print -r -- "$1" | grep -qF -- "$2"; }
count() { print -r -- "$1" | grep -c -- "$2" || true; }

print -r -- "== new untracked file created during campaign -> warning =="
R="$TMP/r1"; mkrepo "$R"
out=$(drive "$R" 'print -r -- x > deliverable.txt' complete)
has "$out" "LOG:" && has "$out" "deliverable.txt" && ok "log warning names the new path" || no "no log warning naming deliverable.txt: $out"
[[ $(count "$out" "^LOG:.*WARNING") == 1 ]] && ok "exactly ONE log warning line" || no "expected exactly one LOG WARNING line: $out"
# R2-H: the comparison is "untracked now" vs "untracked at t0" — it cannot know a file was CREATED (an ignored file
# that became un-ignored, or a tracked file that became untracked, shows up the same way).
has "$out" "became untracked during the campaign" && ok "R2-H wording: the warning says the file(s) became untracked during the campaign" || no "R2-H wording missing: $out"
has "$out" "created during the campaign" && no "R2-H: warning still overstates provenance (\"created during the campaign\")" || ok "R2-H: no \"created during the campaign\" claim"
has "$out" "REPORT:" && print -r -- "$out" | grep "^REPORT:" | grep -qF "deliverable.txt" && ok "campaign-report.md carries the same warning" || no "report missing warning: $out"
has "$out" "RC:0" && ok "warning function returns 0" || no "non-zero rc: $out"
print -r -- "$out" | grep "^LOG:" | grep -q "1 " && ok "count reported" || no "count missing"

print -r -- "== file untracked BEFORE campaign start -> no warning =="
R="$TMP/r2"; mkrepo "$R"; print -r -- pre > "$R/preexisting.txt"
out=$(drive "$R" ':' complete)
has "$out" "WARNING" && no "pre-existing untracked file warned: $out" || ok "no warning for pre-start untracked file"
has "$out" "RC:0" && ok "rc 0" || no "rc: $out"

print -r -- "== pre-existing + new -> only the new one is named =="
R="$TMP/r2b"; mkrepo "$R"; print -r -- pre > "$R/preexisting.txt"
out=$(drive "$R" 'print -r -- n > newfile.txt' complete)
has "$out" "newfile.txt" && ! has "$out" "preexisting.txt" && ok "only newfile.txt named" || no "wrong set: $out"

print -r -- "== gitignored file -> no warning =="
R="$TMP/r3"; mkrepo "$R"
out=$(drive "$R" 'print -r -- x > cruft.ignored' complete)
has "$out" "WARNING" && no "ignored file warned: $out" || ok "no warning for gitignored file"

print -r -- "== .rlp-desk/ files -> no warning =="
R="$TMP/r4"; mkrepo "$R"
out=$(drive "$R" 'mkdir -p .rlp-desk/logs/s .rlp-desk/memos; print -r -- x > .rlp-desk/logs/s/iter-001.json; print -r -- y > .rlp-desk/memos/m.md' complete)
has "$out" "WARNING" && no ".rlp-desk files warned: $out" || ok "no warning for desk dir files"

print -r -- "== desk files do not mask a real deliverable =="
R="$TMP/r4b"; mkrepo "$R"
out=$(drive "$R" 'mkdir -p .rlp-desk/logs; print -r -- x > .rlp-desk/logs/a.json; print -r -- d > src_new.txt' complete)
has "$out" "src_new.txt" && ! has "$out" ".rlp-desk" && ok "real deliverable named, desk file not" || no "wrong set: $out"

print -r -- "== non-git dir -> no warning, no error, rc 0 =="
N="$TMP/nogit"; mkdir -p "$N"
out=$(drive "$N" 'print -r -- x > f.txt' complete)
has "$out" "WARNING" && no "non-git warned: $out" || ok "no warning in a non-git dir"
has "$out" "RC:0" && ok "rc 0 in non-git dir" || no "rc: $out"
[[ "$out" == *"ERR:" && -z "$(print -r -- "$out" | sed -n 's/^ERR://p' | tr -d '[:space:]')" ]] && ok "no stderr noise in non-git dir" || no "stderr noise: $out"

print -r -- "== more than 10 new files -> count + at most 10 paths =="
R="$TMP/r5"; mkrepo "$R"
out=$(drive "$R" 'for i in 01 02 03 04 05 06 07 08 09 10 11 12; do print -r -- x > "n$i.txt"; done' complete)
line=$(print -r -- "$out" | grep '^LOG:.*WARNING')
[[ $(print -r -- "$line" | grep -o 'n[0-9][0-9]\.txt' | wc -l | tr -d ' ') == 10 ]] && ok "exactly 10 paths listed" || no "path count != 10: $line"
print -r -- "$line" | grep -q '12' && ok "total count 12 reported" || no "total 12 missing: $line"

print -r -- "== BLOCKED campaign -> no warning (COMPLETE only) =="
R="$TMP/r6"; mkrepo "$R"
out=$(drive "$R" 'print -r -- x > d.txt' blocked)
has "$out" "WARNING" && no "BLOCKED warned: $out" || ok "no warning when not COMPLETE"

print -r -- "== verdict/exit status unchanged: sentinel untouched, rc 0 =="
R="$TMP/r7"; mkrepo "$R"
L="$TMP/logs-r7"; mkdir -p "$L"; : > "$L/complete.md"
zsh --no-rcs -c '
  set -u
  ROOT="$1"; DESK="$1/.rlp-desk"; LOGS_DIR="$2"
  COMPLETE_SENTINEL="$2/complete.md"; BLOCKED_SENTINEL="$2/blocked.md"
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  source "'"$EX"'"
  _untracked_snapshot_t0
  print -r -- x > "$ROOT/new.txt"
  _untracked_complete_warning
  rc=$?
  [[ -f "$COMPLETE_SENTINEL" && ! -f "$BLOCKED_SENTINEL" ]] && print "SENTINEL_OK" || print "SENTINEL_CHANGED"
  print "RC=$rc"
' _ "$R" "$L" >"$TMP/r7.out" 2>&1
grep -q SENTINEL_OK "$TMP/r7.out" && grep -q 'RC=0' "$TMP/r7.out" && ok "COMPLETE sentinel intact, rc 0 with untracked deliverable" || no "verdict disturbed: $(cat "$TMP/r7.out")"

print -r -- "== integration: REAL generate_campaign_report then warning (cleanup order) =="
R="$TMP/r8"; mkrepo "$R"; L="$TMP/logs-r8"; mkdir -p "$L"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  source "'"$EX"'"
  log(){ print -r -- "LOG:$*"; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="$1"; LOGS_DIR="$2"; DESK="$1/.rlp-desk"; SLUG="w4"
  ITERATION=1; MAX_ITER=1; START_TIME=$(date +%s)
  COST_LOG="$2/cost-log.jsonl"; CAMPAIGN_REPORT_GENERATED=0
  COMPLETE_SENTINEL="$2/complete.md"; BLOCKED_SENTINEL="$2/blocked.md"; : > "$COMPLETE_SENTINEL"
  WITH_SELF_VERIFICATION=0; WITH_SELF_VERIFICATION_REQUESTED=0
  WORKER_MODEL=w; WORKER_ENGINE=we; VERIFIER_MODEL=v; VERIFIER_ENGINE=ve
  CONSENSUS_MODE=cm; CONSENSUS_MODEL=cmm; FINAL_CONSENSUS_MODEL=fcm
  VERIFIED_US="US-001"; CONSECUTIVE_FAILURES=0
  _untracked_snapshot_t0
  print -r -- x > "$ROOT/late-deliverable.txt"
  generate_campaign_report
  _untracked_complete_warning
  grep -c "late-deliverable.txt.*" "$LOGS_DIR/campaign-report.md" | sed "s/^/REPORTHITS:/"
  grep -n "Untracked new files" "$LOGS_DIR/campaign-report.md" | head -1 | sed "s/^/LIBSEC:/"
' _ "$R" "$L" 2>&1)
has "$out" "LOG:" && has "$out" "late-deliverable.txt" && ok "log line emitted after real report generation" || no "no log line: $out"
print -r -- "$out" | grep '^REPORTHITS:' | grep -qv 'REPORTHITS:0' && ok "real campaign-report.md contains the warning" || no "report lacks warning: $out"
grep -q "WARNING" "$L/campaign-report.md" && ok "report has an advisory WARNING line" || no "report has no WARNING line"

print -r -- "== structural: wiring + governance =="
snap_line=$(grep -n '^  _untracked_snapshot_t0' "$RUN" | head -1 | cut -d: -f1)
dirty_line=$(grep -n 'CAMPAIGN_PREEXISTING_DIRTY=$(_git_dirty_names' "$RUN" | head -1 | cut -d: -f1)
[[ -n "$snap_line" && -n "$dirty_line" && "$snap_line" -gt "$dirty_line" ]] && ok "t0 snapshot taken after the preexisting-dirty t0 snapshot in main()" || no "t0 snapshot call not wired in main() (snap=$snap_line dirty=$dirty_line)"
cl=$(sed -n '/^cleanup() {$/,/^}$/p' "$RUN")
gen_line=$(print -r -- "$cl" | grep -n 'generate_campaign_report' | head -1 | cut -d: -f1)
warn_line=$(print -r -- "$cl" | grep -n '_untracked_complete_warning' | head -1 | cut -d: -f1)
[[ -n "$gen_line" && -n "$warn_line" && "$warn_line" -gt "$gen_line" ]] && ok "cleanup() calls the warning after generate_campaign_report" || no "cleanup wiring missing/misordered (gen=$gen_line warn=$warn_line)"
print -r -- "$cl" | grep -B6 '_untracked_complete_warning' | grep -q '_skip_campaign_artifacts' && ok "warning sits inside the campaign-artifacts guard (no duplicate-runner noise)" || no "warning not under _skip_campaign_artifacts guard"
grep -qi 'untracked' "$GOV" && grep -n 'advisory' "$GOV" | grep -qi 'untracked' && ok "governance.md states the untracked-at-COMPLETE warning is advisory" || no "governance.md missing the advisory untracked warning sentence"

print -r -- ""
print -r -- "w4 untracked-complete-warning: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
