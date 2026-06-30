#!/usr/bin/env zsh
# Deterministic regression for the nightly real-LLM harness streak evaluator
# (tests/sv-real-llm/harness/nightly-run.sh). No LLM cost: exercises only the pure
# `--eval-only` streak verdict against mock streak logs, plus the dry-run gate.
# The nightly run itself (bug-05/bug-07 real-LLM) is operator-driven; this pins the
# 3-night-PASS-streak gating that decides the B3_STAGE2_BLOCKING flip (runbook §7.5.2).
set -uo pipefail
REPO="${0:A:h:h}"
NIGHTLY="$REPO/tests/sv-real-llm/harness/nightly-run.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

[[ -x "$NIGHTLY" || -f "$NIGHTLY" ]] || { print "FAIL: nightly-run.sh not found at $NIGHTLY"; exit 2; }
bash -n "$NIGHTLY" && ok "nightly-run.sh: bash -n clean" || no "nightly-run.sh: syntax error"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ev(){ RLP_NIGHTLY_STREAK_LOG="$1" bash "$NIGHTLY" --eval-only; }

# Streak lines are scenario-set-stamped ("set":"b3-e2e"); evaluate_streak counts ONLY that set.
S='"set":"b3-e2e",'
printf '{"date":"d1",'"$S"'"night_verdict":"PASS"}\n{"date":"d2",'"$S"'"night_verdict":"PASS"}\n{"date":"d3",'"$S"'"night_verdict":"PASS"}\n' > "$T/s3.jsonl"
[[ "$(ev "$T/s3.jsonl")" == STREAK_OK_ADVISORY* ]] && ok "3 consecutive PASS → STREAK_OK_ADVISORY" || no "3 PASS not READY_TO_FLIP"

printf '{"date":"d2",'"$S"'"night_verdict":"PASS"}\n{"date":"d3",'"$S"'"night_verdict":"PASS"}\n' > "$T/s2.jsonl"
[[ "$(ev "$T/s2.jsonl")" == NOT_YET* ]] && ok "2 PASS (< target) → NOT_YET" || no "2 PASS not NOT_YET"

printf '{"date":"d1",'"$S"'"night_verdict":"PASS"}\n{"date":"d2",'"$S"'"night_verdict":"FAIL"}\n{"date":"d3",'"$S"'"night_verdict":"PASS"}\n' > "$T/sf.jsonl"
[[ "$(ev "$T/sf.jsonl")" == INVESTIGATE* ]] && ok "a FAIL night in window → INVESTIGATE (halt flip)" || no "FAIL night not INVESTIGATE"

[[ "$(ev "$T/none.jsonl")" == NOT_YET* ]] && ok "no streak log → NOT_YET 0/target" || no "empty log not NOT_YET"

# only the LAST `target` nights count: an old FAIL outside the window must not block
printf '{"date":"d1",'"$S"'"night_verdict":"FAIL"}\n{"date":"d2",'"$S"'"night_verdict":"PASS"}\n{"date":"d3",'"$S"'"night_verdict":"PASS"}\n{"date":"d4",'"$S"'"night_verdict":"PASS"}\n' > "$T/s4.jsonl"
[[ "$(ev "$T/s4.jsonl")" == STREAK_OK_ADVISORY* ]] && ok "old FAIL outside last-target window → STREAK_OK_ADVISORY" || no "windowing wrong"

# custom target via env
printf '{"date":"d1",'"$S"'"night_verdict":"PASS"}\n{"date":"d2",'"$S"'"night_verdict":"PASS"}\n' > "$T/s2b.jsonl"
[[ "$(RLP_NIGHTLY_STREAK_TARGET=2 ev "$T/s2b.jsonl")" == STREAK_OK_ADVISORY* ]] && ok "RLP_NIGHTLY_STREAK_TARGET=2 honored (2 PASS → ADVISORY)" || no "custom target not honored"

# scenario-set isolation: stale OLD-regime lines (no "set", or a different set) must NOT
# count toward the b3-e2e streak (codex/code-reviewer MEDIUM: streak-log semantic mixing).
printf '{"date":"d1","bug05":"PASS","bug07":"PASS","night_verdict":"PASS"}\n{"date":"d2","bug05":"PASS","bug07":"PASS","night_verdict":"PASS"}\n{"date":"d3",'"$S"'"night_verdict":"PASS"}\n' > "$T/mix.jsonl"
[[ "$(ev "$T/mix.jsonl")" == NOT_YET* ]] && ok "2 old-regime PASS + 1 b3-e2e PASS → NOT_YET (old nights excluded, no false READY)" || no "old-regime lines leaked into b3-e2e streak"

# dry-run (no gate) → SKIPPED exit 77, no run, no cost
out=$(bash "$NIGHTLY" 2>&1); rc=$?
[[ "$rc" -eq 77 && "$out" == *SKIPPED* ]] && ok "dry-run without RLP_REAL_LLM_GATE → SKIPPED (exit 77, no cost)" || no "dry-run gate wrong (rc=$rc)"

print ""
if (( FAIL == 0 )); then print "nightly-streak: $PASS/$((PASS+FAIL)) PASS"; else print "nightly-streak: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
