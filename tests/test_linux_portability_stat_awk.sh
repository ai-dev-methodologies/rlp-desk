#!/bin/zsh
# ============================================================================
# Linux portability defects found by the ubuntu:24.04 verification (backlog 2026-10-25 item 3):
#
# L-1  run_ralph_desk.zsh anchored the recovered done-claim freshness window with a BSD-first
#      `stat -f %m F || stat -c %Y F`. On GNU coreutils `stat -f` is the FILESYSTEM report mode, so the
#      chain yields a multi-line blob (or fails) instead of an epoch and ITER_WINDOW_START ends up empty.
#      Contract: the epoch comes from the GNU-first, numerically guarded _file_mtime helper.
# L-2  lib_ralph_desk.zsh awk programs used the regex interval `^#{2,3}`. mawk (Ubuntu's default awk)
#      has no interval expressions: `{2,3}` is matched literally, so every `### US-` story counted 0 ACs,
#      the density lint was silently skipped and the 3-doc lint printed false advisories.
#      Contract: no awk program under src/scripts uses `{n}` / `{n,m}` (static), and the functions give
#      the right answers when awk treats braces literally (an awk shim that emulates exactly that).
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
SCRIPT_DIR="${0:A:h}"; ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"
LIB="${RLP_TEST_LIB_SCRIPT:-$ROOT_DIR/src/scripts/lib_ralph_desk.zsh}"
[[ -f "$RUN" && -f "$LIB" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/linux-port.XXXXXX"); trap 'rm -rf "$TMPD"' EXIT
REAL_PATH="$PATH"

# ---------------------------------------------------------------- L-1
print "== L-1: done-claim window epoch on GNU stat (stat -f = filesystem report) =="
mkdir -p "$TMPD/gnu-bin"
cat > "$TMPD/gnu-bin/stat" <<'SHIM'
#!/bin/sh
# GNU coreutils stat emulation. `-f` is filesystem-status mode: it treats every operand as a path, so
# `-f %m FILE` reports on FILE and complains about the file system of the "file" named %m.
case "$1" in
  -c) [ "$2" = "%Y" ] && [ -e "$3" ] && { echo 1700000000; exit 0; }; echo "stat: bad usage" >&2; exit 1 ;;
  -f) shift
      for a in "$@"; do
        case "$a" in -*) ;; %*) echo "stat: cannot read file system information for '$a': No such file or directory" >&2; rc=1 ;;
          *) printf '  File: "%s"\n    ID: 0        Namelen: 255     Type: ext2/ext3\nBlock size: 4096       Fundamental block size: 4096\nBlocks: Total: 100  Free: 50   Available: 50\nInodes: Total: 100  Free: 50\n' "$a" ;; esac
      done; exit ${rc:-0} ;;
esac
exit 1
SHIM
chmod +x "$TMPD/gnu-bin/stat"
# the real code path: the block that anchors ITER_WINDOW_START on the preserved done-claim's mtime
BLOCK=$(awk '/if \[\[ -z "\$\{ITER_WINDOW_START:-\}" && -f "\$DONE_CLAIM_FILE" \]\]; then/{f=1} f{print} f && /^        fi$/{exit}' "$RUN")
[[ -n "$BLOCK" ]] && ok "extracted the ITER_WINDOW_START anchoring block from $RUN" || { no "could not extract the anchoring block"; BLOCK=":"; }
eval "$(awk '$0 ~ /^_file_mtime\(\) \{/{f=1} f{print} f && /^}/{exit}' "$LIB")"
_run_block() { # $1 = PATH to use
  eval "_blk() { local DONE_CLAIM_FILE='$TMPD/done-claim.json'; ITER_WINDOW_START=''; $BLOCK
    print -r -- \"\$ITER_WINDOW_START\"; }"
  : > "$TMPD/done-claim.json"
  ( PATH="$1"; _blk )
}
got=$(_run_block "$TMPD/gnu-bin:$REAL_PATH")
want="2023-11-14T22:13:20Z"   # 1700000000
[[ "$got" == "$want" ]] && ok "GNU stat shim: ITER_WINDOW_START = $got (numeric epoch window)" \
  || no "GNU stat shim: ITER_WINDOW_START is '$(print -r -- "$got" | head -c 120 | tr '\n' '|')', want $want"
