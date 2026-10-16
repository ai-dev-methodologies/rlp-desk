#!/bin/zsh
# ============================================================================
# F1 / R2-A + R2-B + R2-G parity — the FROZEN fail-closed prompt rule on the zsh side.
#
#   P1 Active dialog   the option block is the last non-blank content of the capture, or
#                      is followed ONLY by recognized footer lines (blank / box-border
#                      lines are layout, not content). Any other line after the options =>
#                      not an active dialog.
#   P2 Option block    >= 2 option lines, exactly ONE cursor-marked. A single cursor line
#                      with no option siblings (an input box `❯ hello`) is not a picker.
#   P3 Question        the question line sits directly above the block, at most ONE blank
#                      line between it and the first option.
#   P4 Decision        accept only when P1-P3 hold, the question matches the prompt wording
#                      and the selected option is an accept option. A picker (P2) in the
#                      bottom region with P1-P4 not all holding => unknown (REFUSE), never
#                      `none`. `none` = no picker at all (inline (y/n) prompts, plain
#                      screens) and keeps the caller's inline logic.
#   Bypass dialog      IDENTIFICATION ONLY (owner decision 2026-10-15: rlp-desk never answers it):
#                      exact full labels "No, exit" / "Yes, I accept", exactly two options,
#                      the heading bound to the dialog block (up to 40 lines above the options,
#                      no question line ending in "?" and no shell-prompt line in between),
#                      confirm footer last.
#   R2-02 wrapped opt  a continuation row inside the option block needs word-wrap evidence
#                      (len(prev row)+1+len(first word) > pane_width) and the option-text indent.
#
# Pure-function table: _bottom_prompt_selection and _claude_bypass_dialog_visible on fixed
# captures (the call-shape tests live in tests/test_w1_prompt_binding.sh).
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
TMP_LIB=$(mktemp -t f1-prompt-selection.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
{
  grep -m1 "^typeset -g _PROMPT_RE=" "$RUN"
  _extract_fn _bottom_prompt_selection
  _extract_fn _claude_bypass_dialog_visible
  _extract_fn _claude_bypass_heading_above
} > "$TMP_LIB"
grep -q "^_bottom_prompt_selection()" "$TMP_LIB" || { print -u2 "FAIL: _bottom_prompt_selection not extracted"; exit 1; }
grep -q "^typeset -g _PROMPT_RE=" "$TMP_LIB" || { print -u2 "FAIL: _PROMPT_RE not extracted"; exit 1; }
source "$TMP_LIB"
grep -q "^_claude_bypass_dialog_visible()" "$TMP_LIB" || no "_claude_bypass_dialog_visible not extracted"
grep -q "^_claude_bypass_heading_above()" "$TMP_LIB" || no "_claude_bypass_heading_above not extracted"

sel() { _bottom_prompt_selection "$1" "${2:-}"; }
byp() { _claude_bypass_dialog_visible "$1" && print -r -- bypass || print -r -- none; }
NL=$'\n'

PERM_OPTS=" ❯ 1. Yes${NL}   2. Yes, allow all edits during this session (shift+tab)${NL}   3. No, and tell Claude what to do differently (esc)"

print "== P1-P4: genuine permission prompts keep working (accept) =="
check "real claude prompt: question, options, no footer" accept \
  "$(sel " Do you want to create test.json?${NL}${PERM_OPTS}")"
check "real claude prompt + blank + footer" accept \
  "$(sel " Do you want to create test.json?${NL}${PERM_OPTS}${NL}${NL} Esc to cancel · Tab to amend")"
check "ONE blank line between the question and the options (R2-G parity)" accept \
  "$(sel " Do you want to create test.json?${NL}${NL}${PERM_OPTS}${NL}${NL} Esc to cancel · Tab to amend")"
check "tool header above, trailing blank rows" accept \
  "$(sel "● Write(test.json)${NL} Do you want to create test.json?${NL}${PERM_OPTS}${NL}${NL}${NL}${NL}")"
check "box border rows after the options are layout, not content" accept \
  "$(sel " Do you want to proceed?${NL}${PERM_OPTS}${NL}╰────────────────────╯")"
check "legacy trust picker: question, cursor on Yes, confirm footer" accept \
  "$(sel "Do you trust the files in this folder?${NL}❯ 1. Yes, proceed${NL}  2. No, exit${NL}Enter to confirm · Esc to cancel")"
check "'Yes, and don't ask again' second option, cursor on 1" accept \
  "$(sel " Do you want to proceed?${NL} ❯ 1. Yes${NL}   2. Yes, and don't ask again for npm run test commands in /tmp/proj${NL}   3. No, and tell Claude what to do differently (esc)")"

print "== R2-A: a picker that is not an active identified dialog is REFUSED (never none) =="
check "R2-A probe 1: output after the options (cursor on No)" unknown \
  "$(sel "Do you want to proceed?${NL}  1. Yes${NL}❯ 2. No${NL}Status: waiting for input")"
check "R2-A probe 1b: output after the options (cursor on Yes)" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}  2. No${NL}Status: waiting for input")"
check "R2-A probe 2: stale 'Previous result' question, a heading, then an unrelated selected-Yes menu" unknown \
  "$(sel "Previous result: Do you want to create old.txt?${NL}Security settings${NL}❯ 1. Yes, enable${NL}  2. No, keep disabled${NL}Esc to cancel")"
