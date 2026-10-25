#!/bin/zsh
# ============================================================================
# R3-02 — the R2-02 word-wrap evidence (length(previous row) + 1 + length(first word of the next row)
# exceeds the wrap column) must be measured against the dialog's CONTENT width, not the raw pane width.
# Ink lays a bordered dialog out inside its box: the visible leading `│ ` (border + padding) is mirrored on
# the right, so a row never grows past  pane_width - inset  (inset = the leading border/padding columns,
# 2 for `│ `). With the raw pane width a genuinely wrapped row whose next word would have fit within the
# PANE (but not within the CONTENT area) was refused (fail-closed), and a right-bordered row (which always
# ends on the pane's last column) counted as "full" whatever it held, so ANY aligned row below a short
# option was accepted as a continuation (fail-open).
#
# Existing fixtures set PANE_W == WRAP_AT and are unbordered, so they cannot tell the two widths apart
# (tests/test_w1_prompt_binding.sh, tests/test_f1_prompt_selection.sh, tests/test_f6b_*.sh). These
# fixtures are BORDERED and the pane (60) is wider than the Ink wrap column (58).
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
TMP_LIB=$(mktemp -t r302-wrap-width.XXXXXX)
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
W=60                       # what tmux reports (#{pane_width})
INSET=2                    # the visible leading `│ ` (border + padding), mirrored on the right
PRE="│   2. "              # option 2 row prefix; its text column is 7
IND="│      "              # continuation indent (aligned to the option text column)