got=$(_run_block "$REAL_PATH")
[[ "$got" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] && ok "native stat: ITER_WINDOW_START = $got" || no "native stat: ITER_WINDOW_START='$got'"
BAD=$(grep -nE 'stat -f %m[^|]*\|\| *stat -c' "$RUN" "$LIB" | head -3)
[[ -z "$BAD" ]] && ok "no BSD-first 'stat -f %m ... || stat -c' chain left in src/scripts" || no "BSD-first stat chain still present: $BAD"

# ---------------------------------------------------------------- L-2
print "== L-2: no awk interval expressions in src/scripts (mawk has none) =="
bad=$(perl -0777 -ne 'while (/\bawk\b[^\x27]*\x27([^\x27]*)\x27/g) { my $p=$1; while ($p =~ /(?<![\\\$\w])\{\d+(?:,\d*)?\}/g) { print "$ARGV: awk program uses an interval: $&\n" } }' "$ROOT_DIR"/src/scripts/*.zsh 2>&1)
[[ -z "$bad" ]] && ok "no awk program under src/scripts uses {n}/{n,m}" || no "awk interval expressions: $bad"

print "== L-2: behaviour when awk matches braces literally (mawk emulation) =="
mkdir -p "$TMPD/mawk-bin"
cat > "$TMPD/mawk-bin/awk" <<'SHIM'
#!/bin/sh
# mawk 1.3.4 has no regex intervals: `{n,m}` matches the literal text. Emulate with a bracket expression (valid in regex literals and strings).
n=$#; i=0
while [ $i -lt $n ]; do
  a=$1; shift
  a=$(printf '%s' "$a" | perl -pe 's/(?<!\\)\{(\d+(?:,\d*)?)\}/[{]${1}[}]/g')
  set -- "$@" "$a"; i=$((i+1))
done
exec /usr/bin/awk "$@"
SHIM
chmod +x "$TMPD/mawk-bin/awk"
[[ -x /usr/bin/awk ]] || sed -i.bak 's#/usr/bin/awk#/bin/awk#' "$TMPD/mawk-bin/awk"
P="$TMPD/plans"; mkdir -p "$P"
printf '### US-001: First\n- AC1: a\n- AC2: b\n### US-002: Second\n- AC1: c\n' > "$P/prd.md"
printf '## US-001: First\n- verify AC1\n- verify AC2\n## US-002: Second\n- verify AC1\n' > "$P/spec.md"
source "$LIB" 2>/dev/null
log(){ :; }; log_error(){ :; }; log_warn(){ :; }; log_debug(){ :; }
export PATH="$TMPD/mawk-bin:$REAL_PATH"
[[ "$(_prd_us_ac_count "$P/prd.md" US-001)" == 2 ]] && ok "_prd_us_ac_count counts the 2 ACs of a ### story" || no "_prd_us_ac_count US-001 = '$(_prd_us_ac_count "$P/prd.md" US-001)' (want 2)"
[[ "$(_prd_us_ac_ids "$P/prd.md" US-001 | tr '\n' ' ')" == "AC1 AC2 " ]] && ok "_prd_us_ac_ids lists AC1 AC2 of a ### story" || no "_prd_us_ac_ids = '$(_prd_us_ac_ids "$P/prd.md" US-001 | tr '\n' ' ')'"
err=$(LOGS_DIR="$TMPD" _lint_test_density "$P/prd.md" "$P/spec.md" warn 2>&1 >/dev/null)
[[ "$err" == *"US-001 has 0 tests for 2 ACs"* ]] && ok "_lint_test_density sees the ACs (density warning raised, not silently skipped)" || no "_lint_test_density skipped: '$err'"
out=$(_lint_3doc_consistency "$P/prd.md" "$P/spec.md" "$P" demo warn 2>&1)
[[ "$out" != *"has no '- AC"* ]] && ok "_lint_3doc_consistency: no false 'has no - ACn' advisory" || no "false advisory: $out"
export PATH="$REAL_PATH"

print ""
print "linux_portability_stat_awk: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