check "R2-A probe 2b: stale 'Previous result' wording directly above the menu" unknown \
  "$(sel "Previous result: Do you want to create old.txt?${NL}❯ 1. Yes${NL}  2. No${NL}Esc to cancel")"
check "question two blank lines above the options (P3: at most one blank)" unknown \
  "$(sel "Do you want to proceed?${NL}${NL}${NL}❯ 1. Yes${NL}  2. No")"
check "no question line at all above the options" unknown \
  "$(sel "  ❯ 1. Yes${NL}    2. No${NL}Esc to cancel")"
check "a non-question line sits between the question and the options" unknown \
  "$(sel "Do you want to proceed?${NL}Details: the command touches 3 files${NL}❯ 1. Yes${NL}  2. No")"
check "two cursor-marked options" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}❯ 2. No")"
check "picker followed by claude UI output (a finished dialog's remnant)" unknown \
  "$(sel "Do you want to create x?${NL}❯ 1. Yes${NL}  2. No${NL}● Done${NL}❯ Try \"refactor\"")"
check "wording but unnumbered unknown picker + footer (Node R2-D probe shape)" unknown \
  "$(sel "Do you want to proceed? (y/n)${NL}❯ Destroy workspace${NL}  Open settings${NL}Esc to cancel")"
check "picker with no cursor + confirm footer" unknown \
  "$(sel "Do you want to proceed?${NL}  1. Yes${NL}  2. No${NL}Enter to confirm · Esc to cancel")"
check "question matches only mid-line ('see: Do you want to ...')" unknown \
  "$(sel "see the log: Do you want to create a.txt?${NL}❯ 1. Yes${NL}  2. No")"

print "== decline / bypass classes keep their meaning =="
check "question ok, cursor on No => decline" decline \
  "$(sel "Do you want to create test.json?${NL}  1. Yes${NL}❯ 2. No")"
BYP_DLG=" WARNING: Claude Code running in Bypass Permissions mode${NL} By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode.${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL} Enter to confirm · Esc to cancel"
check "the bypass-permissions warning (active) => bypass" bypass "$(sel "$BYP_DLG")"
check "stale wording above the warning => bypass" bypass \
  "$(sel "● earlier: Do you want to create test.json?${NL}${BYP_DLG}")"

print "== none stays none: no picker in the bottom region =="
check "inline (y/n) prompt, no picker" none "$(sel "Do you want to create test.json? (y/n)${NL}")"
check "numbered '1) Yes / 2) No' without a cursor (codex inline picker)" none \
  "$(sel "Choose an option:${NL}1) Yes${NL}2) No${NL}")"