# $1 = right border (0|1), $2 = total length of option row 2 (margin + prefix included), $3 = first word of
# the continuation row, $4 = left margin before the box border (default 0), $5 = column of the right border
# (default: the pane's last column). Option 2 is one long word padded to the exact length so the evidence sum
# is exact.
_dialog() {
  local rb=$1 total=$2 word=$3 m=${4:-0} rcol=${5:-$W} row2 mg n
  mg="${(l:m:: :)${:-}}"; n=$(( total - m - ${#PRE} ))
  row2="${mg}${PRE}${(l:n::x:)${:-}}"
  local -a rows=(
    "${mg}│ Do you want to proceed?"
    "${mg}│ ❯ 1. Yes"
    "$row2"
    "${mg}${IND}${word}"
    "${mg}│"
    "${mg}│ Esc to cancel · Tab to amend"
  )
  local r out=""
  (( rb && m == 0 && rcol == W )) && out="╭${(l:$(( W - 2 ))::─:)${:-}}╮"
  for r in "${rows[@]}"; do
    if (( rb )); then out+="${NL}${r}${(l:$(( rcol - ${#r} - 1 )):: :)${:-}}│"; else out+="${NL}${r}"; fi
  done
  (( rb && m == 0 && rcol == W )) && out+="${NL}╰${(l:$(( W - 2 ))::─:)${:-}}╯"
  print -r -- "$out"
}
# the fixture must discriminate: evidence sum = total + 1 + len(word)
_sum() { print -r -- $(( $1 + 1 + ${#2} )); }

print "== R3-02: genuine wraps in a RIGHT-bordered dialog (pane $W, Ink wrap column $(( W - INSET ))) are accepted =="
check "[right-bordered] row 54 + 1 + 5 = $(_sum 54 start) > $(( W - INSET )) (fits the PANE, not the content area) => accept" accept \
  "$(sel "$(_dialog 1 54 start)" $W)"
check "[right-bordered] row 54 + 1 + 4 = $(_sum 54 with) > $(( W - INSET )) => accept" accept \
  "$(sel "$(_dialog 1 54 with)" $W)"
check "[right-bordered] row 57 + 1 + 21 (a word far past either width) => accept" accept \
  "$(sel "$(_dialog 1 57 /Users/alice/dev/rlp-)" $W)"

print "== R3-02: boundary — a next word that FITS the content area is not wrap evidence =="
check "[right-bordered] row 53 + 1 + 4 = $(_sum 53 with) == $(( W - INSET )) (fits the content area exactly) => refuse" unknown \
  "$(sel "$(_dialog 1 53 with)" $W)"
check "[right-bordered] row 53 + 1 + 5 = $(_sum 53 start) > $(( W - INSET )) (one column over) => accept" accept \
  "$(sel "$(_dialog 1 53 start)" $W)"

# R1-05: with a LEFT border only there is no evidence of the right inset, so the raw pane width is used as
# before R3-02 (fail-closed): the inset is subtracted only when the row's right border was matched.
print "== R1-05: left border only (no right border): raw pane width, exactly as before R3-02 =="
check "[left-only] reviewer probe: 56-col option + aligned 'ok' (56+1+2 = $(_sum 56 ok) <= $W) => refuse" unknown \
  "$(sel "$(_dialog 0 56 ok)" $W)"
check "[left-only] row 54 + 1 + 5 = $(_sum 54 start) <= $W => refuse (conservative, no right border seen)" unknown \
  "$(sel "$(_dialog 0 54 start)" $W)"
check "[left-only] row 53 + 1 + 5 = $(_sum 53 start) <= $W => refuse" unknown "$(sel "$(_dialog 0 53 start)" $W)"
check "[left-only] row 57 + 1 + 21 = $(_sum 57 /Users/alice/dev/rlp-) > $W (a genuine wrap by pane width) => accept" accept \
  "$(sel "$(_dialog 0 57 /Users/alice/dev/rlp-)" $W)"

# R2-05: the content area is bounded by the BOXES own borders. A left margin before the border is neither
# text nor a second inset, so it must not shrink the wrap column again. Wrap column = right-border column - 2.
print "== R2-05: box with a left margin (m=8), right border on the pane's last column (60) =="
check "[m=8, rb=60] reviewer probe: 50-col option + aligned ok (50+1+2 = $(_sum 50 ok) <= 58) => refuse" unknown \
  "$(sel "$(_dialog 1 50 ok 8 60)" $W)"
check "[m=0 control] same geometry => refuse" unknown "$(sel "$(_dialog 1 50 ok 0 60)" $W)"
check "[m=8, rb=60] row 53 + 1 + 4 = $(_sum 53 with) == 58 (fits the content area) => refuse" unknown "$(sel "$(_dialog 1 53 with 8 60)" $W)"
check "[m=8, rb=60] row 53 + 1 + 5 = $(_sum 53 start) > 58 => accept" accept "$(sel "$(_dialog 1 53 start 8 60)" $W)"
check "[m=8, rb=60] row 54 + 1 + 5 = 60 > 58 => accept" accept "$(sel "$(_dialog 1 54 start 8 60)" $W)"
print "== R2-05: box with a left margin (m=8) and a symmetric right margin (right border on column 52) =="
check "[m=8, rb=52] row 45 + 1 + 4 = $(_sum 45 with) == 50 (fits the content area) => refuse" unknown "$(sel "$(_dialog 1 45 with 8 52)" $W)"
check "[m=8, rb=52] row 46 + 1 + 4 = $(_sum 46 with) > 50 => accept" accept "$(sel "$(_dialog 1 46 with 8 52)" $W)"
check "[m=8, rb=52] short option row (30) + aligned ok => refuse" unknown "$(sel "$(_dialog 1 30 ok 8 52)" $W)"
print "== R2-05: a right border that is not where the margins say (box much narrower than the pane) proves nothing =="
check "[m=8, rb=40, pane 60] row 30 + 1 + 5 => refuse (raw pane width, fail-closed)" unknown "$(sel "$(_dialog 1 30 start 8 40)" $W)"

# A-C3-01: the border PADDING is never text, whether or not the border qualifies as the wrap column. A box whose
# right border is NOT flush with the pane (margin condition fails) must still measure text extent, otherwise the
# padding inflates the row to the border column and an aligned trailing output row reads as a wrapped option.
print "== A-C3-01: right border off the pane's last column: padding is still not text =="
check "[m=0, rb=60, pane 61] 20-col option + aligned 'ok' => refuse (was accept)" unknown "$(sel "$(_dialog 1 20 ok 0 60)" 61)"
check "[m=0, rb=59, pane 60 (W-1)] 20-col option + aligned 'ok' => refuse" unknown "$(sel "$(_dialog 1 20 ok 0 59)" $W)"
check "[m=0, rb=58, pane 60 (W-2)] 20-col option + aligned 'ok' => refuse" unknown "$(sel "$(_dialog 1 20 ok 0 58)" $W)"
check "[m=0, rb=58, pane 60] 20-col option + aligned 'Status:' => refuse" unknown "$(sel "$(_dialog 1 20 Status: 0 58)" $W)"
check "[m=0, rb=58, pane 60] genuine wrap past the pane width (50 + 1 + 11 = 62 > 60) still accepted (raw width)" accept "$(sel "$(_dialog 1 50 /Users/alice 0 58)" $W)"

print "== R3-02: non-wraps stay refused (fail-closed) =="
for rb in 0 1; do
  lab=$([[ $rb == 1 ]] && print "right-bordered box" || print "left border only")
  check "[$lab] short option row (20) + aligned output 'ok' => refuse" unknown "$(sel "$(_dialog $rb 20 ok)" $W)"
  check "[$lab] short option row (20) + aligned 'Status:' => refuse" unknown "$(sel "$(_dialog $rb 20 Status:)" $W)"
  check "[$lab] long-word wrap geometry but no pane width available => refuse" unknown "$(sel "$(_dialog $rb 57 /Users/alice/dev/rlp-)" "")"
  check "[$lab] long-word wrap geometry on a pane far wider than the rows (400) => refuse" unknown "$(sel "$(_dialog $rb 57 /Users/alice/dev/rlp-)" 400)"
done

print ""
print "r302_wrap_content_width: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
