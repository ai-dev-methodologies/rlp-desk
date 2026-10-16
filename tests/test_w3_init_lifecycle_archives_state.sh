#!/usr/bin/env zsh
# W3 Q5 (security-init-a5 F-08): the PRD-present `init --mode fresh|improve` lifecycle
# must ARCHIVE campaign state exactly like the no-PRD fallback (addendum-5), never
# bare-delete it. `.rlp-desk/` is gitignored, so a deleted cost log or memory is gone.
#
# Six files are in scope: runtime/status.json, status.json, baseline.log,
# cost-log.jsonl (formerly `rm`), memory.md and latest.md (formerly `rm -f`).
#   Q1  fresh: all six archived byte-identical in ONE runs/superseded-*/ dir
#       (runtime/status.json stored as runtime-status.json), live paths emptied,
#       memory/latest regenerated clean.
#   Q2  improve: same lifecycle, same result.
#   Q3  a failed move (context/ read-only) exits 4 BEFORE any destructive step: the
#       five earlier files are in the archive, latest.md and the prompt
#       templates keep their live bytes.
#   Q4  a failed archive dir (logs/<slug>/ read-only) exits non-zero with every
#       original untouched.
#   Q5  none of the six files present: init succeeds, no archive dir is created.
#   Q6  the lifecycle block holds no `rm` command word naming any of the six files.
set -uo pipefail
REPO="${0:A:h:h}"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# mkproj <label>: a project with an initialized slug, so the PRD exists (PRD-present lifecycle).
mkproj() {
  local p="$TMP/$1"; mkdir -p "$p"
  ( cd "$p" && git init -q && git config user.email t@e.com && git config user.name t && git config commit.gpgsign false \
    && echo x > a && git add a && git commit -qm b && ROOT="$p" zsh "$INIT" slugx "first-objective" >/dev/null 2>&1 )
  print -r -- "$p"
}
# seed6 <project>: the six state files with DISTINCT contents; originals copied to <project>.orig/<archive name>.
seed6() {
  local p="$1" i
  LG="$p/.rlp-desk/logs/slugx"; M="$p/.rlp-desk/memos"; C="$p/.rlp-desk/context"; ORIG="$p.orig"
  mkdir -p "$LG/runtime" "$ORIG"
  ANAMES=(runtime-status.json status.json baseline.log cost-log.jsonl slugx-memory.md slugx-latest.md)
  LIVEALL=("$LG/runtime/status.json" "$LG/status.json" "$LG/baseline.log" "$LG/cost-log.jsonl" "$M/slugx-memory.md" "$C/slugx-latest.md")
  for i in {1..6}; do
    printf 'seed-%s-%s%s\n' "${ANAMES[$i]}" "$RANDOM" "$RANDOM" > "${LIVEALL[$i]}"
    cp "${LIVEALL[$i]}" "$ORIG/${ANAMES[$i]}"
  done
}
archive_dirs() { ARCH=( "$LG"/runs/superseded-*(N/) ); }
# arch_has <dir> <names...>: each name exists in dir byte-identical to ORIG
arch_has() {
  local d="$1"; shift; local n
  for n in "$@"; do cmp -s "$ORIG/$n" "$d/$n" || { WHY="$n missing or differs in ${d:t}"; return 1; }; done
  return 0
}
regen_clean() {
  cmp -s "$M/slugx-memory.md" "$ORIG/slugx-memory.md" && { WHY="old memory still live"; return 1; }
  cmp -s "$C/slugx-latest.md" "$ORIG/slugx-latest.md" && { WHY="old latest still live"; return 1; }
  [[ -f "$M/slugx-memory.md" && -f "$C/slugx-latest.md" ]] || { WHY="memory/latest not regenerated"; return 1; }
  return 0
}

