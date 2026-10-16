#!/bin/zsh
# ============================================================================
# F6b / R3-01 — a word-wrap continuation row may follow the LAST option row only when the
# option block is then terminated by a recognized footer line ("Esc to cancel", "Enter to
# confirm", ...). Without a footer, aligned trailing output after a near-full-width last
# option row ("Status: finished", "ok") is output, not wrapped option text => the block is
# not an active dialog => refuse (unknown). Continuations between options keep the R2-02
# word-wrap evidence rule only (see tests/test_f1_prompt_selection.sh).
#
# Pure-function table on fixed captures: _bottom_prompt_selection.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"; }

_extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RUN"; }
TMP_LIB=$(mktemp -t f6b-last-option.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
{
  grep -m1 "^typeset -g _PROMPT_RE=" "$RUN"
  _extract_fn _bottom_prompt_selection
  _extract_fn _claude_bypass_dialog_visible
  _extract_fn _claude_bypass_heading_above
} > "$TMP_LIB"
grep -q "^_bottom_prompt_selection()" "$TMP_LIB" || { print -u2 "FAIL: _bottom_prompt_selection not extracted"; exit 1; }
source "$TMP_LIB"

sel() { _bottom_prompt_selection "$1" "${2:-}"; }
NL=$'\n'

W=60
Q=" Do you want to proceed?"
# Last option row: 6-column prefix + 52 text columns = 58 columns (fits a 60-column pane exactly
# like a full Ink row), so any aligned word of 2+ characters below it "proves" a wrap by length alone.
LAST6="   2. ${${:-Yes, and do not ask again for commands in /Users/kyjin/dev/rlp-desk}[1,52]}"
(( ${#LAST6} == 58 )) || { print -u2 "FIXTURE: last option row is ${#LAST6} columns, expected 58"; exit 1; }
IND="      "   # option text column of "   2. "

print "== R3-01: aligned trailing output after a near-full-width LAST option row is not a continuation =="
check "probe: 58-col last option, 'Status: finished' aligned to the text column, no footer => refuse" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}${IND}Status: finished" $W)"
check "probe: same with the one-word row 'ok' (58+1+2 > 60) => refuse" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}${IND}ok" $W)"
check "probe: same with cursor on the last option => refuse" unknown \
  "$(sel "${Q}${NL}   1. Yes${NL} ❯ 2. ${LAST6[7,-1]}${NL}${IND}ok" $W)"
check "probe: trailing blank line after the aligned output is still not a footer => refuse" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}${IND}ok${NL}" $W)"
check "two-row chain (second row also aligned and 'wrap-proven') after the last option, no footer => refuse" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}${IND}${${:-aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk}[1,52]}${NL}${IND}ok" $W)"

print "== R3-01: a genuinely wrapped LAST option followed by a recognized footer still accepts =="
WRAP_LAST="${LAST6}${NL}${IND}ok-wrapped-tail"
check "wrapped last option + 'Esc to cancel · Tab to amend' footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${WRAP_LAST}${NL}${NL} Esc to cancel · Tab to amend" $W)"
check "wrapped last option + 'Enter to confirm' footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${WRAP_LAST}${NL} Enter to confirm · Esc to cancel" $W)"
check "two-row wrapped last option chain + footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}${IND}${${:-aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk}[1,52]}${NL}${IND}ok${NL}${NL} Esc to cancel · Tab to amend" $W)"
check "wrapped last option + footer but wrap evidence missing (pane wide, width 400) => refuse (R2-02 unchanged)" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${WRAP_LAST}${NL} Esc to cancel · Tab to amend" 400)"
check "wrapped last option + footer but continuation misaligned (one column short) => refuse (R2-02 unchanged)" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${LAST6}${NL}     ok-wrapped-tail${NL} Esc to cancel · Tab to amend" $W)"
check "a non-footer row after the wrapped last option, then the footer => refuse (not terminated by the footer)" unknown \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${WRAP_LAST}${NL}Status: finished${NL} Esc to cancel · Tab to amend" $W)"

print "== R3-01: a wrapped MIDDLE option needs no footer (unchanged R2-02 behavior) =="
MID_LONG="   2. ${${:-Yes, and do not ask again for commands in /Users/kyjin/dev/rlp-desk}[1,52]}"
check "wrapped option 2 of 3, last option plain, no footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${MID_LONG}${NL}${IND}ok-wrapped-tail${NL}   3. No" $W)"
check "wrapped option 1 of 2 (cursor on it), no footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. ${MID_LONG[7,-1]}${NL}${IND}ok-wrapped-tail${NL}   2. No" $W)"
check "wrapped middle option with footer => accept" accept \
  "$(sel "${Q}${NL} ❯ 1. Yes${NL}${MID_LONG}${NL}${IND}ok-wrapped-tail${NL}   3. No${NL}${NL} Esc to cancel · Tab to amend" $W)"

print ""
print "f6b_last_option_continuation: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
