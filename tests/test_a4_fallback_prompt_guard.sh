#!/bin/zsh
# v5.7 §4.14 (Bug 5 fix) — A4 fallback must NOT fire when worker pane has a
# pending TUI permission prompt. Otherwise verifier gets dispatched against
# partial worker output (worker is mid-write, not done).
#
# This test asserts the gating logic: source the regex constants from
# run_ralph_desk.zsh and exercise the adjacency check with realistic captures.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Pull the regex constants out of the runner. They are typeset -g so a `source`
# in a sub-shell would execute the whole script; instead use sed to extract just
# the assignment lines.
TMP_LIB=$(mktemp -t a4-guard-test.XXXXXX)
sed -n '/^typeset -g _PROMPT_RE=/p; /^typeset -g _AFFORDANCE_RE=/p' "$RUN" > "$TMP_LIB"
source "$TMP_LIB"

PASS=0; FAIL=0
pass() { (( PASS++ )); print "PASS: $1"; }
fail() { (( FAIL++ )); print "FAIL: $1"; }

# Mock pane capture
_check_a4_blocked() {
  local capture="$1"
  local -a lines
  lines=("${(@f)capture}")
  local i n=${#lines[@]}
  for ((i=1; i <= n; i++)); do
    if [[ "${lines[i]}" =~ $_PROMPT_RE ]]; then
      local prev="${lines[i-1]:-}"
      local cur="${lines[i]}"
      local next="${lines[i+1]:-}"
      if [[ "$prev" =~ $_AFFORDANCE_RE || "$cur" =~ $_AFFORDANCE_RE || "$next" =~ $_AFFORDANCE_RE ]]; then
        return 0  # blocked (worker stuck on prompt)
      fi
    fi
  done
  return 1  # NOT blocked (proceed with A4)
}

# --- Bug 5 reproducer cases ---
capture1="some output
Do you want to create memos/test-spec.md? (y/n)
"
if _check_a4_blocked "$capture1"; then
  pass "Bug 5: A4 SUSPENDED when worker stuck on file-write prompt"
else
  fail "Bug 5: A4 should be suspended (worker has pending prompt)"
fi

capture2="Do you want to overwrite test.md?
1) Yes
"
if _check_a4_blocked "$capture2"; then
  pass "Bug 5: A4 SUSPENDED with numeric picker affordance"
else
  fail "Bug 5: A4 should be suspended"
fi

# --- Worker genuinely done — A4 should fire ---
capture3="Worker finished writing done-claim.json.
Operation complete.
"
if _check_a4_blocked "$capture3"; then
  fail "Worker idle without prompt — A4 should NOT be suspended"
else
  pass "Worker idle without prompt — A4 fires (correct behavior)"
fi

# --- Worker output mentions 'Do you want to' literally without prompt UI ---
capture4="Tutor says: Do you want to learn more about Rust?
Sure, here's a guide.
"
if _check_a4_blocked "$capture4"; then
  fail "Non-prompt 'Do you want to' text should NOT block A4"
else
  pass "Non-prompt 'Do you want to' text does not falsely block A4"
fi

rm -f "$TMP_LIB"
print
print "Total: $PASS pass, $FAIL fail"
(( FAIL == 0 ))
