#!/usr/bin/env zsh
# IMP-01 — GNU/Linux stat mtime regression.
#
# lib_ralph_desk.zsh's recovery Check-5 and blocked-hygiene mtime sites were
# BSD-first (`stat -f %m || stat -c %Y`). On GNU coreutils, `stat -f %m`
# *succeeds* (prints filesystem info, not an mtime) so the `||` never falls
# through to `-c %Y` -> garbage non-numeric mtime feeds numeric comparisons.
# `_file_mtime` centralizes the GNU-first fix with a numeric guard.
#
# This test puts a `stat` shim on PATH ahead of the real `stat` to emulate a
# GNU host, sources the lib, and calls `_file_mtime` directly.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

tmpdir=$(mktemp -d)
testfile="$tmpdir/f.txt"
echo hello > "$testfile"
real_mtime=$(/usr/bin/stat -f %m "$testfile" 2>/dev/null)

# --- Scenario A: GNU-emulating shim — `stat -c %Y` succeeds with the real
#     numeric mtime; `stat -f %m` (wrongly tried first pre-fix) succeeds with
#     a non-numeric mount-info string, exit 0.
cat > "$tmpdir/stat" <<STAT_STUB
#!/usr/bin/env bash
if [[ "\$1" == "-c" && "\$2" == "%Y" ]]; then
  /usr/bin/stat -f %m "\$3" 2>/dev/null
  exit 0
elif [[ "\$1" == "-f" && "\$2" == "%m" ]]; then
  echo "/System/Volumes/Data 1234567 8388608"
  exit 0
fi
exit 1
STAT_STUB
chmod +x "$tmpdir/stat"

out_a=$(PATH="$tmpdir:$PATH" zsh --no-rcs --no-globalrcs -c '
  source "'"$LIB"'" 2>/dev/null
  _file_mtime "'"$testfile"'"
' 2>&1)
rc_a=$?

if [[ "$out_a" == *"command not found"* || "$out_a" == *"not found"* ]]; then
  no "_file_mtime not yet defined (expected pre-impl; run again after GREEN)"
elif [[ $rc_a -eq 0 && "$out_a" == "$real_mtime" ]]; then
  ok "GNU-shim: _file_mtime returns numeric real mtime ($out_a), not mount string"
else
  no "GNU-shim: expected numeric '$real_mtime', got '$out_a' (rc=$rc_a)"
fi

# --- Scenario B: numeric guard — `stat -c %Y` fails outright; `stat -f %m`
#     succeeds with a non-numeric mount-info string (garbage). `_file_mtime`
#     must guard against feeding that garbage to numeric comparisons and
#     fall back to 0, never a mount-info string.
cat > "$tmpdir/stat" <<'STAT_STUB2'
#!/usr/bin/env bash
if [[ "$1" == "-c" && "$2" == "%Y" ]]; then
  exit 1
elif [[ "$1" == "-f" && "$2" == "%m" ]]; then
  echo "/System/Volumes/Data 1234567 8388608"
  exit 0
fi
exit 1
STAT_STUB2
chmod +x "$tmpdir/stat"

out_b=$(PATH="$tmpdir:$PATH" zsh --no-rcs --no-globalrcs -c '
  source "'"$LIB"'" 2>/dev/null
  _file_mtime "'"$testfile"'"
' 2>&1)

if [[ "$out_b" == "0" ]]; then
  ok "numeric guard: garbage mount-string result falls back to 0"
else
  no "numeric guard: expected '0', got '$out_b'"
fi

rm -rf "$tmpdir"

print ""
if (( FAIL == 0 )); then print "imp01-stat-mtime-gnu: $PASS/$((PASS+FAIL)) PASS"; else print "imp01-stat-mtime-gnu: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