check "a single cursor line is an input box, not a picker" none \
  "$(sel "Do you want to proceed? (y/n)${NL}❯ hello")"
check "claude ready screen" none \
  "$(sel " ▐▛███▛█   Claude Code v2.1.296${NL}──────────${NL}❯ Try \"refactor\"${NL}──────────${NL}  ⏵⏵ bypass permissions on (shift+tab to cycle)")"
check "empty capture" none "$(sel "")"
check "stale dialog far above (outside the bottom region) with a long scrollback after it" none \
  "$(sel "Do you want to create old.txt?${NL}❯ 1. Yes${NL}  2. No${NL}$(for i in {1..20}; do print -r -- "worker output line $i"; done)")"

print "== bypass dialog identification is exact (R2-B / S-4; identification only — the warning is never answered) =="
BH=" WARNING: Claude Code running in Bypass Permissions mode"
BB=" By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode."
FT=" Enter to confirm · Esc to cancel"
# OWN-1: the cursor position no longer matters (nothing is ever pressed): every cursor state is the same warning.
check "full dialog, cursor on No" bypass  "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "full dialog, cursor on Yes" bypass "$(byp "${BH}${NL}${BB}${NL}   1. No, exit${NL} ❯ 2. Yes, I accept${NL}${FT}")"
check "full dialog, no cursor" bypass "$(byp "${BH}${NL}${BB}${NL}   1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "blank lines around the options (real layout)" bypass \
  "$(byp "${BH}${NL}${NL}${BB}${NL}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${NL}${FT}${NL}${NL}")"
check "unnumbered options" bypass "$(byp "${BH}${NL}${BB}${NL}   No, exit${NL} ❯ Yes, I accept${NL}${FT}")"
check "label PREFIX: 'Yes, I accept deleting all project files'" none \
  "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept deleting all project files${NL}${FT}")"
check "label PREFIX on the other option: 'No, exit and delete the project'" none \
  "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit and delete the project${NL}   2. Yes, I accept${NL}${FT}")"
check "extra unnumbered 'Remind me later' option above the expected options" none \
  "$(byp "${BH}${NL}${BB}${NL}   Remind me later${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "extra numbered option above" none \
  "$(byp "${BH}${NL}${BB}${NL}   1. Remind me later${NL} ❯ 2. No, exit${NL}   3. Yes, I accept${NL}${FT}")"
check "extra numbered option below" none \
  "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}   3. Remind me later${NL}${FT}")"
check "stale bypass heading, then an unrelated 'Delete project permanently?' menu" none \
  "$(byp "${BH}${NL}${BB}${NL}Delete project permanently?${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "stale bypass heading, other question and other labels" none \
  "$(byp "${BH}${NL}${BB}${NL}Delete project permanently?${NL} ❯ 1. Yes${NL}   2. No${NL}${FT}")"
check "no heading" none "$(byp " ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "footer is not the last non-blank line" none \
  "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}${NL}shell prompt %")"
check "no footer" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept")"
check "only the decline option" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}${FT}")"

print "== R2-08z / M08: BOTH exact labels are required (dropping the 'No, exit' requirement must be detected) =="
check "M08: decline label 'Cancel' + 'Yes, I accept'" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. Cancel${NL}   2. Yes, I accept${NL}${FT}")"
check "M08: decline label 'Exit' + 'Yes, I accept'" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. Exit${NL}   2. Yes, I accept${NL}${FT}")"
check "M08: decline label bare 'No' + 'Yes, I accept'" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No${NL}   2. Yes, I accept${NL}${FT}")"
check "M08: decline label 'No, thanks' + 'Yes, I accept'" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, thanks${NL}   2. Yes, I accept${NL}${FT}")"
check "M08: 'Yes, I accept' twice, no decline" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. Yes, I accept${NL}   2. Yes, I accept${NL}${FT}")"
check "M08: 'No, exit' twice, no accept" none "$(byp "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. No, exit${NL}${FT}")"
check "backstop: heading-bound ACTIVE picker with a different decline label is still refused as the bypass warning (never none/accept)" bypass \
  "$(sel "${BH}${NL}${BB}${NL} ❯ 1. Cancel${NL}   2. Yes, I accept${NL}${FT}")"
