#!/usr/bin/env zsh
# IMP-09 — paste_to_pane must not write a predictable world-readable /tmp file,
# and must never touch the runner's global EXIT trap.
#
# The old paste_to_pane wrote prompt text to /tmp/.rlp-desk-paste-$$.tmp via
# `>` (PID-predictable, umask perms, follows a pre-planted symlink → content
# leak + clobber on shared hosts). This is the HOT path on every worker/verifier
# dispatch. The fix pipes via `tmux load-buffer -` (stdin, no temp file); a
# probe-fail fallback uses a 0600 mktemp with INLINE cleanup (never an EXIT
# trap — that would overwrite the runner's global `_emit_final_cost_log;
# cleanup` EXIT trap, codex B2).
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

# Extract paste_to_pane from the source (brace-balanced).
_extract_fn() {
  awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1;d=0}
    f{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="{")d++;else if(c=="}"){d--;if(d==0){print;f=0;next}}}print}' "$2"
}

# ---- Scenario A: stdin path (tmux supports `load-buffer -`) ----
run_stdin() {
  local tmpdir; tmpdir=$(mktemp -d)
  local body; body=$(_extract_fn paste_to_pane "$RUN")
  cat > "$tmpdir/tmux" <<'STUB'
#!/usr/bin/env bash
# records: load-buffer stdin → $REC; probe (__probe) succeeds.
case "$1 $2" in
  "load-buffer -b") shift 2
    if [[ "$1" == "__probe" ]]; then exit 0; fi ;;
esac
# find the trailing "-" (stdin) form and capture stdin
for a in "$@"; do :; done
if [[ "${@: -1}" == "-" ]]; then cat > "$REC"; fi
exit 0
STUB
  chmod +x "$tmpdir/tmux"
  { echo 'tmux(){ command "$HDIR/tmux" "$@"; }'
    print -r -- "$body"
    echo 'paste_to_pane "pane-1" "hello-世界"'
  } > "$tmpdir/h.zsh"
  HDIR="$tmpdir" REC="$tmpdir/rec" zsh --no-rcs "$tmpdir/h.zsh" 2>/dev/null
  local buf; buf=$(cat "$tmpdir/rec" 2>/dev/null)
  local leaked; leaked=$(print -rn -- /tmp/.rlp-desk-paste-*(N) | wc -w | tr -d " ")
  print "buf=$buf leaked=$leaked"
  rm -rf "$tmpdir"
}

out=$(run_stdin)
[[ "$out" == *"buf=hello-世界"* ]] && ok "stdin: multibyte prompt lands in the tmux buffer" || no "stdin: buffer content wrong ($out)"
[[ "$out" == *"leaked=0"* ]] && ok "stdin: no world-readable /tmp paste file left" || no "stdin: a /tmp paste file leaked ($out)"

# EXIT-trap invariance on the stdin path.
run_trap_stdin() {
  local tmpdir; tmpdir=$(mktemp -d); local body; body=$(_extract_fn paste_to_pane "$RUN")
  cat > "$tmpdir/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "$3" == "__probe" ]]; then exit 0; fi
if [[ "${@: -1}" == "-" ]]; then cat >/dev/null; fi
exit 0
STUB
  chmod +x "$tmpdir/tmux"
  { echo 'tmux(){ command "$HDIR/tmux" "$@"; }'
    echo "trap 'echo X' EXIT"
    echo 'B=$(trap -p EXIT)'
    print -r -- "$body"
    echo 'paste_to_pane "p1" "hi"'
    echo 'A=$(trap -p EXIT)'
    echo '[[ "$B" == "$A" ]] && echo TRAP_OK || echo TRAP_CHANGED'
  } > "$tmpdir/h.zsh"
  HDIR="$tmpdir" zsh --no-rcs "$tmpdir/h.zsh" 2>/dev/null | grep -E 'TRAP_(OK|CHANGED)'
  rm -rf "$tmpdir"
}
[[ "$(run_trap_stdin)" == "TRAP_OK" ]] && ok "stdin: global EXIT trap unchanged by paste_to_pane" || no "stdin: paste_to_pane clobbered the global EXIT trap"

# ---- Scenario B: probe-fail fallback (tmux rejects `load-buffer -`) ----
run_fallback() {
  local tmpdir; tmpdir=$(mktemp -d); local body; body=$(_extract_fn paste_to_pane "$RUN")
  cat > "$tmpdir/tmux" <<'STUB'
#!/usr/bin/env bash
# Reject the stdin `-` form (incl. the probe) → forces the mktemp fallback.
# Accept the FILE form and record the file's perms + content.
if [[ "${@: -1}" == "-" ]]; then exit 1; fi
if [[ "$1" == "load-buffer" ]]; then
  f="${@: -1}"
  if [[ -f "$f" ]]; then
    stat -f '%Lp' "$f" 2>/dev/null > "$REC.mode" || stat -c '%a' "$f" > "$REC.mode"
    cat "$f" > "$REC"
  fi
fi
exit 0
STUB
  chmod +x "$tmpdir/tmux"
  { echo 'tmux(){ command "$HDIR/tmux" "$@"; }'
    echo "trap 'echo X' EXIT"
    echo 'B=$(trap -p EXIT)'
    print -r -- "$body"
    echo 'paste_to_pane "p1" "fallback-世界"'
    echo 'A=$(trap -p EXIT)'
    echo '[[ "$B" == "$A" ]] && echo TRAP_OK || echo TRAP_CHANGED'
  } > "$tmpdir/h.zsh"
  local trapline; trapline=$(HDIR="$tmpdir" REC="$tmpdir/rec" zsh --no-rcs "$tmpdir/h.zsh" 2>/dev/null | grep -E 'TRAP_(OK|CHANGED)')
  local buf mode leaked
  buf=$(cat "$tmpdir/rec" 2>/dev/null); mode=$(cat "$tmpdir/rec.mode" 2>/dev/null)
  leaked=$(print -rn -- /tmp/.rlp-desk-paste-*(N) | wc -w | tr -d " ")
  print "buf=$buf mode=$mode leaked=$leaked trap=$trapline"
  rm -rf "$tmpdir"
}
fb=$(run_fallback)
[[ "$fb" == *"buf=fallback-世界"* ]] && ok "fallback: content lands via 0600 mktemp path" || no "fallback: content wrong ($fb)"
[[ "$fb" == *"mode=600"* ]] && ok "fallback: temp file is 0600 (not world-readable)" || no "fallback: temp file not 0600 ($fb)"
[[ "$fb" == *"leaked=0"* ]] && ok "fallback: temp file cleaned up inline (no lingering file)" || no "fallback: temp file leaked ($fb)"
[[ "$fb" == *"trap=TRAP_OK"* ]] && ok "fallback: global EXIT trap unchanged (no EXIT trap installed)" || no "fallback: EXIT trap clobbered ($fb)"

print ""
if (( FAIL == 0 )); then print "imp09-paste-no-tmpfile: $PASS/$((PASS+FAIL)) PASS"; else print "imp09-paste-no-tmpfile: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
