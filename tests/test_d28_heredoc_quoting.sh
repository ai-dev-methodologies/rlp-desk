#!/usr/bin/env zsh
# D-28: init_ralph_desk.zsh worker-prompt heredoc — no backtick command-substitution.
#
# The worker prompt heredoc is unquoted (<<EOF). Its markdown inline-code spans
# were written as BARE backticks (`lane_violation_warning`), which the unquoted
# heredoc executed as command substitutions while scaffolding — emitting
# "command not found" noise AND silently stripping the backticked terms from the
# generated worker prompt. (The verifier/testspec heredocs were unaffected: their
# backticks were already backslash-escaped, so they printed literally.)
#
# Fix: escape ONLY the worker heredoc's bare backticks (`->\`), leaving variable
# expansion ($DESK/$SLUG/$OBJECTIVE) and the already-escaped fences intact. This
# avoids the quoted-heredoc pitfalls (literal \` fences, sed metachar escaping for
# $DESK/objective paths). This test pins: no corruption, terms preserved, vars
# still expand, objective special chars survive (no sed → no escaping needed),
# and the verifier/testspec scaffolds stay correct.
set -uo pipefail
REPO=$(cd "${0:A:h}/.." && pwd)
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ print "  PASS $1"; PASS=$((PASS+1)); return 0; }
no(){ print "  FAIL $1"; FAIL=$((FAIL+1)); return 0; }

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cd "$D" || exit 2
git init -q 2>/dev/null

OBJ='build a|b pipe & amp \backslash and 100% done'
err=$(zsh "$INIT" f6mini "$OBJ" 2>&1 >/dev/null)

WP="$D/.rlp-desk/prompts/f6mini.worker.prompt.md"
VP="$D/.rlp-desk/prompts/f6mini.verifier.prompt.md"
TS="$D/.rlp-desk/plans/test-spec-f6mini.md"

cnf=$(print -r -- "$err" | grep -c 'command not found' || true)
[[ "$cnf" -eq 0 ]] && ok "no command-not-found corruption during init ($cnf)" \
  || { no "init emits $cnf command-not-found (worker heredoc executes bare backticks)"; print -r -- "$err" | grep 'command not found' | head -3; }

for term in 'lane_violation_warning' 'infra_failure' 'meta.blocked_hygiene_violated=true'; do
  grep -qF "$term" "$WP" 2>/dev/null && ok "worker prompt preserves backticked term: $term" \
    || no "worker prompt stripped backticked term: $term"
done

# worker still expands its variables (unquoted heredoc retained) — no literal $DESK/$SLUG
lit=$(grep -c '\$DESK\|\$SLUG' "$WP" 2>/dev/null || true)
[[ "$lit" -eq 0 ]] && ok "worker prompt expanded \$DESK/\$SLUG (no literal vars)" || no "worker prompt has $lit literal \$DESK/\$SLUG"

# objective with sed-special chars is intact (variable expansion, no sed escaping involved)
grep -qF "$OBJ" "$WP" && ok "objective special chars (| & \\ %) intact (no sed corruption)" || no "objective corrupted"

# verifier/testspec heredocs untouched and still correct
grep -qF "$D/.rlp-desk/memos/f6mini-verify-verdict.json" "$VP" \
  && ok "verifier verdict path correct (heredoc untouched)" || no "verifier verdict path wrong"

fences=$(grep -c '```' "$TS" 2>/dev/null || true)
broken=$(grep -c '\\```' "$TS" 2>/dev/null || true)
[[ "$fences" -gt 0 && "$broken" -eq 0 ]] && ok "testspec markdown fences intact ($fences fences, 0 literal-backslash)" \
  || no "testspec fences broken (fences=$fences broken=$broken)"

print ""
print "D-28: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
