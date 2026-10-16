#!/usr/bin/env zsh
# W6 C-RE: init's evidence archive (`_arch_mv`) must reserve its runs/superseded-<ts>[-N]
# destination ATOMICALLY and must never overwrite an archived file.
#   A1  a destination dir that already exists (a concurrent init reserved it first, even
#       if still empty) is skipped: init reserves the next -N suffix and archives there.
#   A2  both the bare and the -2 dirs pre-exist -> -3.
#   A3  a same-name file already sitting in the freshly reserved dir (the lost-race
#       residue the old `mkdir -p` + `mv -f` silently overwrote) -> exit 4, the live
#       original stays in place, the planted file is intact.
#   A4  structure: _arch_mv has no `mkdir -p "$_arch_dir"` and no `mv -f`.
# `date` and `mkdir` are shimmed on PATH (fixed timestamp; A3 plants the file) so the
# would-be destination is known and the race residue is deterministic.
set -uo pipefail
REPO="${0:A:h:h}"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TS=20260101-000000

mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<SH
#!/bin/sh
if [ "\$*" = "+%Y%m%d-%H%M%S" ]; then echo $TS; else exec /bin/date "\$@"; fi
SH
# A3 hook: when PLANT_NAME is set, a freshly created runs/superseded-* dir gets a file of that name.
cat > "$TMP/bin/mkdir" <<'SH'
#!/bin/sh
/bin/mkdir "$@" || exit $?
eval "last=\${$#}"
case "$last" in
  */runs/superseded-*) [ -n "${PLANT_NAME:-}" ] && printf 'planted-by-race\n' > "$last/$PLANT_NAME" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/date" "$TMP/bin/mkdir"

mkproj() {
  local p="$TMP/$1"; mkdir -p "$p"
  ( cd "$p" && git init -q && git config user.email t@e.com && git config user.name t && git config commit.gpgsign false \
    && echo x > a && git add a && git commit -qm b && ROOT="$p" zsh "$INIT" slugx "first-objective" >/dev/null 2>&1 )
  P="$p"; LG="$p/.rlp-desk/logs/slugx"; M="$p/.rlp-desk/memos"
  printf 'seed-memory-%s\n' "$RANDOM" > "$M/slugx-memory.md"
  printf 'seed-baseline-%s\n' "$RANDOM" > "$LG/baseline.log"
  cp "$M/slugx-memory.md" "$p.memory.orig"; cp "$LG/baseline.log" "$p.baseline.orig"
}
run_init() { ( cd "$P" && PATH="$TMP/bin:$PATH" ROOT="$P" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); }

print -r -- "== A1: a pre-existing destination dir is skipped, never reused =="
mkproj a1; mkdir -p "$LG/runs/superseded-$TS"   # reserved by a concurrent init that has not moved anything yet
out=$(run_init); rc=$?
if (( rc == 0 )) && [[ -z "$(ls -A "$LG/runs/superseded-$TS")" ]] \
   && cmp -s "$P.memory.orig" "$LG/runs/superseded-$TS-2/slugx-memory.md" \
   && cmp -s "$P.baseline.orig" "$LG/runs/superseded-$TS-2/baseline.log"; then
  ok "A1 archive reserved superseded-$TS-2; the pre-existing (empty, reserved) dir stays empty"
else no "A1 rc=$rc dirs=$(ls "$LG/runs" 2>&1 | tr '\n' ' ') out=$(print -r -- "$out" | tail -3 | tr '\n' '|')"; fi

print -r -- "== A2: bare and -2 both taken -> -3 =="
mkproj a2; mkdir -p "$LG/runs/superseded-$TS" "$LG/runs/superseded-$TS-2"
out=$(run_init); rc=$?
if (( rc == 0 )) && cmp -s "$P.memory.orig" "$LG/runs/superseded-$TS-3/slugx-memory.md" \
   && [[ -z "$(ls -A "$LG/runs/superseded-$TS" "$LG/runs/superseded-$TS-2" | grep -v '^$' | grep -v ':$')" ]]; then
  ok "A2 archive reserved superseded-$TS-3; the two taken dirs stay empty"
else no "A2 rc=$rc dirs=$(ls "$LG/runs" 2>&1 | tr '\n' ' ')"; fi

print -r -- "== A3: a same-name file already in the reserved dir -> exit 4, original intact =="
mkproj a3
out=$( cd "$P" && PLANT_NAME=slugx-memory.md PATH="$TMP/bin:$PATH" ROOT="$P" zsh "$INIT" slugx "new-objective" --mode fresh 2>&1 ); rc=$?
dest="$LG/runs/superseded-$TS/slugx-memory.md"
if (( rc == 4 )) && cmp -s "$P.memory.orig" "$M/slugx-memory.md" \
   && [[ "$(cat "$dest" 2>/dev/null)" == planted-by-race ]]; then
  ok "A3 exit 4; the live memory file is still in place; the planted archive file was not overwritten"
else no "A3 rc=$rc live-intact=$(cmp -s "$P.memory.orig" "$M/slugx-memory.md" && echo y || echo n) planted=$(cat "$dest" 2>&1 | head -1)"; fi
[[ "$out" == *"ERROR: could not archive"* ]] && ok "A3 prints the ERROR line" || no "A3 no ERROR line"

print -r -- "== A4: _arch_mv structure =="
body=$(awk '/^_arch_mv\(\)/{p=1} p{print} p && /^}/{exit}' "$INIT")
if [[ -n "$body" ]] && ! print -r -- "$body" | grep -q 'mkdir -p "\$_arch_dir"' && ! print -r -- "$body" | grep -q 'mv -f'; then
  ok "A4 _arch_mv has no mkdir -p on the archive dir and no mv -f"
else no "A4 _arch_mv still uses mkdir -p \"\$_arch_dir\" or mv -f (or was not found)"; fi

print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