check "backstop: heading-bound ACTIVE picker with a different accept label is still refused as the bypass warning" bypass \
  "$(sel "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, accept and remember${NL}${FT}")"
check "backstop: a footer-less variant of the warning (a future claude wording) is still refused as the bypass warning" bypass \
  "$(sel "${BH}${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept")"
check "backstop: stale heading, then a question line, then an unrelated menu is NOT the bypass warning (and still refused)" unknown \
  "$(sel "${BH}${NL}${BB}${NL}Delete project permanently?${NL} ❯ 1. Yes${NL}   2. No${NL}${FT}")"

print "== R2-03: the heading is bound to the dialog block (real full body, Ink-wrapped at several widths) =="
BT="WARNING: Claude Code running in Bypass Permissions mode"
B1="In Bypass Permissions mode, Claude Code will not ask for your approval before running potentially dangerous commands."
B2="This mode should only be used in a sandboxed container/VM that has restricted internet access and can easily be restored if damaged."
B3="By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode."
BL="https://docs.anthropic.com/s/claude-code-security"
_fold() { LC_ALL=en_US.UTF-8 fold -s -w "$1"; }
_real_dialog() { # $1 = pane width; title, 3 body paragraphs, docs link, the two options, footer
  local W=$1
  print -r -- "$BT" | _fold $W; print ""
  print -r -- "$B1" | _fold $W; print ""
  print -r -- "$B2" | _fold $W; print ""
  print -r -- "$B3" | _fold $W; print ""
  print -r -- "$BL" | _fold $W; print ""
  print -r -- " ❯ 1. No, exit"; print -r -- "   2. Yes, I accept"; print ""
  print -r -- " Enter to confirm · Esc to cancel"
}
for W in 120 80 60 40 30; do
  D="$(_real_dialog $W)"
  UP=$(print -r -- "$D" | awk '/Bypass Permissions mode$|Bypass$/ && !seen {t=NR; seen=1} /1\. No, exit/ {print NR-t; exit}')
  check "R2-03 real dialog at $W columns (title $UP rows above the options): identified (byp)" bypass "$(byp "$D")"
  check "R2-03 real dialog at $W columns: _bottom_prompt_selection => bypass" bypass "$(sel "$D")"
  check "R2-03 real dialog at $W columns under stale permission wording and worker prose" bypass \
    "$(sel "● earlier the worker asked: Do you want to create test.json?${NL}● ran 3 tools${NL}${D}")"
done
D40="$(_real_dialog 40)"
UP40=$(print -r -- "$D40" | awk '/Bypass$/ && !seen {t=NR; seen=1} /1\. No, exit/ {print NR-t; exit}')
(( UP40 > 15 )) && ok "R2-03 fixture check: at 40 columns the title is $UP40 rows above the options (> the old 15-row window)" || no "R2-03 fixture check: title only $UP40 rows above the options"
FILL="$(for i in {1..45}; do print -r -- "worker line $i"; done)"
check "R2-03 negative: a heading far above (more than ~40 rows), unrelated text between" none \
  "$(byp "${BH}${NL}${FILL}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "R2-03 negative: a question line ending in '?' between the heading and the options" none \
  "$(byp "${BH}${NL}${BB}${NL}Are you sure you want to proceed?${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"
check "R2-03 negative: a shell prompt line between the heading and the options (lookalike printed by a command)" none \
  "$(byp "${BH}${NL}${BB}${NL}kyjin@host rlp-desk % ${NL}${BB}${NL} ❯ 1. No, exit${NL}   2. Yes, I accept${NL}${FT}")"

print "== R2-02: a wrapped option row needs word-wrap evidence (pane width) =="
OPT2="Yes, and don't ask again for npm run test commands in /Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk"
_ink_opt() { # $1 width, $2 prefix, $3 text: greedy word wrap, continuation rows indented to the text column
  local W=$1 pre="$2" txt="$3" ind line w first=1
  ind=$(printf '%*s' ${#pre} '')
  line="$pre"
  for w in ${=txt}; do
    if (( first )); then line+="$w"; first=0
    elif (( ${#line} + 1 + ${#w} <= W )); then line+=" $w"
    else print -r -- "$line"; line="$ind$w"; fi
  done
  print -r -- "$line"
}
_wrapped_prompt() { # $1 = width
  print -r -- " Do you want to proceed?"
  print -r -- " ❯ 1. Yes"
  _ink_opt $1 "   2. " "$OPT2"
  print -r -- "   3. No, and tell Claude what to do differently (esc)"
  print ""; print -r -- " Esc to cancel · Tab to amend"
}
for W in 80 60; do
  P="$(_wrapped_prompt $W)"
  check "R2-02 real permission prompt, option 2 wraps at $W columns (rows: $(print -r -- "$P" | wc -l | tr -d ' ')), pane_width=$W" accept "$(sel "$P" $W)"
  check "R2-02 same capture, pane width unavailable => no continuation allowed => refuse" unknown "$(sel "$P")"
  check "R2-02 same capture, width given as 0/garbage => refuse" unknown "$(sel "$P" abc)"
  check "R2-02 same capture, but the pane is wide enough that no wrap is needed (width 400) => no evidence => refuse" unknown "$(sel "$P" 400)"
done
P80="$(_wrapped_prompt 80)"
check "R2-02 the cursor option itself wraps (cursor on the wrapped 2nd row owner) at 80" accept \
  "$(sel " Do you want to proceed?${NL}$(_ink_opt 80 " ❯ 1. " "$OPT2")${NL}   2. No, and tell Claude what to do differently (esc)" 80)"
check "R2-02 continuation indent one column short of the option text column => refuse" unknown \
  "$(sel "${P80/      \/Users/     /Users}" 80)"
check "R2-02 continuation indent one column past the option text column => refuse" unknown \
  "$(sel "${P80/      \/Users/       /Users}" 80)"
check "R2-02 continuation not indented at all => refuse" unknown \
  "$(sel "${P80/      \/Users//Users}" 80)"
check "R2-E style: aligned output after a SHORT option row is not a wrapped option => not an active dialog => refuse" unknown \
  "$(sel " Do you want to proceed?${NL} ❯ 1. Yes${NL}   2. No${NL}      Status: waiting for input" 80)"
check "R2-E style: same with the cursor on No" unknown \
  "$(sel " Do you want to proceed?${NL}   1. Yes${NL} ❯ 2. No${NL}      Status: waiting for input" 80)"
check "R2-E style: aligned output row whose first word fits on the previous option row" unknown \
  "$(sel " Do you want to proceed?${NL} ❯ 1. Yes${NL}   2. Yes, and don't ask again for npm run test commands${NL}      done in 3s${NL}" 80)"
check "R2-02: a continuation row followed by more output is still not an active dialog" unknown \
  "$(sel "$(_wrapped_prompt 80 | sed '/Esc to cancel/d')${NL}Status: waiting for input" 80)"

print "== R2-08z / M13: exactly ONE cursor-marked option (two cursors are never accepted) =="
check "M13: two cursors, first on Yes, last on No" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}❯ 2. No")"
check "M13: two cursors, first on No, last on Yes" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. No${NL}❯ 2. Yes")"
check "M13: three options, two cursors, both on Yes variants" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}❯ 2. Yes, allow all edits${NL}  3. No")"
check "M13: three options, cursors on 1 and 3 (Yes ... No)" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}  2. Yes, allow all edits${NL}❯ 3. No")"
check "M13: two cursors with the confirm footer" unknown \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}❯ 2. Yes, and don't ask again${NL}Enter to confirm · Esc to cancel")"
check "M13: control — exactly one cursor on Yes still accepts" accept \
  "$(sel "Do you want to proceed?${NL}❯ 1. Yes${NL}  2. Yes, allow all edits${NL}  3. No")"

print ""
print "f1_prompt_selection: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