for md in fresh improve; do
  id=$([[ $md == fresh ]] && echo Q1 || echo Q2)
  print -r -- "== $id: PRD-present --mode $md archives the six state files =="
  p=$(mkproj "$md"); seed6 "$p"
  out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode "$md" 2>&1 ); rc=$?
  archive_dirs; WHY=""
  live_gone=0; for f in "${LIVEALL[@]:0:4}"; do [[ ! -e "$f" ]] && live_gone=$((live_gone+1)); done
  if (( rc == 0 )) && (( ${#ARCH} == 1 )) && arch_has "${ARCH[1]}" "${ANAMES[@]}" && (( live_gone == 4 )) && regen_clean; then
    ok "$id rc=0; the six files are byte-identical in one archive dir; the 4 state files left the live paths; memory/latest regenerated clean"
  else
    no "$id rc=$rc archive-dirs=${#ARCH} live-state-gone=$live_gone/4 ${WHY}"
  fi
  [[ "$out" == *"Archived:  "*"evidence artifact(s)"* ]] \
    && ok "$id the summary reports the archived artifacts" || no "$id no 'Archived:' summary line"
done

print -r -- "== Q3: a failed move (context/ read-only) exits 4 before any destructive step =="
if [[ $EUID -eq 0 ]]; then
  no "Q3 needs a non-root user (root ignores chmod 555)"; no "Q4 needs a non-root user (see Q3)"
else
  p=$(mkproj q3); seed6 "$p"
  print -r -- "MARKER-keep-me" >> "$p/.rlp-desk/prompts/slugx.worker.prompt.md"
  marker_before=$(cat "$p/.rlp-desk/prompts/slugx.worker.prompt.md")
  chmod 555 "$C"
  out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
  chmod 755 "$C"; archive_dirs; WHY=""
  if (( rc == 4 )) && [[ "$out" == *"ERROR"* && "$out" == *"slugx-latest.md"* ]] && (( ${#ARCH} == 1 )) \
     && arch_has "${ARCH[1]}" "${ANAMES[@]:0:5}" && cmp -s "$ORIG/slugx-latest.md" "$C/slugx-latest.md" \
     && [[ "$(cat "$p/.rlp-desk/prompts/slugx.worker.prompt.md")" == "$marker_before" ]]; then
    ok "Q3 exit 4 naming latest.md; the 5 earlier files are archived intact; latest.md and the worker prompt keep their live bytes"
  else
    no "Q3 rc=$rc (want 4) archive-dirs=${#ARCH} ${WHY} latest-live=$([[ -f $C/slugx-latest.md ]] && echo yes || echo no) prompt-intact=$([[ "$(cat "$p/.rlp-desk/prompts/slugx.worker.prompt.md")" == "$marker_before" ]] && echo yes || echo no)"
  fi

  print -r -- "== Q4: an unwritable archive location exits non-zero, originals untouched =="
  p=$(mkproj q4); seed6 "$p"
  chmod 555 "$LG"
  out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
  chmod 755 "$LG"; archive_dirs
  intact=0; for i in {1..6}; do cmp -s "$ORIG/${ANAMES[$i]}" "${LIVEALL[$i]}" && intact=$((intact+1)); done
  if (( rc != 0 )) && (( intact == 6 )) && (( ${#ARCH} == 0 )) && [[ "$out" == *"ERROR"* ]]; then
    ok "Q4 rc=$rc, all six originals untouched, no archive dir"
  else
    no "Q4 rc=$rc (want non-zero) intact=$intact/6 archive-dirs=${#ARCH} error-printed=$([[ "$out" == *ERROR* ]] && echo yes || echo no)"
  fi
fi

print -r -- "== Q5: none of the six present is not an error =="
p=$(mkproj q5)
rm -f "$p/.rlp-desk/memos/slugx-memory.md" "$p/.rlp-desk/context/slugx-latest.md"
LG="$p/.rlp-desk/logs/slugx"
rm -f "$LG/status.json" "$LG/baseline.log" "$LG/cost-log.jsonl" "$LG/runtime/status.json"
out=$( cd "$p" && ROOT="$p" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
archive_dirs
if (( rc == 0 )) && (( ${#ARCH} == 0 )) && [[ -f "$p/.rlp-desk/memos/slugx-memory.md" ]]; then
  ok "Q5 rc=0, no archive dir, memory regenerated"
else
  no "Q5 rc=$rc archive-dirs=${#ARCH}"
fi

print -r -- "== Q6: no bare rm of the six files in the lifecycle block =="
# Two shapes: a `for f in ... baseline.log|cost-log ...; do` loop whose body is an rm, and an rm naming memory/latest.
hits=$(awk '/Re-execution mode: --mode/{f=1} /Re-execution summary/{f=0} f' "$INIT" | grep -v '^[[:space:]]*#' \
  | perl -0ne 'my $n=0; $n++ while /for \w+ in[^\n]*(?:baseline\.log|cost-log)[^\n]*\n[^\n]*\brm\b/g; $n++ while /\brm\b[^\n]*(?:memory\.md|latest\.md)/g; print $n')
[[ "$hits" == 0 ]] && ok "Q6 the lifecycle block has no rm command naming the six state files" \
  || no "Q6 the lifecycle block still has $hits rm line(s) for state files"

print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
